from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.core.config import get_settings
from app.security.crypto import SecretVault


def _resolve_store_path() -> Path:
    for path in (Path(os.getenv("HUB_STATE_PATH", "/app/data/hub_state.json")), Path("/tmp/cfhub_data/hub_state.json")):
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            p = path.parent / ".wtest"
            p.write_text("1", encoding="utf-8")
            p.unlink(missing_ok=True)
            return path
        except Exception:
            continue
    return Path("/tmp/hub_state.json")


class PersistentHubStore:
    def __init__(self, path: str | None = None):
        self.path = Path(path) if path else _resolve_store_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        settings = get_settings()
        master = settings.encryption_master_key or settings.jwt_secret_key or "cfhub-fallback-key"
        self._vault = SecretVault(master)
        self.data: dict[str, Any] = self._load()

    def _default_state(self) -> dict[str, Any]:
        settings = get_settings()
        owner_id = settings.owner_telegram_ids[0] if settings.owner_telegram_ids else 0
        return {
            "users": {}, "cf_accounts": {}, "panels": {},
            "operator_pools": {"mci": [], "mtn": [], "mkh": []},
            "manual_operator_ips": {"mci": [], "mtn": [], "mkh": []},
            "warp_v4_pool": [], "warp_v6_pool": [], "warp_probe_device": None, "proxy_ip_pool": [],
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "default_proxy_ip": "",
                "maintenance_mode": False,
                "auto_apply_ip": True,
                "auto_scan_enabled": True,
                "auto_scan_interval_hours": 6,
                "scan_timeout_sec": 2.6,
                # Real Telegram Force-Join Lock
                "tg_lock_enabled": False,
                "tg_lock_channel": "",
                "tg_lock_text": "🔒 برای استفاده رایگان از ربات، ابتدا در کانال تلگرام ما عضو شوید و سپس دکمه «بررسی عضویت» را بزنید:",
                # Fake YouTube Channel Lock
                "yt_lock_enabled": False,
                "yt_lock_url": "https://youtube.com/@CyberMux",
                "yt_lock_text": "🎬 برای حمایت از ما و باز شدن ربات، لطفاً کانال یوتیوب ما را سابسکرایب کنید و سپس دکمه «تایید عضویت» را بزنید:",
                "webapp_url": os.getenv("WEBAPP_URL", "https://app.prostoreshop.site").strip(),
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
            for op in ("mci", "mtn", "mkh"):
                loaded["operator_pools"].setdefault(op, [])
                loaded["manual_operator_ips"].setdefault(op, [])
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
                    "telegram_id": tg_id, "username": username or "", "full_name": full_name or "",
                    "lang": "fa", "is_banned": False, "yt_verified": False,
                    "joined_at": now, "last_seen": now,
                    "configs_generated": 0, "warp_generated": 0,
                }
                self.data["users"][key] = u
            else:
                u["username"] = username or u.get("username", "")
                u["full_name"] = full_name or u.get("full_name", "")
                u["last_seen"] = now
                u.setdefault("lang", "fa")
                u.setdefault("yt_verified", False)
                u.setdefault("warp_generated", 0)
            self.save()
            return u

    def is_yt_verified(self, tg_id: int) -> bool:
        return bool(self.data["users"].get(str(tg_id), {}).get("yt_verified", False))

    def set_yt_verified(self, tg_id: int, val: bool = True) -> None:
        with self._lock:
            u = self.data["users"].setdefault(str(tg_id), {"telegram_id": tg_id})
            u["yt_verified"] = val
            self.save()

    def get_lang(self, tg_id: int) -> str:
        return self.data["users"].get(str(tg_id), {}).get("lang", "fa")

    def toggle_lang(self, tg_id: int) -> str:
        with self._lock:
            u = self.data["users"].setdefault(str(tg_id), {"telegram_id": tg_id, "lang": "fa"})
            nxt = "en" if u.get("lang", "fa") == "fa" else "fa"
            u["lang"] = nxt
            self.save()
            return nxt

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
                "telegram_id": tg_id, "username": "", "full_name": "", "lang": "fa",
                "is_banned": banned, "yt_verified": False, "joined_at": now, "last_seen": now,
                "configs_generated": 0, "warp_generated": 0,
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
