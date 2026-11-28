from __future__ import annotations

import asyncio
import logging
import random
import time
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

from app.bot.operator_scanner import (
    FALLBACK_EDGE_IPS,
    OPERATOR_DNS_SOURCES,
    is_restricted_1034_ip,
    resolve_doh_records,
    sample_operator_cidr_ips,
    probe_proxy_ip,
    verify_cloudflare_edge_ip,
)
from app.bot.worker_template import CURATED_PROXY_IPS
from app.bot.warp_builder import (
    OFFICIAL_WARP_IPV6_ENDPOINTS,
    OFFICIAL_WARP_PEER_PUBKEY,
    generate_x25519_keypair,
    register_real_warp_device,
    split_endpoint,
)
from app.bot.wg_handshake import probe_real_warp_handshake

logger = logging.getLogger(__name__)

WARP_V4_PREFIXES = ["162.159.192", "162.159.193", "162.159.195", "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
WARP_UDP_PORTS = [2408, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 945, 955, 1002, 1018, 1074, 1701, 1843, 2371, 4500]

ProgressCallback = Callable[[int, str], Awaitable[None]]


def generate_warp_v4_candidates(count: int = 24) -> list[tuple[str, int]]:
    base = [
        ("162.159.192.1", 2408), ("162.159.192.8", 854), ("162.159.193.1", 2408),
        ("162.159.193.10", 894), ("162.159.195.1", 2408), ("162.159.195.5", 908),
        ("188.114.96.1", 2408), ("188.114.97.1", 1074), ("188.114.98.1", 939), ("188.114.99.1", 1843),
    ]
    seen = set(base)
    while len(base) < count:
        pair = (f"{random.choice(WARP_V4_PREFIXES)}.{random.randint(1, 250)}", random.choice(WARP_UDP_PORTS))
        if pair not in seen:
            seen.add(pair)
            base.append(pair)
    return base


async def _fallback_tcp_rtt(host: str, timeout_sec: float = 2.0) -> tuple[bool, float | None]:
    """Fallback reachability probe when VPS blocks outbound UDP WireGuard handshakes."""
    writer = None
    try:
        t0 = time.perf_counter()
        _, writer = await asyncio.wait_for(asyncio.open_connection(host.strip("[]"), 443), timeout=timeout_sec)
        ms = round((time.perf_counter() - t0) * 1000.0, 2)
        return True, ms
    except Exception:
        return False, None
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


class BackgroundScannerEngine:
    def __init__(self, store):
        self.store = store
        self._loop_task: asyncio.Task | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.progress_pct: int = 0
        self.last_scan_at: str | None = None
        self._purge_restricted_ips()

    def _purge_restricted_ips(self) -> None:
        changed = False
        for op in ("mci", "mtn", "mkh"):
            old = self.store.data.get("operator_pools", {}).get(op, [])
            cleaned = [x for x in old if not is_restricted_1034_ip(x.get("ip", ""))]
            if len(cleaned) != len(old):
                self.store.data["operator_pools"][op] = cleaned
                changed = True
        for panel in self.store.data.get("panels", {}).values():
            if is_restricted_1034_ip(panel.get("clean_ip", "")):
                op = panel.get("operator", "mci")
                panel["clean_ip"] = FALLBACK_EDGE_IPS.get(op, ["104.16.132.229"])[0]
                changed = True
        if changed:
            self.store.save()

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v24")

    async def stop(self) -> None:
        if self._loop_task and not self._loop_task.done():
            self._loop_task.cancel()
            try:
                await self._loop_task
            except asyncio.CancelledError:
                pass

    async def _ensure_probe_device(self) -> dict:
        dev = self.store.data.get("warp_probe_device")
        if dev and dev.get("private_key"):
            return dev
        reg = await register_real_warp_device(timeout_sec=10.0)
        if reg.ok:
            dev = {
                "private_key": reg.private_key,
                "peer_public_key": reg.peer_public_key or OFFICIAL_WARP_PEER_PUBKEY,
                "reserved": reg.reserved or [0, 0, 0],
            }
            self.store.data["warp_probe_device"] = dev
            self.store.save()
            return dev
        # Local X25519 fallback so WARP scanner NEVER gets skipped!
        priv, _ = generate_x25519_keypair()
        return {"private_key": priv, "peer_public_key": OFFICIAL_WARP_PEER_PUBKEY, "reserved": [0, 0, 0]}

    async def _scheduler_loop(self) -> None:
        await asyncio.sleep(2)
        while True:
            try:
                if self.store.data["settings"].get("auto_scan_enabled", True) and not self.is_scanning:
                    await self.run_full_cycle(trigger="auto")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("V24 background scan error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_warp_only_scan(self, on_progress: ProgressCallback | None = None) -> dict[str, Any]:
        """Dedicated WARP Endpoint scanner (IPv4 + IPv6) with live progress bar."""
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async def _rep(pct: int, msg: str) -> None:
            self.progress_pct = pct
            if on_progress:
                try:
                    await on_progress(pct, msg)
                except Exception:
                    pass

        async with self._scan_lock:
            self.is_scanning = True
            self.current_stage = "warp_udp"
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                await _rep(15, "آماده‌سازی کلید تست WireGuard / WARP...")
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                sem = asyncio.Semaphore(12)

                async def _test_pair(host: str, port: int, version: int):
                    async with sem:
                        ok, rtt = await probe_real_warp_handshake(
                            host, port, probe_dev["private_key"], probe_dev["peer_public_key"],
                            reserved=probe_dev["reserved"], timeout_sec=timeout_sec,
                        )
                        if not ok or rtt is None:
                            ok, rtt = await _fallback_tcp_rtt(host, timeout_sec=timeout_sec)
                        if not ok or rtt is None:
                            return None
                        return {
                            "endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}",
                            "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat(),
                        }

                await _rep(40, "در حال اسکن ۲۴ رله IPv4 کلودفلر WARP...")
                v4_res = await asyncio.gather(*(_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(24)))
                v4_ok = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                if v4_ok:
                    self.store.data["warp_v4_pool"] = v4_ok

                await _rep(75, "در حال اسکن رله‌های IPv6 کلودفلر WARP...")
                v6_res = await asyncio.gather(*(_test_pair(*split_endpoint(ep), 6) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS))
                v6_ok = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]
                if v6_ok:
                    self.store.data["warp_v6_pool"] = v6_ok

                self.last_scan_at = now.isoformat()
                self.store.save()
                await _rep(100, "✅ اسکن اندپوینت‌های WARP تکمیل شد!")
                return {
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    async def run_full_cycle(
        self,
        trigger: str = "manual",
        on_progress: ProgressCallback | None = None,
    ) -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async def _report(pct: int, msg: str) -> None:
            self.progress_pct = pct
            if on_progress:
                try:
                    await on_progress(pct, msg)
                except Exception:
                    pass

        async with self._scan_lock:
            self.is_scanning = True
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                manual = self.store.data.get("manual_operator_ips", {})
                sem = asyncio.Semaphore(18)

                async def _probe(ip: str, source: str):
                    async with sem:
                        res = await verify_cloudflare_edge_ip(ip, 443, timeout_sec=timeout_sec)
                        if res:
                            res["source"] = source
                        return res

                op_steps = [
                    ("mci", "🔵 همراه اول", 15, 35),
                    ("mtn", "🟡 ایرانسل", 40, 58),
                    ("mkh", "🟢 مخابرات", 62, 78),
                ]
                for op, op_fa, p_start, p_end in op_steps:
                    self.current_stage = f"scan_{op}"
                    await _report(p_start, f"در حال دریافت و تست IPهای تمیز {op_fa}...")
                    cand_map: dict[str, str] = {}
                    for mip in manual.get(op, []):
                        if not is_restricted_1034_ip(mip):
                            cand_map[mip.strip()] = "admin_manual"
                    dns_domains = OPERATOR_DNS_SOURCES.get(op, [])
                    resolved = await asyncio.gather(*(resolve_doh_records(d, "A") for d in dns_domains))
                    for dom, ips in zip(dns_domains, resolved):
                        for ip in ips:
                            cand_map.setdefault(ip, dom)
                    for cip in sample_operator_cidr_ips(op, 8):
                        cand_map.setdefault(cip, "cidr_scan")
                    for fb in FALLBACK_EDGE_IPS.get(op, []):
                        cand_map.setdefault(fb, "cf_edge_clean")

                    probed = await asyncio.gather(*(_probe(ip, src) for ip, src in cand_map.items()))
                    valid = [p for p in probed if p is not None]
                    valid.sort(
                        key=lambda x: (
                            2 if x["source"] == "admin_manual" else (1 if "ircf" in x["source"] or "vfarid" in x["source"] else 0),
                            x["score"],
                            -(x["latency_ms"] or 9999),
                        ),
                        reverse=True,
                    )
                    if valid:
                        self.store.data["operator_pools"][op] = valid[:25]
                    await _report(p_end, f"تست {op_fa} تکمیل شد ({len(valid)} IP سالم)")

                if self.store.data["settings"].get("auto_apply_ip", True):
                    for panel in self.store.data.get("panels", {}).values():
                        if panel.get("auto_ip", True):
                            best = self.get_best_operator_ips(panel.get("operator", "mci"), 1)
                            if best:
                                panel["clean_ip"] = best[0]["ip"]

                self.current_stage = "warp_udp"
                await _report(85, "در حال اسکن رله‌های WARP (IPv4 + IPv6)...")
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                wsem = asyncio.Semaphore(12)

                async def _test_pair(host: str, port: int, version: int):
                    async with wsem:
                        ok, rtt = await probe_real_warp_handshake(
                            host, port, probe_dev["private_key"], probe_dev["peer_public_key"],
                            reserved=probe_dev["reserved"], timeout_sec=timeout_sec,
                        )
                        if not ok or rtt is None:
                            ok, rtt = await _fallback_tcp_rtt(host, timeout_sec=timeout_sec)
                        if not ok or rtt is None:
                            return None
                        return {
                            "endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}",
                            "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat(),
                        }

                v4_res, v6_res = await asyncio.gather(
                    asyncio.gather(*(_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(24))),
                    asyncio.gather(*(_test_pair(*split_endpoint(ep), 6) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS)),
                )
                v4_ok = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                v6_ok = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]
                if v4_ok:
                    self.store.data["warp_v4_pool"] = v4_ok
                if v6_ok:
                    self.store.data["warp_v6_pool"] = v6_ok

                self.current_stage = "proxy_ips"
                await _report(93, "در حال تست زنده لیست ProxyIPهای اختیاری...")
                p_res = await asyncio.gather(*(probe_proxy_ip(p, timeout_sec=timeout_sec) for p in CURATED_PROXY_IPS))
                p_ok = sorted([x for x in p_res if x], key=lambda x: x["latency_ms"])
                if p_ok:
                    self.store.data["proxy_ip_pool"] = p_ok
                self.last_scan_at = now.isoformat()
                self.store.save()
                await _report(100, "✅ اسکن کامل انجام شد و برترین IPها روی پنل کاربران سوار شد!")
                return {
                    "mci": len(self.store.data["operator_pools"].get("mci", [])),
                    "mtn": len(self.store.data["operator_pools"].get("mtn", [])),
                    "mkh": len(self.store.data["operator_pools"].get("mkh", [])),
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    def get_best_operator_ips(self, op: str = "mci", count: int = 8) -> list[dict[str, Any]]:
        raw = [x for x in self.store.data.get("operator_pools", {}).get(op, []) if not is_restricted_1034_ip(x.get("ip", ""))]
        if not raw:
            raw = [{"ip": ip, "latency_ms": None, "colo": "CF"} for ip in FALLBACK_EDGE_IPS.get(op, ["104.16.132.229"])]
        items = list(raw)[:count]
        for it in items:
            it["operator"] = op
        return items

    def get_best_warp_endpoints(self) -> tuple[str, str, float | None]:
        v4 = self.store.data.get("warp_v4_pool", [])
        v6 = self.store.data.get("warp_v6_pool", [])
        ep4 = v4[0]["endpoint"] if v4 else "162.159.192.1:2408"
        ep6 = v6[0]["endpoint"] if v6 else OFFICIAL_WARP_IPV6_ENDPOINTS[0]
        ping = v4[0]["latency_ms"] if v4 else (v6[0]["latency_ms"] if v6 else None)
        return ep4, ep6, ping

    def get_proxy_ip_pool(self) -> list[dict[str, Any]]:
        pool = list(self.store.data.get("proxy_ip_pool") or [])
        seen = {x.get("proxy_ip") for x in pool}
        for p in CURATED_PROXY_IPS:
            if p not in seen:
                pool.append({"proxy_ip": p, "latency_ms": None, "ok": True})
        return pool

    def get_best_proxy_ip(self) -> str:
        pool = self.get_proxy_ip_pool()
        return str(pool[0]["proxy_ip"]) if pool else CURATED_PROXY_IPS[0]
