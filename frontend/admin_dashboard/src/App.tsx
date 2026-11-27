import React, { useEffect, useState } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from "recharts";

const NAV_ITEMS = [
  "Overview",
  "Users",
  "Scanners",
  "Pools",
  "Cloudflare API",
  "Channels & YouTube",
  "Broadcasts",
  "System & Security",
] as const;

type Section = (typeof NAV_ITEMS)[number];

export function App() {
  const [section, setSection] = useState<Section>("Overview");
  const [health, setHealth] = useState<any>(null);
  const [history, setHistory] = useState<Array<{ time: string; cpu: number; mem: number }>>([]);

  useEffect(() => {
    const fetchHealth = () => {
      fetch("/api/v1/health")
        .then((r) => r.json())
        .then((data) => {
          setHealth(data);
          setHistory((prev) => [
            ...prev.slice(-19),
            {
              time: new Date().toLocaleTimeString(),
              cpu: data?.system?.cpu_percent ?? 0,
              mem: data?.system?.memory_percent ?? 0,
            },
          ]);
        })
        .catch(() => null);
    };
    fetchHealth();
    const id = setInterval(fetchHealth, 15000);
    return () => clearInterval(id);
  }, []);

  return (
    <div className="min-h-screen flex bg-slate-950 text-slate-100">
      <aside className="w-60 border-r border-slate-800 bg-slate-900 p-4 flex flex-col gap-2">
        <div className="text-lg font-bold text-cyan-400 mb-4">CF Hub Admin</div>
        {NAV_ITEMS.map((item) => (
          <button
            key={item}
            onClick={() => setSection(item)}
            className={`text-left px-3 py-2 rounded-xl text-sm transition ${
              section === item ? "bg-cyan-500/20 text-cyan-300 border border-cyan-500/40" : "text-slate-400 hover:bg-slate-800"
            }`}
          >
            {item}
          </button>
        ))}
      </aside>

      <main className="flex-1 p-6 space-y-6">
        <div className="flex items-center justify-between">
          <h1 className="text-2xl font-bold">{section}</h1>
          <span className="px-3 py-1 rounded-full text-xs bg-emerald-500/15 text-emerald-400 border border-emerald-500/30">
            API: {health?.system?.status || "connecting"}
          </span>
        </div>

        {section === "Overview" && (
          <>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="p-4 rounded-2xl bg-slate-900 border border-slate-800">
                <div className="text-xs text-slate-400">Verified IP Pool</div>
                <div className="text-2xl font-bold text-cyan-400 mt-1">
                  {health?.pools?.ip?.healthy_verified_entries ?? 0} / {health?.pools?.ip?.target_count ?? 100}
                </div>
              </div>
              <div className="p-4 rounded-2xl bg-slate-900 border border-slate-800">
                <div className="text-xs text-slate-400">Verified Endpoint Pool</div>
                <div className="text-2xl font-bold text-emerald-400 mt-1">
                  {health?.pools?.endpoint?.healthy_verified_entries ?? 0} / {health?.pools?.endpoint?.target_count ?? 100}
                </div>
              </div>
              <div className="p-4 rounded-2xl bg-slate-900 border border-slate-800">
                <div className="text-xs text-slate-400">CPU / Memory</div>
                <div className="text-2xl font-bold text-blue-400 mt-1">
                  {health?.system?.cpu_percent ?? 0}% / {health?.system?.memory_percent ?? 0}%
                </div>
              </div>
              <div className="p-4 rounded-2xl bg-slate-900 border border-slate-800">
                <div className="text-xs text-slate-400">Active Scan Jobs</div>
                <div className="text-2xl font-bold text-amber-400 mt-1">{health?.active_jobs ?? 0}</div>
              </div>
            </div>

            <div className="p-4 rounded-2xl bg-slate-900 border border-slate-800 h-72">
              <div className="text-sm font-semibold mb-3 text-slate-300">Live Host Resource Telemetry</div>
              <ResponsiveContainer width="100%" height="88%">
                <LineChart data={history}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
                  <XAxis dataKey="time" stroke="#94a3b8" fontSize={11} />
                  <YAxis domain={[0, 100]} stroke="#94a3b8" fontSize={11} />
                  <Tooltip />
                  <Line type="monotone" dataKey="cpu" stroke="#22d3ee" strokeWidth={2} dot={false} />
                  <Line type="monotone" dataKey="mem" stroke="#10b981" strokeWidth={2} dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </>
        )}

        {section !== "Overview" && (
          <div className="p-6 rounded-2xl bg-slate-900 border border-slate-800 text-sm text-slate-300 space-y-2">
            <p className="font-semibold text-cyan-400">{section} Control Panel</p>
            <p className="text-slate-400">
              Protected by RBAC Bearer JWT authentication (Owner / Admin / Moderator roles) with server-side permission checks and immutable audit logging.
            </p>
          </div>
        )}
      </main>
    </div>
  );
}
export default App;
