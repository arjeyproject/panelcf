from __future__ import annotations

from typing import Literal

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, WebAppInfo

ButtonStyle = Literal["primary", "success", "danger"]

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
    "%5D&accountId=*&zoneId=all&name=CFHubV23"
)
CLOUDFLARE_SIGNUP_URL = "https://dash.cloudflare.com/sign-up"

_NATIVE_STYLE = "style" in getattr(InlineKeyboardButton, "model_fields", {})


class StyledButton(InlineKeyboardButton):
    style: str | None = None


def btn(
    text: str, *, callback_data: str | None = None, url: str | None = None, web_app: WebAppInfo | None = None, style: ButtonStyle | None = None,
) -> InlineKeyboardButton:
    kwargs: dict = {"text": text}
    if callback_data is not None: kwargs["callback_data"] = callback_data
    if url is not None: kwargs["url"] = url
    if web_app is not None: kwargs["web_app"] = web_app
    if style is not None: kwargs["style"] = style
    if _NATIVE_STYLE or style is None:
        return InlineKeyboardButton(**kwargs)
    return StyledButton(**kwargs)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def main_menu_kb(is_admin: bool = False, has_panel: bool = False, lang: str = "fa", webapp_url: str = "") -> InlineKeyboardMarkup:
    if lang == "en":
        top = [btn("🎛️ My Panel (3 VLESS + 3 Trojan)", callback_data="m:mypanel", style="success")] if has_panel else [btn("🚀 Create Free Panel (VLESS + Trojan)", callback_data="m:turbo", style="success")]
        rows = [
            top,
            [btn("🛡️ WARP / WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
            [btn("📶 Clean IPs by Operator", callback_data="m:isp", style="primary")],
            [btn("📱 Apps", callback_data="m:apps", style="primary"), btn("📖 Guide", callback_data="m:guide", style="primary")],
            [btn("💬 Support", callback_data="m:support", style="primary"), btn("🇮🇷 فارسی", callback_data="m:lang", style="primary")],
        ]
        if webapp_url.startswith("https://"):
            rows.insert(1, [btn("🌐 Open Mini App", web_app=WebAppInfo(url=webapp_url), style="success")])
        if is_admin:
            rows.append([btn("🛠️ Admin Panel", callback_data="adm:home", style="danger")])
        return kb(rows)

    top = [btn("🎛️ پنل من (VLESS + Trojan)", callback_data="m:mypanel", style="success")] if has_panel else [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")]
    rows = [
        top,
        [btn("🛡️ کانفیگ WARP و WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
        [btn("📶 آی‌پی تمیز اپراتورها", callback_data="m:isp", style="primary")],
        [btn("📱 برنامه‌ها", callback_data="m:apps", style="primary"), btn("📖 آموزش اتصال", callback_data="m:guide", style="primary")],
        [btn("💬 پشتیبانی", callback_data="m:support", style="primary"), btn("🌐 English", callback_data="m:lang", style="primary")],
    ]
    if webapp_url.startswith("https://"):
        rows.insert(1, [btn("🌐 باز کردن مینی‌اپ (Mini App)", web_app=WebAppInfo(url=webapp_url), style="success")])
    if is_admin:
        rows.append([btn("🛠️ پنل مدیریت", callback_data="adm:home", style="danger")])
    return kb(rows)


def back_home_kb(back_cb: str = "m:home", lang: str = "fa") -> InlineKeyboardMarkup:
    return kb([[btn("🔙 بازگشت" if lang == "fa" else "🔙 Back", callback_data=back_cb, style="primary")]])
