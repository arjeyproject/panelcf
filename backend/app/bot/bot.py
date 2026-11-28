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
    return (
        panel.get("worker_version") == CURRENT_WORKER_VERSION
        and bool(panel.get("last_health_ok", False))
    )




def _progress_bar(pct: int) -> str:
    filled = max(0, min(10, pct // 10))
    return f"[{'█' * filled}{'░' * (10 - filled)}] {pct}%"


async def _check_access_locks(bot: Bot, tg_id: int) -> tuple[bool, str, object | None]:
    """Enforces Real Telegram Channel Lock + Fake YouTube Channel Lock for non-admin users."""
    if _is_admin(tg_id):
        return True, "", None

    cfg = store.data["settings"]

    # 1) Real Telegram Channel Membership Check
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
                rows.append([btn("📢 عضویت در کانال تلگرام", url=join_url, style="primary")])
            rows.append([btn("🔄 بررسی عضویت", callback_data="lock:check", style="success")])
            txt = f"🔒 <b>قفل عضویت کانال تلگرام</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('tg_lock_text', ''))}"
            return False, txt, kb(rows)

    # 2) Fake YouTube Channel Lock (unlocks once user clicks confirm)
    if cfg.get("yt_lock_enabled") and not store.is_yt_verified(tg_id):
        yt_url = str(cfg.get("yt_lock_url") or "https://youtube.com").strip()
        if not yt_url.startswith("http"):
            yt_url = "https://" + yt_url
        rows = [
            [btn("▶️ ورود به کانال یوتیوب", url=yt_url, style="danger")],
            [btn("✅ عضو شدم / تایید", callback_data="lock:yt_confirm", style="success")],
        ]
        txt = f"🎬 <b>حمایت از کانال یوتیوب</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('yt_lock_text', ''))}"
        return False, txt, kb(rows)

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
    pools = store.data.get("operator_pools", {})
    panel = store.data.get("panels", {}).get(str(tg_id))
    if panel:
        st_lbl = "🟢 آپدیت و فعال" if _is_panel_updated(panel) else "🟡 نیاز به آپدیت"
        panel_line = f"🎛️ پنل شما: <b>{st_lbl}</b> (<code>{html.escape(panel['host'])}</code>)"
    else:
        panel_line = "🎛️ پنل شما: ⚪ هنوز ساخته نشده"
    return (
        "⚡ <b>Cloudflare Config Hub — کانفیگ رایگان و تست‌شده</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> | 🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> | 🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b>\n"
        f"🛡️ رله WARP سالم: <b>{len(store.data.get('warp_v4_pool', []))}</b> IPv4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> IPv6\n"
        f"{panel_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 گزینه مورد نظر را انتخاب کنید:"
    )


@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    u = message.from_user
    if not u:
        return
    store.touch_user(u.id, u.username, u.full_name)
    if store.is_banned(u.id) and not _is_admin(u.id):
        await message.answer("🚫 دسترسی شما مسدود شده است.")
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(u.id):
        await message.answer("🛠️ ربات موقتاً در حال به‌روزرسانی است.")
        return
    ok_lock, lock_txt, lock_kb = await _check_access_locks(message.bot, u.id)
    if not ok_lock:
        await message.answer(lock_txt, reply_markup=lock_kb, parse_mode="HTML")
        return
    await message.answer(
        _home_text(u.id),
        reply_markup=main_menu_kb(_is_admin(u.id), _has_panel(u.id), store.get_lang(u.id), store.data["settings"].get("webapp_url", "")),
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
        await _safe_answer(cb, "⚠️ هنوز عضویت شما تایید نشد! ابتدا عضو شوید.", show_alert=True)
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ عضویت شما تایید شد! خوش آمدید.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


@router.callback_query(F.data == "lock:yt_confirm")
async def cb_lock_yt_confirm(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.set_yt_verified(uid, True)
    ok_lock, lock_txt, lock_kb = await _check_access_locks(cb.bot, uid)
    if not ok_lock:
        await _safe_answer(cb, "✅ تایید شد؛ مرحله بعد را انجام دهید.")
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ ممنون از حمایت شما! ربات باز شد.", show_alert=True)
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
    await _safe_answer(cb, "EN" if lang == "en" else "فارسی")
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), lang, store.data["settings"].get("webapp_url", "")))


# ==================== 1. PANEL DEPLOY (PRIMARY CLOUDFLARE PAGES `*.pages.dev` + WORKERS FALLBACK) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    uid = cb.from_user.id
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت پنل رایگان (۳ VLESS + ۳ Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلودفلر نداری، اول ثبت‌نام کن.\n"
        "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن (دسترسی‌های Pages و Workers آماده است).\n"
        "3️⃣ در کلودفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "🔐 <i>پیام توکن بلافاصله پاک و رمزنگاری می‌شود و پنل روی Cloudflare Pages (*.pages.dev) ساخته می‌شود.</i>"
    )
    rows = [
        [btn("🔑 دریافت مستقیم توکن کلودفلر", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
        [btn("🌐 ثبت‌نام رایگان کلودفلر", url=CLOUDFLARE_SIGNUP_URL, style="primary")],
    ]
    if _has_panel(uid):
        rows.append([btn("🎛️ ورود به پنل من", callback_data="m:mypanel", style="primary")])
    rows.append([btn("🔙 بازگشت", callback_data="m:home", style="danger")])
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
            "⚠️ فرمت توکن نامعتبر است. توکن را بدون فاصله ارسال کنید:",
            reply_markup=kb([
                [btn("🔑 دریافت مستقیم توکن", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    wait_msg = await message.answer("⏳ <b>در حال دیپلوی روی Cloudflare Pages (*.pages.dev) و تست واقعی VLESS و Trojan...</b>", parse_mode="HTML")

    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    proj_name = old.get("project_name") or _new_neutral_name()
    proxy_ip = old.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.cmliussss.net")

    dep = await cf_service.deploy_dual_panel(
        api_token=raw_token,
        user_uuid=panel_uuid,
        trojan_password=trojan_pass,
        project_name=proj_name,
        proxy_ip=proxy_ip,
    )
    if not dep.ok:
        await wait_msg.edit_text(
            f"❌ <b>دیپلوی ناموفق بود:</b>\n<code>{html.escape(dep.error or '')}</code>",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔑 ساخت مجدد توکن مستقیم", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    now = datetime.now(timezone.utc).isoformat()
    store.data["cf_accounts"][str(uid)] = {
        "encrypted_token": store.encrypt_secret(raw_token),
        "account_id": dep.account_id,
        "account_name": dep.account_name,
        "connected_at": now,
    }
    op = old.get("operator", "mci")
    pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
    is_healthy = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
    store.data["panels"][str(uid)] = {
        "engine": dep.engine,
        "uuid": panel_uuid,
        "trojan_password": trojan_pass,
        "project_name": dep.project_name,
        "host": dep.worker_host,
        "sni": dep.worker_host,
        "fallback_host": dep.fallback_host,
        "operator": op,
        "clean_ip": pair[0]["ip"],
        "proxy_ip": proxy_ip,
        "auto_ip": True,
        "worker_version": CURRENT_WORKER_VERSION,
        "last_health_ok": is_healthy,
        "created_at": old.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    v_badge = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:80])}"
    t_badge = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:80])}"
    diag = f"\nℹ️ {html.escape(dep.diag_note[:160])}" if dep.diag_note else ""
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"🎉 <b>پنل V23 ({dep.engine.upper()}) آماده شد!</b>\n"
        f"🔷 VLESS: <b>{v_badge}</b>\n🔐 Trojan: <b>{t_badge}</b>{diag}\n\n{text}",
        parse_mode="HTML",
        reply_markup=markup,
    )


# ==================== 2. MY PANEL — ULTRA-CLEAN (NO SUB LINK, NO RENAME BUTTON, QUOTE CONFIGS) ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return (
            "🎛️ <b>پنل من</b>\n━━━━━━━━━━━━━━━━━━━━\nهنوز پنل رایگان نساخته‌اید. روی دکمه سبز زیر بزنید:",
            kb([
                [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")],
                [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
            ]),
        )

    op = panel.get("operator", "mci")
    engine_lbl = "Cloudflare Pages" if panel.get("engine") == "pages" else "Cloudflare Workers"
    updated = _is_panel_updated(panel)
    ver_line = (
        f"📦 وضعیت نسخه: <b>✅ آپدیت هستید ({CURRENT_WORKER_VERSION.upper()})</b>"
        if updated
        else "📦 وضعیت نسخه: <b>⚠️ نیاز به آپدیت — دکمه «آپدیت کنید» را بزنید</b>"
    )
    update_btn = (
        btn("✅ آپدیت هستید", callback_data="cf:up_to_date", style="success")
        if updated
        else btn("🔄 آپدیت کنید", callback_data="cf:redeploy", style="danger")
    )

    text = (
        "🎛️ <b>پنل اختصاصی من</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚡ موتور فعال: <b>{engine_lbl}</b>\n"
        f"🌐 دامنه فعال: <code>{html.escape(panel['host'])}</code>\n"
        f"📶 اپراتور فعال: <b>{OPERATOR_LABELS.get(op, op)}</b>\n"
        f"{ver_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "اپراتور خود را انتخاب کنید تا <b>۶ کانفیگ پرسرعت ECH (۳ VLESS + ۳ Trojan)</b> دریافت کنید:"
    )
    markup = kb([
        [
            btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
            btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
            btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
        ],
        [
            btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary"),
            update_btn,
        ],
        [
            btn("🔁 تغییر ProxyIP", callback_data="cf:edit_proxyip", style="primary"),
            btn("🗑️ حذف پنل", callback_data="cf:disconnect", style="danger"),
        ],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    t, m = _render_personal_panel(cb.from_user.id)
    await _edit(cb, t, m)


@router.callback_query(F.data == "cf:up_to_date")
async def cb_cf_up_to_date(cb: CallbackQuery) -> None:
    await _safe_answer(cb, f"✅ پنل شما روی آخرین نسخه ({CURRENT_WORKER_VERSION.upper()}) آپدیت و سالم است!", show_alert=True)


@router.callback_query(F.data.startswith("cf:getop:"))
async def cb_cf_get_by_op(cb: CallbackQuery) -> None:
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, f"⏳ انتخاب ۳ IP سالم برای {OPERATOR_LABELS.get(op, op)}...")

    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    pool = bg_engine.get_best_operator_ips(op, 8)
    offset = int(panel.get(f"rot_{op}", 0)) % max(1, len(pool))
    rotated = pool[offset:] + pool[:offset]
    panel[f"rot_{op}"] = offset + 2

    verified_ips = await cf_service.pick_best_verified_worker_ips(panel["host"], rotated, operator=op, count=3)
    panel["operator"] = op
    panel["clean_ip"] = verified_ips[0]["ip"]
    store.save()
    store.increment_stat(uid, "configs_generated")

    ech_b64 = await fetch_live_cloudflare_ech_b64()
    if not panel.get("sub_token"):
        panel["sub_token"] = secrets.token_urlsafe(12)
        store.save()
    (ok_v2, _, _), (ok_t2, _, _) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], verified_ips[1]["ip"], 2083, timeout_sec=2.5),
        check_ip_routes_worker(panel["host"], verified_ips[1]["ip"], 8443, timeout_sec=2.5),
    )
    c6 = cf_service.build_six_ech_configs(
        panel, verified_ips, operator=op, ech_b64=ech_b64,
        alt_port_vless=(2083 if ok_v2 else 443), alt_port_trojan=(8443 if ok_t2 else 443),
    )
    op_lbl = OPERATOR_LABELS.get(op, op)
    wurl = (store.data["settings"].get("webapp_url") or "https://app.prostoreshop.site").rstrip("/")
    sub_line = f"\n🔗 <b>لینک اشتراک خودکار (آپدیت دائم ECH):</b>\n<code>{wurl}/sub/{uid}?op={op}&amp;t={panel['sub_token']}</code>\n" if wurl.startswith("https://") else ""

    msg = (
        f"🚀 <b>۶ کانفیگ ضد فیلتر V23 اختصاصی {op_lbl}</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 <b>VLESS #1 (Auto-ECH • بدون انقضا)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_1'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #2 (Live-ECH • ضد محدودیت)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_2'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #3 (Universal TLS • همیشه وصل)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_3'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #1 (Auto-ECH • بدون انقضا)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_1'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #2 (Live-ECH • ضد محدودیت)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_2'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #3 (Universal TLS • همیشه وصل)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_3'])}</code></blockquote>\n"
        f"━━━━━━━━━━━━━━━━━━━━{sub_line}"
        f"⚡ <i>ترکیب Auto-ECH بدون انقضا + پورت ضد محدودیت + Universal TLS</i>"
    )
    await _edit(
        cb,
        msg,
        kb([
            [btn(f"🔄 تعویض با ۳ IP جدید ({op_lbl})", callback_data=f"cf:getop:{op}", style="success")],
            [btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:e2e_test")
async def cb_cf_e2e_test(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, "🩺 در حال تست سرتاسری...")
    wait = await cb.message.answer("⏳ در حال اجرای تست سرتاسری پنل (Health + VLESS + Trojan + ProxyIP)...")
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    op = panel.get("operator", "mci")
    if is_restricted_1034_ip(panel.get("clean_ip", "")):
        pair = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 8), operator=op)
        panel["clean_ip"] = pair[0]["ip"]
        store.save()

    (h_ok, h_ms, h_msg), (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg), (p_ok, p_ms, p_msg) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "trojan", panel["trojan_password"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="cp.cloudflare.com"),
    )

    all_good = bool(h_ok and v_ok and t_ok)
    panel["last_health_ok"] = all_good
    store.save()

    h_l = f"🟢 <b>سالم</b> ({h_ms}ms)" if h_ok else f"🔴 <b>خطا</b> ({html.escape(h_msg[:95])})"
    v_l = f"🟢 <b>سالم</b> ({v_ms}ms)" if v_ok else f"🔴 <b>خطا</b> ({html.escape(v_msg[:110])})"
    t_l = f"🟢 <b>سالم</b> ({t_ms}ms)" if t_ok else f"🔴 <b>خطا</b> ({html.escape(t_msg[:110])})"
    p_l = f"🟢 <b>سالم</b> ({p_ms}ms)" if p_ok else f"🟡 <b>نیاز به ProxyIP</b> ({html.escape(p_msg[:95])})"

    rows = []
    if not all_good:
        hint = "\n\n💡 دکمه <b>🔄 آپدیت کنید</b> زیر را بزنید تا پنل روی Cloudflare Pages (*.pages.dev) منتقل شود."
        rows.append([btn("🔄 آپدیت کنید (انتقال به Pages سالم)", callback_data="cf:redeploy", style="danger")])
    else:
        hint = "\n\n✅ <b>پنل شما کاملاً سالم و آپدیت است!</b>"
    rows.append([btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")])

    await wait.edit_text(
        f"🩺 <b>نتیجه تست سرتاسری پنل شما ({CURRENT_WORKER_VERSION.upper()})</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📡 دامنه فعال: <code>{html.escape(panel['host'])}</code>\n"
        f"🌐 روتینگ IP تمیز (<code>{html.escape(panel['clean_ip'])}</code>): {h_l}\n"
        f"🔷 تونل واقعی VLESS: {v_l}\n"
        f"🔐 تونل واقعی Trojan: {t_l}\n"
        f"🔁 فالبک ProxyIP: {p_l}{hint}",
        parse_mode="HTML",
        reply_markup=kb(rows),
    )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    if uid in _redeploy_locks:
        await _safe_answer(cb, "⏳ آپدیت هم‌اکنون در حال انجام است، لطفاً صبر کنید...", show_alert=True)
        return
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await _safe_answer(cb, "⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return

    _redeploy_locks.add(uid)
    try:
        await _safe_answer(cb, "🔄 در حال انتقال و آپدیت روی Cloudflare Pages...")
        await _edit(
            cb,
            "⏳ <b>در حال آپدیت پنل به نسخه V23 (موتور Cloudflare Pages)...</b>\n"
            "• ساخت پروژه جدید روی <code>*.pages.dev</code> (رفع کامل Error 1101)\n"
            "• دیپلوی مستقیم <code>_worker.js</code> دوپروتکله\n"
            "• تست واقعی VLESS و Trojan (حدود ۱۰ تا ۱۵ ثانیه صبر کنید)",
            kb([[btn("⏳ لطفاً صبر کنید...", callback_data="cf:noop", style="primary")]]),
        )
        try:
            token = store.decrypt_secret(cf["encrypted_token"])
        except Exception:
            await _edit(cb, "❌ توکن قابل رمزگشایی نیست؛ لطفاً از منوی اصلی دوباره متصل شوید.", back_home_kb("m:turbo"))
            return
        if not panel.get("trojan_password"):
            panel["trojan_password"] = secrets.token_urlsafe(12)

        dep = await cf_service.deploy_dual_panel(
            api_token=token,
            user_uuid=panel["uuid"],
            trojan_password=panel["trojan_password"],
            project_name=panel.get("project_name") or panel.get("script_name") or "",
            proxy_ip=panel.get("proxy_ip", "proxyip.cmliussss.net"),
            force_new_name=(panel.get("engine") != "pages"),
        )
        if dep.ok:
            op = panel.get("operator", "mci")
            pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
            is_healthy = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
            panel["engine"] = dep.engine
            panel["project_name"] = dep.project_name
            panel["host"] = dep.worker_host
            panel["sni"] = dep.worker_host
            panel["fallback_host"] = dep.fallback_host
            panel["clean_ip"] = pair[0]["ip"]
            panel["worker_version"] = CURRENT_WORKER_VERSION
            panel["last_health_ok"] = is_healthy
            panel["updated_at"] = datetime.now(timezone.utc).isoformat()
            store.save()

            v_s = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:75])}"
            t_s = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:75])}"
            diag = f"\nℹ️ {html.escape(dep.diag_note[:160])}" if dep.diag_note else ""
            text, markup = _render_personal_panel(uid)
            await _edit(
                cb,
                f"✅ <b>آپدیت به نسخه {CURRENT_WORKER_VERSION.upper()} ({dep.engine.upper()}) انجام شد!</b>\n"
                f"🔷 VLESS: <b>{v_s}</b>\n🔐 Trojan: <b>{t_s}</b>{diag}\n\n{text}",
                markup,
            )
        else:
            await _edit(cb, f"❌ <b>خطا در آپدیت پنل:</b>\n<code>{html.escape(dep.error or '')}</code>", back_home_kb("m:mypanel"))
    finally:
        _redeploy_locks.discard(uid)


@router.callback_query(F.data == "cf:noop")
async def cb_noop(cb: CallbackQuery) -> None:
    await _safe_answer(cb, "⏳ در حال انجام عملیات...")


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(cb, "🔁 آدرس ProxyIP جدید بفرستید (پیشنهاد: <code>proxyip.cmliussss.net</code> یا <code>bpb.yousef.isegaro.com</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    pip = (message.text or "").strip()
    if str(uid) in store.data["panels"] and pip:
        store.data["panels"][str(uid)]["proxy_ip"] = pip
        store.data["panels"][str(uid)]["last_health_ok"] = False
        store.save()
    await state.clear()
    t, m = _render_personal_panel(uid)
    await message.answer(f"✅ ProxyIP ذخیره شد. برای اعمال روی کلودفلر دکمه <b>🔄 آپدیت کنید</b> را بزنید.\n\n{t}", parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await _safe_answer(cb, "🗑️ پنل حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


# ==================== 3. WARP / WIREGUARD (WORKING CORE — LINKS IN QUOTE BLOCKS!) ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    ep4, ep6, _ = bg_engine.get_best_warp_endpoints()
    text = (
        "🛡️ <b>کانفیگ‌های WARP و WireGuard (سالم و تست‌شده)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 رله IPv4: <code>{html.escape(ep4)}</code>\n"
        f"🌐 رله IPv6: <code>{html.escape(ep6)}</code>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "نسخه IP مورد نظر را انتخاب کنید:"
    )
    markup = kb([
        [btn("🌐 IPv6 (پرسرعت و ضد اختلال)", callback_data="warp:mode:ipv6", style="success")],
        [btn("⚡ Dual-Stack (IPv4 + IPv6)", callback_data="warp:mode:dual", style="primary")],
        [btn("🌐 IPv4 (سازگار با همه خطوط)", callback_data="warp:mode:ipv4", style="primary")],
        [btn("🔍 اسکن زنده اندپوینت‌های WARP", callback_data="warp:scan_live", style="success")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)



@router.callback_query(F.data == "warp:scan_live")
async def cb_warp_scan_live(cb: CallbackQuery) -> None:
    if bg_engine.is_scanning:
        await _safe_answer(cb, f"⏳ اسکن هم‌اکنون در حال اجراست ({bg_engine.progress_pct}%).", show_alert=True)
        return
    await _safe_answer(cb, "🔍 اسکن زنده اندپوینت‌های WARP شروع شد!")
    await _edit(
        cb,
        f"🔍 <b>اسکن زنده اندپوینت‌های WARP (IPv4 + IPv6)</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(10)}</code>\n"
        f"⏳ در حال آماده‌سازی...",
        kb([[btn("⏳ در حال اسکن...", callback_data="cf:noop", style="primary")]]),
    )

    async def _on_p(pct: int, msg: str) -> None:
        await _edit(
            cb,
            f"🔍 <b>اسکن زنده اندپوینت‌های WARP (IPv4 + IPv6)</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📊 پیشرفت: <code>{_progress_bar(pct)}</code>\n"
            f"🔄 وضعیت: <b>{html.escape(msg)}</b>",
            kb([[btn(f"⏳ {pct}% تکمیل شده...", callback_data="cf:noop", style="primary")]]),
        )

    res = await bg_engine.run_warp_only_scan(on_progress=_on_p)
    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    await _edit(
        cb,
        f"✅ <b>اسکن اندپوینت‌های WARP با موفقیت تمام شد!</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(100)}</code>\n"
        f"🌐 بهترین رله IPv4: <code>{html.escape(ep4)}</code> (<b>{res.get('warp_v4', 0)}</b> سالم)\n"
        f"🌐 بهترین رله IPv6: <code>{html.escape(ep6)}</code> (<b>{res.get('warp_v6', 0)}</b> سالم)\n"
        f"⚡ بهترین پینگ: <b>{ping or 'Auto'}ms</b>",
        kb([
            [btn("🛡️ ساخت کانفیگ با رله‌های جدید", callback_data="m:warp", style="success")],
            [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
        ]),
    )


@router.callback_query(F.data.startswith("warp:mode:"))
async def cb_warp_plat(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    mode = cb.data.split(":")[2]
    text = f"🛡️ <b>WARP ({mode.upper()})</b>\n━━━━━━━━━━━━━━━━━━━━\nدستگاه خود را انتخاب کنید:"
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:go:{mode}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:go:{mode}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:go:{mode}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:go:"))
async def cb_warp_go(cb: CallbackQuery) -> None:
    _, _, ip_mode, platform = cb.data.split(":")
    await _safe_answer(cb, "⏳ ثبت کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return
    wait = await cb.message.answer("⏳ در حال ساخت کلید اختصاصی WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(f"❌ خطا: <code>{html.escape(reg.error or '')}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:warp"))
        return

    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand="CFHub")  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    try:
        await wait.delete()
    except Exception:
        pass

    txt = (
        f"✅ <b>کانفیگ WARP آماده شد</b>\n"
        f"🏷️ <b>{html.escape(b['label'])}</b>\n"
        f"🎯 رله: <code>{html.escape(b['endpoint'])}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>پیشنهاد اول — ضد فیلتر تهران/ایران (Hiddify / Karing):</b>\n"
        f"<blockquote><code>{html.escape(b['warp_auto_uri'])}</code></blockquote>\n\n"
        f"2️⃣ <b>لینک دولایه WoW (Hiddify / Karing):</b>\n"
        f"<blockquote><code>{html.escape(b['wow_uri'])}</code></blockquote>\n\n"
        f"3️⃣ <b>لینک WireGuard ضد DPI (v2rayNG / MahsaNG):</b>\n"
        f"<blockquote><code>{html.escape(b['wireguard_uri'])}</code></blockquote>"
    )
    await cb.message.answer(txt, parse_mode="HTML")
    await cb.message.answer_document(
        document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
        caption=f"🛡️ <b>فایل آماده AmneziaWG ({ip_mode.upper()})</b>",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("🔄 ساخت کلید جدید", callback_data=cb.data, style="success")],
            [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
        ]),
    )


# ==================== 4. CLEAN IPS BY OPERATOR ====================
@router.callback_query(F.data == "m:isp")
async def cb_isp(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    pools = store.data.get("operator_pools", {})
    text = (
        "📶 <b>آی‌پی‌های تمیز بر اساس اپراتور</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> IP\n"
        f"🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> IP\n"
        f"🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b> IP"
    )
    markup = kb([
        [btn("🔵 همراه اول", callback_data="isp:show:mci", style="primary")],
        [btn("🟡 ایرانسل", callback_data="isp:show:mtn", style="primary")],
        [btn("🟢 مخابرات", callback_data="isp:show:mkh", style="success")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("isp:show:"))
async def cb_isp_show(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    op = cb.data.split(":")[2]
    ips = bg_engine.get_best_operator_ips(op, 10)
    lbl = OPERATOR_LABELS.get(op, op)
    body = "\n".join(
        f"{i+1}. <code>{x['ip']}</code> | 🟢<b>{x.get('latency_ms') or 'Auto'}ms</b> | {x.get('colo', 'CF')}"
        for i, x in enumerate(ips)
    ) or "⏳ در حال دریافت لیست..."
    rows = []
    if _has_panel(cb.from_user.id):
        rows.append([btn(f"⚡ دریافت ۶ کانفیگ {lbl}", callback_data=f"cf:getop:{op}", style="success")])
    rows.append([btn("🔙 اپراتورها", callback_data="m:isp", style="primary")])
    await _edit(cb, f"📶 <b>IP تمیز {lbl}</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


# ==================== 5. APPS, GUIDE & SUPPORT ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    markup = kb([
        [btn("🔥 Hiddify (اندروید / آیفون / ویندوز — پیشنهادی)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (ضد فیلتر WARP)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (اندروید)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (آیفون)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (ویندوز)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, "📱 <b>اپلیکیشن‌های پیشنهادی:</b>", markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
    text = (
        "📖 <b>راهنمای اتصال سریع</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>پنل VLESS + Trojan:</b>\n"
        "• توکن کلودفلر را بفرستید تا پنل شما روی Cloudflare Pages ساخته شود.\n"
        "• داخل «🎛️ پنل من» اپراتور خود را بزنید تا ۶ کانفیگ مرتب (۳ VLESS + ۳ Trojan) بگیرید.\n"
        "• روی اینترنت‌های حساس به SNI، در تنظیمات Hiddify یا v2rayNG گزینه <b>TLS Fragment</b> را روشن کنید.\n\n"
        "2️⃣ <b>کانفیگ WARP:</b>\n"
        "• لینک <code>warp://auto...</code> را در <b>Hiddify</b> یا فایل <code>.conf</code> را در <b>AmneziaWG</b> باز کنید."
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    cfg = store.data["settings"]
    sup_u = cfg.get("support_username", "").lstrip("@")
    sup_id = cfg.get("support_user_id") or (get_settings().owner_telegram_ids[0] if get_settings().owner_telegram_ids else 0)
    rows = []
    if sup_u:
        rows.append([btn(f"💬 چت مستقیم (@{sup_u})", url=f"https://t.me/{sup_u}", style="success")])
        line = f"👤 پشتیبانی: @{html.escape(sup_u)}"
    elif sup_id:
        rows.append([btn("💬 چت مستقیم با مدیریت", url=f"tg://user?id={sup_id}", style="success")])
        line = f"👤 شناسه پشتیبانی: <code>{sup_id}</code>"
    else:
        line = "👤 پشتیبانی آنلاین فعال است."
    rows.append([btn("✉️ ارسال تیکت داخل ربات", callback_data="sup:ticket", style="primary")])
    rows.append([btn("🔙 صفحه اول", callback_data="m:home", style="primary")])
    await _edit(cb, f"💬 <b>پشتیبانی</b>\n━━━━━━━━━━━━━━━━━━━━\n{line}", kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    await state.set_state(Flow.waiting_support_msg)
    await _edit(cb, "✉️ پیام خود را بنویسید:", kb([[btn("❌ انصراف", callback_data="m:support", style="danger")]]))


@router.message(Flow.waiting_support_msg)
async def handle_sup_msg(message: Message, state: FSMContext) -> None:
    u = message.from_user
    if not u:
        return
    tno = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({"id": tno, "user_id": u.id, "text": message.text or "", "at": datetime.now(timezone.utc).isoformat()})
    store.save()
    await state.clear()
    for oid in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(oid, f"📩 <b>تیکت #{tno}</b> از <a href='tg://user?id={u.id}'>{html.escape(u.full_name)}</a> (<code>{u.id}</code>):\n{html.escape(message.text or '')}", parse_mode="HTML")
        except Exception:
            pass
    await message.answer(f"✅ تیکت <b>#{tno}</b> ثبت شد.", parse_mode="HTML", reply_markup=back_home_kb("m:home"))


# ==================== 6. CLEAN ADMIN PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        f"🛠️ <b>پنل مدیریت ({CURRENT_WORKER_VERSION.upper()})</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | آخرین اسکن: <code>{last_s}</code>\n"
        f"📶 IP اپراتورها: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))}\n"
        f"🛡️ WARP تاییدشده: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل فعال: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [
            btn("▶️ اسکن IP اپراتورها + WARP", callback_data="adm:scan_now", style="success"),
            btn("🛡️ اسکن زنده WARP", callback_data="warp:scan_live", style="primary"),
        ],
        [
            btn("🔵 افزودن IP همراه اول", callback_data="adm:addop:mci", style="primary"),
            btn("🟡 افزودن IP ایرانسل", callback_data="adm:addop:mtn", style="primary"),
        ],
        [
            btn("🟢 افزودن IP مخابرات", callback_data="adm:addop:mkh", style="success"),
            btn("👥 مدیریت کاربران", callback_data="adm:users:0", style="primary"),
        ],
        [btn("🔒 قفل کانال تلگرام و یوتیوب", callback_data="adm:locks", style="primary")],
        [
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
            btn("⚙️ تنظیمات و پشتیبانی", callback_data="adm:settings", style="primary"),
        ],
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
        await _safe_answer(cb, f"⏳ اسکن هم‌اکنون در حال اجراست ({bg_engine.progress_pct}%).", show_alert=True)
        return
    await _safe_answer(cb, "🚀 اسکن زنده آغاز شد!")
    await _edit(
        cb,
        f"🔍 <b>جستجوی زنده آی‌پی‌های تمیز و رله‌های WARP</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(5)}</code>\n"
        f"⏳ در حال آماده‌سازی موتور اسکن...",
        kb([[btn("⏳ در حال اسکن...", callback_data="cf:noop", style="primary")]]),
    )

    async def _on_prog(pct: int, stage_msg: str) -> None:
        await _edit(
            cb,
            f"🔍 <b>جستجوی زنده آی‌پی‌های تمیز و رله‌های WARP</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📊 پیشرفت: <code>{_progress_bar(pct)}</code>\n"
            f"🔄 وضعیت: <b>{html.escape(stage_msg)}</b>",
            kb([[btn(f"⏳ {pct}% تکمیل شده...", callback_data="cf:noop", style="primary")]]),
        )

    res = await bg_engine.run_full_cycle(trigger="admin_live", on_progress=_on_prog)
    mci_top = bg_engine.get_best_operator_ips("mci", 1)[0]["ip"]
    mtn_top = bg_engine.get_best_operator_ips("mtn", 1)[0]["ip"]
    mkh_top = bg_engine.get_best_operator_ips("mkh", 1)[0]["ip"]
    await _edit(
        cb,
        f"✅ <b>اسکن کامل با موفقیت به پایان رسید!</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(100)}</code>\n"
        f"🔵 همراه اول: <b>{res.get('mci', 0)}</b> IP (برتر: <code>{mci_top}</code>)\n"
        f"🟡 ایرانسل: <b>{res.get('mtn', 0)}</b> IP (برتر: <code>{mtn_top}</code>)\n"
        f"🟢 مخابرات: <b>{res.get('mkh', 0)}</b> IP (برتر: <code>{mkh_top}</code>)\n"
        f"🛡️ رله WARP سالم: <b>{res.get('warp_v4', 0)}</b> v4 • <b>{res.get('warp_v6', 0)}</b> v6\n\n"
        f"✨ <i>برترین آی‌پی‌ها به‌صورت خودکار روی پنل کاربران سوار شدند.</i>",
        kb([
            [btn("🔄 اسکن مجدد", callback_data="adm:scan_now", style="success")],
            [btn("🔙 بازگشت به پنل مدیریت", callback_data="adm:home", style="primary")],
        ]),
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
    await message.answer(f"✅ {added} IP معتبر به {OPERATOR_LABELS.get(op, op)} اضافه شد.", reply_markup=back_home_kb("adm:home"))


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
        nav.append(btn("⬅️ قبلی", callback_data=f"adm:users:{page-1}", style="primary"))
    if (page + 1) * per_page < len(all_u):
        nav.append(btn("بعدی ➡️", callback_data=f"adm:users:{page+1}", style="primary"))
    if nav:
        rows.append(nav)
    rows.append([btn("🔎 جستجوی کاربر", callback_data="adm:usearch", style="success")])
    rows.append([btn("🔙 پنل مدیریت", callback_data="adm:home", style="danger")])
    await _edit(cb, f"👥 <b>مدیریت کاربران (کل: {len(all_u)})</b>", kb(rows))


def _render_user_card(target_uid: int) -> tuple[str, object]:
    u = store.data.get("users", {}).get(str(target_uid))
    if not u:
        return "❌ یافت نشد.", back_home_kb("adm:users:0")
    p = store.data.get("panels", {}).get(str(target_uid))
    txt = (
        f"👤 <b>پروفایل کاربر</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 <code>{target_uid}</code> | {html.escape(u.get('full_name') or '-')} (@{html.escape(u.get('username') or '-')})\n"
        f"🚦 وضعیت: <b>{'🚫 مسدود' if u.get('is_banned') else '🟢 فعال'}</b>\n"
        f"🚀 پنل: <code>{html.escape(p['host']) if p else 'ندارد'}</code>\n"
        f"📊 تولید: <b>{u.get('configs_generated', 0)}</b> پنل | <b>{u.get('warp_generated', 0)}</b> WARP"
    )
    ban_b = btn("✅ رفع مسدودی", callback_data=f"adm:uban:{target_uid}", style="success") if u.get("is_banned") else btn("🚫 مسدود کردن", callback_data=f"adm:uban:{target_uid}", style="danger")
    rows = [[ban_b], [btn("✉️ پیام مستقیم", callback_data=f"adm:udm:{target_uid}", style="primary")]]
    if p:
        rows.append([btn("🗑️ حذف پنل کاربر", callback_data=f"adm:ureset:{target_uid}", style="danger")])
    rows.append([btn("🔙 لیست کاربران", callback_data="adm:users:0", style="primary")])
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
    if _is_admin(tid):
        await _safe_answer(cb)
        return
    store.set_ban(tid, not store.is_banned(tid))
    await _safe_answer(cb, "✅ انجام شد.", show_alert=True)
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
    await _safe_answer(cb, "🗑️ پاک شد.", show_alert=True)
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
        await message.answer(f"❌ خطا: {exc}", reply_markup=back_home_kb(f"adm:uview:{tid}"))


@router.callback_query(F.data == "adm:usearch")
async def cb_adm_usearch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_user_search)
    await _edit(cb, "🔎 آیدی یا <code>@username</code> را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:users:0", style="danger")]]))


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
    await _edit(cb, f"📢 متن پیام همگانی برای {len(store.data.get('users', {}))} کاربر:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


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
    await message.answer(f"✅ ارسال تمام شد (موفق: {sent} | ناموفق: {fail})", reply_markup=back_home_kb("adm:home"))


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
        f"🔄 اسکن خودکار: <b>{'🟢' if cfg.get('auto_scan_enabled', True) else '🔴'}</b> | تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    await _edit(cb, text, kb([
        [btn("🌐 تنظیم لینک HTTPS مینی‌اپ", callback_data="adm:set_webapp", style="success")],
        [btn("💬 تغییر یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="primary")],
        [
            btn("🔄 تغییر اسکن خودکار", callback_data="adm:tog_scan", style="primary"),
            btn("🛠️ تغییر تعمیرات", callback_data="adm:tog_maint", style="danger"),
        ],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:tog_scan")
async def cb_adm_tog_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_scan_enabled"] = not bool(store.data["settings"].get("auto_scan_enabled", True))
    store.save()
    await _safe_answer(cb, "✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["maintenance_mode"] = not bool(store.data["settings"].get("maintenance_mode", False))
    store.save()
    await _safe_answer(cb, "✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_support)
    await _edit(cb, "💬 یوزرنیم پشتیبانی را بفرستید (مثال: <code>@YourID</code>):", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


@router.message(Flow.adm_set_support)
async def handle_adm_set_sup(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    uname = (message.text or "").strip().lstrip("@")
    store.data["settings"]["support_username"] = uname
    store.save()
    await state.clear()
    await message.answer(f"✅ آیدی پشتیبانی: <b>@{html.escape(uname)}</b>", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))



@router.callback_query(F.data == "adm:locks")
async def cb_adm_locks(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await state.clear()
    await _safe_answer(cb)
    cfg = store.data["settings"]
    tg_st = "🟢 روشن" if cfg.get("tg_lock_enabled") else "🔴 خاموش"
    yt_st = "🟢 روشن" if cfg.get("yt_lock_enabled") else "🔴 خاموش"
    tg_ch = cfg.get("tg_lock_channel") or "تنظیم نشده"
    yt_url = cfg.get("yt_lock_url") or "تنظیم نشده"

    text = (
        "🔒 <b>مدیریت قفل کانال تلگرام (واقعی) و یوتیوب (فیک)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"📢 <b>قفل تلگرام (واقعی):</b> {tg_st}\n"
        f"• کانال: <code>{html.escape(str(tg_ch))}</code>\n"
        f"• متن: <i>{html.escape(str(cfg.get('tg_lock_text', ''))[:90])}</i>\n\n"
        f"🎬 <b>قفل یوتیوب (فیک):</b> {yt_st}\n"
        f"• لینک: <code>{html.escape(str(yt_url))}</code>\n"
        f"• توضیحات: <i>{html.escape(str(cfg.get('yt_lock_text', ''))[:90])}</i>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "<i>نکته: برای کار کردن قفل واقعی تلگرام، ربات را در کانال خود ادمین کنید.</i>"
    )
    markup = kb([
        [
            btn(f"📢 قفل تلگرام: {tg_st}", callback_data="adm:tog_tg_lock", style="success" if cfg.get("tg_lock_enabled") else "danger"),
            btn(f"🎬 قفل یوتیوب: {yt_st}", callback_data="adm:tog_yt_lock", style="success" if cfg.get("yt_lock_enabled") else "danger"),
        ],
        [
            btn("✏️ تنظیم کانال تلگرام", callback_data="adm:set_tg_ch", style="primary"),
            btn("📝 متن قفل تلگرام", callback_data="adm:set_tg_txt", style="primary"),
        ],
        [
            btn("🔗 تنظیم لینک یوتیوب", callback_data="adm:set_yt_url", style="primary"),
            btn("📝 توضیحات یوتیوب", callback_data="adm:set_yt_txt", style="primary"),
        ],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ])
    await _edit(cb, text, markup)


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
    await _safe_answer(cb, "✅ وضعیت قفل تلگرام تغییر کرد.")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:tog_yt_lock")
async def cb_adm_tog_yt_lock(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["yt_lock_enabled"] = not bool(store.data["settings"].get("yt_lock_enabled", False))
    store.save()
    await _safe_answer(cb, "✅ وضعیت قفل یوتیوب تغییر کرد.")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:set_tg_ch")
async def cb_adm_set_tg_ch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_channel)
    await _edit(cb, "📢 آیدی کانال تلگرام (مثال: <code>@MyChannel</code> یا آیدی عددی <code>-100...</code>) را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_channel)
async def handle_adm_set_tg_ch(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    store.data["settings"]["tg_lock_channel"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ کانال تلگرام روی <code>{html.escape(val)}</code> تنظیم شد.", parse_mode="HTML", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_tg_txt")
async def cb_adm_set_tg_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_text)
    await _edit(cb, "📝 متن نمایشی قفل کانال تلگرام را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_text)
async def handle_adm_set_tg_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["tg_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ متن قفل تلگرام ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_url")
async def cb_adm_set_yt_url(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_url)
    await _edit(cb, "🔗 لینک کانال یوتیوب را بفرستید (مثال: <code>https://youtube.com/@CyberMux</code>):", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_url)
async def handle_adm_set_yt_url(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    store.data["settings"]["yt_lock_url"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ لینک یوتیوب ذخیره شد: <code>{html.escape(val)}</code>", parse_mode="HTML", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_txt")
async def cb_adm_set_yt_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_text)
    await _edit(cb, "📝 توضیحات دستی قفل کانال یوتیوب را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_text)
async def handle_adm_set_yt_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["yt_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ توضیحات قفل یوتیوب ذخیره شد.", reply_markup=back_home_kb("adm:locks"))



@router.callback_query(F.data == "adm:set_webapp")
async def cb_adm_set_webapp(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_webapp_url)
    cur = store.data["settings"].get("webapp_url") or "تنظیم نشده"
    await _edit(
        cb,
        f"🌐 <b>تنظیم لینک HTTPS مینی‌اپ تلگرام</b>\n"
        f"لینک فعلی: <code>{html.escape(cur)}</code>\n\n"
        f"لینک HTTPS مینی‌اپ خود را بفرستید (مثال: <code>https://app.prostoreshop.site</code>):",
        kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]),
    )


@router.message(Flow.adm_set_webapp_url)
async def handle_adm_set_webapp(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    if val and not val.startswith("https://"):
        await message.answer("⚠️ لینک مینی‌اپ تلگرام باید حتماً با <code>https://</code> شروع شود.", parse_mode="HTML")
        return
    store.data["settings"]["webapp_url"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ لینک مینی‌اپ ذخیره شد: <code>{html.escape(val)}</code>\nدکمه مینی‌اپ در منوی اصلی ربات فعال شد!", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))


# ==================== LIFECYCLE (24/7 SELF-HEALING ARCHITECTURE) ====================
async def run_polling() -> None:
    global _webapp_runner
    configure_logging()
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required.")

    bot = Bot(token=settings.telegram_bot_token)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)

    # 1. Start Background Scanner + Mini App Server INDEPENDENTLY of Telegram polling!
    bg_engine.start()
    try:
        _webapp_runner = await start_mini_app_server(store, bg_engine, cf_service, bot=bot, port=8080)
    except Exception as exc:
        logger.exception("Mini App server could not bind port 8080: %s", exc)

    # 2. Self-healing resilient Telegram polling loop (auto-recovers from overnight API/network drops!)
    backoff = 3
    try:
        while True:
            try:
                logger.info("Starting Cloudflare Config Hub V23 Pro Bot (Always-Alive Mode).")
                await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types(), handle_signals=False)
                backoff = 3
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("Telegram polling interrupted (%s) — auto-reconnecting in %ss...", exc, backoff)
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
