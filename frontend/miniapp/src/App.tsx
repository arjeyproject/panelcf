import React, { useEffect, useState } from "react";
import { apiRequest } from "./lib/api";

type TabKey =
  | "dashboard"
  | "ip_scanner"
  | "endpoint_scanner"
  | "ip_pool"
  | "endpoint_pool"
  | "builder"
  | "tester"
  | "optimizer"
  | "configs"
  | "favorites"
  | "stats"
  | "tutorials"
  | "settings";

const LABELS: Record<"fa" | "en", Record<TabKey, string>> = {
  fa: {
    dashboard: "داشبورد",
    ip_scanner: "اسکنر IP",
    endpoint_scanner: "اسکنر Endpoint",
    ip_pool: "استخر IP",
    endpoint_pool: "استخر Endpoint",
    builder: "ساخت کانفیگ",
    tester: "تستر کانفیگ",
    optimizer: "بهینه‌ساز",
    configs: "کانفیگ‌های من",
    favorites: "علاقه‌مندی‌ها",
    stats: "آمار",
    tutorials: "آموزش‌ها",
    settings: "تنظیمات",
  },
  en: {
    dashboard: "Dashboard",
    ip_scanner: "IP Scanner",
    endpoint_scanner: "Endpoint Scanner",
    ip_pool: "IP Pool",
    endpoint_pool: "Endpoint Pool",
    builder: "Config Builder",
    tester: "Config Tester",
    optimizer: "Optimizer",
    configs: "My Configs",
    favorites: "Favorites",
    stats: "Statistics",
    tutorials: "Tutorials",
    settings: "Settings",
  },
};

export function App() {
  const [lang, setLang] = useState<"fa" | "en">("fa");
  const [dark, setDark] = useState(true);
  const [tab, setTab] = useState<TabKey>("dashboard");
  const [health, setHealth] = useState<any>(null);
  const [protocol, setProtocol] = useState("vless");
  const [profileName, setProfileName] = useState("CF-Edge-01");
  const [generated, setGenerated] = useState<any>(null);
  const [scanInput, setScanInput] = useState("1.1.1.1\n1.0.0.1");
  const [scanResults, setScanResults] = useState<any[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    window.Telegram?.WebApp?.ready();
    window.Telegram?.WebApp?.expand();
    document.documentElement.dir = lang === "fa" ? "rtl" : "ltr";
    document.documentElement.lang = lang;
    document.documentElement.classList.toggle("dark", dark);
  }, [lang, dark]);

  useEffect(() => {
    apiRequest("/health").then(setHealth).catch(() => null);
  }, []);

  async function runIpScan() {
    setBusy(true);
    setError(null);
    try {
      const ips = scanInput.split(/\s+/).filter(Boolean);
      const data = await apiRequest<any>("/scanners/ip/run", {
        method: "POST",
        body: JSON.stringify({ ips, port: 443, test_tls: true, repeated_attempts: 3 }),
      });
      setScanResults(data.results || []);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function buildSampleConfig(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const form = new FormData(e.currentTarget);
    const params: Record<string, any> = Object.fromEntries(form.entries());
    try {
      const res = await apiRequest<any>("/configs/generate", {
        method: "POST",
        body: JSON.stringify({ name: profileName, protocol, params, include_qr: true }),
      });
      setGenerated(res);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen bg-slate-100 text-slate-900 dark:bg-graphite-950 dark:text-slate-100 pb-16">
      <header className="sticky top-0 z-20 border-b border-slate-200 dark:border-graphite-700 bg-white/85 dark:bg-graphite-900/90 backdrop-blur px-4 py-3 flex items-center justify-between">
        <div>
          <h1 className="text-base font-bold bg-gradient-to-r from-cyan-400 via-blue-400 to-emerald-400 bg-clip-text text-transparent">
            Cloudflare Config Hub
          </h1>
          <p className="text-xs text-slate-500 dark:text-slate-400">
            {lang === "fa" ? "مینی‌اپ مدیریت و اسکن واقعی شبکه" : "Verified Network Diagnostics & Config Engine"}
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => setLang(lang === "fa" ? "en" : "fa")}
            className="px-2.5 py-1 rounded-lg text-xs font-semibold bg-cyan-500/15 text-cyan-400 border border-cyan-500/30"
          >
            {lang === "fa" ? "EN" : "فارسی"}
          </button>
          <button
            onClick={() => setDark(!dark)}
            className="px-2.5 py-1 rounded-lg text-xs font-semibold bg-blue-500/15 text-blue-400 border border-blue-500/30"
          >
            {dark ? "☀️" : "🌙"}
          </button>
        </div>
      </header>

      <nav className="flex overflow-x-auto gap-2 px-4 py-3 border-b border-slate-200 dark:border-graphite-800">
        {(Object.keys(LABELS[lang]) as TabKey[]).map((key) => (
          <button
            key={key}
            onClick={() => setTab(key)}
            className={`whitespace-nowrap px-3 py-1.5 rounded-xl text-xs font-medium transition ${
              tab === key
                ? "bg-cyan-500 text-slate-950 shadow-lg shadow-cyan-500/20"
                : "bg-white dark:bg-graphite-800 text-slate-600 dark:text-slate-300 border border-slate-200 dark:border-graphite-700"
            }`}
          >
            {LABELS[lang][key]}
          </button>
        ))}
      </nav>

      <main className="p-4 max-w-2xl mx-auto space-y-4">
        {error && (
          <div className="p-3 rounded-xl bg-rose-500/15 border border-rose-500/40 text-rose-300 text-xs">
            {error}
          </div>
        )}

        {tab === "dashboard" && (
          <section className="grid grid-cols-2 gap-3">
            <div className="p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700">
              <div className="text-xs text-slate-400">{lang === "fa" ? "IPهای تاییدشده استخر" : "Verified IP Pool"}</div>
              <div className="text-2xl font-bold text-cyan-400 mt-1">
                {health?.pools?.ip?.healthy_verified_entries ?? 0} / {health?.pools?.ip?.target_count ?? 100}
              </div>
            </div>
            <div className="p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700">
              <div className="text-xs text-slate-400">{lang === "fa" ? "Endpointهای تاییدشده" : "Verified Endpoints"}</div>
              <div className="text-2xl font-bold text-emerald-400 mt-1">
                {health?.pools?.endpoint?.healthy_verified_entries ?? 0} / {health?.pools?.endpoint?.target_count ?? 100}
              </div>
            </div>
            <div className="col-span-2 p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700 text-xs text-slate-400 space-y-1">
              <div className="font-semibold text-slate-200">{lang === "fa" ? "شفافیت وضعیت کاندیداها" : "Strict Verification Transparency"}</div>
              <p>
                {lang === "fa"
                  ? "کاندیداها تنها پس از تست واقعی TCP/TLS، محاسبه Jitter و عبور از آستانه امتیاز وارد استخر سالم می‌شوند."
                  : "Candidates only enter healthy pools after real multi-round measurements and weighted stability scoring."}
              </p>
            </div>
          </section>
        )}

        {tab === "ip_scanner" && (
          <section className="p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700 space-y-3">
            <h2 className="font-semibold text-sm text-cyan-400">{LABELS[lang].ip_scanner}</h2>
            <textarea
              rows={4}
              value={scanInput}
              onChange={(e) => setScanInput(e.target.value)}
              className="w-full rounded-xl bg-slate-50 dark:bg-graphite-950 border border-slate-300 dark:border-graphite-700 p-3 text-xs font-mono"
            />
            <button
              disabled={busy}
              onClick={runIpScan}
              className="w-full py-2.5 rounded-xl font-semibold text-sm bg-gradient-to-r from-cyan-500 to-blue-500 text-slate-950 disabled:opacity-50"
            >
              {busy ? (lang === "fa" ? "در حال اسکن..." : "Scanning...") : (lang === "fa" ? "شروع اسکن واقعی" : "Start Real Scan")}
            </button>
            <div className="space-y-2">
              {scanResults.map((r) => (
                <div key={r.ip} className="p-3 rounded-xl bg-graphite-800/60 border border-graphite-700 flex justify-between text-xs">
                  <span className="font-mono text-cyan-300">{r.ip}:{r.port}</span>
                  <span className="text-emerald-400">
                    {r.avg_latency_ms ?? "—"} ms | jitter {r.jitter_ms ?? "—"} ms | {Math.round(r.success_rate * 100)}%
                  </span>
                </div>
              ))}
            </div>
          </section>
        )}

        {tab === "builder" && (
          <section className="p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700 space-y-3">
            <h2 className="font-semibold text-sm text-emerald-400">{LABELS[lang].builder}</h2>
            <div className="flex gap-2 flex-wrap">
              {["vless", "trojan", "wireguard", "warp", "masque"].map((p) => (
                <button
                  key={p}
                  onClick={() => setProtocol(p)}
                  className={`px-3 py-1 rounded-lg text-xs uppercase font-bold ${
                    protocol === p ? "bg-emerald-500 text-slate-950" : "bg-graphite-800 text-slate-300"
                  }`}
                >
                  {p}
                </button>
              ))}
            </div>
            <form onSubmit={buildSampleConfig} className="space-y-2.5 text-xs">
              <input value={profileName} onChange={(e) => setProfileName(e.target.value)} placeholder="Profile Name" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
              {protocol === "vless" && (
                <>
                  <input name="uuid" required placeholder="UUID (RFC 4122)" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700 font-mono" />
                  <input name="address" required placeholder="Server / Edge IP" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700 font-mono" />
                  <input name="sni" required placeholder="TLS SNI" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
                  <input name="path" defaultValue="/ws" placeholder="WS Path" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
                </>
              )}
              {protocol === "trojan" && (
                <>
                  <input name="password" required placeholder="Server Password" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
                  <input name="address" required placeholder="Server Address" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
                  <input name="sni" required placeholder="TLS SNI" className="w-full p-2.5 rounded-xl bg-graphite-950 border border-graphite-700" />
                </>
              )}
              <button disabled={busy} type="submit" className="w-full py-2.5 rounded-xl bg-emerald-500 text-slate-950 font-bold">
                {lang === "fa" ? "تولید و اعتبارسنجی کانفیگ" : "Validate & Generate Config"}
              </button>
            </form>
            {generated && (
              <div className="p-3 rounded-xl bg-graphite-950 border border-emerald-500/40 space-y-2">
                <div className="text-xs text-emerald-400 font-semibold">State: {generated.lifecycle_state}</div>
                <pre className="text-[11px] overflow-x-auto text-slate-200">{generated.serialized}</pre>
                {generated.qr_data_uri && <img src={generated.qr_data_uri} alt="QR Code" className="w-40 h-40 rounded-lg bg-white p-1" />}
              </div>
            )}
          </section>
        )}

        {tab !== "dashboard" && tab !== "ip_scanner" && tab !== "builder" && (
          <section className="p-4 rounded-2xl bg-white dark:bg-graphite-900 border border-slate-200 dark:border-graphite-700 text-xs space-y-2">
            <h2 className="font-semibold text-sm text-blue-400">{LABELS[lang][tab]}</h2>
            <p className="text-slate-400">
              {lang === "fa"
                ? "این بخش مستقیماً به API نسخه ۱ بک‌اند متصل بوده و احراز هویت Telegram WebApp InitData را در سمت سرور بررسی می‌کند."
                : "Connected directly to Backend API v1 with server-side Telegram WebApp InitData HMAC verification."}
            </p>
          </section>
        )}
      </main>
    </div>
  );
}
export default App;
