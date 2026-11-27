#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V6 (Operator Categorization + Dual VLESS/Trojan Worker + IPv6 WARP + Clean UI)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import hashlib
import json

# Production ES Module Cloudflare Worker supporting BOTH VLESS AND Trojan over WebSocket
# Key fixes over V5 that eliminate red pings:
#  1) Wraps direct `connect()` AND `writer.write()` in try/catch so Cloudflare-hosted ping targets
#     (like cp.cloudflare.com/generate_204) IMMEDIATELY fall back to a rotating list of working ProxyIPs!
#  2) Pre-computes Trojan SHA-224(password) in Python (because Cloudflare Workers Web Crypto lacks SHA-224).
#  3) Supports `/sub/{UUID}` and `/sub/{UUID}?op=mci|mtn|mkh` delivering categorized VLESS + Trojan configs
#     grouped cleanly by Iran operator (همراه اول / ایرانسل / مخابرات).
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const USER_ID = '__UUID__';
const TROJAN_PASSWORD = '__TROJAN_PASS__';
const TROJAN_HASH = '__TROJAN_HASH__';
const PROXY_IPS = __PROXY_IPS_JSON__;
const OPERATOR_IPS = __OPERATOR_IPS_JSON__;
const PANEL_BRAND = '__PANEL_BRAND__';

const WS_READY_STATE_OPEN = 1;
const WS_READY_STATE_CLOSING = 2;

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const upgradeHeader = request.headers.get('Upgrade');

      if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
        if (url.pathname === '/health') {
          return new Response(JSON.stringify({
            ok: true,
            service: 'cfhub-v6-worker',
            protocols: ['vless', 'trojan'],
            brand: PANEL_BRAND,
            operators: {
              mci: (OPERATOR_IPS.mci || []).length,
              mtn: (OPERATOR_IPS.mtn || []).length,
              mkh: (OPERATOR_IPS.mkh || []).length,
            },
            timestamp: new Date().toISOString()
          }), {
            status: 200,
            headers: { 'content-type': 'application/json; charset=utf-8' }
          });
        }

        if (url.pathname === `/sub/${USER_ID}` || url.pathname === `/${USER_ID}`) {
          const host = request.headers.get('Host') || url.hostname;
          const opFilter = (url.searchParams.get('op') || 'all').toLowerCase();
          const subText = buildCategorizedSubscription(host, opFilter);
          const encoded = btoa(unescape(encodeURIComponent(subText)));
          const titleMap = { mci: 'همراه اول', mtn: 'ایرانسل', mkh: 'مخابرات', all: 'همه اپراتورها' };
          const title = `⚡ ${PANEL_BRAND} • ${titleMap[opFilter] || 'VIP'}`;
          return new Response(encoded, {
            status: 200,
            headers: {
              'content-type': 'text/plain; charset=utf-8',
              'profile-title': 'base64:' + btoa(unescape(encodeURIComponent(title))),
              'profile-update-interval': '6',
            }
          });
        }

        return new Response('Welcome to nginx!', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      // Extract optional ?proxyip= override
      let overrideProxy = url.searchParams.get('proxyip') || '';
      const pathMatch = url.pathname.match(/proxyip=([^/&?#]+)/i);
      if (pathMatch && pathMatch[1]) {
        overrideProxy = decodeURIComponent(pathMatch[1]);
      }

      return await handleDualWebSocket(request, overrideProxy);
    } catch (err) {
      return new Response(String(err), { status: 500 });
    }
  }
};

function buildCategorizedSubscription(host, opFilter) {
  const opMeta = {
    mci: { label: '🔵همراه اول', list: OPERATOR_IPS.mci || [] },
    mtn: { label: '🟡ایرانسل', list: OPERATOR_IPS.mtn || [] },
    mkh: { label: '🟢مخابرات', list: OPERATOR_IPS.mkh || [] },
  };
  const keys = opFilter === 'all' ? ['mci', 'mtn', 'mkh'] : (opMeta[opFilter] ? [opFilter] : ['mci', 'mtn', 'mkh']);
  const wsPath = encodeURIComponent('/?ed=2048');
  const lines = [];

  for (const key of keys) {
    const meta = opMeta[key];
    const items = meta.list.length ? meta.list.slice(0, 4) : [{ ip: host, latency_ms: 0, colo: 'CF' }];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const ip = typeof it === 'string' ? it : it.ip;
      const hostPart = ip.includes(':') ? `[${ip}]` : ip;
      const ping = it.latency_ms ? `${Math.round(it.latency_ms)}ms` : 'Auto';
      const colo = it.colo ? `•${it.colo}` : '';

      const vlessTag = encodeURIComponent(`${meta.label} • VLESS • ${ping}${colo} • ${PANEL_BRAND}`);
      lines.push(
        `vless://${USER_ID}@${hostPart}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${vlessTag}`
      );

      const trojanTag = encodeURIComponent(`${meta.label} • Trojan • ${ping}${colo} • ${PANEL_BRAND}`);
      lines.push(
        `trojan://${encodeURIComponent(TROJAN_PASSWORD)}@${hostPart}:443?security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${trojanTag}`
      );
    }
  }
  return lines.join('\n');
}

async function handleDualWebSocket(request, overrideProxy) {
  const wsPair = new WebSocketPair();
  const [client, server] = Object.values(wsPair);
  server.accept();

  const earlyDataHeader = request.headers.get('sec-websocket-protocol') || '';
  const readableWS = makeReadableWebSocketStream(server, earlyDataHeader);

  let remoteSocketWrapper = { value: null };
  let isDns = false;

  const proxyCandidates = overrideProxy
    ? [overrideProxy, ...PROXY_IPS.filter(p => p !== overrideProxy)]
    : [...PROXY_IPS];

  readableWS.pipeTo(new WritableStream({
    async write(chunk) {
      const buf = chunk instanceof ArrayBuffer ? chunk : chunk.buffer;
      if (isDns) return;
      if (remoteSocketWrapper.value) {
        const writer = remoteSocketWrapper.value.writable.getWriter();
        await writer.write(buf);
        writer.releaseLock();
        return;
      }

      // Auto-detect Trojan first (56-byte SHA-224 hex + CRLF), otherwise VLESS
      let parsed = parseTrojanHeader(buf);
      let respHeader = null; // Trojan has NO response header

      if (parsed.hasError) {
        const vlessParsed = parseVlessHeader(buf, USER_ID);
        if (vlessParsed.hasError) {
          throw new Error(`Auth failed: ${vlessParsed.message}`);
        }
        parsed = vlessParsed;
        respHeader = new Uint8Array([vlessParsed.vlessVersion[0], 0]);
      }

      const rawClientData = buf.slice(parsed.rawDataIndex);

      if (parsed.isUDP) {
        if (parsed.portRemote === 53) {
          isDns = true;
          await handleDnsOverHttps(rawClientData, server, respHeader);
          return;
        }
        throw new Error('UDP only supported on port 53');
      }

      await handleTCPOutboundWithFallback(
        remoteSocketWrapper,
        parsed.addressRemote,
        parsed.portRemote,
        rawClientData,
        server,
        respHeader,
        proxyCandidates
      );
    },
    close() {},
    abort() {}
  })).catch(() => {
    safeCloseWebSocket(server);
  });

  return new Response(null, { status: 101, webSocket: client });
}

async function handleTCPOutboundWithFallback(
  remoteSocketWrapper,
  addressRemote,
  portRemote,
  rawClientData,
  webSocket,
  respHeader,
  proxyCandidates
) {
  async function openAndWrite(host, port) {
    const sock = connect({ hostname: host, port: Number(port) });
    remoteSocketWrapper.value = sock;
    const writer = sock.writable.getWriter();
    if (rawClientData && rawClientData.byteLength > 0) {
      await writer.write(rawClientData);
    }
    writer.releaseLock();
    return sock;
  }

  async function tryFallbackProxies(idx) {
    if (idx >= proxyCandidates.length) {
      safeCloseWebSocket(webSocket);
      return;
    }
    const candidate = proxyCandidates[idx];
    const [pHost, pPort] = candidate.includes(':') ? candidate.split(':') : [candidate, String(portRemote)];
    try {
      const sock = await openAndWrite(pHost, Number(pPort) || portRemote);
      const gotData = await pumpRemoteToWS(sock, webSocket, respHeader);
      if (!gotData) {
        await tryFallbackProxies(idx + 1);
      } else {
        safeCloseWebSocket(webSocket);
      }
    } catch (_) {
      await tryFallbackProxies(idx + 1);
    }
  }

  // CRITICAL FIX: wrap direct connect() in try/catch so Cloudflare-hosted targets
  // (like cp.cloudflare.com during ping tests!) seamlessly fail over to ProxyIP instead of aborting!
  try {
    const directSock = await openAndWrite(addressRemote, portRemote);
    const gotData = await pumpRemoteToWS(directSock, webSocket, respHeader);
    if (!gotData) {
      await tryFallbackProxies(0);
    } else {
      safeCloseWebSocket(webSocket);
    }
  } catch (_) {
    await tryFallbackProxies(0);
  }
}

async function pumpRemoteToWS(remoteSocket, webSocket, respHeader) {
  let hasIncomingData = false;
  let headerSent = respHeader === null;

  await remoteSocket.readable.pipeTo(new WritableStream({
    async write(chunk) {
      hasIncomingData = true;
      if (webSocket.readyState !== WS_READY_STATE_OPEN) {
        throw new Error('WebSocket closed');
      }
      if (!headerSent && respHeader) {
        headerSent = true;
        const combined = new Uint8Array(respHeader.byteLength + chunk.byteLength);
        combined.set(respHeader, 0);
        combined.set(new Uint8Array(chunk), respHeader.byteLength);
        webSocket.send(combined.buffer);
      } else {
        webSocket.send(chunk);
      }
    }
  })).catch(() => {});

  return hasIncomingData;
}

function parseTrojanHeader(buffer) {
  if (buffer.byteLength < 64) {
    return { hasError: true, message: 'short trojan buffer' };
  }
  const bytes = new Uint8Array(buffer);
  if (bytes[56] !== 0x0d || bytes[57] !== 0x0a) {
    return { hasError: true, message: 'missing trojan crlf' };
  }
  const incomingHash = new TextDecoder().decode(bytes.slice(0, 56)).toLowerCase();
  if (incomingHash !== TROJAN_HASH.toLowerCase()) {
    return { hasError: true, message: 'invalid trojan password hash' };
  }

  const cmd = bytes[58]; // 1 = TCP, 3 = UDP
  const isUDP = cmd === 3;
  if (cmd !== 1 && cmd !== 3) {
    return { hasError: true, message: `unsupported trojan cmd ${cmd}` };
  }

  const atyp = bytes[59];
  let idx = 60;
  let addressRemote = '';

  if (atyp === 1) {
    addressRemote = bytes.slice(idx, idx + 4).join('.');
    idx += 4;
  } else if (atyp === 3) {
    const domLen = bytes[idx];
    idx += 1;
    addressRemote = new TextDecoder().decode(bytes.slice(idx, idx + domLen));
    idx += domLen;
  } else if (atyp === 4) {
    const dv = new DataView(buffer, idx, 16);
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(dv.getUint16(i * 2).toString(16));
    addressRemote = parts.join(':');
    idx += 16;
  } else {
    return { hasError: true, message: `invalid trojan atyp ${atyp}` };
  }

  const portRemote = new DataView(buffer, idx, 2).getUint16(0);
  idx += 2;
  // Skip trailing CRLF
  if (bytes[idx] === 0x0d && bytes[idx + 1] === 0x0a) {
    idx += 2;
  }

  return {
    hasError: false,
    addressRemote,
    portRemote,
    rawDataIndex: idx,
    isUDP,
  };
}

function parseVlessHeader(vlessBuffer, userID) {
  if (vlessBuffer.byteLength < 24) {
    return { hasError: true, message: 'invalid vless header length' };
  }
  const version = new Uint8Array(vlessBuffer.slice(0, 1));
  const incomingUUID = stringifyUUID(new Uint8Array(vlessBuffer.slice(1, 17)));
  if (incomingUUID.toLowerCase() !== userID.toLowerCase()) {
    return { hasError: true, message: 'invalid user uuid' };
  }

  const optLength = new Uint8Array(vlessBuffer.slice(17, 18))[0];
  const command = new Uint8Array(vlessBuffer.slice(18 + optLength, 19 + optLength))[0];
  let isUDP = false;
  if (command === 2) {
    isUDP = true;
  } else if (command !== 1) {
    return { hasError: true, message: `unsupported command ${command}` };
  }

  const portIndex = 18 + optLength + 1;
  const portRemote = new DataView(vlessBuffer.slice(portIndex, portIndex + 2)).getUint16(0);

  let addressIndex = portIndex + 2;
  const addressType = new Uint8Array(vlessBuffer.slice(addressIndex, addressIndex + 1))[0];
  let addressValueIndex = addressIndex + 1;
  let addressLength = 0;
  let addressRemote = '';

  if (addressType === 1) {
    addressLength = 4;
    addressRemote = new Uint8Array(vlessBuffer.slice(addressValueIndex, addressValueIndex + addressLength)).join('.');
  } else if (addressType === 2) {
    addressLength = new Uint8Array(vlessBuffer.slice(addressValueIndex, addressValueIndex + 1))[0];
    addressValueIndex += 1;
    addressRemote = new TextDecoder().decode(vlessBuffer.slice(addressValueIndex, addressValueIndex + addressLength));
  } else if (addressType === 3) {
    addressLength = 16;
    const dv = new DataView(vlessBuffer.slice(addressValueIndex, addressValueIndex + addressLength));
    const ipv6 = [];
    for (let i = 0; i < 8; i++) ipv6.push(dv.getUint16(i * 2).toString(16));
    addressRemote = ipv6.join(':');
  } else {
    return { hasError: true, message: `invalid addressType ${addressType}` };
  }

  return {
    hasError: false,
    addressRemote,
    portRemote,
    rawDataIndex: addressValueIndex + addressLength,
    vlessVersion: version,
    isUDP
  };
}

async function handleDnsOverHttps(rawClientData, webSocket, respHeader) {
  try {
    if (rawClientData.byteLength < 2) return;
    const dv = new DataView(rawClientData);
    const len = dv.getUint16(0);
    const dnsQuery = rawClientData.slice(2, 2 + len);
    const resp = await fetch('https://1.1.1.1/dns-query', {
      method: 'POST',
      headers: { 'content-type': 'application/dns-message' },
      body: dnsQuery
    });
    const ans = new Uint8Array(await resp.arrayBuffer());
    const prefixLen = respHeader ? respHeader.byteLength : 0;
    const out = new Uint8Array(prefixLen + 2 + ans.byteLength);
    if (respHeader) out.set(respHeader, 0);
    out[prefixLen] = (ans.byteLength >> 8) & 0xff;
    out[prefixLen + 1] = ans.byteLength & 0xff;
    out.set(ans, prefixLen + 2);
    if (webSocket.readyState === WS_READY_STATE_OPEN) {
      webSocket.send(out.buffer);
    }
  } catch (_) {}
}

function makeReadableWebSocketStream(webSocketServer, earlyDataHeader) {
  let canceled = false;
  return new ReadableStream({
    start(controller) {
      webSocketServer.addEventListener('message', (event) => {
        if (canceled) return;
        controller.enqueue(event.data);
      });
      webSocketServer.addEventListener('close', () => {
        safeCloseWebSocket(webSocketServer);
        if (!canceled) controller.close();
      });
      webSocketServer.addEventListener('error', (err) => controller.error(err));

      const early = base64ToArrayBuffer(earlyDataHeader);
      if (early) controller.enqueue(early);
    },
    cancel() {
      canceled = true;
      safeCloseWebSocket(webSocketServer);
    }
  });
}

function base64ToArrayBuffer(b64) {
  if (!b64) return null;
  try {
    const clean = b64.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(clean);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  } catch (_) {
    return null;
  }
}

const HEX = Array.from({ length: 256 }, (_, i) => (i + 0x100).toString(16).slice(1));
function stringifyUUID(arr) {
  return (
    HEX[arr[0]] + HEX[arr[1]] + HEX[arr[2]] + HEX[arr[3]] + '-' +
    HEX[arr[4]] + HEX[arr[5]] + '-' +
    HEX[arr[6]] + HEX[arr[7]] + '-' +
    HEX[arr[8]] + HEX[arr[9]] + '-' +
    HEX[arr[10]] + HEX[arr[11]] + HEX[arr[12]] + HEX[arr[13]] + HEX[arr[14]] + HEX[arr[15]]
  );
}

function safeCloseWebSocket(ws) {
  try {
    if (ws.readyState === WS_READY_STATE_OPEN || ws.readyState === WS_READY_STATE_CLOSING) {
      ws.close();
    }
  } catch (_) {}
}
""".strip()

DEFAULT_PROXY_IPS = [
    "proxyip.cmliussss.net",
    "proxyip.fxxk.dedyn.io",
    "proxyip.oracle.fxxk.dedyn.io",
    "proxyip.aliyun.fxxk.dedyn.io",
    "cdn.xn--b6gac.eu.org",
]


def render_worker_script(
    user_uuid: str,
    trojan_password: str,
    proxy_ip: str = "",
    operator_pools: dict | None = None,
    brand: str = "CFHub",
) -> str:
    safe_brand = brand.replace("'", "").replace('"', "").replace("\\", "")[:20] or "CFHub"
    safe_tpass = trojan_password.replace("'", "").replace('"', "").strip()
    trojan_hash = hashlib.sha224(safe_tpass.encode("utf-8")).hexdigest()

    proxies = [p for p in [proxy_ip.strip()] + DEFAULT_PROXY_IPS if p]
    proxies = list(dict.fromkeys(proxies))

    pools = operator_pools or {}
    compact_ops = {
        op: [
            {"ip": x["ip"], "latency_ms": x.get("latency_ms", 0), "colo": x.get("colo", "")}
            for x in (pools.get(op) or [])[:6]
        ]
        for op in ("mci", "mtn", "mkh")
    }

    return (
        WORKER_JS_TEMPLATE
        .replace("__UUID__", user_uuid.strip())
        .replace("__TROJAN_PASS__", safe_tpass)
        .replace("__TROJAN_HASH__", trojan_hash)
        .replace("__PROXY_IPS_JSON__", json.dumps(proxies))
        .replace("__OPERATOR_IPS_JSON__", json.dumps(compact_ops, ensure_ascii=False))
        .replace("__PANEL_BRAND__", safe_brand)
    )
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/operator_scanner.py
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

# Community-maintained Iran ISP Clean IP DNS records + verified CDN clean hostnames per operator
OPERATOR_DNS_SOURCES: dict[str, list[str]] = {
    "mci": [
        "mci.ircf.space",
        "mcic.ircf.space",
        "mci.cf.vfarid.com",
        "www.visa.com",
        "icook.hk",
        "time.is",
    ],
    "mtn": [
        "mtn.ircf.space",
        "mtnc.ircf.space",
        "mtn.cf.vfarid.com",
        "www.shopify.com",
        "icook.tw",
        "ip.sb",
    ],
    "mkh": [
        "mkh.ircf.space",
        "tci.ircf.space",
        "mkh.cf.vfarid.com",
        "www.visa.com.sg",
        "speed.cloudflare.com",
        "www.wto.org",
    ],
}

OPERATOR_LABELS: dict[str, str] = {
    "mci": "🔵 همراه اول",
    "mtn": "🟡 ایرانسل",
    "mkh": "🟢 مخابرات",
}

# Preferred low-hop Cloudflare edge PoPs for Iran traffic (Middle East & Europe)
IRAN_PREFERRED_COLOS = {"DXB", "MCT", "DOH", "BAH", "KWI", "IST", "FRA", "AMS", "MRS", "VIE", "WAW", "BUD", "SOF", "ZRH", "MXP"}


async def resolve_doh_records(domain: str, qtype: str = "A", timeout_sec: float = 4.0) -> list[str]:
    """Resolve DNS A/AAAA via Cloudflare DoH JSON API (works cleanly regardless of host DNS)."""
    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            r = await client.get(
                "https://cloudflare-dns.com/dns-query",
                params={"name": domain, "type": qtype},
                headers={"Accept": "application/dns-json"},
            )
            if r.status_code != 200:
                return []
            answers = r.json().get("Answer") or []
            ips: list[str] = []
            for ans in answers:
                val = str(ans.get("data", "")).strip()
                try:
                    ip_obj = ipaddress.ip_address(val)
                    if ip_obj.is_global:
                        ips.append(str(ip_obj))
                except ValueError:
                    continue
            return ips
    except Exception:
        return []


async def verify_cloudflare_edge_ip(ip: str, port: int = 443, timeout_sec: float = 2.8) -> dict[str, Any] | None:
    """
    Real TLS + HTTP /cdn-cgi/trace verification against an IP.
    Confirms the IP is a live, genuine Cloudflare Edge server (returns exact `colo` PoP & RTT ms).
    """
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    start = time.perf_counter()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port, ssl=ssl_ctx, server_hostname="cloudflare.com"),
            timeout=timeout_sec,
        )
        req = (
            "GET /cdn-cgi/trace HTTP/1.1\r\n"
            "Host: cloudflare.com\r\n"
            "User-Agent: Mozilla/5.0\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        writer.write(req)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        raw = await asyncio.wait_for(reader.read(2048), timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - start) * 1000.0, 2)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass

        text = raw.decode("latin1", errors="ignore")
        if "200 OK" not in text and "colo=" not in text:
            return None

        colo = ""
        for line in text.splitlines():
            if line.startswith("colo="):
                colo = line.split("=", 1)[1].strip().upper()
                break

        # Score favors lower RTT + Iran-friendly Europe/Middle East PoP
        colo_bonus = 12.0 if colo in IRAN_PREFERRED_COLOS else 0.0
        score = round(max(10.0, min(100.0, 92.0 - (rtt_ms / 8.0) + colo_bonus)), 2)
        return {
            "ip": ip,
            "port": port,
            "ip_version": ipaddress.ip_address(ip).version,
            "latency_ms": rtt_ms,
            "colo": colo or "CF",
            "score": score,
            "verified_trace": True,
            "tested_at": datetime.now(timezone.utc).isoformat(),
        }
    except Exception:
        return None


async def refresh_operator_clean_pools(
    manual_overrides: dict[str, list[str]] | None = None,
    timeout_sec: float = 2.8,
) -> dict[str, list[dict[str, Any]]]:
    """
    Discovers & verifies Clean Cloudflare IPs categorized strictly per Iran ISP:
      - mci (همراه اول)
      - mtn (ایرانسل)
      - mkh (مخابرات)
    """
    results: dict[str, list[dict[str, Any]]] = {"mci": [], "mtn": [], "mkh": []}
    sem = asyncio.Semaphore(18)

    async def _probe(ip: str, source: str):
        async with sem:
            res = await verify_cloudflare_edge_ip(ip, 443, timeout_sec=timeout_sec)
            if res:
                res["source"] = source
            return res

    for op in ("mci", "mtn", "mkh"):
        candidate_map: dict[str, str] = {}

        # 1) Admin manually curated Iran-tested IPs for this operator take top priority
        for mip in (manual_overrides or {}).get(op, []):
            try:
                norm = str(ipaddress.ip_address(mip.strip()))
                candidate_map[norm] = "admin_manual"
            except ValueError:
                continue

        # 2) Resolve live Iran operator DNS sources (IPv4 A records)
        dns_domains = OPERATOR_DNS_SOURCES.get(op, [])
        resolved_lists = await asyncio.gather(*(resolve_doh_records(d, "A") for d in dns_domains))
        for dom, ips in zip(dns_domains, resolved_lists):
            for ip in ips:
                candidate_map.setdefault(ip, dom)

        # 3) Verify every unique candidate via real TLS + /cdn-cgi/trace
        probed = await asyncio.gather(*(_probe(ip, src) for ip, src in candidate_map.items()))
        valid = [p for p in probed if p is not None]
        # Prefer admin-verified or IRCF-sourced IPs, then highest score / lowest latency
        valid.sort(
            key=lambda x: (
                2 if x["source"] == "admin_manual" else (1 if "ircf" in x["source"] or "vfarid" in x["source"] else 0),
                x["score"],
                -(x["latency_ms"] or 9999),
            ),
            reverse=True,
        )
        results[op] = valid[:25]

    return results
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/wg_handshake.py
from __future__ import annotations

import asyncio
import base64
import hashlib
import ipaddress
import os
import socket
import struct
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

_CONSTRUCTION = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s"
_IDENTIFIER = b"WireGuard v1 zx2c4 Jason@zx2c4.com"
_LABEL_MAC1 = b"mac1----"


def _blake2s(data: bytes, key: bytes = b"", digest_size: int = 32) -> bytes:
    return hashlib.blake2s(data, key=key, digest_size=digest_size).digest()


def _hmac_blake2s(key: bytes, data: bytes) -> bytes:
    block_size = 64
    if len(key) > block_size:
        key = _blake2s(key)
    key = key.ljust(block_size, b"\x00")
    o_key = bytes(b ^ 0x5C for b in key)
    i_key = bytes(b ^ 0x36 for b in key)
    return _blake2s(o_key + _blake2s(i_key + data))


def _kdf2(key: bytes, inp: bytes) -> tuple[bytes, bytes]:
    t0 = _hmac_blake2s(key, inp)
    t1 = _hmac_blake2s(t0, b"\x01")
    t2 = _hmac_blake2s(t0, t1 + b"\x02")
    return t1, t2


def _aead_encrypt(key: bytes, counter: int, plaintext: bytes, aad: bytes) -> bytes:
    nonce = b"\x00\x00\x00\x00" + struct.pack("<Q", counter)
    return ChaCha20Poly1305(key).encrypt(nonce, plaintext, aad)


def _tai64n_now() -> bytes:
    ns = time.time_ns()
    secs = (ns // 1_000_000_000) + 4611686018427387914
    nsecs = ns % 1_000_000_000
    return struct.pack(">QI", secs, nsecs)


def build_wireguard_handshake_initiation(
    client_private_key_b64: str,
    peer_public_key_b64: str,
    reserved: list[int] | None = None,
) -> tuple[bytes, int]:
    s_priv_bytes = base64.b64decode(client_private_key_b64)
    r_pub_bytes = base64.b64decode(peer_public_key_b64)

    s_priv = x25519.X25519PrivateKey.from_private_bytes(s_priv_bytes)
    s_pub_bytes = s_priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    r_pub = x25519.X25519PublicKey.from_public_bytes(r_pub_bytes)

    e_priv = x25519.X25519PrivateKey.generate()
    e_pub_bytes = e_priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )

    ck = _blake2s(_CONSTRUCTION)
    h = _blake2s(ck + _IDENTIFIER)
    h = _blake2s(h + r_pub_bytes)

    ck = _hmac_blake2s(_hmac_blake2s(ck, e_pub_bytes), b"\x01")
    h = _blake2s(h + e_pub_bytes)

    dh1 = e_priv.exchange(r_pub)
    ck, k = _kdf2(ck, dh1)
    encrypted_static = _aead_encrypt(k, 0, s_pub_bytes, h)
    h = _blake2s(h + encrypted_static)

    dh2 = s_priv.exchange(r_pub)
    ck, k = _kdf2(ck, dh2)
    encrypted_timestamp = _aead_encrypt(k, 0, _tai64n_now(), h)
    h = _blake2s(h + encrypted_timestamp)

    res = (reserved or [0, 0, 0])[:3]
    sender_index = struct.unpack("<I", os.urandom(4))[0]
    header = bytes([1, res[0] & 0xFF, res[1] & 0xFF, res[2] & 0xFF]) + struct.pack("<I", sender_index)
    body = header + e_pub_bytes + encrypted_static + encrypted_timestamp

    mac1_key = _blake2s(_LABEL_MAC1 + r_pub_bytes)
    mac1 = _blake2s(body, key=mac1_key, digest_size=16)
    packet = body + mac1 + (b"\x00" * 16)
    return packet, sender_index


class _WGRespProto(asyncio.DatagramProtocol):
    def __init__(self, fut: asyncio.Future):
        self.fut = fut

    def datagram_received(self, data: bytes, addr):
        if not self.fut.done():
            self.fut.set_result(data)

    def error_received(self, exc):
        if not self.fut.done():
            self.fut.set_exception(exc)


async def probe_real_warp_handshake(
    host: str,
    port: int,
    client_private_key_b64: str,
    peer_public_key_b64: str,
    reserved: list[int] | None = None,
    timeout_sec: float = 2.0,
) -> tuple[bool, float | None]:
    """Supports BOTH IPv4 and IPv6 WireGuard Type-1 -> Type-2 UDP Handshake verification."""
    loop = asyncio.get_running_loop()
    transport = None
    try:
        clean_host = host.strip("[]")
        family = socket.AF_INET6 if ipaddress.ip_address(clean_host).version == 6 else socket.AF_INET
        packet, sender_idx = build_wireguard_handshake_initiation(
            client_private_key_b64, peer_public_key_b64, reserved=reserved
        )
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(
            loop.create_datagram_endpoint(
                lambda: _WGRespProto(fut),
                remote_addr=(clean_host, port),
                family=family,
            ),
            timeout=timeout_sec,
        )
        start = time.perf_counter()
        transport.sendto(packet)
        resp: bytes = await asyncio.wait_for(fut, timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - start) * 1000.0, 2)
        if len(resp) >= 92 and resp[0] == 2:
            recv_idx = struct.unpack("<I", resp[8:12])[0]
            if recv_idx == sender_idx:
                return True, rtt_ms
        return False, None
    except Exception:
        return False, None
    finally:
        if transport is not None:
            transport.close()
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/warp_builder.py
from __future__ import annotations

import base64
import json
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

# Official Cloudflare WARP IPv6 Anycast Endpoints (2606:4700:d0::/48 & d1::/48)
OFFICIAL_WARP_IPV6_ENDPOINTS = [
    "[2606:4700:d0::a29f:c001]:2408",
    "[2606:4700:d0::a29f:c005]:854",
    "[2606:4700:d0::a29f:c008]:894",
    "[2606:4700:d1::a29f:c101]:2408",
    "[2606:4700:d1::a29f:c10a]:908",
    "[2606:4700:d0::a29f:c301]:1074",
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
    priv_b64 = base64.b64encode(
        priv.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
    ).decode("ascii")
    pub_b64 = base64.b64encode(
        pub.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
    ).decode("ascii")
    return priv_b64, pub_b64


async def register_real_warp_device(timeout_sec: float = 12.0) -> WarpRegistration:
    priv_key, pub_key = generate_x25519_keypair()
    payload = {
        "key": pub_key,
        "install_id": "",
        "fcm_token": "",
        "tos": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "model": "Android",
        "serial_number": "",
        "locale": "en_US",
    }
    headers = {
        "User-Agent": "okhttp/3.12.1",
        "CF-Client-Version": "a-6.33-3874",
        "Content-Type": "application/json; charset=UTF-8",
    }

    last_err = "Cloudflare WARP API در دسترس نبود."
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        for reg_url in WARP_REG_URLS:
            try:
                resp = await client.post(reg_url, json=payload, headers=headers)
                if resp.status_code not in (200, 201):
                    last_err = f"HTTP {resp.status_code}"
                    continue
                data = resp.json()
                dev_id = data.get("id", "")
                token = data.get("token", "")
                cfg = data.get("config") or {}
                peers = cfg.get("peers") or [{}]
                iface = cfg.get("interface", {}).get("addresses") or {}
                client_id_b64 = cfg.get("client_id", "")
                reserved = list(base64.b64decode(client_id_b64)[:3]) if client_id_b64 else [0, 0, 0]

                warp_activated = False
                if dev_id and token:
                    try:
                        act = await client.patch(
                            f"{reg_url}/{dev_id}",
                            json={"warp_enabled": True},
                            headers={**headers, "Authorization": f"Bearer {token}"},
                        )
                        warp_activated = act.status_code in (200, 201)
                    except Exception:
                        warp_activated = False

                ipv4 = iface.get("v4", "172.16.0.2")
                ipv6 = iface.get("v6", "")
                peer_pub = peers[0].get("public_key") or OFFICIAL_WARP_PEER_PUBKEY
                return WarpRegistration(
                    ok=True,
                    private_key=priv_key,
                    public_key=pub_key,
                    peer_public_key=peer_pub,
                    ipv4=f"{ipv4}/32" if "/" not in ipv4 else ipv4,
                    ipv6=f"{ipv6}/128" if ipv6 and "/" not in ipv6 else ipv6,
                    reserved=reserved,
                    device_id=dev_id,
                    token=token,
                    warp_activated=warp_activated,
                )
            except Exception as exc:
                last_err = str(exc)

    return WarpRegistration(ok=False, error=f"خطا در ثبت دستگاه WARP: {last_err}")


def split_endpoint(ep: str) -> tuple[str, int]:
    """Safely splits both IPv4 `1.2.3.4:2408` and IPv6 `[2606:4700:d0::a29f:c001]:2408`."""
    ep = ep.strip()
    if ep.startswith("["):
        host, port_s = ep.rsplit("]:", 1)
        return host[1:], int(port_s)
    host, port_s = ep.rsplit(":", 1)
    return host, int(port_s)


def format_endpoint_hostport(host: str, port: int) -> str:
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def format_beautiful_name(
    prefix: str,
    proto: str,
    ping_ms: float | None = None,
    extra: str = "",
) -> str:
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
    reg: WarpRegistration,
    ep_v4: str,
    ep_v6: str,
    platform: PlatformType,
    ip_mode: IPMode = "ipv6",
    ping_ms: float | None = None,
    brand: str = "CFHub",
) -> dict:
    """
    Generates clean, verified IPv4 / IPv6 / Dual-Stack WARP + WireGuard configs:
      - Standard `wireguard://` URI (properly brackets IPv6 endpoints + Dual-Stack interface address)
      - Hiddify `warp://auto` (IPv4/IPv6 ISP scanner on user's device!)
      - Hiddify `WoW` (Warp-in-Warp chaining IPv4 -> IPv6 or IPv6 -> IPv4!)
      - Xray-core JSON with WireGuard + UDP Noise (for v2rayNG / v2rayN)
      - AmneziaWG `.conf` with Jc/Jmin/Jmax anti-DPI headers + Dual-Stack IPv4/IPv6 support
    """
    h4, p4 = split_endpoint(ep_v4)
    h6, p6 = split_endpoint(ep_v6)

    if ip_mode == "ipv6":
        primary_hp = format_endpoint_hostport(h6, p6)
        secondary_hp = format_endpoint_hostport(h4, p4)
        mode_tag = "🌐IPv6"
        dns_strategy = "UseIPv6"
        noise_apply = "ipv6"
        local_addrs = [a for a in [reg.ipv4, reg.ipv6] if a]
        allowed_ips = ["0.0.0.0/0", "::/0"]
        wg_dns = "2606:4700:4700::1111, 1.1.1.1"
    elif ip_mode == "dual":
        primary_hp = format_endpoint_hostport(h4, p4)
        secondary_hp = format_endpoint_hostport(h6, p6)
        mode_tag = "⚡Dual-v4/v6"
        dns_strategy = "UseIP"
        noise_apply = "ip"
        local_addrs = [a for a in [reg.ipv4, reg.ipv6] if a]
        allowed_ips = ["0.0.0.0/0", "::/0"]
        wg_dns = "1.1.1.1, 2606:4700:4700::1111"
    else:
        primary_hp = format_endpoint_hostport(h4, p4)
        secondary_hp = format_endpoint_hostport(h6, p6)
        mode_tag = "🌐IPv4"
        dns_strategy = "UseIPv4"
        noise_apply = "ipv4"
        local_addrs = [reg.ipv4]
        allowed_ips = ["0.0.0.0/0"]
        wg_dns = "1.1.1.1, 8.8.8.8"

    mtu = 1280
    reserved = reg.reserved or [0, 0, 0]
    reserved_csv = ",".join(str(x) for x in reserved)
    plat_tag = {"ios": "🍏iOS", "android": "🤖Android", "windows": "🪟Win"}[platform]

    wg_label = format_beautiful_name(f"🛡️{brand}", f"WARP-{mode_tag}", ping_ms, plat_tag)
    wow_label = format_beautiful_name(f"🌀{brand}", f"WoW-{mode_tag}", ping_ms, plat_tag)
    auto_label = format_beautiful_name(f"🎯{brand}", f"Auto-{mode_tag}", None, plat_tag)

    # 1) Clean standard wireguard:// URI
    wg_query = urlencode({
        "address": ",".join(local_addrs),
        "reserved": reserved_csv,
        "publickey": reg.peer_public_key,
        "mtu": str(mtu),
    })
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{primary_hp}?{wg_query}#{quote(wg_label)}"

    # 2) Hiddify Auto-Scan WARP URI (scans user's own ISP locally in Iran!)
    warp_auto_uri = f"warp://auto?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(auto_label)}"

    # 3) Hiddify Warp-in-Warp (WoW) chaining primary + secondary (v4+v6!)
    wow_uri = (
        f"warp://{primary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(wow_label)}"
        f"&&detour=warp://{secondary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10#{quote(f'🌍Exit•{brand}')}"
    )

    # 4) Full Xray-core WireGuard + UDP Noise JSON (for v2rayNG / v2rayN)
    xray_json = json.dumps(
        {
            "remarks": wg_label,
            "log": {"loglevel": "warning"},
            "dns": {
                "servers": ["https://1.1.1.1/dns-query", "1.1.1.1"],
                "queryStrategy": dns_strategy,
            },
            "inbounds": [
                {
                    "tag": "socks",
                    "port": 10808,
                    "listen": "127.0.0.1",
                    "protocol": "socks",
                    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
                    "settings": {"auth": "noauth", "udp": True},
                }
            ],
            "outbounds": [
                {
                    "tag": "proxy",
                    "protocol": "wireguard",
                    "settings": {
                        "secretKey": reg.private_key,
                        "address": local_addrs,
                        "peers": [
                            {
                                "publicKey": reg.peer_public_key,
                                "allowedIPs": allowed_ips,
                                "endpoint": primary_hp,
                                "keepAlive": 25,
                            }
                        ],
                        "reserved": reserved,
                        "mtu": mtu,
                        "noKernelTun": True,
                    },
                    "streamSettings": {"sockopt": {"dialerProxy": "noise-out"}},
                },
                {
                    "tag": "noise-out",
                    "protocol": "freedom",
                    "settings": {
                        "noises": [
                            {"type": "rand", "packet": "10-30", "delay": "10-25", "applyTo": noise_apply}
                        ]
                    },
                },
                {"tag": "direct", "protocol": "freedom"},
            ],
        },
        indent=2,
        ensure_ascii=False,
    )

    # 5) AmneziaWG .conf (IPv4 / IPv6 / Dual-Stack)
    amnezia_conf = "\n".join([
        f"# {wg_label}",
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {', '.join(local_addrs)}",
        f"DNS = {wg_dns}",
        f"MTU = {mtu}",
        "Jc = 4",
        "Jmin = 40",
        "Jmax = 70",
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
        "secondary_endpoint": secondary_hp,
        "wireguard_uri": wireguard_uri,
        "warp_auto_uri": warp_auto_uri,
        "wow_uri": wow_uri,
        "xray_json": xray_json,
        "xray_filename": f"cfhub_warp_{ip_mode}_{platform}.json",
        "amnezia_conf": amnezia_conf,
        "amnezia_filename": f"cfhub_amneziawg_{ip_mode}_{platform}.conf",
        "reserved": reserved,
    }
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import logging
import random
from datetime import datetime, timezone
from typing import Any

from app.bot.operator_scanner import refresh_operator_clean_pools
from app.bot.warp_builder import (
    OFFICIAL_WARP_IPV6_ENDPOINTS,
    OFFICIAL_WARP_PEER_PUBKEY,
    register_real_warp_device,
    split_endpoint,
)
from app.bot.wg_handshake import probe_real_warp_handshake

logger = logging.getLogger(__name__)

WARP_V4_PREFIXES = ["162.159.192", "162.159.193", "162.159.195", "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
WARP_UDP_PORTS = [2408, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 945, 955, 1002, 1018, 1074, 1701, 1843, 2371, 4500]


def generate_warp_v4_candidates(count: int = 28) -> list[tuple[str, int]]:
    base = [
        ("162.159.192.1", 2408),
        ("162.159.192.8", 854),
        ("162.159.193.1", 2408),
        ("162.159.193.10", 894),
        ("162.159.195.1", 2408),
        ("162.159.195.5", 908),
        ("188.114.96.1", 2408),
        ("188.114.97.1", 1074),
        ("188.114.98.1", 939),
        ("188.114.99.1", 1843),
    ]
    seen = set(base)
    while len(base) < count:
        pair = (f"{random.choice(WARP_V4_PREFIXES)}.{random.randint(1, 250)}", random.choice(WARP_UDP_PORTS))
        if pair not in seen:
            seen.add(pair)
            base.append(pair)
    return base


class BackgroundScannerEngine:
    """
    Clean autonomous background scanner:
      - Phase 1: Iran Operator Clean IP discovery & /cdn-cgi/trace verification (MCI / Irancell / Mokhaberat)
      - Phase 2: Real WireGuard Noise_IKpsk2 UDP Handshake verification (IPv4 + IPv6)
    """

    def __init__(self, store):
        self.store = store
        self._loop_task: asyncio.Task | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.last_scan_at: str | None = None
        self.last_error: str | None = None

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v6")

    async def stop(self) -> None:
        if self._loop_task and not self._loop_task.done():
            self._loop_task.cancel()
            try:
                await self._loop_task
            except asyncio.CancelledError:
                pass

    async def _ensure_probe_device(self) -> dict | None:
        dev = self.store.data.get("warp_probe_device")
        if dev and dev.get("private_key"):
            return dev
        reg = await register_real_warp_device(timeout_sec=10.0)
        if not reg.ok:
            return None
        dev = {
            "private_key": reg.private_key,
            "peer_public_key": reg.peer_public_key or OFFICIAL_WARP_PEER_PUBKEY,
            "reserved": reg.reserved or [0, 0, 0],
        }
        self.store.data["warp_probe_device"] = dev
        self.store.save()
        return dev

    async def _scheduler_loop(self) -> None:
        await asyncio.sleep(2)
        while True:
            try:
                if self.store.data["settings"].get("auto_scan_enabled", True) and not self.is_scanning:
                    await self.run_full_cycle(trigger="auto")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception("V6 background scan error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_full_cycle(self, trigger: str = "manual") -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async with self._scan_lock:
            self.is_scanning = True
            self.last_error = None
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                # --- PHASE 1: Operator-Categorized Clean IP Discovery & /cdn-cgi/trace Verification ---
                self.current_stage = "operator_ips"
                manual = self.store.data.get("manual_operator_ips", {})
                op_pools = await refresh_operator_clean_pools(manual_overrides=manual, timeout_sec=timeout_sec)

                for op in ("mci", "mtn", "mkh"):
                    if op_pools.get(op):
                        self.store.data["operator_pools"][op] = op_pools[op]

                # Auto-apply freshest IP for each user's selected operator
                if self.store.data["settings"].get("auto_apply_ip", True):
                    for panel in self.store.data.get("panels", {}).values():
                        if panel.get("auto_ip", True):
                            op = panel.get("operator", "mci")
                            best = self.get_best_operator_ips(op, 1)
                            if best:
                                panel["clean_ip"] = best[0]["ip"]

                # --- PHASE 2: Real WireGuard UDP Handshake Scan (IPv4 + IPv6) ---
                self.current_stage = "warp_udp"
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                v4_verified: list[dict] = []
                v6_verified: list[dict] = []

                if probe_dev:
                    sem = asyncio.Semaphore(12)

                    async def _test_pair(host: str, port: int, version: int):
                        async with sem:
                            ok, rtt = await probe_real_warp_handshake(
                                host, port, probe_dev["private_key"],
                                probe_dev["peer_public_key"],
                                reserved=probe_dev["reserved"],
                                timeout_sec=timeout_sec,
                            )
                            if not ok or rtt is None:
                                return None
                            ep_str = f"[{host}]:{port}" if version == 6 else f"{host}:{port}"
                            return {
                                "endpoint": ep_str,
                                "host": host,
                                "port": port,
                                "ip_version": version,
                                "latency_ms": rtt,
                                "handshake_verified": True,
                                "tested_at": now.isoformat(),
                            }

                    v4_tasks = [_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(28)]
                    v6_pairs = [split_endpoint(ep) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS]
                    v6_tasks = [_test_pair(h, p, 6) for h, p in v6_pairs]

                    v4_res, v6_res = await asyncio.gather(asyncio.gather(*v4_tasks), asyncio.gather(*v6_tasks))
                    v4_verified = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                    v6_verified = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]

                    if v4_verified:
                        self.store.data["warp_v4_pool"] = v4_verified
                    if v6_verified:
                        self.store.data["warp_v6_pool"] = v6_verified

                self.last_scan_at = now.isoformat()
                summary = {
                    "trigger": trigger,
                    "finished_at": self.last_scan_at,
                    "mci": len(self.store.data["operator_pools"].get("mci", [])),
                    "mtn": len(self.store.data["operator_pools"].get("mtn", [])),
                    "mkh": len(self.store.data["operator_pools"].get("mkh", [])),
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
                self.store.save()
                return summary
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    def get_best_operator_ips(self, op: str = "mci", count: int = 5) -> list[dict[str, Any]]:
        pools = self.store.data.get("operator_pools", {})
        if op == "all":
            merged = []
            for k in ("mci", "mtn", "mkh"):
                for item in pools.get(k, [])[:2]:
                    copy = dict(item)
                    copy["operator"] = k
                    merged.append(copy)
            return merged[:count]
        items = list(pools.get(op, []))[:count]
        for it in items:
            it["operator"] = op
        return items

    def get_best_warp_endpoints(self) -> tuple[str, str, float | None]:
        v4_pool = self.store.data.get("warp_v4_pool", [])
        v6_pool = self.store.data.get("warp_v6_pool", [])
        ep4 = v4_pool[0]["endpoint"] if v4_pool else "162.159.192.1:2408"
        ep6 = v6_pool[0]["endpoint"] if v6_pool else OFFICIAL_WARP_IPV6_ENDPOINTS[0]
        ping = v4_pool[0]["latency_ms"] if v4_pool else (v6_pool[0]["latency_ms"] if v6_pool else None)
        return ep4, ep6, ping
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/store.py
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
            "users": {},
            "cf_accounts": {},
            "panels": {},
            "operator_pools": {"mci": [], "mtn": [], "mkh": []},
            "manual_operator_ips": {"mci": [], "mtn": [], "mkh": []},
            "warp_v4_pool": [],
            "warp_v6_pool": [],
            "warp_probe_device": None,
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "default_proxy_ip": "proxyip.cmliussss.net",
                "maintenance_mode": False,
                "auto_apply_ip": True,
                "auto_scan_enabled": True,
                "auto_scan_interval_hours": 6,
                "scan_timeout_sec": 2.6,
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
                    "telegram_id": tg_id,
                    "username": username or "",
                    "full_name": full_name or "",
                    "lang": "fa",
                    "operator": "mci",
                    "is_banned": False,
                    "joined_at": now,
                    "last_seen": now,
                    "configs_generated": 0,
                    "warp_generated": 0,
                }
                self.data["users"][key] = u
            else:
                u["username"] = username or u.get("username", "")
                u["full_name"] = full_name or u.get("full_name", "")
                u["last_seen"] = now
                u.setdefault("lang", "fa")
                u.setdefault("operator", "mci")
                u.setdefault("warp_generated", 0)
            self.save()
            return u

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
                "is_banned": banned, "joined_at": now, "last_seen": now,
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
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/cf_manager.py
from __future__ import annotations

import json
import random
import string
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urlencode

import httpx

from app.bot.operator_scanner import OPERATOR_LABELS
from app.bot.warp_builder import format_beautiful_name
from app.bot.worker_template import render_worker_script


@dataclass
class CloudflareDeployResult:
    ok: bool
    account_id: str | None = None
    account_name: str | None = None
    script_name: str | None = None
    worker_host: str | None = None
    sub_url: str | None = None
    health_verified: bool = False
    health_latency_ms: float | None = None
    error: str | None = None


class CloudflarePanelService:
    """Deploys a REAL dual-protocol (VLESS + Trojan) Cloudflare Worker and builds operator-categorized configs."""

    BASE = "https://api.cloudflare.com/client/v4"

    async def deploy_dual_worker(
        self,
        api_token: str,
        user_uuid: str,
        trojan_password: str,
        script_name: str,
        proxy_ip: str = "proxyip.cmliussss.net",
        operator_pools: dict | None = None,
        brand: str = "CFHub",
    ) -> CloudflareDeployResult:
        token = api_token.strip()
        headers = {"Authorization": f"Bearer {token}"}
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                r_ver = await client.get(f"{self.BASE}/user/tokens/verify", headers=headers)
                d_ver = r_ver.json()
                if r_ver.status_code != 200 or not d_ver.get("success"):
                    err = (d_ver.get("errors") or [{"message": f"HTTP {r_ver.status_code}"}])[0].get("message")
                    return CloudflareDeployResult(ok=False, error=f"توکن نامعتبر: {err}")
                if (d_ver.get("result") or {}).get("status") != "active":
                    return CloudflareDeployResult(ok=False, error="توکن غیرفعال یا منقضی است.")

                r_acc = await client.get(f"{self.BASE}/accounts", headers=headers, params={"per_page": 5})
                accs = r_acc.json().get("result") or []
                if r_acc.status_code != 200 or not accs:
                    return CloudflareDeployResult(ok=False, error="دسترسی Account در توکن وجود ندارد.")
                account_id = accs[0]["id"]
                account_name = accs[0].get("name") or "Cloudflare"

                subdomain = None
                r_sub = await client.get(f"{self.BASE}/accounts/{account_id}/workers/subdomain", headers=headers)
                if r_sub.status_code == 200 and r_sub.json().get("success"):
                    subdomain = (r_sub.json().get("result") or {}).get("subdomain")
                if not subdomain:
                    cand = f"cfhub-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"
                    r_cr = await client.put(
                        f"{self.BASE}/accounts/{account_id}/workers/subdomain",
                        headers={**headers, "Content-Type": "application/json"},
                        json={"subdomain": cand},
                    )
                    if r_cr.status_code in (200, 201) and r_cr.json().get("success"):
                        subdomain = (r_cr.json().get("result") or {}).get("subdomain", cand)
                    else:
                        return CloudflareDeployResult(ok=False, error="لطفاً یک‌بار در داشبورد کلودفلر وارد Workers & Pages شوید تا ساب‌دامنه رایگان workers.dev ساخته شود.")

                worker_js = render_worker_script(
                    user_uuid=user_uuid,
                    trojan_password=trojan_password,
                    proxy_ip=proxy_ip,
                    operator_pools=operator_pools,
                    brand=brand,
                )
                metadata = json.dumps({"main_module": "worker.js", "compatibility_date": "2024-11-01"})
                files = {
                    "metadata": (None, metadata, "application/json"),
                    "worker.js": ("worker.js", worker_js.encode("utf-8"), "application/javascript+module"),
                }
                r_put = await client.put(
                    f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}",
                    headers=headers,
                    files=files,
                )
                d_put = r_put.json()
                if r_put.status_code not in (200, 201) or not d_put.get("success"):
                    err = (d_put.get("errors") or [{"message": f"HTTP {r_put.status_code}"}])[0].get("message")
                    return CloudflareDeployResult(ok=False, error=f"خطا در دیپلوی Worker: {err}")

                await client.post(
                    f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}/subdomain",
                    headers={**headers, "Content-Type": "application/json"},
                    json={"enabled": True},
                )

                worker_host = f"{script_name}.{subdomain}.workers.dev"
                sub_url = f"https://{worker_host}/sub/{user_uuid}"
                health_ok, lat_ms = await self.verify_worker_live(worker_host)

                return CloudflareDeployResult(
                    ok=True,
                    account_id=account_id,
                    account_name=account_name,
                    script_name=script_name,
                    worker_host=worker_host,
                    sub_url=sub_url,
                    health_verified=health_ok,
                    health_latency_ms=lat_ms,
                )
        except Exception as exc:
            return CloudflareDeployResult(ok=False, error=f"خطا در اتصال به کلودفلر: {exc}")

    @staticmethod
    async def verify_worker_live(worker_host: str) -> tuple[bool, float | None]:
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                t0 = time.perf_counter()
                r = await client.get(f"https://{worker_host}/health")
                ms = round((time.perf_counter() - t0) * 1000.0, 1)
                if r.status_code == 200 and r.json().get("ok") is True:
                    return True, ms
        except Exception:
            pass
        return False, None

    @staticmethod
    def build_vless_uri(
        panel: dict[str, Any],
        ip: str,
        operator: str = "mci",
        ping_ms: float | None = None,
        colo: str = "",
        with_fragment: bool = False,
    ) -> str:
        host_part = f"[{ip}]" if ":" in ip else ip
        path = panel.get("path", "/?ed=2048")
        if panel.get("proxy_ip") and "proxyip=" not in path.lower():
            sep = "&" if "?" in path else "?"
            path = f"{path}{sep}proxyip={panel['proxy_ip']}"
        params = {
            "encryption": "none",
            "security": "tls",
            "type": "ws",
            "host": panel["host"],
            "sni": panel["sni"],
            "path": path,
            "fp": "chrome",
            "alpn": "http/1.1",
        }
        if with_fragment:
            params["fragment"] = "10-50,10-20,tlshello"
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        tag = format_beautiful_name(op_lbl, "VLESS", ping_ms, f"{colo}•{panel.get('name', 'CFHub')}" if colo else panel.get("name", "CFHub"))
        return f"vless://{panel['uuid']}@{host_part}:443?{urlencode(params)}#{quote(tag)}"

    @staticmethod
    def build_trojan_uri(
        panel: dict[str, Any],
        ip: str,
        operator: str = "mci",
        ping_ms: float | None = None,
        colo: str = "",
        with_fragment: bool = False,
    ) -> str:
        host_part = f"[{ip}]" if ":" in ip else ip
        path = panel.get("path", "/?ed=2048")
        if panel.get("proxy_ip") and "proxyip=" not in path.lower():
            sep = "&" if "?" in path else "?"
            path = f"{path}{sep}proxyip={panel['proxy_ip']}"
        params = {
            "security": "tls",
            "type": "ws",
            "host": panel["host"],
            "sni": panel["sni"],
            "path": path,
            "fp": "chrome",
            "alpn": "http/1.1",
        }
        if with_fragment:
            params["fragment"] = "10-50,10-20,tlshello"
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        tag = format_beautiful_name(op_lbl, "Trojan", ping_ms, f"{colo}•{panel.get('name', 'CFHub')}" if colo else panel.get("name", "CFHub"))
        tpass = quote(panel["trojan_password"], safe="")
        return f"trojan://{tpass}@{host_part}:443?{urlencode(params)}#{quote(tag)}"

    @staticmethod
    def build_xray_fragment_json(
        panel: dict[str, Any],
        ip: str,
        protocol: str = "vless",
        operator: str = "mci",
        ping_ms: float | None = None,
    ) -> str:
        """Full Xray-core JSON with TLS ClientHello Fragment (supports both VLESS and Trojan)."""
        path = panel.get("path", "/?ed=2048")
        if panel.get("proxy_ip") and "proxyip=" not in path.lower():
            sep = "&" if "?" in path else "?"
            path = f"{path}{sep}proxyip={panel['proxy_ip']}"
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        remarks = format_beautiful_name(op_lbl, f"{protocol.upper()}-Fragment", ping_ms, panel.get("name", "CFHub"))

        if protocol == "trojan":
            out_settings = {
                "servers": [{"address": ip, "port": 443, "password": panel["trojan_password"]}]
            }
        else:
            out_settings = {
                "vnext": [{"address": ip, "port": 443, "users": [{"id": panel["uuid"], "encryption": "none"}]}]
            }

        cfg = {
            "remarks": remarks,
            "log": {"loglevel": "warning"},
            "dns": {"servers": ["https://1.1.1.1/dns-query", "8.8.8.8"]},
            "inbounds": [
                {
                    "tag": "socks",
                    "port": 10808,
                    "listen": "127.0.0.1",
                    "protocol": "socks",
                    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
                    "settings": {"auth": "noauth", "udp": True},
                }
            ],
            "outbounds": [
                {
                    "tag": "proxy",
                    "protocol": protocol,
                    "settings": out_settings,
                    "streamSettings": {
                        "network": "ws",
                        "security": "tls",
                        "tlsSettings": {"serverName": panel["sni"], "fingerprint": "chrome", "alpn": ["http/1.1"]},
                        "wsSettings": {"path": path, "headers": {"Host": panel["host"]}},
                        "sockopt": {"dialerProxy": "fragment-out", "tcpKeepAliveIdle": 100},
                    },
                },
                {
                    "tag": "fragment-out",
                    "protocol": "freedom",
                    "settings": {"fragment": {"packets": "tlshello", "length": "10-50", "interval": "10-20"}},
                },
                {"tag": "direct", "protocol": "freedom"},
            ],
        }
        return json.dumps(cfg, indent=2, ensure_ascii=False)
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/ui.py
from __future__ import annotations

from typing import Literal

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

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
    "%5D&accountId=*&zoneId=all&name=CFHubV6"
)
CLOUDFLARE_SIGNUP_URL = "https://dash.cloudflare.com/sign-up"

_NATIVE_STYLE = "style" in getattr(InlineKeyboardButton, "model_fields", {})


class StyledButton(InlineKeyboardButton):
    style: str | None = None


def btn(
    text: str,
    *,
    callback_data: str | None = None,
    url: str | None = None,
    style: ButtonStyle | None = None,
) -> InlineKeyboardButton:
    kwargs: dict = {"text": text}
    if callback_data is not None:
        kwargs["callback_data"] = callback_data
    if url is not None:
        kwargs["url"] = url
    if style is not None:
        kwargs["style"] = style
    if _NATIVE_STYLE or style is None:
        return InlineKeyboardButton(**kwargs)
    return StyledButton(**kwargs)


def kb(rows: list[list[InlineKeyboardButton]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=rows)


def main_menu_kb(is_admin: bool = False, has_panel: bool = False, lang: str = "fa") -> InlineKeyboardMarkup:
    if lang == "en":
        top = (
            [btn("🎛️ My Panel (VLESS + Trojan)", callback_data="m:mypanel", style="success")]
            if has_panel
            else [btn("🚀 Create Free Panel (VLESS + Trojan)", callback_data="m:turbo", style="success")]
        )
        rows = [
            top,
            [btn("🛡️ WARP / WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
            [btn("📶 Clean IPs by ISP (MCI / Irancell / TCI)", callback_data="m:isp", style="primary")],
            [
                btn("📱 Apps", callback_data="m:apps", style="primary"),
                btn("📖 Guide", callback_data="m:guide", style="primary"),
            ],
            [
                btn("💬 Support", callback_data="m:support", style="primary"),
                btn("🇮🇷 فارسی", callback_data="m:lang", style="primary"),
            ],
        ]
        if is_admin:
            rows.append([btn("🛠️ Admin Panel", callback_data="adm:home", style="danger")])
        return kb(rows)

    # Clean, minimal, zero-clutter Persian menu focused 100% on working free configs
    top = (
        [btn("🎛️ پنل من (VLESS + Trojan فعال)", callback_data="m:mypanel", style="success")]
        if has_panel
        else [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")]
    )
    rows = [
        top,
        [btn("🛡️ کانفیگ‌های WARP و WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
        [btn("📶 آی‌پی تمیز اپراتورها (همراه اول • ایرانسل • مخابرات)", callback_data="m:isp", style="primary")],
        [
            btn("📱 دانلود برنامه‌ها", callback_data="m:apps", style="primary"),
            btn("📖 آموزش اتصال", callback_data="m:guide", style="primary"),
        ],
        [
            btn("💬 پشتیبانی", callback_data="m:support", style="primary"),
            btn("🌐 English", callback_data="m:lang", style="primary"),
        ],
    ]
    if is_admin:
        rows.append([btn("🛠️ پنل مدیریت", callback_data="adm:home", style="danger")])
    return kb(rows)


def back_home_kb(back_cb: str = "m:home", lang: str = "fa") -> InlineKeyboardMarkup:
    lbl = "🔙 بازگشت" if lang == "fa" else "🔙 Back"
    return kb([[btn(lbl, callback_data=back_cb, style="primary")]])
__CFHUB_V6_EOF__

cat <<'__CFHUB_V6_EOF__' > backend/app/bot/bot.py
from __future__ import annotations

import asyncio
import base64
import html
import logging
import random
import secrets
import string
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
from app.bot.cf_manager import CloudflarePanelService
from app.bot.operator_scanner import OPERATOR_LABELS
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
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.protocols.base import generate_qr_png_base64
from app.services.monitoring import collect_system_health

logger = logging.getLogger(__name__)
router = Router()

store = PersistentHubStore()
bg_engine = BackgroundScannerEngine(store)
cf_service = CloudflarePanelService()


class Flow(StatesGroup):
    waiting_cf_token = State()
    waiting_panel_name = State()
    waiting_panel_proxyip = State()
    waiting_support_msg = State()
    adm_import_op_ips = State()
    adm_user_search = State()
    adm_dm_text = State()
    adm_broadcast = State()
    adm_set_support = State()


def _is_admin(tg_id: int) -> bool:
    return tg_id in set(get_settings().owner_telegram_ids)


def _has_panel(tg_id: int) -> bool:
    return str(tg_id) in store.data.get("panels", {})


async def _edit(cb: CallbackQuery, text: str, markup) -> None:
    if not cb.message:
        return
    try:
        await cb.message.edit_text(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)
    except TelegramBadRequest as exc:
        if "message is not modified" in str(exc).lower():
            return
        await cb.message.answer(text, reply_markup=markup, parse_mode="HTML", disable_web_page_preview=True)


async def _send_qr(target_msg: Message, payload: str, caption: str, markup) -> None:
    uri = generate_qr_png_base64(payload)
    if uri.startswith("data:image/png;base64,"):
        raw = base64.b64decode(uri.split(",", 1)[1])
        await target_msg.answer_photo(
            photo=BufferedInputFile(raw, filename="qr_code.png"),
            caption=caption[:1020],
            parse_mode="HTML",
            reply_markup=markup,
        )
    else:
        await target_msg.answer(caption, parse_mode="HTML", reply_markup=markup)


def _home_text(tg_id: int) -> str:
    pools = store.data.get("operator_pools", {})
    mci_c = len(pools.get("mci", []))
    mtn_c = len(pools.get("mtn", []))
    mkh_c = len(pools.get("mkh", []))
    w4_c = len(store.data.get("warp_v4_pool", []))
    w6_c = len(store.data.get("warp_v6_pool", []))
    panel = store.data.get("panels", {}).get(str(tg_id))

    panel_line = (
        f"🎛️ پنل شما: 🟢 <b>فعال</b> (<code>{html.escape(panel['host'])}</code>)"
        if panel
        else "🎛️ پنل شما: ⚪ هنوز ساخته نشده"
    )
    return (
        "⚡ <b>Cloudflare Config Hub — کانفیگ رایگان و سالم</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{mci_c}</b> IP | 🟡 ایرانسل: <b>{mtn_c}</b> IP | 🟢 مخابرات: <b>{mkh_c}</b> IP\n"
        f"🛡️ رله WARP فعال: <b>{w4_c}</b> IPv4 • <b>{w6_c}</b> IPv6\n"
        f"{panel_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 بخش مورد نظر را انتخاب کنید:"
    )


# ==================== START, HOME & LANGUAGE ====================
@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    u = message.from_user
    if not u:
        return
    store.touch_user(u.id, u.username, u.full_name)
    if store.is_banned(u.id) and not _is_admin(u.id):
        await message.answer("🚫 دسترسی شما مسدود شده است.")
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(u.id):
        await message.answer("🛠️ ربات موقتاً در حال به‌روزرسانی است.")
        return
    await message.answer(
        _home_text(u.id),
        reply_markup=main_menu_kb(_is_admin(u.id), _has_panel(u.id), store.get_lang(u.id)),
        parse_mode="HTML",
    )


@router.message(Command("admin"))
async def cmd_admin(message: Message, state: FSMContext) -> None:
    await state.clear()
    if not message.from_user or not _is_admin(message.from_user.id):
        return
    text, markup = _build_admin_dashboard()
    await message.answer(text, reply_markup=markup, parse_mode="HTML")


@router.callback_query(F.data == "m:home")
async def cb_home(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    uid = cb.from_user.id
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid)))


@router.callback_query(F.data == "m:lang")
async def cb_lang(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    lang = store.toggle_lang(uid)
    await cb.answer("EN" if lang == "en" else "فارسی")
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), lang))


# ==================== 1. TURBO PANEL (REAL DUAL VLESS + TROJAN DEPLOYMENT) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    uid = cb.from_user.id
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت پنل رایگان (VLESS + Trojan واقعی روی کلودفلر)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلادفلر نداری، اول ثبت‌نام کن.\n"
        "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن (دسترسی‌ها آماده است).\n"
        "3️⃣ در کلادفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "✨ ربات به‌صورت خودکار Worker واقعی <b>VLESS + Trojan</b> با دسته‌بندی همراه اول، ایرانسل و مخابرات روی اکانت شما دیپلوی می‌کند.\n"
        "🔐 <i>پیام توکن بلافاصله از چت پاک و رمزنگاری می‌شود.</i>"
    )
    rows = [
        [btn("🔑 دریافت مستقیم توکن کلودفلر", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
        [btn("🌐 ثبت‌نام رایگان کلودفلر", url=CLOUDFLARE_SIGNUP_URL, style="primary")],
    ]
    if _has_panel(uid):
        rows.append([btn("🎛️ ورود به پنل من", callback_data="m:mypanel", style="primary")])
    rows.append([btn("🔙 بازگشت", callback_data="m:home", style="danger")])
    await _edit(cb, text, kb(rows))


@router.message(Flow.waiting_cf_token)
async def handle_cf_token(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    raw_token = (message.text or "").strip()
    try:
        await message.delete()
    except Exception:
        pass

    if len(raw_token) < 20 or " " in raw_token:
        await message.answer(
            "⚠️ فرمت توکن نامعتبر است. توکن را بدون فاصله ارسال کنید:",
            reply_markup=kb([
                [btn("🔑 دریافت مستقیم توکن", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    wait_msg = await message.answer("⏳ <b>در حال دیپلوی Worker دوپروتکله (VLESS + Trojan) روی کلودفلر شما...</b>", parse_mode="HTML")

    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    script_name = old.get("script_name") or f"cfhub-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"
    brand = old.get("name") or "CFHub"
    proxy_ip = old.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.cmliussss.net")
    op_pools = store.data.get("operator_pools", {})

    dep = await cf_service.deploy_dual_worker(
        api_token=raw_token,
        user_uuid=panel_uuid,
        trojan_password=trojan_pass,
        script_name=script_name,
        proxy_ip=proxy_ip,
        operator_pools=op_pools,
        brand=brand,
    )
    if not dep.ok:
        await wait_msg.edit_text(
            f"❌ <b>دیپلوی ناموفق بود:</b>\n<code>{html.escape(dep.error or '')}</code>",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔑 ساخت مجدد توکن مستقیم", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    now = datetime.now(timezone.utc).isoformat()
    store.data["cf_accounts"][str(uid)] = {
        "encrypted_token": store.encrypt_secret(raw_token),
        "account_id": dep.account_id,
        "account_name": dep.account_name,
        "connected_at": now,
    }
    best_mci = bg_engine.get_best_operator_ips("mci", 1)
    clean_ip = best_mci[0]["ip"] if best_mci else "104.16.132.229"
    store.data["panels"][str(uid)] = {
        "name": brand,
        "uuid": panel_uuid,
        "trojan_password": trojan_pass,
        "script_name": dep.script_name,
        "host": dep.worker_host,
        "sni": dep.worker_host,
        "sub_url": dep.sub_url,
        "operator": old.get("operator", "mci"),
        "clean_ip": clean_ip,
        "proxy_ip": proxy_ip,
        "path": "/?ed=2048",
        "auto_ip": True,
        "worker_deployed": True,
        "health_verified": dep.health_verified,
        "health_latency_ms": dep.health_latency_ms,
        "created_at": old.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    h_txt = f"🟢 زنده ({dep.health_latency_ms}ms)" if dep.health_verified else "🟡 در حال انتشار DNS (۳۰ ثانیه)"
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(f"🎉 <b>پنل VLESS + Trojan شما دیپلوی شد!</b> ({h_txt})\n\n{text}", parse_mode="HTML", reply_markup=markup)


# ==================== 2. MY PANEL (VLESS + TROJAN CATEGORIZED BY OPERATOR) ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return (
            "🎛️ <b>پنل من</b>\n━━━━━━━━━━━━━━━━━━━━\nهنوز پنلی نساخته‌اید. روی دکمه سبز زیر بزنید تا در ۳۰ ثانیه Worker واقعی VLESS + Trojan روی کلودفلر شما ساخته شود:",
            kb([
                [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")],
                [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
            ]),
        )

    op = panel.get("operator", "mci")
    op_lbl = OPERATOR_LABELS.get(op, "🔵 همراه اول")
    sub_all = panel.get("sub_url", "")
    text = (
        "🎛️ <b>پنل اختصاصی من (VLESS + Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 Worker: <code>{html.escape(panel['host'])}</code>\n"
        f"📶 اپراتور پیش‌فرض: <b>{op_lbl}</b>\n"
        f"🟢 IP تمیز فعال: <code>{html.escape(panel['clean_ip'])}</code>\n"
        f"🔁 ProxyIP: <code>{html.escape(panel.get('proxy_ip', '-'))}</code>\n"
        f"🔗 لینک سابسکریپشن دسته‌بندی‌شده (همه اپراتورها):\n<code>{html.escape(sub_all)}</code>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "اپراتور خود را بزنید تا کانفیگ <b>VLESS + Trojan</b> همان اپراتور را بگیرید:"
    )
    markup = kb([
        [
            btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
            btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
            btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
        ],
        [
            btn("🧩 Fragment VLESS (JSON)", callback_data="cf:frag:vless", style="primary"),
            btn("🧩 Fragment Trojan (JSON)", callback_data="cf:frag:trojan", style="primary"),
        ],
        [
            btn("🩺 تست زنده Worker", callback_data="cf:health", style="primary"),
            btn("♻️ آپدیت و Re-Deploy", callback_data="cf:redeploy", style="success"),
        ],
        [
            btn("🏷️ تغییر نام", callback_data="cf:edit_name", style="primary"),
            btn("🔁 تغییر ProxyIP", callback_data="cf:edit_proxyip", style="primary"),
        ],
        [btn("🗑️ حذف پنل و قطع اتصال", callback_data="cf:disconnect", style="danger")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    text, markup = _render_personal_panel(cb.from_user.id)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("cf:getop:"))
async def cb_cf_get_by_op(cb: CallbackQuery) -> None:
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer(f"⚡ ساخت کانفیگ {OPERATOR_LABELS.get(op, op)}...")

    best = bg_engine.get_best_operator_ips(op, 3)
    if best:
        top = best[0]
        ip, ping_ms, colo = top["ip"], top.get("latency_ms"), top.get("colo", "")
    else:
        ip, ping_ms, colo = panel["clean_ip"], None, "CF"

    panel["operator"] = op
    panel["clean_ip"] = ip
    # Ensure trojan_password exists for panels upgraded from older versions
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)
    store.save()
    store.increment_stat(uid, "configs_generated")

    vless_uri = cf_service.build_vless_uri(panel, ip, op, ping_ms, colo, with_fragment=False)
    trojan_uri = cf_service.build_trojan_uri(panel, ip, op, ping_ms, colo, with_fragment=False)
    op_sub = f"{panel.get('sub_url', '')}?op={op}"
    op_lbl = OPERATOR_LABELS.get(op, op)

    caption = (
        f"✅ <b>کانفیگ‌های {op_lbl} آماده شد!</b>\n"
        f"🟢 IP تمیز: <code>{html.escape(ip)}</code>" + (f" (<b>{ping_ms}ms • {colo}</b>)" if ping_ms else "") + "\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>VLESS (کلیک برای کپی):</b>\n<code>{html.escape(vless_uri)}</code>\n\n"
        f"2️⃣ <b>Trojan (کلیک برای کپی):</b>\n<code>{html.escape(trojan_uri)}</code>\n\n"
        f"🔗 <b>لینک سابسکریپشن اختصاصی {op_lbl}:</b>\n<code>{html.escape(op_sub)}</code>"
    )
    await _send_qr(cb.message, vless_uri, caption, kb([
        [
            btn("🧩 فایل Fragment VLESS", callback_data="cf:frag:vless", style="success"),
            btn("🧩 فایل Fragment Trojan", callback_data="cf:frag:trojan", style="success"),
        ],
        [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
    ]))


@router.callback_query(F.data.startswith("cf:frag:"))
async def cb_cf_frag(cb: CallbackQuery) -> None:
    proto = cb.data.split(":")[2]  # vless | trojan
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer("🧩 ساخت فایل Fragment...")
    op = panel.get("operator", "mci")
    best = bg_engine.get_best_operator_ips(op, 1)
    ip = best[0]["ip"] if best else panel["clean_ip"]
    ping_ms = best[0].get("latency_ms") if best else None
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)
        store.save()

    frag_json = cf_service.build_xray_fragment_json(panel, ip, protocol=proto, operator=op, ping_ms=ping_ms)
    store.increment_stat(uid, "configs_generated")
    await cb.message.answer_document(
        document=BufferedInputFile(frag_json.encode("utf-8"), filename=f"{panel['name']}_{proto}_{op}_Fragment.json"),
        caption=(
            f"🧩 <b>فایل {proto.upper()} Fragment ضد فیلتر ({OPERATOR_LABELS.get(op, op)})</b>\n"
            "در <b>v2rayNG</b> با گزینه <i>Import custom config from local</i> وارد کنید تا پینگ سبز شود."
        ),
        parse_mode="HTML",
        reply_markup=back_home_kb("m:mypanel"),
    )


@router.callback_query(F.data == "cf:health")
async def cb_cf_health(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer("🩺 در حال تست زنده...")
    ok, ms = await cf_service.verify_worker_live(panel["host"])
    if ok:
        await cb.message.answer(f"🟢 <b>Worker زنده و سالم است!</b>\n🌐 <code>{html.escape(panel['host'])}</code>\n⚡ پاسخ: <b>{ms}ms (HTTP 200)</b>", parse_mode="HTML")
    else:
        await cb.message.answer("🔴 <b>Worker پاسخ نداد!</b> دکمه <b>♻️ آپدیت و Re-Deploy</b> را بزنید.", parse_mode="HTML")


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await cb.answer("⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return
    await cb.answer("♻️ در حال Re-Deploy با VLESS + Trojan...")
    try:
        token = store.decrypt_secret(cf["encrypted_token"])
    except Exception:
        await cb.answer("❌ لطفاً توکن را مجدد وارد کنید.", show_alert=True)
        return
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    dep = await cf_service.deploy_dual_worker(
        api_token=token,
        user_uuid=panel["uuid"],
        trojan_password=panel["trojan_password"],
        script_name=panel.get("script_name", f"cfhub-{uid % 9999}"),
        proxy_ip=panel.get("proxy_ip", "proxyip.cmliussss.net"),
        operator_pools=store.data.get("operator_pools", {}),
        brand=panel.get("name", "CFHub"),
    )
    if dep.ok:
        panel["host"] = dep.worker_host
        panel["sni"] = dep.worker_host
        panel["sub_url"] = dep.sub_url
        panel["worker_deployed"] = True
        panel["health_verified"] = dep.health_verified
        store.save()
        text, markup = _render_personal_panel(uid)
        await _edit(cb, f"✅ <b>Worker با کد جدید VLESS + Trojan و IP اپراتورها آپدیت شد!</b>\n\n{text}", markup)
    else:
        await cb.message.answer(f"❌ خطا: <code>{html.escape(dep.error or '')}</code>", parse_mode="HTML")


@router.callback_query(F.data == "cf:edit_name")
async def cb_cf_edit_name(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_name)
    await _edit(cb, "🏷️ نام جدید برای نمایش روی کانفیگ‌ها بفرستید:", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_name)
async def handle_panel_name(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    name = (message.text or "").strip()[:20]
    if str(uid) in store.data["panels"] and name:
        store.data["panels"][str(uid)]["name"] = name
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ نام ذخیره شد.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(cb, "🔁 آدرس ProxyIP جدید بفرستید (مثال: <code>proxyip.cmliussss.net</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    pip = (message.text or "").strip()
    if str(uid) in store.data["panels"] and pip:
        store.data["panels"][str(uid)]["proxy_ip"] = pip
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ ProxyIP ذخیره شد.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await cb.answer("🗑️ پنل حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid)))


# ==================== 3. WARP / WIREGUARD WITH IPv4 + IPv6 + DUAL-STACK ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    text = (
        "🛡️ <b>کانفیگ‌های WARP و WireGuard (پشتیبانی کامل IPv4 + IPv6)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 بهترین رله IPv4: <code>{html.escape(ep4)}</code>\n"
        f"🌐 بهترین رله IPv6: <code>{html.escape(ep6)}</code>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "نسخه IP مورد نظر خود را انتخاب کنید:"
    )
    markup = kb([
        [btn("🌐 نسخه IPv6 (ضد اختلال و پرسرعت)", callback_data="warp:mode:ipv6", style="success")],
        [btn("⚡ نسخه دوگانه Dual-Stack (IPv4 + IPv6)", callback_data="warp:mode:dual", style="primary")],
        [btn("🌐 نسخه IPv4 (سازگار با همه شبکه‌ها)", callback_data="warp:mode:ipv4", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:mode:"))
async def cb_warp_choose_plat(cb: CallbackQuery) -> None:
    await cb.answer()
    ip_mode = cb.data.split(":")[2]
    titles = {"ipv6": "🌐 WARP IPv6", "dual": "⚡ WARP Dual-Stack (v4+v6)", "ipv4": "🌐 WARP IPv4"}
    text = f"<b>{titles.get(ip_mode, ip_mode)}</b>\n━━━━━━━━━━━━━━━━━━━━\nدستگاه خود را انتخاب کنید:"
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:go:{ip_mode}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:go:{ip_mode}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:go:{ip_mode}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:go:"))
async def cb_warp_generate(cb: CallbackQuery) -> None:
    _, _, ip_mode, platform = cb.data.split(":")
    await cb.answer("⏳ ثبت کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return

    wait = await cb.message.answer("⏳ در حال ساخت کلید X25519 و فعال‌سازی دستگاه واقعی روی Cloudflare WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(f"❌ خطا در ثبت WARP: <code>{html.escape(reg.error or '')}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:warp"))
        return

    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    brand = store.data.get("panels", {}).get(str(uid), {}).get("name", "CFHub")
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand=brand)  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    await wait.delete()

    txt = (
        f"✅ <b>کانفیگ WARP آماده شد!</b>\n"
        f"🏷️ نام: <b>{html.escape(b['label'])}</b>\n"
        f"🎯 رله: <code>{html.escape(b['endpoint'])}</code> | Reserved: <code>{b['reserved']}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>پیشنهاد اول برای Hiddify / Streisand (اسکنر خودکار روی اینترنت ایران شما):</b>\n"
        f"<code>{html.escape(b['warp_auto_uri'])}</code>\n\n"
        f"2️⃣ <b>لینک Warp-in-Warp دولایه (IPv4 + IPv6 برای Hiddify / Karing):</b>\n"
        f"<code>{html.escape(b['wow_uri'])}</code>\n\n"
        f"3️⃣ <b>لینک استاندارد WireGuard ({ip_mode.upper()}):</b>\n"
        f"<code>{html.escape(b['wireguard_uri'])}</code>"
    )
    await cb.message.answer(txt, parse_mode="HTML")

    await cb.message.answer_document(
        document=BufferedInputFile(b["xray_json"].encode("utf-8"), filename=b["xray_filename"]),
        caption=f"🔥 <b>فایل Xray Noise JSON ({ip_mode.upper()}) — مخصوص v2rayNG / v2rayN</b>",
        parse_mode="HTML",
    )
    await cb.message.answer_document(
        document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
        caption=f"🛡️ <b>فایل AmneziaWG ({ip_mode.upper()}) — ضد اختلال UDP</b>",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("🔄 ساخت کلید جدید", callback_data=cb.data, style="success")],
            [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
        ]),
    )


# ==================== 4. CLEAN IPS CATEGORIZED BY OPERATOR ====================
@router.callback_query(F.data == "m:isp")
async def cb_isp_menu(cb: CallbackQuery) -> None:
    await cb.answer()
    pools = store.data.get("operator_pools", {})
    text = (
        "📶 <b>آی‌پی‌های تمیز دسته‌بندی‌شده بر اساس اپراتور</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> IP تاییدشده\n"
        f"🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> IP تاییدشده\n"
        f"🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b> IP تاییدشده\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "اپراتور خود را انتخاب کنید:"
    )
    markup = kb([
        [btn("🔵 لیست IP تمیز همراه اول", callback_data="isp:show:mci", style="primary")],
        [btn("🟡 لیست IP تمیز ایرانسل", callback_data="isp:show:mtn", style="primary")],
        [btn("🟢 لیست IP تمیز مخابرات", callback_data="isp:show:mkh", style="success")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("isp:show:"))
async def cb_isp_show(cb: CallbackQuery) -> None:
    await cb.answer()
    op = cb.data.split(":")[2]
    ips = bg_engine.get_best_operator_ips(op, 12)
    lbl = OPERATOR_LABELS.get(op, op)
    if ips:
        body = "\n".join(
            f"{i+1}. <code>{x['ip']}</code> | 🟢<b>{x['latency_ms']}ms</b> | {x.get('colo', 'CF')}"
            for i, x in enumerate(ips)
        )
    else:
        body = "⏳ در حال دریافت و تست IPهای این اپراتور؛ ۱ دقیقه دیگر بررسی کنید."

    rows = []
    if _has_panel(cb.from_user.id):
        rows.append([btn(f"⚡ دریافت VLESS + Trojan روی {lbl}", callback_data=f"cf:getop:{op}", style="success")])
    rows.append([btn("🔙 بازگشت به اپراتورها", callback_data="m:isp", style="primary")])
    await _edit(cb, f"📶 <b>برترین IPهای تمیز {lbl}</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


# ==================== 5. APPS, GUIDE & SUPPORT ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await cb.answer()
    markup = kb([
        [btn("🔥 Hiddify (اندروید / آیفون / ویندوز — بهترین)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (ضد فیلتر WireGuard/WARP)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (اندروید)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (آیفون)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (ویندوز)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, "📱 <b>اپلیکیشن‌های پیشنهادی برای اتصال بدون قطعی:</b>", markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📖 <b>راهنمای سریع اتصال با پینگ سبز</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>پنل اختصاصی VLESS + Trojan:</b>\n"
        "• یک‌بار توکن کلودفلر را ارسال کنید تا Worker واقعی شما ساخته شود.\n"
        "• از داخل «🎛️ پنل من» اپراتور خود (همراه اول / ایرانسل / مخابرات) را بزنید تا هم VLESS و هم Trojan همان اپراتور را بگیرید.\n"
        "• اگر روی اینترنت شما پینگ عادی قرمز بود، فایل <b>🧩 Fragment JSON</b> را در v2rayNG ایمپورت کنید.\n\n"
        "2️⃣ <b>کانفیگ WARP (IPv4 + IPv6):</b>\n"
        "• در <b>Hiddify</b>: لینک اول (<code>warp://auto...</code>) یا لینک WoW دولایه را ایمپورت کنید.\n"
        "• در <b>v2rayNG</b>: فایل <code>.json</code> فرستاده‌شده را با <i>Import custom config</i> وارد کنید."
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    cfg = store.data["settings"]
    sup_u = cfg.get("support_username", "").lstrip("@")
    sup_id = cfg.get("support_user_id") or (get_settings().owner_telegram_ids[0] if get_settings().owner_telegram_ids else 0)
    rows = []
    if sup_u:
        rows.append([btn(f"💬 پیام مستقیم (@{sup_u})", url=f"https://t.me/{sup_u}", style="success")])
        line = f"👤 پشتیبانی: @{html.escape(sup_u)}"
    elif sup_id:
        rows.append([btn("💬 پیام مستقیم به مدیریت", url=f"tg://user?id={sup_id}", style="success")])
        line = f"👤 شناسه پشتیبانی: <code>{sup_id}</code>"
    else:
        line = "👤 پشتیبانی داخل ربات فعال است."
    rows.append([btn("✉️ ارسال تیکت داخل ربات", callback_data="sup:ticket", style="primary")])
    rows.append([btn("🔙 صفحه اول", callback_data="m:home", style="primary")])
    await _edit(cb, f"💬 <b>پشتیبانی</b>\n━━━━━━━━━━━━━━━━━━━━\n{line}", kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_support_msg)
    await _edit(cb, "✉️ پیام خود را بنویسید:", kb([[btn("❌ انصراف", callback_data="m:support", style="danger")]]))


@router.message(Flow.waiting_support_msg)
async def handle_sup_msg(message: Message, state: FSMContext) -> None:
    u = message.from_user
    if not u:
        return
    tno = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({"id": tno, "user_id": u.id, "text": message.text or "", "at": datetime.now(timezone.utc).isoformat()})
    store.save()
    await state.clear()
    for oid in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(oid, f"📩 <b>تیکت #{tno}</b> از <a href='tg://user?id={u.id}'>{html.escape(u.full_name)}</a> (<code>{u.id}</code>):\n{html.escape(message.text or '')}", parse_mode="HTML")
        except Exception:
            pass
    await message.answer(f"✅ پیام شما با شماره <b>#{tno}</b> ارسال شد.", parse_mode="HTML", reply_markup=back_home_kb("m:home"))


# ==================== 6. CLEAN & PRO ADMIN PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        "🛠️ <b>پنل مدیریت V6</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | آخرین اسکن: <code>{last_s}</code>\n"
        f"📶 IP اپراتورها: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))}\n"
        f"🛡️ WARP تاییدشده: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل فعال: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [btn("▶️ اسکن فوری اپراتورها + WARP (v4/v6)", callback_data="adm:scan_now", style="success")],
        [
            btn("🔵 افزودن IP همراه اول", callback_data="adm:addop:mci", style="primary"),
            btn("🟡 افزودن IP ایرانسل", callback_data="adm:addop:mtn", style="primary"),
        ],
        [
            btn("🟢 افزودن IP مخابرات", callback_data="adm:addop:mkh", style="success"),
            btn("👥 مدیریت کاربران", callback_data="adm:users:0", style="primary"),
        ],
        [
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
            btn("⚙️ تنظیمات و پشتیبانی", callback_data="adm:settings", style="primary"),
        ],
        [btn("🔙 صفحه اول", callback_data="m:home", style="danger")],
    ])
    return text, markup


@router.callback_query(F.data == "adm:home")
async def cb_adm_home(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await state.clear()
    await cb.answer()
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    if bg_engine.is_scanning:
        await cb.answer("⏳ اسکن در حال اجراست.", show_alert=True)
        return
    asyncio.create_task(bg_engine.run_full_cycle(trigger="admin"))
    await cb.answer("🚀 اسکن اپراتورها و WARP v4/v6 شروع شد!", show_alert=True)
    await asyncio.sleep(0.4)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:addop:"))
async def cb_adm_addop(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    op = cb.data.split(":")[2]
    await state.update_data(target_op=op)
    await state.set_state(Flow.adm_import_op_ips)
    await _edit(
        cb,
        f"➕ <b>افزودن IPهای تست‌شده برای {OPERATOR_LABELS.get(op, op)}</b>\n\nIPها را (در خطوط جدا یا با فاصله) بفرستید تا در اولویت این اپراتور قرار بگیرند:",
        kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]),
    )


@router.message(Flow.adm_import_op_ips)
async def handle_adm_import_op(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    import ipaddress
    op = (await state.get_data()).get("target_op", "mci")
    raw_items = [x.strip() for x in (message.text or "").replace(",", " ").split() if x.strip()]
    added = []
    for item in raw_items:
        try:
            ip_s = str(ipaddress.ip_address(item))
            if ip_s not in store.data["manual_operator_ips"][op]:
                store.data["manual_operator_ips"][op].append(ip_s)
                added.append(ip_s)
        except ValueError:
            continue
    store.save()
    await state.clear()
    asyncio.create_task(bg_engine.run_full_cycle(trigger=f"manual_{op}"))
    await message.answer(
        f"✅ تعداد <b>{len(added)}</b> IP به لیست {OPERATOR_LABELS.get(op, op)} اضافه شد و اسکن اعتبارسنجی آغاز گردید.",
        parse_mode="HTML",
        reply_markup=back_home_kb("adm:home"),
    )


@router.callback_query(F.data.startswith("adm:users:"))
async def cb_adm_users(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
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
        nav.append(btn("⬅️ قبلی", callback_data=f"adm:users:{page-1}", style="primary"))
    if (page + 1) * per_page < len(all_u):
        nav.append(btn("بعدی ➡️", callback_data=f"adm:users:{page+1}", style="primary"))
    if nav:
        rows.append(nav)
    rows.append([btn("🔎 جستجوی کاربر", callback_data="adm:usearch", style="success")])
    rows.append([btn("🔙 پنل مدیریت", callback_data="adm:home", style="danger")])
    await _edit(cb, f"👥 <b>مدیریت کاربران (کل: {len(all_u)})</b>", kb(rows))


def _render_user_card(target_uid: int) -> tuple[str, object]:
    u = store.data.get("users", {}).get(str(target_uid))
    if not u:
        return "❌ یافت نشد.", back_home_kb("adm:users:0")
    p = store.data.get("panels", {}).get(str(target_uid))
    txt = (
        f"👤 <b>پروفایل کاربر</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 <code>{target_uid}</code> | {html.escape(u.get('full_name') or '-')} (@{html.escape(u.get('username') or '-')})\n"
        f"🚦 وضعیت: <b>{'🚫 مسدود' if u.get('is_banned') else '🟢 فعال'}</b>\n"
        f"🚀 پنل: <code>{html.escape(p['host']) if p else 'ندارد'}</code>\n"
        f"📊 تولید: <b>{u.get('configs_generated', 0)}</b> پنل | <b>{u.get('warp_generated', 0)}</b> WARP"
    )
    ban_b = btn("✅ رفع مسدودی", callback_data=f"adm:uban:{target_uid}", style="success") if u.get("is_banned") else btn("🚫 مسدود کردن", callback_data=f"adm:uban:{target_uid}", style="danger")
    rows = [[ban_b], [btn("✉️ پیام مستقیم", callback_data=f"adm:udm:{target_uid}", style="primary")]]
    if p:
        rows.append([btn("🗑️ حذف پنل کاربر", callback_data=f"adm:ureset:{target_uid}", style="danger")])
    rows.append([btn("🔙 لیست کاربران", callback_data="adm:users:0", style="primary")])
    return txt, kb(rows)


@router.callback_query(F.data.startswith("adm:uview:"))
async def cb_adm_uview(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    t, m = _render_user_card(int(cb.data.split(":")[2]))
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:uban:"))
async def cb_adm_uban(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    tid = int(cb.data.split(":")[2])
    if _is_admin(tid):
        return
    store.set_ban(tid, not store.is_banned(tid))
    await cb.answer("✅ انجام شد.", show_alert=True)
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
    await cb.answer("🗑️ پاک شد.", show_alert=True)
    t, m = _render_user_card(tid)
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:udm:"))
async def cb_adm_udm(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
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
        await message.answer(f"❌ خطا: {exc}", reply_markup=back_home_kb(f"adm:uview:{tid}"))


@router.callback_query(F.data == "adm:usearch")
async def cb_adm_usearch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_user_search)
    await _edit(cb, "🔎 آیدی عددی یا <code>@username</code> را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:users:0", style="danger")]]))


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
    await cb.answer()
    await state.set_state(Flow.adm_broadcast)
    await _edit(cb, f"📢 متن پیام همگانی برای {len(store.data.get('users', {}))} کاربر:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


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
    await message.answer(f"✅ ارسال تمام شد (موفق: {sent} | ناموفق: {fail})", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:settings")
async def cb_adm_settings(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID:{cfg.get('support_user_id')}"
    text = (
        f"⚙️ <b>تنظیمات</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 پشتیبانی: <b>{html.escape(str(sup))}</b>\n"
        f"🔄 اسکن خودکار: <b>{'🟢' if cfg.get('auto_scan_enabled', True) else '🔴'}</b> | تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    await _edit(cb, text, kb([
        [btn("💬 تغییر یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="success")],
        [
            btn("🔄 تغییر اسکن خودکار", callback_data="adm:tog_scan", style="primary"),
            btn("🛠️ تغییر تعمیرات", callback_data="adm:tog_maint", style="danger"),
        ],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:tog_scan")
async def cb_adm_tog_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_scan_enabled"] = not bool(store.data["settings"].get("auto_scan_enabled", True))
    store.save()
    await cb.answer("✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["maintenance_mode"] = not bool(store.data["settings"].get("maintenance_mode", False))
    store.save()
    await cb.answer("✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_set_support)
    await _edit(cb, "💬 یوزرنیم پشتیبانی را بفرستید (مثال: <code>@YourID</code>):", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


@router.message(Flow.adm_set_support)
async def handle_adm_set_sup(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    uname = (message.text or "").strip().lstrip("@")
    store.data["settings"]["support_username"] = uname
    store.save()
    await state.clear()
    await message.answer(f"✅ آیدی پشتیبانی: <b>@{html.escape(uname)}</b>", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))


# ==================== LIFECYCLE ====================
async def on_startup() -> None:
    logger.info("Starting V6 Background Engine (MCI/Irancell/Mokhaberat + WARP IPv4/IPv6)...")
    bg_engine.start()


async def on_shutdown() -> None:
    await bg_engine.stop()


async def run_polling() -> None:
    configure_logging()
    settings = get_settings()
    if not settings.telegram_bot_token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required.")
    bot = Bot(token=settings.telegram_bot_token)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)
    dp.startup.register(on_startup)
    dp.shutdown.register(on_shutdown)
    logger.info("Starting Cloudflare Config Hub V6 Clean Pro Bot.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V6_EOF__

python3 -c '
from pathlib import Path
p = Path("docker-compose.yml")
txt = p.read_text(encoding="utf-8")
if "./data:/app/data" not in txt and "telegram_bot:" in txt:
    txt = txt.replace(
        "command: [\"python\", \"-m\", \"app.bot.bot\"]",
        "command: [\"python\", \"-m\", \"app.bot.bot\"]\n    volumes:\n      - ./data:/app/data"
    )
    p.write_text(txt, encoding="utf-8")
    print("Mounted persistent ./data volume in docker-compose.yml")
'

echo ">>> Rebuilding and restarting telegram_bot..."
docker compose up -d --build telegram_bot
sleep 4
docker compose logs --tail=30 telegram_bot
echo ">>> V6 Upgrade complete! Send /start to your Telegram bot."
