from __future__ import annotations

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, WebAppInfo

from app.bot.localization.i18n import t


def build_main_menu(lang: str = "fa", miniapp_url: str = "") -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    if miniapp_url.startswith("https://"):
        rows.append([InlineKeyboardButton(text=t("btn_miniapp", lang), web_app=WebAppInfo(url=miniapp_url))])

    rows.extend([
        [InlineKeyboardButton(text=t("btn_build_fast", lang), callback_data="menu:build_fast")],
        [
            InlineKeyboardButton(text=t("btn_wireguard", lang), callback_data="proto:wireguard"),
            InlineKeyboardButton(text=t("btn_masque", lang), callback_data="proto:masque"),
        ],
        [
            InlineKeyboardButton(text=t("btn_vless", lang), callback_data="proto:vless"),
            InlineKeyboardButton(text=t("btn_trojan", lang), callback_data="proto:trojan"),
        ],
        [
            InlineKeyboardButton(text=t("btn_ip_scanner", lang), callback_data="scan:ip"),
            InlineKeyboardButton(text=t("btn_ep_scanner", lang), callback_data="scan:endpoint"),
        ],
        [
            InlineKeyboardButton(text=t("btn_tester", lang), callback_data="menu:tester"),
            InlineKeyboardButton(text=t("btn_optimizer", lang), callback_data="menu:optimizer"),
        ],
        [
            InlineKeyboardButton(text=t("btn_pool", lang), callback_data="menu:pool"),
            InlineKeyboardButton(text=t("btn_qr", lang), callback_data="menu:qr"),
        ],
        [
            InlineKeyboardButton(text=t("btn_my_configs", lang), callback_data="menu:my_configs"),
            InlineKeyboardButton(text=t("btn_favorites", lang), callback_data="menu:favorites"),
        ],
        [
            InlineKeyboardButton(text=t("btn_net_tools", lang), callback_data="menu:net_tools"),
            InlineKeyboardButton(text=t("btn_tutorials", lang), callback_data="menu:tutorials"),
        ],
        [
            InlineKeyboardButton(text=t("btn_account", lang), callback_data="menu:account"),
            InlineKeyboardButton(text=t("btn_rewards", lang), callback_data="menu:rewards"),
        ],
        [
            InlineKeyboardButton(text=t("btn_referral", lang), callback_data="menu:referral"),
            InlineKeyboardButton(text=t("btn_news", lang), callback_data="menu:news"),
        ],
        [
            InlineKeyboardButton(text=t("btn_support", lang), callback_data="menu:support"),
            InlineKeyboardButton(text=t("btn_settings", lang), callback_data="menu:settings"),
        ],
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def build_nav_controls(lang: str = "fa", retry_cb: str | None = None) -> InlineKeyboardMarkup:
    row = [InlineKeyboardButton(text=t("btn_back", lang), callback_data="nav:home")]
    if retry_cb:
        row.append(InlineKeyboardButton(text=t("btn_retry", lang), callback_data=retry_cb))
    row.append(InlineKeyboardButton(text=t("btn_cancel", lang), callback_data="nav:cancel"))
    return InlineKeyboardMarkup(inline_keyboard=[row])
