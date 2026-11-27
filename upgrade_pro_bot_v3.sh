#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to Pro Automated V3..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_EOF__' > backend/app/bot/ui.py
from __future__ import annotations

from typing import Literal

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

ButtonStyle = Literal["primary", "success", "danger"]

_NATIVE_STYLE = "style" in getattr(InlineKeyboardButton, "model_fields", {})


class StyledButton(InlineKeyboardButton):
    """Fallback InlineKeyboardButton subclass for older aiogram versions without native `style`."""
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


def main_menu_kb(is_admin: bool = False) -> InlineKeyboardMarkup:
    rows = [
        [btn("🚀 ساخت کانفیگ پرسرعت", callback_data="m:fast", style="success")],
        [btn("⚡ ساخت کانفیگ‌های WARP", callback_data="m:warp", style="primary")],
        [
            btn("📚 آموزش‌ها", callback_data="m:tutorials", style="primary"),
            btn("🆘 پشتیبانی", callback_data="m:support", style="danger"),
        ],
    ]
    if is_admin:
        rows.append([btn("🛡️ پنل مدیریت حرفه‌ای", callback_data="adm:home", style="success")])
    return kb(rows)


def back_home_kb(back_cb: str = "m:home", extra_rows: list[list[InlineKeyboardButton]] | None = None) -> InlineKeyboardMarkup:
    rows = list(extra_rows) if extra_rows else []
    rows.append([btn("🔙 بازگشت", callback_data=back_cb)])
    return kb(rows)
__CFHUB_EOF__

cat <<'__CFHUB_EOF__' > backend/app/bot/store.py
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
    """Thread-safe persistent storage with Fernet encryption for user Cloudflare API tokens."""

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
            "scan_history": [],
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "maintenance_mode": False,
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
                    "is_banned": False,
                    "joined_at": now,
                    "last_seen": now,
                    "configs_generated": 0,
                }
                self.data["users"][key] = u
            else:
                u["username"] = username or u.get("username", "")
                u["full_name"] = full_name or u.get("full_name", "")
                u["last_seen"] = now
            self.save()
            return u

    def increment_configs(self, tg_id: int) -> None:
        with self._lock:
            u = self.data["users"].get(str(tg_id))
            if u:
                u["configs_generated"] = int(u.get("configs_generated", 0)) + 1
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
                "is_banned": banned,
                "joined_at": now,
                "last_seen": now,
                "configs_generated": 0,
            })
            u["is_banned"] = banned
            self.save()
__CFHUB_EOF__

cat <<'__CFHUB_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import ipaddress
import logging
import random
import socket
import time
from datetime import datetime, timezone
from typing import Any

from app.ranking.ip_ranker import CandidateMetricsInput, SmartIPRanker
from app.scanners.base import BoundedAdaptiveRunner
from app.scanners.ip_scanner import IPCandidateScanner, IPScanOptions

logger = logging.getLogger(__name__)

# Official public Cloudflare IPv4 edge ranges
DEFAULT_CF_CIDRS = [
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "162.159.0.0/16",
    "188.114.96.0/20",
]

# Documented Cloudflare WARP / MASQUE endpoints
DEFAULT_WARP_ENDPOINTS = [
    "engage.cloudflareclient.com:2408",
    "162.159.192.1:2408",
    "162.159.192.8:2408",
    "162.159.193.1:2408",
    "162.159.193.10:2408",
    "162.159.195.1:2408",
    "162.159.195.5:2408",
    "188.114.96.1:2408",
    "188.114.97.1:2408",
    "188.114.98.1:2408",
    "188.114.99.1:2408",
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


async def probe_warp_endpoint(host: str, port: int, timeout_sec: float = 2.2) -> tuple[bool, float | None]:
    """Real DNS + edge reachability latency probe for WARP / MASQUE endpoints."""
    loop = asyncio.get_running_loop()
    start = time.perf_counter()
    try:
        infos = await asyncio.wait_for(loop.getaddrinfo(host, port, type=socket.SOCK_DGRAM), timeout=timeout_sec)
        target_ip = infos[0][4][0]
        reader, writer = await asyncio.wait_for(asyncio.open_connection(target_ip, 443), timeout=timeout_sec)
        elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True, elapsed_ms
    except Exception:
        return False, None


class BackgroundScannerEngine:
    """
    Autonomous background IP & Endpoint scanner engine.
    Continuously probes, ranks, and refreshes healthy pools without fabricating any results.
    """

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

                # Phase 2: Real Endpoint scan (WireGuard & MASQUE)
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
                        ok, lat = await probe_warp_endpoint(host, port, timeout_sec=timeout_sec)
                        if ok and lat is not None:
                            latencies.append(lat)
                        await asyncio.sleep(0.08)
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
__CFHUB_EOF__

cat <<'__CFHUB_EOF__' > backend/app/bot/cf_manager.py
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
    """Real Cloudflare API v4 onboarding, account discovery, and personal panel builder."""

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
        panel_name: str = "CF-Hub-Pro",
        path: str = "/ws",
        force_new_uuid: bool = False,
    ) -> dict[str, Any]:
        key = str(tg_id)
        existing = store.data["panels"].get(key) or {}
        panel_uuid = str(uuid.uuid4()) if (force_new_uuid or not existing.get("uuid")) else existing["uuid"]
        now = datetime.now(timezone.utc).isoformat()
        panel = {
            "name": panel_name,
            "uuid": panel_uuid,
            "host": host_domain,
            "clean_ip": clean_ip,
            "port": 443,
            "path": path,
            "sni": host_domain,
            "fp": "chrome",
            "alpn": "http/1.1",
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
__CFHUB_EOF__

cat <<'__CFHUB_EOF__' > backend/app/bot/warp_builder.py
from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519

PlatformType = Literal["ios", "android", "windows"]


@dataclass
class WarpRegistration:
    ok: bool
    private_key: str = ""
    public_key: str = ""
    peer_public_key: str = ""
    ipv4: str = "172.16.0.2/32"
    ipv6: str = ""
    reserved: list[int] | None = None
    device_id: str = ""
    token: str = ""
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
    """Register a genuine anonymous Cloudflare WARP WireGuard device via Cloudflare client API."""
    priv_key, pub_key = generate_x25519_keypair()
    payload = {
        "key": pub_key,
        "install_id": "",
        "fcm_token": "",
        "tos": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "model": "PC",
        "serial_number": "",
        "locale": "en_US",
    }
    headers = {
        "User-Agent": "okhttp/3.12.1",
        "Content-Type": "application/json; charset=UTF-8",
    }
    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            resp = await client.post("https://api.cloudflareclient.com/v0a2158/reg", json=payload, headers=headers)
            if resp.status_code not in (200, 201):
                return WarpRegistration(ok=False, error=f"Cloudflare WARP API پاسخ HTTP {resp.status_code} داد.")
            data = resp.json()
            cfg = data.get("config") or {}
            peers = cfg.get("peers") or [{}]
            iface = cfg.get("interface", {}).get("addresses") or {}
            client_id_b64 = cfg.get("client_id", "")
            reserved = list(base64.b64decode(client_id_b64)[:3]) if client_id_b64 else [0, 0, 0]
            ipv4 = iface.get("v4", "172.16.0.2")
            ipv6 = iface.get("v6", "")
            return WarpRegistration(
                ok=True,
                private_key=priv_key,
                public_key=pub_key,
                peer_public_key=peers[0].get("public_key", ""),
                ipv4=f"{ipv4}/32" if "/" not in ipv4 else ipv4,
                ipv6=f"{ipv6}/128" if ipv6 and "/" not in ipv6 else ipv6,
                reserved=reserved,
                device_id=data.get("id", ""),
                token=data.get("token", ""),
            )
    except Exception as exc:
        return WarpRegistration(ok=False, error=f"خطا در ثبت دستگاه WARP: {exc}")


def format_warp_wireguard(reg: WarpRegistration, endpoint: str, platform: PlatformType) -> dict:
    mtu = 1280 if platform in ("ios", "android") else 1380
    addresses = f"{reg.ipv4}, {reg.ipv6}" if reg.ipv6 else reg.ipv4
    reserved = reg.reserved or [0, 0, 0]

    lines = [
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {addresses}",
        "DNS = 1.1.1.1, 1.0.0.1",
        f"MTU = {mtu}",
        "",
        "[Peer]",
        f"PublicKey = {reg.peer_public_key}",
        "AllowedIPs = 0.0.0.0/0, ::/0",
        f"Endpoint = {endpoint}",
        "PersistentKeepalive = 25",
    ]
    conf_text = "\n".join(lines) + "\n"

    host, port_s = endpoint.rsplit(":", 1)
    singbox_json = json.dumps(
        {
            "type": "wireguard",
            "tag": f"CF-WARP-{platform.upper()}",
            "server": host.strip("[]"),
            "server_port": int(port_s),
            "local_address": [a for a in [reg.ipv4, reg.ipv6] if a],
            "private_key": reg.private_key,
            "peer_public_key": reg.peer_public_key,
            "reserved": reserved,
            "mtu": mtu,
        },
        indent=2,
    )

    clients = {
        "ios": "WireGuard / Streisand / Shadowrocket / Hiddify (آیفون)",
        "android": "Hiddify / AmneziaWG / WireGuard / v2rayNG (اندروید)",
        "windows": "WireGuard Official / Hiddify / Sing-box (ویندوز)",
    }

    return {
        "filename": f"cfhub_warp_wg_{platform}.conf",
        "file_content": conf_text,
        "singbox_json": singbox_json,
        "qr_payload": conf_text,
        "reserved": reserved,
        "recommended_clients": clients[platform],
    }


def format_warp_masque(reg: WarpRegistration, endpoint: str, platform: PlatformType) -> dict:
    host, _ = endpoint.rsplit(":", 1)
    masque_endpoint = f"{host}:443"
    mtu = 1280 if platform in ("ios", "android") else 1350

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
        "local_address": [a for a in [reg.ipv4, reg.ipv6] if a],
        "mtu": mtu,
        "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/",
    }
    serialized = json.dumps(profile, indent=2)
    clients = {
        "ios": "Cloudflare WARP (حالت MASQUE) / کلاینت‌های HTTP/3 RFC 9298 در آیفون",
        "android": "Cloudflare WARP (حالت MASQUE) / کلاینت‌های HTTP/3 QUIC در اندروید",
        "windows": "Cloudflare WARP Desktop (حالت MASQUE) / کلاینت‌های QUIC در ویندوز",
    }
    return {
        "filename": f"cfhub_masque_{platform}.json",
        "file_content": serialized,
        "qr_payload": serialized,
        "endpoint": masque_endpoint,
        "recommended_clients": clients[platform],
    }
__CFHUB_EOF__

cat <<'__CFHUB_EOF__' > backend/app/bot/bot.py
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
from app.bot.ui import back_home_kb, btn, kb, main_menu_kb
from app.bot.warp_builder import format_warp_masque, format_warp_wireguard, register_real_warp_device
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
    waiting_support_msg = State()
    adm_add_cidr = State()
    adm_custom_scan = State()
    adm_ban_uid = State()
    adm_broadcast = State()
    adm_set_support = State()


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
    ip_cnt = len(store.data.get("ip_pool", []))
    ep_cnt = len(store.data.get("endpoint_pool", []))
    top_ip = store.data["ip_pool"][0] if ip_cnt else None
    ping_str = f"{top_ip['latency_ms']}ms" if top_ip and top_ip.get("latency_ms") else "در حال اسکن..."
    scan_badge = "🔄 در حال به‌روزرسانی خودکار" if bg_engine.is_scanning else "🟢 آماده و آنلاین"
    connected = "✅ متصل" if str(tg_id) in store.data.get("cf_accounts", {}) else "⚪ متصل نشده"

    return (
        "🌐 <b>پلتفرم هوشمند Cloudflare Config Hub</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ موتور اسکن پس‌زمینه: <b>{scan_badge}</b>\n"
        f"🟢 IPهای سالم تاییدشده: <b>{ip_cnt}</b> (بهترین پینگ: <b>{ping_str}</b>)\n"
        f"🎯 اندپوینت‌های WARP فعال: <b>{ep_cnt}</b>\n"
        f"☁️ وضعیت کلودفلر شما: <b>{connected}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 یکی از گزینه‌های زیر را انتخاب کنید:"
    )


# ==================== START & HOME ====================
@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    user = message.from_user
    if not user:
        return
    store.touch_user(user.id, user.username, user.full_name)
    if store.is_banned(user.id) and not _is_admin(user.id):
        await message.answer("🚫 دسترسی شما به ربات مسدود شده است.")
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(user.id):
        await message.answer("🛠️ ربات موقتاً در حالت به‌روزرسانی است. لطفاً کمی بعد دوباره تلاش کنید.")
        return
    await message.answer(_home_text(user.id), reply_markup=main_menu_kb(_is_admin(user.id)), parse_mode="HTML")


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
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid)))


# ==================== 1. HIGH-SPEED CONFIG & CLOUDFLARE PERSONAL PANEL ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    best_ips = bg_engine.get_best_ips(5)
    best_ip_str = best_ips[0]["ip"] if best_ips else "104.16.132.229"
    best_ping = f"{best_ips[0]['latency_ms']}ms" if best_ips and best_ips[0].get("latency_ms") else "تست‌نشده"

    if not panel and cf:
        default_host = f"cfhub.{cf['workers_subdomain']}.workers.dev" if cf.get("workers_subdomain") else (
            cf["zones"][0] if cf.get("zones") else "your-worker.workers.dev"
        )
        panel = cf_service.ensure_personal_panel(store, uid, default_host, best_ip_str)

    text = (
        "🚀 <b>پنل اختصاصی و هوشمند کلودفلر شما</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"☁️ اکانت کلودفلر: <b>{html.escape(cf.get('account_name', 'Cloudflare'))}</b>\n"
        f"🌐 هاست / دامنه پنل: <code>{html.escape(panel['host'])}</code>\n"
        f"🟢 IP تمیز فعال: <code>{html.escape(panel['clean_ip'])}</code> (بهترین استخر: {best_ping})\n"
        f"🔑 UUID اختصاصی: <code>{html.escape(panel['uuid'])}</code>\n"
        f"🛤️ مسیر (Path): <code>{html.escape(panel['path'])}</code>\n"
        f"📦 تعداد Workerها: <b>{len(cf.get('workers_scripts', []))}</b> | دامنه‌ها: <b>{len(cf.get('zones', []))}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "با یک کلیک کانفیگ پرسرعت خود را دریافت یا بهینه‌سازی کنید:"
    )
    markup = kb([
        [btn("⚡ دریافت کانفیگ پرسرعت + QR", callback_data="cf:get_one", style="success")],
        [btn("📦 دریافت پکیج ۵ آی‌پی برتر", callback_data="cf:get_bundle", style="success")],
        [
            btn("🔄 تعویض خودکار IP تمیز", callback_data="cf:swap_ip", style="primary"),
            btn("🎛️ تغییر دامنه / هاست", callback_data="cf:edit_host", style="primary"),
        ],
        [
            btn("🛤️ تغییر Path", callback_data="cf:edit_path", style="primary"),
            btn("♻️ ساخت UUID جدید", callback_data="cf:reset_uuid", style="primary"),
        ],
        [
            btn("📘 آموزش کلودفلر", callback_data="cf:guide", style="primary"),
            btn("🗑️ قطع اتصال توکن", callback_data="cf:disconnect", style="danger"),
        ],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
    ])
    return text, markup


@router.callback_query(F.data == "m:fast")
async def cb_fast_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    uid = cb.from_user.id
    if store.is_banned(uid) and not _is_admin(uid):
        await cb.answer("🚫 حساب شما مسدود است.", show_alert=True)
        return

    if str(uid) in store.data.get("cf_accounts", {}):
        text, markup = _render_personal_panel(uid)
        await _edit(cb, text, markup)
        return

    text = (
        "🚀 <b>ساخت کانفیگ پرسرعت اختصاصی (Cloudflare)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "برای ساخت <b>پنل شخصی اختصاصی</b> و دریافت خودکار کانفیگ‌های پرسرعت با بهترین IPهای تمیز اسکن‌شده در پس‌زمینه، کافیست اکانت رایگان کلودفلر خود را یک‌بار متصل کنید.\n\n"
        "🔐 <i>توکن شما با رمزنگاری AES (Fernet) ذخیره می‌شود و پیام توکن بلافاصله از چت حذف می‌گردد.</i>"
    )
    markup = kb([
        [btn("🔑 دریافت و اتصال توکن کلودفلر", callback_data="cf:connect", style="success")],
        [btn("📘 آموزش ثبت‌نام کلودفلر و گرفتن توکن", callback_data="cf:guide", style="primary")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:guide")
async def cb_cf_guide(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📘 <b>آموزش صفر تا صد ثبت‌نام کلودفلر و گرفتن API Token کامل</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "<b>مرحله ۱ — ثبت‌نام رایگان:</b>\n"
        "1️⃣ وارد سایت <code>dash.cloudflare.com/sign-up</code> شوید.\n"
        "2️⃣ یک ایمیل معتبر و رمز قوی وارد کرده و ایمیل تایید را باز کنید.\n"
        "3️⃣ از منوی سمت چپ وارد بخش <b>Workers &amp; Pages</b> شوید و یک ساب‌دامنه رایگان <code>workers.dev</code> برای خود ثبت کنید.\n\n"
        "<b>مرحله ۲ — ساخت API Token با دسترسی کامل:</b>\n"
        "1️⃣ روی آیکون پروفایل بالا سمت راست کلیک کرده و <b>My Profile → API Tokens</b> را باز کنید.\n"
        "2️⃣ دکمه <b>Create Token</b> را بزنید.\n"
        "3️⃣ در پایین صفحه گزینه <b>Create Custom Token</b> (یا قالب <b>Edit Cloudflare Workers</b>) را انتخاب کنید.\n"
        "4️⃣ دسترسی‌های زیر را روی <b>Edit</b> قرار دهید:\n"
        "• <code>Account → Workers Scripts: Edit</code>\n"
        "• <code>Account → Workers KV Storage: Edit</code>\n"
        "• <code>Account → Account Settings: Read</code>\n"
        "• <code>Zone → DNS: Edit</code> و <code>Zone → Workers Routes: Edit</code>\n"
        "5️⃣ دکمه <b>Continue to summary → Create Token</b> را بزنید و توکن ساخته شده را کپی کنید.\n\n"
        "✅ حالا دکمه سبز پایین را بزنید و توکن را ارسال کنید:"
    )
    markup = kb([
        [btn("🔑 الان توکن را وارد می‌کنم", callback_data="cf:connect", style="success")],
        [btn("🔙 بازگشت", callback_data="m:fast")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:connect")
async def cb_cf_connect(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🔑 <b>اتصال امن اکانت کلودفلر</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "لطفاً <b>Cloudflare API Token</b> خود را همینجا ارسال کنید.\n\n"
        "🛡️ <i>به‌محض دریافت، پیام شما برای امنیت پاک می‌شود، توکن مستقیم از طریق API کلودفلر بررسی شده و به‌صورت رمزنگاری‌شده ذخیره می‌گردد.</i>"
    )
    markup = kb([
        [btn("📘 آموزش گرفتن توکن", callback_data="cf:guide", style="primary")],
        [btn("❌ انصراف", callback_data="m:fast", style="danger")],
    ])
    await _edit(cb, text, markup)


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
            "⚠️ فرمت توکن نامعتبر است. توکن کلودفلر معمولاً حدود ۴۰ کاراکتر و بدون فاصله است.\nدوباره ارسال کنید یا انصراف بزنید:",
            reply_markup=kb([[btn("❌ انصراف", callback_data="m:fast", style="danger")]]),
        )
        return

    wait_msg = await message.answer("⏳ در حال اعتبارسنجی زنده توکن و دریافت اطلاعات اکانت کلودفلر...")
    info = await cf_service.inspect_and_connect(raw_token)
    if not info.valid:
        await wait_msg.edit_text(
            f"❌ <b>توکن تایید نشد!</b>\nدلیل: <code>{html.escape(info.error or 'Invalid token')}</code>\n\n"
            "لطفاً دسترسی‌های توکن را بررسی کرده و مجدد ارسال کنید.",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("📘 راهنمای گرفتن توکن", callback_data="cf:guide", style="primary")],
                [btn("❌ انصراف", callback_data="m:fast", style="danger")],
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
    store.save()
    await state.clear()

    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(f"✅ <b>اتصال کلودفلر با موفقیت انجام شد!</b>\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:get_one")
async def cb_cf_get_one(cb: CallbackQuery) -> None:
    await cb.answer("⚡ در حال ساخت کانفیگ...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        await _edit(cb, "⚠️ ابتدا اکانت کلودفلر خود را متصل کنید.", back_home_kb("m:fast"))
        return

    best_ips = bg_engine.get_best_ips(1)
    if best_ips:
        panel["clean_ip"] = best_ips[0]["ip"]
        store.save()
        ping_info = f"{best_ips[0]['latency_ms']}ms | امتیاز {best_ips[0]['score']}"
    else:
        ping_info = "در انتظار پایان اولین دور اسکن پس‌زمینه"

    uri = cf_service.build_vless_uri(panel)
    store.increment_configs(uid)
    caption = (
        f"🚀 <b>کانفیگ پرسرعت اختصاصی شما آماده شد!</b>\n"
        f"🟢 IP تمیز انتخابی: <code>{html.escape(panel['clean_ip'])}</code> ({ping_info})\n"
        f"🌐 هاست: <code>{html.escape(panel['host'])}</code>\n\n"
        f"👇 روی لینک زیر بزنید تا کپی شود:\n<code>{html.escape(uri)}</code>"
    )
    markup = kb([
        [btn("🔄 تعویض IP تمیز", callback_data="cf:swap_ip", style="primary")],
        [btn("🔙 بازگشت به پنل شخصی", callback_data="m:fast")],
    ])
    if cb.message:
        await _send_qr(cb.message, uri, caption, markup)


@router.callback_query(F.data == "cf:get_bundle")
async def cb_cf_get_bundle(cb: CallbackQuery) -> None:
    await cb.answer("📦 در حال ساخت پکیج...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        await _edit(cb, "⚠️ ابتدا اکانت کلودفلر خود را متصل کنید.", back_home_kb("m:fast"))
        return

    best_ips = bg_engine.get_best_ips(5)
    ips_to_use = [x["ip"] for x in best_ips] if best_ips else [panel["clean_ip"]]
    uris = [cf_service.build_vless_uri(panel, override_ip=ip, label_suffix=f"-#{i+1}") for i, ip in enumerate(ips_to_use)]
    bundle_txt = "\n".join(uris)
    store.increment_configs(uid)

    if cb.message:
        await cb.message.answer_document(
            document=BufferedInputFile(bundle_txt.encode("utf-8"), filename="cfhub_highspeed_bundle.txt"),
            caption=(
                f"📦 <b>پکیج {len(uris)} کانفیگ با برترین IPهای اسکن‌شده پس‌زمینه</b>\n"
                "می‌توانید کل فایل یا متن زیر را در کلاینت خود (Hiddify / v2rayNG / Streisand) ایمپورت کنید."
            ),
            parse_mode="HTML",
            reply_markup=back_home_kb("m:fast"),
        )


@router.callback_query(F.data == "cf:swap_ip")
async def cb_cf_swap_ip(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    pool = store.data.get("ip_pool", [])
    if not panel or not pool:
        await cb.answer("⏳ هنوز IP جدیدی در استخر آماده نیست؛ کمی صبر کنید.", show_alert=True)
        return
    next_idx = (int(panel.get("ip_index", 0)) + 1) % min(len(pool), 20)
    chosen = pool[next_idx]
    panel["ip_index"] = next_idx
    panel["clean_ip"] = chosen["ip"]
    store.save()
    await cb.answer(f"✅ IP تغییر کرد: {chosen['ip']} ({chosen['latency_ms']}ms)")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:edit_host")
async def cb_cf_edit_host(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_host)
    await _edit(
        cb,
        "🎛️ <b>تغییر دامنه / هاست پنل</b>\n\nدامنه کلودفلر یا ساب‌دامنه <code>workers.dev</code> خود را بدون <code>https://</code> ارسال کنید:\nمثال: <code>my-panel.username.workers.dev</code>",
        kb([[btn("❌ انصراف", callback_data="m:fast", style="danger")]]),
    )


@router.message(Flow.waiting_panel_host)
async def handle_panel_host(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    host = (message.text or "").strip().replace("https://", "").replace("http://", "").split("/")[0]
    if "." not in host or len(host) < 4:
        await message.answer("⚠️ دامنه معتبر وارد کنید (مثال: `sub.example.com`).")
        return
    panel = store.data["panels"].get(str(uid))
    if panel:
        panel["host"] = host
        panel["sni"] = host
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ دامنه پنل به <code>{html.escape(host)}</code> تغییر یافت.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:edit_path")
async def cb_cf_edit_path(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_path)
    await _edit(
        cb,
        "🛤️ <b>تغییر مسیر (Path) پنل</b>\n\nمسیر جدید را با <code>/</code> شروع کرده و ارسال کنید (مثال: <code>/ws?ed=2048</code>):",
        kb([[btn("❌ انصراف", callback_data="m:fast", style="danger")]]),
    )


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
    await message.answer(f"✅ مسیر پنل به <code>{html.escape(path)}</code> تغییر یافت.\n\n{text}", parse_mode="HTML", reply_markup=markup)


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
    await cb.answer("🗑️ توکن کلودفلر با موفقیت حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid)))


# ==================== 2. WARP (WIREGUARD & MASQUE) — 1-CLICK BY PLATFORM ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    ep_wg = bg_engine.get_best_endpoint("wireguard")
    ep_mq = bg_engine.get_best_endpoint("masque")
    wg_info = f"<code>{ep_wg['endpoint']}</code> ({ep_wg['latency_ms']}ms)" if ep_wg else "<code>engage.cloudflareclient.com:2408</code>"
    mq_info = f"<code>{ep_mq['endpoint']}</code> ({ep_mq['latency_ms']}ms)" if ep_mq else "<code>162.159.192.1:443</code>"

    text = (
        "⚡ <b>ساخت خودکار کانفیگ‌های WARP (با یک کلیک)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚡ بهترین اندپوینت WireGuard:\n{wg_info}\n\n"
        f"🌀 بهترین اندپوینت MASQUE:\n{mq_info}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "ابتدا نوع پروتکل مورد نظر را انتخاب کنید:"
    )
    markup = kb([
        [btn("⚡ WireGuard (سریع و همه‌کاره)", callback_data="warp:proto:wg", style="success")],
        [btn("🌀 MASQUE (پروتکل جدید HTTP/3 QUIC)", callback_data="warp:proto:masque", style="primary")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:proto:"))
async def cb_warp_choose_platform(cb: CallbackQuery) -> None:
    await cb.answer()
    proto = cb.data.split(":")[2]  # wg | masque
    title = "⚡ WireGuard WARP" if proto == "wg" else "🌀 MASQUE WARP (RFC 9298)"
    text = (
        f"<b>{title}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "سیستم‌عامل دستگاه خود را انتخاب کنید تا کانفیگ اختصاصی با کلید واقعی و بهترین اندپوینت به‌صورت خودکار ساخته شود:"
    )
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:build:{proto}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:build:{proto}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:build:{proto}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:build:"))
async def cb_warp_build_one_click(cb: CallbackQuery) -> None:
    _, _, proto, platform = cb.data.split(":")
    await cb.answer("⏳ در حال ثبت کلید واقعی WARP و ساخت کانفیگ...")
    uid = cb.from_user.id

    if cb.message:
        wait = await cb.message.answer("⏳ در حال ثبت دستگاه جدید در سرورهای Cloudflare WARP و تنظیم بهترین اندپوینت...")
    else:
        return

    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(
            f"❌ <b>ثبت خودکار دستگاه در API کلودفلر موقتاً با خطا مواجه شد:</b>\n"
            f"<code>{html.escape(reg.error or 'Unknown error')}</code>\n\n"
            "لطفاً چند ثانیه بعد دوباره تلاش کنید.",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 تلاش مجدد", callback_data=cb.data, style="success")],
                [btn("🔙 بازگشت", callback_data="m:warp")],
            ]),
        )
        return

    best_ep = bg_engine.get_best_endpoint("masque" if proto == "masque" else "wireguard")
    endpoint_str = best_ep["endpoint"] if best_ep else ("162.159.192.1:443" if proto == "masque" else "engage.cloudflareclient.com:2408")
    ping_txt = f"{best_ep['latency_ms']}ms" if best_ep else "پیش‌فرض رسمی"

    store.increment_configs(uid)
    plat_fa = {"ios": "🍏 آیفون (iOS)", "android": "🤖 اندروید (Android)", "windows": "🪟 ویندوز (Windows)"}[platform]

    if proto == "wg":
        built = format_warp_wireguard(reg, endpoint_str, platform)  # type: ignore[arg-type]
        await wait.delete()
        doc = BufferedInputFile(built["file_content"].encode("utf-8"), filename=built["filename"])
        await cb.message.answer_document(
            document=doc,
            caption=(
                f"✅ <b>کانفیگ WireGuard WARP آماده شد!</b>\n"
                f"📱 پلتفرم: <b>{plat_fa}</b>\n"
                f"🎯 اندپوینت بهینه: <code>{html.escape(endpoint_str)}</code> ({ping_txt})\n"
                f"🔢 Reserved: <code>{built['reserved']}</code>\n"
                f"📲 برنامه‌های پیشنهادی: {html.escape(built['recommended_clients'])}"
            ),
            parse_mode="HTML",
        )
        await _send_qr(
            cb.message,
            built["qr_payload"],
            "📱 <b>QR Code آماده اسکن با اپلیکیشن WireGuard</b>",
            kb([
                [btn("🔄 ساخت کلید جدید", callback_data=cb.data, style="primary")],
                [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
            ]),
        )
    else:
        built = format_warp_masque(reg, endpoint_str, platform)  # type: ignore[arg-type]
        await wait.delete()
        doc = BufferedInputFile(built["file_content"].encode("utf-8"), filename=built["filename"])
        await cb.message.answer_document(
            document=doc,
            caption=(
                f"✅ <b>پروفایل MASQUE (RFC 9298 HTTP/3) آماده شد!</b>\n"
                f"📱 پلتفرم: <b>{plat_fa}</b>\n"
                f"🎯 اندپوینت QUIC: <code>{html.escape(built['endpoint'])}</code> ({ping_txt})\n"
                f"📲 کلاینت‌های سازگار: {html.escape(built['recommended_clients'])}"
            ),
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 ساخت پروفایل جدید", callback_data=cb.data, style="primary")],
                [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
            ]),
        )


# ==================== 3. SUPPORT ====================
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
        id_line = f"👤 شناسه مدیر پشتیبانی: <code>{sup_id}</code>"
    else:
        id_line = "👤 پشتیبانی آنلاین داخل ربات فعال است."

    rows.append([btn("✉️ ارسال پیام تیکت داخل ربات", callback_data="sup:ticket", style="primary")])
    rows.append([btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")])

    text = (
        "🆘 <b>پشتیبانی رسمی ربات</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{id_line}\n\n"
        "اگر در اتصال توکن کلودفلر، ساخت پنل یا وارد کردن کانفیگ‌ها سوالی دارید، مستقیم پیام دهید یا از دکمه زیر تیکت بفرستید:"
    )
    await _edit(cb, text, kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_support_msg)
    await _edit(
        cb,
        "✉️ پیام خود را بنویسید و ارسال کنید؛ پیام شما مستقیماً به مدیر ربات ارسال می‌شود:",
        kb([[btn("❌ انصراف", callback_data="m:support", style="danger")]]),
    )


@router.message(Flow.waiting_support_msg)
async def handle_support_msg(message: Message, state: FSMContext) -> None:
    user = message.from_user
    if not user:
        return
    ticket_no = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({
        "id": ticket_no,
        "user_id": user.id,
        "username": user.username or "",
        "text": message.text or "",
        "at": datetime.now(timezone.utc).isoformat(),
    })
    store.save()
    await state.clear()

    # Notify owner immediately
    for owner_id in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(
                owner_id,
                f"📩 <b>تیکت پشتیبانی جدید #{ticket_no}</b>\n"
                f"👤 کاربر: <a href='tg://user?id={user.id}'>{html.escape(user.full_name)}</a> (<code>{user.id}</code>)\n"
                f"📝 پیام:\n{html.escape(message.text or '')}",
                parse_mode="HTML",
            )
        except Exception:
            pass

    await message.answer(
        f"✅ پیام شما با شماره <b>#{ticket_no}</b> به دست پشتیبانی رسید.",
        parse_mode="HTML",
        reply_markup=back_home_kb("m:home"),
    )


# ==================== 4. TUTORIALS ====================
@router.callback_query(F.data == "m:tutorials")
async def cb_tutorials(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    text = (
        "📚 <b>مرکز آموزش کامل ربات</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "بخش آموزشی مورد نظر خود را انتخاب کنید:"
    )
    markup = kb([
        [btn("🤖 آموزش کامل کار با ربات", callback_data="tut:bot", style="success")],
        [btn("☁️ آموزش کلودفلر و دریافت API Token", callback_data="cf:guide", style="primary")],
        [
            btn("🍏 آموزش آیفون", callback_data="tut:ios", style="primary"),
            btn("🤖 آموزش اندروید", callback_data="tut:android", style="primary"),
        ],
        [btn("🪟 آموزش ویندوز", callback_data="tut:windows", style="primary")],
        [btn("🔙 بازگشت به منوی اصلی", callback_data="m:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("tut:"))
async def cb_tut_detail(cb: CallbackQuery) -> None:
    await cb.answer()
    topic = cb.data.split(":")[1]
    guides = {
        "bot": (
            "🤖 <b>آموزش کامل استفاده از ربات</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "1️⃣ <b>اسکن خودکار پس‌زمینه:</b> ربات به‌صورت ۲۴ ساعته در پس‌زمینه IPهای کلودفلر و اندپوینت‌های WARP را واقعی تست می‌کند و بهترین‌ها را نگه می‌دارد.\n\n"
            "2️⃣ <b>ساخت کانفیگ پرسرعت:</b> وارد این بخش شوید، توکن اکانت کلودفلر خود را یک‌بار متصل کنید تا پنل اختصاصی شما ساخته شود. از آن به بعد با یک کلیک کانفیگ + QR بگیرید و هر زمان سرعت افت کرد دکمه «تعویض خودکار IP تمیز» را بزنید.\n\n"
            "3️⃣ <b>ساخت کانفیگ‌های WARP:</b> پروتکل WireGuard یا MASQUE و سپس دستگاه خود (آیفون/اندروید/ویندوز) را بزنید تا کلید اختصاصی و فایل آماده اتصال بگیرید."
        ),
        "ios": (
            "🍏 <b>راهنمای اتصال در آیفون (iOS)</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "• برای <b>VLESS / کانفیگ پرسرعت:</b> اپلیکیشن <b>Streisand</b>، <b>V2Box</b> یا <b>Hiddify</b> را از App Store نصب کرده، لینک کانفیگ را کپی و گزینه Import from Clipboard بزنید.\n"
            "• برای <b>WireGuard WARP:</b> اپلیکیشن <b>WireGuard</b> را نصب کرده، روی + بزنید و فایل <code>.conf</code> یا QR Code را اسکن کنید.\n"
            "• برای <b>MASQUE:</b> از کلاینت رسمی Cloudflare WARP در حالت MASQUE یا کلاینت‌های HTTP/3 پشتیبانی‌کننده استفاده کنید."
        ),
        "android": (
            "🤖 <b>راهنمای اتصال در اندروید (Android)</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "• برای <b>VLESS / کانفیگ پرسرعت:</b> اپلیکیشن <b>v2rayNG</b> یا <b>Hiddify</b> را نصب کرده، لینک یا فایل پکیج ۵ آی‌پی را ایمپورت کنید.\n"
            "• برای <b>WireGuard WARP:</b> در اپلیکیشن <b>WireGuard</b> یا <b>AmneziaWG</b> روی + بزنید و فایل <code>.conf</code> ارسال‌شده توسط ربات را انتخاب کنید."
        ),
        "windows": (
            "🪟 <b>راهنمای اتصال در ویندوز (Windows)</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "• برای <b>VLESS:</b> برنامه <b>Hiddify</b> یا <b>v2rayN</b> را باز کرده و با <code>Ctrl+V</code> لینک کانفیگ را وارد کنید.\n"
            "• برای <b>WireGuard WARP:</b> نرم‌افزار رسمی <b>WireGuard for Windows</b> را نصب کرده و گزینه <b>Import tunnel(s) from file</b> را بزنید و فایل <code>.conf</code> را انتخاب کنید."
        ),
    }
    await _edit(cb, guides.get(topic, "آموزش یافت نشد."), back_home_kb("m:tutorials"))


# ==================== 5. PRO ADMIN PANEL (OWNER ONLY) ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    cfg = store.data["settings"]
    ip_cnt = len(store.data.get("ip_pool", []))
    ep_cnt = len(store.data.get("endpoint_pool", []))
    u_cnt = len(store.data.get("users", {}))
    cf_cnt = len(store.data.get("cf_accounts", {}))
    scan_status = (
        f"⏳ در حال اسکن ({bg_engine.current_stage}: {bg_engine.progress_done}/{bg_engine.progress_total})"
        if bg_engine.is_scanning
        else "🟢 آماده (در حالت پس‌زمینه)"
    )
    last_scan = bg_engine.last_scan_at[:19].replace("T", " ") if bg_engine.last_scan_at else "هنوز انجام نشده"

    text = (
        "🛡️ <b>پنل مدیریت حرفه‌ای Cloudflare Config Hub</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ موتور اسکن: <b>{scan_status}</b>\n"
        f"🕒 آخرین اسکن: <code>{last_scan} UTC</code>\n"
        f"🟢 استخر IP سالم: <b>{ip_cnt}</b> | 🎯 اندپوینت سالم: <b>{ep_cnt}</b>\n"
        f"👥 کل کاربران: <b>{u_cnt}</b> | ☁️ کلودفلر متصل: <b>{cf_cnt}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b> | Disk <b>{sys_h['disk_percent']}%</b>\n"
        f"🛠️ حالت تعمیر: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b> | اسکن خودکار: <b>{'🟢 فعال' if cfg.get('auto_scan_enabled', True) else '🔴 خاموش'}</b>\n"
        "━━━━━━━━━━━━━━━━━━━━"
    )
    scan_btn = (
        btn("⛔ توقف اسکن فعال", callback_data="adm:scan_stop", style="danger")
        if bg_engine.is_scanning
        else btn("▶️ شروع اسکن فوری IP و Endpoint", callback_data="adm:scan_now", style="success")
    )
    markup = kb([
        [scan_btn],
        [
            btn("🌐 مدیریت IPهای سالم", callback_data="adm:ips", style="primary"),
            btn("🎯 مدیریت اندپوینت‌ها", callback_data="adm:eps", style="primary"),
        ],
        [
            btn("🧪 اسکن IP دلخواه", callback_data="adm:custom_scan", style="primary"),
            btn("➕ افزودن رنج CIDR", callback_data="adm:add_cidr", style="success"),
        ],
        [
            btn("👥 مدیریت کاربران", callback_data="adm:users", style="primary"),
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
        ],
        [
            btn("⚙️ تنظیمات ربات و پشتیبانی", callback_data="adm:settings", style="primary"),
            btn("🔄 رفرش آمار", callback_data="adm:home", style="primary"),
        ],
        [btn("🔙 بازگشت به منوی کاربر", callback_data="m:home")],
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


@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan_now(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        await cb.answer("⛔ دسترسی غیرمجاز!", show_alert=True)
        return
    if bg_engine.is_scanning:
        await cb.answer("⏳ اسکن هم‌اکنون در حال اجراست.", show_alert=True)
        return
    asyncio.create_task(bg_engine.run_full_cycle(trigger="admin_manual"))
    await cb.answer("🚀 اسکن واقعی IP و Endpoint در پس‌زمینه شروع شد!", show_alert=True)
    await asyncio.sleep(0.5)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:scan_stop")
async def cb_adm_scan_stop(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        await cb.answer("⛔ دسترسی غیرمجاز!", show_alert=True)
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
    if pool:
        lines = [
            f"{i+1}. <code>{x['ip']}:{x['port']}</code> | ⭐ <b>{x['score']}</b> | ⚡ {x['latency_ms']}ms | J:{x['jitter_ms']} | {int(x['success_rate']*100)}%"
            for i, x in enumerate(pool[:15])
        ]
        body = "\n".join(lines)
    else:
        body = "هنوز IP تاییدشده‌ای در استخر نیست. دکمه اسکن فوری را بزنید."

    text = f"🌐 <b>استخر IPهای سالم و رتبه‌بندی‌شده ({len(pool)} عدد)</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}"
    markup = kb([
        [
            btn("📥 خروجی TXT", callback_data="adm:export_ips_txt", style="success"),
            btn("📥 خروجی CSV", callback_data="adm:export_ips_csv", style="primary"),
        ],
        [btn("🗑️ پاک‌سازی کامل استخر IP", callback_data="adm:purge_ips", style="danger")],
        [btn("🔙 بازگشت به پنل ادمین", callback_data="adm:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.in_({"adm:export_ips_txt", "adm:export_ips_csv"}))
async def cb_adm_export_ips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    pool = store.data.get("ip_pool", [])
    if not pool:
        await cb.answer("استخر خالی است.", show_alert=True)
        return
    if cb.data.endswith("txt"):
        content = "\n".join(f"{x['ip']}:{x['port']}" for x in pool).encode("utf-8")
        fname = "healthy_ips.txt"
    else:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["ip", "port", "score", "latency_ms", "jitter_ms", "success_rate", "tested_at"])
        for x in pool:
            w.writerow([x["ip"], x["port"], x["score"], x["latency_ms"], x["jitter_ms"], x["success_rate"], x["tested_at"]])
        content = buf.getvalue().encode("utf-8")
        fname = "healthy_ips.csv"
    if cb.message:
        await cb.message.answer_document(BufferedInputFile(content, filename=fname), caption=f"📥 خروجی {len(pool)} آی‌پی سالم تاییدشده")


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
    if eps:
        lines = [
            f"{i+1}. <code>{e['endpoint']}</code> [{e['protocol'].upper()}] | ⭐ <b>{e['score']}</b> | ⚡ {e['latency_ms']}ms"
            for i, e in enumerate(eps[:15])
        ]
        body = "\n".join(lines)
    else:
        body = "هنوز اندپوینتی اسکن نشده است."
    text = f"🎯 <b>استخر Endpointهای سالم ({len(eps)} عدد)</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}"
    await _edit(cb, text, back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:add_cidr")
async def cb_adm_add_cidr(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_add_cidr)
    cur = ", ".join(store.data.get("custom_cidrs", [])) or "هیچ"
    await _edit(
        cb,
        f"➕ <b>افزودن رنج CIDR جدید به موتور اسکن</b>\n\nرنج‌های اختصاصی فعلی: <code>{html.escape(cur)}</code>\n\nیک رنج IPv4 معتبر بفرستید (مثال: <code>104.21.0.0/16</code>):",
        kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]),
    )


@router.message(Flow.adm_add_cidr)
async def handle_adm_add_cidr(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    import ipaddress
    raw = (message.text or "").strip()
    try:
        net = ipaddress.ip_network(raw, strict=False)
        if not net.is_global:
            raise ValueError("Private/reserved CIDR blocked")
    except Exception as exc:
        await message.answer(f"❌ رنج نامعتبر است: {exc}")
        return
    if str(net) not in store.data["custom_cidrs"]:
        store.data["custom_cidrs"].append(str(net))
        store.save()
    await state.clear()
    await message.answer(f"✅ رنج <code>{net}</code> به موتور اسکن اضافه شد.", parse_mode="HTML", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:custom_scan")
async def cb_adm_custom_scan(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_custom_scan)
    await _edit(
        cb,
        "🧪 <b>اسکن فوری لیست IP دلخواه</b>\n\nIPهای عمومی مورد نظر را (جدا شده با خط جدید یا فاصله) ارسال کنید:",
        kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]),
    )


@router.message(Flow.adm_custom_scan)
async def handle_adm_custom_scan(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    ips = [x.strip() for x in (message.text or "").replace(",", " ").split() if x.strip()][:100]
    await state.clear()
    if not ips:
        await message.answer("⚠️ هیچ IP ارسال نشد.", reply_markup=back_home_kb("adm:home"))
        return
    wait = await message.answer(f"⏳ در حال اسکن واقعی {len(ips)} IP...")
    summary = await bg_engine.run_full_cycle(trigger="admin_custom", custom_ips=ips)
    await wait.edit_text(
        f"✅ <b>اسکن تمام شد!</b>\n"
        f"تست شده: <b>{summary.get('ips_tested', 0)}</b>\n"
        f"IPهای سالم در استخر: <b>{summary.get('healthy_ips', 0)}</b>",
        parse_mode="HTML",
        reply_markup=back_home_kb("adm:ips"),
    )


@router.callback_query(F.data == "adm:users")
async def cb_adm_users(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    users = list(store.data.get("users", {}).values())
    banned = sum(1 for u in users if u.get("is_banned"))
    recent = "\n".join(
        f"• <code>{u['telegram_id']}</code> | {html.escape(u.get('full_name') or '-')} | کانفیگ: {u.get('configs_generated', 0)} | {'🚫' if u.get('is_banned') else '✅'}"
        for u in users[-10:]
    ) or "کاربری ثبت نشده است."
    text = (
        f"👥 <b>مدیریت کاربران</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"کل کاربران: <b>{len(users)}</b> | مسدود شده: <b>{banned}</b>\n\n"
        f"<b>آخرین کاربران:</b>\n{recent}"
    )
    markup = kb([
        [btn("🚫 مسدود / رفع مسدودی کاربر با آیدی", callback_data="adm:ban_prompt", style="danger")],
        [btn("🔙 بازگشت به پنل ادمین", callback_data="adm:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:ban_prompt")
async def cb_adm_ban_prompt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_ban_uid)
    await _edit(
        cb,
        "🚫 آیدی عددی کاربر را برای <b>مسدود یا رفع مسدودی</b> (Toggle) بفرستید:",
        kb([[btn("❌ انصراف", callback_data="adm:users", style="danger")]]),
    )


@router.message(Flow.adm_ban_uid)
async def handle_adm_ban_uid(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    txt = (message.text or "").strip()
    if not txt.isdigit():
        await message.answer("⚠️ فقط آیدی عددی وارد کنید.")
        return
    target = int(txt)
    if _is_admin(target):
        await message.answer("⚠️ نمی‌توانید مدیر ربات را مسدود کنید.")
        return
    new_state = not store.is_banned(target)
    store.set_ban(target, new_state)
    await state.clear()
    status = "🚫 مسدود شد" if new_state else "✅ رفع مسدودی شد"
    await message.answer(f"کاربر <code>{target}</code> {status}.", parse_mode="HTML", reply_markup=back_home_kb("adm:users"))


@router.callback_query(F.data == "adm:broadcast")
async def cb_adm_broadcast(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_broadcast)
    await _edit(
        cb,
        f"📢 <b>ارسال همگانی به {len(store.data.get('users', {}))} کاربر</b>\n\nمتن پیام خود را ارسال کنید:",
        kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]),
    )


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
    await message.answer(
        f"✅ ارسال همگانی تمام شد.\nموفق: <b>{sent}</b> | ناموفق: <b>{failed}</b>",
        parse_mode="HTML",
        reply_markup=back_home_kb("adm:home"),
    )


@router.callback_query(F.data == "adm:settings")
async def cb_adm_settings(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID: {cfg.get('support_user_id')}"
    text = (
        "⚙️ <b>تنظیمات پیشرفته ربات و موتور اسکن</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🆘 پشتیبانی فعلی: <b>{html.escape(str(sup))}</b>\n"
        f"🔄 اسکن خودکار پس‌زمینه: <b>{'🟢 فعال' if cfg.get('auto_scan_enabled', True) else '🔴 غیرفعال'}</b>\n"
        f"⏱️ بازه اسکن خودکار: <b>هر {cfg.get('auto_scan_interval_hours', 6)} ساعت</b>\n"
        f"🎯 حداقل امتیاز کیفیت IP: <b>{cfg.get('min_quality_score', 55.0)}</b>\n"
        f"🛠️ حالت تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    markup = kb([
        [btn("🆘 تغییر آیدی یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="primary")],
        [
            btn("🔄 تغییر وضعیت اسکن خودکار", callback_data="adm:tog_autoscan", style="primary"),
            btn("⏱️ تغییر بازه (3/6/12/24h)", callback_data="adm:cycle_interval", style="primary"),
        ],
        [btn("🛠️ تغییر وضعیت حالت تعمیرات", callback_data="adm:tog_maint", style="danger")],
        [btn("🔙 بازگشت به پنل ادمین", callback_data="adm:home")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:tog_autoscan")
async def cb_adm_tog_autoscan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    cur = bool(store.data["settings"].get("auto_scan_enabled", True))
    store.data["settings"]["auto_scan_enabled"] = not cur
    store.save()
    await cb.answer("✅ وضعیت اسکن خودکار تغییر کرد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    cur = bool(store.data["settings"].get("maintenance_mode", False))
    store.data["settings"]["maintenance_mode"] = not cur
    store.save()
    await cb.answer("✅ وضعیت حالت تعمیرات تغییر کرد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:cycle_interval")
async def cb_adm_cycle_interval(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    options = [3, 6, 12, 24]
    cur = int(store.data["settings"].get("auto_scan_interval_hours", 6))
    nxt = options[(options.index(cur) + 1) % len(options)] if cur in options else 6
    store.data["settings"]["auto_scan_interval_hours"] = nxt
    store.save()
    await cb.answer(f"⏱️ بازه اسکن خودکار: هر {nxt} ساعت")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_set_support)
    await _edit(
        cb,
        "🆘 یوزرنیم تلگرام پشتیبانی خود را (با یا بدون <code>@</code>) ارسال کنید (مثال: <code>@MySupportID</code>):",
        kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]),
    )


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
    logger.info("Launching BackgroundScannerEngine on bot startup...")
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
    logger.info("Starting Cloudflare Config Hub Pro Bot (Automated Background Engine + Colored UI).")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_EOF__

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
echo ">>> Upgrade complete! Send /start to your Telegram bot."
