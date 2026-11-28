from __future__ import annotations

import asyncio
import html
import logging
import secrets
import uuid
from datetime import datetime, timezone

from aiogram import Bot, Dispatcher, F, Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BufferedInputFile, CallbackQuery, Message

from app.bot.bg_engine import BackgroundScannerEngine
from app.bot.cf_manager import CloudflarePanelService, _new_neutral_name, fetch_live_cloudflare_ech_b64
from app.bot.i18n import op_label, tr
from app.bot.operator_scanner import OPERATOR_LABELS, is_restricted_1034_ip
from app.bot.store import PersistentHubStore
from app.bot.ui import (
    CLOUDFLARE_DIRECT_TOKEN_URL,
    CLOUDFLARE_SIGNUP_URL,
    back_home_kb,
    btn,
    kb,
    main_menu_kb,
)
from app.bot.warp_builder import build_warp_bundle, register_real_warp_device
from app.bot.webapp import start_mini_app_server
from app.bot.worker_template import CURRENT_WORKER_VERSION
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.services.monitoring import collect_system_health

logger = logging.getLogger(__name__)
router = Router()

store = PersistentHubStore()
bg_engine = BackgroundScannerEngine(store)
cf_service = CloudflarePanelService()
_redeploy_locks: set[int] = set()
_webapp_runner = None


class Flow(StatesGroup):
    waiting_cf_token = State()
    waiting_panel_proxyip = State()
    waiting_support_msg = State()
    adm_import_op_ips = State()
    adm_user_search = State()
    adm_dm_text = State()
    adm_broadcast = State()
    adm_set_support = State()
    adm_set_tg_channel = State()
    adm_set_tg_text = State()
    adm_set_yt_url = State()
    adm_set_yt_text = State()
    adm_set_webapp_url = State()


def _is_admin(tg_id: int) -> bool:
    return tg_id in set(get_settings().owner_telegram_ids)


def _has_panel(tg_id: int) -> bool:
    return str(tg_id) in store.data.get("panels", {})


def _is_panel_updated(panel: dict) -> bool:
    return panel.get("worker_version") == CURRENT_WORKER_VERSION and bool(panel.get("last_health_ok", False))


def _progress_bar(pct: int) -> str:
    filled = max(0, min(10, pct // 10))
    return f"[{'█' * filled}{'░' * (10 - filled)}] {pct}%"


async def _check_access_locks(bot: Bot, tg_id: int) -> tuple[bool, str, object | None]:
    if _is_admin(tg_id):
        return True, "", None
    cfg = store.data["settings"]
    if cfg.get("tg_lock_enabled") and cfg.get("tg_lock_channel"):
        chan = str(cfg["tg_lock_channel"]).strip()
        chat_id = int(chan) if (chan.startswith("-") and chan[1:].isdigit()) else (chan if chan.startswith("@") else f"@{chan}")
        is_member = False
        try:
            mem = await bot.get_chat_member(chat_id=chat_id, user_id=tg_id)
            is_member = mem.status in ("member", "administrator", "creator")
        except Exception:
            is_member = False
        if not is_member:
            join_url = f"https://t.me/{chan.lstrip('@')}" if not chan.startswith("-") else None
            rows = []
            if join_url:
                rows.append([btn("📢 عضویت در کانال / Join Channel", url=join_url, style="primary")])
            rows.append([btn("🔄 بررسی عضویت / Verify", callback_data="lock:check", style="success")])
            return False, f"🔒 <b>Channel Lock</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('tg_lock_text', ''))}", kb(rows)

    if cfg.get("yt_lock_enabled") and not store.is_yt_verified(tg_id):
        yt_url = str(cfg.get("yt_lock_url") or "https://youtube.com").strip()
        if not yt_url.startswith("http"):
            yt_url = "https://" + yt_url
        rows = [
            [btn("▶️ YouTube Channel", url=yt_url, style="danger")],
            [btn("✅ تایید عضویت / Confirm", callback_data="lock:yt_confirm", style="success")],
        ]
        return False, f"🎬 <b>YouTube Support</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('yt_lock_text', ''))}", kb(rows)
    return True, "", None


async def _safe_answer(cb: CallbackQuery, text: str | None = None, show_alert: bool = False) -> None:
    try:
        await cb.answer(text=text, show_alert=show_alert)
    except Exception:
        pass


async def _edit(cb: CallbackQuery, text: str, markup) -> None:
    if not cb.message:
        return
    try:
        await cb.message.edit_text(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)
    except TelegramBadRequest as exc:
        if "message is not modified" in str(exc).lower():
            return
        try:
            await cb.message.answer(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)
        except Exception:
            pass
    except Exception:
        try:
            await cb.message.answer(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)
        except Exception:
            pass


def _home_text(tg_id: int) -> str:
    lang = store.get_lang(tg_id)
    pools = store.data.get("operator_pools", {})
    panel = store.data.get("panels", {}).get(str(tg_id))
    if panel:
        st_lbl = tr(lang, "home_panel_ok") if _is_panel_updated(panel) else tr(lang, "home_panel_upd")
        panel_line = f"{tr(lang, 'home_panel_line', status=st_lbl)} (<code>{html.escape(panel['host'])}</code>)"
    else:
        panel_line = tr(lang, "home_panel_line", status=tr(lang, "home_panel_none"))
    return (
        f"{tr(lang, 'home_title')}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{tr(lang, 'home_pools', mci=len(pools.get('mci', [])), mtn=len(pools.get('mtn', [])), mkh=len(pools.get('mkh', [])))}\n"
        f"{tr(lang, 'home_warp', v4=len(store.data.get('warp_v4_pool', [])), v6=len(store.data.get('warp_v6_pool', [])))}\n"
        f"{panel_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{tr(lang, 'home_pick')}"
    )


@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    u = message.from_user
    if not u:
        return
    store.touch_user(u.id, u.username, u.full_name)
    lang = store.get_lang(u.id)
    if store.is_banned(u.id) and not _is_admin(u.id):
        await message.answer(tr(lang, "banned"))
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(u.id):
        await message.answer(tr(lang, "maintenance"))
        return
    ok_lock, lock_txt, lock_kb = await _check_access_locks(message.bot, u.id)
    if not ok_lock:
        await message.answer(lock_txt, reply_markup=lock_kb, parse_mode="HTML")
        return
    await message.answer(
        _home_text(u.id),
        reply_markup=main_menu_kb(_is_admin(u.id), _has_panel(u.id), lang, store.data["settings"].get("webapp_url", "")),
        parse_mode="HTML",
    )


@router.message(Command("admin"))
async def cmd_admin(message: Message, state: FSMContext) -> None:
    await state.clear()
    if not message.from_user or not _is_admin(message.from_user.id):
        return
    t, m = _build_admin_dashboard()
    await message.answer(t, reply_markup=m, parse_mode="HTML")


@router.callback_query(F.data == "lock:check")
async def cb_lock_check(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    ok_lock, lock_txt, lock_kb = await _check_access_locks(cb.bot, uid)
    if not ok_lock:
        await _safe_answer(cb, "⚠️ Not verified yet.", show_alert=True)
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ Verified!", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


@router.callback_query(F.data == "lock:yt_confirm")
async def cb_lock_yt_confirm(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.set_yt_verified(uid, True)
    ok_lock, lock_txt, lock_kb = await _check_access_locks(cb.bot, uid)
    if not ok_lock:
        await _safe_answer(cb, "✅")
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ Unlocked!", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


@router.callback_query(F.data == "m:home")
async def cb_home(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    uid = cb.from_user.id
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


@router.callback_query(F.data == "m:lang")
async def cb_lang(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.toggle_lang(uid)
    await _safe_answer(cb, "English" if lang == "en" else "فارسی")
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), lang, store.data["settings"].get("webapp_url", "")))


# ==================== 1. PANEL DEPLOY (PROXYIP OFF BY DEFAULT!) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    await state.set_state(Flow.waiting_cf_token)
    text = f"{tr(lang, 'turbo_title')}\n━━━━━━━━━━━━━━━━━━━━\n{tr(lang, 'turbo_body')}"
    rows = [
        [btn(tr(lang, "btn_get_token"), url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
        [btn(tr(lang, "btn_cf_signup"), url=CLOUDFLARE_SIGNUP_URL, style="primary")],
    ]
    if _has_panel(uid):
        rows.append([btn(tr(lang, "btn_my_panel"), callback_data="m:mypanel", style="primary")])
    rows.append([btn(tr(lang, "btn_back"), callback_data="m:home", style="danger")])
    await _edit(cb, text, kb(rows))


@router.message(Flow.waiting_cf_token)
async def handle_cf_token(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    lang = store.get_lang(uid)
    raw_token = (message.text or "").strip()
    try:
        await message.delete()
    except Exception:
        pass

    if len(raw_token) < 20 or " " in raw_token:
        await message.answer(
            tr(lang, "bad_token"),
            reply_markup=kb([
                [btn(tr(lang, "btn_get_token"), url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn(tr(lang, "btn_cancel"), callback_data="m:home", style="danger")],
            ]),
        )
        return

    wait_msg = await message.answer(tr(lang, "deploying"), parse_mode="HTML")
    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    proj_name = old.get("project_name") or _new_neutral_name()

    # Deploy clean DIRECT worker (ProxyIP OFF by default!)
    dep = await cf_service.deploy_dual_panel(
        api_token=raw_token, user_uuid=panel_uuid, trojan_password=trojan_pass,
        project_name=proj_name, proxy_ip="",
    )
    if not dep.ok:
        await wait_msg.edit_text(
            f"{tr(lang, 'deploy_fail')}\n<code>{html.escape(dep.error or '')}</code>",
            parse_mode="HTML",
            reply_markup=kb([
                [btn(tr(lang, "btn_get_token"), url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn(tr(lang, "btn_cancel"), callback_data="m:home", style="danger")],
            ]),
        )
        return

    now = datetime.now(timezone.utc).isoformat()
    store.data["cf_accounts"][str(uid)] = {
        "encrypted_token": store.encrypt_secret(raw_token),
        "account_id": dep.account_id, "account_name": dep.account_name, "connected_at": now,
    }
    op = old.get("operator", "mci")
    pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
    is_healthy = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
    store.data["panels"][str(uid)] = {
        "engine": dep.engine, "uuid": panel_uuid, "trojan_password": trojan_pass,
        "project_name": dep.project_name, "host": dep.worker_host, "sni": dep.worker_host,
        "fallback_host": dep.fallback_host, "operator": op, "clean_ip": pair[0]["ip"],
        "proxy_ip_enabled": False, "proxy_ip_mode": "off", "proxy_ip": "",
        "auto_ip": True, "worker_version": CURRENT_WORKER_VERSION, "last_health_ok": is_healthy,
        "sub_token": old.get("sub_token") or secrets.token_urlsafe(12),
        "created_at": old.get("created_at", now), "updated_at": now,
    }
    store.save()
    await state.clear()

    v_badge = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:80])}"
    t_badge = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:80])}"
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"{tr(lang, 'deploy_ok', engine=dep.engine.upper())}\n"
        f"🔷 VLESS: <b>{v_badge}</b> | 🔐 Trojan: <b>{t_badge}</b>\n\n{text}",
        parse_mode="HTML", reply_markup=markup,
    )


# ==================== 2. MY PANEL + OPTIONAL PROXYIP MENU ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    lang = store.get_lang(uid)
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return (
            tr(lang, "panel_empty"),
            kb([
                [btn(tr(lang, "btn_create_panel"), callback_data="m:turbo", style="success")],
                [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
            ]),
        )

    op = panel.get("operator", "mci")
    engine_lbl = "Cloudflare Pages" if panel.get("engine") == "pages" else "Cloudflare Workers"
    updated = _is_panel_updated(panel)
    eff_px, px_mode = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
    if not panel.get("proxy_ip_enabled", False):
        px_line = tr(lang, "panel_proxy_off")
        px_st = tr(lang, "st_off")
    elif px_mode == "auto":
        px_line = tr(lang, "panel_proxy_auto", val=html.escape(eff_px))
        px_st = tr(lang, "st_on")
    else:
        px_line = tr(lang, "panel_proxy_on", val=html.escape(eff_px))
        px_st = tr(lang, "st_on")

    ver_line = tr(lang, "panel_ver_ok", ver=CURRENT_WORKER_VERSION.upper()) if updated else tr(lang, "panel_ver_old")
    update_btn = (
        btn(tr(lang, "btn_updated"), callback_data="cf:up_to_date", style="success")
        if updated else btn(tr(lang, "btn_update"), callback_data="cf:redeploy", style="danger")
    )

    text = (
        f"{tr(lang, 'panel_title')}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{tr(lang, 'panel_engine', engine=engine_lbl)}\n"
        f"{tr(lang, 'panel_domain', host=html.escape(panel['host']))}\n"
        f"{tr(lang, 'panel_op', op=op_label(op, lang))}\n"
        f"{px_line}\n"
        f"{ver_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{tr(lang, 'panel_pick_op')}"
    )
    markup = kb([
        [
            btn(op_label("mci", lang), callback_data="cf:getop:mci", style="success"),
            btn(op_label("mtn", lang), callback_data="cf:getop:mtn", style="success"),
            btn(op_label("mkh", lang), callback_data="cf:getop:mkh", style="success"),
        ],
        [
            btn(tr(lang, "btn_e2e"), callback_data="cf:e2e_test", style="primary"),
            update_btn,
        ],
        [
            btn(tr(lang, "btn_proxy_menu", st=px_st), callback_data="cf:proxy_menu", style="primary"),
            btn(tr(lang, "btn_disconnect"), callback_data="cf:disconnect", style="danger"),
        ],
        [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
    ])
    return text, markup


def _render_proxy_menu(uid: int) -> tuple[str, object]:
    lang = store.get_lang(uid)
    panel = store.data["panels"].get(str(uid)) or {}
    eff_px, px_mode = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
    cur_line = (
        tr(lang, "panel_proxy_off") if not panel.get("proxy_ip_enabled", False)
        else (tr(lang, "panel_proxy_auto", val=html.escape(eff_px)) if px_mode == "auto" else tr(lang, "panel_proxy_on", val=html.escape(eff_px)))
    )
    text = (
        f"{tr(lang, 'proxy_title')}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"{cur_line}\n\n"
        f"{tr(lang, 'proxy_desc')}\n\n"
        f"📋 {tr(lang, 'proxy_list_lbl')}"
    )
    rows = [
        [btn(tr(lang, "btn_proxy_disable"), callback_data="cf:px:off", style="success" if not panel.get("proxy_ip_enabled", False) else "primary")],
        [btn(tr(lang, "btn_proxy_auto"), callback_data="cf:px:auto", style="success" if (panel.get("proxy_ip_enabled") and px_mode == "auto") else "primary")],
    ]
    pool = bg_engine.get_proxy_ip_pool()[:6]
    for i in range(0, len(pool), 2):
        row = []
        for idx in range(i, min(i + 2, len(pool))):
            it = pool[idx]
            ms = f" ({int(round(it['latency_ms']))}ms)" if it.get("latency_ms") else ""
            short = it["proxy_ip"].replace("proxyip.", "")[:18]
            row.append(btn(f"🌐 {short}{ms}", callback_data=f"cf:px:idx:{idx}", style="primary"))
        rows.append(row)
    rows.append([btn(tr(lang, "btn_proxy_custom"), callback_data="cf:edit_proxyip", style="primary")])
    rows.append([btn(tr(lang, "btn_back"), callback_data="m:mypanel", style="danger")])
    return text, kb(rows)


@router.callback_query(F.data == "cf:proxy_menu")
async def cb_cf_proxy_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    t, m = _render_proxy_menu(cb.from_user.id)
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("cf:px:"))
async def cb_cf_px_set(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    panel = store.data["panels"].get(str(uid))
    if not panel:
        await _safe_answer(cb)
        return
    parts = cb.data.split(":")
    action = parts[2]
    if action == "off":
        panel["proxy_ip_enabled"] = False
        panel["proxy_ip_mode"] = "off"
        store.save()
        await _safe_answer(cb, tr(lang, "proxy_saved_off"), show_alert=True)
    elif action == "auto":
        panel["proxy_ip_enabled"] = True
        panel["proxy_ip_mode"] = "auto"
        store.save()
        await _safe_answer(cb, tr(lang, "proxy_saved_auto"), show_alert=True)
    elif action == "idx" and len(parts) >= 4:
        pool = bg_engine.get_proxy_ip_pool()
        idx = int(parts[3])
        if 0 <= idx < len(pool):
            val = pool[idx]["proxy_ip"]
            panel["proxy_ip_enabled"] = True
            panel["proxy_ip_mode"] = "list"
            panel["proxy_ip"] = val
            store.save()
            await _safe_answer(cb, tr(lang, "proxy_saved_val", val=val), show_alert=True)
    t, m = _render_proxy_menu(uid)
    await _edit(cb, t, m)


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    t, m = _render_personal_panel(cb.from_user.id)
    await _edit(cb, t, m)


@router.callback_query(F.data == "cf:up_to_date")
async def cb_cf_up_to_date(cb: CallbackQuery) -> None:
    lang = store.get_lang(cb.from_user.id)
    await _safe_answer(cb, tr(lang, "up_to_date_alert", ver=CURRENT_WORKER_VERSION.upper()), show_alert=True)


@router.callback_query(F.data.startswith("cf:getop:"))
async def cb_cf_get_by_op(cb: CallbackQuery) -> None:
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, "⏳...")

    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)
    if not panel.get("sub_token"):
        panel["sub_token"] = secrets.token_urlsafe(12)

    pool = bg_engine.get_best_operator_ips(op, 8)
    offset = int(panel.get(f"rot_{op}", 0)) % max(1, len(pool))
    rotated = pool[offset:] + pool[:offset]
    panel[f"rot_{op}"] = offset + 2

    verified_ips = await cf_service.pick_best_verified_worker_ips(panel["host"], rotated, operator=op, count=3)
    panel["operator"] = op
    panel["clean_ip"] = verified_ips[0]["ip"]
    store.save()
    store.increment_stat(uid, "configs_generated")

    eff_px, px_mode = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
    ech_b64 = await fetch_live_cloudflare_ech_b64()
    (ok_v2, _, _), (ok_t2, _, _) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], verified_ips[1]["ip"], 2083, timeout_sec=2.5),
        check_ip_routes_worker(panel["host"], verified_ips[1]["ip"], 8443, timeout_sec=2.5),
    )
    c6 = cf_service.build_six_ech_configs(
        panel, verified_ips, operator=op, ech_b64=ech_b64,
        alt_port_vless=(2083 if ok_v2 else 443), alt_port_trojan=(8443 if ok_t2 else 443),
        effective_proxy_ip=eff_px,
    )
    op_lbl = op_label(op, lang)
    px_desc = tr(lang, "st_off") if not eff_px else f"{eff_px} ({px_mode})"
    wurl = (store.data["settings"].get("webapp_url") or "https://app.prostoreshop.site").rstrip("/")
    sub_line = f"\n{tr(lang, 'cfg_sub_title')}\n<code>{wurl}/sub/{uid}?op={op}&amp;t={panel['sub_token']}</code>\n" if wurl.startswith("https://") else ""

    msg = (
        f"{tr(lang, 'cfg_title', op=op_lbl)}\n"
        f"{tr(lang, 'cfg_proxy_line', mode=html.escape(px_desc))}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 <b>VLESS #1 (Turbo-TLS)</b>\n<blockquote><code>{html.escape(c6['vless_1'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #2 (Fast-Alt)</b>\n<blockquote><code>{html.escape(c6['vless_2'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #3 (ECH-Shield)</b>\n<blockquote><code>{html.escape(c6['vless_3'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #1 (Turbo-TLS)</b>\n<blockquote><code>{html.escape(c6['trojan_1'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #2 (Fast-Alt)</b>\n<blockquote><code>{html.escape(c6['trojan_2'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #3 (ECH-Shield)</b>\n<blockquote><code>{html.escape(c6['trojan_3'])}</code></blockquote>\n"
        f"━━━━━━━━━━━━━━━━━━━━{sub_line}"
        f"{tr(lang, 'cfg_note')}"
    )
    await _edit(
        cb, msg,
        kb([
            [btn(tr(lang, "btn_rotate_ips", op=op_lbl), callback_data=f"cf:getop:{op}", style="success")],
            [btn(tr(lang, "btn_proxy_menu", st=tr(lang, "st_on") if eff_px else tr(lang, "st_off")), callback_data="cf:proxy_menu", style="primary")],
            [btn(tr(lang, "btn_my_panel"), callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:e2e_test")
async def cb_cf_e2e_test(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, "🩺...")
    wait = await cb.message.answer("⏳ Testing Health, VLESS & Trojan...")
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    op = panel.get("operator", "mci")
    if is_restricted_1034_ip(panel.get("clean_ip", "")):
        pair = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 8), operator=op)
        panel["clean_ip"] = pair[0]["ip"]
        store.save()

    (h_ok, h_ms, h_msg), (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "trojan", panel["trojan_password"], target_host="www.gstatic.com"),
    )
    all_good = bool(h_ok and v_ok and t_ok)
    panel["last_health_ok"] = all_good
    store.save()

    h_l = f"🟢 <b>OK</b> ({h_ms}ms)" if h_ok else f"🔴 <b>ERR</b> ({html.escape(h_msg[:80])})"
    v_l = f"🟢 <b>OK</b> ({v_ms}ms)" if v_ok else f"🔴 <b>ERR</b> ({html.escape(v_msg[:95])})"
    t_l = f"🟢 <b>OK</b> ({t_ms}ms)" if t_ok else f"🔴 <b>ERR</b> ({html.escape(t_msg[:95])})"

    rows = []
    if not all_good:
        rows.append([btn(tr(lang, "btn_update"), callback_data="cf:redeploy", style="danger")])
    rows.append([btn(tr(lang, "btn_my_panel"), callback_data="m:mypanel", style="primary")])

    await wait.edit_text(
        f"🩺 <b>E2E Health ({CURRENT_WORKER_VERSION.upper()})</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📡 <code>{html.escape(panel['host'])}</code>\n"
        f"🌐 Clean IP (<code>{html.escape(panel['clean_ip'])}</code>): {h_l}\n"
        f"🔷 VLESS: {v_l}\n"
        f"🔐 Trojan: {t_l}",
        parse_mode="HTML", reply_markup=kb(rows),
    )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    if uid in _redeploy_locks:
        await _safe_answer(cb, "⏳ Updating...", show_alert=True)
        return
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await _safe_answer(cb, "⚠️ Account not found.", show_alert=True)
        return

    _redeploy_locks.add(uid)
    try:
        await _safe_answer(cb, "🔄 Updating to V24...")
        await _edit(cb, tr(lang, "deploying"), kb([[btn("⏳...", callback_data="cf:noop", style="primary")]]))
        try:
            token = store.decrypt_secret(cf["encrypted_token"])
        except Exception:
            await _edit(cb, "❌ Re-connect Cloudflare token.", back_home_kb("m:turbo", lang))
            return
        if not panel.get("trojan_password"):
            panel["trojan_password"] = secrets.token_urlsafe(12)

        dep = await cf_service.deploy_dual_panel(
            api_token=token, user_uuid=panel["uuid"], trojan_password=panel["trojan_password"],
            project_name=panel.get("project_name") or panel.get("script_name") or "", proxy_ip="",
            force_new_name=(panel.get("engine") != "pages"),
        )
        if dep.ok:
            op = panel.get("operator", "mci")
            pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
            panel["engine"] = dep.engine
            panel["project_name"] = dep.project_name
            panel["host"] = dep.worker_host
            panel["sni"] = dep.worker_host
            panel["fallback_host"] = dep.fallback_host
            panel["clean_ip"] = pair[0]["ip"]
            panel["worker_version"] = CURRENT_WORKER_VERSION
            panel["last_health_ok"] = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
            panel["updated_at"] = datetime.now(timezone.utc).isoformat()
            store.save()
            text, markup = _render_personal_panel(uid)
            await _edit(cb, f"✅ <b>{CURRENT_WORKER_VERSION.upper()} Updated!</b>\n\n{text}", markup)
        else:
            await _edit(cb, f"{tr(lang, 'deploy_fail')}\n<code>{html.escape(dep.error or '')}</code>", back_home_kb("m:mypanel", lang))
    finally:
        _redeploy_locks.discard(uid)


@router.callback_query(F.data == "cf:noop")
async def cb_noop(cb: CallbackQuery) -> None:
    await _safe_answer(cb, "⏳...")


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    lang = store.get_lang(cb.from_user.id)
    await _safe_answer(cb)
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(cb, tr(lang, "proxy_ask_custom"), kb([[btn(tr(lang, "btn_cancel"), callback_data="cf:proxy_menu", style="danger")]]))


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    lang = store.get_lang(uid)
    pip = (message.text or "").strip()
    if str(uid) in store.data["panels"] and pip:
        p = store.data["panels"][str(uid)]
        p["proxy_ip_enabled"] = True
        p["proxy_ip_mode"] = "custom"
        p["proxy_ip"] = pip
        store.save()
    await state.clear()
    t, m = _render_proxy_menu(uid)
    await message.answer(f"{tr(lang, 'proxy_saved_val', val=html.escape(pip))}\n\n{t}", parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await _safe_answer(cb, tr(lang, "disconnect_ok"), show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, lang, store.data["settings"].get("webapp_url", "")))


# ==================== 3. WARP / WIREGUARD ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    ep4, ep6, _ = bg_engine.get_best_warp_endpoints()
    text = (
        f"{tr(lang, 'warp_title')}\n━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 IPv4: <code>{html.escape(ep4)}</code>\n🌐 IPv6: <code>{html.escape(ep6)}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n{tr(lang, 'warp_pick')}"
    )
    markup = kb([
        [btn(tr(lang, "btn_warp_v6"), callback_data="warp:mode:ipv6", style="success")],
        [btn(tr(lang, "btn_warp_dual"), callback_data="warp:mode:dual", style="primary")],
        [btn(tr(lang, "btn_warp_v4"), callback_data="warp:mode:ipv4", style="primary")],
        [btn(tr(lang, "btn_warp_scan"), callback_data="warp:scan_live", style="success")],
        [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "warp:scan_live")
async def cb_warp_scan_live(cb: CallbackQuery) -> None:
    lang = store.get_lang(cb.from_user.id)
    if bg_engine.is_scanning:
        await _safe_answer(cb, f"⏳ {bg_engine.progress_pct}%", show_alert=True)
        return
    await _safe_answer(cb, "🔍 Scanning WARP...")
    await _edit(cb, f"🔍 <b>WARP Scan</b>\n<code>{_progress_bar(10)}</code>", kb([[btn("⏳...", callback_data="cf:noop", style="primary")]]))

    async def _on_p(pct: int, msg: str) -> None:
        await _edit(cb, f"🔍 <b>WARP Scan</b>\n<code>{_progress_bar(pct)}</code>\n{html.escape(msg)}", kb([[btn(f"⏳ {pct}%", callback_data="cf:noop", style="primary")]]))

    res = await bg_engine.run_warp_only_scan(on_progress=_on_p)
    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    await _edit(
        cb,
        f"✅ <b>WARP Scan Complete!</b>\n<code>{_progress_bar(100)}</code>\n"
        f"IPv4: <code>{html.escape(ep4)}</code> ({res.get('warp_v4', 0)})\n"
        f"IPv6: <code>{html.escape(ep6)}</code> ({res.get('warp_v6', 0)}) | ⚡ {ping or 'Auto'}ms",
        kb([
            [btn(tr(lang, "btn_back"), callback_data="m:warp", style="success")],
            [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
        ]),
    )


@router.callback_query(F.data.startswith("warp:mode:"))
async def cb_warp_plat(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    mode = cb.data.split(":")[2]
    markup = kb([
        [btn(tr(lang, "btn_ios"), callback_data=f"warp:go:{mode}:ios", style="primary")],
        [btn(tr(lang, "btn_android"), callback_data=f"warp:go:{mode}:android", style="success")],
        [btn(tr(lang, "btn_windows"), callback_data=f"warp:go:{mode}:windows", style="primary")],
        [btn(tr(lang, "btn_back"), callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, f"🛡️ <b>WARP ({mode.upper()})</b>\n━━━━━━━━━━━━━━━━━━━━\n{tr(lang, 'warp_pick_os')}", markup)


@router.callback_query(F.data.startswith("warp:go:"))
async def cb_warp_go(cb: CallbackQuery) -> None:
    _, _, ip_mode, platform = cb.data.split(":")
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    await _safe_answer(cb, "⏳...")
    if not cb.message:
        return
    wait = await cb.message.answer("⏳ Registering real WARP key...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(f"❌ <code>{html.escape(reg.error or '')}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:warp", lang))
        return

    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand="CFHub")  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    try:
        await wait.delete()
    except Exception:
        pass

    txt = (
        f"✅ <b>WARP Ready</b> — <code>{html.escape(b['endpoint'])}</code>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>WARP Anti-DPI (Hiddify / Karing):</b>\n<blockquote><code>{html.escape(b['warp_auto_uri'])}</code></blockquote>\n\n"
        f"2️⃣ <b>WoW Double-Hop (Hiddify / Karing):</b>\n<blockquote><code>{html.escape(b['wow_uri'])}</code></blockquote>\n\n"
        f"3️⃣ <b>WireGuard QUIC Noise (v2rayNG / Streisand):</b>\n<blockquote><code>{html.escape(b['wireguard_uri'])}</code></blockquote>"
    )
    await cb.message.answer(txt, parse_mode="HTML")
    await cb.message.answer_document(
        document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
        caption=f"🛡️ <b>AmneziaWG ({ip_mode.upper()})</b>",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("🔄 New Key", callback_data=cb.data, style="success")],
            [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
        ]),
    )


# ==================== 4. CLEAN IPS, APPS, GUIDE, SUPPORT ====================
@router.callback_query(F.data == "m:isp")
async def cb_isp(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    pools = store.data.get("operator_pools", {})
    text = (
        f"{tr(lang, 'isp_title')}\n━━━━━━━━━━━━━━━━━━━━\n"
        f"{tr(lang, 'home_pools', mci=len(pools.get('mci', [])), mtn=len(pools.get('mtn', [])), mkh=len(pools.get('mkh', [])))}"
    )
    markup = kb([
        [btn(op_label("mci", lang), callback_data="isp:show:mci", style="primary")],
        [btn(op_label("mtn", lang), callback_data="isp:show:mtn", style="primary")],
        [btn(op_label("mkh", lang), callback_data="isp:show:mkh", style="success")],
        [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("isp:show:"))
async def cb_isp_show(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    op = cb.data.split(":")[2]
    ips = bg_engine.get_best_operator_ips(op, 10)
    lbl = op_label(op, lang)
    body = "\n".join(
        f"{i+1}. <code>{x['ip']}</code> | 🟢<b>{x.get('latency_ms') or 'Auto'}ms</b> | {x.get('colo', 'CF')}"
        for i, x in enumerate(ips)
    ) or "⏳..."
    rows = []
    if _has_panel(cb.from_user.id):
        rows.append([btn(tr(lang, "btn_get_6_op", op=lbl), callback_data=f"cf:getop:{op}", style="success")])
    rows.append([btn(tr(lang, "btn_back"), callback_data="m:isp", style="primary")])
    await _edit(cb, f"📶 <b>{lbl}</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    markup = kb([
        [btn("🔥 Hiddify (iOS / Android / Windows)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (WARP Anti-DPI)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (Android)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (iOS)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (Windows)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")],
    ])
    await _edit(cb, tr(lang, "apps_title"), markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    await _edit(cb, f"{tr(lang, 'guide_title')}\n━━━━━━━━━━━━━━━━━━━━\n{tr(lang, 'guide_body')}", back_home_kb("m:home", lang))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    cfg = store.data["settings"]
    sup_u = cfg.get("support_username", "").lstrip("@")
    sup_id = cfg.get("support_user_id") or (get_settings().owner_telegram_ids[0] if get_settings().owner_telegram_ids else 0)
    rows = []
    if sup_u:
        rows.append([btn(f"{tr(lang, 'btn_direct_chat')} (@{sup_u})", url=f"https://t.me/{sup_u}", style="success")])
        line = f"👤 @{html.escape(sup_u)}"
    elif sup_id:
        rows.append([btn(tr(lang, "btn_direct_chat"), url=f"tg://user?id={sup_id}", style="success")])
        line = f"👤 ID: <code>{sup_id}</code>"
    else:
        line = "👤 Online"
    rows.append([btn(tr(lang, "btn_send_ticket"), callback_data="sup:ticket", style="primary")])
    rows.append([btn(tr(lang, "btn_home"), callback_data="m:home", style="primary")])
    await _edit(cb, f"{tr(lang, 'support_title')}\n━━━━━━━━━━━━━━━━━━━━\n{line}", kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    lang = store.get_lang(cb.from_user.id)
    await state.set_state(Flow.waiting_support_msg)
    await _edit(cb, tr(lang, "ticket_prompt"), kb([[btn(tr(lang, "btn_cancel"), callback_data="m:support", style="danger")]]))


@router.message(Flow.waiting_support_msg)
async def handle_sup_msg(message: Message, state: FSMContext) -> None:
    u = message.from_user
    if not u:
        return
    lang = store.get_lang(u.id)
    tno = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({"id": tno, "user_id": u.id, "text": message.text or "", "at": datetime.now(timezone.utc).isoformat()})
    store.save()
    await state.clear()
    for oid in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(oid, f"📩 <b>Ticket #{tno}</b> from <a href='tg://user?id={u.id}'>{html.escape(u.full_name)}</a> (<code>{u.id}</code>):\n{html.escape(message.text or '')}", parse_mode="HTML")
        except Exception:
            pass
    await message.answer(tr(lang, "ticket_sent", id=tno), parse_mode="HTML", reply_markup=back_home_kb("m:home", lang))


# ==================== 5. ADMIN PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "-"

    text = (
        f"🛠️ <b>پنل مدیریت ({CURRENT_WORKER_VERSION.upper()})</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | <code>{last_s}</code>\n"
        f"📶 IP: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))} | 🔀Px:{len(store.data.get('proxy_ip_pool', []))}\n"
        f"🛡️ WARP: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [btn("▶️ اسکن کامل + WARP + ProxyIP", callback_data="adm:scan_now", style="success"), btn("🛡️ اسکن WARP", callback_data="warp:scan_live", style="primary")],
        [btn("🔵 IP همراه اول", callback_data="adm:addop:mci", style="primary"), btn("🟡 IP ایرانسل", callback_data="adm:addop:mtn", style="primary")],
        [btn("🟢 IP مخابرات", callback_data="adm:addop:mkh", style="success"), btn("👥 مدیریت کاربران", callback_data="adm:users:0", style="primary")],
        [btn("🔒 قفل تلگرام و یوتیوب", callback_data="adm:locks", style="primary")],
        [btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"), btn("⚙️ تنظیمات", callback_data="adm:settings", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="danger")],
    ])
    return text, markup


@router.callback_query(F.data == "adm:home")
async def cb_adm_home(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        await _safe_answer(cb)
        return
    await state.clear()
    await _safe_answer(cb)
    t, m = _build_admin_dashboard()
    await _edit(cb, t, m)


@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    if bg_engine.is_scanning:
        await _safe_answer(cb, f"⏳ {bg_engine.progress_pct}%", show_alert=True)
        return
    await _safe_answer(cb, "🚀 اسکن آغاز شد!")
    await _edit(cb, f"🔍 <b>اسکن زنده</b>\n<code>{_progress_bar(5)}</code>", kb([[btn("⏳...", callback_data="cf:noop", style="primary")]]))

    async def _on_prog(pct: int, stage_msg: str) -> None:
        await _edit(cb, f"🔍 <b>اسکن زنده</b>\n<code>{_progress_bar(pct)}</code>\n{html.escape(stage_msg)}", kb([[btn(f"⏳ {pct}%", callback_data="cf:noop", style="primary")]]))

    res = await bg_engine.run_full_cycle(trigger="admin_live", on_progress=_on_prog)
    await _edit(
        cb,
        f"✅ <b>اسکن کامل شد!</b>\n<code>{_progress_bar(100)}</code>\n"
        f"🔵 {res.get('mci', 0)} | 🟡 {res.get('mtn', 0)} | 🟢 {res.get('mkh', 0)} | 🛡️ {res.get('warp_v4', 0)}+{res.get('warp_v6', 0)}",
        kb([[btn("🔄 اسکن مجدد", callback_data="adm:scan_now", style="success")], [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")]]),
    )


@router.callback_query(F.data.startswith("adm:addop:"))
async def cb_adm_addop(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    op = cb.data.split(":")[2]
    await state.update_data(target_op=op)
    await state.set_state(Flow.adm_import_op_ips)
    await _edit(cb, f"➕ IPهای تمیز {OPERATOR_LABELS.get(op, op)} را ارسال کنید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_import_op_ips)
async def handle_adm_import_op(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    op = (await state.get_data()).get("target_op", "mci")
    added = 0
    for item in (message.text or "").replace(",", " ").split():
        ip_s = item.strip()
        if not is_restricted_1034_ip(ip_s) and ip_s not in store.data["manual_operator_ips"][op]:
            store.data["manual_operator_ips"][op].append(ip_s)
            added += 1
    store.save()
    await state.clear()
    asyncio.create_task(bg_engine.run_full_cycle(trigger=f"manual_{op}"))
    await message.answer(f"✅ +{added} IP اضافه شد.", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data.startswith("adm:users:"))
async def cb_adm_users(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    page = int(cb.data.split(":")[2])
    per_page = 6
    all_u = sorted(store.data.get("users", {}).values(), key=lambda x: x.get("last_seen", ""), reverse=True)
    chunk = all_u[page * per_page : (page + 1) * per_page]
    rows = []
    for u in chunk:
        uid = u["telegram_id"]
        b = "🚫" if u.get("is_banned") else ("🚀" if _has_panel(uid) else "👤")
        nm = f"@{u['username']}" if u.get("username") else (u.get("full_name") or str(uid))
        rows.append([btn(f"{b} {nm[:20]} | {uid}", callback_data=f"adm:uview:{uid}", style="primary")])
    nav = []
    if page > 0:
        nav.append(btn("⬅️", callback_data=f"adm:users:{page-1}", style="primary"))
    if (page + 1) * per_page < len(all_u):
        nav.append(btn("➡️", callback_data=f"adm:users:{page+1}", style="primary"))
    if nav:
        rows.append(nav)
    rows.append([btn("🔎 جستجو", callback_data="adm:usearch", style="success")])
    rows.append([btn("🔙 پنل مدیریت", callback_data="adm:home", style="danger")])
    await _edit(cb, f"👥 <b>کاربران ({len(all_u)})</b>", kb(rows))


def _render_user_card(target_uid: int) -> tuple[str, object]:
    u = store.data.get("users", {}).get(str(target_uid))
    if not u:
        return "❌ یافت نشد.", back_home_kb("adm:users:0")
    p = store.data.get("panels", {}).get(str(target_uid))
    txt = (
        f"👤 <code>{target_uid}</code> | {html.escape(u.get('full_name') or '-')} (@{html.escape(u.get('username') or '-')})\n"
        f"🚦 {'🚫 مسدود' if u.get('is_banned') else '🟢 فعال'} | 🚀 <code>{html.escape(p['host']) if p else '-'}</code>\n"
        f"📊 {u.get('configs_generated', 0)} Cfg • {u.get('warp_generated', 0)} WARP"
    )
    ban_b = btn("✅ رفع مسدودی", callback_data=f"adm:uban:{target_uid}", style="success") if u.get("is_banned") else btn("🚫 مسدود", callback_data=f"adm:uban:{target_uid}", style="danger")
    rows = [[ban_b, btn("✉️ پیام", callback_data=f"adm:udm:{target_uid}", style="primary")]]
    if p:
        rows.append([btn("🗑️ حذف پنل کاربر", callback_data=f"adm:ureset:{target_uid}", style="danger")])
    rows.append([btn("🔙 لیست", callback_data="adm:users:0", style="primary")])
    return txt, kb(rows)


@router.callback_query(F.data.startswith("adm:uview:"))
async def cb_adm_uview(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    t, m = _render_user_card(int(cb.data.split(":")[2]))
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:uban:"))
async def cb_adm_uban(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    tid = int(cb.data.split(":")[2])
    if not _is_admin(tid):
        store.set_ban(tid, not store.is_banned(tid))
    await _safe_answer(cb, "✅", show_alert=True)
    t, m = _render_user_card(tid)
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:ureset:"))
async def cb_adm_ureset(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    tid = int(cb.data.split(":")[2])
    store.data["cf_accounts"].pop(str(tid), None)
    store.data["panels"].pop(str(tid), None)
    store.save()
    await _safe_answer(cb, "🗑️", show_alert=True)
    t, m = _render_user_card(tid)
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:udm:"))
async def cb_adm_udm(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    tid = int(cb.data.split(":")[2])
    await state.update_data(dm_target=tid)
    await state.set_state(Flow.adm_dm_text)
    await _edit(cb, f"✉️ پیام برای <code>{tid}</code>:", kb([[btn("❌ انصراف", callback_data=f"adm:uview:{tid}", style="danger")]]))


@router.message(Flow.adm_dm_text)
async def handle_adm_dm(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    tid = int((await state.get_data()).get("dm_target", 0))
    await state.clear()
    try:
        await message.bot.send_message(tid, f"📩 <b>پیام مدیریت:</b>\n\n{html.escape(message.text or '')}", parse_mode="HTML")
        await message.answer("✅ ارسال شد.", reply_markup=back_home_kb(f"adm:uview:{tid}"))
    except Exception as exc:
        await message.answer(f"❌ {exc}", reply_markup=back_home_kb(f"adm:uview:{tid}"))


@router.callback_query(F.data == "adm:usearch")
async def cb_adm_usearch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_user_search)
    await _edit(cb, "🔎 آیدی یا <code>@username</code>:", kb([[btn("❌ انصراف", callback_data="adm:users:0", style="danger")]]))


@router.message(Flow.adm_user_search)
async def handle_adm_usearch(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    u = store.find_user(message.text or "")
    await state.clear()
    if not u:
        await message.answer("❌ یافت نشد.", reply_markup=back_home_kb("adm:users:0"))
        return
    t, m = _render_user_card(int(u["telegram_id"]))
    await message.answer(t, parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "adm:broadcast")
async def cb_adm_bc(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_broadcast)
    await _edit(cb, f"📢 متن پیام همگانی ({len(store.data.get('users', {}))}):", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_broadcast)
async def handle_adm_bc(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    txt = message.text or ""
    await state.clear()
    sent, fail = 0, 0
    for uid_s in list(store.data.get("users", {}).keys()):
        try:
            await message.bot.send_message(int(uid_s), f"📢 <b>اطلاعیه:</b>\n\n{html.escape(txt)}", parse_mode="HTML")
            sent += 1
            await asyncio.sleep(0.05)
        except Exception:
            fail += 1
    await message.answer(f"✅ موفق: {sent} | ❌ ناموفق: {fail}", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:settings")
async def cb_adm_settings(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID:{cfg.get('support_user_id')}"
    text = (
        f"⚙️ <b>تنظیمات</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 پشتیبانی: <b>{html.escape(str(sup))}</b>\n"
        f"🌐 مینی‌اپ: <code>{html.escape(str(cfg.get('webapp_url') or '-'))}</code>\n"
        f"🔄 اسکن: {'🟢' if cfg.get('auto_scan_enabled', True) else '🔴'} | 🛠️ تعمیرات: {'🔴' if cfg.get('maintenance_mode') else '🟢'}"
    )
    await _edit(cb, text, kb([
        [btn("🌐 لینک HTTPS مینی‌اپ", callback_data="adm:set_webapp", style="success")],
        [btn("💬 یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="primary")],
        [btn("🔄 اسکن خودکار", callback_data="adm:tog_scan", style="primary"), btn("🛠️ تعمیرات", callback_data="adm:tog_maint", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:tog_scan")
async def cb_adm_tog_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_scan_enabled"] = not bool(store.data["settings"].get("auto_scan_enabled", True))
    store.save()
    await _safe_answer(cb, "✅")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["maintenance_mode"] = not bool(store.data["settings"].get("maintenance_mode", False))
    store.save()
    await _safe_answer(cb, "✅")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_support)
    await _edit(cb, "💬 یوزرنیم پشتیبانی (مثال: <code>@YourID</code>):", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


@router.message(Flow.adm_set_support)
async def handle_adm_set_sup(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    uname = (message.text or "").strip().lstrip("@")
    store.data["settings"]["support_username"] = uname
    store.save()
    await state.clear()
    await message.answer(f"✅ @{html.escape(uname)}", reply_markup=back_home_kb("adm:settings"))


@router.callback_query(F.data == "adm:locks")
async def cb_adm_locks(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await state.clear()
    await _safe_answer(cb)
    cfg = store.data["settings"]
    tg_st = "🟢" if cfg.get("tg_lock_enabled") else "🔴"
    yt_st = "🟢" if cfg.get("yt_lock_enabled") else "🔴"
    text = (
        f"🔒 <b>قفل کانال‌ها</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"📢 تلگرام: {tg_st} <code>{html.escape(str(cfg.get('tg_lock_channel') or '-'))}</code>\n"
        f"🎬 یوتیوب: {yt_st} <code>{html.escape(str(cfg.get('yt_lock_url') or '-'))}</code>"
    )
    await _edit(cb, text, kb([
        [btn(f"📢 تلگرام {tg_st}", callback_data="adm:tog_tg_lock", style="success" if cfg.get("tg_lock_enabled") else "danger"),
         btn(f"🎬 یوتیوب {yt_st}", callback_data="adm:tog_yt_lock", style="success" if cfg.get("yt_lock_enabled") else "danger")],
        [btn("✏️ کانال تلگرام", callback_data="adm:set_tg_ch", style="primary"), btn("📝 متن تلگرام", callback_data="adm:set_tg_txt", style="primary")],
        [btn("🔗 لینک یوتیوب", callback_data="adm:set_yt_url", style="primary"), btn("📝 متن یوتیوب", callback_data="adm:set_yt_txt", style="primary")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:tog_tg_lock")
async def cb_adm_tog_tg_lock(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    cur = bool(store.data["settings"].get("tg_lock_enabled", False))
    if (not cur) and not store.data["settings"].get("tg_lock_channel"):
        await _safe_answer(cb, "⚠️ ابتدا کانال تلگرام را تنظیم کنید.", show_alert=True)
        return
    store.data["settings"]["tg_lock_enabled"] = not cur
    store.save()
    await _safe_answer(cb, "✅")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:tog_yt_lock")
async def cb_adm_tog_yt_lock(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["yt_lock_enabled"] = not bool(store.data["settings"].get("yt_lock_enabled", False))
    store.save()
    await _safe_answer(cb, "✅")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:set_tg_ch")
async def cb_adm_set_tg_ch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_channel)
    await _edit(cb, "📢 آیدی کانال (<code>@Channel</code> یا <code>-100...</code>):", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_channel)
async def handle_adm_set_tg_ch(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["tg_lock_channel"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_tg_txt")
async def cb_adm_set_tg_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_text)
    await _edit(cb, "📝 متن قفل تلگرام:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_text)
async def handle_adm_set_tg_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["tg_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_url")
async def cb_adm_set_yt_url(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_url)
    await _edit(cb, "🔗 لینک یوتیوب:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_url)
async def handle_adm_set_yt_url(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["yt_lock_url"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_txt")
async def cb_adm_set_yt_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_text)
    await _edit(cb, "📝 متن یوتیوب:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_text)
async def handle_adm_set_yt_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["yt_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_webapp")
async def cb_adm_set_webapp(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_webapp_url)
    await _edit(cb, "🌐 لینک HTTPS مینی‌اپ (مثال: <code>https://app.prostoreshop.site</code>):", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


@router.message(Flow.adm_set_webapp_url)
async def handle_adm_set_webapp(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    if val and not val.startswith("https://"):
        await message.answer("⚠️ باید با https:// شروع شود.")
        return
    store.data["settings"]["webapp_url"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ <code>{html.escape(val)}</code>", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))


# ==================== LIFECYCLE (24/7 SELF-HEALING) ====================
async def run_polling() -> None:
    global _webapp_runner
    configure_logging()
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required.")

    bot = Bot(token=settings.telegram_bot_token)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)

    bg_engine.start()
    try:
        _webapp_runner = await start_mini_app_server(store, bg_engine, cf_service, bot=bot, port=8080)
    except Exception as exc:
        logger.exception("Mini App server could not bind port 8080: %s", exc)

    backoff = 3
    try:
        while True:
            try:
                logger.info("Starting Cloudflare Config Hub V24 Pro Bot (Always-Alive).")
                await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types(), handle_signals=False)
                backoff = 3
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("Polling interrupted (%s) — reconnecting in %ss...", exc, backoff)
                await asyncio.sleep(backoff)
                backoff = min(30, backoff * 2)
    finally:
        await bg_engine.stop()
        if _webapp_runner is not None:
            await _webapp_runner.cleanup()
        try:
            await bot.session.close()
        except Exception:
            pass


if __name__ == "__main__":
    asyncio.run(run_polling())
