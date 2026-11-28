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
    <span class="ver-chip">V24</span>
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
            <div class="row-t"><span data-i18n="active_panel"></span> <span id="pnlVerBadge" class="bdg b-g">V24</span></div>
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
          <button class="btn btn-soft btn-sm" onclick="copyFragSub()" data-i18n="copy_btn"></button>
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
    token_ph: 'Cloudflare API Token را پیست کنید...', deploy_btn: '🚀 ساخت پنل V24',
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
    update_core: 'هسته پنل (V24)', update_core_sub: 'به‌روزرسانی روی Cloudflare Pages',
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
    c_turbo: 'پینگ فوری • اتصال پایدار', c_alt: 'ضد محدودیت سرعت', c_ech: 'ضد DPI با کلید زنده ECH',
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
    token_ph: 'Paste Cloudflare API Token...', deploy_btn: '🚀 Deploy V24 Panel',
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
    update_core: 'Panel Core (V24)', update_core_sub: 'Redeploy latest worker to Pages',
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
    c_turbo: 'Instant ping • Universal TLS', c_alt: 'Bypasses port-443 throttling', c_ech: 'Anti-DPI with live ECH',
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
  try { await api('/api/v24/lang', 'POST', { lang: nxt }); } catch(_) {}
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
    const d = await api('/api/v24/bootstrap');
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
    const r = await api('/api/v24/lock/verify', 'POST', {});
    if (r.unlocked) { toast('✅'); bootstrap(); } else toast('⚠️');
  } catch (e) { toast('❌ ' + e.message); }
}

async function toggleProxySwitch() {
  haptic('medium');
  const en = document.getElementById('swProxy').checked;
  try {
    const r = await api('/api/v24/panel/proxyip', 'POST', { enabled: en, mode: en ? 'auto' : 'off' });
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
    const r = await api('/api/v24/panel/proxyip', 'POST', { enabled: true, mode, proxy_ip: val });
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
    { k: 'vless_1', t: 'VLESS #1', tag: 'Turbo', c: 'b-b', s: t('c_turbo') },
    { k: 'vless_2', t: 'VLESS #2', tag: 'Fast', c: 'b-g', s: t('c_alt') },
    { k: 'vless_3', t: 'VLESS #3', tag: 'ECH', c: 'b-o', s: t('c_ech') },
    { k: 'trojan_1', t: 'Trojan #1', tag: 'Turbo', c: 'b-b', s: t('c_turbo') },
    { k: 'trojan_2', t: 'Trojan #2', tag: 'Fast', c: 'b-g', s: t('c_alt') },
    { k: 'trojan_3', t: 'Trojan #3', tag: 'ECH', c: 'b-o', s: t('c_ech') },
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
    const d = await api(`/api/v24/panel/configs?op=${op}&rotate=${rotate ? 1 : 0}`);
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
    await api('/api/v24/panel/deploy', 'POST', { api_token: token });
    document.getElementById('inpCfToken').value = '';
    toast('🎉 V24 Ready!');
    await bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; btn.textContent = t('deploy_btn'); }
}

async function redeployPanel() {
  const btn = document.getElementById('btnRedeploy');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    await api('/api/v24/panel/redeploy', 'POST', {});
    toast('✅ V24 Updated!');
    await bootstrap();
  } catch (e) { toast('❌ ' + e.message); }
  finally { btn.disabled = false; }
}

async function runE2ETest() {
  const btn = document.getElementById('btnE2E');
  btn.disabled = true; btn.textContent = '⏳';
  try {
    const d = await api('/api/v24/panel/test', 'POST', {});
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
  try { await api('/api/v24/panel/disconnect', 'POST', {}); closeSheet(); toast('🗑️'); bootstrap(); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== WARP ====================
function setWarpMode(m, el) { haptic(); state.warpMode = m; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
function setWarpPlat(p, el) { haptic(); state.warpPlat = p; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }

async function generateWarp() {
  const btn = document.getElementById('btnGenWarp');
  btn.disabled = true; btn.textContent = '⏳...';
  try {
    const b = await api('/api/v24/warp/generate', 'POST', { ip_mode: state.warpMode, platform: state.warpPlat });
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
  try { await api('/api/v24/warp/scan', 'POST', {}); toast('🔍 Scanning...'); setTimeout(bootstrap, 6000); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== CLEAN IPS & SUPPORT ====================
async function loadCleanIps(op, el) {
  if (el) { el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
  const box = document.getElementById('cleanIpsCard');
  box.innerHTML = `<div class="pad" style="text-align:center;color:var(--text-2);font-size:12px;">${t('loading')}</div>`;
  try {
    const d = await api(`/api/v24/ips?op=${op}`);
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
  try { const r = await api('/api/v24/support/ticket', 'POST', { text: txt }); document.getElementById('inpTicket').value = ''; toast(`✅ #${r.ticket_id}`); }
  catch (e) { toast('❌ ' + e.message); }
}

// ==================== ADMIN ====================
async function loadAdminDashboard() {
  if (!state.isAdmin) return;
  try {
    const d = await api('/api/v24/admin/overview');
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
    try { const d = await api('/api/v24/admin/overview'); updateScanUI(d.scanner); if (!d.scanner.is_scanning) { clearInterval(state.scanTimer); toast('✅'); bootstrap(); } }
    catch(_) { clearInterval(state.scanTimer); }
  }, 2000);
}
async function adminStartScan(mode) { haptic('medium'); try { await api('/api/v24/admin/scan', 'POST', { mode }); toast('🚀'); pollScanStatus(); } catch (e) { toast('❌ ' + e.message); } }
function setAdmOp(op, el) { haptic(); state.admOp = op; el.parentElement.querySelectorAll('.seg-b').forEach(b => b.classList.remove('active')); el.classList.add('active'); }
async function adminAddIps() {
  const raw = document.getElementById('inpAdmIps').value.trim(); if (!raw) return;
  try { const r = await api('/api/v24/admin/ips', 'POST', { operator: state.admOp, ips: raw }); document.getElementById('inpAdmIps').value = ''; toast(`✅ +${r.added}`); }
  catch (e) { toast('❌ ' + e.message); }
}

async function loadAdminUsers(page=0) {
  const q = document.getElementById('inpUserSearch').value.trim();
  const box = document.getElementById('admUsersList');
  try {
    const d = await api(`/api/v24/admin/users?page=${page}&q=${encodeURIComponent(q)}`);
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
async function adminUserAction(uid, action) { try { await api('/api/v24/admin/user/action', 'POST', { target_id: uid, action }); closeSheet(); toast('✅'); loadAdminUsers(0); } catch (e) { toast('❌ ' + e.message); } }
function openDmModal(uid) {
  openSheet(`
    <div style="font-size:16px;font-weight:700;margin-bottom:8px;">✉️ DM <span class="mono">${uid}</span></div>
    <textarea id="inpDmMsg" class="ta" style="margin-bottom:10px;"></textarea>
    <button class="btn btn-blue" onclick="sendDm(${uid})">Send</button>
  `);
}
async function sendDm(uid) { const txt = document.getElementById('inpDmMsg').value.trim(); if (!txt) return; try { await api('/api/v24/admin/user/dm', 'POST', { target_id: uid, text: txt }); closeSheet(); toast('✅'); } catch (e) { toast('❌ ' + e.message); } }
async function saveAdminSettings() {
  try {
    await api('/api/v24/admin/settings', 'POST', {
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
  try { const r = await api('/api/v24/admin/broadcast', 'POST', { text: txt }); document.getElementById('inpBroadcast').value = ''; toast(`✅ ${r.sent} / ❌ ${r.failed}`); }
  catch (e) { toast('❌ ' + e.message); }
}

bootstrap();
</script>
</body>
</html>
"""
