from __future__ import annotations

TEXTS: dict[str, dict[str, str]] = {
    "fa": {
        "home_title": "⚡ <b>Cloudflare Config Hub — V24</b>",
        "home_panel_ok": "🟢 فعال و آپدیت",
        "home_panel_upd": "🟡 نیاز به آپدیت",
        "home_panel_none": "⚪ هنوز ساخته نشده",
        "home_panel_line": "🎛️ پنل شما: <b>{status}</b>",
        "home_pools": "🔵 همراه اول: <b>{mci}</b> | 🟡 ایرانسل: <b>{mtn}</b> | 🟢 مخابرات: <b>{mkh}</b>",
        "home_warp": "🛡️ رله WARP سالم: <b>{v4}</b> IPv4 • <b>{v6}</b> IPv6",
        "home_pick": "👇 گزینه مورد نظر را انتخاب کنید:",
        "banned": "🚫 دسترسی شما مسدود شده است.",
        "maintenance": "🛠️ ربات موقتاً در حال به‌روزرسانی است.",
        "turbo_title": "🚀 <b>ساخت پنل رایگان (VLESS + Trojan)</b>",
        "turbo_body": (
            "1️⃣ اگر اکانت کلودفلر نداری، اول ثبت‌نام کن.\n"
            "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن.\n"
            "3️⃣ در کلودفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
            "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
            "🔐 <i>پیام توکن بلافاصله پاک و رمزنگاری می‌شود. پنل به‌صورت پیش‌فرض بدون ProxyIP (مستقیم و پرسرعت) ساخته می‌شود.</i>"
        ),
        "btn_get_token": "🔑 دریافت مستقیم توکن کلودفلر",
        "btn_cf_signup": "🌐 ثبت‌نام رایگان کلودفلر",
        "btn_my_panel": "🎛️ ورود به پنل من",
        "btn_back": "🔙 بازگشت",
        "btn_home": "🔙 صفحه اول",
        "btn_cancel": "❌ انصراف",
        "bad_token": "⚠️ فرمت توکن نامعتبر است. توکن را بدون فاصله ارسال کنید:",
        "deploying": "⏳ <b>در حال دیپلوی V24 روی Cloudflare Pages و تست واقعی VLESS و Trojan...</b>",
        "deploy_fail": "❌ <b>دیپلوی ناموفق بود:</b>",
        "deploy_ok": "🎉 <b>پنل V24 ({engine}) آماده شد!</b>",
        "panel_empty": "🎛️ <b>پنل من</b>\n━━━━━━━━━━━━━━━━━━━━\nهنوز پنل رایگان نساخته‌اید. روی دکمه سبز زیر بزنید:",
        "btn_create_panel": "🚀 ساخت پنل رایگان (VLESS + Trojan)",
        "panel_title": "🎛️ <b>پنل اختصاصی من</b>",
        "panel_engine": "⚡ موتور: <b>{engine}</b>",
        "panel_domain": "🌐 دامنه: <code>{host}</code>",
        "panel_op": "📶 اپراتور: <b>{op}</b>",
        "panel_proxy_off": "🔀 ProxyIP: <b>⚪ خاموش (اتصال مستقیم و سریع)</b>",
        "panel_proxy_auto": "🔀 ProxyIP: <b>🟢 خودکار ({val})</b>",
        "panel_proxy_on": "🔀 ProxyIP: <b>🟢 فعال ({val})</b>",
        "panel_ver_ok": "📦 نسخه: <b>✅ آپدیت ({ver})</b>",
        "panel_ver_old": "📦 نسخه: <b>⚠️ نیاز به آپدیت — دکمه «آپدیت» را بزنید</b>",
        "panel_pick_op": "اپراتور خود را برای دریافت <b>۶ کانفیگ پرسرعت (۳ VLESS + ۳ Trojan)</b> انتخاب کنید:",
        "op_mci": "🔵 همراه اول",
        "op_mtn": "🟡 ایرانسل",
        "op_mkh": "🟢 مخابرات",
        "btn_e2e": "🩺 تست پنل",
        "btn_updated": "✅ آپدیت هستید",
        "btn_update": "🔄 آپدیت کنید",
        "btn_proxy_menu": "🔀 تنظیمات ProxyIP ({st})",
        "btn_disconnect": "🗑️ حذف پنل",
        "st_on": "روشن",
        "st_off": "خاموش",
        "cfg_title": "🚀 <b>۶ کانفیگ پرسرعت V24 اختصاصی {op}</b>",
        "cfg_proxy_line": "🔀 حالت ProxyIP: <b>{mode}</b>",
        "cfg_sub_title": "🔗 <b>لینک اشتراک خودکار (Auto-Sub):</b>",
        "cfg_note": "⚡ <i>#1 و #2 روی همه کلاینت‌ها فوری پینگ می‌دهند؛ #3 مجهز به ECH ضد فیلتر است.</i>",
        "btn_rotate_ips": "🔄 تعویض با ۳ IP جدید ({op})",
        "proxy_title": "🔀 <b>تنظیمات اختیاری ProxyIP</b>",
        "proxy_desc": (
            "در حالت پیش‌فرض <b>ProxyIP خاموش</b> است تا کانفیگ‌ها مستقیم، بدون اختلال و با بالاترین سرعت وصل شوند.\n"
            "فقط اگر برای سایت‌های پشت کلودفلر نیاز داشتید، از گزینه‌های زیر آن را روشن کنید:"
        ),
        "btn_proxy_disable": "⚪ خاموش کردن ProxyIP (پیشنهادی • مستقیم)",
        "btn_proxy_auto": "⚡ فعال‌سازی خودکار (سریع‌ترین ProxyIP تست‌شده)",
        "btn_proxy_custom": "✏️ وارد کردن ProxyIP اختصاصی",
        "proxy_list_lbl": "یا یکی از ProxyIPهای لیست زیر را انتخاب کنید:",
        "proxy_saved_off": "⚪ ProxyIP خاموش شد (حالت مستقیم فعال).",
        "proxy_saved_auto": "⚡ ProxyIP خودکار روی سریع‌ترین رله فعال شد!",
        "proxy_saved_val": "✅ ProxyIP روی {val} تنظیم و فعال شد.",
        "proxy_ask_custom": "✏️ آدرس ProxyIP اختصاصی خود را بفرستید (مثال: <code>1.2.3.4:443</code> یا <code>proxy.domain.com</code>):",
        "warp_title": "🛡️ <b>کانفیگ‌های WARP و WireGuard</b>",
        "warp_pick": "نسخه IP مورد نظر را انتخاب کنید:",
        "btn_warp_v6": "🌐 IPv6 (پرسرعت و ضد اختلال)",
        "btn_warp_dual": "⚡ Dual-Stack (IPv4 + IPv6)",
        "btn_warp_v4": "🌐 IPv4 (سازگار با همه خطوط)",
        "btn_warp_scan": "🔍 اسکن زنده اندپوینت‌های WARP",
        "warp_pick_os": "دستگاه خود را انتخاب کنید:",
        "btn_ios": "🍏 آیفون (iOS)",
        "btn_android": "🤖 اندروید (Android)",
        "btn_windows": "🪟 ویندوز (Windows)",
        "isp_title": "📶 <b>آی‌پی‌های تمیز بر اساس اپراتور</b>",
        "btn_get_6_op": "⚡ دریافت ۶ کانفیگ {op}",
        "apps_title": "📱 <b>اپلیکیشن‌های پیشنهادی:</b>",
        "guide_title": "📖 <b>راهنمای اتصال سریع</b>",
        "guide_body": (
            "1️⃣ <b>پنل VLESS + Trojan:</b>\n"
            "• کانفیگ‌های <b>#1 (Turbo-TLS)</b> و <b>#2 (AltPort)</b> برای پینگ سریع و پایدار در تمام برنامه‌ها هستند.\n"
            "• اگر ProxyIP خاموش باشد سرعت و پینگ بهترین حالت است؛ در صورت نیاز می‌توانید از دکمه ProxyIP آن را روشن کنید.\n"
            "• در تنظیمات v2rayNG گزینه <b>Enable Mux</b> را خاموش بگذارید.\n\n"
            "2️⃣ <b>کانفیگ WARP:</b>\n"
            "• لینک WARP را در <b>Hiddify</b> یا فایل <code>.conf</code> را در <b>AmneziaWG</b> وارد کنید."
        ),
        "support_title": "💬 <b>پشتیبانی</b>",
        "btn_direct_chat": "💬 چت مستقیم با پشتیبانی",
        "btn_send_ticket": "✉️ ارسال تیکت داخل ربات",
        "ticket_prompt": "✉️ پیام یا مشکل خود را بنویسید:",
        "ticket_sent": "✅ تیکت <b>#{id}</b> ثبت و به مدیریت ارسال شد.",
        "up_to_date_alert": "✅ پنل شما روی آخرین نسخه ({ver}) آپدیت و سالم است!",
        "disconnect_ok": "🗑️ پنل حذف شد.",
    },
    "en": {
        "home_title": "⚡ <b>Cloudflare Config Hub — V24</b>",
        "home_panel_ok": "🟢 Active & Updated",
        "home_panel_upd": "🟡 Update Available",
        "home_panel_none": "⚪ Not Created Yet",
        "home_panel_line": "🎛️ Your Panel: <b>{status}</b>",
        "home_pools": "🔵 MCI: <b>{mci}</b> | 🟡 Irancell: <b>{mtn}</b> | 🟢 TCI: <b>{mkh}</b>",
        "home_warp": "🛡️ Healthy WARP Relays: <b>{v4}</b> IPv4 • <b>{v6}</b> IPv6",
        "home_pick": "👇 Choose an option below:",
        "banned": "🚫 Your access has been restricted.",
        "maintenance": "🛠️ The bot is temporarily under maintenance.",
        "turbo_title": "🚀 <b>Create Free Panel (VLESS + Trojan)</b>",
        "turbo_body": (
            "1️⃣ Sign up for a free Cloudflare account if you don't have one.\n"
            "2️⃣ Tap <b>Get Cloudflare Token</b> below (Pages & Workers permissions are pre-selected).\n"
            "3️⃣ Click <b>Continue to summary</b> → <b>Create Token</b>.\n"
            "4️⃣ Copy the token and <b>paste it here</b>.\n\n"
            "🔐 <i>Your token message is deleted & encrypted immediately. ProxyIP is OFF by default for max speed & stability.</i>"
        ),
        "btn_get_token": "🔑 Get Cloudflare Token",
        "btn_cf_signup": "🌐 Free Cloudflare Sign-up",
        "btn_my_panel": "🎛️ Open My Panel",
        "btn_back": "🔙 Back",
        "btn_home": "🔙 Main Menu",
        "btn_cancel": "❌ Cancel",
        "bad_token": "⚠️ Invalid token format. Please send the token without spaces:",
        "deploying": "⏳ <b>Deploying V24 to Cloudflare Pages & running live VLESS/Trojan tests...</b>",
        "deploy_fail": "❌ <b>Deployment failed:</b>",
        "deploy_ok": "🎉 <b>Panel V24 ({engine}) is ready!</b>",
        "panel_empty": "🎛️ <b>My Panel</b>\n━━━━━━━━━━━━━━━━━━━━\nYou haven't created a panel yet. Tap the button below:",
        "btn_create_panel": "🚀 Create Free Panel (VLESS + Trojan)",
        "panel_title": "🎛️ <b>My Private Panel</b>",
        "panel_engine": "⚡ Engine: <b>{engine}</b>",
        "panel_domain": "🌐 Domain: <code>{host}</code>",
        "panel_op": "📶 Operator: <b>{op}</b>",
        "panel_proxy_off": "🔀 ProxyIP: <b>⚪ OFF (Direct High-Speed)</b>",
        "panel_proxy_auto": "🔀 ProxyIP: <b>🟢 Auto ({val})</b>",
        "panel_proxy_on": "🔀 ProxyIP: <b>🟢 ON ({val})</b>",
        "panel_ver_ok": "📦 Version: <b>✅ Up to date ({ver})</b>",
        "panel_ver_old": "📦 Version: <b>⚠️ Update needed — tap Update</b>",
        "panel_pick_op": "Select an operator to get <b>6 optimized configs (3 VLESS + 3 Trojan)</b>:",
        "op_mci": "🔵 MCI",
        "op_mtn": "🟡 Irancell",
        "op_mkh": "🟢 TCI",
        "btn_e2e": "🩺 Health Test",
        "btn_updated": "✅ Up to Date",
        "btn_update": "🔄 Update Core",
        "btn_proxy_menu": "🔀 ProxyIP ({st})",
        "btn_disconnect": "🗑️ Delete Panel",
        "st_on": "ON",
        "st_off": "OFF",
        "cfg_title": "🚀 <b>6 V24 High-Speed Configs — {op}</b>",
        "cfg_proxy_line": "🔀 ProxyIP Mode: <b>{mode}</b>",
        "cfg_sub_title": "🔗 <b>Auto-Updating Subscription (Auto-Sub):</b>",
        "cfg_note": "⚡ <i>#1 & #2 give instant ping on every client; #3 uses ECH Shield for strict DPI.</i>",
        "btn_rotate_ips": "🔄 Rotate 3 Fresh IPs ({op})",
        "proxy_title": "🔀 <b>Optional ProxyIP Settings</b>",
        "proxy_desc": (
            "By default, <b>ProxyIP is OFF</b> so connections route directly through Cloudflare Edge without public-proxy lag.\n"
            "Enable it only if you need access to Cloudflare-hosted websites:"
        ),
        "btn_proxy_disable": "⚪ Turn OFF ProxyIP (Recommended • Direct)",
        "btn_proxy_auto": "⚡ Enable Auto ProxyIP (Fastest Live-Tested)",
        "btn_proxy_custom": "✏️ Enter Custom ProxyIP",
        "proxy_list_lbl": "Or pick a verified ProxyIP from the list below:",
        "proxy_saved_off": "⚪ ProxyIP disabled (Direct mode active).",
        "proxy_saved_auto": "⚡ Auto ProxyIP enabled with fastest relay!",
        "proxy_saved_val": "✅ ProxyIP set to {val}.",
        "proxy_ask_custom": "✏️ Send your custom ProxyIP (e.g. <code>1.2.3.4:443</code> or <code>proxy.domain.com</code>):",
        "warp_title": "🛡️ <b>WARP & WireGuard Configs</b>",
        "warp_pick": "Select IP version:",
        "btn_warp_v6": "🌐 IPv6 (Fast & Anti-DPI)",
        "btn_warp_dual": "⚡ Dual-Stack (IPv4 + IPv6)",
        "btn_warp_v4": "🌐 IPv4 (Universal)",
        "btn_warp_scan": "🔍 Live WARP Endpoint Scan",
        "warp_pick_os": "Select your device:",
        "btn_ios": "🍏 iPhone (iOS)",
        "btn_android": "🤖 Android",
        "btn_windows": "🪟 Windows",
        "isp_title": "📶 <b>Clean Edge IPs by Operator</b>",
        "btn_get_6_op": "⚡ Get 6 Configs ({op})",
        "apps_title": "📱 <b>Recommended Client Apps:</b>",
        "guide_title": "📖 <b>Quick Connection Guide</b>",
        "guide_body": (
            "1️⃣ <b>VLESS + Trojan Panel:</b>\n"
            "• Configs <b>#1 (Turbo-TLS)</b> and <b>#2 (AltPort)</b> provide instant ping and maximum speed on all clients.\n"
            "• Keep ProxyIP OFF for best stability; turn it ON only when needed.\n"
            "• In v2rayNG settings, keep <b>Enable Mux</b> turned OFF.\n\n"
            "2️⃣ <b>WARP Configs:</b>\n"
            "• Import the WARP link in <b>Hiddify</b> or the <code>.conf</code> file in <b>AmneziaWG</b>."
        ),
        "support_title": "💬 <b>Support</b>",
        "btn_direct_chat": "💬 Direct Chat with Support",
        "btn_send_ticket": "✉️ Submit Ticket",
        "ticket_prompt": "✉️ Write your message or issue:",
        "ticket_sent": "✅ Ticket <b>#{id}</b> submitted to admin.",
        "up_to_date_alert": "✅ Your panel is already on the latest version ({ver})!",
        "disconnect_ok": "🗑️ Panel deleted.",
    },
}


def tr(lang: str, key: str, **kwargs) -> str:
    d = TEXTS.get(lang, TEXTS["fa"])
    raw = d.get(key, TEXTS["fa"].get(key, key))
    return raw.format(**kwargs) if kwargs else raw


def op_label(op: str, lang: str = "fa") -> str:
    return tr(lang, f"op_{op}") if op in ("mci", "mtn", "mkh") else op
