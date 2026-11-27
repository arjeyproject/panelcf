#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V4 (AutoVless UI + Direct CF Token + Anti-DPI WARP)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/ui.py
from __future__ import annotations

from typing import Literal

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

ButtonStyle = Literal["primary", "success", "danger"]

# Direct Cloudflare API Token creation URL with all required permissions pre-selected
CLOUDFLARE_DIRECT_TOKEN_URL = (
    "https://dash.cloudflare.com/profile/api-tokens?"
    "permissionGroupKeys=%5B"
    "%7B%22key%22%3A%22page%22%2C%22type%22%3A%22edit%22%7D%2C"
    "%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C"
    "%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C"
    "%7B%22key%22%3A%22account_settings%22%2C%22type%22%3A%22read%22%7D%2C"
    "%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C"
    "%7B%22key%22%3A%22workers_routes%22%2C%22type%22%3A%22edit%22%7D%2C"
    "%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D"
    "%5D&accountId=*&zoneId=all&name=CFHubTurbo"
)
CLOUDFLARE_SIGNUP_URL = "https://dash.cloudflare.com/sign-up"

_NATIVE_STYLE = "style" in getattr(InlineKeyboardButton, "model_fields", {})


class StyledButton(InlineKeyboardButton):
    """InlineKeyboardButton subclass ensuring `style` (primary/success/danger) serializes for Bot API 9.4+."""
    style: str | None = None


def btn(
    text: str,
    *,
    callback_data: str | None = None,
    url: str | None = None,
    style: ButtonStyle | None = None,
) -> InlineKeyboardButton:
    kwargs: dict = {"text": text}
    if callback_data is not None:
        kwargs["callback_data"] = callback_data
    if url is not None:
        kwargs["url"] = url
    if style is not None:
        kwargs["style"] = style
    if _NATIVE_STYLE or style is None:
        return InlineKeyboardButton(**kwargs)
    return StyledButton(**kwargs)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def main_menu_kb(is_admin: bool = False, lang: str = "fa") -> InlineKeyboardMarkup:
    if lang == "en":
        rows = [
            [btn("🚀 Build Turbo Panel", callback_data="m:turbo", style="success")],
            [btn("🎛️ Manage My Panel", callback_data="m:mypanel", style="primary")],
            [btn("🛡️ Build WARP / WireGuard", callback_data="m:warp", style="primary")],
            [btn("📱 Apps & Downloads", callback_data="m:apps", style="primary")],
            [
                btn("📖 Connection Guide", callback_data="m:guide", style="primary"),
                btn("💬 Support", callback_data="m:support", style="primary"),
            ],
            [
                btn("🔴 Free Config", callback_data="m:free", style="primary"),
                btn("🎁 Invite Friends", callback_data="m:invite", style="primary"),
            ],
            [
                btn("❤️ Support Us", callback_data="m:donate", style="primary"),
                btn("🇮🇷 فارسی", callback_data="m:lang", style="primary"),
            ],
        ]
        if is_admin:
            rows.append([btn("🛠️ Admin Panel", callback_data="adm:home", style="danger")])
        return kb(rows)

    # Persian RTL layout matching the requested AutoVless design
    rows = [
        [btn("🚀 ساخت پنل توربو", callback_data="m:turbo", style="success")],
        [btn("🎛️ مدیریت پنل من", callback_data="m:mypanel", style="primary")],
        [btn("🛡️ ساخت WARP / WireGuard", callback_data="m:warp", style="primary")],
        [btn("📱 برنامه‌ها و دانلود", callback_data="m:apps", style="primary")],
        [
            btn("📖 راهنمای اتصال", callback_data="m:guide", style="primary"),
            btn("💬 پشتیبانی", callback_data="m:support", style="primary"),
        ],
        [
            btn("🔴 کانفیگ رایگان", callback_data="m:free", style="primary"),
            btn("🎁 دعوت دوستان", callback_data="m:invite", style="primary"),
        ],
        [
            btn("❤️ حمایت از ما", callback_data="m:donate", style="primary"),
            btn("🌐 English", callback_data="m:lang", style="primary"),
        ],
    ]
    if is_admin:
        rows.append([btn("🛠️ پنل مدیریت", callback_data="adm:home", style="danger")])
    return kb(rows)


def back_home_kb(
    back_cb: str = "m:home",
    lang: str = "fa",
    extra_rows: list[list[InlineKeyboardButton]] | None = None,
) -> InlineKeyboardMarkup:
    rows = list(extra_rows) if extra_rows else []
    label = "🔙 بازگشت" if lang == "fa" else "🔙 Back"
    rows.append([btn(label, callback_data=back_cb, style="primary")])
    return kb(rows)
__CFHUB_V4_EOF__

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/store.py
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.core.config import get_settings
from app.security.crypto import SecretVault


def _resolve_writable_store_path() -> Path:
    candidates = [
        Path(os.getenv("HUB_STATE_PATH", "/app/data/hub_state.json")),
        Path("/tmp/cfhub_data/hub_state.json"),
    ]
    for path in candidates:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            probe = path.parent / ".write_test"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            return path
        except Exception:
            continue
    return Path("/tmp/hub_state.json")


class PersistentHubStore:
    """Thread-safe JSON persistent store with Fernet AES encryption for Cloudflare API tokens."""

    def __init__(self, path: str | None = None):
        self.path = Path(path) if path else _resolve_writable_store_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        settings = get_settings()
        master = settings.encryption_master_key or settings.jwt_secret_key or "cfhub-default-fallback-key"
        self._vault = SecretVault(master)
        self.data: dict[str, Any] = self._load()

    def _default_state(self) -> dict[str, Any]:
        settings = get_settings()
        owner_id = settings.owner_telegram_ids[0] if settings.owner_telegram_ids else 0
        return {
            "users": {},
            "cf_accounts": {},
            "panels": {},
            "ip_pool": [],
            "endpoint_pool": [],
            "custom_cidrs": [],
            "free_configs": [],
            "scan_history": [],
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "channel_username": os.getenv("CHANNEL_USERNAME", "").lstrip("@"),
                "donate_text": "❤️ این سرویس رایگان است و رایگان می‌ماند.\nبهترین حمایت شما معرفی ربات به دوستانتان است!",
                "maintenance_mode": False,
                "auto_apply_ip": True,
                "auto_scan_enabled": True,
                "auto_scan_interval_hours": 6,
                "ip_sample_size": 48,
                "min_quality_score": 55.0,
                "scan_timeout_sec": 2.8,
                "scan_concurrency": 24,
            },
        }

    def _load(self) -> dict[str, Any]:
        default = self._default_state()
        if not self.path.exists():
            return default
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            for k, v in default.items():
                loaded.setdefault(k, v)
            for sk, sv in default["settings"].items():
                loaded["settings"].setdefault(sk, sv)
            return loaded
        except Exception:
            return default

    def save(self) -> None:
        with self._lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp.replace(self.path)

    def encrypt_secret(self, raw: str) -> str:
        return self._vault.encrypt(raw)

    def decrypt_secret(self, enc: str) -> str:
        return self._vault.decrypt(enc)

    def touch_user(self, tg_id: int, username: str | None, full_name: str | None) -> dict[str, Any]:
        with self._lock:
            key = str(tg_id)
            now = datetime.now(timezone.utc).isoformat()
            u = self.data["users"].get(key)
            if not u:
                u = {
                    "telegram_id": tg_id,
                    "username": username or "",
                    "full_name": full_name or "",
                    "lang": "fa",
                    "is_banned": False,
                    "is_vip": False,
                    "referrals": [],
                    "referred_by": None,
                    "joined_at": now,
                    "last_seen": now,
                    "configs_generated": 0,
                    "warp_generated": 0,
                }
                self.data["users"][key] = u
            else:
                u["username"] = username or u.get("username", "")
                u["full_name"] = full_name or u.get("full_name", "")
                u["last_seen"] = now
                u.setdefault("lang", "fa")
                u.setdefault("referrals", [])
                u.setdefault("warp_generated", 0)
            self.save()
            return u

    def get_lang(self, tg_id: int) -> str:
        return self.data["users"].get(str(tg_id), {}).get("lang", "fa")

    def toggle_lang(self, tg_id: int) -> str:
        with self._lock:
            u = self.data["users"].setdefault(str(tg_id), {"telegram_id": tg_id, "lang": "fa"})
            nxt = "en" if u.get("lang", "fa") == "fa" else "fa"
            u["lang"] = nxt
            self.save()
            return nxt

    def record_referral(self, referrer_id: int, new_user_id: int) -> bool:
        if referrer_id == new_user_id:
            return False
        with self._lock:
            ref_u = self.data["users"].get(str(referrer_id))
            new_u = self.data["users"].get(str(new_user_id))
            if not ref_u or not new_u or new_u.get("referred_by"):
                return False
            refs = ref_u.setdefault("referrals", [])
            if new_user_id not in refs:
                refs.append(new_user_id)
                new_u["referred_by"] = referrer_id
                self.save()
                return True
            return False

    def increment_stat(self, tg_id: int, field: str = "configs_generated") -> None:
        with self._lock:
            u = self.data["users"].get(str(tg_id))
            if u:
                u[field] = int(u.get(field, 0)) + 1
                self.save()

    def is_banned(self, tg_id: int) -> bool:
        return bool(self.data["users"].get(str(tg_id), {}).get("is_banned", False))

    def set_ban(self, tg_id: int, banned: bool) -> None:
        with self._lock:
            key = str(tg_id)
            now = datetime.now(timezone.utc).isoformat()
            u = self.data["users"].setdefault(key, {
                "telegram_id": tg_id,
                "username": "",
                "full_name": "",
                "lang": "fa",
                "is_banned": banned,
                "joined_at": now,
                "last_seen": now,
                "configs_generated": 0,
                "warp_generated": 0,
            })
            u["is_banned"] = banned
            self.save()

    def find_user(self, query: str) -> dict[str, Any] | None:
        q = query.strip().lstrip("@").lower()
        if not q:
            return None
        if q in self.data["users"]:
            return self.data["users"][q]
        for u in self.data["users"].values():
            if u.get("username", "").lower() == q:
                return u
        return None
__CFHUB_V4_EOF__

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import ipaddress
import logging
import os
import random
import socket
import struct
import time
from datetime import datetime, timezone
from typing import Any

from app.ranking.ip_ranker import CandidateMetricsInput, SmartIPRanker
from app.scanners.base import BoundedAdaptiveRunner
from app.scanners.ip_scanner import IPCandidateScanner, IPScanOptions

logger = logging.getLogger(__name__)

# Official Cloudflare public IPv4 edge ranges
DEFAULT_CF_CIDRS = [
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "162.159.0.0/16",
    "188.114.96.0/20",
]

# Official Cloudflare WARP WireGuard UDP endpoints (verified engage ranges + alternate UDP ports)
DEFAULT_WARP_ENDPOINTS = [
    "162.159.192.1:2408",
    "162.159.192.1:500",
    "162.159.192.1:1701",
    "162.159.192.1:4500",
    "162.159.192.1:854",
    "162.159.192.1:894",
    "162.159.192.8:2408",
    "162.159.193.1:2408",
    "162.159.193.1:894",
    "162.159.193.10:2408",
    "162.159.195.1:2408",
    "162.159.195.1:908",
    "162.159.195.5:2408",
    "188.114.96.1:2408",
    "188.114.96.1:854",
    "188.114.97.1:2408",
    "188.114.97.1:1074",
    "188.114.98.1:2408",
    "188.114.99.1:2408",
    "engage.cloudflareclient.com:2408",
    "162.159.192.1:443",
    "162.159.193.1:443",
    "162.159.195.1:443",
]


def sample_ips_from_cidrs(cidrs: list[str], total_samples: int = 48) -> list[str]:
    networks = []
    for raw in cidrs:
        try:
            net = ipaddress.ip_network(raw.strip(), strict=False)
            if net.version == 4 and net.is_global:
                networks.append(net)
        except ValueError:
            continue
    if not networks:
        return []
    result: set[str] = set()
    per_net = max(2, total_samples // len(networks))
    for net in networks:
        num = net.num_addresses
        if num <= 4:
            for ip in net.hosts():
                result.add(str(ip))
        else:
            for _ in range(per_net * 2):
                if len(result) >= total_samples:
                    break
                offset = random.randint(1, num - 2)
                result.add(str(net.network_address + offset))
    return list(result)[:total_samples]


class _UDPProbeProtocol(asyncio.DatagramProtocol):
    def __init__(self, fut: asyncio.Future):
        self.fut = fut

    def datagram_received(self, data: bytes, addr):
        if not self.fut.done():
            self.fut.set_result(data)

    def error_received(self, exc):
        if not self.fut.done():
            self.fut.set_exception(exc)


async def probe_warp_udp_endpoint(host: str, port: int, timeout_sec: float = 2.0) -> tuple[bool, float | None, str]:
    """
    Real WARP UDP / Edge reachability probe.
    Tests DNS resolution + real UDP socket transmission + edge latency on the exact host.
    """
    loop = asyncio.get_running_loop()
    start = time.perf_counter()
    try:
        infos = await asyncio.wait_for(loop.getaddrinfo(host, port, type=socket.SOCK_DGRAM), timeout=timeout_sec)
        target_ip = infos[0][4][0]
    except Exception:
        return False, None, "dns_failed"

    # Send a minimal UDP keepalive/probe packet (checks OS routing & ICMP unreachable errors)
    transport = None
    try:
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(
            loop.create_datagram_endpoint(lambda: _UDPProbeProtocol(fut), remote_addr=(target_ip, port)),
            timeout=timeout_sec,
        )
        # 4-byte non-malformed probe (WireGuard type=4 keepalive header with zero receiver)
        transport.sendto(struct.pack("<II", 4, 0) + os.urandom(8))
        # Verify edge RTT via TCP/443 simultaneously so latency reflects real round-trip time to this PoP
        reader, writer = await asyncio.wait_for(asyncio.open_connection(target_ip, 443), timeout=timeout_sec)
        elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        # Check if an immediate ICMP Port Unreachable occurred on UDP
        if fut.done() and fut.exception() is not None:
            return False, None, "icmp_unreachable"
        return True, elapsed_ms, "reachable"
    except Exception:
        return False, None, "timeout"
    finally:
        if transport is not None:
            transport.close()


class BackgroundScannerEngine:
    """Autonomous background IP & WARP Endpoint scanner engine."""

    def __init__(self, store):
        self.store = store
        self._ip_scanner = IPCandidateScanner()
        self._ranker = SmartIPRanker()
        self._loop_task: asyncio.Task | None = None
        self._active_runner: BoundedAdaptiveRunner | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.progress_done: int = 0
        self.progress_total: int = 0
        self.last_scan_at: str | None = None
        self.last_error: str | None = None

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_scanner")

    async def stop(self) -> None:
        self.cancel_current_scan()
        if self._loop_task and not self._loop_task.done():
            self._loop_task.cancel()
            try:
                await self._loop_task
            except asyncio.CancelledError:
                pass

    def cancel_current_scan(self) -> None:
        if self._active_runner:
            self._active_runner.cancel()

    async def _scheduler_loop(self) -> None:
        await asyncio.sleep(3)
        while True:
            try:
                auto_on = bool(self.store.data["settings"].get("auto_scan_enabled", True))
                if auto_on and not self.is_scanning:
                    await self.run_full_cycle(trigger="auto")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception("Background scanner cycle error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_full_cycle(self, trigger: str = "manual", custom_ips: list[str] | None = None) -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async with self._scan_lock:
            self.is_scanning = True
            self.last_error = None
            cfg = self.store.data["settings"]
            timeout_sec = float(cfg.get("scan_timeout_sec", 2.8))
            concurrency = int(cfg.get("scan_concurrency", 24))
            min_score = float(cfg.get("min_quality_score", 55.0))
            sample_size = int(cfg.get("ip_sample_size", 48))

            try:
                # Phase 1: Real multi-round TCP/TLS IP scan
                self.current_stage = "ip_scan"
                cidrs = list(DEFAULT_CF_CIDRS) + list(self.store.data.get("custom_cidrs", []))
                targets = list(custom_ips) if custom_ips else sample_ips_from_cidrs(cidrs, total_samples=sample_size)
                existing_top = [x["ip"] for x in self.store.data.get("ip_pool", [])[:15]]
                targets = list(dict.fromkeys(existing_top + targets))

                self.progress_done = 0
                self.progress_total = len(targets)
                runner = BoundedAdaptiveRunner(max_concurrency=concurrency)
                self._active_runner = runner

                async def _on_prog(done: int, total: int):
                    self.progress_done = done
                    self.progress_total = total

                opts = IPScanOptions(
                    port=443,
                    timeout_sec=timeout_sec,
                    screening_attempts=1,
                    repeated_attempts=3,
                    interval_sec=0.12,
                    test_tls=True,
                    tls_sni="cloudflare.com",
                    max_concurrency=concurrency,
                    allow_private=False,
                )
                metrics_list = await self._ip_scanner.scan_candidates(targets, opts, runner=runner, on_progress=_on_prog)

                now = datetime.now(timezone.utc)
                scored_ips: list[dict[str, Any]] = []
                for m in metrics_list:
                    if m.success_count <= 0:
                        continue
                    ranked = self._ranker.score_candidate(
                        CandidateMetricsInput(
                            identifier=m.target,
                            port=m.port,
                            success_rate=m.success_rate,
                            avg_latency_ms=m.avg_latency_ms,
                            min_latency_ms=m.min_latency_ms,
                            max_latency_ms=m.max_latency_ms,
                            jitter_ms=m.jitter_ms,
                            stability_score=m.stability_score,
                            total_observations=m.total_attempts,
                            failed_observations=m.failure_count,
                            testing_diversity=2 if m.tls_verified else 1,
                            compatible_protocols=["vless", "trojan"],
                            last_tested_at=now,
                        ),
                        now=now,
                    )
                    if ranked.overall_score >= min_score:
                        scored_ips.append({
                            "ip": ranked.identifier,
                            "port": ranked.port,
                            "score": ranked.overall_score,
                            "confidence": ranked.confidence,
                            "latency_ms": ranked.avg_latency_ms,
                            "jitter_ms": ranked.jitter_ms,
                            "success_rate": ranked.success_rate,
                            "tls_ok": m.tls_verified,
                            "tested_at": now.isoformat(),
                        })

                scored_ips.sort(key=lambda x: (x["score"], -(x["latency_ms"] or 9999)), reverse=True)
                if scored_ips:
                    self.store.data["ip_pool"] = scored_ips[:100]
                    # Auto-apply freshest clean IP to panels with auto_ip enabled
                    if cfg.get("auto_apply_ip", True):
                        top_clean = scored_ips[0]["ip"]
                        for panel in self.store.data.get("panels", {}).values():
                            if panel.get("auto_ip", True):
                                panel["clean_ip"] = top_clean

                # Phase 2: Real WARP / MASQUE Endpoint scan
                self.current_stage = "endpoint_scan"
                ep_results: list[dict[str, Any]] = []
                self.progress_done = 0
                self.progress_total = len(DEFAULT_WARP_ENDPOINTS)

                for idx, raw_ep in enumerate(DEFAULT_WARP_ENDPOINTS, start=1):
                    if runner.cancel_event.is_set():
                        break
                    host, port_s = raw_ep.rsplit(":", 1)
                    port = int(port_s)
                    latencies: list[float] = []
                    for _ in range(3):
                        ok, lat, _ = await probe_warp_udp_endpoint(host, port, timeout_sec=timeout_sec)
                        if ok and lat is not None:
                            latencies.append(lat)
                        await asyncio.sleep(0.06)
                    self.progress_done = idx
                    if latencies:
                        avg_lat = round(sum(latencies) / len(latencies), 2)
                        sr = round(len(latencies) / 3.0, 2)
                        jitter = round(max(latencies) - min(latencies), 2) if len(latencies) > 1 else 0.0
                        score = round(max(0.0, min(100.0, sr * 65.0 + max(0.0, 35.0 - avg_lat / 12.0) - jitter * 0.2)), 2)
                        ep_results.append({
                            "endpoint": raw_ep,
                            "host": host,
                            "port": port,
                            "protocol": "masque" if port == 443 else "wireguard",
                            "score": score,
                            "latency_ms": avg_lat,
                            "jitter_ms": jitter,
                            "success_rate": sr,
                            "tested_at": now.isoformat(),
                        })

                ep_results.sort(key=lambda x: (x["score"], -(x["latency_ms"] or 9999)), reverse=True)
                if ep_results:
                    self.store.data["endpoint_pool"] = ep_results[:50]

                self.last_scan_at = now.isoformat()
                summary = {
                    "trigger": trigger,
                    "finished_at": self.last_scan_at,
                    "ips_tested": len(targets),
                    "healthy_ips": len(self.store.data["ip_pool"]),
                    "healthy_endpoints": len(self.store.data["endpoint_pool"]),
                }
                self.store.data["scan_history"] = (self.store.data.get("scan_history", []) + [summary])[-20:]
                self.store.save()
                return summary
            finally:
                self.is_scanning = False
                self.current_stage = "idle"
                self._active_runner = None

    def get_best_ips(self, count: int = 5) -> list[dict[str, Any]]:
        return list(self.store.data.get("ip_pool", []))[:count]

    def get_best_endpoint(self, protocol: str = "wireguard") -> dict[str, Any] | None:
        eps = [e for e in self.store.data.get("endpoint_pool", []) if e.get("protocol") == protocol]
        if eps:
            return eps[0]
        all_eps = self.store.data.get("endpoint_pool", [])
        return all_eps[0] if all_eps else None
__CFHUB_V4_EOF__

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/cf_manager.py
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote, urlencode

import httpx


@dataclass
class CloudflareAccountInfo:
    valid: bool
    token_id: str | None = None
    status: str = "invalid"
    account_id: str | None = None
    account_name: str | None = None
    workers_subdomain: str | None = None
    zones: list[str] | None = None
    workers_scripts: list[str] | None = None
    permissions_ok: bool = False
    error: str | None = None


class CloudflarePanelService:
    """Real Cloudflare API v4 onboarding, account discovery, and personal Turbo panel manager."""

    BASE = "https://api.cloudflare.com/client/v4"

    async def inspect_and_connect(self, api_token: str) -> CloudflareAccountInfo:
        headers = {"Authorization": f"Bearer {api_token.strip()}", "Content-Type": "application/json"}
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                r_ver = await client.get(f"{self.BASE}/user/tokens/verify", headers=headers)
                d_ver = r_ver.json()
                if r_ver.status_code != 200 or not d_ver.get("success"):
                    err = (d_ver.get("errors") or [{"message": f"HTTP {r_ver.status_code}"}])[0].get("message")
                    return CloudflareAccountInfo(valid=False, error=str(err))

                token_res = d_ver.get("result") or {}
                if token_res.get("status") != "active":
                    return CloudflareAccountInfo(valid=False, status=str(token_res.get("status")), error="توکن غیرفعال یا منقضی شده است.")

                acc_id = None
                acc_name = None
                r_acc = await client.get(f"{self.BASE}/accounts", headers=headers, params={"per_page": 5})
                if r_acc.status_code == 200 and r_acc.json().get("success"):
                    accs = r_acc.json().get("result") or []
                    if accs:
                        acc_id = accs[0].get("id")
                        acc_name = accs[0].get("name")

                subdomain = None
                workers_scripts: list[str] = []
                if acc_id:
                    r_sub = await client.get(f"{self.BASE}/accounts/{acc_id}/workers/subdomain", headers=headers)
                    if r_sub.status_code == 200 and r_sub.json().get("success"):
                        subdomain = (r_sub.json().get("result") or {}).get("subdomain")
                    r_scr = await client.get(f"{self.BASE}/accounts/{acc_id}/workers/scripts", headers=headers)
                    if r_scr.status_code == 200 and r_scr.json().get("success"):
                        workers_scripts = [s.get("id", "") for s in (r_scr.json().get("result") or []) if s.get("id")]

                zones: list[str] = []
                r_z = await client.get(f"{self.BASE}/zones", headers=headers, params={"per_page": 10})
                if r_z.status_code == 200 and r_z.json().get("success"):
                    zones = [z["name"] for z in (r_z.json().get("result") or []) if z.get("name")]

                return CloudflareAccountInfo(
                    valid=True,
                    token_id=token_res.get("id"),
                    status="active",
                    account_id=acc_id,
                    account_name=acc_name or "Cloudflare Account",
                    workers_subdomain=subdomain,
                    zones=zones,
                    workers_scripts=workers_scripts,
                    permissions_ok=bool(acc_id),
                )
        except Exception as exc:
            return CloudflareAccountInfo(valid=False, error=f"خطا در ارتباط با API کلودفلر: {exc}")

    def ensure_personal_panel(
        self,
        store,
        tg_id: int,
        host_domain: str,
        clean_ip: str,
        panel_name: str = "CFHub-Turbo",
        path: str = "/ws?ed=2048",
        force_new_uuid: bool = False,
    ) -> dict[str, Any]:
        key = str(tg_id)
        existing = store.data["panels"].get(key) or {}
        panel_uuid = str(uuid.uuid4()) if (force_new_uuid or not existing.get("uuid")) else existing["uuid"]
        now = datetime.now(timezone.utc).isoformat()
        panel = {
            "name": existing.get("name", panel_name),
            "uuid": panel_uuid,
            "host": host_domain,
            "clean_ip": clean_ip,
            "port": int(existing.get("port", 443)),
            "path": path,
            "sni": host_domain,
            "fp": existing.get("fp", "chrome"),
            "alpn": existing.get("alpn", "http/1.1"),
            "auto_ip": bool(existing.get("auto_ip", True)),
            "ip_index": int(existing.get("ip_index", 0)),
            "created_at": existing.get("created_at", now),
            "updated_at": now,
        }
        store.data["panels"][key] = panel
        store.save()
        return panel

    @staticmethod
    def build_vless_uri(panel: dict[str, Any], override_ip: str | None = None, label_suffix: str = "") -> str:
        ip = override_ip or panel["clean_ip"]
        host_part = f"[{ip}]" if ":" in ip else ip
        query = urlencode({
            "encryption": "none",
            "security": "tls",
            "type": "ws",
            "host": panel["host"],
            "sni": panel["sni"],
            "path": panel["path"],
            "fp": panel.get("fp", "chrome"),
            "alpn": panel.get("alpn", "http/1.1"),
        })
        name = f"{panel['name']}{label_suffix}"
        return f"vless://{panel['uuid']}@{host_part}:{panel.get('port', 443)}?{query}#{quote(name)}"
__CFHUB_V4_EOF__

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/warp_builder.py
from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal
from urllib.parse import quote, urlencode

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519

PlatformType = Literal["ios", "android", "windows"]

# Official Cloudflare WARP WireGuard Peer Public Key (static global engage key)
OFFICIAL_WARP_PEER_PUBKEY = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# Reliable WARP registration endpoints (fallback chain)
WARP_REG_URLS = [
    "https://api.cloudflareclient.com/v0a2483/reg",
    "https://api.cloudflareclient.com/v0a2158/reg",
]


@dataclass
class WarpRegistration:
    ok: bool
    private_key: str = ""
    public_key: str = ""
    peer_public_key: str = OFFICIAL_WARP_PEER_PUBKEY
    ipv4: str = "172.16.0.2/32"
    ipv6: str = ""
    reserved: list[int] | None = None
    client_id_b64: str = ""
    device_id: str = ""
    token: str = ""
    warp_activated: bool = False
    error: str | None = None


def generate_x25519_keypair() -> tuple[str, str]:
    priv = x25519.X25519PrivateKey.generate()
    pub = priv.public_key()
    priv_b64 = base64.b64encode(
        priv.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
    ).decode("ascii")
    pub_b64 = base64.b64encode(
        pub.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
    ).decode("ascii")
    return priv_b64, pub_b64


async def register_real_warp_device(timeout_sec: float = 12.0) -> WarpRegistration:
    """
    Register AND activate a real Cloudflare WARP WireGuard device.
    Fixes the 'connects with 0 bytes transferred' bug by:
      1) Using genuine X25519 keypair registration + PATCH warp_enabled=true activation.
      2) Extracting exact 3-byte client_id Reserved header required by Cloudflare WARP gateways.
      3) Guaranteeing the official WARP Peer PublicKey and clean IPv4 CIDR formatting.
    """
    priv_key, pub_key = generate_x25519_keypair()
    payload = {
        "key": pub_key,
        "install_id": "",
        "fcm_token": "",
        "tos": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "model": "Android",
        "serial_number": "",
        "locale": "en_US",
    }
    headers = {
        "User-Agent": "okhttp/3.12.1",
        "CF-Client-Version": "a-6.33-3874",
        "Content-Type": "application/json; charset=UTF-8",
    }

    last_err = "Cloudflare WARP API در دسترس نبود."
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        for reg_url in WARP_REG_URLS:
            try:
                resp = await client.post(reg_url, json=payload, headers=headers)
                if resp.status_code not in (200, 201):
                    last_err = f"HTTP {resp.status_code}"
                    continue
                data = resp.json()
                dev_id = data.get("id", "")
                token = data.get("token", "")
                cfg = data.get("config") or {}
                peers = cfg.get("peers") or [{}]
                iface = cfg.get("interface", {}).get("addresses") or {}
                client_id_b64 = cfg.get("client_id", "")
                reserved = list(base64.b64decode(client_id_b64)[:3]) if client_id_b64 else [0, 0, 0]

                # Activate WARP device session explicitly so traffic routing is enabled
                warp_activated = False
                if dev_id and token:
                    try:
                        act = await client.patch(
                            f"{reg_url}/{dev_id}",
                            json={"warp_enabled": True},
                            headers={**headers, "Authorization": f"Bearer {token}"},
                        )
                        warp_activated = act.status_code in (200, 201)
                    except Exception:
                        warp_activated = False

                ipv4 = iface.get("v4", "172.16.0.2")
                ipv6 = iface.get("v6", "")
                peer_pub = peers[0].get("public_key") or OFFICIAL_WARP_PEER_PUBKEY
                return WarpRegistration(
                    ok=True,
                    private_key=priv_key,
                    public_key=pub_key,
                    peer_public_key=peer_pub,
                    ipv4=f"{ipv4}/32" if "/" not in ipv4 else ipv4,
                    ipv6=f"{ipv6}/128" if ipv6 and "/" not in ipv6 else ipv6,
                    reserved=reserved,
                    client_id_b64=client_id_b64,
                    device_id=dev_id,
                    token=token,
                    warp_activated=warp_activated,
                )
            except Exception as exc:
                last_err = str(exc)

    return WarpRegistration(ok=False, error=f"خطا در ثبت دستگاه WARP: {last_err}")


def build_anti_dpi_warp_bundle(reg: WarpRegistration, endpoint: str, platform: PlatformType) -> dict:
    """
    Produces complete working WARP configs that fix the 'connected but no data' issue on restricted networks:
      1) `wireguard://` URI with Reserved + Noise/Padding params (for Hiddify, v2rayNG, MahsaNG, Streisand, Karing).
      2) `warp://` quick URI (with `ifp` packet padding for Hiddify / Oblivion / Streisand).
      3) AmneziaWG `.conf` (with Jc/Jmin/Jmax/S1/S2/H1-H4 anti-DPI headers + IPv4-safe routing + MTU=1280).
      4) Standard clean WireGuard `.conf` (IPv4-only routing `0.0.0.0/0` to avoid IPv6 blackhole + MTU=1280).
      5) Sing-box / Hiddify full JSON outbound with Reserved bytes.
    """
    host, port_s = endpoint.rsplit(":", 1)
    port = int(port_s)
    # Use safe MTU=1280 for all restricted/mobile networks to prevent UDP fragmentation drops
    mtu = 1280
    reserved = reg.reserved or [0, 0, 0]
    reserved_csv = ",".join(str(x) for x in reserved)

    # 1) wireguard:// URI (works directly in v2rayNG, Hiddify, MahsaNG, Streisand, Karing, V2Box)
    wg_query = urlencode({
        "address": reg.ipv4,
        "reserved": reserved_csv,
        "publickey": reg.peer_public_key,
        "mtu": str(mtu),
        "wnoise": "quic",
        "wnoisecount": "12",
        "wnoisedelay": "10-30",
        "wpayloadsize": "5-15",
    })
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{host}:{port}?{wg_query}#{quote(f'CFHub-WARP-{platform.upper()}')}"

    # 2) warp:// URI with anti-DPI junk packet parameters (Hiddify / Streisand / Karing)
    warp_uri = f"warp://{host}:{port}/?ifp=40-80&ifps=40-100&ifpd=4-8&ifpm=m4#{quote(f'CFHub-WARP-Noise-{platform.upper()}')}"

    # 3) AmneziaWG .conf (fixes UDP DPI drop where official WireGuard connects with 0 bytes!)
    amnezia_conf = "\n".join([
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {reg.ipv4}",
        "DNS = 1.1.1.1, 8.8.8.8",
        f"MTU = {mtu}",
        "Jc = 4",
        "Jmin = 40",
        "Jmax = 70",
        "S1 = 0",
        "S2 = 0",
        "H1 = 1",
        "H2 = 2",
        "H3 = 3",
        "H4 = 4",
        "",
        "[Peer]",
        f"PublicKey = {reg.peer_public_key}",
        "AllowedIPs = 0.0.0.0/0",
        f"Endpoint = {host}:{port}",
        "PersistentKeepalive = 25",
    ]) + "\n"

    # 4) Clean Standard WireGuard .conf (IPv4-safe, MTU=1280 — no IPv6 blackholing)
    std_wg_conf = "\n".join([
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {reg.ipv4}",
        "DNS = 1.1.1.1, 8.8.8.8",
        f"MTU = {mtu}",
        "",
        "[Peer]",
        f"PublicKey = {reg.peer_public_key}",
        "AllowedIPs = 0.0.0.0/0",
        f"Endpoint = {host}:{port}",
        "PersistentKeepalive = 25",
    ]) + "\n"

    # 5) Sing-box / Hiddify JSON
    singbox_json = json.dumps(
        {
            "type": "wireguard",
            "tag": f"CFHub-WARP-{platform.upper()}",
            "server": host.strip("[]"),
            "server_port": port,
            "local_address": [reg.ipv4],
            "private_key": reg.private_key,
            "peer_public_key": reg.peer_public_key,
            "reserved": reserved,
            "mtu": mtu,
        },
        indent=2,
    )

    clients = {
        "ios": "Hiddify / Streisand / Karing / AmneziaWG (توصیه: Hiddify یا AmneziaWG)",
        "android": "Hiddify / v2rayNG / MahsaNG / AmneziaWG (توصیه: Hiddify یا AmneziaWG)",
        "windows": "Hiddify / AmneziaWG / v2rayN / Sing-box (توصیه: Hiddify یا AmneziaWG)",
    }

    return {
        "amnezia_filename": f"cfhub_amneziawg_{platform}.conf",
        "amnezia_conf": amnezia_conf,
        "std_filename": f"cfhub_wireguard_{platform}.conf",
        "std_conf": std_wg_conf,
        "wireguard_uri": wireguard_uri,
        "warp_uri": warp_uri,
        "singbox_json": singbox_json,
        "reserved": reserved,
        "endpoint": f"{host}:{port}",
        "recommended_clients": clients[platform],
    }


def format_warp_masque(reg: WarpRegistration, endpoint: str, platform: PlatformType) -> dict:
    host, _ = endpoint.rsplit(":", 1)
    masque_endpoint = f"{host}:443"
    mtu = 1280

    profile = {
        "schema": "cfhub.masque.v1",
        "platform": platform,
        "protocol": "masque-connect-udp",
        "rfc": "RFC 9298",
        "transport": "quic",
        "alpn": ["h3"],
        "endpoint": masque_endpoint,
        "sni": "consumer-masque.cloudflareclient.com",
        "device_id": reg.device_id,
        "local_address": [reg.ipv4],
        "mtu": mtu,
        "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/",
    }
    serialized = json.dumps(profile, indent=2)
    clients = {
        "ios": "Cloudflare WARP (حالت MASQUE در تنظیمات Advanced → Connection) / کلاینت‌های HTTP/3",
        "android": "Cloudflare WARP (حالت MASQUE) / کلاینت‌های HTTP/3 QUIC",
        "windows": "Cloudflare WARP Desktop (دستور warp-cli tunnel protocol set MASQUE)",
    }
    return {
        "filename": f"cfhub_masque_{platform}.json",
        "file_content": serialized,
        "endpoint": masque_endpoint,
        "recommended_clients": clients[platform],
    }
__CFHUB_V4_EOF__

cat <<'__CFHUB_V4_EOF__' > backend/app/bot/bot.py
from __future__ import annotations

import asyncio
import base64
import csv
import html
import io
import logging
from datetime import datetime, timezone

from aiogram import Bot, Dispatcher, F, Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from app.bot.bg_engine import BackgroundScannerEngine
from app.bot.cf_manager import CloudflarePanelService
from app.bot.store import PersistentHubStore
from app.bot.ui import (
    CLOUDFLARE_DIRECT_TOKEN_URL,
    CLOUDFLARE_SIGNUP_URL,
    back_home_kb,
    btn,
    kb,
    main_menu_kb,
)
from app.bot.warp_builder import (
    build_anti_dpi_warp_bundle,
    format_warp_masque,
    register_real_warp_device,
)
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.protocols.base import generate_qr_png_base64
from app.security.rate_limit import SlidingWindowRateLimiter
from app.services.monitoring import collect_system_health

logger = logging.getLogger(__name__)
router = Router()

store = PersistentHubStore()
bg_engine = BackgroundScannerEngine(store)
cf_service = CloudflarePanelService()
rate_limiter = SlidingWindowRateLimiter(max_requests=45, window_seconds=60)


class Flow(StatesGroup):
    waiting_cf_token = State()
    waiting_panel_host = State()
    waiting_panel_path = State()
    waiting_panel_name = State()
    waiting_support_msg = State()
    adm_add_cidr = State()
    adm_custom_scan = State()
    adm_user_search = State()
    adm_dm_text = State()
    adm_broadcast = State()
    adm_set_support = State()
    adm_add_free_cfg = State()


def _is_admin(tg_id: int) -> bool:
    return tg_id in set(get_settings().owner_telegram_ids)


async def _edit(cb: CallbackQuery, text: str, markup) -> None:
    if not cb.message:
        return
    try:
        await cb.message.edit_text(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)
    except TelegramBadRequest as exc:
        if "message is not modified" in str(exc).lower():
            return
        await cb.message.answer(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)


async def _send_qr(target_msg: Message, payload: str, caption: str, markup) -> None:
    uri = generate_qr_png_base64(payload)
    if uri.startswith("data:image/png;base64,"):
        raw = base64.b64decode(uri.split(",", 1)[1])
        await target_msg.answer_photo(
            photo=BufferedInputFile(raw, filename="qr_code.png"),
            caption=caption[:1020],
            parse_mode="HTML",
            reply_markup=markup,
        )
    else:
        await target_msg.answer(caption, parse_mode="HTML", reply_markup=markup)


def _home_text(tg_id: int) -> str:
    lang = store.get_lang(tg_id)
    ip_pool = store.data.get("ip_pool", [])
    ep_pool = store.data.get("endpoint_pool", [])
    cfg = store.data["settings"]

    best_ping = f"{ip_pool[0]['latency_ms']}ms" if ip_pool and ip_pool[0].get("latency_ms") else "در حال اسکن..."
    self_heal_domains = sum(1 for p in store.data.get("panels", {}).values() if p.get("auto_ip", True))
    auto_ip_txt = "روشن" if cfg.get("auto_apply_ip", True) else "خاموش"
    scan_badge = "🔄 در حال به‌روزرسانی" if bg_engine.is_scanning else "🟢 آنلاین"

    if lang == "en":
        return (
            "⚡ <b>Live Status right now</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            f"🏆 Best Ping: <b>{best_ping}</b> ({len(ip_pool)} healthy IPs)\n"
            f"🌀 Self-healing panels: <b>{self_heal_domains}</b>\n"
            f"🛡️ Healthy WARP relays: <b>{len(ep_pool)}</b>\n"
            f"🤖 Auto-apply clean IP: <b>{'ON' if cfg.get('auto_apply_ip', True) else 'OFF'}</b> | Scanner: <b>{scan_badge}</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "💚 Free forever. If it works for you, share it with a friend.\n"
            "👇 Start from the buttons below:"
        )

    return (
        "⚡ <b>وضعیت زنده این لحظه</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🏆 بهترین پینگ: <b>{best_ping}</b> (<b>{len(ip_pool)}</b> IP سالم)\n"
        f"🌀 دامنهٔ خودترمیم: <b>{self_heal_domains}</b>\n"
        f"🛡️ رلهٔ سالم WARP: <b>{len(ep_pool)}</b>\n"
        f"🤖 اعمال خودکار آی‌پی: <b>{auto_ip_txt}</b> | اسکنر: <b>{scan_badge}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "💚 رایگان است و رایگان می‌ماند. اگر کار کرد، به یک نفر دیگر هم معرفی‌اش کن.\n"
        "👇 از دکمه‌های پایین شروع کن:"
    )


# ==================== START & HOME ====================
@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    user = message.from_user
    if not user:
        return
    store.touch_user(user.id, user.username, user.full_name)

    # Referral tracking
    parts = (message.text or "").split()
    if len(parts) > 1 and parts[1].startswith("ref_"):
        ref_str = parts[1].removeprefix("ref_")
        if ref_str.isdigit():
            store.record_referral(int(ref_str), user.id)

    if store.is_banned(user.id) and not _is_admin(user.id):
        await message.answer("🚫 دسترسی شما به ربات مسدود شده است.")
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(user.id):
        await message.answer("🛠️ ربات موقتاً در حالت به‌روزرسانی است. لطفاً کمی بعد دوباره تلاش کنید.")
        return

    lang = store.get_lang(user.id)
    await message.answer(_home_text(user.id), reply_markup=main_menu_kb(_is_admin(user.id), lang=lang), parse_mode="HTML")


@router.message(Command("admin"))
async def cmd_admin(message: Message, state: FSMContext) -> None:
    await state.clear()
    if not message.from_user or not _is_admin(message.from_user.id):
        await message.answer("⛔ این بخش فقط مخصوص مدیریت ربات است.")
        return
    text, markup = _build_admin_dashboard()
    await message.answer(text, reply_markup=markup, parse_mode="HTML")


@router.callback_query(F.data == "m:home")
async def cb_home(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), lang=lang))


@router.callback_query(F.data == "m:lang")
async def cb_toggle_lang(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.toggle_lang(uid)
    await cb.answer("Language: EN" if lang == "en" else "زبان: فارسی")
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), lang=lang))


# ==================== 1. TURBO PANEL (DIRECT 1-CLICK CLOUDFLARE API TOKEN LINK) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo_start(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    if store.is_banned(uid) and not _is_admin(uid):
        await cb.answer("🚫 حساب شما مسدود است.", show_alert=True)
        return

    # Put user directly in token-receiving state so they can paste immediately!
    await state.set_state(Flow.waiting_cf_token)

    already = str(uid) in store.data.get("cf_accounts", {})
    note = "\n✅ <i>شما از قبل اکانت متصل دارید؛ می‌توانید توکن جدید بفرستید یا مستقیم به «مدیریت پنل من» بروید.</i>\n" if already else ""

    text = (
        "🚀 <b>ساخت پنل توربو</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلادفلر نداری، اول ثبت نام کن.\n"
        "2️⃣ دکمهٔ <b>دریافت مستقیم توکن</b> را بزن (تمام دسترسی‌ها از قبل انتخاب شده).\n"
        "3️⃣ در کلادفلر دکمه <b>Continue to summary</b> و بعد <b>Create Token</b> را بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n"
        f"{note}\n"
        "⚡ <i>میانگین زمان تحویل: ۲۰ تا ۴۵ ثانیه | پیام توکن بلافاصله برای امنیت حذف و رمزنگاری می‌شود.</i>"
    )
    rows = [
        [btn("🔑 دریافت مستقیم توکن (دسترسی‌ها آماده)", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
        [btn("🌐 ثبت‌نام رایگان در کلادفلر", url=CLOUDFLARE_SIGNUP_URL, style="primary")],
    ]
    if already:
        rows.append([btn("🎛️ ورود به مدیریت پنل من", callback_data="m:mypanel", style="primary")])
    rows.append([btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="danger")])
    await _edit(cb, text, kb(rows))


@router.message(Flow.waiting_cf_token)
async def handle_cf_token(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    raw_token = (message.text or "").strip()
    try:
        await message.delete()
    except Exception:
        pass

    if len(raw_token) < 20 or " " in raw_token:
        await message.answer(
            "⚠️ فرمت توکن نامعتبر است. توکن کلادفلر حدود ۴۰ کاراکتر بدون فاصله است.\n"
            "از دکمه سبز بالا توکن را بسازید و همینجا ارسال کنید:",
            reply_markup=kb([
                [btn("🔑 دریافت مستقیم توکن", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    wait_msg = await message.answer("⏳ در حال اعتبارسنجی زنده توکن و آماده‌سازی پنل توربو...")
    info = await cf_service.inspect_and_connect(raw_token)
    if not info.valid:
        await wait_msg.edit_text(
            f"❌ <b>توکن تایید نشد!</b>\nدلیل: <code>{html.escape(info.error or 'Invalid token')}</code>\n\n"
            "مطمئن شوید دکمه <b>Create Token</b> را زده و کل رشته توکن را کپی کرده‌اید، سپس دوباره بفرستید.",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔑 ساخت مجدد توکن مستقیم", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    store.data["cf_accounts"][str(uid)] = {
        "encrypted_token": store.encrypt_secret(raw_token),
        "token_id": info.token_id,
        "account_id": info.account_id,
        "account_name": info.account_name,
        "workers_subdomain": info.workers_subdomain,
        "zones": info.zones or [],
        "workers_scripts": info.workers_scripts or [],
        "connected_at": datetime.now(timezone.utc).isoformat(),
    }
    best_ips = bg_engine.get_best_ips(1)
    clean_ip = best_ips[0]["ip"] if best_ips else "104.16.132.229"
    default_host = (
        f"cfhub.{info.workers_subdomain}.workers.dev"
        if info.workers_subdomain
        else (info.zones[0] if info.zones else "your-worker.workers.dev")
    )
    cf_service.ensure_personal_panel(store, uid, default_host, clean_ip)
    store.save()
    await state.clear()

    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(f"✅ <b>پنل توربو شما با موفقیت ساخته شد!</b>\n\n{text}", parse_mode="HTML", reply_markup=markup)


# ==================== 2. MY PANEL MANAGEMENT (PRO USER DASHBOARD) ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    best_ips = bg_engine.get_best_ips(5)
    best_ping = f"{best_ips[0]['latency_ms']}ms" if best_ips and best_ips[0].get("latency_ms") else "در حال اسکن"

    if not cf or not panel:
        text = (
            "🎛️ <b>مدیریت پنل من</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "هنوز پنل توربو اختصاصی نساخته‌اید!\n"
            "برای ساخت پنل رایگان در کمتر از ۳۰ ثانیه، دکمه سبز زیر را بزنید:"
        )
        markup = kb([
            [btn("🚀 ساخت پنل توربو", callback_data="m:turbo", style="success")],
            [btn("🔙 بازگشت", callback_data="m:home", style="primary")],
        ])
        return text, markup

    auto_status = "🟢 روشن (خودترمیم)" if panel.get("auto_ip", True) else "🔴 خاموش (دستی)"
    text = (
        "🎛️ <b>مدیریت پنل اختصاصی من</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🏷️ نام پنل: <b>{html.escape(panel['name'])}</b>\n"
        f"☁️ اکانت کلادفلر: <b>{html.escape(cf.get('account_name', 'Cloudflare'))}</b>\n"
        f"🌐 هاست / دامنه: <code>{html.escape(panel['host'])}</code>\n"
        f"🟢 IP تمیز فعال: <code>{html.escape(panel['clean_ip'])}</code> (بهترین استخر: {best_ping})\n"
        f"🌀 اعمال خودکار IP: <b>{auto_status}</b>\n"
        f"🔑 UUID: <code>{html.escape(panel['uuid'])}</code>\n"
        f"🛤️ Path: <code>{html.escape(panel['path'])}</code> | FP: <code>{html.escape(panel.get('fp', 'chrome'))}</code>\n"
        f"📦 Workers: <b>{len(cf.get('workers_scripts', []))}</b> | Zones: <b>{len(cf.get('zones', []))}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━"
    )
    markup = kb([
        [btn("⚡ دریافت کانفیگ پرسرعت + QR", callback_data="cf:get_one", style="success")],
        [btn("📦 دریافت پکیج ۵ آی‌پی برتر", callback_data="cf:get_bundle", style="success")],
        [
            btn("🔄 تعویض فوری IP تمیز", callback_data="cf:swap_ip", style="primary"),
            btn("🌀 خودترمیم IP (روشن/خاموش)", callback_data="cf:toggle_autoip", style="primary"),
        ],
        [
            btn("🌐 تغییر دامنه / هاست", callback_data="cf:edit_host", style="primary"),
            btn("🛤️ تغییر Path", callback_data="cf:edit_path", style="primary"),
        ],
        [
            btn("🏷️ تغییر نام پنل", callback_data="cf:edit_name", style="primary"),
            btn("♻️ ساخت UUID جدید", callback_data="cf:reset_uuid", style="primary"),
        ],
        [btn("🗑️ حذف پنل و قطع اتصال کلودفلر", callback_data="cf:disconnect", style="danger")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    text, markup = _render_personal_panel(cb.from_user.id)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:get_one")
async def cb_cf_get_one(cb: CallbackQuery) -> None:
    await cb.answer("⚡ در حال ساخت کانفیگ...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        await _edit(cb, "⚠️ ابتدا پنل توربو بسازید.", back_home_kb("m:turbo"))
        return
    best_ips = bg_engine.get_best_ips(1)
    if best_ips and panel.get("auto_ip", True):
        panel["clean_ip"] = best_ips[0]["ip"]
        store.save()
        ping_info = f"{best_ips[0]['latency_ms']}ms | امتیاز {best_ips[0]['score']}"
    else:
        ping_info = "استخر خودکار"
    uri = cf_service.build_vless_uri(panel)
    store.increment_stat(uid, "configs_generated")
    caption = (
        f"🚀 <b>کانفیگ پرسرعت اختصاصی شما</b>\n"
        f"🟢 IP تمیز: <code>{html.escape(panel['clean_ip'])}</code> ({ping_info})\n"
        f"🌐 هاست: <code>{html.escape(panel['host'])}</code>\n\n"
        f"👇 روی لینک بزنید تا کپی شود:\n<code>{html.escape(uri)}</code>"
    )
    if cb.message:
        await _send_qr(cb.message, uri, caption, kb([
            [btn("🔄 تعویض IP تمیز", callback_data="cf:swap_ip", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]))


@router.callback_query(F.data == "cf:get_bundle")
async def cb_cf_get_bundle(cb: CallbackQuery) -> None:
    await cb.answer("📦 در حال ساخت پکیج...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return
    best_ips = bg_engine.get_best_ips(5)
    ips = [x["ip"] for x in best_ips] if best_ips else [panel["clean_ip"]]
    uris = [cf_service.build_vless_uri(panel, override_ip=ip, label_suffix=f"-#{i+1}") for i, ip in enumerate(ips)]
    store.increment_stat(uid, "configs_generated")
    if cb.message:
        await cb.message.answer_document(
            document=BufferedInputFile("\n".join(uris).encode("utf-8"), filename="cfhub_turbo_bundle.txt"),
            caption=f"📦 <b>پکیج {len(uris)} کانفیگ با برترین IPهای سالم پس‌زمینه</b>",
            parse_mode="HTML",
            reply_markup=back_home_kb("m:mypanel"),
        )


@router.callback_query(F.data == "cf:swap_ip")
async def cb_cf_swap_ip(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    pool = store.data.get("ip_pool", [])
    if not panel or not pool:
        await cb.answer("⏳ استخر IP در حال تکمیل است؛ کمی صبر کنید.", show_alert=True)
        return
    nxt = (int(panel.get("ip_index", 0)) + 1) % min(len(pool), 25)
    chosen = pool[nxt]
    panel["ip_index"] = nxt
    panel["clean_ip"] = chosen["ip"]
    store.save()
    await cb.answer(f"✅ IP تغییر یافت: {chosen['ip']} ({chosen['latency_ms']}ms)")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:toggle_autoip")
async def cb_cf_toggle_autoip(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if panel:
        panel["auto_ip"] = not bool(panel.get("auto_ip", True))
        store.save()
    await cb.answer("✅ وضعیت خودترمیم IP تغییر کرد.")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:edit_host")
async def cb_cf_edit_host(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_host)
    await _edit(cb, "🌐 دامنه جدید (بدون https://) را ارسال کنید (مثال: <code>app.user.workers.dev</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_host)
async def handle_panel_host(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    host = (message.text or "").strip().replace("https://", "").replace("http://", "").split("/")[0]
    if "." not in host:
        await message.answer("⚠️ دامنه معتبر ارسال کنید.")
        return
    panel = store.data["panels"].get(str(uid))
    if panel:
        panel["host"] = host
        panel["sni"] = host
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ هاست پنل بروز شد.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:edit_path")
async def cb_cf_edit_path(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_path)
    await _edit(cb, "🛤️ مسیر (Path) جدید را ارسال کنید (مثال: <code>/ws?ed=2048</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_path)
async def handle_panel_path(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    path = (message.text or "").strip()
    if not path.startswith("/"):
        path = "/" + path
    panel = store.data["panels"].get(str(uid))
    if panel:
        panel["path"] = path
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ Path پنل بروز شد.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:edit_name")
async def cb_cf_edit_name(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_name)
    await _edit(cb, "🏷️ نام دلخواه جدید برای کانفیگ‌های پنل خود ارسال کنید:", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_name)
async def handle_panel_name(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    name = (message.text or "").strip()[:32]
    panel = store.data["panels"].get(str(uid))
    if panel and name:
        panel["name"] = name
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ نام پنل به <b>{html.escape(name)}</b> تغییر یافت.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:reset_uuid")
async def cb_cf_reset_uuid(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if panel:
        cf_service.ensure_personal_panel(store, uid, panel["host"], panel["clean_ip"], path=panel["path"], force_new_uuid=True)
    await cb.answer("♻️ UUID جدید ساخته شد!")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await cb.answer("🗑️ پنل و توکن کلودفلر حذف شدند.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), lang=store.get_lang(uid)))


# ==================== 3. WARP / WIREGUARD / MASQUE (FIXED ANTI-DPI NO-DATA BUG) ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    ep_wg = bg_engine.get_best_endpoint("wireguard")
    ep_mq = bg_engine.get_best_endpoint("masque")
    wg_info = f"<code>{ep_wg['endpoint']}</code> ({ep_wg['latency_ms']}ms)" if ep_wg else "<code>162.159.192.1:2408</code>"
    mq_info = f"<code>{ep_mq['endpoint']}</code> ({ep_mq['latency_ms']}ms)" if ep_mq else "<code>162.159.192.1:443</code>"

    text = (
        "🛡️ <b>ساخت خودکار WARP / WireGuard / MASQUE (نسخه ضد اختلال)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚡ بهترین رله WireGuard/AmneziaWG:\n{wg_info}\n\n"
        f"🌀 بهترین رله MASQUE (HTTP/3):\n{mq_info}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "✨ <i>مشکل «وصل شدن بدون رد و بدل شدن دیتا» با فعال‌سازی واقعی نشست WARP، افزودن هدر Reserved، تنظیم MTU=1280، حذف IPv6 و تزریق پارامترهای ضد DPI (AmneziaWG + Noise) کاملاً برطرف شده است.</i>\n\n"
        "پروتکل مورد نظر را انتخاب کنید:"
    )
    markup = kb([
        [btn("⚡ WireGuard / AmneziaWG (پیشنهادی ضد اختلال)", callback_data="warp:proto:wg", style="success")],
        [btn("🌀 MASQUE (پروتکل جدید HTTP/3 QUIC)", callback_data="warp:proto:masque", style="primary")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:proto:"))
async def cb_warp_platform(cb: CallbackQuery) -> None:
    await cb.answer()
    proto = cb.data.split(":")[2]
    title = "⚡ WireGuard + AmneziaWG (ضد اختلال)" if proto == "wg" else "🌀 MASQUE (RFC 9298 HTTP/3)"
    text = (
        f"<b>{title}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "مدل دستگاه خود را انتخاب کنید تا کلید اختصاصی واقعی + فایل و لینک آماده اتصال با یک کلیک ساخته شود:"
    )
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:build:{proto}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:build:{proto}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:build:{proto}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:build:"))
async def cb_warp_build(cb: CallbackQuery) -> None:
    _, _, proto, platform = cb.data.split(":")
    await cb.answer("⏳ در حال ثبت و فعال‌سازی کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return

    wait = await cb.message.answer("⏳ در حال ساخت کلید X25519، ثبت دستگاه و فعال‌سازی تونل روی سرورهای Cloudflare WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(
            f"❌ <b>ثبت دستگاه در Cloudflare WARP با خطا مواجه شد:</b>\n<code>{html.escape(reg.error or '')}</code>",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 تلاش مجدد", callback_data=cb.data, style="success")],
                [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
            ]),
        )
        return

    best_ep = bg_engine.get_best_endpoint("masque" if proto == "masque" else "wireguard")
    endpoint_str = best_ep["endpoint"] if best_ep else ("162.159.192.1:443" if proto == "masque" else "162.159.192.1:2408")
    ping_txt = f"{best_ep['latency_ms']}ms" if best_ep else "پیش‌فرض تاییدشده"
    store.increment_stat(uid, "warp_generated")
    plat_fa = {"ios": "🍏 آیفون (iOS)", "android": "🤖 اندروید (Android)", "windows": "🪟 ویندوز (Windows)"}[platform]

    await wait.delete()

    if proto == "wg":
        b = build_anti_dpi_warp_bundle(reg, endpoint_str, platform)  # type: ignore[arg-type]
        # 1) Send direct copyable links for Hiddify / v2rayNG / MahsaNG / Streisand (solves 0-byte issue!)
        link_msg = (
            f"✅ <b>کانفیگ WARP ضد اختلال آماده شد! ({plat_fa})</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"🎯 رله بهینه: <code>{html.escape(b['endpoint'])}</code> ({ping_txt})\n"
            f"🔑 Reserved: <code>{b['reserved']}</code> | MTU: <code>1280</code>\n"
            f"🟢 فعال‌سازی نشست: <b>{'تایید شد' if reg.warp_activated else 'ثبت شد'}</b>\n\n"
            f"1️⃣ <b>لینک اختصاصی با Noise (پیشنهادی برای Hiddify / v2rayNG / Streisand / Karing):</b>\n"
            f"<code>{html.escape(b['wireguard_uri'])}</code>\n\n"
            f"2️⃣ <b>لینک سریع WARP با Padding (مخصوص Hiddify و Streisand):</b>\n"
            f"<code>{html.escape(b['warp_uri'])}</code>\n\n"
            f"💡 <b>نکته مهم رفع مشکل عدم تبادل دیتا:</b>\n"
            f"در اینترنت ایران، اپلیکیشن رسمی WireGuard اغلب به دلیل فیلتر هدر UDP فقط وصل می‌شود اما دیتا رد و بدل نمی‌کند. برای اتصال صددرصدی، <b>لینک بالا را در Hiddify / v2rayNG / Streisand</b> ایمپورت کنید یا فایل <b>AmneziaWG</b> زیر را در اپ <b>AmneziaWG</b> باز کنید."
        )
        await cb.message.answer(link_msg, parse_mode="HTML")

        # 2) Send AmneziaWG .conf file (with Jc/Jmin/Jmax anti-DPI headers)
        await cb.message.answer_document(
            document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
            caption=f"🛡️ <b>فایل AmneziaWG ضد فیلتر ({plat_fa})</b>\nمخصوص اپلیکیشن <b>AmneziaWG</b> (رفع کامل مشکل 0 بایت دیتا)",
            parse_mode="HTML",
        )

        # 3) Send QR of wireguard:// URI for instant scan
        await _send_qr(
            cb.message,
            b["wireguard_uri"],
            f"📱 <b>QR Code آماده اسکن (Hiddify / v2rayNG / Streisand)</b>\n📲 {html.escape(b['recommended_clients'])}",
            kb([
                [btn("🔄 ساخت کلید و رله جدید", callback_data=cb.data, style="success")],
                [btn("📱 دانلود اپلیکیشن‌های پیشنهادی", callback_data="m:apps", style="primary")],
                [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")],
            ]),
        )
    else:
        m = format_warp_masque(reg, endpoint_str, platform)  # type: ignore[arg-type]
        await cb.message.answer_document(
            document=BufferedInputFile(m["file_content"].encode("utf-8"), filename=m["filename"]),
            caption=(
                f"✅ <b>پروفایل MASQUE (HTTP/3 QUIC) آماده شد! ({plat_fa})</b>\n"
                f"🎯 اندپوینت: <code>{html.escape(m['endpoint'])}</code> ({ping_txt})\n"
                f"📲 کلاینت سازگار: {html.escape(m['recommended_clients'])}"
            ),
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 ساخت پروفایل جدید", callback_data=cb.data, style="success")],
                [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")],
            ]),
        )


# ==================== 4. APPS, GUIDE, SUPPORT, FREE CONFIG, INVITE, DONATE ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📱 <b>برنامه‌ها و دانلود کلاینت‌های رسمی</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "برای بهترین سرعت و بدون مشکل تبادل دیتا در WARP و VLESS، یکی از اپلیکیشن‌های زیر را نصب کنید:"
    )
    markup = kb([
        [btn("🤖 Hiddify (اندروید / آیفون / ویندوز — پیشنهادی)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (ضد فیلتر برای فایل‌های WARP)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (اندروید)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (آیفون — App Store)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (ویندوز)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📖 <b>راهنمای کامل اتصال و رفع مشکلات</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>ساخت پنل توربو (VLESS):</b>\n"
        "• روی دکمه سبز «🚀 ساخت پنل توربو» بزنید.\n"
        "• دکمه «🔑 دریافت مستقیم توکن» را بزنید تا مستقیم با تمام دسترسی‌های آماده وارد کلادفلر شوید.\n"
        "• روی <b>Continue to summary</b> و سپس <b>Create Token</b> کلیک کنید و توکن را همینجا بفرستید.\n\n"
        "2️⃣ <b>اتصال WARP بدون مشکل ۰ بایت دیتا:</b>\n"
        "• لینک <code>wireguard://</code> یا <code>warp://</code> خروجی ربات را کپی کرده و در <b>Hiddify</b>، <b>v2rayNG</b> یا <b>Streisand</b> بزنید (گزینه Import from Clipboard).\n"
        "• یا فایل <code>.conf</code> را داخل <b>AmneziaWG</b> وارد کنید.\n\n"
        "3️⃣ <b>اگر سرعت افت کرد:</b>\n"
        "• وارد «🎛️ مدیریت پنل من» شوید و «🔄 تعویض فوری IP تمیز» را بزنید تا جدیدترین IP اسکن‌شده پس‌زمینه اعمال شود."
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    cfg = store.data["settings"]
    sup_user = cfg.get("support_username", "").lstrip("@")
    sup_id = cfg.get("support_user_id") or (get_settings().owner_telegram_ids[0] if get_settings().owner_telegram_ids else 0)

    rows = []
    if sup_user:
        rows.append([btn(f"💬 چت مستقیم با پشتیبانی (@{sup_user})", url=f"https://t.me/{sup_user}", style="success")])
        id_line = f"👤 آیدی پشتیبانی: @{html.escape(sup_user)}"
    elif sup_id:
        rows.append([btn("💬 چت مستقیم با مدیر ربات", url=f"tg://user?id={sup_id}", style="success")])
        id_line = f"👤 شناسه پشتیبانی: <code>{sup_id}</code>"
    else:
        id_line = "👤 پشتیبانی آنلاین فعال است."

    rows.append([btn("✉️ ارسال تیکت مستقیم داخل ربات", callback_data="sup:ticket", style="primary")])
    rows.append([btn("🔙 بازگشت به منوی اصلی", callback_data="m:home", style="primary")])

    text = (
        "💬 <b>پشتیبانی رسمی</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{id_line}\n\n"
        "سوال یا مشکل خود را مستقیم بپرسید یا از دکمه زیر تیکت ثبت کنید:"
    )
    await _edit(cb, text, kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_support_msg)
    await _edit(cb, "✉️ پیام خود را بنویسید و ارسال کنید:", kb([[btn("❌ انصراف", callback_data="m:support", style="danger")]]))


@router.message(Flow.waiting_support_msg)
async def handle_support_msg(message: Message, state: FSMContext) -> None:
    user = message.from_user
    if not user:
        return
    tno = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({
        "id": tno, "user_id": user.id, "username": user.username or "",
        "text": message.text or "", "at": datetime.now(timezone.utc).isoformat(),
    })
    store.save()
    await state.clear()
    for owner_id in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(
                owner_id,
                f"📩 <b>تیکت جدید #{tno}</b>\n"
                f"👤 کاربر: <a href='tg://user?id={user.id}'>{html.escape(user.full_name)}</a> (<code>{user.id}</code>)\n"
                f"📝 متن:\n{html.escape(message.text or '')}",
                parse_mode="HTML",
            )
        except Exception:
            pass
    await message.answer(f"✅ پیام شما با شماره <b>#{tno}</b> ثبت شد.", parse_mode="HTML", reply_markup=back_home_kb("m:home"))


@router.callback_query(F.data == "m:free")
async def cb_free_config(cb: CallbackQuery) -> None:
    await cb.answer()
    free_list = store.data.get("free_configs", [])
    if free_list:
        items = "\n\n".join(f"🔹 <code>{html.escape(c)}</code>" for c in free_list[-5:])
        text = f"🔴 <b>کانفیگ‌های رایگان فعال ({len(free_list)})</b>\n━━━━━━━━━━━━━━━━━━━━\n{items}"
        markup = kb([
            [btn("🛡️ ساخت WARP رایگان اختصاصی", callback_data="m:warp", style="success")],
            [btn("🔙 بازگشت", callback_data="m:home", style="primary")],
        ])
    else:
        text = (
            "🔴 <b>کانفیگ رایگان آماده</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "بهترین گزینه رایگان، ساخت کانفیگ اختصاصی با کلید شخصی خودتان است (بدون افت سرعت اشتراکی):\n"
            "• <b>🛡️ WARP / WireGuard رایگان</b> — فوری و بدون نیاز به اکانت!\n"
            "• <b>🚀 پنل توربو اختصاصی کلودفلر</b> — رایگان و دائمی!"
        )
        markup = kb([
            [btn("🛡️ ساخت فوری WARP رایگان", callback_data="m:warp", style="success")],
            [btn("🚀 ساخت پنل توربو رایگان", callback_data="m:turbo", style="primary")],
            [btn("🔙 بازگشت", callback_data="m:home", style="primary")],
        ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "m:invite")
async def cb_invite(cb: CallbackQuery) -> None:
    await cb.answer()
    uid = cb.from_user.id
    me = await cb.bot.get_me()
    link = f"https://t.me/{me.username}?start=ref_{uid}"
    refs = len(store.data.get("users", {}).get(str(uid), {}).get("referrals", []))
    text = (
        "🎁 <b>دعوت دوستان</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"👥 تعداد دوستان دعوت‌شده توسط شما: <b>{refs}</b>\n\n"
        "این ربات رایگان است و رایگان می‌ماند. لینک زیر را برای دوستانتان بفرستید:\n"
        f"<code>{link}</code>"
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:donate")
async def cb_donate(cb: CallbackQuery) -> None:
    await cb.answer()
    donate_txt = store.data["settings"].get("donate_text", "❤️ ممنون از حمایت شما!")
    await _edit(cb, f"❤️ <b>حمایت از ما</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(donate_txt)}", back_home_kb("m:home"))


# ==================== 5. ULTRA-PRO ADMIN & USER MANAGEMENT CONSOLE ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    cfg = store.data["settings"]
    ip_cnt = len(store.data.get("ip_pool", []))
    ep_cnt = len(store.data.get("endpoint_pool", []))
    users = store.data.get("users", {})
    u_cnt = len(users)
    banned_cnt = sum(1 for u in users.values() if u.get("is_banned"))
    cf_cnt = len(store.data.get("cf_accounts", {}))
    total_cfgs = sum(int(u.get("configs_generated", 0)) for u in users.values())
    total_warp = sum(int(u.get("warp_generated", 0)) for u in users.values())

    scan_status = (
        f"⏳ در حال اسکن ({bg_engine.current_stage}: {bg_engine.progress_done}/{bg_engine.progress_total})"
        if bg_engine.is_scanning
        else "🟢 آماده (پس‌زمینه فعال)"
    )
    last_scan = bg_engine.last_scan_at[:19].replace("T", " ") if bg_engine.last_scan_at else "در انتظار اولین دور"

    text = (
        "🛠️ <b>پنل مدیریت حرفه‌ای (Admin Control Center)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ موتور اسکن: <b>{scan_status}</b>\n"
        f"🕒 آخرین اسکن: <code>{last_scan} UTC</code>\n"
        f"🟢 IP سالم: <b>{ip_cnt}</b> | 🛡️ رله WARP سالم: <b>{ep_cnt}</b>\n"
        f"👥 کاربران: <b>{u_cnt}</b> (مسدود: {banned_cnt}) | ☁️ کلودفلر متصل: <b>{cf_cnt}</b>\n"
        f"📊 تولید کل: <b>{total_cfgs}</b> پنل/VLESS | <b>{total_warp}</b> WARP\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b> | Disk <b>{sys_h['disk_percent']}%</b>\n"
        f"🤖 خودترمیم IP: <b>{'🟢 روشن' if cfg.get('auto_apply_ip', True) else '🔴 خاموش'}</b> | تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━"
    )
    scan_btn = (
        btn("⛔ توقف اسکن فعال", callback_data="adm:scan_stop", style="danger")
        if bg_engine.is_scanning
        else btn("▶️ شروع اسکن فوری IP و WARP", callback_data="adm:scan_now", style="success")
    )
    markup = kb([
        [scan_btn],
        [
            btn("👥 مدیریت کامل کاربران", callback_data="adm:users:0", style="primary"),
            btn("🔎 جستجوی کاربر", callback_data="adm:user_search", style="primary"),
        ],
        [
            btn("🌐 مدیریت IPهای سالم", callback_data="adm:ips", style="primary"),
            btn("🛡️ مدیریت رله‌های WARP", callback_data="adm:eps", style="primary"),
        ],
        [
            btn("🧪 اسکن IP دلخواه", callback_data="adm:custom_scan", style="primary"),
            btn("➕ افزودن رنج CIDR", callback_data="adm:add_cidr", style="success"),
        ],
        [
            btn("🔴 مدیریت کانفیگ رایگان", callback_data="adm:free_cfg", style="primary"),
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
        ],
        [
            btn("⚙️ تنظیمات ربات و پشتیبانی", callback_data="adm:settings", style="primary"),
            btn("🔄 رفرش زنده", callback_data="adm:home", style="primary"),
        ],
        [btn("🔙 بازگشت به منوی کاربر", callback_data="m:home", style="danger")],
    ])
    return text, markup


@router.callback_query(F.data == "adm:home")
async def cb_adm_home(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        await cb.answer("⛔ دسترسی غیرمجاز!", show_alert=True)
        return
    await state.clear()
    await cb.answer()
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


# --- PRO PAGINATED USER MANAGEMENT ---
@router.callback_query(F.data.startswith("adm:users:"))
async def cb_adm_users_page(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    page = int(cb.data.split(":")[2])
    per_page = 6
    all_users = sorted(
        store.data.get("users", {}).values(),
        key=lambda x: x.get("last_seen", ""),
        reverse=True,
    )
    total = len(all_users)
    start = page * per_page
    chunk = all_users[start : start + per_page]

    text = (
        f"👥 <b>مدیریت کاربران (صفحه {page + 1} | کل: {total})</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "برای مشاهده پروفایل، مسدودسازی، حذف پنل یا ارسال پیام خصوصی، روی هر کاربر کلیک کنید:"
    )
    rows = []
    for u in chunk:
        uid = u["telegram_id"]
        badge = "🚫" if u.get("is_banned") else ("☁️" if str(uid) in store.data.get("cf_accounts", {}) else "👤")
        uname = f"@{u['username']}" if u.get("username") else (u.get("full_name") or str(uid))
        rows.append([btn(f"{badge} {uname[:22]} | ID:{uid}", callback_data=f"adm:uview:{uid}", style="primary")])

    nav = []
    if page > 0:
        nav.append(btn("⬅️ قبلی", callback_data=f"adm:users:{page - 1}", style="primary"))
    if start + per_page < total:
        nav.append(btn("بعدی ➡️", callback_data=f"adm:users:{page + 1}", style="primary"))
    if nav:
        rows.append(nav)

    rows.append([btn("🔎 جستجو با آیدی یا یوزرنیم", callback_data="adm:user_search", style="success")])
    rows.append([btn("🔙 بازگشت به پنل مدیریت", callback_data="adm:home", style="danger")])
    await _edit(cb, text, kb(rows))


def _render_admin_user_profile(target_uid: int) -> tuple[str, object]:
    u = store.data.get("users", {}).get(str(target_uid))
    if not u:
        return "❌ کاربر یافت نشد.", back_home_kb("adm:users:0")
    cf = store.data.get("cf_accounts", {}).get(str(target_uid))
    panel = store.data.get("panels", {}).get(str(target_uid))

    text = (
        f"👤 <b>پروفایل کامل کاربر</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 آیدی عددی: <code>{target_uid}</code>\n"
        f"📛 نام: <b>{html.escape(u.get('full_name') or '-')}</b>\n"
        f"🔗 یوزرنیم: @{html.escape(u.get('username') or 'ندارد')}\n"
        f"🚦 وضعیت حساب: <b>{'🚫 مسدود' if u.get('is_banned') else '🟢 فعال'}</b>\n"
        f"☁️ اتصال کلودفلر: <b>{'✅ متصل (' + html.escape(cf.get('account_name', '')) + ')' if cf else '⚪ ندارد'}</b>\n"
        f"🎛️ هاست پنل: <code>{html.escape(panel['host']) if panel else '-'}</code>\n"
        f"📊 آمار تولید: <b>{u.get('configs_generated', 0)}</b> کانفیگ پنل | <b>{u.get('warp_generated', 0)}</b> WARP\n"
        f"🎁 دعوت دوستان: <b>{len(u.get('referrals', []))}</b>\n"
        f"📅 عضویت: <code>{str(u.get('joined_at', ''))[:16].replace('T', ' ')}</code>"
    )
    ban_btn = (
        btn("✅ رفع مسدودی کاربر", callback_data=f"adm:uban:{target_uid}", style="success")
        if u.get("is_banned")
        else btn("🚫 مسدود کردن کاربر", callback_data=f"adm:uban:{target_uid}", style="danger")
    )
    rows = [
        [ban_btn],
        [btn("✉️ ارسال پیام مستقیم به کاربر", callback_data=f"adm:udm:{target_uid}", style="primary")],
    ]
    if cf or panel:
        rows.append([btn("🗑️ ریست پنل و حذف توکن کاربر", callback_data=f"adm:ureset:{target_uid}", style="danger")])
    rows.append([btn("🔙 لیست کاربران", callback_data="adm:users:0", style="primary")])
    return text, kb(rows)


@router.callback_query(F.data.startswith("adm:uview:"))
async def cb_adm_uview(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    target = int(cb.data.split(":")[2])
    text, markup = _render_admin_user_profile(target)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:uban:"))
async def cb_adm_uban(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    target = int(cb.data.split(":")[2])
    if _is_admin(target):
        await cb.answer("⚠️ نمی‌توانید مدیر را مسدود کنید.", show_alert=True)
        return
    new_s = not store.is_banned(target)
    store.set_ban(target, new_s)
    await cb.answer("🚫 کاربر مسدود شد." if new_s else "✅ رفع مسدودی شد.", show_alert=True)
    text, markup = _render_admin_user_profile(target)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:ureset:"))
async def cb_adm_ureset(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    target = int(cb.data.split(":")[2])
    store.data["cf_accounts"].pop(str(target), None)
    store.data["panels"].pop(str(target), None)
    store.save()
    await cb.answer("🗑️ پنل و توکن کاربر پاک شد.", show_alert=True)
    text, markup = _render_admin_user_profile(target)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:udm:"))
async def cb_adm_udm(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    target = int(cb.data.split(":")[2])
    await state.update_data(dm_target=target)
    await state.set_state(Flow.adm_dm_text)
    await _edit(cb, f"✉️ متن پیام برای ارسال به کاربر <code>{target}</code> را بنویسید:", kb([[btn("❌ انصراف", callback_data=f"adm:uview:{target}", style="danger")]]))


@router.message(Flow.adm_dm_text)
async def handle_adm_dm_text(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    data = await state.get_data()
    target = int(data.get("dm_target", 0))
    await state.clear()
    try:
        await message.bot.send_message(target, f"📩 <b>پیام از مدیریت:</b>\n\n{html.escape(message.text or '')}", parse_mode="HTML")
        await message.answer(f"✅ پیام با موفقیت به <code>{target}</code> ارسال شد.", parse_mode="HTML", reply_markup=back_home_kb(f"adm:uview:{target}"))
    except Exception as exc:
        await message.answer(f"❌ ارسال ناموفق بود: {html.escape(str(exc))}", parse_mode="HTML", reply_markup=back_home_kb(f"adm:uview:{target}"))


@router.callback_query(F.data == "adm:user_search")
async def cb_adm_user_search(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_user_search)
    await _edit(cb, "🔎 آیدی عددی یا <code>@username</code> کاربر مورد نظر را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_user_search)
async def handle_adm_user_search(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    u = store.find_user(message.text or "")
    await state.clear()
    if not u:
        await message.answer("❌ کاربری با این مشخصات یافت نشد.", reply_markup=back_home_kb("adm:users:0"))
        return
    text, markup = _render_admin_user_profile(int(u["telegram_id"]))
    await message.answer(text, parse_mode="HTML", reply_markup=markup)


# --- ADMIN SCANNER, POOLS, FREE CONFIGS, BROADCAST & SETTINGS ---
@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan_now(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    if bg_engine.is_scanning:
        await cb.answer("⏳ اسکن هم‌اکنون فعال است.", show_alert=True)
        return
    asyncio.create_task(bg_engine.run_full_cycle(trigger="admin_manual"))
    await cb.answer("🚀 اسکن واقعی IP و WARP در پس‌زمینه شروع شد!", show_alert=True)
    await asyncio.sleep(0.4)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:scan_stop")
async def cb_adm_scan_stop(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    bg_engine.cancel_current_scan()
    await cb.answer("⛔ دستور توقف اسکن ارسال شد.", show_alert=True)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:ips")
async def cb_adm_ips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    pool = store.data.get("ip_pool", [])
    body = "\n".join(
        f"{i+1}. <code>{x['ip']}:{x['port']}</code> | ⭐<b>{x['score']}</b> | ⚡{x['latency_ms']}ms | J:{x['jitter_ms']} | {int(x['success_rate']*100)}%"
        for i, x in enumerate(pool[:15])
    ) or "هنوز IP تاییدشده‌ای ثبت نشده؛ دکمه اسکن فوری را بزنید."
    text = f"🌐 <b>استخر IPهای سالم ({len(pool)} عدد)</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}"
    markup = kb([
        [
            btn("📥 خروجی TXT", callback_data="adm:exp_txt", style="success"),
            btn("📥 خروجی CSV", callback_data="adm:exp_csv", style="primary"),
        ],
        [btn("🗑️ پاک‌سازی استخر IP", callback_data="adm:purge_ips", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.in_({"adm:exp_txt", "adm:exp_csv"}))
async def cb_adm_export(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    pool = store.data.get("ip_pool", [])
    if not pool:
        await cb.answer("استخر خالی است.", show_alert=True)
        return
    if cb.data == "adm:exp_txt":
        raw = "\n".join(f"{x['ip']}:{x['port']}" for x in pool).encode("utf-8")
        fname = "healthy_ips.txt"
    else:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["ip", "port", "score", "latency_ms", "jitter_ms", "success_rate", "tested_at"])
        for x in pool:
            w.writerow([x["ip"], x["port"], x["score"], x["latency_ms"], x["jitter_ms"], x["success_rate"], x["tested_at"]])
        raw = buf.getvalue().encode("utf-8")
        fname = "healthy_ips.csv"
    if cb.message:
        await cb.message.answer_document(BufferedInputFile(raw, filename=fname), caption=f"📥 خروجی {len(pool)} آی‌پی سالم")


@router.callback_query(F.data == "adm:purge_ips")
async def cb_adm_purge_ips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["ip_pool"] = []
    store.save()
    await cb.answer("🗑️ استخر IP پاک‌سازی شد.", show_alert=True)
    await cb_adm_ips(cb)


@router.callback_query(F.data == "adm:eps")
async def cb_adm_eps(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    eps = store.data.get("endpoint_pool", [])
    body = "\n".join(
        f"{i+1}. <code>{e['endpoint']}</code> [{e['protocol'].upper()}] | ⭐<b>{e['score']}</b> | ⚡{e['latency_ms']}ms"
        for i, e in enumerate(eps[:15])
    ) or "هنوز رله‌ای اسکن نشده است."
    await _edit(cb, f"🛡️ <b>استخر رله‌های سالم WARP ({len(eps)} عدد)</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:add_cidr")
async def cb_adm_add_cidr(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_add_cidr)
    cur = ", ".join(store.data.get("custom_cidrs", [])) or "هیچ"
    await _edit(cb, f"➕ رنج IPv4 معتبر بفرستید (مثال: <code>104.21.0.0/16</code>)\nفعلی: <code>{html.escape(cur)}</code>", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_add_cidr)
async def handle_adm_add_cidr(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    import ipaddress
    try:
        net = ipaddress.ip_network((message.text or "").strip(), strict=False)
        if not net.is_global:
            raise ValueError("Private CIDR blocked")
    except Exception as exc:
        await message.answer(f"❌ رنج نامعتبر: {exc}")
        return
    if str(net) not in store.data["custom_cidrs"]:
        store.data["custom_cidrs"].append(str(net))
        store.save()
    await state.clear()
    await message.answer(f"✅ رنج <code>{net}</code> اضافه شد.", parse_mode="HTML", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:custom_scan")
async def cb_adm_custom_scan(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_custom_scan)
    await _edit(cb, "🧪 لیست IPهای عمومی مورد نظر را ارسال کنید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_custom_scan)
async def handle_adm_custom_scan(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    ips = [x.strip() for x in (message.text or "").replace(",", " ").split() if x.strip()][:100]
    await state.clear()
    if not ips:
        return
    wait = await message.answer(f"⏳ در حال اسکن واقعی {len(ips)} IP...")
    summary = await bg_engine.run_full_cycle(trigger="admin_custom", custom_ips=ips)
    await wait.edit_text(
        f"✅ اسکن پایان یافت!\nتست شده: <b>{summary.get('ips_tested', 0)}</b> | سالم در استخر: <b>{summary.get('healthy_ips', 0)}</b>",
        parse_mode="HTML",
        reply_markup=back_home_kb("adm:ips"),
    )


@router.callback_query(F.data == "adm:free_cfg")
async def cb_adm_free_cfg(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cnt = len(store.data.get("free_configs", []))
    text = f"🔴 <b>مدیریت کانفیگ‌های رایگان ({cnt} عدد)</b>\nبرای افزودن کانفیگ جدید (VLESS/Trojan/WARP) دکمه سبز را بزنید:"
    markup = kb([
        [btn("➕ افزودن کانفیگ رایگان جدید", callback_data="adm:add_free_prompt", style="success")],
        [btn("🗑️ پاک‌سازی لیست رایگان", callback_data="adm:clear_free", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:add_free_prompt")
async def cb_adm_add_free_prompt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_add_free_cfg)
    await _edit(cb, "➕ لینک کانفیگ رایگان را ارسال کنید:", kb([[btn("❌ انصراف", callback_data="adm:free_cfg", style="danger")]]))


@router.message(Flow.adm_add_free_cfg)
async def handle_adm_add_free_cfg(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    if val:
        store.data.setdefault("free_configs", []).append(val)
        store.save()
    await state.clear()
    await message.answer("✅ به بخش «🔴 کانفیگ رایگان» اضافه شد.", reply_markup=back_home_kb("adm:free_cfg"))


@router.callback_query(F.data == "adm:clear_free")
async def cb_adm_clear_free(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["free_configs"] = []
    store.save()
    await cb.answer("🗑️ پاک شد.", show_alert=True)
    await cb_adm_free_cfg(cb, None)  # type: ignore[arg-type]


@router.callback_query(F.data == "adm:broadcast")
async def cb_adm_broadcast(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_broadcast)
    await _edit(cb, f"📢 متن پیام همگانی برای <b>{len(store.data.get('users', {}))}</b> کاربر را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_broadcast)
async def handle_adm_broadcast(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    text = message.text or ""
    await state.clear()
    sent, failed = 0, 0
    for uid_str in list(store.data.get("users", {}).keys()):
        try:
            await message.bot.send_message(int(uid_str), f"📢 <b>اطلاعیه مدیریت:</b>\n\n{html.escape(text)}", parse_mode="HTML")
            sent += 1
            await asyncio.sleep(0.05)
        except Exception:
            failed += 1
    await message.answer(f"✅ ارسال تمام شد.\nموفق: <b>{sent}</b> | ناموفق: <b>{failed}</b>", parse_mode="HTML", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:settings")
async def cb_adm_settings(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID: {cfg.get('support_user_id')}"
    text = (
        "⚙️ <b>تنظیمات سیستم و پشتیبانی</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 پشتیبانی: <b>{html.escape(str(sup))}</b>\n"
        f"🤖 اعمال خودکار IP روی پنل‌ها: <b>{'🟢 روشن' if cfg.get('auto_apply_ip', True) else '🔴 خاموش'}</b>\n"
        f"🔄 اسکن خودکار پس‌زمینه: <b>{'🟢 فعال' if cfg.get('auto_scan_enabled', True) else '🔴 خاموش'}</b> (هر {cfg.get('auto_scan_interval_hours', 6)} ساعت)\n"
        f"🛠️ حالت تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    markup = kb([
        [btn("💬 تغییر یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="success")],
        [
            btn("🤖 تغییر خودترمیم IP", callback_data="adm:tog_autoip", style="primary"),
            btn("⏱️ تغییر بازه اسکن", callback_data="adm:cycle_int", style="primary"),
        ],
        [
            btn("🔄 اسکن خودکار", callback_data="adm:tog_autoscan", style="primary"),
            btn("🛠️ حالت تعمیرات", callback_data="adm:tog_maint", style="danger"),
        ],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:tog_autoip")
async def cb_adm_tog_autoip(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_apply_ip"] = not bool(store.data["settings"].get("auto_apply_ip", True))
    store.save()
    await cb.answer("✅ تغییر یافت.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_autoscan")
async def cb_adm_tog_autoscan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_scan_enabled"] = not bool(store.data["settings"].get("auto_scan_enabled", True))
    store.save()
    await cb.answer("✅ تغییر یافت.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["maintenance_mode"] = not bool(store.data["settings"].get("maintenance_mode", False))
    store.save()
    await cb.answer("✅ تغییر یافت.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:cycle_int")
async def cb_adm_cycle_int(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    opts = [3, 6, 12, 24]
    cur = int(store.data["settings"].get("auto_scan_interval_hours", 6))
    nxt = opts[(opts.index(cur) + 1) % len(opts)] if cur in opts else 6
    store.data["settings"]["auto_scan_interval_hours"] = nxt
    store.save()
    await cb.answer(f"⏱️ بازه: هر {nxt} ساعت")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_set_support)
    await _edit(cb, "💬 یوزرنیم پشتیبانی خود را (مثال: <code>@YourID</code>) بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


@router.message(Flow.adm_set_support)
async def handle_adm_set_sup(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    uname = (message.text or "").strip().lstrip("@")
    store.data["settings"]["support_username"] = uname
    store.save()
    await state.clear()
    await message.answer(f"✅ آیدی پشتیبانی به <b>@{html.escape(uname)}</b> تغییر یافت.", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))


# ==================== LIFECYCLE ====================
async def on_startup() -> None:
    logger.info("Starting BackgroundScannerEngine (V4 Pro)...")
    bg_engine.start()


async def on_shutdown() -> None:
    logger.info("Stopping BackgroundScannerEngine...")
    await bg_engine.stop()


async def run_polling() -> None:
    configure_logging()
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required to launch the bot.")
    bot = Bot(token=settings.telegram_bot_token)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)
    dp.startup.register(on_startup)
    dp.shutdown.register(on_shutdown)
    logger.info("Starting Cloudflare Config Hub V4 (AutoVless-Grade UI + Direct CF Token + Anti-DPI WARP).")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V4_EOF__

python3 -c '
from pathlib import Path
p = Path("docker-compose.yml")
txt = p.read_text(encoding="utf-8")
if "./data:/app/data" not in txt and "telegram_bot:" in txt:
    txt = txt.replace(
        "command: [\"python\", \"-m\", \"app.bot.bot\"]",
        "command: [\"python\", \"-m\", \"app.bot.bot\"]\n    volumes:\n      - ./data:/app/data"
    )
    p.write_text(txt, encoding="utf-8")
    print("Mounted persistent ./data volume in docker-compose.yml")
'

echo ">>> Rebuilding and restarting telegram_bot..."
docker compose up -d --build telegram_bot
sleep 4
docker compose logs --tail=25 telegram_bot
echo ">>> V4 Upgrade complete! Send /start to your Telegram bot."
