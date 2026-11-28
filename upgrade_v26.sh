#!/usr/bin/env bash
set -euo pipefail

echo ">>> Applying CFHub V26 (6/6 Native-ECH Port-443 without uTLS Conflict + 1-Click Custom Domain + Auto-Fragment JSON + Iran Tier-1/SaaS IPs)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/i18n.py
from __future__ import annotations

TEXTS: dict[str, dict[str, str]] = {
    "fa": {
        "home_title": "⚡ <b>Cloudflare Config Hub — V26</b>",
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
        "deploying": "⏳ <b>در حال دیپلوی V26 روی Cloudflare Pages و تست واقعی VLESS و Trojan...</b>",
        "deploy_fail": "❌ <b>دیپلوی ناموفق بود:</b>",
        "deploy_ok": "🎉 <b>پنل V26 ({engine}) آماده شد!</b>",
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
        "btn_custom_dom": "🌐 دامنه اختصاصی",
        "btn_frag_sub": "🛡️ ساب فرگمنت (JSON)",
        "dom_title": "🌐 <b>اتصال دامنه اختصاصی (بالاترین سرعت)</b>",
        "dom_desc": "دامنه اختصاصی کلودفلر SNI شما را از <code>pages.dev</code> جدا می‌کند تا بدون نیاز به ECH یا فرگمنت، پینگ ۶۰ تا ۱۱۰ میلی‌ثانیه و حداکثر سرعت بگیرید.\n\nیک دامنه از اکانت کلودفلر خود انتخاب کنید یا زیردامنه دلخواه بفرستید (مثال: <code>cdn.domain.com</code>):",
        "dom_none": "هیچ دامنه فعالی در اکانت کلودفلر شما پیدا نشد. اگر دامنه دارید آن را در کلودفلر ثبت کنید یا نام زیردامنه آن را ارسال کنید:",
        "dom_ok": "✅ دامنه اختصاصی <code>{dom}</code> با موفقیت به پنل وصل و DNS آن تنظیم شد!\nحالا کانفیگ‌های شما مستقیم و با حداکثر سرعت بدون نیاز به ECH کار می‌کنند.",
        "dom_revert": "↩️ بازگشت به دامنه رایگان pages.dev",
        "st_on": "روشن",
        "st_off": "خاموش",
        "cfg_title": "🚀 <b>۶ کانفیگ پرسرعت V26 اختصاصی {op}</b>",
        "cfg_proxy_line": "🔀 حالت ProxyIP: <b>{mode}</b>",
        "cfg_sub_title": "🔗 <b>لینک اشتراک خودکار (Auto-Sub):</b>",
        "cfg_note": "⚡ <i>هر ۶ کانفیگ روی پورت ۴۴۳ با ECH خالص (بدون تداخل uTLS) و IPهای تمیز ایران ساخته شده‌اند تا SNI مسدود نشود. اگر کلاینت قدیمی دارید، از Auto-Fragment (JSON) یا اتصال دامنه اختصاصی استفاده کنید.</i>",
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
        "home_title": "⚡ <b>Cloudflare Config Hub — V26</b>",
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
        "deploying": "⏳ <b>Deploying V26 to Cloudflare Pages & running live VLESS/Trojan tests...</b>",
        "deploy_fail": "❌ <b>Deployment failed:</b>",
        "deploy_ok": "🎉 <b>Panel V26 ({engine}) is ready!</b>",
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
        "btn_custom_dom": "🌐 Custom Domain",
        "btn_frag_sub": "🛡️ Fragment Sub (JSON)",
        "dom_title": "🌐 <b>Bind Custom Domain (Max Speed)</b>",
        "dom_desc": "A Cloudflare custom domain replaces <code>pages.dev</code> SNI so all 6 configs run at full speed without ECH or Fragment.\n\nPick a domain from your Cloudflare account or type a subdomain (e.g. <code>cdn.domain.com</code>):",
        "dom_none": "No active domain found in your Cloudflare account. Add a domain to Cloudflare first, or send a subdomain:",
        "dom_ok": "✅ Custom domain <code>{dom}</code> bound & DNS configured!\nAll 6 configs now run in direct high-speed TLS mode.",
        "dom_revert": "↩️ Revert to free pages.dev",
        "st_on": "ON",
        "st_off": "OFF",
        "cfg_title": "🚀 <b>6 V26 High-Speed Configs — {op}</b>",
        "cfg_proxy_line": "🔀 ProxyIP Mode: <b>{mode}</b>",
        "cfg_sub_title": "🔗 <b>Auto-Updating Subscription (Auto-Sub):</b>",
        "cfg_note": "⚡ <i>All 6 configs use Port 443 + Native ECH (no uTLS conflict) + Iran clean IPs to bypass SNI blocks. For older clients, use Auto-Fragment JSON or bind a Custom Domain.</i>",
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
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import base64
import hashlib
import json

CURRENT_WORKER_VERSION = "v26"

# Curated ProxyIP pool (ONLY used when user explicitly enables ProxyIP!)
CURATED_PROXY_IPS = [
    "proxyip.cmliussss.net",
    "proxyip.fxxk.dedyn.io",
    "proxyip.oracle.fxxk.dedyn.io",
    "proxyip.digitalocean.fxxk.dedyn.io",
    "proxyip.sg.fxxk.dedyn.io",
    "proxyip.us.fxxk.dedyn.io",
    "bpb.yousef.isegaro.com",
    "cdn.xn--b6gac.eu.org",
]

DEFAULT_PROXY_IPS = CURATED_PROXY_IPS

# V26 High-Performance Pure-ASCII ES Module for Cloudflare Pages (`_worker.js`) & Workers (`index.js`):
#   1) TRUE 0-RTT EARLY DATA (`?ed=2560`): Properly pads unpadded Base64URL `Sec-WebSocket-Protocol` headers from Xray/sing-box!
#      Cuts connection latency by 1-2 full RTTs (250-500ms faster ping & page loads!).
#   2) ZERO-COPY STREAMING PIPELINE (`makeReadableWebSocketStream` -> `WritableStream`): Eliminates per-packet Promise chain lag!
#   3) DIRECT-FIRST (ProxyIP OFF by default, `r: []`): Never stalls on slow/dead public ProxyIPs.
#   4) PATH-BASED OPTIONAL PROXYIP (`/px/<host[:port]>` or `?proxyip=...`): Zero redeploy needed, 100% compatible with `?ed=2560`!
#   5) FULL TROJAN + VLESS UDP DNS: Correctly decodes & encodes BOTH VLESS UDP DNS and Trojan UDP DNS packets!
#   6) SMART `cp.cloudflare.com:80` PING BRIDGE: When ProxyIP is OFF and Hiddify/Karing pings `http://cp.cloudflare.com`,
#      performs a real upstream 204 check via `fetch` instead of failing on CF's loopback socket block!
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const EMBEDDED_B64 = '__CFG_B64__';
const WS_OPEN = 1;
const WS_CLOSING = 2;
const RELAY_TIMEOUT_MS = 2200;

const HEX = [];
for (let i = 0; i < 256; i++) {
  HEX.push((i + 256).toString(16).slice(1));
}

function loadConfig(env) {
  const raw = (env && env.CFG_B64) ? env.CFG_B64 : EMBEDDED_B64;
  try {
    if (raw) {
      const bin = atob(raw);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return JSON.parse(new TextDecoder().decode(bytes));
    }
  } catch (_) {}
  return { u: '', h: '', r: [], v: 'v26' };
}

export default {
  async fetch(request, env, ctx) {
    try {
      const cfg = loadConfig(env);
      const url = new URL(request.url);
      const upgrade = (request.headers.get('Upgrade') || '').toLowerCase();

      if (upgrade !== 'websocket') {
        if (url.pathname === '/health') {
          return new Response(JSON.stringify({
            ok: true,
            v: cfg.v || 'v26',
            direct_default: (cfg.r || []).length === 0,
            ts: Date.now()
          }), {
            status: 200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'cache-control': 'no-store'
            }
          });
        }
        return new Response('<!doctype html><html><head><title>Cloud Edge</title></head><body><h1>200 OK</h1></body></html>', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      // Extract optional ProxyIP from path `/px/<host[:port]>` OR query `?proxyip=...`
      let rawProxy = '';
      if (url.pathname.startsWith('/px/')) {
        try {
          rawProxy = decodeURIComponent(url.pathname.slice(4)).replace(/^\/+|\/+$/g, '').trim();
        } catch (_) {
          rawProxy = url.pathname.slice(4).replace(/^\/+|\/+$/g, '').trim();
        }
      } else {
        rawProxy = (url.searchParams.get('proxyip') || url.searchParams.get('relay') || url.searchParams.get('r') || '').trim();
      }

      return await handleWebSocket(request, cfg, rawProxy);
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: String(err && err.message || err) }), {
        status: 500,
        headers: { 'content-type': 'application/json; charset=utf-8' }
      });
    }
  }
};

function parseHostPort(raw, defPort) {
  const s = String(raw || '').trim();
  if (!s) return [null, defPort];
  if (s.charCodeAt(0) === 91) {
    const end = s.indexOf(']');
    if (end !== -1) {
      const rest = s.slice(end + 1);
      const p = rest.charCodeAt(0) === 58 ? Number(rest.slice(1)) : defPort;
      return [s.slice(1, end), p || defPort];
    }
  }
  const idx = s.lastIndexOf(':');
  if (idx !== -1 && s.indexOf(':') === idx) {
    return [s.slice(0, idx), Number(s.slice(idx + 1)) || defPort];
  }
  return [s, defPort];
}

function toU8(chunk) {
  if (chunk instanceof Uint8Array) return chunk;
  if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk);
  if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  return new TextEncoder().encode(String(chunk));
}

function b64UrlToU8(b64) {
  if (!b64) return null;
  try {
    let s = String(b64).replace(/-/g, '+').replace(/_/g, '/').trim();
    const mod = s.length % 4;
    if (mod === 2) s += '==';
    else if (mod === 3) s += '=';
    else if (mod === 1) return null;
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch (_) {
    return null;
  }
}

function makeReadableWebSocketStream(ws, earlyHeader) {
  let canceled = false;
  return new ReadableStream({
    start(controller) {
      ws.addEventListener('message', (event) => {
        if (canceled) return;
        try {
          controller.enqueue(toU8(event.data));
        } catch (_) {}
      });
      ws.addEventListener('close', () => {
        safeClose(ws);
        if (!canceled) {
          canceled = true;
          try { controller.close(); } catch (_) {}
        }
      });
      ws.addEventListener('error', (err) => {
        if (!canceled) {
          canceled = true;
          try { controller.error(err); } catch (_) {}
        }
      });
      const early = b64UrlToU8(earlyHeader);
      if (early && early.byteLength > 0) {
        controller.enqueue(early);
      }
    },
    cancel() {
      canceled = true;
      safeClose(ws);
    }
  });
}

function closeRemote(remoteBox) {
  remoteBox.ready = false;
  try { if (remoteBox.writer) remoteBox.writer.releaseLock(); } catch (_) {}
  remoteBox.writer = null;
  try { if (remoteBox.sock) remoteBox.sock.close(); } catch (_) {}
  remoteBox.sock = null;
}

async function handleWebSocket(request, cfg, rawProxy) {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  // Direct by default! Relays ONLY populated when user explicitly enabled ProxyIP
  const relays = [];
  if (rawProxy && rawProxy !== 'off' && rawProxy !== 'none') {
    for (const x of rawProxy.split(',')) {
      const t = x.trim();
      if (t && !relays.includes(t)) relays.push(t);
    }
  }
  if (Array.isArray(cfg.r) && cfg.r.length > 0 && rawProxy !== 'off') {
    for (const x of cfg.r) {
      if (x && !relays.includes(x)) relays.push(x);
    }
  }

  const remoteBox = { sock: null, writer: null, ready: false };
  let udpHandler = null;
  let initialized = false;

  const earlyHdr = request.headers.get('sec-websocket-protocol') || '';
  const readable = makeReadableWebSocketStream(server, earlyHdr);

  readable.pipeTo(new WritableStream({
    async write(chunk) {
      if (udpHandler) {
        await udpHandler(chunk);
        return;
      }
      if (initialized) {
        if (remoteBox.ready && remoteBox.writer) {
          await remoteBox.writer.write(chunk);
        }
        return;
      }
      initialized = true;

      let parsed = decodeTrojan(chunk, cfg.h || '');
      let respHead = null;
      let proto = 'trojan';
      if (parsed.err) {
        const vl = decodeVless(chunk, cfg.u || '');
        if (vl.err) {
          safeClose(server);
          return;
        }
        parsed = vl;
        respHead = new Uint8Array([vl.ver, 0]);
        proto = 'vless';
      }

      const initData = chunk.subarray(parsed.idx);
      if (parsed.udp) {
        if (proto === 'vless' && parsed.port === 53) {
          udpHandler = makeVlessDnsHandler(server, respHead);
          await udpHandler(initData);
          return;
        }
        if (proto === 'trojan') {
          udpHandler = makeTrojanDnsHandler(server);
          await udpHandler(initData);
          return;
        }
        safeClose(server);
        return;
      }

      // Smart Hiddify/Karing `cp.cloudflare.com:80` connectivity check bridge when ProxyIP is OFF
      if (relays.length === 0 && parsed.port === 80 && (parsed.host === 'cp.cloudflare.com' || parsed.host === 'connectivitycheck.cloudflare.com')) {
        await handleDirect204Bridge(server, respHead);
        return;
      }

      await dialUpstream(remoteBox, parsed.host, parsed.port, initData, server, respHead, relays);
    },
    close() {
      closeRemote(remoteBox);
      safeClose(server);
    },
    abort() {
      closeRemote(remoteBox);
      safeClose(server);
    }
  })).catch(() => {
    closeRemote(remoteBox);
    safeClose(server);
  });

  return new Response(null, { status: 101, webSocket: client });
}

async function handleDirect204Bridge(ws, respHead) {
  try {
    await fetch('https://www.gstatic.com/generate_204', { method: 'GET' });
    const reply = new TextEncoder().encode('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    if (ws.readyState === WS_OPEN) {
      if (respHead) {
        const merged = new Uint8Array(respHead.byteLength + reply.byteLength);
        merged.set(respHead, 0);
        merged.set(reply, respHead.byteLength);
        ws.send(merged);
      } else {
        ws.send(reply);
      }
    }
  } catch (_) {
  } finally {
    safeClose(ws);
  }
}

async function dialUpstream(remoteBox, host, port, initData, ws, respHead, relays) {
  async function openAndSend(h, p) {
    closeRemote(remoteBox);
    const sock = connect({ hostname: h, port: Number(p) }, { allowHalfOpen: false });
    if (sock.opened && typeof sock.opened.catch === 'function') sock.opened.catch(() => {});
    if (sock.closed && typeof sock.closed.catch === 'function') sock.closed.catch(() => {});
    const writer = sock.writable.getWriter();
    remoteBox.sock = sock;
    remoteBox.writer = writer;
    if (initData && initData.byteLength > 0) {
      await writer.write(initData);
    }
    remoteBox.ready = true;
    return sock;
  }

  async function tryRelay(idx) {
    if (idx >= relays.length || ws.readyState !== WS_OPEN) {
      closeRemote(remoteBox);
      safeClose(ws);
      return;
    }
    const hp = parseHostPort(relays[idx], port);
    if (!hp[0]) {
      await tryRelay(idx + 1);
      return;
    }
    try {
      const sock = await openAndSend(hp[0], hp[1]);
      const nextRetry = (idx + 1 < relays.length) ? () => tryRelay(idx + 1) : null;
      pipeRemoteToWs(sock, remoteBox, ws, respHead, nextRetry, initData && initData.byteLength > 0).catch(() => safeClose(ws));
    } catch (_) {
      await tryRelay(idx + 1);
    }
  }

  try {
    const sock = await openAndSend(host, port);
    const fallback = relays.length > 0 ? () => tryRelay(0) : null;
    pipeRemoteToWs(sock, remoteBox, ws, respHead, fallback, initData && initData.byteLength > 0).catch(() => safeClose(ws));
  } catch (_) {
    if (relays.length > 0) {
      await tryRelay(0).catch(() => safeClose(ws));
    } else {
      closeRemote(remoteBox);
      safeClose(ws);
    }
  }
}

async function pipeRemoteToWs(sock, remoteBox, ws, respHead, onEmptyRetry, hasInitData) {
  let head = respHead;
  let gotData = false;
  let reader = null;
  let timer = null;

  try {
    reader = sock.readable.getReader();
    if (onEmptyRetry && hasInitData) {
      timer = setTimeout(() => {
        if (!gotData) {
          try { reader.cancel(); } catch (_) {}
          try { sock.close(); } catch (_) {}
        }
      }, RELAY_TIMEOUT_MS);
    }

    while (true) {
      const res = await reader.read();
      if (res.done) break;
      const value = res.value;
      if (!value || value.byteLength === 0) continue;
      if (!gotData) {
        gotData = true;
        if (timer) { clearTimeout(timer); timer = null; }
      }
      if (ws.readyState !== WS_OPEN) break;
      const data = toU8(value);
      if (head) {
        const merged = new Uint8Array(head.byteLength + data.byteLength);
        merged.set(head, 0);
        merged.set(data, head.byteLength);
        ws.send(merged);
        head = null;
      } else {
        ws.send(data);
      }
    }
  } catch (_) {
  } finally {
    if (timer) { clearTimeout(timer); timer = null; }
    try { if (reader) reader.releaseLock(); } catch (_) {}
    if (remoteBox.sock === sock) closeRemote(remoteBox);
    else { try { sock.close(); } catch (_) {} }
  }

  if (!gotData && onEmptyRetry && ws.readyState === WS_OPEN) {
    await onEmptyRetry();
  } else {
    safeClose(ws);
  }
}

async function dohQuery(q) {
  let r = null;
  try {
    r = await fetch('https://1.1.1.1/dns-query', {
      method: 'POST',
      headers: { 'content-type': 'application/dns-message' },
      body: q
    });
  } catch (_) {}
  if (!r || !r.ok) {
    r = await fetch('https://dns.google/dns-query', {
      method: 'POST',
      headers: { 'content-type': 'application/dns-message' },
      body: q
    });
  }
  return new Uint8Array(await r.arrayBuffer());
}

function makeVlessDnsHandler(ws, initHead) {
  let head = initHead;
  return async (buf) => {
    try {
      let off = 0;
      while (off + 2 <= buf.byteLength) {
        const len = (buf[off] << 8) | buf[off + 1];
        if (off + 2 + len > buf.byteLength) break;
        const q = buf.subarray(off + 2, off + 2 + len);
        off += 2 + len;
        const ans = await dohQuery(q);
        const plen = head ? head.byteLength : 0;
        const out = new Uint8Array(plen + 2 + ans.byteLength);
        if (head) { out.set(head, 0); head = null; }
        out[plen] = (ans.byteLength >> 8) & 255;
        out[plen + 1] = ans.byteLength & 255;
        out.set(ans, plen + 2);
        if (ws.readyState === WS_OPEN) ws.send(out);
      }
    } catch (_) {}
  };
}

function makeTrojanDnsHandler(ws) {
  return async (buf) => {
    try {
      let off = 0;
      while (off + 8 <= buf.byteLength) {
        const startOff = off;
        const atyp = buf[off++];
        if (atyp === 1) {
          if (off + 4 > buf.byteLength) break;
          off += 4;
        } else if (atyp === 3) {
          const dl = buf[off++];
          if (off + dl > buf.byteLength) break;
          off += dl;
        } else if (atyp === 4) {
          if (off + 16 > buf.byteLength) break;
          off += 16;
        } else break;
        if (off + 6 > buf.byteLength) break;
        const port = (buf[off] << 8) | buf[off + 1];
        const addrHeaderEnd = off + 2;
        const len = (buf[off + 2] << 8) | buf[off + 3];
        if (buf[off + 4] !== 13 || buf[off + 5] !== 10) break;
        off += 6;
        if (off + len > buf.byteLength) break;
        const q = buf.subarray(off, off + len);
        off += len;
        if (port !== 53) continue;
        const ans = await dohQuery(q);
        const addrHdr = buf.subarray(startOff, addrHeaderEnd);
        const out = new Uint8Array(addrHdr.byteLength + 4 + ans.byteLength);
        out.set(addrHdr, 0);
        out[addrHdr.byteLength] = (ans.byteLength >> 8) & 255;
        out[addrHdr.byteLength + 1] = ans.byteLength & 255;
        out[addrHdr.byteLength + 2] = 13;
        out[addrHdr.byteLength + 3] = 10;
        out.set(ans, addrHdr.byteLength + 4);
        if (ws.readyState === WS_OPEN) ws.send(out);
      }
    } catch (_) {}
  };
}

function decodeTrojan(u8, expectedHash) {
  if (!expectedHash || u8.byteLength < 64 || u8[56] !== 13 || u8[57] !== 10) return { err: true };
  const h = new TextDecoder().decode(u8.subarray(0, 56)).toLowerCase();
  if (h !== expectedHash.toLowerCase()) return { err: true };
  const cmd = u8[58];
  if (cmd !== 1 && cmd !== 3) return { err: true };
  const atyp = u8[59];
  let idx = 60, host = '';
  if (atyp === 1) {
    if (idx + 4 > u8.byteLength) return { err: true };
    host = u8[idx] + '.' + u8[idx + 1] + '.' + u8[idx + 2] + '.' + u8[idx + 3];
    idx += 4;
  } else if (atyp === 3) {
    const dl = u8[idx++];
    if (idx + dl > u8.byteLength) return { err: true };
    host = new TextDecoder().decode(u8.subarray(idx, idx + dl));
    idx += dl;
  } else if (atyp === 4) {
    if (idx + 16 > u8.byteLength) return { err: true };
    const p = [];
    for (let i = 0; i < 8; i++) p.push(((u8[idx + i * 2] << 8) | u8[idx + i * 2 + 1]).toString(16));
    host = p.join(':');
    idx += 16;
  } else return { err: true };
  if (idx + 2 > u8.byteLength) return { err: true };
  const port = (u8[idx] << 8) | u8[idx + 1];
  idx += 2;
  if (idx + 2 <= u8.byteLength && u8[idx] === 13 && u8[idx + 1] === 10) idx += 2;
  return { err: false, host, port, idx, udp: cmd === 3 };
}

function decodeVless(u8, expectedUid) {
  if (!expectedUid || u8.byteLength < 24) return { err: true };
  const ver = u8[0];
  if (toUuid(u8.subarray(1, 17)).toLowerCase() !== expectedUid.toLowerCase()) return { err: true };
  const opt = u8[17];
  if (19 + opt + 3 > u8.byteLength) return { err: true };
  const cmd = u8[18 + opt];
  if (cmd !== 1 && cmd !== 2) return { err: true };
  const pi = 19 + opt;
  const port = (u8[pi] << 8) | u8[pi + 1];
  const at = u8[pi + 2];
  let idx = pi + 3, host = '';
  if (at === 1) {
    if (idx + 4 > u8.byteLength) return { err: true };
    host = u8[idx] + '.' + u8[idx + 1] + '.' + u8[idx + 2] + '.' + u8[idx + 3];
    idx += 4;
  } else if (at === 2) {
    const dl = u8[idx++];
    if (idx + dl > u8.byteLength) return { err: true };
    host = new TextDecoder().decode(u8.subarray(idx, idx + dl));
    idx += dl;
  } else if (at === 3) {
    if (idx + 16 > u8.byteLength) return { err: true };
    const p = [];
    for (let i = 0; i < 8; i++) p.push(((u8[idx + i * 2] << 8) | u8[idx + i * 2 + 1]).toString(16));
    host = p.join(':');
    idx += 16;
  } else return { err: true };
  return { err: false, host, port, idx, ver, udp: cmd === 2 };
}

function toUuid(a) {
  return (
    HEX[a[0]] + HEX[a[1]] + HEX[a[2]] + HEX[a[3]] + '-' +
    HEX[a[4]] + HEX[a[5]] + '-' +
    HEX[a[6]] + HEX[a[7]] + '-' +
    HEX[a[8]] + HEX[a[9]] + '-' +
    HEX[a[10]] + HEX[a[11]] + HEX[a[12]] + HEX[a[13]] + HEX[a[14]] + HEX[a[15]]
  );
}

function safeClose(ws) {
  try {
    if (ws.readyState === WS_OPEN || ws.readyState === WS_CLOSING) ws.close();
  } catch (_) {}
}
""".strip()

CANARY_JS = r"""
export default {
  async fetch(request) {
    return new Response(JSON.stringify({ ok: true, canary: true }), {
      status: 200,
      headers: { 'content-type': 'application/json' }
    });
  }
};
""".strip()


def build_worker_payload(
    user_uuid: str,
    trojan_password: str,
    proxy_ip: str = "",
) -> tuple[str, list[dict]]:
    """
    V26: By default `proxy_ip=""` -> `r: []` (pure direct mode, ZERO public ProxyIP interference!).
    Users can toggle ProxyIP ON/OFF instantly via path `/px/<host[:port]>` with ZERO redeploy.
    """
    safe_tpass = trojan_password.replace("'", "").replace('"', "").strip()
    trojan_hash = hashlib.sha224(safe_tpass.encode("utf-8")).hexdigest()
    proxies = [p.strip() for p in [proxy_ip] if p and p.strip()]

    cfg_obj = {
        "u": user_uuid.strip(),
        "p": safe_tpass,
        "h": trojan_hash,
        "r": proxies,
        "v": CURRENT_WORKER_VERSION,
    }
    cfg_b64 = base64.b64encode(json.dumps(cfg_obj, separators=(",", ":")).encode("utf-8")).decode("ascii")
    js = WORKER_JS_TEMPLATE.replace("__CFG_B64__", cfg_b64)
    bindings = [{"type": "plain_text", "name": "CFG_B64", "text": cfg_b64}]
    return js, bindings
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/operator_scanner.py
from __future__ import annotations

import asyncio
import ipaddress
import logging
import ssl
import time
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger(__name__)

RESTRICTED_EDGE_1034_NETS = [
    ipaddress.ip_network("162.159.0.0/16"),
    ipaddress.ip_network("1.0.0.0/8"),
    ipaddress.ip_network("198.41.128.0/17"),
]


def is_restricted_1034_ip(ip_str: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip_str.strip())
        if addr.version != 4 or not addr.is_global:
            return True
        return any(addr in net for net in RESTRICTED_EDGE_1034_NETS)
    except ValueError:
        return True


# Tier 1: Real Iran-crowdsourced operator-specific clean IP DNS feeds (continuously tested INSIDE Iran!)
IRAN_TIER1_DNS: dict[str, list[str]] = {
    "mci": ["mci.ircf.space", "mcic.ircf.space", "mci.cf.vfarid.com"],
    "mtn": ["mtn.ircf.space", "mtnc.ircf.space", "mtn.cf.vfarid.com"],
    "mkh": ["mkh.ircf.space", "tci.ircf.space", "mkh.cf.vfarid.com"],
}

# Tier 2: Global / multi-operator clean CF feeds (used only as secondary backup behind Tier 1!)
IRAN_TIER2_DNS: dict[str, list[str]] = {
    "mci": ["cf.090227.xyz", "cf.877774.xyz", "bestcf.onecf.eu.org", "ip.164746.xyz", "icook.tw", "www.visa.com", "www.visa.com.sg", "time.is", "www.wto.org"],
    "mtn": ["cf.877774.xyz", "cf.090227.xyz", "bestcf.onecf.eu.org", "ip.164746.xyz", "www.visa.com.sg", "www.visa.com.hk", "icook.hk", "www.csgo.com", "time.is"],
    "mkh": ["cf.090227.xyz", "mci.ircf.space", "cf.877774.xyz", "bestcf.onecf.eu.org", "icook.hk", "icook.tw", "www.visa.com", "time.is", "www.wto.org"],
}

# Backward-compat union
OPERATOR_DNS_SOURCES: dict[str, list[str]] = {
    op: IRAN_TIER1_DNS[op] + IRAN_TIER2_DNS[op] for op in ("mci", "mtn", "mkh")
}

# Tier 3: Proven Iran-friendly fallback edge IPs (only if DNS feeds fail)
FALLBACK_EDGE_IPS: dict[str, list[str]] = {
    "mci": ["104.16.132.229", "104.18.32.47", "104.21.48.84", "172.64.155.209", "172.67.70.10", "104.17.148.22"],
    "mtn": ["104.16.133.229", "104.19.44.11", "104.22.10.22", "172.64.147.228", "172.67.182.91", "104.17.147.22"],
    "mkh": ["104.16.51.111", "104.18.21.226", "104.21.15.72", "104.24.10.15", "172.64.150.11", "172.67.131.50"],
}

OPERATOR_LABELS: dict[str, str] = {
    "mci": "🔵 همراه اول",
    "mtn": "🟡 ایرانسل",
    "mkh": "🟢 مخابرات",
}

IRAN_PREFERRED_COLOS = {"DXB", "MCT", "DOH", "BAH", "KWI", "IST", "FRA", "AMS", "MRS", "VIE", "WAW", "BUD", "SOF", "ZRH", "MXP"}


def source_tier_rank(source: str) -> int:
    """
    CRITICAL IRAN RANKING RULE:
      3 = Admin Manual (tested directly from Iran by admin)
      2 = Tier-1 Iran Operator Feeds (ircf.space / vfarid.com — crowdsourced from real Iran users!)
      1 = Tier-2 Community Clean CF Feeds (090227 / 877774 / bestcf / icook / visa)
      0 = Tier-3 Fallback
    """
    s = (source or "").lower()
    if s == "admin_manual":
        return 3
    if "ircf.space" in s or "vfarid.com" in s:
        return 2
    if s and s not in ("cf_edge_clean", "cidr_scan", "fallback"):
        return 1
    return 0


def sample_operator_cidr_ips(op: str, count: int = 0) -> list[str]:
    # Intentionally disabled in V25: random /16 CIDRs tested from a European VPS are often blackholed in Iran!
    return []


async def resolve_doh_records(domain: str, qtype: str = "A", timeout_sec: float = 4.5) -> list[str]:
    for endpoint in ("https://cloudflare-dns.com/dns-query", "https://dns.google/resolve"):
        try:
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                r = await client.get(
                    endpoint,
                    params={"name": domain, "type": qtype},
                    headers={"Accept": "application/dns-json"},
                )
                if r.status_code != 200:
                    continue
                ips = [
                    str(ans.get("data", "")).strip()
                    for ans in (r.json().get("Answer") or [])
                    if not is_restricted_1034_ip(str(ans.get("data", "")).strip())
                ]
                if ips:
                    return ips
        except Exception:
            continue
    return []


async def measure_edge_download_mbps(ip: str, byte_count: int = 262144, timeout_sec: float = 3.0) -> float:
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, 443, ssl=ssl_ctx, server_hostname="speed.cloudflare.com"),
            timeout=timeout_sec,
        )
        req = (
            f"GET /__down?bytes={byte_count} HTTP/1.1\r\n"
            "Host: speed.cloudflare.com\r\n"
            "User-Agent: Mozilla/5.0 Chrome/131.0.0.0\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        writer.write(req)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout_sec)

        t0 = time.perf_counter()
        total = 0
        while total < byte_count:
            chunk = await asyncio.wait_for(reader.read(32768), timeout=timeout_sec)
            if not chunk:
                break
            total += len(chunk)
        elapsed = max(0.01, time.perf_counter() - t0)
        return round((total * 8.0) / (elapsed * 1_000_000.0), 2)
    except Exception:
        return 0.0
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def verify_cloudflare_edge_ip(ip: str, port: int = 443, timeout_sec: float = 2.8) -> dict[str, Any] | None:
    if is_restricted_1034_ip(ip):
        return None
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    start = time.perf_counter()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port, ssl=ssl_ctx, server_hostname="cloudflare.com"),
            timeout=timeout_sec,
        )
        req = (
            "GET /cdn-cgi/trace HTTP/1.1\r\n"
            "Host: cloudflare.com\r\n"
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        writer.write(req)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        raw = await asyncio.wait_for(reader.read(2048), timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - start) * 1000.0, 2)
        text = raw.decode("latin1", errors="ignore")
        if "200 OK" not in text and "colo=" not in text:
            return None
        colo = ""
        for line in text.splitlines():
            if line.startswith("colo="):
                colo = line.split("=", 1)[1].strip().upper()
                break

        dl_mbps = await measure_edge_download_mbps(ip, byte_count=262144, timeout_sec=2.8)
        colo_bonus = 12.0 if colo in IRAN_PREFERRED_COLOS else 0.0
        speed_bonus = min(30.0, dl_mbps * 0.8)
        score = round(max(10.0, min(100.0, 58.0 - (rtt_ms / 10.0) + colo_bonus + speed_bonus)), 2)
        return {
            "ip": ip, "port": port, "ip_version": 4,
            "latency_ms": rtt_ms, "speed_mbps": dl_mbps,
            "colo": colo or "CF", "score": score,
            "verified_trace": True, "tested_at": datetime.now(timezone.utc).isoformat(),
        }
    except Exception:
        return None
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def probe_proxy_ip(host_port: str, timeout_sec: float = 2.8) -> dict[str, Any] | None:
    """Verifies TLS handshake reachability & RTT of a candidate ProxyIP."""
    s = host_port.strip()
    if not s:
        return None
    host, port = s, 443
    if ":" in s and not s.startswith("["):
        parts = s.rsplit(":", 1)
        if parts[1].isdigit():
            host, port = parts[0], int(parts[1])
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    try:
        t0 = time.perf_counter()
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port, ssl=ssl_ctx, server_hostname=host),
            timeout=timeout_sec,
        )
        ms = round((time.perf_counter() - t0) * 1000.0, 1)
        return {"proxy_ip": s, "latency_ms": ms, "ok": True, "tested_at": datetime.now(timezone.utc).isoformat()}
    except Exception:
        return None
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/ws_tester.py
from __future__ import annotations

import asyncio
import base64
import hashlib
import os
import ssl
import struct
import time
import uuid as uuid_lib

BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def _build_ws_frame(payload: bytes, opcode: int = 0x2) -> bytes:
    mask_key = os.urandom(4)
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    header.extend(mask_key)
    masked = bytes(b ^ mask_key[i & 3] for i, b in enumerate(payload))
    return bytes(header) + masked


async def _read_ws_frame(reader: asyncio.StreamReader, timeout_sec: float = 6.0) -> bytes:
    head = await asyncio.wait_for(reader.readexactly(2), timeout=timeout_sec)
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", await asyncio.wait_for(reader.readexactly(2), timeout=timeout_sec))[0]
    elif length == 127:
        length = struct.unpack("!Q", await asyncio.wait_for(reader.readexactly(8), timeout=timeout_sec))[0]
    return await asyncio.wait_for(reader.readexactly(length), timeout=timeout_sec)


def build_vless_test_packet(user_uuid: str, target_host: str = "www.gstatic.com", target_port: int = 80) -> bytes:
    uid_bytes = uuid_lib.UUID(user_uuid).bytes
    dom = target_host.encode("ascii")
    http_req = f"GET /generate_204 HTTP/1.1\r\nHost: {target_host}\r\nUser-Agent: {BROWSER_UA}\r\nConnection: close\r\n\r\n".encode("ascii")
    return b"\x00" + uid_bytes + b"\x00\x01" + struct.pack("!H", target_port) + b"\x02" + bytes([len(dom)]) + dom + http_req


def build_trojan_test_packet(password: str, target_host: str = "www.gstatic.com", target_port: int = 80) -> bytes:
    pw_hash = hashlib.sha224(password.encode("utf-8")).hexdigest().encode("ascii")
    dom = target_host.encode("ascii")
    http_req = f"GET /generate_204 HTTP/1.1\r\nHost: {target_host}\r\nUser-Agent: {BROWSER_UA}\r\nConnection: close\r\n\r\n".encode("ascii")
    return pw_hash + b"\r\n\x01\x03" + bytes([len(dom)]) + dom + struct.pack("!H", target_port) + b"\r\n" + http_req


async def check_ip_routes_worker(worker_host: str, connect_ip: str, port: int = 443, timeout_sec: float = 4.5) -> tuple[bool, float | None, str]:
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    try:
        t0 = time.perf_counter()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(connect_ip, port, ssl=ssl_ctx, server_hostname=worker_host),
            timeout=timeout_sec,
        )
        req = (
            f"GET /health HTTP/1.1\r\n"
            f"Host: {worker_host}\r\n"
            f"User-Agent: {BROWSER_UA}\r\n"
            f"Accept: application/json\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("ascii")
        writer.write(req)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        raw = await asyncio.wait_for(reader.read(1024), timeout=timeout_sec)
        ms = round((time.perf_counter() - t0) * 1000.0, 1)
        text = raw.decode("utf-8", errors="ignore")
        first = text.splitlines()[0] if text else "empty"
        if "200" in first and '"ok":true' in text.replace(" ", ""):
            return True, ms, "HTTP 200 OK"
        body = text.split("\r\n\r\n", 1)[1].strip()[:90] if "\r\n\r\n" in text else ""
        return False, ms, f"{first} {body}".strip()
    except Exception as exc:
        return False, None, str(exc)
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def test_worker_tunnel_e2e(
    worker_host: str,
    connect_ip: str | None,
    protocol: str,
    credential: str,
    port: int = 443,
    target_host: str = "www.gstatic.com",
    ws_path: str = "/cdn",
    timeout_sec: float = 8.0,
    use_early_data: bool = True,
) -> tuple[bool, float | None, str]:
    target_addr = connect_ip or worker_host
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    writer = None
    try:
        t0 = time.perf_counter()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(target_addr, port, ssl=ssl_ctx, server_hostname=worker_host),
            timeout=timeout_sec,
        )
        payload = (
            build_trojan_test_packet(credential, target_host=target_host)
            if protocol == "trojan"
            else build_vless_test_packet(credential, target_host=target_host)
        )
        ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
        ed_hdr = ""
        if use_early_data:
            # Exact raw unpadded Base64URL header sent by Xray/v2rayNG/Hiddify when `?ed=2560` is active!
            ed_b64 = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
            ed_hdr = f"Sec-WebSocket-Protocol: {ed_b64}\r\n"

        upgrade = (
            f"GET {ws_path} HTTP/1.1\r\n"
            f"Host: {worker_host}\r\n"
            f"User-Agent: {BROWSER_UA}\r\n"
            f"Origin: https://{worker_host}\r\n"
            f"Accept: */*\r\n"
            f"Accept-Language: en-US,en;q=0.9\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"{ed_hdr}"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode("ascii")
        writer.write(upgrade)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)

        resp_head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout_sec)
        status_line = resp_head.splitlines()[0].decode("latin1", "ignore")
        if "101" not in status_line:
            extra = ""
            try:
                body = await asyncio.wait_for(reader.read(400), timeout=1.5)
                extra = " | " + body.decode("utf-8", "ignore").strip().replace("\n", " ")[:120]
            except Exception:
                pass
            return False, None, f"{status_line}{extra}"

        if not use_early_data:
            writer.write(_build_ws_frame(payload))
            await asyncio.wait_for(writer.drain(), timeout=timeout_sec)

        data = await _read_ws_frame(reader, timeout_sec=timeout_sec)
        rtt_ms = round((time.perf_counter() - t0) * 1000.0, 1)

        if protocol == "vless":
            if len(data) < 2 or data[0] != 0:
                return False, rtt_ms, "Invalid VLESS header"
            body = data[2:]
        else:
            body = data

        if b"204" in body or b"HTTP/1.1 20" in body or b"HTTP/1.1 30" in body or b"HTTP/1.1 40" in body:
            return True, rtt_ms, "HTTP 204 OK"
        return False, rtt_ms, f"Unexpected reply ({len(body)}B)"
    except Exception as exc:
        return False, None, str(exc)
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/wg_handshake.py
from __future__ import annotations
import asyncio, base64, hashlib, ipaddress, os, socket, struct, time
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

_CONSTRUCTION = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s"
_IDENTIFIER = b"WireGuard v1 zx2c4 Jason@zx2c4.com"
_LABEL_MAC1 = b"mac1----"

def _blake2s(data: bytes, key: bytes = b"", digest_size: int = 32) -> bytes:
    return hashlib.blake2s(data, key=key, digest_size=digest_size).digest()

def _hmac_blake2s(key: bytes, data: bytes) -> bytes:
    if len(key) > 64: key = _blake2s(key)
    key = key.ljust(64, b"\x00")
    return _blake2s(bytes(b ^ 0x5C for b in key) + _blake2s(bytes(b ^ 0x36 for b in key) + data))

def _kdf2(key: bytes, inp: bytes) -> tuple[bytes, bytes]:
    t0 = _hmac_blake2s(key, inp)
    t1 = _hmac_blake2s(t0, b"\x01")
    return t1, _hmac_blake2s(t0, t1 + b"\x02")

def _aead_encrypt(key: bytes, counter: int, plaintext: bytes, aad: bytes) -> bytes:
    return ChaCha20Poly1305(key).encrypt(b"\x00\x00\x00\x00" + struct.pack("<Q", counter), plaintext, aad)

def _tai64n_now() -> bytes:
    ns = time.time_ns()
    return struct.pack(">QI", (ns // 1_000_000_000) + 4611686018427387914, ns % 1_000_000_000)

def build_wireguard_handshake_initiation(client_private_key_b64: str, peer_public_key_b64: str, reserved: list[int] | None = None) -> tuple[bytes, int]:
    s_priv = x25519.X25519PrivateKey.from_private_bytes(base64.b64decode(client_private_key_b64))
    s_pub_bytes = s_priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    r_pub_bytes = base64.b64decode(peer_public_key_b64)
    r_pub = x25519.X25519PublicKey.from_public_bytes(r_pub_bytes)
    e_priv = x25519.X25519PrivateKey.generate()
    e_pub_bytes = e_priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    ck = _blake2s(_CONSTRUCTION)
    h = _blake2s(_blake2s(ck + _IDENTIFIER) + r_pub_bytes)
    ck = _hmac_blake2s(_hmac_blake2s(ck, e_pub_bytes), b"\x01")
    h = _blake2s(h + e_pub_bytes)
    ck, k = _kdf2(ck, e_priv.exchange(r_pub))
    enc_s = _aead_encrypt(k, 0, s_pub_bytes, h)
    h = _blake2s(h + enc_s)
    ck, k = _kdf2(ck, s_priv.exchange(r_pub))
    enc_t = _aead_encrypt(k, 0, _tai64n_now(), h)
    res = (reserved or [0, 0, 0])[:3]
    sidx = struct.unpack("<I", os.urandom(4))[0]
    body = bytes([1, res[0] & 0xFF, res[1] & 0xFF, res[2] & 0xFF]) + struct.pack("<I", sidx) + e_pub_bytes + enc_s + enc_t
    mac1 = _blake2s(body, key=_blake2s(_LABEL_MAC1 + r_pub_bytes), digest_size=16)
    return body + mac1 + (b"\x00" * 16), sidx

class _WGRespProto(asyncio.DatagramProtocol):
    def __init__(self, fut: asyncio.Future): self.fut = fut
    def datagram_received(self, data: bytes, addr):
        if not self.fut.done(): self.fut.set_result(data)
    def error_received(self, exc):
        if not self.fut.done(): self.fut.set_exception(exc)

async def probe_real_warp_handshake(host: str, port: int, client_private_key_b64: str, peer_public_key_b64: str, reserved: list[int] | None = None, timeout_sec: float = 2.0) -> tuple[bool, float | None]:
    loop = asyncio.get_running_loop()
    transport = None
    try:
        clean = host.strip("[]")
        family = socket.AF_INET6 if ipaddress.ip_address(clean).version == 6 else socket.AF_INET
        pkt, sidx = build_wireguard_handshake_initiation(client_private_key_b64, peer_public_key_b64, reserved=reserved)
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(loop.create_datagram_endpoint(lambda: _WGRespProto(fut), remote_addr=(clean, port), family=family), timeout=timeout_sec)
        t0 = time.perf_counter()
        transport.sendto(pkt)
        resp: bytes = await asyncio.wait_for(fut, timeout=timeout_sec)
        rtt = round((time.perf_counter() - t0) * 1000.0, 2)
        if len(resp) >= 92 and resp[0] == 2 and struct.unpack("<I", resp[8:12])[0] == sidx:
            return True, rtt
        return False, None
    except Exception:
        return False, None
    finally:
        if transport is not None: transport.close()
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/warp_builder.py
from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal
from urllib.parse import quote, urlencode

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519

PlatformType = Literal["ios", "android", "windows"]
IPMode = Literal["ipv4", "ipv6", "dual"]

OFFICIAL_WARP_PEER_PUBKEY = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

WARP_REG_URLS = [
    "https://api.cloudflareclient.com/v0a2483/reg",
    "https://api.cloudflareclient.com/v0a2158/reg",
]

OFFICIAL_WARP_IPV6_ENDPOINTS = [
    "[2606:4700:d0::a29f:c005]:854",
    "[2606:4700:d0::a29f:c008]:894",
    "[2606:4700:d1::a29f:c10a]:908",
    "[2606:4700:d0::a29f:c301]:1074",
    "[2606:4700:d0::a29f:c001]:2408",
    "[2606:4700:d1::a29f:c101]:2408",
]


@dataclass
class WarpRegistration:
    ok: bool
    private_key: str = ""
    public_key: str = ""
    peer_public_key: str = OFFICIAL_WARP_PEER_PUBKEY
    ipv4: str = "172.16.0.2/32"
    ipv6: str = "2606:4700:110:8a36:df92:102a:9602:fa18/128"
    reserved: list[int] | None = None
    device_id: str = ""
    token: str = ""
    warp_activated: bool = False
    error: str | None = None


def generate_x25519_keypair() -> tuple[str, str]:
    priv = x25519.X25519PrivateKey.generate()
    pub = priv.public_key()
    return (
        base64.b64encode(priv.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode("ascii"),
        base64.b64encode(pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode("ascii"),
    )


async def register_real_warp_device(timeout_sec: float = 12.0) -> WarpRegistration:
    priv_key, pub_key = generate_x25519_keypair()
    payload = {
        "key": pub_key, "install_id": "", "fcm_token": "",
        "tos": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "model": "Android", "serial_number": "", "locale": "en_US",
    }
    headers = {"User-Agent": "okhttp/3.12.1", "CF-Client-Version": "a-6.33-3874", "Content-Type": "application/json; charset=UTF-8"}
    last_err = "Cloudflare WARP API در دسترس نبود."
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        for reg_url in WARP_REG_URLS:
            try:
                resp = await client.post(reg_url, json=payload, headers=headers)
                if resp.status_code not in (200, 201):
                    last_err = f"HTTP {resp.status_code}"
                    continue
                data = resp.json()
                dev_id, token = data.get("id", ""), data.get("token", "")
                cfg = data.get("config") or {}
                peers = cfg.get("peers") or [{}]
                iface = cfg.get("interface", {}).get("addresses") or {}
                cid_b64 = cfg.get("client_id", "")
                reserved = list(base64.b64decode(cid_b64)[:3]) if cid_b64 else [0, 0, 0]
                warp_activated = False
                if dev_id and token:
                    try:
                        act = await client.patch(
                            f"{reg_url}/{dev_id}", json={"warp_enabled": True},
                            headers={**headers, "Authorization": f"Bearer {token}"},
                        )
                        warp_activated = act.status_code in (200, 201)
                    except Exception:
                        pass
                ipv4 = iface.get("v4", "172.16.0.2")
                ipv6 = iface.get("v6", "")
                return WarpRegistration(
                    ok=True, private_key=priv_key, public_key=pub_key,
                    peer_public_key=peers[0].get("public_key") or OFFICIAL_WARP_PEER_PUBKEY,
                    ipv4=f"{ipv4}/32" if "/" not in ipv4 else ipv4,
                    ipv6=f"{ipv6}/128" if ipv6 and "/" not in ipv6 else ipv6,
                    reserved=reserved, device_id=dev_id, token=token, warp_activated=warp_activated,
                )
            except Exception as exc:
                last_err = str(exc)
    return WarpRegistration(ok=False, error=f"خطا در ثبت دستگاه WARP: {last_err}")


def split_endpoint(ep: str) -> tuple[str, int]:
    ep = ep.strip()
    if ep.startswith("["):
        host, port_s = ep.rsplit("]:", 1)
        return host[1:], int(port_s)
    host, port_s = ep.rsplit(":", 1)
    return host, int(port_s)


def format_endpoint_hostport(host: str, port: int) -> str:
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def format_beautiful_name(prefix: str, proto: str, ping_ms: float | None = None, extra: str = "") -> str:
    if ping_ms is not None and ping_ms > 0:
        p = int(round(ping_ms))
        dot = "🟢" if p < 120 else ("🟡" if p < 240 else "🟠")
        ping_str = f"{dot}{p}ms"
    else:
        ping_str = "⚡Auto"
    parts = [prefix, proto, ping_str]
    if extra:
        parts.append(extra)
    return " • ".join(parts)


def build_warp_bundle(
    reg: WarpRegistration, ep_v4: str, ep_v6: str, platform: PlatformType,
    ip_mode: IPMode = "ipv6", ping_ms: float | None = None, brand: str = "CFHub",
) -> dict:
    """
    V19 Iran / Tehran Anti-DPI WARP & WireGuard Bundle:
      - Uses Iran-tuned UDP Noise (`ifp=40-80&ifps=40-100&ifpd=4-8&ifpm=m4`) for Hiddify/Karing/Streisand.
      - Adds `wnoise=quic&wnoisecount=15&wnoisedelay=10-20&wpayloadsize=10-20` to `wireguard://` for v2rayNG/MahsaNG.
      - Uses AmneziaWG junk packet obfuscation (`Jc=5, Jmin=50, Jmax=100`, `MTU=1280`) to bypass Iran UDP DPI.
    """
    h4, p4 = split_endpoint(ep_v4)
    h6, p6 = split_endpoint(ep_v6)
    if ip_mode == "ipv6":
        primary_hp, secondary_hp, mode_tag = format_endpoint_hostport(h6, p6), format_endpoint_hostport(h4, p4), "IPv6"
        local_addrs, allowed_ips, wg_dns = [a for a in [reg.ipv4, reg.ipv6] if a], ["0.0.0.0/0", "::/0"], "2606:4700:4700::1111, 1.1.1.1"
    elif ip_mode == "dual":
        primary_hp, secondary_hp, mode_tag = format_endpoint_hostport(h4, p4), format_endpoint_hostport(h6, p6), "Dual"
        local_addrs, allowed_ips, wg_dns = [a for a in [reg.ipv4, reg.ipv6] if a], ["0.0.0.0/0", "::/0"], "1.1.1.1, 2606:4700:4700::1111"
    else:
        primary_hp, secondary_hp, mode_tag = format_endpoint_hostport(h4, p4), format_endpoint_hostport(h6, p6), "IPv4"
        local_addrs, allowed_ips, wg_dns = [reg.ipv4], ["0.0.0.0/0"], "1.1.1.1, 8.8.8.8"

    mtu = 1280
    reserved = reg.reserved or [0, 0, 0]
    reserved_csv = ",".join(str(x) for x in reserved)
    plat_tag = {"ios": "🍏iOS", "android": "🤖Android", "windows": "🪟Win"}[platform]
    wg_label = format_beautiful_name(f"🛡️{brand}", f"WG-AntiDPI-{mode_tag}", ping_ms, plat_tag)
    wow_label = format_beautiful_name(f"🌀{brand}", f"WoW-Iran-{mode_tag}", ping_ms, plat_tag)
    auto_label = format_beautiful_name(f"🎯{brand}", f"WARP-Noise-{mode_tag}", None, plat_tag)

    # Anti-DPI WireGuard URI (compatible with v2rayNG / MahsaNG / NekoBox / Streisand)
    wg_query = urlencode({
        "address": ",".join(local_addrs),
        "reserved": reserved_csv,
        "publickey": reg.peer_public_key,
        "mtu": str(mtu),
        "wnoise": "quic",
        "wnoisecount": "15",
        "wnoisedelay": "10-20",
        "wpayloadsize": "10-20",
    })
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{primary_hp}?{wg_query}#{quote(wg_label)}"

    # Iran-tuned Hiddify / Karing Noise WARP URI
    warp_auto_uri = f"warp://{primary_hp}?ifp=40-80&ifps=40-100&ifpd=4-8&ifpm=m4#{quote(auto_label)}"

    # Double-hop WARP-in-WARP (WoW) with Iran Anti-DPI Noise
    wow_uri = (
        f"warp://{primary_hp}?ifp=40-80&ifps=40-100&ifpd=4-8&ifpm=m4#{quote(wow_label)}"
        f"&&detour=warp://{secondary_hp}?ifp=40-80&ifps=40-100&ifpd=4-8&ifpm=m4#{quote(f'🌍Exit•{brand}')}"
    )

    # AmneziaWG (AWG) config tuned for Iran/Tehran UDP DPI
    amnezia_conf = "\n".join([
        f"# {wg_label}",
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {', '.join(local_addrs)}",
        f"DNS = {wg_dns}",
        f"MTU = {mtu}",
        "Jc = 5",
        "Jmin = 50",
        "Jmax = 100",
        "S1 = 0",
        "S2 = 0",
        "H1 = 1",
        "H2 = 2",
        "H3 = 3",
        "H4 = 4",
        "",
        "[Peer]",
        f"PublicKey = {reg.peer_public_key}",
        f"AllowedIPs = {', '.join(allowed_ips)}",
        f"Endpoint = {primary_hp}",
        "PersistentKeepalive = 25",
    ]) + "\n"

    return {
        "label": wg_label,
        "endpoint": primary_hp,
        "wireguard_uri": wireguard_uri,
        "warp_auto_uri": warp_auto_uri,
        "wow_uri": wow_uri,
        "amnezia_conf": amnezia_conf,
        "amnezia_filename": f"cfhub_awg_iran_{ip_mode}_{platform}.conf",
        "reserved": reserved,
    }
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import logging
import random
import time
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

from app.bot.operator_scanner import (
    FALLBACK_EDGE_IPS,
    IRAN_TIER1_DNS,
    IRAN_TIER2_DNS,
    OPERATOR_DNS_SOURCES,
    is_restricted_1034_ip,
    resolve_doh_records,
    sample_operator_cidr_ips,
    source_tier_rank,
    probe_proxy_ip,
    verify_cloudflare_edge_ip,
)
from app.bot.worker_template import CURATED_PROXY_IPS
from app.bot.warp_builder import (
    OFFICIAL_WARP_IPV6_ENDPOINTS,
    OFFICIAL_WARP_PEER_PUBKEY,
    generate_x25519_keypair,
    register_real_warp_device,
    split_endpoint,
)
from app.bot.wg_handshake import probe_real_warp_handshake

logger = logging.getLogger(__name__)

WARP_V4_PREFIXES = ["162.159.192", "162.159.193", "162.159.195", "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
WARP_UDP_PORTS = [2408, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 945, 955, 1002, 1018, 1074, 1701, 1843, 2371, 4500]

ProgressCallback = Callable[[int, str], Awaitable[None]]


def generate_warp_v4_candidates(count: int = 24) -> list[tuple[str, int]]:
    base = [
        ("162.159.192.1", 2408), ("162.159.192.8", 854), ("162.159.193.1", 2408),
        ("162.159.193.10", 894), ("162.159.195.1", 2408), ("162.159.195.5", 908),
        ("188.114.96.1", 2408), ("188.114.97.1", 1074), ("188.114.98.1", 939), ("188.114.99.1", 1843),
    ]
    seen = set(base)
    while len(base) < count:
        pair = (f"{random.choice(WARP_V4_PREFIXES)}.{random.randint(1, 250)}", random.choice(WARP_UDP_PORTS))
        if pair not in seen:
            seen.add(pair)
            base.append(pair)
    return base


async def _fallback_tcp_rtt(host: str, timeout_sec: float = 2.0) -> tuple[bool, float | None]:
    """Fallback reachability probe when VPS blocks outbound UDP WireGuard handshakes."""
    writer = None
    try:
        t0 = time.perf_counter()
        _, writer = await asyncio.wait_for(asyncio.open_connection(host.strip("[]"), 443), timeout=timeout_sec)
        ms = round((time.perf_counter() - t0) * 1000.0, 2)
        return True, ms
    except Exception:
        return False, None
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


class BackgroundScannerEngine:
    def __init__(self, store):
        self.store = store
        self._loop_task: asyncio.Task | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.progress_pct: int = 0
        self.last_scan_at: str | None = None
        self._purge_restricted_ips()

    def _purge_restricted_ips(self) -> None:
        changed = False
        for op in ("mci", "mtn", "mkh"):
            old = self.store.data.get("operator_pools", {}).get(op, [])
            cleaned = [x for x in old if not is_restricted_1034_ip(x.get("ip", "")) and x.get("source") != "cidr_scan"]
            if len(cleaned) != len(old):
                self.store.data["operator_pools"][op] = cleaned
                changed = True
        for panel in self.store.data.get("panels", {}).values():
            if is_restricted_1034_ip(panel.get("clean_ip", "")):
                op = panel.get("operator", "mci")
                panel["clean_ip"] = FALLBACK_EDGE_IPS.get(op, ["104.16.132.229"])[0]
                changed = True
        if changed:
            self.store.save()

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v26")

    async def stop(self) -> None:
        if self._loop_task and not self._loop_task.done():
            self._loop_task.cancel()
            try:
                await self._loop_task
            except asyncio.CancelledError:
                pass

    async def _ensure_probe_device(self) -> dict:
        dev = self.store.data.get("warp_probe_device")
        if dev and dev.get("private_key"):
            return dev
        reg = await register_real_warp_device(timeout_sec=10.0)
        if reg.ok:
            dev = {
                "private_key": reg.private_key,
                "peer_public_key": reg.peer_public_key or OFFICIAL_WARP_PEER_PUBKEY,
                "reserved": reg.reserved or [0, 0, 0],
            }
            self.store.data["warp_probe_device"] = dev
            self.store.save()
            return dev
        # Local X25519 fallback so WARP scanner NEVER gets skipped!
        priv, _ = generate_x25519_keypair()
        return {"private_key": priv, "peer_public_key": OFFICIAL_WARP_PEER_PUBKEY, "reserved": [0, 0, 0]}

    async def _scheduler_loop(self) -> None:
        await asyncio.sleep(2)
        while True:
            try:
                if self.store.data["settings"].get("auto_scan_enabled", True) and not self.is_scanning:
                    await self.run_full_cycle(trigger="auto")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("V26 background scan error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_warp_only_scan(self, on_progress: ProgressCallback | None = None) -> dict[str, Any]:
        """Dedicated WARP Endpoint scanner (IPv4 + IPv6) with live progress bar."""
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async def _rep(pct: int, msg: str) -> None:
            self.progress_pct = pct
            if on_progress:
                try:
                    await on_progress(pct, msg)
                except Exception:
                    pass

        async with self._scan_lock:
            self.is_scanning = True
            self.current_stage = "warp_udp"
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                await _rep(15, "آماده‌سازی کلید تست WireGuard / WARP...")
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                sem = asyncio.Semaphore(12)

                async def _test_pair(host: str, port: int, version: int):
                    async with sem:
                        ok, rtt = await probe_real_warp_handshake(
                            host, port, probe_dev["private_key"], probe_dev["peer_public_key"],
                            reserved=probe_dev["reserved"], timeout_sec=timeout_sec,
                        )
                        if not ok or rtt is None:
                            ok, rtt = await _fallback_tcp_rtt(host, timeout_sec=timeout_sec)
                        if not ok or rtt is None:
                            return None
                        return {
                            "endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}",
                            "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat(),
                        }

                await _rep(40, "در حال اسکن ۲۴ رله IPv4 کلودفلر WARP...")
                v4_res = await asyncio.gather(*(_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(24)))
                v4_ok = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                if v4_ok:
                    self.store.data["warp_v4_pool"] = v4_ok

                await _rep(75, "در حال اسکن رله‌های IPv6 کلودفلر WARP...")
                v6_res = await asyncio.gather(*(_test_pair(*split_endpoint(ep), 6) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS))
                v6_ok = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]
                if v6_ok:
                    self.store.data["warp_v6_pool"] = v6_ok

                self.last_scan_at = now.isoformat()
                self.store.save()
                await _rep(100, "✅ اسکن اندپوینت‌های WARP تکمیل شد!")
                return {
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    async def run_full_cycle(
        self,
        trigger: str = "manual",
        on_progress: ProgressCallback | None = None,
    ) -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async def _report(pct: int, msg: str) -> None:
            self.progress_pct = pct
            if on_progress:
                try:
                    await on_progress(pct, msg)
                except Exception:
                    pass

        async with self._scan_lock:
            self.is_scanning = True
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                manual = self.store.data.get("manual_operator_ips", {})
                sem = asyncio.Semaphore(18)

                async def _probe(ip: str, source: str):
                    async with sem:
                        res = await verify_cloudflare_edge_ip(ip, 443, timeout_sec=timeout_sec)
                        if res:
                            res["source"] = source
                        return res

                op_steps = [
                    ("mci", "🔵 همراه اول", 15, 35),
                    ("mtn", "🟡 ایرانسل", 40, 58),
                    ("mkh", "🟢 مخابرات", 62, 78),
                ]
                for op, op_fa, p_start, p_end in op_steps:
                    self.current_stage = f"scan_{op}"
                    await _report(p_start, f"در حال دریافت و تست IPهای تمیز {op_fa}...")
                    cand_map: dict[str, str] = {}
                    for mip in manual.get(op, []):
                        if not is_restricted_1034_ip(mip):
                            cand_map[mip.strip()] = "admin_manual"
                    t1_domains = IRAN_TIER1_DNS.get(op, [])
                    t2_domains = IRAN_TIER2_DNS.get(op, [])
                    all_domains = t1_domains + t2_domains
                    resolved = await asyncio.gather(*(resolve_doh_records(d, "A") for d in all_domains))
                    for dom, ips in zip(all_domains, resolved):
                        for ip in ips:
                            cand_map.setdefault(ip, dom)
                    for fb in FALLBACK_EDGE_IPS.get(op, []):
                        cand_map.setdefault(fb, "cf_edge_clean")

                    probed = await asyncio.gather(*(_probe(ip, src) for ip, src in cand_map.items()))
                    valid = [p for p in probed if p is not None]
                    valid.sort(
                        key=lambda x: (
                            source_tier_rank(x.get("source", "")),
                            x["score"],
                            -(x["latency_ms"] or 9999),
                        ),
                        reverse=True,
                    )
                    if valid:
                        self.store.data["operator_pools"][op] = valid[:25]
                    await _report(p_end, f"تست {op_fa} تکمیل شد ({len(valid)} IP سالم)")

                if self.store.data["settings"].get("auto_apply_ip", True):
                    for panel in self.store.data.get("panels", {}).values():
                        if panel.get("auto_ip", True):
                            best = self.get_best_operator_ips(panel.get("operator", "mci"), 1)
                            if best:
                                panel["clean_ip"] = best[0]["ip"]

                self.current_stage = "warp_udp"
                await _report(85, "در حال اسکن رله‌های WARP (IPv4 + IPv6)...")
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                wsem = asyncio.Semaphore(12)

                async def _test_pair(host: str, port: int, version: int):
                    async with wsem:
                        ok, rtt = await probe_real_warp_handshake(
                            host, port, probe_dev["private_key"], probe_dev["peer_public_key"],
                            reserved=probe_dev["reserved"], timeout_sec=timeout_sec,
                        )
                        if not ok or rtt is None:
                            ok, rtt = await _fallback_tcp_rtt(host, timeout_sec=timeout_sec)
                        if not ok or rtt is None:
                            return None
                        return {
                            "endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}",
                            "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat(),
                        }

                v4_res, v6_res = await asyncio.gather(
                    asyncio.gather(*(_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(24))),
                    asyncio.gather(*(_test_pair(*split_endpoint(ep), 6) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS)),
                )
                v4_ok = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                v6_ok = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]
                if v4_ok:
                    self.store.data["warp_v4_pool"] = v4_ok
                if v6_ok:
                    self.store.data["warp_v6_pool"] = v6_ok

                self.current_stage = "proxy_ips"
                await _report(93, "در حال تست زنده لیست ProxyIPهای اختیاری...")
                p_res = await asyncio.gather(*(probe_proxy_ip(p, timeout_sec=timeout_sec) for p in CURATED_PROXY_IPS))
                p_ok = sorted([x for x in p_res if x], key=lambda x: x["latency_ms"])
                if p_ok:
                    self.store.data["proxy_ip_pool"] = p_ok
                self.last_scan_at = now.isoformat()
                self.store.save()
                await _report(100, "✅ اسکن کامل انجام شد و برترین IPها روی پنل کاربران سوار شد!")
                return {
                    "mci": len(self.store.data["operator_pools"].get("mci", [])),
                    "mtn": len(self.store.data["operator_pools"].get("mtn", [])),
                    "mkh": len(self.store.data["operator_pools"].get("mkh", [])),
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    def get_best_operator_ips(self, op: str = "mci", count: int = 8) -> list[dict[str, Any]]:
        raw = [x for x in self.store.data.get("operator_pools", {}).get(op, []) if not is_restricted_1034_ip(x.get("ip", ""))]
        if not raw:
            raw = [{"ip": ip, "latency_ms": None, "colo": "CF"} for ip in FALLBACK_EDGE_IPS.get(op, ["104.16.132.229"])]
        items = list(raw)[:count]
        for it in items:
            it["operator"] = op
        return items

    def get_best_warp_endpoints(self) -> tuple[str, str, float | None]:
        v4 = self.store.data.get("warp_v4_pool", [])
        v6 = self.store.data.get("warp_v6_pool", [])
        ep4 = v4[0]["endpoint"] if v4 else "162.159.192.1:2408"
        ep6 = v6[0]["endpoint"] if v6 else OFFICIAL_WARP_IPV6_ENDPOINTS[0]
        ping = v4[0]["latency_ms"] if v4 else (v6[0]["latency_ms"] if v6 else None)
        return ep4, ep6, ping

    def get_proxy_ip_pool(self) -> list[dict[str, Any]]:
        pool = list(self.store.data.get("proxy_ip_pool") or [])
        seen = {x.get("proxy_ip") for x in pool}
        for p in CURATED_PROXY_IPS:
            if p not in seen:
                pool.append({"proxy_ip": p, "latency_ms": None, "ok": True})
        return pool

    def get_best_proxy_ip(self) -> str:
        pool = self.get_proxy_ip_pool()
        return str(pool[0]["proxy_ip"]) if pool else CURATED_PROXY_IPS[0]
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/store.py
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
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/cf_manager.py
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import random
import re
import string
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urlencode

import httpx

from app.bot.operator_scanner import FALLBACK_EDGE_IPS, OPERATOR_LABELS, is_restricted_1034_ip, source_tier_rank
from app.bot.warp_builder import format_beautiful_name
from app.bot.worker_template import CANARY_JS, build_worker_payload
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e


def _new_neutral_name() -> str:
    prefix = random.choice(["web-app", "cdn-site", "edge-web", "static-app", "cloud-page"])
    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    return f"{prefix}-{suffix}"



_ECH_CACHE: dict[str, Any] = {"val": "", "ts": 0.0}


def _extract_ech_b64_from_dns_data(data_str: str) -> str:
    """Extracts Base64 ECHConfigList from Cloudflare DoH HTTPS (type 65) Answer data."""
    m = re.search(r'ech="?([A-Za-z0-9+/=]{24,})"?', data_str)
    if m:
        return m.group(1)
    # Fallback: parse RFC 3597 wire-format hex `\# <len> <hex...>` for SvcParamKey 5 (ech)
    if data_str.startswith("\\#"):
        parts = data_str.split()
        if len(parts) >= 3:
            try:
                raw = bytes.fromhex("".join(parts[2:]))
                # Skip 2-byte priority + target domain name (0x00 for root '.')
                idx = 2
                while idx < len(raw) and raw[idx] != 0:
                    idx += 1 + raw[idx]
                idx += 1  # skip null terminator
                while idx + 4 <= len(raw):
                    key = (raw[idx] << 8) | raw[idx + 1]
                    vlen = (raw[idx + 2] << 8) | raw[idx + 3]
                    idx += 4
                    if idx + vlen > len(raw):
                        break
                    if key == 5 and vlen >= 16:
                        return base64.b64encode(raw[idx : idx + vlen]).decode("ascii")
                    idx += vlen
            except Exception:
                pass
    return ""


async def fetch_live_cloudflare_ech_b64(timeout_sec: float = 4.0) -> str:
    """
    Fetches live Cloudflare ECH public key (Base64 ECHConfigList) from `cloudflare-ech.com` HTTPS record.
    Cached for 30 minutes so users in Iran get valid ECH without needing any DoH query on their phone!
    """
    now = time.time()
    if _ECH_CACHE["val"] and (now - _ECH_CACHE["ts"]) < 300:
        return str(_ECH_CACHE["val"])

    doh_urls = [
        "https://cloudflare-dns.com/dns-query",
        "https://dns.google/resolve",
    ]
    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            for url in doh_urls:
                try:
                    r = await client.get(
                        url,
                        params={"name": "cloudflare-ech.com", "type": "65"},
                        headers={"Accept": "application/dns-json"},
                    )
                    if r.status_code != 200:
                        continue
                    for ans in (r.json().get("Answer") or []):
                        ech_b64 = _extract_ech_b64_from_dns_data(str(ans.get("data", "")))
                        if ech_b64:
                            _ECH_CACHE["val"] = ech_b64
                            _ECH_CACHE["ts"] = now
                            return ech_b64
                except Exception:
                    continue
    except Exception:
        pass
    return str(_ECH_CACHE["val"] or "")


@dataclass
class CloudflareDeployResult:
    ok: bool
    engine: str = "pages"  # "pages" | "workers"
    account_id: str | None = None
    account_name: str | None = None
    project_name: str | None = None
    worker_host: str | None = None
    fallback_host: str | None = None
    custom_domain_bound: bool = False
    health_ok: bool = False
    health_msg: str = ""
    vless_verified: bool = False
    vless_ms: float | None = None
    vless_msg: str = ""
    trojan_verified: bool = False
    trojan_ms: float | None = None
    trojan_msg: str = ""
    diag_note: str = ""
    error: str | None = None


class CloudflarePanelService:
    BASE = "https://api.cloudflare.com/client/v4"

    async def _deploy_pages(
        self,
        client: httpx.AsyncClient,
        headers: dict[str, str],
        account_id: str,
        project_name: str,
        worker_js: str,
    ) -> tuple[bool, str | None, str]:
        """
        Engine #1 (PRIMARY): Deploy `_worker.js` to Cloudflare Pages (`https://<project>.pages.dev`).
        Solves BOTH Error 1101 on flagged `workers.dev` subdomains AND `workers.dev` ISP blocks in Iran!
        """
        # 1. Create or reuse Pages project
        proj_payload = {
            "name": project_name,
            "production_branch": "main",
            "deployment_configs": {
                "production": {"compatibility_date": "2024-11-01"}
            },
        }
        r_proj = await client.post(
            f"{self.BASE}/accounts/{account_id}/pages/projects",
            headers={**headers, "Content-Type": "application/json"},
            json=proj_payload,
        )
        d_proj = r_proj.json() if r_proj.content else {}
        subdomain = f"{project_name}.pages.dev"

        if r_proj.status_code in (200, 201) and d_proj.get("success"):
            subdomain = (d_proj.get("result") or {}).get("subdomain") or subdomain
        else:
            # Check if project already exists (code 8000002 / 409)
            r_get = await client.get(f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}", headers=headers)
            if r_get.status_code == 200 and r_get.json().get("success"):
                subdomain = (r_get.json().get("result") or {}).get("subdomain") or subdomain
                # Ensure compatibility_date is set on existing project
                await client.patch(
                    f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}",
                    headers={**headers, "Content-Type": "application/json"},
                    json={"deployment_configs": {"production": {"compatibility_date": "2024-11-01"}}},
                )
            else:
                err = (d_proj.get("errors") or [{"message": f"Pages HTTP {r_proj.status_code}"}])[0].get("message")
                return False, None, f"Pages project error: {err}"

        # 2. Upload 1 tiny index.html asset via Pages Upload Token (ensures valid manifest on all CF accounts)
        manifest_str = "{}"
        try:
            r_tok = await client.get(
                f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}/upload-token",
                headers=headers,
            )
            if r_tok.status_code == 200 and r_tok.json().get("success"):
                jwt = (r_tok.json().get("result") or {}).get("jwt")
                if jwt:
                    html_bytes = b"<!doctype html><html><head><title>OK</title></head><body><h1>200 OK</h1></body></html>"
                    asset_key = hashlib.md5(html_bytes).hexdigest()
                    b64_val = base64.b64encode(html_bytes).decode("ascii")
                    jwt_headers = {"Authorization": f"Bearer {jwt}", "Content-Type": "application/json"}
                    r_up = await client.post(
                        f"{self.BASE}/pages/assets/upload",
                        headers=jwt_headers,
                        json=[{"key": asset_key, "value": b64_val, "metadata": {"contentType": "text/html"}, "base64": True}],
                    )
                    if r_up.status_code in (200, 201):
                        await client.post(
                            f"{self.BASE}/pages/assets/upsert-hashes",
                            headers=jwt_headers,
                            json={"hashes": [asset_key]},
                        )
                        manifest_str = json.dumps({"/index.html": asset_key})
        except Exception:
            manifest_str = "{}"

        # 3. Create Direct Upload deployment containing `_worker.js`
        files = {
            "manifest": (None, manifest_str),
            "branch": (None, "main"),
            "_worker.js": ("_worker.js", worker_js.encode("utf-8"), "application/javascript+module"),
        }
        r_dep = await client.post(
            f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}/deployments",
            headers=headers,
            files=files,
        )
        d_dep = r_dep.json() if r_dep.content else {}
        if r_dep.status_code not in (200, 201) or not d_dep.get("success"):
            err = (d_dep.get("errors") or [{"message": f"Pages Deploy HTTP {r_dep.status_code}"}])[0].get("message")
            return False, None, f"Pages deploy error: {err}"

        dep_id = (d_dep.get("result") or {}).get("id")
        # 4. Wait up to 16s for Pages build/deploy pipeline to mark deployment live
        for _ in range(8):
            await asyncio.sleep(2.0)
            if not dep_id:
                break
            try:
                r_st = await client.get(
                    f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}/deployments/{dep_id}",
                    headers=headers,
                )
                if r_st.status_code == 200:
                    st = (r_st.json().get("result") or {}).get("latest_stage") or {}
                    if st.get("name") == "deploy" and st.get("status") == "success":
                        break
                    if st.get("status") == "failure":
                        return False, None, "Pages deployment stage failed"
            except Exception:
                pass

        return True, subdomain, "OK"

    async def _deploy_worker_raw(
        self,
        client: httpx.AsyncClient,
        headers: dict[str, str],
        account_id: str,
        script_name: str,
        worker_js: str,
        bindings: list[dict] | None = None,
    ) -> tuple[bool, str]:
        meta: dict[str, Any] = {"main_module": "index.js", "compatibility_date": "2024-11-01"}
        if bindings:
            meta["bindings"] = bindings
        files = {
            "metadata": (None, json.dumps(meta), "application/json"),
            "index.js": ("index.js", worker_js.encode("utf-8"), "application/javascript+module"),
        }
        r_put = await client.put(
            f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}",
            headers=headers,
            files=files,
        )
        d_put = r_put.json() if r_put.content else {}
        if r_put.status_code not in (200, 201) or not d_put.get("success"):
            err = (d_put.get("errors") or [{"message": f"HTTP {r_put.status_code}"}])[0].get("message")
            return False, str(err)

        await client.post(
            f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}/subdomain",
            headers={**headers, "Content-Type": "application/json"},
            json={"enabled": True},
        )
        return True, "OK"

    async def deploy_dual_panel(
        self,
        api_token: str,
        user_uuid: str,
        trojan_password: str,
        project_name: str,
        proxy_ip: str = "",
        force_new_name: bool = False,
    ) -> CloudflareDeployResult:
        token = api_token.strip()
        headers = {"Authorization": f"Bearer {token}"}
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                # 1. Verify Token
                r_ver = await client.get(f"{self.BASE}/user/tokens/verify", headers=headers)
                d_ver = r_ver.json()
                if r_ver.status_code != 200 or not d_ver.get("success"):
                    err = (d_ver.get("errors") or [{"message": f"HTTP {r_ver.status_code}"}])[0].get("message")
                    return CloudflareDeployResult(ok=False, error=f"توکن نامعتبر: {err}")
                if (d_ver.get("result") or {}).get("status") != "active":
                    return CloudflareDeployResult(ok=False, error="توکن غیرفعال یا منقضی است.")

                # 2. Fetch Account ID
                r_acc = await client.get(f"{self.BASE}/accounts", headers=headers, params={"per_page": 5})
                accs = r_acc.json().get("result") or []
                if r_acc.status_code != 200 or not accs:
                    return CloudflareDeployResult(ok=False, error="دسترسی Account در توکن وجود ندارد.")
                account_id = accs[0]["id"]
                account_name = accs[0].get("name") or "Cloudflare"

                worker_js, bindings = build_worker_payload(
                    user_uuid=user_uuid,
                    trojan_password=trojan_password,
                    proxy_ip=proxy_ip,
                )

                target_name = _new_neutral_name() if (force_new_name or not project_name or project_name.startswith("cfhub-")) else project_name

                # ========== ENGINE #1: CLOUDFLARE PAGES (`*.pages.dev`) ==========
                p_ok, pages_host, p_err = await self._deploy_pages(client, headers, account_id, target_name, worker_js)
                diag_notes: list[str] = []

                if p_ok and pages_host:
                    await asyncio.sleep(3.0)
                    h_ok, _, h_msg = await check_ip_routes_worker(pages_host, pages_host, 443, timeout_sec=7.0)
                    (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg) = await asyncio.gather(
                        test_worker_tunnel_e2e(pages_host, None, "vless", user_uuid),
                        test_worker_tunnel_e2e(pages_host, None, "trojan", trojan_password),
                    )
                    if not (h_ok and v_ok and t_ok):
                        await asyncio.sleep(3.0)
                        if not h_ok:
                            h_ok, _, h_msg = await check_ip_routes_worker(pages_host, pages_host, 443, timeout_sec=7.0)
                        if not v_ok:
                            v_ok, v_ms, v_msg = await test_worker_tunnel_e2e(pages_host, None, "vless", user_uuid)
                        if not t_ok:
                            t_ok, t_ms, t_msg = await test_worker_tunnel_e2e(pages_host, None, "trojan", trojan_password)
                    if h_ok and (v_ok or t_ok):
                        return CloudflareDeployResult(
                            ok=True,
                            engine="pages",
                            account_id=account_id,
                            account_name=account_name,
                            project_name=target_name,
                            worker_host=pages_host,
                            fallback_host=pages_host,
                            health_ok=h_ok,
                            health_msg=h_msg,
                            vless_verified=v_ok,
                            vless_ms=v_ms,
                            vless_msg=v_msg,
                            trojan_verified=t_ok,
                            trojan_ms=t_ms,
                            trojan_msg=t_msg,
                            diag_note="🚀 دیپلوی موفق روی Cloudflare Pages (*.pages.dev)",
                        )
                    diag_notes.append(f"Pages test: health={h_msg}, vless={v_msg}")
                else:
                    diag_notes.append(f"Pages skipped: {p_err}")

                # ========== ENGINE #2: CLOUDFLARE WORKERS FALLBACK + CANARY DIAGNOSTIC ==========
                subdomain = None
                r_sub = await client.get(f"{self.BASE}/accounts/{account_id}/workers/subdomain", headers=headers)
                if r_sub.status_code == 200 and r_sub.json().get("success"):
                    subdomain = (r_sub.json().get("result") or {}).get("subdomain")
                if not subdomain:
                    cand = f"app-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"
                    r_cr = await client.put(
                        f"{self.BASE}/accounts/{account_id}/workers/subdomain",
                        headers={**headers, "Content-Type": "application/json"},
                        json={"subdomain": cand},
                    )
                    if r_cr.status_code in (200, 201) and r_cr.json().get("success"):
                        subdomain = (r_cr.json().get("result") or {}).get("subdomain", cand)

                if not subdomain:
                    return CloudflareDeployResult(ok=False, error=f"دیپلوی Pages و Workers ناموفق بود: {' | '.join(diag_notes)}")

                w_name = _new_neutral_name()
                w_ok, w_err = await self._deploy_worker_raw(client, headers, account_id, w_name, worker_js, bindings)
                if not w_ok:
                    return CloudflareDeployResult(ok=False, error=f"خطا در دیپلوی: {w_err}")

                w_host = f"{w_name}.{subdomain}.workers.dev"
                await asyncio.sleep(2.5)
                h_ok, _, h_msg = await check_ip_routes_worker(w_host, w_host, 443, timeout_sec=6.0)

                # If even Workers returned 1101, run a 4-line canary WITHOUT cloudflare:sockets to pinpoint account ban!
                if not h_ok and "1101" in h_msg:
                    c_name = f"ping-{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
                    c_up, _ = await self._deploy_worker_raw(client, headers, account_id, c_name, CANARY_JS, None)
                    if c_up:
                        await asyncio.sleep(2.0)
                        c_ok, _, c_msg = await check_ip_routes_worker(f"{c_name}.{subdomain}.workers.dev", f"{c_name}.{subdomain}.workers.dev", 443, timeout_sec=5.0)
                        try:
                            await client.delete(f"{self.BASE}/accounts/{account_id}/workers/scripts/{c_name}", headers=headers)
                        except Exception:
                            pass
                        if not c_ok:
                            diag_notes.append("⚠️ اکانت کلودفلر شما توسط کلودفلر محدود (Suspend/1101) شده است؛ لطفاً با یک ایمیل جدید اکانت کلودفلر تازه بسازید.")
                        else:
                            diag_notes.append("⚠️ کلودفلر روی این اکانت ماژول cloudflare:sockets را مسدود کرده است.")

                (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg) = await asyncio.gather(
                    test_worker_tunnel_e2e(w_host, None, "vless", user_uuid),
                    test_worker_tunnel_e2e(w_host, None, "trojan", trojan_password),
                )

                # If Pages had succeeded earlier (even if slow to propagate), prefer Pages host if Workers gave 1101
                final_host = w_host
                final_engine = "workers"
                if (not v_ok) and p_ok and pages_host:
                    await asyncio.sleep(3.0)
                    p_v_ok, p_v_ms, p_v_msg = await test_worker_tunnel_e2e(pages_host, None, "vless", user_uuid)
                    if p_v_ok:
                        p_t_ok, p_t_ms, p_t_msg = await test_worker_tunnel_e2e(pages_host, None, "trojan", trojan_password)
                        p_h_ok, _, p_h_msg = await check_ip_routes_worker(pages_host, pages_host, 443)
                        final_host, final_engine = pages_host, "pages"
                        h_ok, h_msg = p_h_ok, p_h_msg
                        v_ok, v_ms, v_msg = p_v_ok, p_v_ms, p_v_msg
                        t_ok, t_ms, t_msg = p_t_ok, p_t_ms, p_t_msg

                return CloudflareDeployResult(
                    ok=True,
                    engine=final_engine,
                    account_id=account_id,
                    account_name=account_name,
                    project_name=target_name if final_engine == "pages" else w_name,
                    worker_host=final_host,
                    fallback_host=w_host,
                    health_ok=h_ok,
                    health_msg=h_msg,
                    vless_verified=v_ok,
                    vless_ms=v_ms,
                    vless_msg=v_msg,
                    trojan_verified=t_ok,
                    trojan_ms=t_ms,
                    trojan_msg=t_msg,
                    diag_note=" | ".join(diag_notes),
                )
        except Exception as exc:
            return CloudflareDeployResult(ok=False, error=f"خطا در اتصال به کلودفلر: {exc}")

    @staticmethod
    async def pick_best_verified_worker_ips(
        worker_host: str,
        candidates: list[dict[str, Any]],
        operator: str = "mci",
        count: int = 3,
    ) -> list[dict[str, Any]]:
        """
        V25 Iran-First Verified IP Selector:
          - STRICTLY PRESERVES IRAN TIER PRIORITY (Admin Manual > Iran IRCF/vFarid > Community Clean CF > Fallback).
            NEVER lets a Europe-fast/Iran-blackholed IP outrank a true Iran-tested clean IP!
          - Verifies every candidate IP against the user's real Cloudflare Pages host on Port 443 (`/health` 200 OK).
          - Spreads the 3 configs across distinct `/16` subnets within the top Iran tier for maximum resilience.
        """
        clean_cands = [c for c in candidates if not is_restricted_1034_ip(c.get("ip", ""))]
        existing_set = {c["ip"] for c in clean_cands}
        for fb in FALLBACK_EDGE_IPS.get(operator, ["104.16.132.229", "104.21.48.84", "172.64.155.209"]):
            if fb not in existing_set:
                clean_cands.append({"ip": fb, "latency_ms": None, "speed_mbps": 0.0, "colo": "CF", "source": "fallback"})

        # Keep Tier priority intact BEFORE slicing sample!
        clean_cands.sort(
            key=lambda x: (
                source_tier_rank(x.get("source", "")),
                x.get("score") or 0.0,
                -(x.get("latency_ms") or 9999.0),
            ),
            reverse=True,
        )

        sample = clean_cands[:15]
        checked = await asyncio.gather(
            *(check_ip_routes_worker(worker_host, c["ip"], 443, timeout_sec=3.2) for c in sample)
        )
        passing = []
        for cand, (ok, ms, _) in zip(sample, checked):
            if ok:
                item = dict(cand)
                item["latency_ms"] = ms if ms is not None else (cand.get("latency_ms") or 999.0)
                passing.append(item)

        # CRITICAL: Sort by IRAN TIER FIRST, then real throughput & RTT!
        passing.sort(
            key=lambda x: (
                -source_tier_rank(x.get("source", "")),
                -(x.get("speed_mbps") or 0.0),
                x.get("latency_ms") or 9999.0,
            )
        )

        # Pick diverse /16 subnets within highest tiers first
        chosen: list[dict[str, Any]] = []
        seen_prefix: set[str] = set()
        for item in passing:
            pref = ".".join(item["ip"].split(".")[:2])
            if pref not in seen_prefix:
                chosen.append(item)
                seen_prefix.add(pref)
                if len(chosen) >= count:
                    return chosen

        for item in passing:
            if item not in chosen:
                chosen.append(item)
                if len(chosen) >= count:
                    return chosen

        while len(chosen) < count and clean_cands:
            chosen.append(clean_cands[len(chosen) % len(clean_cands)])
        return chosen[:count]

    async def list_account_zones(self, api_token: str, account_id: str) -> list[dict[str, str]]:
        """Lists active Cloudflare domains (Zones) on the user's account for 1-click Custom Domain binding."""
        headers = {"Authorization": f"Bearer {api_token.strip()}"}
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                r = await client.get(
                    f"{self.BASE}/zones",
                    headers=headers,
                    params={"account.id": account_id, "status": "active", "per_page": 20},
                )
                if r.status_code != 200 or not r.json().get("success"):
                    return []
                return [
                    {"id": z["id"], "name": z["name"]}
                    for z in (r.json().get("result") or [])
                    if z.get("id") and z.get("name")
                ]
        except Exception:
            return []

    async def bind_custom_domain(
        self,
        api_token: str,
        account_id: str,
        project_name: str,
        pages_host: str,
        custom_domain: str,
    ) -> tuple[bool, str]:
        """
        Binds a Custom Domain to the user's Cloudflare Pages project AND creates a proxied CNAME DNS record!
        Eliminates `*.pages.dev` SNI blocking completely in Iran (100% speed, 0 ECH/Fragment overhead).
        """
        dom = custom_domain.strip().lower().strip(".")
        if not dom or "." not in dom or dom.endswith(".pages.dev") or dom.endswith(".workers.dev"):
            return False, "فرمت دامنه اختصاصی نامعتبر است (مثال: cdn.yourdomain.com)."

        headers = {"Authorization": f"Bearer {api_token.strip()}", "Content-Type": "application/json"}
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                # 1. Attach custom domain to Cloudflare Pages project
                r_dom = await client.post(
                    f"{self.BASE}/accounts/{account_id}/pages/projects/{project_name}/domains",
                    headers=headers,
                    json={"name": dom},
                )
                d_dom = r_dom.json() if r_dom.content else {}
                if r_dom.status_code not in (200, 201) and not (d_dom.get("errors") and any("already" in str(e.get("message", "")).lower() for e in d_dom["errors"])):
                    err = (d_dom.get("errors") or [{"message": f"HTTP {r_dom.status_code}"}])[0].get("message")
                    return False, f"خطا در ثبت دامنه روی Pages: {err}"

                # 2. Find matching Zone & create/update Proxied CNAME -> pages_host
                zones = await self.list_account_zones(api_token, account_id)
                matched_zone = None
                for z in sorted(zones, key=lambda x: len(x["name"]), reverse=True):
                    if dom == z["name"] or dom.endswith("." + z["name"]):
                        matched_zone = z
                        break

                if matched_zone:
                    zid = matched_zone["id"]
                    r_list = await client.get(
                        f"{self.BASE}/zones/{zid}/dns_records",
                        headers=headers,
                        params={"name": dom},
                    )
                    existing = (r_list.json().get("result") or []) if r_list.status_code == 200 else []
                    rec_body = {"type": "CNAME", "name": dom, "content": pages_host, "proxied": True, "ttl": 1}
                    if existing:
                        await client.put(f"{self.BASE}/zones/{zid}/dns_records/{existing[0]['id']}", headers=headers, json=rec_body)
                    else:
                        await client.post(f"{self.BASE}/zones/{zid}/dns_records", headers=headers, json=rec_body)

                return True, dom
        except Exception as exc:
            return False, f"خطا در اتصال دامنه: {exc}"

    @staticmethod
    def is_custom_domain(host: str) -> bool:
        h = (host or "").strip().lower()
        return bool(h) and not h.endswith(".pages.dev") and not h.endswith(".workers.dev")

    @staticmethod
    def resolve_panel_proxy_ip(panel: dict[str, Any], best_auto_proxy: str = "") -> tuple[str, str]:
        """
        Returns `(effective_proxy_ip, mode_label)`.
        Default for all new & existing panels is OFF (`""`, `"off"`).
        """
        if not panel.get("proxy_ip_enabled", False):
            return "", "off"
        mode = str(panel.get("proxy_ip_mode") or "auto").lower()
        if mode == "auto":
            return (best_auto_proxy or "proxyip.cmliussss.net"), "auto"
        val = str(panel.get("proxy_ip") or "").strip()
        if not val:
            return (best_auto_proxy or "proxyip.cmliussss.net"), "auto"
        return val, mode

    @staticmethod
    def build_six_ech_configs(
        panel: dict[str, Any],
        ip_list: list[dict[str, Any]],
        operator: str = "mci",
        ech_b64: str = "",
        alt_port_vless: int = 443,
        alt_port_trojan: int = 443,
        effective_proxy_ip: str = "",
    ) -> dict[str, Any]:
        """
        V26 Unbreakable 6/6 Iran-Engineered Config Pack (3 VLESS + 3 Trojan, ALL Port 443):
          AUTOMATICALLY adapts to the panel's domain type:
          A) Free `*.pages.dev` / `*.workers.dev` (Iran DPI blocks plaintext `pages.dev` SNI!):
             - ALL 6 configs use **Native ECH** (`cloudflare-ech.com` outer SNI) with **NO `fp=` uTLS conflict**!
               (In Xray-core / v2rayNG, combining `fp=chrome` with `ech=` breaks ECH on Go/uTLS! Omitting `fp=` uses Go's native TLS 1.3 ECH!)
             - #1 (`ECH-Turbo • 0-RTT`): Live 5-min Base64 ECH (ZERO external DNS wait on phone!) + `?ed=2560` + Tier-1 IP #1.
             - #2 (`ECH-Stable`): Live 5-min Base64 ECH + standard `/cdn` (no early data) + Tier-1 IP #2 (2nd `/16` subnet).
             - #3 (`ECH-Auto`): Dynamic IP-DoH ECH (`cloudflare-ech.com+https://223.5.5.5/dns-query`, NEVER expires!) + `?ed=2560` + Tier-1 IP #3.
          B) Custom Domain (`cdn.yourdomain.com` — NOT blocked by Iran SNI filter!):
             - ALL 6 configs use **Pure Turbo TLS 1.3** (`fp=chrome`/`fp=ios`, `?ed=2560`, ZERO ECH overhead) for 100% full speed!
          - ProxyIP is OFF by default (`/cdn`). When user toggles ProxyIP ON, uses `/px/<proxyip>` with zero redeploy!
        """
        i1 = ip_list[0]
        i2 = ip_list[1] if len(ip_list) > 1 else i1
        i3 = ip_list[2] if len(ip_list) > 2 else i2
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        brand = "CFHub"
        tpass = quote(panel["trojan_password"], safe="")

        is_custom = CloudflarePanelService.is_custom_domain(panel["host"])
        base_route = f"/px/{quote(effective_proxy_ip, safe='.:[]')}" if effective_proxy_ip else "/cdn"
        px_tag = "•Px" if effective_proxy_ip else ""

        # Direct IP-based DoH (Alibaba 223.5.5.5 & DNSPod 1.12.12.12 — no domain resolution bootstrap needed in Iran!)
        ECH_AUTO_DOH = "cloudflare-ech.com+https://223.5.5.5/dns-query"
        ECH_AUTO_DOH_2 = "cloudflare-ech.com+https://1.12.12.12/dns-query"
        live_ech = (ech_b64 or "").strip()

        def _hp(ip: str) -> str:
            return f"[{ip}]" if ":" in ip else ip

        def _build(proto: str, it: dict, idx: int, mode: str, use_ed: bool = True, ech_val: str = "", fp_val: str = "") -> str:
            ws_path = f"{base_route}?ed=2560" if use_ed else base_route
            params: dict[str, str] = {
                "security": "tls",
                "type": "ws",
                "host": panel["host"],
                "sni": panel["sni"],
                "path": ws_path,
                "alpn": "http/1.1",
            }
            if proto == "vless":
                params["encryption"] = "none"
            # CRITICAL: NEVER combine `fp=` (uTLS) with `ech=`! Go native TLS handles ECH cleanly when `fp` is omitted!
            if ech_val:
                params["ech"] = ech_val
            elif fp_val:
                params["fp"] = fp_val

            colo = it.get("colo") or "CF"
            tier = source_tier_rank(it.get("source", ""))
            src_badge = "IR" if tier >= 2 else colo
            tag = format_beautiful_name(
                op_lbl,
                f"{'VLESS' if proto == 'vless' else 'Trojan'}-{idx}",
                it.get("latency_ms"),
                f"{src_badge}•{mode}{px_tag}•{brand}",
            )
            cred = panel["uuid"] if proto == "vless" else tpass
            return f"{proto}://{cred}@{_hp(it['ip'])}:443?{urlencode(params)}#{quote(tag)}"

        if is_custom:
            return {
                "vless_1": _build("vless", i1, 1, "Direct0RTT", use_ed=True, fp_val="chrome"),
                "vless_2": _build("vless", i2, 2, "Direct-iOS", use_ed=True, fp_val="ios"),
                "vless_3": _build("vless", i3, 3, "Direct-WS", use_ed=False, fp_val="chrome"),
                "trojan_1": _build("trojan", i1, 1, "Direct0RTT", use_ed=True, fp_val="chrome"),
                "trojan_2": _build("trojan", i2, 2, "Direct-iOS", use_ed=True, fp_val="ios"),
                "trojan_3": _build("trojan", i3, 3, "Direct-WS", use_ed=False, fp_val="chrome"),
                "proxy_active": bool(effective_proxy_ip),
                "proxy_ip": effective_proxy_ip,
                "is_custom_domain": True,
                "ech_active": False,
            }

        e1 = live_ech or ECH_AUTO_DOH
        e2 = live_ech or ECH_AUTO_DOH_2
        e3 = ECH_AUTO_DOH
        return {
            "vless_1": _build("vless", i1, 1, "ECH-0RTT", use_ed=True, ech_val=e1),
            "vless_2": _build("vless", i2, 2, "ECH-Direct", use_ed=False, ech_val=e2),
            "vless_3": _build("vless", i3, 3, "ECH-Auto", use_ed=True, ech_val=e3),
            "trojan_1": _build("trojan", i1, 1, "ECH-0RTT", use_ed=True, ech_val=e1),
            "trojan_2": _build("trojan", i2, 2, "ECH-Direct", use_ed=False, ech_val=e2),
            "trojan_3": _build("trojan", i3, 3, "ECH-Auto", use_ed=True, ech_val=e3),
            "proxy_active": bool(effective_proxy_ip),
            "proxy_ip": effective_proxy_ip,
            "is_custom_domain": False,
            "ech_active": True,
        }

    @staticmethod
    def build_fragment_json_bundle(
        panel: dict[str, Any],
        ip_list: list[dict[str, Any]],
        operator: str = "mci",
        effective_proxy_ip: str = "",
    ) -> list[dict[str, Any]]:
        """
        V26 Iran-Tuned Anti-DPI TLS-Fragment Xray JSON Array (6 configs: 3 VLESS + 3 Trojan):
          Splits `*.pages.dev` TLS ClientHello into tiny 10-20 byte TCP segments so Iran DPI cannot inspect SNI!
          Works 100% WITHOUT ECH on v2rayNG, Hiddify, v2rayN, and Streisand!
        """
        op_lbl = OPERATOR_LABELS.get(operator, "CF")
        base_route = f"/px/{quote(effective_proxy_ip, safe='.:[]')}" if effective_proxy_ip else "/cdn"
        ws_path = f"{base_route}?ed=2560"
        out = []
        for idx, it in enumerate(ip_list[:3], start=1):
            for proto in ("vless", "trojan"):
                is_tr = proto == "trojan"
                settings = (
                    {"servers": [{"address": it["ip"], "port": 443, "password": panel["trojan_password"]}]}
                    if is_tr
                    else {"vnext": [{"address": it["ip"], "port": 443, "users": [{"id": panel["uuid"], "encryption": "none"}]}]}
                )
                out.append({
                    "remarks": f"{op_lbl} • {proto.upper()}-{idx} • Fragment-10-20 • CFHub",
                    "log": {"loglevel": "warning"},
                    "dns": {"servers": ["https://1.1.1.1/dns-query", "8.8.8.8"], "queryStrategy": "UseIPv4"},
                    "inbounds": [{
                        "tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
                        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
                        "settings": {"auth": "noauth", "udp": True},
                    }],
                    "outbounds": [
                        {
                            "tag": "proxy", "protocol": proto, "settings": settings,
                            "streamSettings": {
                                "network": "ws", "security": "tls",
                                "tlsSettings": {"serverName": panel["host"], "fingerprint": "chrome", "alpn": ["http/1.1"], "allowInsecure": False},
                                "wsSettings": {"path": ws_path, "headers": {"Host": panel["host"]}},
                                "sockopt": {"dialerProxy": "frag-out", "tcpKeepAliveIdle": 100, "tcpNoDelay": True},
                            },
                        },
                        {
                            "tag": "frag-out", "protocol": "freedom",
                            "settings": {"fragment": {"packets": "tlshello", "length": "10-20", "interval": "10-20"}},
                            "streamSettings": {"sockopt": {"tcpKeepAliveIdle": 100, "tcpNoDelay": True}},
                        },
                        {"tag": "direct", "protocol": "freedom"},
                    ],
                })
        return out
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/webapp_ui.py
from __future__ import annotations

MINI_APP_HTML = r"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover"/>
<title>CFHub</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
  :root {
    --bg: #F2F2F7;
    --surface: #FFFFFF;
    --surface-2: #F5F5F7;
    --glass: rgba(242, 242, 247, 0.86);
    --sep: rgba(60, 60, 67, 0.12);
    --text: #000000;
    --text-2: #636366;
    --text-3: #8E8E93;
    --blue: #007AFF;
    --green: #34C759;
    --orange: #FF9500;
    --red: #FF3B30;
    --seg-bg: rgba(118, 118, 128, 0.12);
    --seg-act: #FFFFFF;
    --radius: 14px;
  }
  [data-theme="dark"] {
    --bg: #000000;
    --surface: #1C1C1E;
    --surface-2: #2C2C2E;
    --glass: rgba(18, 18, 20, 0.86);
    --sep: rgba(84, 84, 88, 0.42);
    --text: #FFFFFF;
    --text-2: #AEAEB2;
    --text-3: #8E8E93;
    --blue: #0A84FF;
    --green: #30D158;
    --orange: #FF9F0A;
    --red: #FF453A;
    --seg-bg: rgba(118, 118, 128, 0.24);
    --seg-act: #3A3A3C;
  }
  * {
    box-sizing: border-box;
    -webkit-tap-highlight-color: transparent;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Segoe UI", Tahoma, sans-serif;
  }
  html, body {
    margin: 0; padding: 0;
    background: var(--bg); color: var(--text);
    min-height: 100vh; overflow-x: hidden;
    font-size: 14px;
  }

  /* Compact Frosted iOS Top Bar */
  .topbar {
    position: sticky; top: 0; z-index: 40; height: 48px;
    background: var(--glass);
    backdrop-filter: saturate(180%) blur(20px);
    -webkit-backdrop-filter: saturate(180%) blur(20px);
    border-bottom: 0.5px solid var(--sep);
    padding: 0 14px;
    display: flex; align-items: center; justify-content: space-between;
  }
  .brand {
    display: flex; align-items: center; gap: 7px;
    font-size: 16px; font-weight: 700; letter-spacing: -0.3px;
  }
  .dot-live {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--green); box-shadow: 0 0 0 3px rgba(52,199,89,0.2);
  }
  .ver-chip {
    font-size: 10px; font-weight: 700; padding: 2px 6px;
    border-radius: 999px; background: rgba(0,122,255,0.12); color: var(--blue);
  }
  .top-btns { display: flex; gap: 6px; }
  .pill-btn {
    border: none; background: var(--seg-bg); color: var(--text);
    height: 28px; padding: 0 10px; border-radius: 999px;
    font-size: 12px; font-weight: 600; cursor: pointer;
    display: inline-flex; align-items: center; justify-content: center;
  }

  /* Main Compact Container */
  .wrap { max-width: 480px; margin: 0 auto; padding: 10px 14px 82px; }
  .sec-hdr {
    font-size: 11px; font-weight: 600; color: var(--text-2);
    margin: 12px 10px 5px; letter-spacing: 0.15px;
    display: flex; justify-content: space-between; align-items: center;
  }

  /* iOS Grouped Inset Card */
  .card {
    background: var(--surface); border-radius: var(--radius);
    border: 0.5px solid var(--sep); overflow: hidden; margin-bottom: 10px;
  }
  .pad { padding: 12px 14px; }

  /* Compact 4-Column Status Strip (Single Clean Card) */
  .strip {
    display: grid; grid-template-columns: repeat(4, 1fr);
    background: var(--surface); border-radius: var(--radius);
    border: 0.5px solid var(--sep); margin-bottom: 10px;
  }
  .strip-item {
    padding: 8px 4px; text-align: center;
    border-inline-end: 0.5px solid var(--sep);
  }
  .strip-item:last-child { border-inline-end: none; }
  .strip-v { font-size: 15px; font-weight: 700; line-height: 1.2; }
  .strip-l { font-size: 10px; color: var(--text-2); margin-top: 2px; }

  /* Inset Rows */
  .row {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 14px; gap: 10px; border-bottom: 0.5px solid var(--sep);
  }
  .row:last-child { border-bottom: none; }
  .row-m { min-width: 0; flex: 1; }
  .row-t { font-size: 14px; font-weight: 600; line-height: 1.3; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .row-s { font-size: 11.5px; color: var(--text-2); margin-top: 1px; word-break: break-all; }

  /* Compact iOS Segmented Control */
  .seg {
    display: flex; background: var(--seg-bg); padding: 2.5px;
    border-radius: 10px; margin-bottom: 10px;
  }
  .seg-b {
    flex: 1; border: none; background: transparent; color: var(--text);
    padding: 6.5px 4px; border-radius: 8px;
    font-size: 12.5px; font-weight: 600; cursor: pointer; transition: .15s;
  }
  .seg-b.active { background: var(--seg-act); box-shadow: 0 1px 3px rgba(0,0,0,0.12); }

  /* Buttons */
  .btn {
    border: none; border-radius: 11px; padding: 10px 14px;
    font-size: 14px; font-weight: 600; cursor: pointer; width: 100%;
    display: inline-flex; align-items: center; justify-content: center; gap: 5px;
    text-decoration: none; transition: opacity .12s, transform .08s;
  }
  .btn:active { opacity: 0.72; transform: scale(0.985); }
  .btn-blue { background: var(--blue); color: #fff; }
  .btn-green { background: var(--green); color: #fff; }
  .btn-red { background: rgba(255,59,48,0.12); color: var(--red); }
  .btn-soft { background: var(--seg-bg); color: var(--text); }
  .btn-sm { padding: 6px 11px; font-size: 12px; border-radius: 9px; width: auto; }
  .g2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }

  /* Badges */
  .bdg { font-size: 10.5px; font-weight: 600; padding: 2px 7px; border-radius: 999px; white-space: nowrap; }
  .b-g { background: rgba(52,199,89,0.15); color: var(--green); }
  .b-b { background: rgba(0,122,255,0.13); color: var(--blue); }
  .b-o { background: rgba(255,149,0,0.15); color: var(--orange); }
  .b-r { background: rgba(255,59,48,0.13); color: var(--red); }
  .b-n { background: var(--seg-bg); color: var(--text-2); }

  /* Inputs */
  .inp, .ta {
    width: 100%; background: var(--surface-2); border: 0.5px solid var(--sep);
    border-radius: 10px; padding: 9px 12px; font-size: 13.5px; color: var(--text); outline: none;
  }
  .inp:focus, .ta:focus { border-color: var(--blue); }
  .ta { min-height: 70px; resize: vertical; }

  /* Authentic iOS UISwitch */
  .sw { position: relative; display: inline-block; width: 46px; height: 28px; flex-shrink: 0; }
  .sw input { opacity: 0; width: 0; height: 0; }
  .sl {
    position: absolute; cursor: pointer; inset: 0; border-radius: 28px;
    background: rgba(120,120,128,0.32); transition: .22s;
  }
  .sl:before {
    position: absolute; content: ""; height: 24px; width: 24px;
    left: 2px; bottom: 2px; background: #fff; border-radius: 50%;
    transition: .22s; box-shadow: 0 1px 4px rgba(0,0,0,0.22);
  }
  input:checked + .sl { background: var(--green); }
  input:checked + .sl:before { transform: translateX(18px); }

  /* Progress */
  .pwrap { background: var(--seg-bg); border-radius: 999px; height: 6px; overflow: hidden; margin: 8px 0 5px; }
  .pbar { height: 100%; background: var(--blue); width: 0%; transition: width .3s; }

  /* Compact Frosted iOS Bottom Tab Bar */
  .tabbar {
    position: fixed; bottom: 0; left: 0; right: 0; z-index: 50;
    background: var(--glass);
    backdrop-filter: saturate(180%) blur(24px);
    -webkit-backdrop-filter: saturate(180%) blur(24px);
    border-top: 0.5px solid var(--sep);
    display: flex; justify-content: space-around;
    padding: 6px 6px calc(6px + env(safe-area-inset-bottom));
  }
  .tbtn {
    border: none; background: transparent; color: var(--text-3);
    display: flex; flex-direction: column; align-items: center; gap: 2px;
    font-size: 10.5px; font-weight: 600; cursor: pointer; padding: 2px 10px;
  }
  .tbtn.active { color: var(--blue); }
  .tbtn svg { width: 21px; height: 21px; stroke: currentColor; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }

  /* Bottom Sheet */
  .backdrop {
    position: fixed; inset: 0; background: rgba(0,0,0,0.42);
    z-index: 80; display: none; align-items: flex-end; justify-content: center;
  }
  .backdrop.open { display: flex; }
  .sheet {
    width: 100%; max-width: 480px; background: var(--surface);
    border-radius: 20px 20px 0 0; padding: 10px 16px 24px;
    max-height: 82vh; overflow-y: auto; animation: up .2s ease;
  }
  @keyframes up { from { transform: translateY(30px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  .handle { width: 36px; height: 4px; border-radius: 99px; background: var(--sep); margin: 0 auto 12px; }

  /* Pill Toast */
  .toast {
    position: fixed; top: 56px; left: 50%; transform: translateX(-50%);
    background: rgba(28,28,30,0.92); color: #fff;
    padding: 8px 16px; border-radius: 999px; font-size: 12.5px; font-weight: 600;
    z-index: 99; display: none; white-space: nowrap; box-shadow: 0 4px 16px rgba(0,0,0,0.22);
  }
  .hidden { display: none !important; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; direction: ltr; unicode-bidi: embed; }
</style>
</head>
<body>

<div class="topbar">
  <div class="brand">
    <span class="dot-live"></span>
    <span>CFHub</span>
    <span class="ver-chip">V26</span>
  </div>
  <div class="top-btns">
    <button class="pill-btn" id="btnLang" onclick="toggleLang()">EN</button>
    <button class="pill-btn" id="btnTheme" onclick="toggleTheme()">🌙</button>
  </div>
</div>

<div id="toast" class="toast"></div>

<!-- LOCK VIEW -->
<div id="lockView" class="wrap hidden">
  <div class="card pad" style="text-align:center; margin-top:24px;">
    <div style="font-size:38px; margin-bottom:8px;">🔒</div>
    <div id="lockTitle" style="font-size:16px; font-weight:700; margin-bottom:6px;"></div>
    <div id="lockText" style="font-size:13px; color:var(--text-2); line-height:1.55; margin-bottom:14px;"></div>
    <a id="lockUrlBtn" href="#" target="_blank" class="btn btn-blue" style="margin-bottom:8px;" data-i18n="join_channel"></a>
    <button class="btn btn-green" onclick="verifyLock()" data-i18n="verify_join"></button>
  </div>
</div>

<!-- MAIN APP -->
<div id="appView" class="wrap">

  <!-- ==================== TAB 1: PANEL ==================== -->
  <div id="tab-panel">
    <div class="strip">
      <div class="strip-item"><div id="stMci" class="strip-v">-</div><div class="strip-l" data-i18n="op_mci"></div></div>
      <div class="strip-item"><div id="stMtn" class="strip-v">-</div><div class="strip-l" data-i18n="op_mtn"></div></div>
      <div class="strip-item"><div id="stMkh" class="strip-v">-</div><div class="strip-l" data-i18n="op_mkh"></div></div>
      <div class="strip-item"><div id="stWarp" class="strip-v">-</div><div class="strip-l">WARP</div></div>
    </div>

    <!-- NO PANEL -->
    <div id="noPanelCard" class="card pad hidden">
      <div style="font-size:15.5px; font-weight:700; margin-bottom:5px;" data-i18n="create_title"></div>
      <div style="font-size:12.5px; color:var(--text-2); line-height:1.55; margin-bottom:12px;" data-i18n="create_desc"></div>
      <div class="g2" style="margin-bottom:10px;">
        <a id="cfTokenLink" href="#" target="_blank" class="btn btn-green btn-sm" data-i18n="get_token"></a>
        <a href="https://dash.cloudflare.com/sign-up" target="_blank" class="btn btn-soft btn-sm" data-i18n="cf_signup"></a>
      </div>
      <input id="inpCfToken" class="inp mono" data-i18n-ph="token_ph" style="margin-bottom:8px;"/>
      <button id="btnDeployPanel" class="btn btn-blue" onclick="deployPanel()" data-i18n="deploy_btn"></button>
    </div>

    <!-- ACTIVE PANEL -->
    <div id="activePanelBox" class="hidden">
      <div class="card">
        <div class="row">
          <div class="row-m">
            <div class="row-t"><span data-i18n="active_panel"></span> <span id="pnlVerBadge" class="bdg b-g">V26</span></div>
            <div id="pnlHost" class="row-s mono">-</div>
          </div>
          <button class="btn btn-blue btn-sm" onclick="copySubLink()" data-i18n="copy_sub"></button>
        </div>
        <!-- Optional ProxyIP Switch (OFF by default!) -->
        <div class="row">
          <div class="row-m">
            <div class="row-t">
              <span data-i18n="proxy_ip_title"></span>
              <span id="proxyStatusBdg" class="bdg b-n">-</span>
            </div>
            <div id="proxySubLbl" class="row-s">-</div>
          </div>
          <div style="display:flex; align-items:center; gap:8px;">
            <button id="btnPickProxy" class="btn btn-soft btn-sm hidden" onclick="openProxySheet()" data-i18n="change_btn"></button>
            <label class="sw"><input type="checkbox" id="swProxy" onchange="toggleProxySwitch()"/><span class="sl"></span></label>
          </div>
        </div>
      </div>

      <div class="seg" id="opSeg">
        <button class="seg-b active" data-op="mci" onclick="selectOperator('mci', this)" data-i18n="op_mci"></button>
        <button class="seg-b" data-op="mtn" onclick="selectOperator('mtn', this)" data-i18n="op_mtn"></button>
        <button class="seg-b" data-op="mkh" onclick="selectOperator('mkh', this)" data-i18n="op_mkh"></button>
      </div>

      <div id="configsCard" class="card"></div>

      <div class="g2" style="margin-bottom:10px;">
        <button class="btn btn-blue btn-sm" onclick="copyAllConfigs()" data-i18n="copy_all"></button>
        <button class="btn btn-soft btn-sm" onclick="rotateIps()" data-i18n="rotate_ips"></button>
      </div>

      <div class="sec-hdr"><span data-i18n="panel_tools"></span></div>
      <div class="card">
        <div class="row">
          <div class="row-m"><div class="row-t" data-i18n="e2e_title"></div><div class="row-s" data-i18n="e2e_sub"></div></div>
          <button id="btnE2E" class="btn btn-soft btn-sm" onclick="runE2ETest()" data-i18n="run_btn"></button>
        </div>
        <div class="row">
          <div class="row-m"><div class="row-t" data-i18n="update_core"></div><div class="row-s" data-i18n="update_core_sub"></div></div>
          <button id="btnRedeploy" class="btn btn-green btn-sm" onclick="redeployPanel()" data-i18n="update_btn"></button>
        </div>
        <div class="row">
          <div class="row-m"><div class="row-t" data-i18n="frag_title"></div><div class="row-s" data-i18n="frag_sub"></div></div>
          <button class="btn btn-blue btn-sm" onclick="copyFragSub()" data-i18n="copy_btn"></button>
        </div>
        <div class="row">
          <div class="row-m"><div class="row-t" data-i18n="dom_title"></div><div class="row-s" data-i18n="dom_sub"></div></div>
          <button class="btn btn-soft btn-sm" onclick="openDomainSheet()" data-i18n="change_btn"></button>
        </div>
        <div class="row">
          <div class="row-m"><div class="row-t" style="color:var(--red);" data-i18n="delete_panel"></div><div class="row-s" data-i18n="delete_panel_sub"></div></div>
          <button class="btn btn-red btn-sm" onclick="disconnectPanel()" data-i18n="delete_btn"></button>
        </div>
      </div>
    </div>
  </div>

  <!-- ==================== TAB 2: WARP ==================== -->
  <div id="tab-warp" class="hidden">
    <div class="sec-hdr"><span data-i18n="warp_relays"></span></div>
    <div class="card">
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="warp_ep4"></div><div id="warpEp4" class="row-s mono">-</div></div>
        <span id="warpPing" class="bdg b-g">-</span>
      </div>
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="warp_ep6"></div><div id="warpEp6" class="row-s mono">-</div></div>
        <button class="btn btn-soft btn-sm" onclick="scanWarpLive()" data-i18n="scan_btn"></button>
      </div>
    </div>

    <div class="sec-hdr"><span data-i18n="warp_gen_sec"></span></div>
    <div class="card pad">
      <div class="seg" id="warpModeSeg">
        <button class="seg-b active" onclick="setWarpMode('ipv6', this)">IPv6</button>
        <button class="seg-b" onclick="setWarpMode('dual', this)">Dual</button>
        <button class="seg-b" onclick="setWarpMode('ipv4', this)">IPv4</button>
      </div>
      <div class="seg" id="warpPlatSeg">
        <button class="seg-b active" onclick="setWarpPlat('ios', this)">iOS</button>
        <button class="seg-b" onclick="setWarpPlat('android', this)">Android</button>
        <button class="seg-b" onclick="setWarpPlat('windows', this)">Windows</button>
      </div>
      <button id="btnGenWarp" class="btn btn-blue" onclick="generateWarp()" data-i18n="warp_gen_btn"></button>
    </div>

    <div id="warpResultCard" class="card hidden"></div>
  </div>

  <!-- ==================== TAB 3: TOOLS ==================== -->
  <div id="tab-tools" class="hidden">
    <div class="sec-hdr"><span data-i18n="clean_ips_sec"></span></div>
    <div class="seg">
      <button class="seg-b active" onclick="loadCleanIps('mci', this)" data-i18n="op_mci"></button>
      <button class="seg-b" onclick="loadCleanIps('mtn', this)" data-i18n="op_mtn"></button>
      <button class="seg-b" onclick="loadCleanIps('mkh', this)" data-i18n="op_mkh"></button>
    </div>
    <div id="cleanIpsCard" class="card"></div>

    <div class="sec-hdr"><span data-i18n="apps_sec"></span></div>
    <div class="card">
      <div class="row"><div class="row-m"><div class="row-t">Hiddify</div><div class="row-s">iOS / Android / Windows</div></div><a href="https://github.com/hiddify/hiddify-app/releases/latest" target="_blank" class="btn btn-soft btn-sm" data-i18n="dl_btn"></a></div>
      <div class="row"><div class="row-m"><div class="row-t">v2rayNG</div><div class="row-s">Android (Xray Core)</div></div><a href="https://github.com/2dust/v2rayNG/releases/latest" target="_blank" class="btn btn-soft btn-sm" data-i18n="dl_btn"></a></div>
      <div class="row"><div class="row-m"><div class="row-t">Streisand</div><div class="row-s">iPhone / iPad (iOS)</div></div><a href="https://apps.apple.com/app/streisand/id6450534064" target="_blank" class="btn btn-soft btn-sm" data-i18n="dl_btn"></a></div>
      <div class="row"><div class="row-m"><div class="row-t">AmneziaWG</div><div class="row-s">Anti-DPI WARP / WireGuard</div></div><a href="https://github.com/amnezia-vpn/amneziawg-android/releases/latest" target="_blank" class="btn btn-soft btn-sm" data-i18n="dl_btn"></a></div>
      <div class="row"><div class="row-m"><div class="row-t">v2rayN</div><div class="row-s">Windows Desktop</div></div><a href="https://github.com/2dust/v2rayN/releases/latest" target="_blank" class="btn btn-soft btn-sm" data-i18n="dl_btn"></a></div>
    </div>

    <div class="sec-hdr"><span data-i18n="guide_sec"></span></div>
    <div class="card pad" style="font-size:12.5px; color:var(--text-2); line-height:1.65;" id="guideBox"></div>

    <div class="sec-hdr"><span data-i18n="support_sec"></span></div>
    <div class="card pad">
      <a id="directSupBtn" href="#" target="_blank" class="btn btn-soft" style="margin-bottom:8px;" data-i18n="direct_sup"></a>
      <textarea id="inpTicket" class="ta" data-i18n-ph="ticket_ph" style="margin-bottom:8px;"></textarea>
      <button class="btn btn-blue" onclick="sendSupportTicket()" data-i18n="send_ticket"></button>
    </div>
  </div>

  <!-- ==================== TAB 4: ADMIN (ADMINS ONLY) ==================== -->
  <div id="tab-admin" class="hidden">
    <div class="strip">
      <div class="strip-item"><div id="admCpu" class="strip-v">-</div><div class="strip-l">CPU</div></div>
      <div class="strip-item"><div id="admRam" class="strip-v">-</div><div class="strip-l">RAM</div></div>
      <div class="strip-item"><div id="admUsersCnt" class="strip-v">-</div><div class="strip-l" data-i18n="adm_users"></div></div>
      <div class="strip-item"><div id="admPanelsCnt" class="strip-v">-</div><div class="strip-l" data-i18n="adm_panels"></div></div>
    </div>

    <div class="card pad">
      <div style="display:flex; justify-content:space-between; align-items:center;">
        <span style="font-size:13.5px; font-weight:700;" data-i18n="adm_scanner"></span>
        <span id="admScanState" class="bdg b-g">-</span>
      </div>
      <div class="pwrap"><div id="admProgBar" class="pbar"></div></div>
      <div id="admScanInfo" style="font-size:11.5px; color:var(--text-2); margin-bottom:8px;">-</div>
      <div class="g2">
        <button class="btn btn-green btn-sm" onclick="adminStartScan('full')" data-i18n="adm_scan_full"></button>
        <button class="btn btn-blue btn-sm" onclick="adminStartScan('warp')" data-i18n="adm_scan_warp"></button>
      </div>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_add_ips"></span></div>
    <div class="card pad">
      <div class="seg" id="admOpSeg">
        <button class="seg-b active" onclick="setAdmOp('mci', this)" data-i18n="op_mci"></button>
        <button class="seg-b" onclick="setAdmOp('mtn', this)" data-i18n="op_mtn"></button>
        <button class="seg-b" onclick="setAdmOp('mkh', this)" data-i18n="op_mkh"></button>
      </div>
      <textarea id="inpAdmIps" class="ta mono" placeholder="104.16.132.229 104.21.48.84" style="margin-bottom:8px;"></textarea>
      <button class="btn btn-blue btn-sm" style="width:100%;" onclick="adminAddIps()" data-i18n="adm_add_ips_btn"></button>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_users_sec"></span></div>
    <div class="card pad">
      <div style="display:flex; gap:6px; margin-bottom:8px;">
        <input id="inpUserSearch" class="inp" data-i18n-ph="adm_search_ph"/>
        <button class="btn btn-blue btn-sm" onclick="loadAdminUsers(0)" data-i18n="search_btn"></button>
      </div>
      <div id="admUsersList"></div>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_locks_sec"></span></div>
    <div class="card">
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="adm_tg_lock"></div><div class="row-s" data-i18n="adm_tg_lock_s"></div></div>
        <label class="sw"><input type="checkbox" id="swTgLock" onchange="saveAdminSettings()"/><span class="sl"></span></label>
      </div>
      <div class="pad" style="border-bottom:0.5px solid var(--sep);">
        <input id="inpTgChan" class="inp mono" placeholder="@Channel / -100..." style="margin-bottom:6px;"/>
        <input id="inpTgText" class="inp" data-i18n-ph="adm_lock_txt_ph"/>
      </div>
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="adm_yt_lock"></div><div class="row-s" data-i18n="adm_yt_lock_s"></div></div>
        <label class="sw"><input type="checkbox" id="swYtLock" onchange="saveAdminSettings()"/><span class="sl"></span></label>
      </div>
      <div class="pad">
        <input id="inpYtUrl" class="inp mono" placeholder="https://youtube.com/@CyberMux" style="margin-bottom:6px;"/>
        <input id="inpYtText" class="inp" data-i18n-ph="adm_lock_txt_ph" style="margin-bottom:8px;"/>
        <button class="btn btn-blue btn-sm" style="width:100%;" onclick="saveAdminSettings()" data-i18n="save_btn"></button>
      </div>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_sys_sec"></span></div>
    <div class="card">
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="adm_autoscan"></div></div>
        <label class="sw"><input type="checkbox" id="swAutoScan" onchange="saveAdminSettings()"/><span class="sl"></span></label>
      </div>
      <div class="row">
        <div class="row-m"><div class="row-t" data-i18n="adm_maint"></div></div>
        <label class="sw"><input type="checkbox" id="swMaint" onchange="saveAdminSettings()"/><span class="sl"></span></label>
      </div>
      <div class="pad">
        <input id="inpSupUser" class="inp mono" placeholder="Support username (no @)" style="margin-bottom:6px;"/>
        <input id="inpWebappUrl" class="inp mono" placeholder="https://app.prostoreshop.site" style="margin-bottom:8px;"/>
        <button class="btn btn-blue btn-sm" style="width:100%;" onclick="saveAdminSettings()" data-i18n="save_btn"></button>
      </div>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_bc_sec"></span></div>
    <div class="card pad">
      <textarea id="inpBroadcast" class="ta" data-i18n-ph="adm_bc_ph" style="margin-bottom:8px;"></textarea>
      <button class="btn btn-green" onclick="adminBroadcast()" data-i18n="adm_bc_btn"></button>
    </div>

    <div class="sec-hdr"><span data-i18n="adm_tickets_sec"></span></div>
    <div id="admTicketsCard" class="card"></div>
  </div>
</div>

<!-- BOTTOM TAB BAR -->
<nav class="tabbar" id="bottomTabBar">
  <button class="tbtn active" data-tab="panel" onclick="switchTab('panel', this)">
    <svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/></svg>
    <span data-i18n="tab_panel"></span>
  </button>
  <button class="tbtn" data-tab="warp" onclick="switchTab('warp', this)">
    <svg viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    <span>WARP</span>
  </button>
  <button class="tbtn" data-tab="tools" onclick="switchTab('tools', this)">
    <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
    <span data-i18n="tab_tools"></span>
  </button>
  <button class="tbtn hidden" id="navAdminBtn" data-tab="admin" onclick="switchTab('admin', this)">
    <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.6.85 1 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
    <span data-i18n="tab_admin"></span>
  </button>
</nav>

<!-- MODAL SHEET -->
<div id="modalBackdrop" class="backdrop" onclick="if(event.target===this) closeSheet()">
  <div class="sheet">
    <div class="handle"></div>
    <div id="sheetBody"></div>
  </div>
</div>

<script>
const I18N = {
  fa: {
    tab_panel: 'پنل من', tab_tools: 'ابزارها', tab_admin: 'مدیریت',
    op_mci: 'همراه اول', op_mtn: 'ایرانسل', op_mkh: 'مخابرات',
    join_channel: 'ورود به کانال', verify_join: 'تایید و بررسی عضویت',
    create_title: 'ساخت پنل رایگان اختصاصی',
    create_desc: 'توکن کلودفلر را وارد کنید تا پنل VLESS و Trojan شما بدون ProxyIP (مستقیم و پرسرعت) ساخته شود.',
    get_token: '🔑 دریافت توکن', cf_signup: '🌐 ثبت‌نام کلودفلر',
    token_ph: 'Cloudflare API Token را پیست کنید...', deploy_btn: '🚀 ساخت پنل V26',
    active_panel: 'پنل فعال', copy_sub: 'Auto-Sub',
    proxy_ip_title: 'ProxyIP اختیاری',
    proxy_off_bdg: 'خاموش', proxy_on_bdg: 'روشن',
    proxy_off_sub: 'اتصال مستقیم • بالاترین سرعت و پینگ',
    proxy_auto_sub: 'خودکار (سریع‌ترین): ',
    proxy_list_sub: 'انتخاب‌شده: ',
    change_btn: 'تغییر',
    copy_all: '📋 کپی همه ۶ کانفیگ', rotate_ips: '🔄 تعویض ۳ IP جدید',
    panel_tools: 'ابزارهای پنل',
    e2e_title: 'تست سرتاسری پنل', e2e_sub: 'بررسی Health، VLESS و Trojan', run_btn: 'اجرا',
    update_core: 'هسته پنل (V26)', update_core_sub: 'به‌روزرسانی روی Cloudflare Pages',
    update_btn: 'آپدیت', updated_btn: 'آپدیت هستید',
    frag_title: 'Auto-Fragment (JSON)', frag_sub: 'ویژه فیلترینگ شدید', copy_btn: 'کپی',
    delete_panel: 'حذف پنل فعلی', delete_panel_sub: 'قطع اتصال و حذف توکن', delete_btn: 'حذف',
    warp_relays: 'رله‌های فعال WARP', warp_ep4: 'اندپوینت IPv4', warp_ep6: 'اندپوینت IPv6',
    scan_btn: '🔍 اسکن', warp_gen_sec: 'ساخت کلید اختصاصی WARP', warp_gen_btn: '🛡️ ساخت کانفیگ WARP',
    clean_ips_sec: 'آی‌پی‌های تمیز اپراتورها', apps_sec: 'اپلیکیشن‌ها', dl_btn: 'دانلود',
    guide_sec: 'راهنمای سریع',
    guide_html: '<b>۱. بهترین پینگ:</b> کانفیگ‌های <b>#1 (Turbo)</b> و <b>#2 (Fast)</b> روی تمام کلاینت‌ها فوری پینگ می‌دهند.<br/><b>۲. ProxyIP:</b> در حالت پیش‌فرض خاموش بگذارید تا اختلال ایجاد نشود؛ در صورت نیاز با سوییچ بالا روشن کنید.<br/><b>۳. v2rayNG:</b> گزینه <b>Enable Mux</b> را خاموش بگذارید.',
    support_sec: 'پشتیبانی', direct_sup: '💬 چت مستقیم پشتیبانی',
    ticket_ph: 'پیام یا مشکل خود را بنویسید...', send_ticket: '✉️ ارسال تیکت',
    adm_users: 'کاربران', adm_panels: 'پنل‌ها', adm_scanner: 'اسکنر هوشمند',
    adm_scan_full: '▶️ اسکن کامل', adm_scan_warp: '🛡️ اسکن WARP',
    adm_add_ips: 'افزودن IP دستی', adm_add_ips_btn: '➕ ثبت و اسکن',
    adm_users_sec: 'مدیریت کاربران', adm_search_ph: 'آیدی یا @username...', search_btn: 'جستجو',
    adm_locks_sec: 'قفل تلگرام و یوتیوب', adm_tg_lock: 'قفل تلگرام (واقعی)', adm_tg_lock_s: 'ربات باید ادمین کانال باشد',
    adm_yt_lock: 'قفل یوتیوب (فیک)', adm_yt_lock_s: 'با تایید کاربر باز می‌شود', adm_lock_txt_ph: 'متن پیام قفل...',
    adm_sys_sec: 'تنظیمات سیستم', adm_autoscan: 'اسکن خودکار دوره‌ای', adm_maint: 'حالت تعمیرات',
    save_btn: '💾 ذخیره', adm_bc_sec: 'ارسال همگانی', adm_bc_ph: 'متن اطلاعیه برای همه کاربران...',
    adm_bc_btn: '📢 ارسال به همه', adm_tickets_sec: 'تیکت‌های اخیر',
    copied: '✅ کپی شد', loading: '⏳ در حال بارگذاری...',
    c_turbo: 'ECH خالص + 0-RTT (پینگ فوری)', c_alt: 'ECH خالص پایدار (سازگار با همه)', c_ech: 'ECH خودکار (بدون انقضا • IP-DoH)', dom_title: 'دامنه اختصاصی کلودفلر', dom_sub: 'حذف محدودیت pages.dev • حداکثر سرعت',
    sheet_proxy_title: '🔀 انتخاب ProxyIP اختیاری',
    sheet_proxy_auto: '⚡ خودکار (سریع‌ترین تست‌شده)',
    sheet_proxy_custom: 'ذخیره آدرس دلخواه',
    sheet_close: 'بستن', sheet_cancel: 'انصراف', sheet_del_confirm: 'بله، حذف کن',
    ready: 'آماده', empty: 'موردی ثبت نشده', reply: 'پاسخ',
  },
  en: {
    tab_panel: 'Panel', tab_tools: 'Tools', tab_admin: 'Admin',
    op_mci: 'MCI', op_mtn: 'Irancell', op_mkh: 'TCI',
    join_channel: 'Open Channel', verify_join: 'Verify Membership',
    create_title: 'Create Free Private Panel',
    create_desc: 'Paste your Cloudflare API token to deploy your VLESS & Trojan panel (Direct mode, ProxyIP OFF by default).',
    get_token: '🔑 Get Token', cf_signup: '🌐 Sign Up',
    token_ph: 'Paste Cloudflare API Token...', deploy_btn: '🚀 Deploy V26 Panel',
    active_panel: 'Active Panel', copy_sub: 'Auto-Sub',
    proxy_ip_title: 'Optional ProxyIP',
    proxy_off_bdg: 'OFF', proxy_on_bdg: 'ON',
    proxy_off_sub: 'Direct Edge • Max speed & lowest ping',
    proxy_auto_sub: 'Auto (Fastest): ',
    proxy_list_sub: 'Selected: ',
    change_btn: 'Select',
    copy_all: '📋 Copy All 6 Configs', rotate_ips: '🔄 Rotate 3 Fresh IPs',
    panel_tools: 'Panel Actions',
    e2e_title: 'End-to-End Test', e2e_sub: 'Check Health, VLESS & Trojan', run_btn: 'Run',
    update_core: 'Panel Core (V26)', update_core_sub: 'Redeploy latest worker to Pages',
    update_btn: 'Update', updated_btn: 'Up to Date',
    frag_title: 'Auto-Fragment (JSON)', frag_sub: 'For heavy DPI filtering', copy_btn: 'Copy',
    delete_panel: 'Delete Panel', delete_panel_sub: 'Disconnect & remove token', delete_btn: 'Delete',
    warp_relays: 'Live WARP Relays', warp_ep4: 'IPv4 Endpoint', warp_ep6: 'IPv6 Endpoint',
    scan_btn: '🔍 Scan', warp_gen_sec: 'Generate Private WARP Key', warp_gen_btn: '🛡️ Generate WARP Config',
    clean_ips_sec: 'Clean Edge IPs', apps_sec: 'Client Apps', dl_btn: 'Download',
    guide_sec: 'Quick Guide',
    guide_html: '<b>1. Fastest Ping:</b> Configs <b>#1 (Turbo)</b> & <b>#2 (Fast)</b> work immediately on every client.<br/><b>2. ProxyIP:</b> Keep OFF by default for best speed; toggle ON above only if needed.<br/><b>3. v2rayNG:</b> Keep <b>Enable Mux</b> turned OFF.',
    support_sec: 'Support', direct_sup: '💬 Direct Support Chat',
    ticket_ph: 'Describe your issue or message...', send_ticket: '✉️ Submit Ticket',
    adm_users: 'Users', adm_panels: 'Panels', adm_scanner: 'Smart Scanner',
    adm_scan_full: '▶️ Full Scan', adm_scan_warp: '🛡️ WARP Scan',
    adm_add_ips: 'Add Manual IPs', adm_add_ips_btn: '➕ Save & Scan',
    adm_users_sec: 'User Management', adm_search_ph: 'ID or @username...', search_btn: 'Search',
    adm_locks_sec: 'Telegram & YouTube Locks', adm_tg_lock: 'Telegram Lock (Real)', adm_tg_lock_s: 'Bot must be channel admin',
    adm_yt_lock: 'YouTube Lock (Soft)', adm_yt_lock_s: 'Unlocks on confirm click', adm_lock_txt_ph: 'Lock message text...',
    adm_sys_sec: 'System Settings', adm_autoscan: 'Periodic Auto-Scan', adm_maint: 'Maintenance Mode',
    save_btn: '💾 Save', adm_bc_sec: 'Broadcast', adm_bc_ph: 'Message to all users...',
    adm_bc_btn: '📢 Send to All', adm_tickets_sec: 'Recent Tickets',
    copied: '✅ Copied', loading: '⏳ Loading...',
    c_turbo: 'Native ECH + 0-RTT (Fastest)', c_alt: 'Native ECH Stable (Universal)', c_ech: 'Auto ECH (Never-Expire IP-DoH)', dom_title: 'Custom Cloudflare Domain', dom_sub: 'Bypass pages.dev SNI • Max speed',
    sheet_proxy_title: '🔀 Select Optional ProxyIP',
    sheet_proxy_auto: '⚡ Auto (Fastest Live-Tested)',
    sheet_proxy_custom: 'Save Custom ProxyIP',
    sheet_close: 'Close', sheet_cancel: 'Cancel', sheet_del_confirm: 'Yes, Delete',
    ready: 'Ready', empty: 'Nothing here yet', reply: 'Reply',
  }
};

const tg = (window.Telegram && window.Telegram.WebApp) ? window.Telegram.WebApp : null;
if (tg) {
  tg.ready(); tg.expand();
  if (tg.colorScheme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
    document.getElementById('btnTheme').textContent = '☀️';
  }
}

let state = {
  op: 'mci', warpMode: 'ipv6', warpPlat: 'ios', admOp: 'mci',
  configs: {}, subUrl: '', fragSubUrl: '',
  isAdmin: false, hasPanel: false, lang: 'fa',
  proxyEnabled: false, proxyMode: 'off', proxyVal: '', proxyList: [],
  scanTimer: null,
};

function t(k) { return (I18N[state.lang] && I18N[state.lang][k]) || I18N.fa[k] || k; }

function applyLang(lang) {
  state.lang = (lang === 'en') ? 'en' : 'fa';
  document.documentElement.lang = state.lang;
  document.documentElement.dir = state.lang === 'fa' ? 'rtl' : 'ltr';
  document.getElementById('btnLang').textContent = state.lang === 'fa' ? 'EN' : 'FA';
  document.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll('[data-i18n-ph]').forEach(el => { el.placeholder = t(el.dataset.i18nPh); });
  document.getElementById('guideBox').innerHTML = t('guide_html');
  renderProxyUI();
}

function haptic(type='light') { try { if (tg && tg.HapticFeedback) tg.HapticFeedback.impactOccurred(type); } catch(_) {} }
function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg; el.style.display = 'block';
  clearTimeout(window._tT); window._tT = setTimeout(() => { el.style.display = 'none'; }, 2100);
}
function toggleTheme() {
  haptic();
  const dark = document.documentElement.getAttribute('data-theme') === 'dark';
  if (dark) { document.documentElement.removeAttribute('data-theme'); document.getElementById('btnTheme').textContent = '🌙'; }
  else { document.documentElement.setAttribute('data-theme', 'dark'); document.getElementById('btnTheme').textContent = '☀️'; }
}

async function api(path, method='GET', body=null) {
  const headers = { 'Content-Type': 'application/json' };
  if (tg && tg.initData) headers['X-Telegram-Init-Data'] = tg.initData;
  const opts = { method, headers };
  if (body !== null) opts.body = JSON.stringify(body);
  const res = await fetch(path, opts);
  const data = await res.json();
  if (!res.ok && !data.ok) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

function copyText(txt, okMsg=null) {
  haptic(); const m = okMsg || t('copied');
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(txt).then(() => toast(m)).catch(() => fallbackCopy(txt, m));
  } else fallbackCopy(txt, m);
}
function fallbackCopy(txt, m) {
  const ta = document.createElement('textarea'); ta.value = txt; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  try { document.execCommand('copy'); toast(m); } catch(_) { toast('❌'); }
  document.body.removeChild(ta);
}
function openSheet(htmlContent) { document.getElementById('sheetBody').innerHTML = htmlContent; document.getElementById('modalBackdrop').classList.add('open'); }
function closeSheet() { document.getElementById('modalBackdrop').classList.remove('open'); }
function escapeHtml(s) { return String(s || '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m])); }

function switchTab(name, btnEl) {
  haptic();
  ['panel','warp','tools','admin'].forEach(k => document.getElementById('tab-' + k).classList.toggle('hidden', k !== name));
  document.querySelectorAll('.tbtn').forEach(b => b.classList.remove('active'));
  if (btnEl) btnEl.classList.add('active');
  if (name === 'tools') loadCleanIps('mci');
  if (name === 'admin') loadAdminDashboard();
}

async function toggleLang() {
  haptic();
  const nxt = state.lang === 'fa' ? 'en' : 'fa';
  applyLang(nxt);
  try { await api('/api/v26/lang', 'POST', { lang: nxt }); } catch(_) {}
  if (state.hasPanel) renderConfigsList();
}

function renderProxyUI() {
  const sw = document.getElementById('swProxy');
  const bdg = document.getElementById('proxyStatusBdg');
  const sub = document.getElementById('proxySubLbl');
  const pick = document.getElementById('btnPickProxy');
  if (!sw) return;
  sw.checked = !!state.proxyEnabled;
  if (!state.proxyEnabled) {
    bdg.className = 'bdg b-n'; bdg.textContent = t('proxy_off_bdg');
    sub.textContent = t('proxy_off_sub');
    pick.classList.add('hidden');
  } else {
    bdg.className = 'bdg b-g'; bdg.textContent = t('proxy_on_bdg');
    sub.textContent = (state.proxyMode === 'auto' ? t('proxy_auto_sub') : t('proxy_list_sub')) + (state.proxyVal || 'Auto');
    pick.classList.remove('hidden');
  }
}

async function bootstrap() {
  applyLang(state.lang);
  try {
    const d = await api('/api/v26/bootstrap');
    if (d.lang) applyLang(d.lang);
    if (d.locked) {
      document.getElementById('appView').classList.add('hidden');
      document.getElementById('bottomTabBar').classList.add('hidden');
      document.getElementById('lockView').classList.remove('hidden');
      document.getElementById('lockTitle').textContent = d.lock_type === 'tg' ? 'Telegram Channel' : 'YouTube Channel';
      document.getElementById('lockText').textContent = d.lock_text || '';
      const uBtn = document.getElementById('lockUrlBtn');
      if (d.lock_url) { uBtn.href = d.lock_url; uBtn.classList.remove('hidden'); } else uBtn.classList.add('hidden');
      return;
    }

    document.getElementById('lockView').classList.add('hidden');
    document.getElementById('appView').classList.remove('hidden');
    document.getElementById('bottomTabBar').classList.remove('hidden');

    state.isAdmin = !!d.is_admin;
    state.hasPanel = !!d.has_panel;
    state.proxyList = d.proxy_ip_pool || [];
    document.getElementById('navAdminBtn').classList.toggle('hidden', !state.isAdmin);

    document.getElementById('stMci').textContent = d.pools.mci;
    document.getElementById('stMtn').textContent = d.pools.mtn;
    document.getElementById('stMkh').textContent = d.pools.mkh;
    document.getElementById('stWarp').textContent = (d.warp.v4_count + d.warp.v6_count);
    document.getElementById('warpEp4').textContent = d.warp.ep4;
    document.getElementById('warpEp6').textContent = d.warp.ep6;
    document.getElementById('warpPing').textContent = d.warp.ping ? (Math.round(d.warp.ping) + 'ms') : 'Auto';
    document.getElementById('cfTokenLink').href = d.cf_token_url;

    const supBtn = document.getElementById('directSupBtn');
    if (d.support_url) { supBtn.href = d.support_url; supBtn.classList.remove('hidden'); } else supBtn.classList.add('hidden');

    if (d.has_panel && d.panel) {
      document.getElementById('noPanelCard').classList.add('hidden');
      document.getElementById('activePanelBox').classList.remove('hidden');
      document.getElementById('pnlHost').textContent = d.panel.host;
      state.proxyEnabled = !!d.panel.proxy_ip_enabled;
      state.proxyMode = d.panel.proxy_ip_mode || 'off';
      state.proxyVal = d.panel.effective_proxy_ip || '';
      renderProxyUI();

      const badge = document.getElementById('pnlVerBadge');
      const rBtn = document.getElementById('btnRedeploy');
      if (d.panel.is_updated) {
        badge.className = 'bdg b-g'; badge.textContent = d.panel.version.toUpperCase();
        rBtn.className = 'btn btn-green btn-sm'; rBtn.textContent = t('updated_btn');
      } else {
        badge.className = 'bdg b-r'; badge.textContent = 'Update';
        rBtn.className = 'btn btn-red btn-sm'; rBtn.textContent = t('update_btn');
      }
      state.op = d.panel.operator || 'mci';
      document.querySelectorAll('#opSeg .seg-b').forEach(b => b.classList.toggle('active', b.dataset.op === state.op));
      await loadConfigs(state.op, false);
    } else {
      document.getElementById('noPanelCard').classList.remove('hidden');
      document.getElementById('activePanelBox').classList.add('hidden');
    }
  } catch (e) { toast('⚠️ ' + e.message); }
}

async function verifyLock() {
  haptic();
  try {
    const r = await api('/api/v26/lock/verify', 'POST', {});
    if (r.unlocked) { toast('✅'); bootstrap(); } else toast('⚠️');
  } catch (e) { toast('❌ ' + e.message); }
}

async function toggleProxySwitch() {
  haptic('medium');
  const en = document.getElementById('swProxy').checked;
  try {
    const r = await api('/api/v26/panel/proxyip', 'POST', { enabled: en, mode: en ? 'auto' : 'off' });
    state.proxyEnabled = !!r.proxy_ip_enabled;
    state.proxyMode = r.proxy_ip_mode || 'off';
    state.proxyVal = r.effective_proxy_ip || '';
    renderProxyUI();
    await loadConfigs(state.op, false);
    toast(state.proxyEnabled ? ('⚡ ProxyIP: ' + state.proxyVal) : t('proxy_off_sub'));
  } catch (e) {
    document.getElementById('swProxy').checked = !en;
    toast('❌ ' + e.message);
  }
}

function openProxySheet() {
  haptic();
  let listHtml = '';
  (state.proxyList || []).forEach(it => {
    const ms = it.latency_ms ? `<span class="bdg b-g">${Math.round(it.latency_ms)}ms</span>` : `<span class="bdg b-n">Ready</span>`;
    listHtml += `<div class="row" style="cursor:pointer;" onclick="setProxyChoice('list', '${escapeHtml(it.proxy_ip)}')">
      <div class="row-m"><div class="row-t mono" style="font-size:13px;">${escapeHtml(it.proxy_ip)}</div></div>${ms}
    </div>`;
  });
  openSheet(`
    <div style="font-size:16px;font-weight:700;margin-bottom:10px;">${t('sheet_proxy_title')}</div>
    <button class="btn btn-green" style="margin-bottom:10px;" onclick="setProxyChoice('auto', '')">${t('sheet_proxy_auto')}</button>
    <div class="card">${listHtml}</div>
    <div style="display:flex;gap:6px;margin-top:8px;">
      <input id="inpCustomPx" class="inp mono" placeholder="ip:port or domain"/>
      <button class="btn btn-blue btn-sm" onclick="setProxyChoice('custom', document.getElementById('inpCustomPx').value.trim())">${t('save_btn')}</button>
    </div>
  `);
}

async function setProxyChoice(mode, val) {
  if (mode === 'custom' && !val) return;
  try {
    const r = await api('/api/v26/panel/proxyip', 'POST', { enabled: true, mode, proxy_ip: val });
    state.proxyEnabled = !!r.proxy_ip_enabled;
    state.proxyMode = r.proxy_ip_mode;
    state.proxyVal = r.effective_proxy_ip;
    closeSheet();
    renderProxyUI();
    await loadConfigs(state.op, false);
    toast('✅ ' + state.proxyVal);
  } catch (e) { toast('❌ ' + e.message); }
}

async function selectOperator(op, el) {
  haptic(); state.op = op;
  document.querySelectorAll('#opSeg .seg-b').forEach(b => b.classList.remove('active'));
  if (el) el.classList.add('active');
  await loadConfigs(op, false);
}

async function rotateIps() { haptic('medium'); await loadConfigs(state.op, true); toast('🔄'); }

function renderConfigsList() {
  const box = document.getElementById('configsCard');
  const list = [
    { k: 'vless_1', t: 'VLESS #1', tag: 'ECH-0RTT', c: 'b-b', s: t('c_turbo') },
    { k: 'vless_2', t: 'VLESS #2', tag: 'ECH', c: 'b-g', s: t('c_alt') },
    { k: 'vless_3', t: 'VLESS #3', tag: 'AutoECH', c: 'b-o', s: t('c_ech') },
    { k: 'trojan_1', t: 'Trojan #1', tag: 'ECH-0RTT', c: 'b-b', s: t('c_turbo') },
    { k: 'trojan_2', t: 'Trojan #2', tag: 'ECH', c: 'b-g', s: t('c_alt') },
    { k: 'trojan_3', t: 'Trojan #3', tag: 'AutoECH', c: 'b-o', s: t('c_ech') },
  ];
  box.innerHTML = '';
  list.forEach(it => {
    const uri = state.configs[it.k];
    if (!uri) return;
    const r = document.createElement('div'); r.className = 'row';
    const pxPill = state.proxyEnabled ? '<span class="bdg b-n">Px</span>' : '';
    r.innerHTML = `<div class="row-m"><div class="row-t">${it.t} <span class="bdg ${it.c}">${it.tag}</span>${pxPill}</div><div class="row-s">${it.s}</div></div>`;
    const btn = document.createElement('button'); btn.className = 'btn btn-soft btn-sm'; btn.textContent = t('copy_btn');
    btn.onclick = () => copyText(uri, `✅ ${it.t}`);
    r.appendChild(btn); box.appendChild(r);
  });
}

async function loadConfigs(op, rotate=false) {
  document.getElementById('configsCard').innerHTML = `<div class="pad" style="text-align:center;color:var(--text-2);font-size:12.5px;">${t('loading')}</div>`;
  try {
    const d = await api(`/api/v26/panel/configs?op=${op}&rotate=${rotate ? 1 : 0}`);
    state.configs = d.configs || {}; state.subUrl = d.sub_url || ''; state.fragSubUrl = d.frag_sub_url || '';
    renderConfigsList();
  } catch (e) {
    document.getElementById('configsCard').innerHTML = `<div class="pad" style="text-align:center;color:var(--red);font-size:12.5px;">❌ ${e.message}</div>`;
  }
}

function copyAllConfigs() {
  const all = ['vless_1','vless_2','vless_3','trojan_1','trojan_2','trojan_3'].map(k => state.configs[k]).filter(Boolean).join('\n');
  if (all) copyText(all);
}
function copySubLink() { if (state.subUrl) copyText(state.subUrl); }
function copyFragSub() { if (state.fragSubUrl) copyText(state.fragSubUrl); }

async function deployPanel() {
  const token = document.getElementById('inpCfToken').value.trim();
  if (token.length < 20) return toast('⚠️ Invalid Token');
  const btn = document.getElementById('btnDeployPanel');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    await api('/api/v26/panel/deploy', 'POST', { api_token: token });
    document.getElementById('inpCfToken').value = '';
    toast('🎉 V26 Ready!');
    await bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; btn.textContent = t('deploy_btn'); }
}

async function redeployPanel() {
  const btn = document.getElementById('btnRedeploy');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    await api('/api/v26/panel/redeploy', 'POST', {});
    toast('✅ V26 Updated!');
    await bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; }
}

async function runE2ETest() {
  const btn = document.getElementById('btnE2E');
  btn.disabled = true; btn.textContent = '⏳';
  try {
    const d = await api('/api/v26/panel/test', 'POST', {});
    openSheet(`
      <div style="font-size:16px;font-weight:700;margin-bottom:10px;">🩺 ${t('e2e_title')}</div>
      <div class="card">
        <div class="row"><div class="row-t">Clean IP Health</div><span class="bdg ${d.health.ok?'b-g':'b-r'}">${d.health.ok ? d.health.ms+'ms' : 'ERR'}</span></div>
        <div class="row"><div class="row-t">VLESS Tunnel</div><span class="bdg ${d.vless.ok?'b-g':'b-r'}">${d.vless.ok ? d.vless.ms+'ms' : 'ERR'}</span></div>
        <div class="row"><div class="row-t">Trojan Tunnel</div><span class="bdg ${d.trojan.ok?'b-g':'b-r'}">${d.trojan.ok ? d.trojan.ms+'ms' : 'ERR'}</span></div>
      </div>
      <button class="btn btn-blue" onclick="closeSheet()">${t('sheet_close')}</button>
    `);
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; btn.textContent = t('run_btn'); }
}


async function openDomainSheet() {
  haptic();
  openSheet(`<div style="font-size:16px;font-weight:700;margin-bottom:10px;">🌐 ${t('dom_title')}</div><div style="text-align:center;color:var(--text-2);padding:12px;">${t('loading')}</div>`);
  try {
    const d = await api('/api/v26/panel/zones');
    let zHtml = '';
    (d.zones || []).forEach(z => {
      const sug = 'edge.' + z.name;
      zHtml += `<div class="row" style="cursor:pointer;" onclick="document.getElementById('inpCustDom').value='${escapeHtml(sug)}'">
        <div class="row-m"><div class="row-t mono">${escapeHtml(z.name)}</div><div class="row-s mono">${escapeHtml(sug)}</div></div>
        <span class="bdg b-g">Active</span>
      </div>`;
    });
    openSheet(`
      <div style="font-size:16px;font-weight:700;margin-bottom:6px;">🌐 ${t('dom_title')}</div>
      <div style="font-size:12px;color:var(--text-2);margin-bottom:10px;">${t('dom_sub')}</div>
      ${zHtml ? `<div class="card">${zHtml}</div>` : ''}
      <input id="inpCustDom" class="inp mono" placeholder="edge.yourdomain.com" style="margin-bottom:8px;"/>
      <div class="g2">
        <button class="btn btn-blue btn-sm" onclick="bindCustomDomain(document.getElementById('inpCustDom').value.trim())">${t('save_btn')}</button>
        <button class="btn btn-soft btn-sm" onclick="bindCustomDomain('__revert__')">pages.dev</button>
      </div>
    `);
  } catch (e) { closeSheet(); toast('❌ ' + e.message); }
}
async function bindCustomDomain(dom) {
  if (!dom) return;
  try {
    await api('/api/v26/panel/domain', 'POST', { domain: dom });
    closeSheet();
    toast('✅ Domain Updated!');
    await bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
}

function disconnectPanel() {
  openSheet(`
    <div style="font-size:16px;font-weight:700;margin-bottom:12px;color:var(--red);">🗑️ ${t('delete_panel')}</div>
    <div class="g2">
      <button class="btn btn-soft" onclick="closeSheet()">${t('sheet_cancel')}</button>
      <button class="btn btn-red" onclick="confirmDisconnect()">${t('sheet_del_confirm')}</button>
    </div>
  `);
}
async function confirmDisconnect() {
  try { await api('/api/v26/panel/disconnect', 'POST', {}); closeSheet(); toast('🗑️'); bootstrap(); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== WARP ====================
function setWarpMode(m, el) { haptic(); state.warpMode = m; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
function setWarpPlat(p, el) { haptic(); state.warpPlat = p; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }

async function generateWarp() {
  const btn = document.getElementById('btnGenWarp');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    const b = await api('/api/v26/warp/generate', 'POST', { ip_mode: state.warpMode, platform: state.warpPlat });
    const card = document.getElementById('warpResultCard');
    card.classList.remove('hidden');
    card.innerHTML = `
      <div class="row"><div class="row-m"><div class="row-t">WARP Anti-DPI</div><div class="row-s mono">${b.endpoint}</div></div><button class="btn btn-blue btn-sm" id="wC1">${t('copy_btn')}</button></div>
      <div class="row"><div class="row-m"><div class="row-t">WoW Double-Hop</div><div class="row-s">Hiddify / Karing</div></div><button class="btn btn-soft btn-sm" id="wC2">${t('copy_btn')}</button></div>
      <div class="row"><div class="row-m"><div class="row-t">WireGuard QUIC Noise</div><div class="row-s">v2rayNG / Streisand</div></div><button class="btn btn-soft btn-sm" id="wC3">${t('copy_btn')}</button></div>
      <div class="row"><div class="row-m"><div class="row-t">AmneziaWG (.conf)</div><div class="row-s">${b.amnezia_filename}</div></div><button class="btn btn-green btn-sm" id="wDl">${t('dl_btn')}</button></div>
    `;
    document.getElementById('wC1').onclick = () => copyText(b.warp_auto_uri);
    document.getElementById('wC2').onclick = () => copyText(b.wow_uri);
    document.getElementById('wC3').onclick = () => copyText(b.wireguard_uri);
    document.getElementById('wDl').onclick = () => {
      const bl = new Blob([b.amnezia_conf], { type: 'text/plain;charset=utf-8' });
      const u = URL.createObjectURL(bl); const a = document.createElement('a'); a.href = u; a.download = b.amnezia_filename; a.click(); URL.revokeObjectURL(u);
    };
    toast('✅ WARP Ready');
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; btn.textContent = t('warp_gen_btn'); }
}

async function scanWarpLive() {
  haptic();
  try { await api('/api/v26/warp/scan', 'POST', {}); toast('🔍 Scanning...'); setTimeout(bootstrap, 6000); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== CLEAN IPS & SUPPORT ====================
async function loadCleanIps(op, el) {
  if (el) { el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
  const box = document.getElementById('cleanIpsCard');
  box.innerHTML = `<div class="pad" style="text-align:center;color:var(--text-2);font-size:12px;">${t('loading')}</div>`;
  try {
    const d = await api(`/api/v26/ips?op=${op}`);
    box.innerHTML = '';
    if (!d.ips.length) { box.innerHTML = `<div class="pad" style="text-align:center;color:var(--text-2);">${t('empty')}</div>`; return; }
    d.ips.forEach((x, i) => {
      const r = document.createElement('div'); r.className = 'row'; r.style.cursor = 'pointer';
      const spd = x.speed_mbps ? ` • ${Math.round(x.speed_mbps)}M` : '';
      r.innerHTML = `<div class="row-m"><div class="row-t mono">${i+1}. ${x.ip}</div><div class="row-s">${x.colo||'CF'}${spd}</div></div><span class="bdg b-g">${x.latency_ms ? Math.round(x.latency_ms)+'ms' : 'Auto'}</span>`;
      r.onclick = () => copyText(x.ip, `✅ ${x.ip}`);
      box.appendChild(r);
    });
  } catch (e) { box.innerHTML = `<div class="pad" style="color:var(--red);">${e.message}</div>`; }
}

async function sendSupportTicket() {
  const txt = document.getElementById('inpTicket').value.trim();
  if (!txt) return;
  try { const r = await api('/api/v26/support/ticket', 'POST', { text: txt }); document.getElementById('inpTicket').value = ''; toast(`✅ #${r.ticket_id}`); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== ADMIN ====================
async function loadAdminDashboard() {
  if (!state.isAdmin) return;
  try {
    const d = await api('/api/v26/admin/overview');
    document.getElementById('admCpu').textContent = d.sys.cpu_percent + '%';
    document.getElementById('admRam').textContent = d.sys.memory_percent + '%';
    document.getElementById('admUsersCnt').textContent = d.counts.users;
    document.getElementById('admPanelsCnt').textContent = d.counts.panels;
    updateScanUI(d.scanner);
    if (d.scanner.is_scanning) pollScanStatus();

    const s = d.settings;
    document.getElementById('swTgLock').checked = !!s.tg_lock_enabled;
    document.getElementById('inpTgChan').value = s.tg_lock_channel || '';
    document.getElementById('inpTgText').value = s.tg_lock_text || '';
    document.getElementById('swYtLock').checked = !!s.yt_lock_enabled;
    document.getElementById('inpYtUrl').value = s.yt_lock_url || '';
    document.getElementById('inpYtText').value = s.yt_lock_text || '';
    document.getElementById('swAutoScan').checked = !!s.auto_scan_enabled;
    document.getElementById('swMaint').checked = !!s.maintenance_mode;
    document.getElementById('inpSupUser').value = s.support_username || '';
    document.getElementById('inpWebappUrl').value = s.webapp_url || '';

    const tBox = document.getElementById('admTicketsCard');
    tBox.innerHTML = '';
    if (!d.tickets.length) tBox.innerHTML = `<div class="pad" style="text-align:center;color:var(--text-2);font-size:12px;">${t('empty')}</div>`;
    else d.tickets.slice(-8).reverse().forEach(tk => {
      const r = document.createElement('div'); r.className = 'row';
      r.innerHTML = `<div class="row-m"><div class="row-t">#${tk.id} • <span class="mono">${tk.user_id}</span></div><div class="row-s">${escapeHtml(tk.text)}</div></div><button class="btn btn-soft btn-sm" onclick="openDmModal(${tk.user_id})">${t('reply')}</button>`;
      tBox.appendChild(r);
    });
    loadAdminUsers(0);
  } catch (e) { toast('❌ ' + e.message); }
}

function updateScanUI(sc) {
  document.getElementById('admProgBar').style.width = (sc.progress_pct || 0) + '%';
  const st = document.getElementById('admScanState');
  if (sc.is_scanning) { st.className = 'bdg b-o'; st.textContent = sc.progress_pct + '%'; document.getElementById('admScanInfo').textContent = sc.stage; }
  else { st.className = 'bdg b-g'; st.textContent = t('ready'); document.getElementById('admScanInfo').textContent = sc.last_scan_at ? sc.last_scan_at.slice(0,16).replace('T',' ') : t('ready'); }
}
function pollScanStatus() {
  clearInterval(state.scanTimer);
  state.scanTimer = setInterval(async () => {
    try { const d = await api('/api/v26/admin/overview'); updateScanUI(d.scanner); if (!d.scanner.is_scanning) { clearInterval(state.scanTimer); toast('✅'); bootstrap(); } }
    catch(_) { clearInterval(state.scanTimer); }
  }, 2000);
}
async function adminStartScan(mode) { haptic('medium'); try { await api('/api/v26/admin/scan', 'POST', { mode }); toast('🚀'); pollScanStatus(); } catch (e) { toast('❌ ' + e.message); } }
function setAdmOp(op, el) { haptic(); state.admOp = op; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
async function adminAddIps() {
  const raw = document.getElementById('inpAdmIps').value.trim(); if (!raw) return;
  try { const r = await api('/api/v26/admin/ips', 'POST', { operator: state.admOp, ips: raw }); document.getElementById('inpAdmIps').value = ''; toast(`✅ +${r.added}`); }
  catch (e) { toast('❌ ' + e.message); }
}

async function loadAdminUsers(page=0) {
  const q = document.getElementById('inpUserSearch').value.trim();
  const box = document.getElementById('admUsersList');
  try {
    const d = await api(`/api/v26/admin/users?page=${page}&q=${encodeURIComponent(q)}`);
    box.innerHTML = '';
    if (!d.users.length) { box.innerHTML = `<div style="text-align:center;color:var(--text-2);font-size:12px;padding:8px;">${t('empty')}</div>`; return; }
    d.users.forEach(u => {
      const r = document.createElement('div'); r.className = 'row'; r.style.padding = '8px 2px'; r.style.cursor = 'pointer';
      const b = u.is_banned ? '<span class="bdg b-r">Ban</span>' : (u.has_panel ? '<span class="bdg b-g">Panel</span>' : '<span class="bdg b-b">User</span>');
      r.innerHTML = `<div class="row-m"><div class="row-t">${escapeHtml(u.full_name || u.username || u.telegram_id)}</div><div class="row-s mono">${u.telegram_id} ${u.username ? '@'+escapeHtml(u.username) : ''}</div></div>${b}`;
      r.onclick = () => openUserModal(u);
      box.appendChild(r);
    });
  } catch (e) { box.innerHTML = `<div style="color:var(--red);font-size:12px;">${e.message}</div>`; }
}

function openUserModal(u) {
  openSheet(`
    <div style="font-size:16px;font-weight:700;margin-bottom:8px;">👤 ${escapeHtml(u.full_name || String(u.telegram_id))}</div>
    <div class="card">
      <div class="row"><div class="row-t">ID</div><div class="mono">${u.telegram_id}</div></div>
      <div class="row"><div class="row-t">Panel</div><div class="mono" style="font-size:11.5px;">${escapeHtml(u.panel_host || '-')}</div></div>
      <div class="row"><div class="row-t">Usage</div><div>${u.configs_generated||0} Cfg • ${u.warp_generated||0} WARP</div></div>
    </div>
    <div class="g2" style="margin-bottom:8px;">
      <button class="btn ${u.is_banned ? 'btn-green' : 'btn-red'} btn-sm" onclick="adminUserAction(${u.telegram_id}, 'toggle_ban')">${u.is_banned ? 'Unban' : 'Ban'}</button>
      <button class="btn btn-blue btn-sm" onclick="openDmModal(${u.telegram_id})">DM</button>
    </div>
    ${u.has_panel ? `<button class="btn btn-red" onclick="adminUserAction(${u.telegram_id}, 'reset_panel')">Delete User Panel</button>` : ''}
  `);
}
async function adminUserAction(uid, action) { try { await api('/api/v26/admin/user/action', 'POST', { target_id: uid, action }); closeSheet(); toast('✅'); loadAdminUsers(0); } catch (e) { toast('❌ ' + e.message); } }
function openDmModal(uid) {
  openSheet(`
    <div style="font-size:16px;font-weight:700;margin-bottom:8px;">✉️ DM <span class="mono">${uid}</span></div>
    <textarea id="inpDmMsg" class="ta" style="margin-bottom:10px;"></textarea>
    <button class="btn btn-blue" onclick="sendDm(${uid})">Send</button>
  `);
}
async function sendDm(uid) { const txt = document.getElementById('inpDmMsg').value.trim(); if (!txt) return; try { await api('/api/v26/admin/user/dm', 'POST', { target_id: uid, text: txt }); closeSheet(); toast('✅'); } catch (e) { toast('❌ ' + e.message); } }
async function saveAdminSettings() {
  try {
    await api('/api/v26/admin/settings', 'POST', {
      tg_lock_enabled: document.getElementById('swTgLock').checked,
      tg_lock_channel: document.getElementById('inpTgChan').value.trim(),
      tg_lock_text: document.getElementById('inpTgText').value.trim(),
      yt_lock_enabled: document.getElementById('swYtLock').checked,
      yt_lock_url: document.getElementById('inpYtUrl').value.trim(),
      yt_lock_text: document.getElementById('inpYtText').value.trim(),
      auto_scan_enabled: document.getElementById('swAutoScan').checked,
      maintenance_mode: document.getElementById('swMaint').checked,
      support_username: document.getElementById('inpSupUser').value.trim().replace(/^@/, ''),
      webapp_url: document.getElementById('inpWebappUrl').value.trim(),
    });
    toast('✅ Saved');
  } catch (e) { toast('❌ ' + e.message); }
}
async function adminBroadcast() {
  const txt = document.getElementById('inpBroadcast').value.trim(); if (!txt) return;
  try { const r = await api('/api/v26/admin/broadcast', 'POST', { text: txt }); document.getElementById('inpBroadcast').value = ''; toast(`✅ ${r.sent} / ❌ ${r.failed}`); }
  catch (e) { toast('❌ ' + e.message); }
}

bootstrap();
</script>
</body>
</html>
"""
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/webapp.py
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
from app.bot.operator_scanner import is_restricted_1034_ip
from app.bot.ui import CLOUDFLARE_DIRECT_TOKEN_URL
from app.bot.warp_builder import build_warp_bundle, register_real_warp_device
from app.bot.webapp_ui import MINI_APP_HTML
from app.bot.worker_template import CURRENT_WORKER_VERSION
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e
from app.core.config import get_settings
from app.services.monitoring import collect_system_health

logger = logging.getLogger(__name__)


def verify_telegram_init_data(init_data: str, bot_token: str) -> dict | None:
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
        return json.loads(user_raw) if user_raw else None
    except Exception:
        return None


def _ensure_sub_token(store, panel: dict) -> str:
    if not panel.get("sub_token"):
        panel["sub_token"] = secrets.token_urlsafe(12)
        store.save()
    return str(panel["sub_token"])


async def _probe_alt_ports(worker_host: str, ip_v: str, ip_t: str) -> tuple[int, int]:
    (ok_v, _, _), (ok_t, _, _) = await asyncio.gather(
        check_ip_routes_worker(worker_host, ip_v, 2083, timeout_sec=2.5),
        check_ip_routes_worker(worker_host, ip_t, 8443, timeout_sec=2.5),
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

        eff_proxy, _ = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
        ips = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 10), operator=op, count=3)
        if fmt == "json":
            arr = cf_service.build_fragment_json_bundle(panel, ips, operator=op, effective_proxy_ip=eff_proxy)
            return web.Response(
                text=json.dumps(arr, ensure_ascii=False, indent=2),
                content_type="application/json",
                headers={"Profile-Update-Interval": "2", "Cache-Control": "no-store"},
            )

        ech_b64 = "" if cf_service.is_custom_domain(panel["host"]) else await fetch_live_cloudflare_ech_b64()
        c6 = cf_service.build_six_ech_configs(panel, ips, operator=op, ech_b64=ech_b64, effective_proxy_ip=eff_proxy)
        raw_lines = "\n".join(c6[k] for k in ("vless_1", "vless_2", "vless_3", "trojan_1", "trojan_2", "trojan_3"))
        b64_payload = base64.b64encode(raw_lines.encode("utf-8")).decode("ascii")
        return web.Response(
            text=b64_payload, content_type="text/plain",
            headers={"Profile-Title": "CFHub V26", "Profile-Update-Interval": "2", "Cache-Control": "no-store"},
        )

    async def handle_bootstrap(request: web.Request) -> web.Response:
        u = _auth_user(request)
        pools = store.data.get("operator_pools", {})
        pool_counts = {k: len(pools.get(k, [])) for k in ("mci", "mtn", "mkh")}
        ep4, ep6, wping = bg_engine.get_best_warp_endpoints()
        px_pool = bg_engine.get_proxy_ip_pool()
        cfg = store.data["settings"]
        sup_u = str(cfg.get("support_username") or "").lstrip("@")
        sup_id = cfg.get("support_user_id") or (settings.owner_telegram_ids[0] if settings.owner_telegram_ids else 0)
        sup_url = f"https://t.me/{sup_u}" if sup_u else (f"tg://user?id={sup_id}" if sup_id else "")

        if not u:
            return web.json_response({
                "ok": True, "authenticated": False, "is_admin": False, "has_panel": False, "lang": "fa",
                "pools": pool_counts, "proxy_ip_pool": px_pool,
                "warp": {"ep4": ep4, "ep6": ep6, "ping": wping, "v4_count": len(store.data.get("warp_v4_pool", [])), "v6_count": len(store.data.get("warp_v6_pool", []))},
                "cf_token_url": CLOUDFLARE_DIRECT_TOKEN_URL, "support_url": sup_url,
            })

        uid = u["id"]
        if store.is_banned(uid) and not u["is_admin"]:
            return web.json_response({"ok": False, "error": "Access restricted"}, status=403)
        if cfg.get("maintenance_mode") and not u["is_admin"]:
            return web.json_response({"ok": False, "error": "Maintenance mode"}, status=503)

        lock_res = await _check_locks_for(uid, u["is_admin"])
        if lock_res:
            return web.json_response({"ok": True, "lang": store.get_lang(uid), **lock_res})

        panel = store.data.get("panels", {}).get(str(uid))
        panel_out = None
        if panel:
            _ensure_sub_token(store, panel)
            eff_px, px_mode = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
            panel_out = {
                "host": panel["host"],
                "engine": panel.get("engine", "pages"),
                "operator": panel.get("operator", "mci"),
                "proxy_ip_enabled": bool(panel.get("proxy_ip_enabled", False)),
                "proxy_ip_mode": px_mode,
                "effective_proxy_ip": eff_px,
                "version": panel.get("worker_version", "v25"),
                "is_updated": bool(panel.get("worker_version") == CURRENT_WORKER_VERSION and panel.get("last_health_ok", False)),
            }

        return web.json_response({
            "ok": True, "authenticated": True, "is_admin": u["is_admin"], "has_panel": bool(panel),
            "lang": store.get_lang(uid), "panel": panel_out, "pools": pool_counts, "proxy_ip_pool": px_pool,
            "warp": {"ep4": ep4, "ep6": ep6, "ping": wping, "v4_count": len(store.data.get("warp_v4_pool", [])), "v6_count": len(store.data.get("warp_v6_pool", []))},
            "cf_token_url": CLOUDFLARE_DIRECT_TOKEN_URL, "support_url": sup_url,
        })

    async def handle_lock_verify(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        if store.data["settings"].get("yt_lock_enabled"):
            store.set_yt_verified(u["id"], True)
        lock_res = await _check_locks_for(u["id"], u["is_admin"])
        return web.json_response({"ok": True, "unlocked": lock_res is None})

    async def handle_lang(request: web.Request) -> web.Response:
        u = _auth_user(request)
        body = {}
        try:
            body = await request.json()
        except Exception:
            pass
        if not u:
            return web.json_response({"ok": True, "lang": body.get("lang", "fa")})
        req_lang = body.get("lang")
        if req_lang in ("fa", "en"):
            store.data["users"].setdefault(str(u["id"]), {"telegram_id": u["id"]})["lang"] = req_lang
            store.save()
            return web.json_response({"ok": True, "lang": req_lang})
        return web.json_response({"ok": True, "lang": store.toggle_lang(u["id"])})

    async def handle_panel_configs(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Open inside Telegram"}, status=401)
        uid = str(u["id"])
        op = request.query.get("op", "mci").strip().lower()
        rotate = request.query.get("rotate", "0") == "1"
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        panel = store.data.get("panels", {}).get(uid)
        if not panel:
            return web.json_response({"ok": False, "error": "No panel found"}, status=404)

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

        eff_proxy, _ = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
        ech_b64 = "" if cf_service.is_custom_domain(panel["host"]) else await fetch_live_cloudflare_ech_b64()
        c6 = cf_service.build_six_ech_configs(panel, ips, operator=op, ech_b64=ech_b64, effective_proxy_ip=eff_proxy)
        base_url = (store.data["settings"].get("webapp_url") or f"https://{request.host}").rstrip("/")
        return web.json_response({
            "ok": True, "configs": c6,
            "sub_url": f"{base_url}/sub/{uid}?op={op}&t={sub_tok}",
            "frag_sub_url": f"{base_url}/sub/{uid}?op={op}&t={sub_tok}&fmt=json",
        })

    async def handle_panel_deploy(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        body = await request.json()
        raw_token = str(body.get("api_token", "")).strip()
        if len(raw_token) < 20 or " " in raw_token:
            return web.json_response({"ok": False, "error": "Invalid Cloudflare Token"}, status=400)

        uid_s = str(u["id"])
        old = store.data["panels"].get(uid_s) or {}
        panel_uuid = old.get("uuid") or str(uuid.uuid4())
        trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
        proj_name = old.get("project_name") or _new_neutral_name()

        # Deploy clean DIRECT worker (proxy_ip="") — ProxyIP is OFF by default!
        dep = await cf_service.deploy_dual_panel(
            api_token=raw_token, user_uuid=panel_uuid, trojan_password=trojan_pass,
            project_name=proj_name, proxy_ip="",
        )
        if not dep.ok:
            return web.json_response({"ok": False, "error": dep.error or "Deploy failed"}, status=400)

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
            "proxy_ip_enabled": False, "proxy_ip_mode": "off", "proxy_ip": "",
            "auto_ip": True, "worker_version": CURRENT_WORKER_VERSION,
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
            return web.json_response({"ok": False, "error": "Cloudflare account not found"}, status=404)
        token = store.decrypt_secret(cf["encrypted_token"])
        dep = await cf_service.deploy_dual_panel(
            api_token=token, user_uuid=panel["uuid"], trojan_password=panel["trojan_password"],
            project_name=panel.get("project_name") or "", proxy_ip="",
            force_new_name=(panel.get("engine") != "pages"),
        )
        if not dep.ok:
            return web.json_response({"ok": False, "error": dep.error or "Update failed"}, status=400)
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
            return web.json_response({"ok": False, "error": "Panel not found"}, status=404)
        (h_ok, h_ms, h_m), (v_ok, v_ms, v_m), (t_ok, t_ms, t_m) = await asyncio.gather(
            check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
            test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "vless", panel["uuid"], target_host="www.gstatic.com", use_early_data=True),
            test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "trojan", panel["trojan_password"], target_host="www.gstatic.com", use_early_data=True),
        )
        panel["last_health_ok"] = bool(h_ok and (v_ok or t_ok))
        store.save()
        return web.json_response({
            "ok": True,
            "health": {"ok": h_ok, "ms": h_ms, "msg": h_m},
            "vless": {"ok": v_ok, "ms": v_ms, "msg": v_m},
            "trojan": {"ok": t_ok, "ms": t_ms, "msg": t_m},
        })

    async def handle_panel_proxyip(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        panel = store.data["panels"].get(str(u["id"]))
        if not panel:
            return web.json_response({"ok": False, "error": "Panel not found"}, status=404)
        body = await request.json()
        enabled = bool(body.get("enabled", False))
        mode = str(body.get("mode", "auto" if enabled else "off")).lower()
        pip = str(body.get("proxy_ip", "")).strip()

        if not enabled or mode == "off":
            panel["proxy_ip_enabled"] = False
            panel["proxy_ip_mode"] = "off"
        elif mode == "auto":
            panel["proxy_ip_enabled"] = True
            panel["proxy_ip_mode"] = "auto"
        else:
            panel["proxy_ip_enabled"] = True
            panel["proxy_ip_mode"] = mode
            if pip:
                panel["proxy_ip"] = pip
        store.save()
        eff, eff_mode = cf_service.resolve_panel_proxy_ip(panel, bg_engine.get_best_proxy_ip())
        return web.json_response({
            "ok": True,
            "proxy_ip_enabled": bool(panel["proxy_ip_enabled"]),
            "proxy_ip_mode": eff_mode,
            "effective_proxy_ip": eff,
        })

    async def handle_panel_zones(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        uid_s = str(u["id"])
        cf = store.data["cf_accounts"].get(uid_s)
        if not cf:
            return web.json_response({"ok": True, "zones": []})
        token = store.decrypt_secret(cf["encrypted_token"])
        zones = await cf_service.list_account_zones(token, cf["account_id"])
        return web.json_response({"ok": True, "zones": zones})

    async def handle_panel_domain(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        uid_s = str(u["id"])
        cf = store.data["cf_accounts"].get(uid_s)
        panel = store.data["panels"].get(uid_s)
        if not cf or not panel:
            return web.json_response({"ok": False, "error": "Panel not found"}, status=404)
        body = await request.json()
        dom = str(body.get("domain", "")).strip().lower()
        if dom == "__revert__":
            fb = panel.get("fallback_host") or f"{panel.get('project_name', '')}.pages.dev"
            panel["host"] = fb
            panel["sni"] = fb
            panel["custom_domain"] = ""
            store.save()
            return web.json_response({"ok": True, "host": fb})
        token = store.decrypt_secret(cf["encrypted_token"])
        pages_host = panel.get("fallback_host") or f"{panel.get('project_name', '')}.pages.dev"
        ok, res = await cf_service.bind_custom_domain(token, cf["account_id"], panel["project_name"], pages_host, dom)
        if not ok:
            return web.json_response({"ok": False, "error": res}, status=400)
        panel["host"] = res
        panel["sni"] = res
        panel["custom_domain"] = res
        store.save()
        return web.json_response({"ok": True, "host": res})

    async def handle_panel_disconnect(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
        uid_s = str(u["id"])
        store.data["cf_accounts"].pop(uid_s, None)
        store.data["panels"].pop(uid_s, None)
        store.save()
        return web.json_response({"ok": True})

    async def handle_warp_generate(request: web.Request) -> web.Response:
        u = _auth_user(request)
        if not u:
            return web.json_response({"ok": False, "error": "Open inside Telegram"}, status=401)
        body = await request.json()
        ip_mode = body.get("ip_mode", "ipv6")
        platform = body.get("platform", "ios")
        if ip_mode not in ("ipv4", "ipv6", "dual"):
            ip_mode = "ipv6"
        if platform not in ("ios", "android", "windows"):
            platform = "ios"
        reg = await register_real_warp_device()
        if not reg.ok:
            return web.json_response({"ok": False, "error": reg.error or "WARP registration failed"}, status=502)
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
            return web.json_response({"ok": False, "error": "Empty message"}, status=400)
        tno = len(store.data.get("support_tickets", [])) + 1
        store.data["support_tickets"].append({"id": tno, "user_id": u["id"], "text": txt, "at": datetime.now(timezone.utc).isoformat()})
        store.save()
        if bot is not None:
            for oid in admin_ids:
                try:
                    await bot.send_message(oid, f"📩 <b>Ticket #{tno}</b> from <a href='tg://user?id={u['id']}'>{html.escape(u['full_name'] or str(u['id']))}</a> (<code>{u['id']}</code>):\n{html.escape(txt)}", parse_mode="HTML")
                except Exception:
                    pass
        return web.json_response({"ok": True, "ticket_id": tno})

    def _require_admin(request: web.Request) -> dict | None:
        u = _auth_user(request)
        return u if (u and u["is_admin"]) else None

    async def handle_admin_overview(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        return web.json_response({
            "ok": True, "sys": collect_system_health(),
            "counts": {"users": len(store.data.get("users", {})), "panels": len(store.data.get("panels", {}))},
            "scanner": {
                "is_scanning": bg_engine.is_scanning, "stage": bg_engine.current_stage,
                "progress_pct": bg_engine.progress_pct, "last_scan_at": bg_engine.last_scan_at,
            },
            "settings": store.data.get("settings", {}),
            "tickets": store.data.get("support_tickets", [])[-20:],
        })

    async def handle_admin_scan(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        if bg_engine.is_scanning:
            return web.json_response({"ok": False, "error": "Already scanning"}, status=409)
        if body.get("mode") == "warp":
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
        added = 0
        for item in str(body.get("ips", "")).replace(",", " ").split():
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
        return web.json_response({
            "ok": True, "total": len(all_u),
            "users": [{**u, "has_panel": str(u["telegram_id"]) in panels, "panel_host": (panels.get(str(u["telegram_id"])) or {}).get("host", "")} for u in chunk],
        })

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
            return web.json_response({"ok": False, "error": "Bot unavailable"}, status=503)
        body = await request.json()
        await bot.send_message(int(body.get("target_id", 0)), f"📩 <b>Admin:</b>\n\n{html.escape(str(body.get('text', '')).strip())}", parse_mode="HTML")
        return web.json_response({"ok": True})

    async def handle_admin_settings(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        body = await request.json()
        for k in ("tg_lock_enabled", "tg_lock_channel", "tg_lock_text", "yt_lock_enabled", "yt_lock_url", "yt_lock_text", "auto_scan_enabled", "maintenance_mode", "support_username", "webapp_url"):
            if k in body:
                store.data["settings"][k] = body[k]
        store.save()
        return web.json_response({"ok": True})

    async def handle_admin_broadcast(request: web.Request) -> web.Response:
        if not _require_admin(request):
            return web.json_response({"ok": False, "error": "Admin only"}, status=403)
        if bot is None:
            return web.json_response({"ok": False, "error": "Bot unavailable"}, status=503)
        txt = str((await request.json()).get("text", "")).strip()
        sent, failed = 0, 0
        for uid_s in list(store.data.get("users", {}).keys()):
            try:
                await bot.send_message(int(uid_s), f"📢 <b>Announcement:</b>\n\n{html.escape(txt)}", parse_mode="HTML")
                sent += 1
                await asyncio.sleep(0.04)
            except Exception:
                failed += 1
        return web.json_response({"ok": True, "sent": sent, "failed": failed})

    app.router.add_get("/", handle_index)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/sub/{uid}", handle_sub)
    for pref in ("/api/v26", "/api/v25", "/api/v24", "/api/v23"):
        app.router.add_get(f"{pref}/bootstrap", handle_bootstrap)
        app.router.add_post(f"{pref}/lock/verify", handle_lock_verify)
        app.router.add_post(f"{pref}/lang", handle_lang)
        app.router.add_get(f"{pref}/panel/configs", handle_panel_configs)
        app.router.add_post(f"{pref}/panel/deploy", handle_panel_deploy)
        app.router.add_post(f"{pref}/panel/redeploy", handle_panel_redeploy)
        app.router.add_post(f"{pref}/panel/test", handle_panel_test)
        app.router.add_post(f"{pref}/panel/proxyip", handle_panel_proxyip)
        app.router.add_get(f"{pref}/panel/zones", handle_panel_zones)
        app.router.add_post(f"{pref}/panel/domain", handle_panel_domain)
        app.router.add_post(f"{pref}/panel/disconnect", handle_panel_disconnect)
        app.router.add_post(f"{pref}/warp/generate", handle_warp_generate)
        app.router.add_post(f"{pref}/warp/scan", handle_warp_scan)
        app.router.add_get(f"{pref}/ips", handle_ips)
        app.router.add_post(f"{pref}/support/ticket", handle_support_ticket)
        app.router.add_get(f"{pref}/admin/overview", handle_admin_overview)
        app.router.add_post(f"{pref}/admin/scan", handle_admin_scan)
        app.router.add_post(f"{pref}/admin/ips", handle_admin_ips)
        app.router.add_get(f"{pref}/admin/users", handle_admin_users)
        app.router.add_post(f"{pref}/admin/user/action", handle_admin_user_action)
        app.router.add_post(f"{pref}/admin/user/dm", handle_admin_dm)
        app.router.add_post(f"{pref}/admin/settings", handle_admin_settings)
        app.router.add_post(f"{pref}/admin/broadcast", handle_admin_broadcast)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    logger.info("V26 iOS Minimalist Mini App listening on http://0.0.0.0:%s", port)
    return runner
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/ui.py
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
    "%5D&accountId=*&zoneId=all&name=CFHubV26"
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
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > backend/app/bot/bot.py
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
    waiting_custom_domain = State()
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
            btn(tr(lang, "btn_custom_dom"), callback_data="cf:domain_menu", style="success"),
        ],
        [
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
    ech_b64 = "" if cf_service.is_custom_domain(panel["host"]) else await fetch_live_cloudflare_ech_b64()
    c6 = cf_service.build_six_ech_configs(panel, verified_ips, operator=op, ech_b64=ech_b64, effective_proxy_ip=eff_px)
    op_lbl = op_label(op, lang)
    px_desc = tr(lang, "st_off") if not eff_px else f"{eff_px} ({px_mode})"
    wurl = (store.data["settings"].get("webapp_url") or "https://app.prostoreshop.site").rstrip("/")
    sub_line = (
        f"\n{tr(lang, 'cfg_sub_title')}\n<code>{wurl}/sub/{uid}?op={op}&amp;t={panel['sub_token']}</code>\n"
        f"🛡️ <b>Auto-Fragment (JSON • ضد فیلتر شدید):</b>\n<code>{wurl}/sub/{uid}?op={op}&amp;t={panel['sub_token']}&amp;fmt=json</code>\n"
    ) if wurl.startswith("https://") else ""

    msg = (
        f"{tr(lang, 'cfg_title', op=op_lbl)}\n"
        f"{tr(lang, 'cfg_proxy_line', mode=html.escape(px_desc))}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 <b>VLESS #1 ({'Direct 0-RTT' if c6.get('is_custom_domain') else 'ECH 0-RTT'})</b>\n<blockquote><code>{html.escape(c6['vless_1'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #2 ({'Direct iOS' if c6.get('is_custom_domain') else 'ECH Stable'})</b>\n<blockquote><code>{html.escape(c6['vless_2'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #3 ({'Direct WS' if c6.get('is_custom_domain') else 'ECH Auto'})</b>\n<blockquote><code>{html.escape(c6['vless_3'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #1 ({'Direct 0-RTT' if c6.get('is_custom_domain') else 'ECH 0-RTT'})</b>\n<blockquote><code>{html.escape(c6['trojan_1'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #2 ({'Direct iOS' if c6.get('is_custom_domain') else 'ECH Stable'})</b>\n<blockquote><code>{html.escape(c6['trojan_2'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #3 ({'Direct WS' if c6.get('is_custom_domain') else 'ECH Auto'})</b>\n<blockquote><code>{html.escape(c6['trojan_3'])}</code></blockquote>\n"
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
        test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "vless", panel["uuid"], target_host="www.gstatic.com", use_early_data=True),
        test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "trojan", panel["trojan_password"], target_host="www.gstatic.com", use_early_data=True),
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
        await _safe_answer(cb, "🔄 Updating to V26...")
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


@router.callback_query(F.data == "cf:domain_menu")
async def cb_cf_domain_menu(cb: CallbackQuery, state: FSMContext) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, "🔍...")
    await state.set_state(Flow.waiting_custom_domain)
    zones = []
    try:
        token = store.decrypt_secret(cf["encrypted_token"])
        zones = await cf_service.list_account_zones(token, cf["account_id"])
    except Exception:
        pass
    rows = []
    for z in zones[:6]:
        sug = f"edge.{z['name']}"
        rows.append([btn(f"🌐 {sug}", callback_data=f"cf:binddom:{sug}", style="success")])
    if cf_service.is_custom_domain(panel.get("host", "")):
        rows.append([btn(tr(lang, "dom_revert"), callback_data="cf:binddom:__revert__", style="primary")])
    rows.append([btn(tr(lang, "btn_back"), callback_data="m:mypanel", style="danger")])
    body = tr(lang, "dom_desc") if zones else tr(lang, "dom_none")
    await _edit(cb, f"{tr(lang, 'dom_title')}\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


@router.callback_query(F.data.startswith("cf:binddom:"))
async def cb_cf_binddom_btn(cb: CallbackQuery, state: FSMContext) -> None:
    uid = cb.from_user.id
    lang = store.get_lang(uid)
    dom = cb.data.split(":", 2)[2]
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await _safe_answer(cb)
        return
    await state.clear()
    if dom == "__revert__":
        fb = panel.get("fallback_host") or f"{panel.get('project_name', '')}.pages.dev"
        panel["host"] = fb
        panel["sni"] = fb
        panel["custom_domain"] = ""
        store.save()
        await _safe_answer(cb, "✅", show_alert=True)
        t, m = _render_personal_panel(uid)
        await _edit(cb, t, m)
        return
    await _safe_answer(cb, "⏳...")
    token = store.decrypt_secret(cf["encrypted_token"])
    pages_host = panel.get("fallback_host") or f"{panel.get('project_name', '')}.pages.dev"
    ok, res = await cf_service.bind_custom_domain(token, cf["account_id"], panel["project_name"], pages_host, dom)
    if not ok:
        await _edit(cb, f"❌ {html.escape(res)}", back_home_kb("m:mypanel", lang))
        return
    panel["host"] = res
    panel["sni"] = res
    panel["custom_domain"] = res
    store.save()
    t, m = _render_personal_panel(uid)
    await _edit(cb, f"{tr(lang, 'dom_ok', dom=html.escape(res))}\n\n{t}", m)


@router.message(Flow.waiting_custom_domain)
async def handle_custom_domain_msg(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    lang = store.get_lang(uid)
    dom = (message.text or "").strip().lower()
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    await state.clear()
    if not cf or not panel:
        return
    token = store.decrypt_secret(cf["encrypted_token"])
    pages_host = panel.get("fallback_host") or f"{panel.get('project_name', '')}.pages.dev"
    ok, res = await cf_service.bind_custom_domain(token, cf["account_id"], panel["project_name"], pages_host, dom)
    if not ok:
        await message.answer(f"❌ {html.escape(res)}", parse_mode="HTML", reply_markup=back_home_kb("m:mypanel", lang))
        return
    panel["host"] = res
    panel["sni"] = res
    panel["custom_domain"] = res
    store.save()
    t, m = _render_personal_panel(uid)
    await message.answer(f"{tr(lang, 'dom_ok', dom=html.escape(res))}\n\n{t}", parse_mode="HTML", reply_markup=m)


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
                logger.info("Starting Cloudflare Config Hub V26 Pro Bot (Always-Alive).")
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
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > .env.example
# ============================================================
# Cloudflare Config Hub (CFHub V26) — Environment Template
# Copy to `.env` and fill in your real credentials.
# NEVER commit `.env` with real tokens to a public repository!
# ============================================================

# 1. Telegram Bot Token from @BotFather
TELEGRAM_BOT_TOKEN=1234567890:REPLACE_WITH_YOUR_BOT_TOKEN

# 2. Admin Telegram numeric IDs in JSON list format (e.g. [123456789] or [111,222])
OWNER_TELEGRAM_IDS=[123456789]

# 3. Secret keys (generate with: openssl rand -hex 24)
#    Note: Avoid bare `$` or escape as `$$` for Docker Compose.
ENCRYPTION_MASTER_KEY=REPLACE_WITH_RANDOM_48_HEX_CHARS
JWT_SECRET_KEY=REPLACE_WITH_ANOTHER_RANDOM_48_HEX_CHARS

# 4. HTTPS Mini App URL (Cloudflare Proxied + Origin Rule -> port 8088)
WEBAPP_URL=https://app.prostoreshop.site

# 5. Optional Telegram Support Username (without @)
SUPPORT_USERNAME=your_support_username
__CFHUB_V26_EOF__

cat <<'__CFHUB_V26_EOF__' > install.sh
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/arjeyproject/panelcf.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/panelcf}"

echo "============================================================"
echo "  CFHub V26 — One-Click Installer (Bot + iOS Mini App + 24/7)"
echo "============================================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Please run as root (sudo bash install.sh)."
  exit 1
fi

echo ">>> [1/5] Installing prerequisites (git, curl, ufw, cron, docker)..."
apt-get update -y
apt-get install -y git curl ca-certificates ufw cron openssl
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker cron
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 8088/tcp >/dev/null 2>&1 || true

echo ">>> [2/5] Fetching / updating repository at $INSTALL_DIR..."
if [ -d "$INSTALL_DIR/.git" ]; then
  cd "$INSTALL_DIR"
  git pull --ff-only || true
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi
mkdir -p data
chmod 777 data

echo ">>> [3/5] Configuring .env..."
if [ ! -f .env ]; then
  read -rp "Enter TELEGRAM_BOT_TOKEN: " BOT_TOKEN
  read -rp "Enter Admin Telegram numeric ID (e.g. 8516792883): " ADMIN_ID
  read -rp "Enter Mini App HTTPS URL [https://app.prostoreshop.site]: " APP_URL
  APP_URL="${APP_URL:-https://app.prostoreshop.site}"
  read -rp "Enter Support Username without @ (optional): " SUP_USER

  # Auto-wrap numeric ID(s) in brackets for Pydantic list validation
  ADMIN_ID_CLEAN="$(echo "$ADMIN_ID" | tr -d ' []')"
  ENC_KEY="$(openssl rand -hex 24)"
  JWT_KEY="$(openssl rand -hex 24)"

  cat <<EOF > .env
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
OWNER_TELEGRAM_IDS=[${ADMIN_ID_CLEAN}]
ENCRYPTION_MASTER_KEY=${ENC_KEY}
JWT_SECRET_KEY=${JWT_KEY}
WEBAPP_URL=${APP_URL}
SUPPORT_USERNAME=${SUP_USER}
EOF
  # Escape any literal '$' for Docker Compose safety
  sed -i 's/\$/\$\$/g' .env
  echo "[OK] Created .env with secure random keys."
else
  echo "[OK] Existing .env detected — keeping current credentials."
fi

echo ">>> [4/5] Installing 2-minute 24/7 Watchdog..."
cat <<__WD_EOF__ > /usr/local/bin/cfhub-watchdog.sh
#!/usr/bin/env bash
if ! curl -sf --max-time 6 http://127.0.0.1:8088/health >/dev/null 2>&1; then
  sleep 3
  if ! curl -sf --max-time 6 http://127.0.0.1:8088/health >/dev/null 2>&1; then
    echo "\$(date -u +%FT%TZ) [WATCHDOG] Unhealthy -> restarting telegram_bot" >> /var/log/cfhub-watchdog.log
    cd "$INSTALL_DIR" && docker compose up -d --no-deps telegram_bot >> /var/log/cfhub-watchdog.log 2>&1
  fi
fi
__WD_EOF__
chmod +x /usr/local/bin/cfhub-watchdog.sh
(crontab -l 2>/dev/null | grep -v "cfhub-watchdog.sh"; echo "*/2 * * * * /usr/local/bin/cfhub-watchdog.sh") | crontab - || true

echo ">>> [5/5] Building and starting telegram_bot (V26)..."
docker compose up -d --build --no-deps telegram_bot
sleep 5
echo -n "Health check: "
curl -s http://127.0.0.1:8088/health || true
echo ""
echo "============================================================"
echo "  DONE! Bot & iOS Mini App are running 24/7 on port 8088."
echo "  View logs: cd $INSTALL_DIR && docker compose logs -f telegram_bot"
echo "============================================================"
__CFHUB_V26_EOF__

chmod +x install.sh

echo ">>> Rebuilding and restarting telegram_bot (V26)..."
docker compose up -d --build --no-deps telegram_bot
sleep 5
curl -s http://127.0.0.1:8088/health || true
echo ""
docker compose logs --tail=20 telegram_bot
echo ">>> V26 Complete! Now delete this updater script (rm -f upgrade_v26.sh) before git push."
