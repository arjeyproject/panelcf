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

from app.bot.operator_scanner import FALLBACK_EDGE_IPS, OPERATOR_LABELS, is_restricted_1034_ip
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
    if _ECH_CACHE["val"] and (now - _ECH_CACHE["ts"]) < 600:
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
        proxy_ip: str = "proxyip.cmliussss.net",
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
        V20 High-Speed IP Selector:
          - Probes candidate IPs directly against the user's Pages host.
          - Ranks by combined Throughput (Mbps) + Low RTT.
          - Enforces SUBNET DIVERSITY (picks IPs from different /16 prefixes like 104.16, 104.21, 172.64)
            so if Iran's ISP throttles one subnet, the other configs deliver full speed!
        """
        clean_cands = [c for c in candidates if not is_restricted_1034_ip(c.get("ip", ""))]
        existing_set = {c["ip"] for c in clean_cands}
        for fb in FALLBACK_EDGE_IPS.get(operator, ["104.16.132.229", "104.21.48.84", "172.64.155.209"]):
            if fb not in existing_set:
                clean_cands.append({"ip": fb, "latency_ms": None, "speed_mbps": 0.0, "colo": "CF"})

        sample = clean_cands[:12]
        checked = await asyncio.gather(
            *(check_ip_routes_worker(worker_host, c["ip"], 443, timeout_sec=3.0) for c in sample)
        )
        passing = []
        for cand, (ok, ms, _) in zip(sample, checked):
            if ok:
                item = dict(cand)
                item["latency_ms"] = ms if ms is not None else (cand.get("latency_ms") or 999.0)
                passing.append(item)

        # Sort by highest speed_mbps first (if measured), then lowest real RTT
        passing.sort(key=lambda x: (-(x.get("speed_mbps") or 0.0), x.get("latency_ms") or 9999.0))

        # Pick diverse /16 subnets first (e.g. 104.16.*, 104.21.*, 172.64.*)
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
            chosen.append(chosen[0] if chosen else clean_cands[len(chosen) % len(clean_cands)])
        return chosen[:count]

    @staticmethod
    def build_six_ech_configs(
        panel: dict[str, Any],
        ip_list: list[dict[str, Any]],
        operator: str = "mci",
        ech_b64: str = "",
        alt_port_vless: int = 2083,
        alt_port_trojan: int = 8443,
    ) -> dict[str, Any]:
        """
        V23 Zero-Expiry Multi-Strategy 6-Config Pack (3 VLESS + 3 Trojan):
          Fixes overnight key-rotation blackout! Never puts all 6 configs on expiring static ECH:
          - #1 (Auto-ECH • Port 443): Dynamic DoH ECH (`cloudflare-ech.com+https://...`) -> Auto-rotates, NEVER expires!
          - #2 (Live-ECH • Alt Port 2083/8443): Fresh 10-min Base64 ECH on non-443 Cloudflare port -> Bypasses port-443 QoS & blocked DoH!
          - #3 (Universal TLS 1.3 • Port 443): Clean uTLS (`fp=randomized`/`chrome`, `ed=2048`) -> Works on 100% of clients & never expires!
          Uses anti-DPI neutral WS path `/assets/cdn` (accepted natively by V23 Worker).
        """
        i1 = ip_list[0]
        i2 = ip_list[1] if len(ip_list) > 1 else i1
        i3 = ip_list[2] if len(ip_list) > 2 else i2
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        brand = "CFHub"
        tpass = quote(panel["trojan_password"], safe="")

        ECH_DOH_1 = "cloudflare-ech.com+https://dns.alidns.com/dns-query"
        ECH_DOH_2 = "cloudflare-ech.com+https://doh.pub/dns-query"

        def _hp(ip: str) -> str:
            return f"[{ip}]" if ":" in ip else ip

        def _build(proto: str, it: dict, idx: int, port: int, ws_path: str, mode: str, ech_val: str = "", fp_val: str = "") -> str:
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
            if ech_val:
                params["ech"] = ech_val
            elif fp_val:
                params["fp"] = fp_val

            colo = it.get("colo") or "CF"
            mbps = it.get("speed_mbps") or 0
            spd_tag = f"•{int(round(mbps))}M" if mbps >= 1 else ""
            tag = format_beautiful_name(op_lbl, f"{'VLESS' if proto == 'vless' else 'Trojan'}-{idx}", it.get("latency_ms"), f"{colo}{spd_tag}•{mode}•{brand}")
            cred = panel["uuid"] if proto == "vless" else tpass
            return f"{proto}://{cred}@{_hp(it['ip'])}:{port}?{urlencode(params)}#{quote(tag)}"

        # Port check: use alt port for #2 only when live ECH is present; fallback cleanly
        p_v2 = alt_port_vless if alt_port_vless in (443, 2053, 2083, 2087, 2096, 8443) else 443
        p_t2 = alt_port_trojan if alt_port_trojan in (443, 2053, 2083, 2087, 2096, 8443) else 443

        return {
            "vless_1": _build("vless", i1, 1, 443, "/assets/cdn", "AutoECH", ech_val=ECH_DOH_1),
            "vless_2": _build("vless", i2, 2, p_v2, "/assets/cdn", f"LiveECH-{p_v2}", ech_val=ech_b64 or ECH_DOH_2),
            "vless_3": _build("vless", i3, 3, 443, "/assets/cdn?ed=2048", "UniversalTLS", fp_val="randomized"),
            "trojan_1": _build("trojan", i1, 1, 443, "/assets/cdn", "AutoECH", ech_val=ECH_DOH_2),
            "trojan_2": _build("trojan", i2, 2, p_t2, "/assets/cdn", f"LiveECH-{p_t2}", ech_val=ech_b64 or ECH_DOH_1),
            "trojan_3": _build("trojan", i3, 3, 443, "/assets/cdn?ed=2048", "UniversalTLS", fp_val="chrome"),
            "ech_active": True,
        }

    @staticmethod
    def build_fragment_json_bundle(
        panel: dict[str, Any],
        ip_list: list[dict[str, Any]],
        operator: str = "mci",
    ) -> list[dict[str, Any]]:
        """Builds Anti-DPI TLS-Fragment Xray JSON array for extreme censorship fallback (v2rayNG/v2rayN/Hiddify)."""
        op_lbl = OPERATOR_LABELS.get(operator, "CF")
        out = []
        for idx, it in enumerate(ip_list[:2], start=1):
            for proto in ("vless", "trojan"):
                is_tr = proto == "trojan"
                settings = (
                    {"servers": [{"address": it["ip"], "port": 443, "password": panel["trojan_password"]}]}
                    if is_tr
                    else {"vnext": [{"address": it["ip"], "port": 443, "users": [{"id": panel["uuid"], "encryption": "none"}]}]}
                )
                out.append({
                    "remarks": f"{op_lbl} • {proto.upper()}-{idx} • AutoFragment • CFHub",
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
                                "tlsSettings": {"serverName": panel["host"], "fingerprint": "chrome", "alpn": ["http/1.1"]},
                                "wsSettings": {"path": "/assets/cdn", "headers": {"Host": panel["host"]}},
                                "sockopt": {"dialerProxy": "frag-out", "tcpKeepAliveIdle": 100, "tcpNoDelay": True},
                            },
                        },
                        {
                            "tag": "frag-out", "protocol": "freedom",
                            "settings": {"fragment": {"packets": "tlshello", "length": "40-80", "interval": "10-20"}},
                        },
                        {"tag": "direct", "protocol": "freedom"},
                    ],
                })
        return out
