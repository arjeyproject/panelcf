from __future__ import annotations

import asyncio
import logging

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import CommandStart
from aiogram.types import CallbackQuery, Message

from app.bot.keyboards.main import build_main_menu, build_nav_controls
from app.bot.localization.i18n import t
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.security.rate_limit import SlidingWindowRateLimiter

logger = logging.getLogger(__name__)
router = Router()
_bot_limiter = SlidingWindowRateLimiter(max_requests=30, window_seconds=60)
_user_lang: dict[int, str] = {}


def _lang_for(user_id: int) -> str:
    return _user_lang.get(user_id, "fa")


@router.message(CommandStart())
async def cmd_start(message: Message) -> None:
    uid = message.from_user.id if message.from_user else 0
    allowed, _ = _bot_limiter.allow(f"tg:{uid}")
    if not allowed:
        await message.answer("⏳ Rate limit exceeded. Please wait a moment.")
        return
    lang = _lang_for(uid)
    settings = get_settings()
    await message.answer(
        f"{t('welcome', lang)}\n\n{t('menu_prompt', lang)}",
        reply_markup=build_main_menu(lang=lang, miniapp_url=settings.telegram_miniapp_url),
        parse_mode="Markdown",
    )


@router.callback_query(F.data == "nav:home")
async def cb_home(callback: CallbackQuery) -> None:
    lang = _lang_for(callback.from_user.id)
    settings = get_settings()
    if callback.message:
        await callback.message.edit_text(
            t("menu_prompt", lang),
            reply_markup=build_main_menu(lang=lang, miniapp_url=settings.telegram_miniapp_url),
        )
    await callback.answer()


@router.callback_query(F.data == "menu:settings")
async def cb_settings(callback: CallbackQuery) -> None:
    uid = callback.from_user.id
    current = _lang_for(uid)
    next_lang = "en" if current == "fa" else "fa"
    _user_lang[uid] = next_lang
    settings = get_settings()
    if callback.message:
        await callback.message.edit_text(
            f"✅ Language switched to **{next_lang.upper()}**.",
            reply_markup=build_main_menu(lang=next_lang, miniapp_url=settings.telegram_miniapp_url),
            parse_mode="Markdown",
        )
    await callback.answer()


@router.callback_query(F.data.startswith(("proto:", "scan:", "menu:")))
async def cb_sections(callback: CallbackQuery) -> None:
    lang = _lang_for(callback.from_user.id)
    action = callback.data or ""
    descriptions = {
        "proto:wireguard": "⚡ **WireGuard / WARP**\nDistinguishes self-hosted WireGuard peers from registered Cloudflare WARP devices. Open the Mini App or send parameters to validate & export `.conf` / QR.",
        "proto:masque": "🌀 **MASQUE (RFC 9298)**\nHTTP/3 QUIC CONNECT-UDP workflow. Validates ALPN `h3`, SNI, and auth mode without relabeling other protocols.",
        "proto:vless": "🔷 **VLESS**\nValidates RFC 4122 UUID, TLS/Reality parameters, transport (`ws`/`grpc`/`tcp`), and tags user-provided vs. generated fields.",
        "proto:trojan": "🔐 **Trojan**\nValidates TLS SNI and user-provided password without fabricating server credentials.",
        "scan:ip": "🧪 **IP Candidate Scanner**\nMulti-stage TCP/TLS/HTTP probe with jitter, IQR outlier filtering, and SSRF protection.",
        "scan:endpoint": "🎯 **Endpoint Scanner**\nAsync DNS + TCP + TLS SNI verification with protocol compatibility classification.",
        "menu:pool": "📦 **Automated Pool**\n24h scheduled refresh targeting 100 verified IPs and 100 verified endpoints (strict threshold—never padded).",
        "menu:optimizer": "⚙️ **Configuration Optimizer**\nSyntax audit, compatibility matrix, and measurement-backed ranking presets.",
    }
    text = descriptions.get(action, f"📌 Section `{action}` ready. Use the Mini App for rich visual controls or API endpoints for automation.")
    if callback.message:
        await callback.message.edit_text(text, reply_markup=build_nav_controls(lang, retry_cb=action), parse_mode="Markdown")
    await callback.answer()


async def run_polling() -> None:
    configure_logging()
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required to launch the bot.")
    bot = Bot(token=settings.telegram_bot_token)
    dp = Dispatcher()
    dp.include_router(router)
    logger.info("Starting Cloudflare Config Hub Telegram Bot in polling mode.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
