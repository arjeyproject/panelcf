from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import html
import json
import logging
import secrets
import uuid
from datetime import datetime, timezone
from urllib.parse import parse_qsl

from aiohttp import web

from app.bot.cf_manager import _new_neutral_name, fetch_live_cloudflare_ech_b64
from app.bot.operator_scanner import OPERATOR_LABELS, is_restricted_1034_ip
from app.bot.ui import CLOUDFLARE_DIRECT_TOKEN_URL
from app.bot.warp_builder import build_warp_bundle, register_real_warp_device
from app.bot.webapp_ui import MINI_APP_HTML
from app.bot.worker_template import CURRENT_WORKER_VERSION
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e
from app.core.config import get_settings
from app.services.monitoring import collect_system_health

logger = logging.getLogger(__name__)


def verify_telegram_init_data(init_data: str, bot_token: str) -> dict | None:
    """Cryptographically verifies Telegram WebApp `initData` via HMAC-SHA256."""
    if not init_data or not bot_token:
        return None
    try:
        pairs = parse_qsl(init_data, keep_blank_values=True)
        data_dict = dict(pairs)
        received_hash = data_dict.pop("hash", None)
        if not received_hash:
            return None
        check_string = "\n".join(f"{k}={v}" for k, v in sorted(data_dict.items()))
        secret_key = hmac.new(b"WebAppData", bot_token.encode("utf-8"), hashlib.sha256).digest()
        computed = hmac.new(secret_key, check_string.encode("utf-8"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(computed, received_hash):
            return None
        user_raw = data_dict.get("user")
        if not user_raw:
            return None
        return json.loads(user_raw)
    except Exception:
        return None


def _ensure_sub_token(store, panel: dict) -> str:
    if not panel.get("sub_token"):
        panel["sub_token"] = secrets.token_urlsafe(12)
        store.save()
    return str(panel["sub_token"])


async def _probe_alt_ports(worker_host: str, ip_v: str, ip_t: str) -> tuple[int, int]:
    """Verifies whether alt Cloudflare HTTPS ports 2083 & 8443 route cleanly; falls back to 443 if blocked."""
    (ok_v, _, _), (ok_t, _, _) = await asyncio.gather(
        check_ip_routes_worker(worker_host, ip_v, 2083, timeout_sec=2.6),
        check_ip_routes_worker(worker_host, ip_t, 8443, timeout_sec=2.6),
    )
    return (2083 if ok_v else 443), (8443 if ok_t else 443)


async def start_mini_app_server(store, bg_engine, cf_service, bot=None, port: int = 8080) -> web.AppRunner:
    app = web.Application()
    settings = get_settings()
    admin_ids = set(settings.owner_telegram_ids)

    def _auth_user(request: web.Request) -> dict | None:
        init_data = request.headers.get("X-Telegram-Init-Data", "").strip()
        u = verify_telegram_init_data(init_data, settings.telegram_bot_token or "")
        if u and u.get("id"):
            uid = int(u["id"])
            full_name = " ".join(x for x in [u.get("first_name", ""), u.get("last_name", "")] if x).strip()
            store.touch_user(uid, u.get("username"), full_name)
            return {"id": uid, "username": u.get("username", ""), "full_name": full_name, "is_admin": uid in admin_ids}
        return None

    async def _check_locks_for(uid: int, is_admin: bool) -> dict | None:
        if is_admin:
            return None
        cfg = store.data["settings"]
        if cfg.get("tg_lock_enabled") and cfg.get("tg_lock_channel") and bot is not None:
            chan = str(cfg["tg_lock_channel"]).strip()
            chat_id = int(chan) if (chan.startswith("-") and chan[1:].isdigit()) else (chan if chan.startswith("@") else f"@{chan}")
            is_member = False
            try:
                mem = await bot.get_chat_member(chat_id=chat_id, user_id=uid)
                is_member = mem.status in ("member", "administrator", "creator")
            except Exception:
                is_member = False
            if not is_member:
                join_url = f"https://t.me/{chan.lstrip('@')}" if not chan.startswith("-") else ""
                return {"locked": True, "lock_type": "tg", "lock_text": cfg.get("tg_lock_text", ""), "lock_url": join_url}
        if cfg.get("yt_lock_enabled") and not store.is_yt_verified(uid):
            yt_url = str(cfg.get("yt_lock_url") or "https://youtube.com").strip()
            if not yt_url.startswith("http"):
                yt_url = "https://" + yt_url
            return {"locked": True, "lock_type": "yt", "lock_text": cfg.get("yt_lock_text", ""), "lock_url": yt_url}
        return None

    async def handle_index(request: web.Request) -> web.Response:
        return web.Response(text=MINI_APP_HTML, content_type="text/html", charset="utf-8", headers={"Cache-Control": "no-store"})

    async def handle_health(request: web.Request) -> web.Response:
        return web.json_response({"ok": True, "service": "cfhub_miniapp", "v": CURRENT_WORKER_VERSION})

    # ==================== AUTO-UPDATING SUBSCRIPTION ENDPOINT ====================
    async def handle_sub(request: web.Request) -> web.Response:
        uid = request.match_info.get("uid", "").strip()
        tok = request.query.get("t", "").strip()
        op = request.query.get("op", "mci").strip().lower()
        fmt = request.query.get("fmt", "b64").strip().lower()
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        panel = store.data.get("panels", {}).get(uid)
        if not panel or not tok or panel.get("sub_token") != tok:
            return web.Response(status=404, text="Subscription not found")

        ips = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 10), operator=op, count=3)
        if fmt == "json":
            arr = cf_service.build_fragment_json_bundle(panel, ips, operator=op)
            return web.Response(
                text=json.dumps(arr, ensure_ascii=False, indent=2),
                content_type="application/json",
                headers={"Profile-Update-Interval": "2", "Cache-Control": "no-store"},
            )

        ech_b64 = await fetch_live_cloudflare_ech_b64()
        p_v, p_t = await _probe_alt_ports(panel["host"], ips[1]["ip"], ips[1]["ip"])
        c6 = cf_service.build_six_ech_configs(panel, ips, operator=op, ech_b64=ech_b64, alt_port_vless=p_v, alt_port_trojan=p_t)
        raw_lines = "\n".join(c6[k] for k in ("vless_1", "vless_2", "vless_3", "trojan_1", "trojan_2", "trojan_3"))
        b64_payload = base64.b64encode(raw_lines.encode("utf-8")).decode("ascii")
        return web.Response(
            text=b64_payload,
            content_type="text/plain",
            headers={
                "Profile-Title": "CFHub Turbo V23",
                "Profile-Update-Interval": "2",
                "Cache-Control": "no-store",
            },
        )

    # ==================== V23 MINI APP BOOTSTRAP ====================
    async def handle_bootstrap(request: web.Request) -> web.Response:
        u = _auth_user(request)
        pools = store.data.get("operator_pools", {})
        pool_counts = {k: len(pools.get(k, [])) for k in ("mci", "mtn", "mkh")}
        ep4, ep6, wping = bg_engine.get_best_warp_endpoints()
        cfg = store.data["settings"]
        sup_u = str(cfg.get("support_username") or "").lstrip("@")
        sup_id = cfg.get("support_user_id") or (settings.owner_telegram_ids[0] if settings.owner_telegram_ids else 0)
        sup_url = f"https://t.me/{sup_u}" if sup_u else (f"tg://user?id={sup_id}" if sup_id else "")

        if not u:
            return web.json_response({
                "ok": True, "authenticated": False, "is_admin": False, "has_panel": False, "lang": "fa",
                "pools": pool_counts,
                "warp": {"ep4": ep4, "ep6": ep6, "ping": wping, "v4_count": len(store.data.get("warp_v4_pool", [])), "v6_count": len(store.data.get("warp_v6_pool", []))},
                "cf_token_url": CLOUDFLARE_DIRECT_TOKEN_URL, "support_url": sup_url,
            })

        uid = u["id"]
        if store.is_banned(uid) and not u["is_admin"]:
            return web.json_response({"ok": False, "error": "دسترسی شما مسدود شده است."}, status=403)
        if cfg.get("maintenance_mode") and not u["is_admin"]:
            return web.json_response({"ok": False, "error": "ربات موقتاً در حال به‌روزرسانی است."}, status=503)

        lock_res = await _check_locks_for(uid, u["is_admin"])
        if lock_res:
            return web.json_response({"ok": True, **lock_res})

        panel = store.data.get("panels", {}).get(str(uid))
        panel_out = None
        if panel:
            _ensure_sub_token(store, panel)
            panel_out = {
                "host": panel["host"],
                "engine": panel.get("engine", "pages"),
                "operator": panel.get("operator", "mci"),
                "proxy_ip": panel.get("proxy_ip", ""),
                "version": panel.get("worker_version", "v22"),
                "is_updated": bool(panel.get("worker_version") == CURRENT_WORKER_VERSION and panel.get("last_health_ok", False)),
            }

        return web.json_response({
            "ok": True, "authenticated": True, "is_admin": u["is_admin"], "has_panel": bool(panel),
            "lang": store.get_lang(uid), "panel": panel_out, "pools": pool_counts,
            "warp": {"ep4": ep4, "ep6": ep6, "ping": wping, "v4_count": len(store.data.get("warp_v4_pool", [])), "v6_count": len(store.data.get("warp_v6_pool", []))},
            "cf_token_url": CLOUDFLARE_DIRECT_TOKEN_URL, "support_url": sup_url,
        })

    async def handle_lock_verify(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "نیاز به باز کردن داخل تلگرام"}, status=401)
        cfg = store.data["settings"]
        if cfg.get("yt_lock_enabled"):
            store.set_yt_verified(u["id"], True)
        lock_res = await _check_locks_for(u["id"], u["is_admin"])
        return web.json_response({"ok": True, "unlocked": lock_res is None})

    async def handle_lang(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": True, "lang": "fa"})
        return web.json_response({"ok": True, "lang": store.toggle_lang(u["id"])})

    # ==================== USER PANEL APIs ====================
    async def handle_panel_configs(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "لطفاً مینی‌اپ را از داخل تلگرام باز کنید."}, status=401)
        uid = str(u["id"])
        op = request.query.get("op", "mci").strip().lower()
        rotate = request.query.get("rotate", "0") == "1"
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        panel = store.data.get("panels", {}).get(uid)
        if not panel:
            return web.json_response({"ok": False, "error": "پنل فعال یافت نشد."}, status=404)

        pool = bg_engine.get_best_operator_ips(op, 10)
        offset = int(panel.get(f"rot_{op}", 0)) % max(1, len(pool))
        if rotate:
            offset = (offset + 3) % max(1, len(pool))
            panel[f"rot_{op}"] = offset
        rotated = pool[offset:] + pool[:offset]

        ips = await cf_service.pick_best_verified_worker_ips(panel["host"], rotated, operator=op, count=3)
        panel["operator"] = op
        panel["clean_ip"] = ips[0]["ip"]
        sub_tok = _ensure_sub_token(store, panel)
        store.save()
        store.increment_stat(u["id"], "configs_generated")

        ech_b64 = await fetch_live_cloudflare_ech_b64()
        p_v, p_t = await _probe_alt_ports(panel["host"], ips[1]["ip"], ips[1]["ip"])
        c6 = cf_service.build_six_ech_configs(panel, ips, operator=op, ech_b64=ech_b64, alt_port_vless=p_v, alt_port_trojan=p_t)
        base_url = (store.data["settings"].get("webapp_url") or f"https://{request.host}").rstrip("/")
        return web.json_response({
            "ok": True,
            "configs": c6,
            "sub_url": f"{base_url}/sub/{uid}?op={op}&t={sub_tok}",
            "frag_sub_url": f"{base_url}/sub/{uid}?op={op}&t={sub_tok}&fmt=json",
        })

    async def handle_panel_deploy(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "نیاز به احراز هویت تلگرام"}, status=401)
        body = await request.json()
        raw_token = str(body.get("api_token", "")).strip()
        if len(raw_token) < 20 or " " in raw_token:
            return web.json_response({"ok": False, "error": "فرمت توکن کلودفلر نامعتبر است."}, status=400)

        uid_s = str(u["id"])
        old = store.data["panels"].get(uid_s) or {}
        panel_uuid = old.get("uuid") or str(uuid.uuid4())
        trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
        proj_name = old.get("project_name") or _new_neutral_name()
        proxy_ip = old.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.fxxk.dedyn.io")

        dep = await cf_service.deploy_dual_panel(
            api_token=raw_token, user_uuid=panel_uuid, trojan_password=trojan_pass,
            project_name=proj_name, proxy_ip=proxy_ip,
        )
        if not dep.ok:
            return web.json_response({"ok": False, "error": dep.error or "دیپلوی ناموفق بود"}, status=400)

        now = datetime.now(timezone.utc).isoformat()
        store.data["cf_accounts"][uid_s] = {
            "encrypted_token": store.encrypt_secret(raw_token),
            "account_id": dep.account_id, "account_name": dep.account_name, "connected_at": now,
        }
        op = old.get("operator", "mci")
        pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
        store.data["panels"][uid_s] = {
            "engine": dep.engine, "uuid": panel_uuid, "trojan_password": trojan_pass,
            "project_name": dep.project_name, "host": dep.worker_host, "sni": dep.worker_host,
            "fallback_host": dep.fallback_host, "operator": op, "clean_ip": pair[0]["ip"],
            "proxy_ip": proxy_ip, "auto_ip": True, "worker_version": CURRENT_WORKER_VERSION,
            "last_health_ok": bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified)),
            "sub_token": old.get("sub_token") or secrets.token_urlsafe(12),
            "created_at": old.get("created_at", now), "updated_at": now,
        }
        store.save()
        return web.json_response({"ok": True, "host": dep.worker_host})

    async def handle_panel_redeploy(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        uid_s = str(u["id"])
        cf = store.data["cf_accounts"].get(uid_s)
        panel = store.data["panels"].get(uid_s)
        if not cf or not panel:
            return web.json_response({"ok": False, "error": "اکانت کلودفلر یافت نشد."}, status=404)
        token = store.decrypt_secret(cf["encrypted_token"])
        dep = await cf_service.deploy_dual_panel(
            api_token=token, user_uuid=panel["uuid"], trojan_password=panel["trojan_password"],
            project_name=panel.get("project_name") or "", proxy_ip=panel.get("proxy_ip", "proxyip.fxxk.dedyn.io"),
            force_new_name=(panel.get("engine") != "pages"),
        )
        if not dep.ok:
            return web.json_response({"ok": False, "error": dep.error or "آپدیت ناموفق بود"}, status=400)
        panel["engine"] = dep.engine
        panel["project_name"] = dep.project_name
        panel["host"] = dep.worker_host
        panel["sni"] = dep.worker_host
        panel["worker_version"] = CURRENT_WORKER_VERSION
        panel["last_health_ok"] = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
        panel["updated_at"] = datetime.now(timezone.utc).isoformat()
        store.save()
        return web.json_response({"ok": True})

    async def handle_panel_test(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        panel = store.data["panels"].get(str(u["id"]))
        if not panel:
            return web.json_response({"ok": False, "error": "پنل یافت نشد."}, status=404)
        (h_ok, h_ms, h_m), (v_ok, v_ms, v_m), (t_ok, t_ms, t_m), (p_ok, p_ms, p_m) = await asyncio.gather(
            check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
            test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="www.gstatic.com"),
            test_worker_tunnel_e2e(panel["host"], None, "trojan", panel["trojan_password"], target_host="www.gstatic.com"),
            test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="cp.cloudflare.com"),
        )
        panel["last_health_ok"] = bool(h_ok and (v_ok or t_ok))
        store.save()
        return web.json_response({
            "ok": True,
            "health": {"ok": h_ok, "ms": h_ms, "msg": h_m},
            "vless": {"ok": v_ok, "ms": v_ms, "msg": v_m},
            "trojan": {"ok": t_ok, "ms": t_ms, "msg": t_m},
            "proxy": {"ok": p_ok, "ms": p_ms, "msg": p_m},
        })

    async def handle_panel_proxyip(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        body = await request.json()
        pip = str(body.get("proxy_ip", "")).strip()
        panel = store.data["panels"].get(str(u["id"]))
        if panel and pip:
            panel["proxy_ip"] = pip
            panel["last_health_ok"] = False
            store.save()
        return web.json_response({"ok": True})

    async def handle_panel_disconnect(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        uid_s = str(u["id"])
        store.data["cf_accounts"].pop(uid_s, None)
        store.data["panels"].pop(uid_s, None)
        store.save()
        return web.json_response({"ok": True})

    # ==================== WARP, IPS & SUPPORT APIs ====================
    async def handle_warp_generate(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "لطفاً از داخل تلگرام باز کنید"}, status=401)
        body = await request.json()
        ip_mode = body.get("ip_mode", "ipv6")
        platform = body.get("platform", "ios")
        if ip_mode not in ("ipv4", "ipv6", "dual"):
            ip_mode = "ipv6"
        if platform not in ("ios", "android", "windows"):
            platform = "ios"
        reg = await register_real_warp_device()
        if not reg.ok:
            return web.json_response({"ok": False, "error": reg.error or "خطا در ثبت WARP"}, status=502)
        ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
        bundle = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand="CFHub")
        store.increment_stat(u["id"], "warp_generated")
        return web.json_response({"ok": True, **bundle})

    async def handle_warp_scan(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        if not bg_engine.is_scanning:
            asyncio.create_task(bg_engine.run_warp_only_scan())
        return web.json_response({"ok": True})

    async def handle_ips(request: web.Request) -> web.Response:
        op = request.query.get("op", "mci").strip().lower()
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        return web.json_response({"ok": True, "ips": bg_engine.get_best_operator_ips(op, 12)})

    async def handle_support_ticket(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        body = await request.json()
        txt = str(body.get("text", "")).strip()
        if not txt:
            return web.json_response({"ok": False, "error": "متن خالی است"}, status=400)
        tno = len(store.data.get("support_tickets", [])) + 1
        store.data["support_tickets"].append({"id": tno, "user_id": u["id"], "text": txt, "at": datetime.now(timezone.utc).isoformat()})
        store.save()
        if bot is not None:
            for oid in admin_ids:
                try:
                    await bot.send_message(oid, f"📩 <b>تیکت #{tno} (مینی‌اپ)</b> از <a href='tg://user?id={u['id']}'>{html.escape(u['full_name'] or str(u['id']))}</a> (<code>{u['id']}</code>):\n{html.escape(txt)}", parse_mode="HTML")
                except Exception:
                    pass
        return web.json_response({"ok": True, "ticket_id": tno})

    # ==================== ADMIN APIs (STRICTLY ADMIN-ONLY VIA CRYPTOGRAPHIC INITDATA) ====================
    def _require_admin(request: web.Request) -> dict | None:
        u = _auth_user(request)
        if not u or not u["is_admin"]:
            return None
        return u

    async def handle_admin_overview(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        sys_h = collect_system_health()
        return web.json_response({
            "ok": True,
            "sys": sys_h,
            "counts": {"users": len(store.data.get("users", {})), "panels": len(store.data.get("panels", {}))},
            "scanner": {
                "is_scanning": bg_engine.is_scanning,
                "stage": bg_engine.current_stage,
                "progress_pct": bg_engine.progress_pct,
                "last_scan_at": bg_engine.last_scan_at,
            },
            "settings": store.data.get("settings", {}),
            "tickets": store.data.get("support_tickets", [])[-20:],
        })

    async def handle_admin_scan(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        mode = body.get("mode", "full")
        if bg_engine.is_scanning:
            return web.json_response({"ok": False, "error": "اسکن هم‌اکنون در حال اجراست"}, status=409)
        if mode == "warp":
            asyncio.create_task(bg_engine.run_warp_only_scan())
        else:
            asyncio.create_task(bg_engine.run_full_cycle(trigger="miniapp_admin"))
        return web.json_response({"ok": True})

    async def handle_admin_ips(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        op = body.get("operator", "mci")
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        raw = str(body.get("ips", ""))
        added = 0
        for item in raw.replace(",", " ").split():
            ip_s = item.strip()
            if not is_restricted_1034_ip(ip_s) and ip_s not in store.data["manual_operator_ips"][op]:
                store.data["manual_operator_ips"][op].append(ip_s)
                added += 1
        store.save()
        if added and not bg_engine.is_scanning:
            asyncio.create_task(bg_engine.run_full_cycle(trigger=f"miniapp_manual_{op}"))
        return web.json_response({"ok": True, "added": added})

    async def handle_admin_users(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        q = request.query.get("q", "").strip().lstrip("@").lower()
        page = int(request.query.get("page", "0") or 0)
        all_u = sorted(store.data.get("users", {}).values(), key=lambda x: x.get("last_seen", ""), reverse=True)
        if q:
            all_u = [u for u in all_u if q in str(u.get("telegram_id", "")) or q in str(u.get("username", "")).lower() or q in str(u.get("full_name", "")).lower()]
        chunk = all_u[page * 12 : (page + 1) * 12]
        panels = store.data.get("panels", {})
        out = []
        for u in chunk:
            tid = str(u["telegram_id"])
            p = panels.get(tid)
            out.append({**u, "has_panel": bool(p), "panel_host": p["host"] if p else ""})
        return web.json_response({"ok": True, "users": out, "total": len(all_u)})

    async def handle_admin_user_action(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        tid = int(body.get("target_id", 0))
        action = body.get("action", "")
        if action == "toggle_ban" and tid not in admin_ids:
            store.set_ban(tid, not store.is_banned(tid))
        elif action == "reset_panel":
            store.data["cf_accounts"].pop(str(tid), None)
            store.data["panels"].pop(str(tid), None)
            store.save()
        return web.json_response({"ok": True})

    async def handle_admin_dm(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        if bot is None:
            return web.json_response({"ok": False, "error": "Bot instance unavailable"}, status=503)
        body = await request.json()
        tid = int(body.get("target_id", 0))
        txt = str(body.get("text", "")).strip()
        await bot.send_message(tid, f"📩 <b>پیام مدیریت:</b>\n\n{html.escape(txt)}", parse_mode="HTML")
        return web.json_response({"ok": True})

    async def handle_admin_settings(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        allowed = (
            "tg_lock_enabled", "tg_lock_channel", "tg_lock_text",
            "yt_lock_enabled", "yt_lock_url", "yt_lock_text",
            "auto_scan_enabled", "maintenance_mode",
            "support_username", "webapp_url", "default_proxy_ip",
        )
        for k in allowed:
            if k in body:
                store.data["settings"][k] = body[k]
        store.save()
        return web.json_response({"ok": True})

    async def handle_admin_broadcast(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        if bot is None:
            return web.json_response({"ok": False, "error": "Bot unavailable"}, status=503)
        body = await request.json()
        txt = str(body.get("text", "")).strip()
        sent, failed = 0, 0
        for uid_s in list(store.data.get("users", {}).keys()):
            try:
                await bot.send_message(int(uid_s), f"📢 <b>اطلاعیه:</b>\n\n{html.escape(txt)}", parse_mode="HTML")
                sent += 1
                await asyncio.sleep(0.04)
            except Exception:
                failed += 1
        return web.json_response({"ok": True, "sent": sent, "failed": failed})

    # Routes
    app.router.add_get("/", handle_index)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/sub/{uid}", handle_sub)
    app.router.add_get("/api/v23/bootstrap", handle_bootstrap)
    app.router.add_post("/api/v23/lock/verify", handle_lock_verify)
    app.router.add_post("/api/v23/lang", handle_lang)
    app.router.add_get("/api/v23/panel/configs", handle_panel_configs)
    app.router.add_post("/api/v23/panel/deploy", handle_panel_deploy)
    app.router.add_post("/api/v23/panel/redeploy", handle_panel_redeploy)
    app.router.add_post("/api/v23/panel/test", handle_panel_test)
    app.router.add_post("/api/v23/panel/proxyip", handle_panel_proxyip)
    app.router.add_post("/api/v23/panel/disconnect", handle_panel_disconnect)
    app.router.add_post("/api/v23/warp/generate", handle_warp_generate)
    app.router.add_post("/api/v23/warp/scan", handle_warp_scan)
    app.router.add_get("/api/v23/ips", handle_ips)
    app.router.add_post("/api/v23/support/ticket", handle_support_ticket)
    app.router.add_get("/api/v23/admin/overview", handle_admin_overview)
    app.router.add_post("/api/v23/admin/scan", handle_admin_scan)
    app.router.add_post("/api/v23/admin/ips", handle_admin_ips)
    app.router.add_get("/api/v23/admin/users", handle_admin_users)
    app.router.add_post("/api/v23/admin/user/action", handle_admin_user_action)
    app.router.add_post("/api/v23/admin/user/dm", handle_admin_dm)
    app.router.add_post("/api/v23/admin/settings", handle_admin_settings)
    app.router.add_post("/api/v23/admin/broadcast", handle_admin_broadcast)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    logger.info("V23 iOS Minimalist Mini App listening on http://0.0.0.0:%s", port)
    return runner
