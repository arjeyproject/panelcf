from __future__ import annotations

MINI_APP_HTML = r"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover"/>
<title>CFHub iOS</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
  :root {
    --bg: #F2F2F7;
    --surface: #FFFFFF;
    --surface-2: #F9F9FB;
    --glass: rgba(249, 249, 251, 0.82);
    --separator: rgba(60, 60, 67, 0.12);
    --text: #000000;
    --text-2: #6C6C70;
    --text-3: #8E8E93;
    --blue: #007AFF;
    --green: #34C759;
    --orange: #FF9500;
    --red: #FF3B30;
    --indigo: #5856D6;
    --seg-bg: rgba(118, 118, 128, 0.12);
    --seg-active: #FFFFFF;
    --shadow: 0 2px 10px rgba(0, 0, 0, 0.04);
    --radius: 16px;
  }
  [data-theme="dark"] {
    --bg: #000000;
    --surface: #1C1C1E;
    --surface-2: #2C2C2E;
    --glass: rgba(28, 28, 30, 0.84);
    --separator: rgba(84, 84, 88, 0.45);
    --text: #FFFFFF;
    --text-2: #AEAEB2;
    --text-3: #8E8E93;
    --blue: #0A84FF;
    --green: #30D158;
    --orange: #FF9F0A;
    --red: #FF453A;
    --indigo: #5E5CE6;
    --seg-bg: rgba(118, 118, 128, 0.24);
    --seg-active: #3A3A3C;
    --shadow: 0 4px 16px rgba(0, 0, 0, 0.35);
  }
  * {
    box-sizing: border-box;
    -webkit-tap-highlight-color: transparent;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Tahoma, sans-serif;
  }
  html, body {
    margin: 0;
    padding: 0;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    overflow-x: hidden;
  }

  /* Frosted iOS Top Bar */
  .topbar {
    position: sticky;
    top: 0;
    z-index: 40;
    background: var(--glass);
    backdrop-filter: saturate(180%) blur(20px);
    -webkit-backdrop-filter: saturate(180%) blur(20px);
    border-bottom: 0.5px solid var(--separator);
    padding: 12px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .topbar-title {
    font-size: 17px;
    font-weight: 700;
    letter-spacing: -0.3px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .pill-ver {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 999px;
    background: rgba(0, 122, 255, 0.12);
    color: var(--blue);
  }
  .topbar-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .icon-pill {
    border: none;
    background: var(--seg-bg);
    color: var(--text);
    height: 32px;
    padding: 0 11px;
    border-radius: 999px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  /* Main Content */
  .container {
    max-width: 540px;
    margin: 0 auto;
    padding: 14px 16px 96px;
  }
  .section-label {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-2);
    margin: 16px 12px 7px;
    text-transform: uppercase;
    letter-spacing: 0.2px;
  }

  /* iOS Inset Grouped Card */
  .card {
    background: var(--surface);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    border: 0.5px solid var(--separator);
    overflow: hidden;
    margin-bottom: 12px;
  }
  .card-pad { padding: 14px 16px; }

  /* Inset List Rows */
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    gap: 12px;
    border-bottom: 0.5px solid var(--separator);
  }
  .row:last-child { border-bottom: none; }
  .row-main { min-width: 0; flex: 1; }
  .row-title { font-size: 15px; font-weight: 600; line-height: 1.35; }
  .row-sub { font-size: 12px; color: var(--text-2); margin-top: 2px; word-break: break-all; }

  /* Stats Grid */
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 8px;
    margin-bottom: 12px;
  }
  .stat-tile {
    background: var(--surface);
    border-radius: 14px;
    border: 0.5px solid var(--separator);
    padding: 10px 6px;
    text-align: center;
    box-shadow: var(--shadow);
  }
  .stat-val { font-size: 17px; font-weight: 700; color: var(--text); }
  .stat-lbl { font-size: 11px; color: var(--text-2); margin-top: 2px; }

  /* iOS Segmented Control */
  .segmented {
    display: flex;
    background: var(--seg-bg);
    padding: 3px;
    border-radius: 12px;
    margin-bottom: 12px;
  }
  .seg-btn {
    flex: 1;
    border: none;
    background: transparent;
    color: var(--text);
    padding: 8px 6px;
    border-radius: 9px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.18s ease;
  }
  .seg-btn.active {
    background: var(--seg-active);
    box-shadow: 0 1px 4px rgba(0, 0, 0, 0.12);
    color: var(--text);
  }

  /* iOS Buttons */
  .btn {
    border: none;
    border-radius: 12px;
    padding: 12px 16px;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    width: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    transition: opacity 0.15s, transform 0.1s;
    text-decoration: none;
  }
  .btn:active { opacity: 0.72; transform: scale(0.985); }
  .btn-primary { background: var(--blue); color: #fff; }
  .btn-green { background: var(--green); color: #fff; }
  .btn-red { background: rgba(255, 59, 48, 0.12); color: var(--red); }
  .btn-soft { background: var(--seg-bg); color: var(--text); }
  .btn-sm { padding: 7px 12px; font-size: 13px; border-radius: 10px; width: auto; }
  .btn-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }

  /* Badges */
  .badge {
    font-size: 11px;
    font-weight: 600;
    padding: 3px 9px;
    border-radius: 999px;
    white-space: nowrap;
  }
  .b-green { background: rgba(52, 199, 89, 0.15); color: var(--green); }
  .b-blue { background: rgba(0, 122, 255, 0.14); color: var(--blue); }
  .b-orange { background: rgba(255, 149, 0, 0.15); color: var(--orange); }
  .b-red { background: rgba(255, 59, 48, 0.14); color: var(--red); }

  /* iOS Inputs */
  .input, .textarea {
    width: 100%;
    background: var(--surface-2);
    border: 0.5px solid var(--separator);
    border-radius: 12px;
    padding: 11px 14px;
    font-size: 14px;
    color: var(--text);
    outline: none;
  }
  .input:focus, .textarea:focus { border-color: var(--blue); }
  .textarea { min-height: 82px; resize: vertical; }

  /* Authentic iOS UISwitch */
  .switch {
    position: relative;
    display: inline-block;
    width: 50px;
    height: 30px;
    flex-shrink: 0;
  }
  .switch input { opacity: 0; width: 0; height: 0; }
  .slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background: rgba(120, 120, 128, 0.32);
    transition: .25s;
    border-radius: 30px;
  }
  .slider:before {
    position: absolute;
    content: "";
    height: 26px;
    width: 26px;
    left: 2px;
    bottom: 2px;
    background: #fff;
    transition: .25s;
    border-radius: 50%;
    box-shadow: 0 2px 5px rgba(0,0,0,0.2);
  }
  input:checked + .slider { background: var(--green); }
  input:checked + .slider:before { transform: translateX(20px); }

  /* Progress Bar */
  .prog-wrap { background: var(--seg-bg); border-radius: 999px; height: 8px; overflow: hidden; margin: 10px 0 6px; }
  .prog-bar { height: 100%; background: var(--blue); width: 0%; transition: width 0.35s ease; border-radius: 999px; }

  /* Frosted iOS Bottom Tab Bar */
  .tabbar {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    z-index: 50;
    background: var(--glass);
    backdrop-filter: saturate(180%) blur(24px);
    -webkit-backdrop-filter: saturate(180%) blur(24px);
    border-top: 0.5px solid var(--separator);
    display: flex;
    justify-content: space-around;
    padding: 8px 8px calc(8px + env(safe-area-inset-bottom));
  }
  .tab-btn {
    border: none;
    background: transparent;
    color: var(--text-3);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    padding: 2px 12px;
  }
  .tab-btn.active { color: var(--blue); }
  .tab-btn svg { width: 22px; height: 22px; stroke: currentColor; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }

  /* iOS Modal Sheet */
  .sheet-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.42);
    z-index: 80;
    display: none;
    align-items: flex-end;
    justify-content: center;
  }
  .sheet-backdrop.open { display: flex; }
  .sheet {
    width: 100%;
    max-width: 540px;
    background: var(--surface);
    border-radius: 22px 22px 0 0;
    padding: 12px 18px 26px;
    max-height: 85vh;
    overflow-y: auto;
    animation: slideUp 0.22s ease;
  }
  @keyframes slideUp { from { transform: translateY(40px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  .sheet-handle { width: 38px; height: 5px; border-radius: 99px; background: var(--separator); margin: 0 auto 12px; }

  /* Toast */
  .toast {
    position: fixed;
    top: 66px;
    left: 50%;
    transform: translateX(-50%);
    background: rgba(28, 28, 30, 0.92);
    color: #fff;
    padding: 10px 18px;
    border-radius: 999px;
    font-size: 13px;
    font-weight: 600;
    z-index: 99;
    display: none;
    box-shadow: 0 6px 20px rgba(0,0,0,0.22);
    white-space: nowrap;
  }
  .hidden { display: none !important; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; direction: ltr; unicode-bidi: embed; }
</style>
</head>
<body>

<div class="topbar">
  <div class="topbar-title">
    <span>CFHub</span>
    <span class="pill-ver">V23</span>
  </div>
  <div class="topbar-actions">
    <button class="icon-pill" id="btnLang" onclick="toggleLang()">EN</button>
    <button class="icon-pill" id="btnTheme" onclick="toggleTheme()">🌙</button>
  </div>
</div>

<div id="toast" class="toast"></div>

<!-- LOCK SCREEN (If Telegram / YouTube Force-Join Lock Active) -->
<div id="lockView" class="container hidden">
  <div class="card card-pad" style="text-align:center; margin-top: 28px;">
    <div style="font-size:44px; margin-bottom:10px;">🔒</div>
    <div id="lockTitle" style="font-size:18px; font-weight:700; margin-bottom:8px;">عضویت الزامی</div>
    <div id="lockText" style="font-size:14px; color:var(--text-2); line-height:1.6; margin-bottom:18px;"></div>
    <a id="lockUrlBtn" href="#" target="_blank" class="btn btn-primary" style="margin-bottom:10px;">ورود به کانال</a>
    <button class="btn btn-green" onclick="verifyLock()">تایید و بررسی عضویت</button>
  </div>
</div>

<!-- MAIN APP CONTAINER -->
<div id="appView" class="container">

  <!-- ==================== TAB 1: PANEL / CONFIGS ==================== -->
  <div id="tab-panel">
    <div class="stats-grid">
      <div class="stat-tile"><div id="stMci" class="stat-val">-</div><div class="stat-lbl">همراه اول</div></div>
      <div class="stat-tile"><div id="stMtn" class="stat-val">-</div><div class="stat-lbl">ایرانسل</div></div>
      <div class="stat-tile"><div id="stMkh" class="stat-val">-</div><div class="stat-lbl">مخابرات</div></div>
      <div class="stat-tile"><div id="stWarp" class="stat-val">-</div><div class="stat-lbl">WARP</div></div>
    </div>

    <!-- No Panel State: Direct Deploy inside Mini App -->
    <div id="noPanelCard" class="card card-pad hidden">
      <div style="font-size:17px; font-weight:700; margin-bottom:6px;">ساخت پنل رایگان اختصاصی</div>
      <div style="font-size:13px; color:var(--text-2); line-height:1.6; margin-bottom:14px;">
        توکن کلودفلر خود را بگیرید و اینجا وارد کنید تا پنل VLESS و Trojan شما روی Cloudflare Pages با فناوری ECH ساخته شود.
      </div>
      <div class="btn-grid" style="margin-bottom:12px;">
        <a id="cfTokenLink" href="#" target="_blank" class="btn btn-green btn-sm">🔑 دریافت مستقیم توکن</a>
        <a href="https://dash.cloudflare.com/sign-up" target="_blank" class="btn btn-soft btn-sm">🌐 ثبت‌نام کلودفلر</a>
      </div>
      <input id="inpCfToken" class="input mono" placeholder="Cloudflare API Token را اینجا پیست کنید..." style="margin-bottom:10px;"/>
      <button id="btnDeployPanel" class="btn btn-primary" onclick="deployPanel()">🚀 ساخت و تست پنل (Pages)</button>
    </div>

    <!-- Active Panel State -->
    <div id="activePanelBox" class="hidden">
      <div class="card">
        <div class="row">
          <div class="row-main">
            <div class="row-title">پنل فعال شما</div>
            <div id="pnlHost" class="row-sub mono">-</div>
          </div>
          <span id="pnlVerBadge" class="badge b-green">V23</span>
        </div>
        <div class="row">
          <div class="row-main">
            <div class="row-title">لینک اشتراک خودکار (Auto-Sub)</div>
            <div class="row-sub">آپدیت خودکار ECH و سریع‌ترین IPها</div>
          </div>
          <button class="btn btn-primary btn-sm" onclick="copySubLink()">کپی لینک</button>
        </div>
      </div>

      <div class="section-label">انتخاب اپراتور</div>
      <div class="segmented">
        <button class="seg-btn active" data-op="mci" onclick="selectOperator('mci', this)">همراه اول</button>
        <button class="seg-btn" data-op="mtn" onclick="selectOperator('mtn', this)">ایرانسل</button>
        <button class="seg-btn" data-op="mkh" onclick="selectOperator('mkh', this)">مخابرات</button>
      </div>

      <div id="configsCard" class="card">
        <div class="card-pad" style="text-align:center; color:var(--text-2); font-size:14px;">در حال بارگذاری کانفیگ‌ها...</div>
      </div>

      <div class="btn-grid" style="margin-bottom:12px;">
        <button class="btn btn-primary btn-sm" onclick="copyAllConfigs()">📋 کپی همه ۶ کانفیگ</button>
        <button class="btn btn-soft btn-sm" onclick="rotateIps()">🔄 تعویض با ۳ IP جدید</button>
      </div>

      <div class="section-label">ابزارهای پنل</div>
      <div class="card">
        <div class="row">
          <div class="row-main"><div class="row-title">تست سرتاسری پنل</div><div class="row-sub">بررسی Health، VLESS، Trojan و ProxyIP</div></div>
          <button id="btnE2E" class="btn btn-soft btn-sm" onclick="runE2ETest()">اجرا</button>
        </div>
        <div class="row">
          <div class="row-main"><div class="row-title">آپدیت هسته پنل</div><div id="updSubTxt" class="row-sub">آخرین نسخه V23 روی Pages</div></div>
          <button id="btnRedeploy" class="btn btn-green btn-sm" onclick="redeployPanel()">آپدیت</button>
        </div>
        <div class="row">
          <div class="row-main"><div class="row-title">تغییر ProxyIP</div><div id="pnlProxyIp" class="row-sub mono">-</div></div>
          <button class="btn btn-soft btn-sm" onclick="openProxyModal()">ویرایش</button>
        </div>
        <div class="row">
          <div class="row-main"><div class="row-title">کانفیگ Auto-Fragment (JSON)</div><div class="row-sub">ویژه شرایط فیلترینگ شدید</div></div>
          <button class="btn btn-soft btn-sm" onclick="copyFragSub()">کپی ساب</button>
        </div>
        <div class="row">
          <div class="row-main"><div class="row-title" style="color:var(--red);">حذف پنل فعلی</div><div class="row-sub">قطع اتصال توکن و حذف تنظیمات</div></div>
          <button class="btn btn-red btn-sm" onclick="disconnectPanel()">حذف</button>
        </div>
      </div>
    </div>
  </div>

  <!-- ==================== TAB 2: WARP / WIREGUARD ==================== -->
  <div id="tab-warp" class="hidden">
    <div class="section-label">رله‌های فعال WARP</div>
    <div class="card">
      <div class="row">
        <div class="row-main"><div class="row-title">بهترین اندپوینت IPv4</div><div id="warpEp4" class="row-sub mono">-</div></div>
        <span id="warpPing" class="badge b-green">-</span>
      </div>
      <div class="row">
        <div class="row-main"><div class="row-title">بهترین اندپوینت IPv6</div><div id="warpEp6" class="row-sub mono">-</div></div>
        <button class="btn btn-soft btn-sm" onclick="scanWarpLive()">🔍 اسکن</button>
      </div>
    </div>

    <div class="section-label">تنظیمات ساخت کلید اختصاصی</div>
    <div class="card card-pad">
      <div style="font-size:12px; color:var(--text-2); margin-bottom:6px;">نسخه IP</div>
      <div class="segmented" id="warpModeSeg">
        <button class="seg-btn active" onclick="setWarpMode('ipv6', this)">IPv6 ضد اختلال</button>
        <button class="seg-btn" onclick="setWarpMode('dual', this)">Dual-Stack</button>
        <button class="seg-btn" onclick="setWarpMode('ipv4', this)">IPv4</button>
      </div>
      <div style="font-size:12px; color:var(--text-2); margin-bottom:6px;">سیستم‌عامل</div>
      <div class="segmented" id="warpPlatSeg">
        <button class="seg-btn active" onclick="setWarpPlat('ios', this)">آیفون iOS</button>
        <button class="seg-btn" onclick="setWarpPlat('android', this)">اندروید</button>
        <button class="seg-btn" onclick="setWarpPlat('windows', this)">ویندوز</button>
      </div>
      <button id="btnGenWarp" class="btn btn-primary" onclick="generateWarp()">🛡️ ساخت کانفیگ اختصاصی WARP</button>
    </div>

    <div id="warpResultCard" class="card hidden"></div>
  </div>

  <!-- ==================== TAB 3: TOOLS (CLEAN IPS, APPS, GUIDE, SUPPORT) ==================== -->
  <div id="tab-tools" class="hidden">
    <div class="section-label">آی‌پی‌های تمیز بر اساس اپراتور</div>
    <div class="segmented">
      <button class="seg-btn active" onclick="loadCleanIps('mci', this)">همراه اول</button>
      <button class="seg-btn" onclick="loadCleanIps('mtn', this)">ایرانسل</button>
      <button class="seg-btn" onclick="loadCleanIps('mkh', this)">مخابرات</button>
    </div>
    <div id="cleanIpsCard" class="card"></div>

    <div class="section-label">اپلیکیشن‌های پیشنهادی</div>
    <div class="card">
      <div class="row"><div class="row-main"><div class="row-title">Hiddify</div><div class="row-sub">اندروید، آیفون و ویندوز (پشتیبانی کامل ECH و WARP)</div></div><a href="https://github.com/hiddify/hiddify-app/releases/latest" target="_blank" class="btn btn-soft btn-sm">دانلود</a></div>
      <div class="row"><div class="row-main"><div class="row-title">v2rayNG</div><div class="row-sub">اندروید (نسخه 1.9.30+ برای ECH)</div></div><a href="https://github.com/2dust/v2rayNG/releases/latest" target="_blank" class="btn btn-soft btn-sm">دانلود</a></div>
      <div class="row"><div class="row-main"><div class="row-title">Streisand</div><div class="row-sub">آیفون iOS (پشتیبانی کامل ECH و WireGuard)</div></div><a href="https://apps.apple.com/app/streisand/id6450534064" target="_blank" class="btn btn-soft btn-sm">دانلود</a></div>
      <div class="row"><div class="row-main"><div class="row-title">AmneziaWG</div><div class="row-sub">ضد فیلتر تخصصی WARP و WireGuard</div></div><a href="https://github.com/amnezia-vpn/amneziawg-android/releases/latest" target="_blank" class="btn btn-soft btn-sm">دانلود</a></div>
      <div class="row"><div class="row-main"><div class="row-title">v2rayN</div><div class="row-sub">ویندوز (نسخه 7+ با هسته Xray 25)</div></div><a href="https://github.com/2dust/v2rayN/releases/latest" target="_blank" class="btn btn-soft btn-sm">دانلود</a></div>
    </div>

    <div class="section-label">راهنمای اتصال سریع</div>
    <div class="card card-pad" style="font-size:13px; color:var(--text-2); line-height:1.7;">
      <b>۱. بهترین سرعت و بدون قطعی:</b> لینک <b>Auto-Sub</b> را در Hiddify یا v2rayNG اضافه کنید تا همیشه جدیدترین کلید ECH و سریع‌ترین IPها را دریافت کنید.<br/>
      <b>۲. نکته مهم v2rayNG:</b> در تنظیمات برنامه، گزینه <b>Enable Mux</b> را خاموش بگذارید.<br/>
      <b>۳. اگر ECH روی اینترنت شما جواب نداد:</b> از کانفیگ‌های <b>#3 (UniversalTLS)</b> یا لینک <b>Auto-Fragment</b> استفاده کنید.
    </div>

    <div class="section-label">پشتیبانی و ارسال تیکت</div>
    <div class="card card-pad">
      <a id="directSupBtn" href="#" target="_blank" class="btn btn-soft" style="margin-bottom:10px;">💬 چت مستقیم با پشتیبانی</a>
      <textarea id="inpTicket" class="textarea" placeholder="پیام یا مشکل خود را بنویسید..." style="margin-bottom:10px;"></textarea>
      <button class="btn btn-primary" onclick="sendSupportTicket()">✉️ ارسال تیکت به مدیریت</button>
    </div>
  </div>

  <!-- ==================== TAB 4: ADMIN PANEL (ONLY FOR ADMINS!) ==================== -->
  <div id="tab-admin" class="hidden">
    <div class="section-label">وضعیت زنده سرور</div>
    <div class="stats-grid">
      <div class="stat-tile"><div id="admCpu" class="stat-val">-</div><div class="stat-lbl">CPU</div></div>
      <div class="stat-tile"><div id="admRam" class="stat-val">-</div><div class="stat-lbl">RAM</div></div>
      <div class="stat-tile"><div id="admUsersCnt" class="stat-val">-</div><div class="stat-lbl">کاربران</div></div>
      <div class="stat-tile"><div id="admPanelsCnt" class="stat-val">-</div><div class="stat-lbl">پنل فعال</div></div>
    </div>

    <div class="card card-pad">
      <div style="display:flex; justify-content:space-between; align-items:center;">
        <span style="font-size:14px; font-weight:700;">موتور اسکنر هوشمند</span>
        <span id="admScanState" class="badge b-green">آماده</span>
      </div>
      <div class="prog-wrap"><div id="admProgBar" class="prog-bar"></div></div>
      <div id="admScanInfo" style="font-size:12px; color:var(--text-2); margin-bottom:10px;">آماده اجرا</div>
      <div class="btn-grid">
        <button class="btn btn-green btn-sm" onclick="adminStartScan('full')">▶️ اسکن کامل + WARP</button>
        <button class="btn btn-primary btn-sm" onclick="adminStartScan('warp')">🛡️ اسکن زنده WARP</button>
      </div>
    </div>

    <div class="section-label">افزودن IP تمیز دستی</div>
    <div class="card card-pad">
      <div class="segmented" id="admOpSeg">
        <button class="seg-btn active" onclick="setAdmOp('mci', this)">همراه اول</button>
        <button class="seg-btn" onclick="setAdmOp('mtn', this)">ایرانسل</button>
        <button class="seg-btn" onclick="setAdmOp('mkh', this)">مخابرات</button>
      </div>
      <textarea id="inpAdmIps" class="textarea mono" placeholder="آی‌پی‌ها را با فاصله یا خط جدید وارد کنید (مثلاً 104.16.132.229)" style="margin-bottom:10px;"></textarea>
      <button class="btn btn-primary btn-sm" style="width:100%;" onclick="adminAddIps()">➕ ثبت آی‌پی‌ها و اسکن</button>
    </div>

    <div class="section-label">مدیریت کاربران</div>
    <div class="card card-pad">
      <div style="display:flex; gap:8px; margin-bottom:10px;">
        <input id="inpUserSearch" class="input" placeholder="جستجو با آیدی یا @username..."/>
        <button class="btn btn-primary btn-sm" onclick="loadAdminUsers(0)">جستجو</button>
      </div>
      <div id="admUsersList"></div>
    </div>

    <div class="section-label">قفل کانال تلگرام (واقعی) و یوتیوب (فیک)</div>
    <div class="card">
      <div class="row">
        <div class="row-main"><div class="row-title">قفل عضویت تلگرام</div><div class="row-sub">ربات باید ادمین کانال باشد</div></div>
        <label class="switch"><input type="checkbox" id="swTgLock" onchange="saveAdminSettings()"/><span class="slider"></span></label>
      </div>
      <div class="card-pad" style="border-bottom:0.5px solid var(--separator);">
        <input id="inpTgChan" class="input mono" placeholder="@MyChannel یا -100..." style="margin-bottom:8px;"/>
        <input id="inpTgText" class="input" placeholder="متن قفل تلگرام"/>
      </div>
      <div class="row">
        <div class="row-main"><div class="row-title">قفل کانال یوتیوب (فیک)</div><div class="row-sub">با کلیک کاربر باز می‌شود</div></div>
        <label class="switch"><input type="checkbox" id="swYtLock" onchange="saveAdminSettings()"/><span class="slider"></span></label>
      </div>
      <div class="card-pad">
        <input id="inpYtUrl" class="input mono" placeholder="https://youtube.com/@CyberMux" style="margin-bottom:8px;"/>
        <input id="inpYtText" class="input" placeholder="متن قفل یوتیوب" style="margin-bottom:10px;"/>
        <button class="btn btn-primary btn-sm" style="width:100%;" onclick="saveAdminSettings()">💾 ذخیره تنظیمات قفل‌ها</button>
      </div>
    </div>

    <div class="section-label">تنظیمات سیستم و پشتیبانی</div>
    <div class="card">
      <div class="row">
        <div class="row-main"><div class="row-title">اسکن خودکار دوره‌ای</div><div class="row-sub">به‌روزرسانی خودکار لیست IPها</div></div>
        <label class="switch"><input type="checkbox" id="swAutoScan" onchange="saveAdminSettings()"/><span class="slider"></span></label>
      </div>
      <div class="row">
        <div class="row-main"><div class="row-title">حالت تعمیرات</div><div class="row-sub">محدود کردن دسترسی کاربران عادی</div></div>
        <label class="switch"><input type="checkbox" id="swMaint" onchange="saveAdminSettings()"/><span class="slider"></span></label>
      </div>
      <div class="card-pad">
        <div style="font-size:12px; color:var(--text-2); margin-bottom:4px;">یوزرنیم پشتیبانی</div>
        <input id="inpSupUser" class="input mono" placeholder="username (بدون @)" style="margin-bottom:8px;"/>
        <div style="font-size:12px; color:var(--text-2); margin-bottom:4px;">لینک HTTPS مینی‌اپ</div>
        <input id="inpWebappUrl" class="input mono" placeholder="https://app.prostoreshop.site" style="margin-bottom:8px;"/>
        <div style="font-size:12px; color:var(--text-2); margin-bottom:4px;">ProxyIP پیش‌فرض</div>
        <input id="inpDefProxy" class="input mono" placeholder="proxyip.fxxk.dedyn.io" style="margin-bottom:10px;"/>
        <button class="btn btn-primary btn-sm" style="width:100%;" onclick="saveAdminSettings()">💾 ذخیره تنظیمات سیستم</button>
      </div>
    </div>

    <div class="section-label">ارسال همگانی (Broadcast)</div>
    <div class="card card-pad">
      <textarea id="inpBroadcast" class="textarea" placeholder="متن اطلاعیه همگانی برای همه کاربران..." style="margin-bottom:10px;"></textarea>
      <button class="btn btn-green" onclick="adminBroadcast()">📢 ارسال به همه کاربران</button>
    </div>

    <div class="section-label">تیکت‌های اخیر پشتیبانی</div>
    <div id="admTicketsCard" class="card"></div>
  </div>
</div>

<!-- FROSTED iOS BOTTOM TAB BAR -->
<nav class="tabbar" id="bottomTabBar">
  <button class="tab-btn active" data-tab="panel" onclick="switchTab('panel', this)">
    <svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/></svg>
    <span>پنل من</span>
  </button>
  <button class="tab-btn" data-tab="warp" onclick="switchTab('warp', this)">
    <svg viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    <span>WARP</span>
  </button>
  <button class="tab-btn" data-tab="tools" onclick="switchTab('tools', this)">
    <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
    <span>ابزارها</span>
  </button>
  <button class="tab-btn hidden" id="navAdminBtn" data-tab="admin" onclick="switchTab('admin', this)">
    <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.6.85 1 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
    <span>مدیریت</span>
  </button>
</nav>

<!-- MODAL SHEET -->
<div id="modalBackdrop" class="sheet-backdrop" onclick="if(event.target===this) closeSheet()">
  <div class="sheet">
    <div class="sheet-handle"></div>
    <div id="sheetBody"></div>
  </div>
</div>

<script>
const tg = (window.Telegram && window.Telegram.WebApp) ? window.Telegram.WebApp : null;
if (tg) {
  tg.ready();
  tg.expand();
  if (tg.colorScheme === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
    document.getElementById('btnTheme').textContent = '☀️';
  }
}

let state = {
  op: 'mci',
  warpMode: 'ipv6',
  warpPlat: 'ios',
  admOp: 'mci',
  configs: {},
  subUrl: '',
  fragSubUrl: '',
  isAdmin: false,
  hasPanel: false,
  lang: 'fa',
  scanTimer: null,
};

function haptic(type='light') {
  try { if (tg && tg.HapticFeedback) tg.HapticFeedback.impactOccurred(type); } catch(_) {}
}

function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.style.display = 'block';
  clearTimeout(window._tT);
  window._tT = setTimeout(() => { el.style.display = 'none'; }, 2200);
}

function toggleTheme() {
  haptic();
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  if (isDark) {
    document.documentElement.removeAttribute('data-theme');
    document.getElementById('btnTheme').textContent = '🌙';
  } else {
    document.documentElement.setAttribute('data-theme', 'dark');
    document.getElementById('btnTheme').textContent = '☀️';
  }
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

function copyText(txt, okMsg='✅ کپی شد!') {
  haptic();
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(txt).then(() => toast(okMsg)).catch(() => fallbackCopy(txt, okMsg));
  } else {
    fallbackCopy(txt, okMsg);
  }
}

function fallbackCopy(txt, okMsg) {
  const ta = document.createElement('textarea');
  ta.value = txt;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); toast(okMsg); } catch(_) { toast('❌ خطا در کپی'); }
  document.body.removeChild(ta);
}

function openSheet(htmlContent) {
  document.getElementById('sheetBody').innerHTML = htmlContent;
  document.getElementById('modalBackdrop').classList.add('open');
}
function closeSheet() {
  document.getElementById('modalBackdrop').classList.remove('open');
}

function switchTab(name, btnEl) {
  haptic();
  ['panel', 'warp', 'tools', 'admin'].forEach(t => {
    document.getElementById('tab-' + t).classList.toggle('hidden', t !== name);
  });
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  if (btnEl) btnEl.classList.add('active');
  if (name === 'tools') loadCleanIps('mci');
  if (name === 'admin') loadAdminDashboard();
}

async function toggleLang() {
  haptic();
  try {
    const r = await api('/api/v23/lang', 'POST', {});
    state.lang = r.lang;
    document.getElementById('btnLang').textContent = r.lang === 'fa' ? 'EN' : 'FA';
    toast(r.lang === 'fa' ? 'زبان فارسی فعال شد' : 'English active');
  } catch(_) {}
}

async function bootstrap() {
  try {
    const d = await api('/api/v23/bootstrap');
    if (d.locked) {
      document.getElementById('appView').classList.add('hidden');
      document.getElementById('bottomTabBar').classList.add('hidden');
      document.getElementById('lockView').classList.remove('hidden');
      document.getElementById('lockTitle').textContent = d.lock_type === 'tg' ? 'قفل کانال تلگرام' : 'حمایت از کانال یوتیوب';
      document.getElementById('lockText').textContent = d.lock_text || '';
      const uBtn = document.getElementById('lockUrlBtn');
      if (d.lock_url) { uBtn.href = d.lock_url; uBtn.classList.remove('hidden'); }
      else { uBtn.classList.add('hidden'); }
      return;
    }

    document.getElementById('lockView').classList.add('hidden');
    document.getElementById('appView').classList.remove('hidden');
    document.getElementById('bottomTabBar').classList.remove('hidden');

    state.isAdmin = !!d.is_admin;
    state.hasPanel = !!d.has_panel;
    state.lang = d.lang || 'fa';
    document.getElementById('btnLang').textContent = state.lang === 'fa' ? 'EN' : 'FA';
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
    if (d.support_url) { supBtn.href = d.support_url; supBtn.classList.remove('hidden'); }
    else { supBtn.classList.add('hidden'); }

    if (d.has_panel && d.panel) {
      document.getElementById('noPanelCard').classList.add('hidden');
      document.getElementById('activePanelBox').classList.remove('hidden');
      document.getElementById('pnlHost').textContent = d.panel.host;
      document.getElementById('pnlProxyIp').textContent = d.panel.proxy_ip || '-';
      const badge = document.getElementById('pnlVerBadge');
      const rBtn = document.getElementById('btnRedeploy');
      if (d.panel.is_updated) {
        badge.className = 'badge b-green';
        badge.textContent = '✅ آپدیت ' + d.panel.version.toUpperCase();
        rBtn.className = 'btn btn-green btn-sm';
        rBtn.textContent = 'آپدیت هستید';
      } else {
        badge.className = 'badge b-red';
        badge.textContent = 'نیاز به آپدیت';
        rBtn.className = 'btn btn-red btn-sm';
        rBtn.textContent = 'آپدیت کنید';
      }
      state.op = d.panel.operator || 'mci';
      document.querySelectorAll('#tab-panel .seg-btn').forEach(b => b.classList.toggle('active', b.dataset.op === state.op));
      await loadConfigs(state.op, false);
    } else {
      document.getElementById('noPanelCard').classList.remove('hidden');
      document.getElementById('activePanelBox').classList.add('hidden');
    }
  } catch (e) {
    toast('⚠️ ' + e.message);
  }
}

async function verifyLock() {
  haptic();
  try {
    const r = await api('/api/v23/lock/verify', 'POST', {});
    if (r.unlocked) {
      toast('✅ عضویت تایید شد!');
      bootstrap();
    } else {
      toast('⚠️ هنوز عضویت شما تایید نشد');
    }
  } catch (e) { toast('❌ ' + e.message); }
}

async function selectOperator(op, el) {
  haptic();
  state.op = op;
  document.querySelectorAll('#tab-panel .seg-btn').forEach(b => b.classList.remove('active'));
  if (el) el.classList.add('active');
  await loadConfigs(op, false);
}

async function rotateIps() {
  haptic('medium');
  await loadConfigs(state.op, true);
  toast('🔄 ۳ آی‌پی جدید جایگزین شد');
}

async function loadConfigs(op, rotate=false) {
  const box = document.getElementById('configsCard');
  box.innerHTML = '<div class="card-pad" style="text-align:center;color:var(--text-2);font-size:13px;">⏳ در حال انتخاب بهترین آی‌پی‌ها و کلید ECH...</div>';
  try {
    const d = await api(`/api/v23/panel/configs?op=${op}&rotate=${rotate ? 1 : 0}`);
    state.configs = d.configs || {};
    state.subUrl = d.sub_url || '';
    state.fragSubUrl = d.frag_sub_url || '';
    const list = [
      { k: 'vless_1', t: 'VLESS #1', s: 'Auto-ECH • بدون انقضا • پورت 443', b: 'b-blue' },
      { k: 'vless_2', t: 'VLESS #2', s: 'Live-ECH • ضد محدودیت پهنای باند', b: 'b-green' },
      { k: 'vless_3', t: 'VLESS #3', s: 'Universal TLS • همیشه وصل', b: 'b-orange' },
      { k: 'trojan_1', t: 'Trojan #1', s: 'Auto-ECH • بدون انقضا • پورت 443', b: 'b-blue' },
      { k: 'trojan_2', t: 'Trojan #2', s: 'Live-ECH • ضد محدودیت پهنای باند', b: 'b-green' },
      { k: 'trojan_3', t: 'Trojan #3', s: 'Universal TLS • همیشه وصل', b: 'b-orange' },
    ];
    box.innerHTML = '';
    list.forEach(it => {
      const uri = state.configs[it.k];
      if (!uri) return;
      const r = document.createElement('div');
      r.className = 'row';
      r.innerHTML = `<div class="row-main"><div class="row-title">${it.t} <span class="badge ${it.b}" style="margin-right:4px;">ECH/TLS</span></div><div class="row-sub">${it.s}</div></div>`;
      const btn = document.createElement('button');
      btn.className = 'btn btn-soft btn-sm';
      btn.textContent = 'کپی';
      btn.onclick = () => copyText(uri, `✅ ${it.t} کپی شد`);
      r.appendChild(btn);
      box.appendChild(r);
    });
  } catch (e) {
    box.innerHTML = `<div class="card-pad" style="text-align:center;color:var(--red);font-size:13px;">❌ ${e.message}</div>`;
  }
}

function copyAllConfigs() {
  const all = ['vless_1','vless_2','vless_3','trojan_1','trojan_2','trojan_3'].map(k => state.configs[k]).filter(Boolean).join('\n');
  if (!all) return toast('کانفیگی موجود نیست');
  copyText(all, '✅ همه ۶ کانفیگ کپی شدند!');
}
function copySubLink() {
  if (!state.subUrl) return toast('ابتدا پنل بسازید');
  copyText(state.subUrl, '✅ لینک اشتراک Auto-Sub کپی شد!');
}
function copyFragSub() {
  if (!state.fragSubUrl) return toast('ابتدا پنل بسازید');
  copyText(state.fragSubUrl, '✅ لینک Auto-Fragment کپی شد!');
}

async function deployPanel() {
  const token = document.getElementById('inpCfToken').value.trim();
  if (token.length < 20) return toast('⚠️ توکن کلودفلر معتبر نیست');
  const btn = document.getElementById('btnDeployPanel');
  btn.disabled = true; btn.textContent = '⏳ در حال دیپلوی روی Pages...';
  try {
    await api('/api/v23/panel/deploy', 'POST', { api_token: token });
    document.getElementById('inpCfToken').value = '';
    toast('🎉 پنل V23 ساخته شد!');
    await bootstrap();
  } catch (e) {
    toast('❌ ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = '🚀 ساخت و تست پنل (Pages)';
  }
}

async function redeployPanel() {
  const btn = document.getElementById('btnRedeploy');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    await api('/api/v23/panel/redeploy', 'POST', {});
    toast('✅ پنل به V23 آپدیت شد!');
    await bootstrap();
  } catch (e) {
    toast('❌ ' + e.message);
  } finally {
    btn.disabled = false;
  }
}

async function runE2ETest() {
  const btn = document.getElementById('btnE2E');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    const d = await api('/api/v23/panel/test', 'POST', {});
    openSheet(`
      <div style="font-size:17px;font-weight:700;margin-bottom:12px;">🩺 نتیجه تست سرتاسری</div>
      <div class="card">
        <div class="row"><div class="row-title">روتینگ IP تمیز</div><span class="badge ${d.health.ok?'b-green':'b-red'}">${d.health.ok ? d.health.ms+'ms' : 'خطا'}</span></div>
        <div class="row"><div class="row-title">تونل واقعی VLESS</div><span class="badge ${d.vless.ok?'b-green':'b-red'}">${d.vless.ok ? d.vless.ms+'ms' : 'خطا'}</span></div>
        <div class="row"><div class="row-title">تونل واقعی Trojan</div><span class="badge ${d.trojan.ok?'b-green':'b-red'}">${d.trojan.ok ? d.trojan.ms+'ms' : 'خطا'}</span></div>
        <div class="row"><div class="row-title">فالبک ProxyIP</div><span class="badge ${d.proxy.ok?'b-green':'b-orange'}">${d.proxy.ok ? d.proxy.ms+'ms' : 'نیاز به تعویض'}</span></div>
      </div>
      <button class="btn btn-primary" onclick="closeSheet()">بستن</button>
    `);
  } catch (e) {
    toast('❌ ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'اجرا';
  }
}

function openProxyModal() {
  const cur = document.getElementById('pnlProxyIp').textContent;
  openSheet(`
    <div style="font-size:17px;font-weight:700;margin-bottom:8px;">🔁 تغییر ProxyIP</div>
    <div style="font-size:13px;color:var(--text-2);margin-bottom:12px;">پیشنهاد: proxyip.fxxk.dedyn.io یا bpb.yousef.isegaro.com</div>
    <input id="inpNewProxy" class="input mono" value="${cur === '-' ? '' : cur}" style="margin-bottom:12px;"/>
    <button class="btn btn-primary" onclick="saveProxyIp()">ذخیره ProxyIP</button>
  `);
}

async function saveProxyIp() {
  const pip = document.getElementById('inpNewProxy').value.trim();
  if (!pip) return;
  try {
    await api('/api/v23/panel/proxyip', 'POST', { proxy_ip: pip });
    closeSheet();
    toast('✅ ذخیره شد — دکمه آپدیت را بزنید');
    bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
}

async function disconnectPanel() {
  openSheet(`
    <div style="font-size:17px;font-weight:700;margin-bottom:8px;color:var(--red);">🗑️ حذف پنل</div>
    <div style="font-size:14px;color:var(--text-2);margin-bottom:16px;">آیا مطمئن هستید می‌خواهید پنل و توکن ذخیره‌شده خود را حذف کنید؟</div>
    <div class="btn-grid">
      <button class="btn btn-soft" onclick="closeSheet()">انصراف</button>
      <button class="btn btn-red" onclick="confirmDisconnect()">بله، حذف کن</button>
    </div>
  `);
}
async function confirmDisconnect() {
  try {
    await api('/api/v23/panel/disconnect', 'POST', {});
    closeSheet();
    toast('🗑️ پنل حذف شد');
    bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
}

// ==================== WARP ====================
function setWarpMode(m, el) {
  haptic(); state.warpMode = m;
  el.parentElement.querySelectorAll('.seg-btn').forEach(b => b.classList.remove('active'));
  el.classList.add('active');
}
function setWarpPlat(p, el) {
  haptic(); state.warpPlat = p;
  el.parentElement.querySelectorAll('.seg-btn').forEach(b => b.classList.remove('active'));
  el.classList.add('active');
}

async function generateWarp() {
  const btn = document.getElementById('btnGenWarp');
  btn.disabled = true; btn.textContent = '⏳ در حال ثبت کلید واقعی...';
  try {
    const b = await api('/api/v23/warp/generate', 'POST', { ip_mode: state.warpMode, platform: state.warpPlat });
    const card = document.getElementById('warpResultCard');
    card.classList.remove('hidden');
    card.innerHTML = `
      <div class="row"><div class="row-main"><div class="row-title">WARP Anti-DPI (Hiddify / Karing)</div><div class="row-sub mono">${b.endpoint}</div></div><button class="btn btn-primary btn-sm" id="wCopy1">کپی</button></div>
      <div class="row"><div class="row-main"><div class="row-title">WoW دولایه (Hiddify / Karing)</div><div class="row-sub">ضد فیلتر قوی تهران و ایران</div></div><button class="btn btn-soft btn-sm" id="wCopy2">کپی</button></div>
      <div class="row"><div class="row-main"><div class="row-title">WireGuard ضد DPI (v2rayNG / MahsaNG)</div><div class="row-sub">دارای نویز QUIC</div></div><button class="btn btn-soft btn-sm" id="wCopy3">کپی</button></div>
      <div class="row"><div class="row-main"><div class="row-title">فایل AmneziaWG (.conf)</div><div class="row-sub">${b.amnezia_filename}</div></div><button class="btn btn-green btn-sm" id="wDlConf">دانلود</button></div>
    `;
    document.getElementById('wCopy1').onclick = () => copyText(b.warp_auto_uri, '✅ لینک WARP کپی شد');
    document.getElementById('wCopy2').onclick = () => copyText(b.wow_uri, '✅ لینک WoW کپی شد');
    document.getElementById('wCopy3').onclick = () => copyText(b.wireguard_uri, '✅ لینک WireGuard کپی شد');
    document.getElementById('wDlConf').onclick = () => {
      const blob = new Blob([b.amnezia_conf], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = b.amnezia_filename; a.click();
      URL.revokeObjectURL(url);
      toast('⬇️ فایل AmneziaWG دانلود شد');
    };
    toast('✅ کلید اختصاصی WARP ساخته شد');
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; btn.textContent = '🛡️ ساخت کانفیگ اختصاصی WARP'; }
}

async function scanWarpLive() {
  haptic();
  try {
    await api('/api/v23/warp/scan', 'POST', {});
    toast('🔍 اسکن رله‌های WARP شروع شد...');
    setTimeout(bootstrap, 6000);
  } catch (e) { toast('❌ ' + e.message); }
}

// ==================== CLEAN IPS & SUPPORT ====================
async function loadCleanIps(op, el) {
  if (el) {
    el.parentElement.querySelectorAll('.seg-btn').forEach(b => b.classList.remove('active'));
    el.classList.add('active');
  }
  const box = document.getElementById('cleanIpsCard');
  box.innerHTML = '<div class="card-pad" style="text-align:center;color:var(--text-2);font-size:13px;">⏳ در حال بارگذاری...</div>';
  try {
    const d = await api(`/api/v23/ips?op=${op}`);
    box.innerHTML = '';
    if (!d.ips.length) { box.innerHTML = '<div class="card-pad" style="text-align:center;color:var(--text-2);">لیست خالی است</div>'; return; }
    d.ips.forEach((x, i) => {
      const r = document.createElement('div');
      r.className = 'row';
      const spd = x.speed_mbps ? ` • ${Math.round(x.speed_mbps)}Mbps` : '';
      r.innerHTML = `<div class="row-main"><div class="row-title mono">${i+1}. ${x.ip}</div><div class="row-sub">${x.colo || 'CF'}${spd}</div></div><span class="badge b-green">${x.latency_ms ? Math.round(x.latency_ms)+'ms' : 'Auto'}</span>`;
      r.style.cursor = 'pointer';
      r.onclick = () => copyText(x.ip, `✅ IP ${x.ip} کپی شد`);
      box.appendChild(r);
    });
  } catch (e) { box.innerHTML = `<div class="card-pad" style="color:var(--red);">${e.message}</div>`; }
}

async function sendSupportTicket() {
  const txt = document.getElementById('inpTicket').value.trim();
  if (!txt) return toast('⚠️ متن پیام را بنویسید');
  try {
    const r = await api('/api/v23/support/ticket', 'POST', { text: txt });
    document.getElementById('inpTicket').value = '';
    toast(`✅ تیکت #${r.ticket_id} ارسال شد`);
  } catch (e) { toast('❌ ' + e.message); }
}

// ==================== ADMIN PANEL ====================
async function loadAdminDashboard() {
  if (!state.isAdmin) return;
  try {
    const d = await api('/api/v23/admin/overview');
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
    document.getElementById('inpDefProxy').value = s.default_proxy_ip || '';

    const tBox = document.getElementById('admTicketsCard');
    tBox.innerHTML = '';
    if (!d.tickets.length) {
      tBox.innerHTML = '<div class="card-pad" style="text-align:center;color:var(--text-2);font-size:13px;">تیکتی ثبت نشده است</div>';
    } else {
      d.tickets.slice(-8).reverse().forEach(t => {
        const r = document.createElement('div');
        r.className = 'row';
        r.innerHTML = `<div class="row-main"><div class="row-title">تیکت #${t.id} • <span class="mono">${t.user_id}</span></div><div class="row-sub">${escapeHtml(t.text)}</div></div><button class="btn btn-soft btn-sm" onclick="openDmModal(${t.user_id})">پاسخ</button>`;
        tBox.appendChild(r);
      });
    }
    loadAdminUsers(0);
  } catch (e) { toast('❌ ' + e.message); }
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
}

function updateScanUI(sc) {
  document.getElementById('admProgBar').style.width = (sc.progress_pct || 0) + '%';
  const st = document.getElementById('admScanState');
  if (sc.is_scanning) {
    st.className = 'badge b-orange';
    st.textContent = sc.progress_pct + '%';
    document.getElementById('admScanInfo').textContent = 'در حال اجرا: ' + sc.stage;
  } else {
    st.className = 'badge b-green';
    st.textContent = 'آماده';
    document.getElementById('admScanInfo').textContent = sc.last_scan_at ? ('آخرین اسکن: ' + sc.last_scan_at.slice(0,16).replace('T',' ')) : 'آماده اجرا';
  }
}

function pollScanStatus() {
  clearInterval(state.scanTimer);
  state.scanTimer = setInterval(async () => {
    try {
      const d = await api('/api/v23/admin/overview');
      updateScanUI(d.scanner);
      if (!d.scanner.is_scanning) {
        clearInterval(state.scanTimer);
        toast('✅ اسکن کامل شد!');
        bootstrap();
      }
    } catch(_) { clearInterval(state.scanTimer); }
  }, 2000);
}

async function adminStartScan(mode) {
  haptic('medium');
  try {
    await api('/api/v23/admin/scan', 'POST', { mode });
    toast('🚀 اسکن زنده آغاز شد');
    pollScanStatus();
  } catch (e) { toast('❌ ' + e.message); }
}

function setAdmOp(op, el) {
  haptic(); state.admOp = op;
  el.parentElement.querySelectorAll('.seg-btn').forEach(b => b.classList.remove('active'));
  el.classList.add('active');
}

async function adminAddIps() {
  const raw = document.getElementById('inpAdmIps').value.trim();
  if (!raw) return toast('⚠️ آی‌پی وارد کنید');
  try {
    const r = await api('/api/v23/admin/ips', 'POST', { operator: state.admOp, ips: raw });
    document.getElementById('inpAdmIps').value = '';
    toast(`✅ ${r.added} آی‌پی معتبر اضافه شد`);
  } catch (e) { toast('❌ ' + e.message); }
}

async function loadAdminUsers(page=0) {
  const q = document.getElementById('inpUserSearch').value.trim();
  const box = document.getElementById('admUsersList');
  try {
    const d = await api(`/api/v23/admin/users?page=${page}&q=${encodeURIComponent(q)}`);
    box.innerHTML = '';
    if (!d.users.length) { box.innerHTML = '<div style="text-align:center;color:var(--text-2);font-size:13px;padding:10px;">کاربری یافت نشد</div>'; return; }
    d.users.forEach(u => {
      const r = document.createElement('div');
      r.className = 'row';
      r.style.padding = '10px 4px';
      const badge = u.is_banned ? '<span class="badge b-red">مسدود</span>' : (u.has_panel ? '<span class="badge b-green">پنل</span>' : '<span class="badge b-blue">عادی</span>');
      r.innerHTML = `<div class="row-main"><div class="row-title">${escapeHtml(u.full_name || u.username || u.telegram_id)}</div><div class="row-sub mono">${u.telegram_id} ${u.username ? '@'+escapeHtml(u.username) : ''}</div></div>${badge}`;
      r.style.cursor = 'pointer';
      r.onclick = () => openUserModal(u);
      box.appendChild(r);
    });
  } catch (e) { box.innerHTML = `<div style="color:var(--red);font-size:13px;">${e.message}</div>`; }
}

function openUserModal(u) {
  openSheet(`
    <div style="font-size:17px;font-weight:700;margin-bottom:10px;">👤 پروفایل کاربر</div>
    <div class="card">
      <div class="row"><div class="row-title">شناسه</div><div class="mono">${u.telegram_id}</div></div>
      <div class="row"><div class="row-title">نام</div><div>${escapeHtml(u.full_name || '-')}</div></div>
      <div class="row"><div class="row-title">پنل</div><div class="mono" style="font-size:12px;">${escapeHtml(u.panel_host || 'ندارد')}</div></div>
      <div class="row"><div class="row-title">تولید کانفیگ</div><div>${u.configs_generated || 0} پنل • ${u.warp_generated || 0} WARP</div></div>
    </div>
    <div class="btn-grid" style="margin-bottom:8px;">
      <button class="btn ${u.is_banned ? 'btn-green' : 'btn-red'} btn-sm" onclick="adminUserAction(${u.telegram_id}, 'toggle_ban')">${u.is_banned ? '✅ رفع مسدودی' : '🚫 مسدود کردن'}</button>
      <button class="btn btn-primary btn-sm" onclick="openDmModal(${u.telegram_id})">✉️ پیام مستقیم</button>
    </div>
    ${u.has_panel ? `<button class="btn btn-red" onclick="adminUserAction(${u.telegram_id}, 'reset_panel')">🗑️ حذف پنل کاربر</button>` : ''}
  `);
}

async function adminUserAction(uid, action) {
  try {
    await api('/api/v23/admin/user/action', 'POST', { target_id: uid, action });
    closeSheet();
    toast('✅ عملیات انجام شد');
    loadAdminUsers(0);
  } catch (e) { toast('❌ ' + e.message); }
}

function openDmModal(uid) {
  openSheet(`
    <div style="font-size:17px;font-weight:700;margin-bottom:10px;">✉️ ارسال پیام به <span class="mono">${uid}</span></div>
    <textarea id="inpDmMsg" class="textarea" placeholder="متن پیام..." style="margin-bottom:12px;"></textarea>
    <button class="btn btn-primary" onclick="sendDm(${uid})">ارسال پیام</button>
  `);
}

async function sendDm(uid) {
  const txt = document.getElementById('inpDmMsg').value.trim();
  if (!txt) return;
  try {
    await api('/api/v23/admin/user/dm', 'POST', { target_id: uid, text: txt });
    closeSheet();
    toast('✅ پیام ارسال شد');
  } catch (e) { toast('❌ ' + e.message); }
}

async function saveAdminSettings() {
  try {
    await api('/api/v23/admin/settings', 'POST', {
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
      default_proxy_ip: document.getElementById('inpDefProxy').value.trim(),
    });
    toast('✅ تنظیمات ذخیره شد');
  } catch (e) { toast('❌ ' + e.message); }
}

async function adminBroadcast() {
  const txt = document.getElementById('inpBroadcast').value.trim();
  if (!txt) return toast('⚠️ متن پیام همگانی را بنویسید');
  try {
    const r = await api('/api/v23/admin/broadcast', 'POST', { text: txt });
    document.getElementById('inpBroadcast').value = '';
    toast(`✅ ارسال شد (موفق: ${r.sent} | ناموفق: ${r.failed})`);
  } catch (e) { toast('❌ ' + e.message); }
}

bootstrap();
</script>
</body>
</html>
"""
