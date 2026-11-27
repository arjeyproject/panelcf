#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V8 (Fixed Operator Delivery + Auto ProxyIP Pool + No Rename Clutter)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/proxyip_scanner.py
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

# Well-known open-source community ProxyIP pools (BPB / edgetunnel / cmliu / anycast)
# Each domain resolves dynamically via DoH to live non-CF reverse-proxy IPs that forward port 443 to Cloudflare!
PROXYIP_DNS_SOURCES: list[str] = [
    "proxyip.cmliussss.net",
    "proxyip.fxxk.dedyn.io",
    "proxyip.oracle.fxxk.dedyn.io",
    "proxyip.aliyun.fxxk.dedyn.io",
    "proxyip.digitalocean.fxxk.dedyn.io",
    "proxyip.vultr.fxxk.dedyn.io",
    "proxyip.multacom.fxxk.dedyn.io",
    "cdn.xn--b6gac.eu.org",
    "cdn-all.xn--b6gac.eu.org",
    "edgetunnel.anycast.eu.org",
    "bpb.yousef.isegaro.com",
    "workers.cloudflare.cyou",
    "cdn.anycast.eu.org",
    "ts.hpc.tw",
]

# Preferred low-latency PoPs for Iran users (Europe + Middle East)
IRAN_FAST_COLOS = {"FRA", "AMS", "DXB", "MCT", "DOH", "IST", "VIE", "ZRH", "MXP", "WAW", "BUD", "MRS", "SOF", "LHR", "CDG"}


async def resolve_proxyip_domain(domain: str, timeout_sec: float = 4.0) -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            r = await client.get(
                "https://cloudflare-dns.com/dns-query",
                params={"name": domain, "type": "A"},
                headers={"Accept": "application/dns-json"},
            )
            if r.status_code != 200:
                return []
            ips: list[str] = []
            for ans in (r.json().get("Answer") or []):
                val = str(ans.get("data", "")).strip()
                try:
                    ip_obj = ipaddress.ip_address(val)
                    if ip_obj.version == 4 and ip_obj.is_global:
                        ips.append(str(ip_obj))
                except ValueError:
                    continue
            return ips
    except Exception:
        return []


async def verify_single_proxyip(ip: str, port: int = 443, timeout_sec: float = 3.0) -> dict[str, Any] | None:
    """
    Real ProxyIP verification:
    Connects via TLS to `ip:port` with SNI `speed.cloudflare.com`, sends `GET /cdn-cgi/trace`,
    and verifies a genuine Cloudflare trace response (`colo=...` + `fl=...`).
    Only hosts that truly proxy TLS/443 to Cloudflare pass this check!
    """
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    writer = None
    try:
        t0 = time.perf_counter()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port, ssl=ssl_ctx, server_hostname="speed.cloudflare.com"),
            timeout=timeout_sec,
        )
        req = (
            "GET /cdn-cgi/trace HTTP/1.1\r\n"
            "Host: speed.cloudflare.com\r\n"
            "User-Agent: Mozilla/5.0\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        writer.write(req)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        raw = await asyncio.wait_for(reader.read(2048), timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - t0) * 1000.0, 1)

        text = raw.decode("latin1", errors="ignore")
        if "colo=" not in text or "fl=" not in text:
            return None

        colo = "CF"
        loc = ""
        for line in text.splitlines():
            if line.startswith("colo="):
                colo = line.split("=", 1)[1].strip().upper()
            elif line.startswith("loc="):
                loc = line.split("=", 1)[1].strip().upper()

        bonus = 15.0 if colo in IRAN_FAST_COLOS else 0.0
        score = round(max(10.0, min(100.0, 95.0 - (rtt_ms / 7.5) + bonus)), 1)
        return {
            "address": f"{ip}:{port}",
            "ip": ip,
            "port": port,
            "latency_ms": rtt_ms,
            "colo": colo,
            "loc": loc,
            "score": score,
            "verified": True,
            "tested_at": datetime.now(timezone.utc).isoformat(),
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


async def discover_and_verify_proxyips(
    manual_proxyips: list[str] | None = None,
    timeout_sec: float = 3.0,
) -> list[dict[str, Any]]:
    """Resolves community ProxyIP domains + admin manual entries, probes every IP live, and returns ranked healthy list."""
    candidates: dict[tuple[str, int], str] = {}

    for raw in (manual_proxyips or []):
        s = raw.strip()
        if not s:
            continue
        if ":" in s and not s.startswith("["):
            h, p_s = s.rsplit(":", 1)
            port = int(p_s) if p_s.isdigit() else 443
        else:
            h, port = s, 443
        try:
            ip_obj = ipaddress.ip_address(h)
            if ip_obj.is_global:
                candidates[(str(ip_obj), port)] = "admin_manual"
        except ValueError:
            ips = await resolve_proxyip_domain(h)
            for ip in ips:
                candidates[(ip, port)] = f"manual:{h}"

    resolved_batches = await asyncio.gather(*(resolve_proxyip_domain(d) for d in PROXYIP_DNS_SOURCES))
    for dom, ips in zip(PROXYIP_DNS_SOURCES, resolved_batches):
        for ip in ips:
            candidates.setdefault((ip, 443), dom)

    sem = asyncio.Semaphore(20)

    async def _probe(ip: str, port: int, src: str):
        async with sem:
            res = await verify_single_proxyip(ip, port, timeout_sec=timeout_sec)
            if res:
                res["source"] = src
            return res

    probed = await asyncio.gather(*(_probe(ip, port, src) for (ip, port), src in candidates.items()))
    healthy = [x for x in probed if x is not None]
    healthy.sort(
        key=lambda x: (1 if x["source"].startswith(("admin", "manual")) else 0, x["score"], -(x["latency_ms"] or 9999)),
        reverse=True,
    )
    return healthy[:30]
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import hashlib
import json

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
            service: 'cfhub-v8-worker',
            protocols: ['vless', 'trojan'],
            proxy_ips: PROXY_IPS.length,
            timestamp: new Date().toISOString()
          }), {
            status: 200,
            headers: { 'content-type': 'application/json; charset=utf-8' }
          });
        }

        if (url.pathname === `/sub/${USER_ID}` || url.pathname === `/${USER_ID}`) {
          const host = request.headers.get('Host') || url.hostname;
          const opFilter = (url.searchParams.get('op') || 'all').toLowerCase();
          const subText = buildSubscription(host, opFilter);
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

      // Extract ProxyIP from EITHER `/proxyip=ip:port` path OR `?proxyip=ip:port` query
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

function buildSubscription(host, opFilter) {
  const opMeta = {
    mci: { label: '🔵همراه اول', list: OPERATOR_IPS.mci || [] },
    mtn: { label: '🟡ایرانسل', list: OPERATOR_IPS.mtn || [] },
    mkh: { label: '🟢مخابرات', list: OPERATOR_IPS.mkh || [] },
  };
  const keys = opFilter === 'all' ? ['mci', 'mtn', 'mkh'] : (opMeta[opFilter] ? [opFilter] : ['mci', 'mtn', 'mkh']);
  const bestProxy = PROXY_IPS.length ? PROXY_IPS[0] : '';
  const rawPath = bestProxy ? `/proxyip=${bestProxy}?ed=2560` : '/?ed=2560';
  const wsPath = encodeURIComponent(rawPath);
  const lines = [];

  for (const key of keys) {
    const meta = opMeta[key];
    const items = meta.list.length ? meta.list.slice(0, 4) : [{ ip: host, latency_ms: 0, colo: 'CF' }];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const ip = typeof it === 'string' ? it : it.ip;
      const hostPart = ip.includes(':') ? `[${ip}]` : ip;
      const ping = it.latency_ms ? `🟢${Math.round(it.latency_ms)}ms` : '⚡Auto';
      const colo = it.colo ? `•${it.colo}` : '';

      const vlessTag = encodeURIComponent(`${meta.label} • VLESS • ${ping}${colo}`);
      lines.push(
        `vless://${USER_ID}@${hostPart}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${vlessTag}`
      );

      const trojanTag = encodeURIComponent(`${meta.label} • Trojan • ${ping}${colo}`);
      lines.push(
        `trojan://${encodeURIComponent(TROJAN_PASSWORD)}@${hostPart}:443?security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${trojanTag}`
      );
    }
  }
  return lines.join('\n');
}

function toUint8Array(chunk) {
  if (chunk instanceof Uint8Array) return chunk;
  if (chunk instanceof ArrayBuffer) return new Uint8Array(chunk);
  if (ArrayBuffer.isView(chunk)) return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  return new TextEncoder().encode(String(chunk));
}

async function handleDualWebSocket(request, overrideProxy) {
  const wsPair = new WebSocketPair();
  const [client, server] = Object.values(wsPair);
  server.accept();

  const earlyDataHeader = request.headers.get('sec-websocket-protocol') || '';
  const readableWS = makeReadableWebSocketStream(server, earlyDataHeader);

  let remoteSocketWrapper = { value: null };
  let isDns = false;
  let udpWrite = null;

  const proxyCandidates = overrideProxy
    ? [overrideProxy, ...PROXY_IPS.filter(p => p !== overrideProxy)]
    : [...PROXY_IPS];

  readableWS.pipeTo(new WritableStream({
    async write(chunk) {
      const u8 = toUint8Array(chunk);
      if (isDns && udpWrite) {
        return udpWrite(u8);
      }
      if (remoteSocketWrapper.value) {
        const writer = remoteSocketWrapper.value.writable.getWriter();
        await writer.write(u8);
        writer.releaseLock();
        return;
      }

      let parsed = parseTrojanHeader(u8);
      let respHeader = null;

      if (parsed.hasError) {
        const vless = parseVlessHeader(u8, USER_ID);
        if (vless.hasError) {
          throw new Error(`Auth failed: ${vless.message}`);
        }
        parsed = vless;
        respHeader = new Uint8Array([vless.vlessVersion, 0]);
      }

      const rawClientData = u8.slice(parsed.rawDataIndex);

      if (parsed.isUDP) {
        if (parsed.portRemote === 53) {
          isDns = true;
          udpWrite = makeDnsHandler(server, respHeader);
          return udpWrite(rawClientData);
        }
        throw new Error('UDP only supported on port 53');
      }

      await startTCPOutbound(
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

async function startTCPOutbound(
  remoteSocketWrapper,
  addressRemote,
  portRemote,
  rawClientData,
  webSocket,
  respHeader,
  proxyCandidates
) {
  async function connectAndWrite(host, port) {
    const tcpSocket = connect({ hostname: host, port: Number(port) });
    remoteSocketWrapper.value = tcpSocket;
    const writer = tcpSocket.writable.getWriter();
    if (rawClientData && rawClientData.byteLength > 0) {
      await writer.write(rawClientData);
    }
    writer.releaseLock();
    return tcpSocket;
  }

  async function retryProxy(idx) {
    if (idx >= proxyCandidates.length) {
      safeCloseWebSocket(webSocket);
      return;
    }
    const raw = proxyCandidates[idx];
    const [pHost, pPort] = raw.includes(':') ? raw.split(':') : [raw, String(portRemote)];
    try {
      const sock = await connectAndWrite(pHost, Number(pPort) || portRemote);
      sock.closed.catch(() => {}).finally(() => {
        if (remoteSocketWrapper.value === sock) {
          safeCloseWebSocket(webSocket);
        }
      });
      pumpRemoteToWS(sock, webSocket, respHeader, () => retryProxy(idx + 1));
    } catch (_) {
      await retryProxy(idx + 1);
    }
  }

  try {
    const tcpSocket = await connectAndWrite(addressRemote, portRemote);
    pumpRemoteToWS(tcpSocket, webSocket, respHeader, () => retryProxy(0));
  } catch (_) {
    await retryProxy(0);
  }
}

async function pumpRemoteToWS(remoteSocket, webSocket, respHeader, retryFn) {
  let header = respHeader;
  let hasIncomingData = false;

  await remoteSocket.readable.pipeTo(new WritableStream({
    async write(chunk) {
      hasIncomingData = true;
      if (webSocket.readyState !== WS_READY_STATE_OPEN) {
        throw new Error('WebSocket closed');
      }
      const data = toUint8Array(chunk);
      if (header) {
        const merged = new Uint8Array(header.byteLength + data.byteLength);
        merged.set(header, 0);
        merged.set(data, header.byteLength);
        webSocket.send(merged);
        header = null;
      } else {
        webSocket.send(data);
      }
    },
    abort() {}
  })).catch(() => {});

  if (!hasIncomingData && retryFn) {
    await retryFn();
  } else {
    safeCloseWebSocket(webSocket);
  }
}

function makeDnsHandler(webSocket, initialRespHeader) {
  let respHeader = initialRespHeader;
  return async function handleDnsChunk(rawClientData) {
    try {
      let offset = 0;
      while (offset + 2 <= rawClientData.byteLength) {
        const len = (rawClientData[offset] << 8) | rawClientData[offset + 1];
        if (offset + 2 + len > rawClientData.byteLength) break;
        const dnsQuery = rawClientData.subarray(offset + 2, offset + 2 + len);
        offset += 2 + len;

        const resp = await fetch('https://1.1.1.1/dns-query', {
          method: 'POST',
          headers: { 'content-type': 'application/dns-message' },
          body: dnsQuery
        });
        const ans = new Uint8Array(await resp.arrayBuffer());
        const prefixLen = respHeader ? respHeader.byteLength : 0;
        const out = new Uint8Array(prefixLen + 2 + ans.byteLength);
        if (respHeader) {
          out.set(respHeader, 0);
          respHeader = null;
        }
        out[prefixLen] = (ans.byteLength >> 8) & 0xff;
        out[prefixLen + 1] = ans.byteLength & 0xff;
        out.set(ans, prefixLen + 2);
        if (webSocket.readyState === WS_READY_STATE_OPEN) {
          webSocket.send(out);
        }
      }
    } catch (_) {}
  };
}

function parseTrojanHeader(u8) {
  if (u8.byteLength < 64) return { hasError: true, message: 'short' };
  if (u8[56] !== 0x0d || u8[57] !== 0x0a) return { hasError: true, message: 'no crlf' };
  const incomingHash = new TextDecoder().decode(u8.subarray(0, 56)).toLowerCase();
  if (incomingHash !== TROJAN_HASH.toLowerCase()) return { hasError: true, message: 'bad hash' };

  const cmd = u8[58];
  const isUDP = cmd === 3;
  if (cmd !== 1 && cmd !== 3) return { hasError: true, message: 'bad cmd' };

  const atyp = u8[59];
  let idx = 60;
  let addressRemote = '';

  if (atyp === 1) {
    addressRemote = `${u8[idx]}.${u8[idx + 1]}.${u8[idx + 2]}.${u8[idx + 3]}`;
    idx += 4;
  } else if (atyp === 3) {
    const domLen = u8[idx];
    idx += 1;
    addressRemote = new TextDecoder().decode(u8.subarray(idx, idx + domLen));
    idx += domLen;
  } else if (atyp === 4) {
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(((u8[idx + i * 2] << 8) | u8[idx + i * 2 + 1]).toString(16));
    addressRemote = parts.join(':');
    idx += 16;
  } else {
    return { hasError: true, message: 'bad atyp' };
  }

  const portRemote = (u8[idx] << 8) | u8[idx + 1];
  idx += 2;
  if (idx + 2 <= u8.byteLength && u8[idx] === 0x0d && u8[idx + 1] === 0x0a) idx += 2;

  return { hasError: false, addressRemote, portRemote, rawDataIndex: idx, isUDP };
}

function parseVlessHeader(u8, userID) {
  if (u8.byteLength < 24) return { hasError: true, message: 'short' };
  const version = u8[0];
  const incomingUUID = stringifyUUID(u8.subarray(1, 17));
  if (incomingUUID.toLowerCase() !== userID.toLowerCase()) return { hasError: true, message: 'bad uuid' };

  const optLength = u8[17];
  const command = u8[18 + optLength];
  let isUDP = false;
  if (command === 2) isUDP = true;
  else if (command !== 1) return { hasError: true, message: 'bad cmd' };

  const portIndex = 19 + optLength;
  const portRemote = (u8[portIndex] << 8) | u8[portIndex + 1];

  const addressIndex = portIndex + 2;
  const addressType = u8[addressIndex];
  let idx = addressIndex + 1;
  let addressRemote = '';

  if (addressType === 1) {
    addressRemote = `${u8[idx]}.${u8[idx + 1]}.${u8[idx + 2]}.${u8[idx + 3]}`;
    idx += 4;
  } else if (addressType === 2) {
    const domLen = u8[idx];
    idx += 1;
    addressRemote = new TextDecoder().decode(u8.subarray(idx, idx + domLen));
    idx += domLen;
  } else if (addressType === 3) {
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(((u8[idx + i * 2] << 8) | u8[idx + i * 2 + 1]).toString(16));
    addressRemote = parts.join(':');
    idx += 16;
  } else {
    return { hasError: true, message: 'bad atyp' };
  }

  return { hasError: false, addressRemote, portRemote, rawDataIndex: idx, vlessVersion: version, isUDP };
}

function makeReadableWebSocketStream(webSocketServer, earlyDataHeader) {
  let canceled = false;
  return new ReadableStream({
    start(controller) {
      webSocketServer.addEventListener('message', (event) => {
        if (!canceled) controller.enqueue(event.data);
      });
      webSocketServer.addEventListener('close', () => {
        safeCloseWebSocket(webSocketServer);
        if (!canceled) controller.close();
      });
      webSocketServer.addEventListener('error', (err) => controller.error(err));

      const early = base64ToUint8Array(earlyDataHeader);
      if (early) controller.enqueue(early);
    },
    cancel() {
      canceled = true;
      safeCloseWebSocket(webSocketServer);
    }
  });
}

function base64ToUint8Array(b64) {
  if (!b64) return null;
  try {
    const clean = b64.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(clean);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
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
    if (ws.readyState === WS_READY_STATE_OPEN || ws.readyState === WS_READY_STATE_CLOSING) ws.close();
  } catch (_) {}
}
""".strip()

FALLBACK_PROXY_IPS = [
    "proxyip.cmliussss.net:443",
    "proxyip.fxxk.dedyn.io:443",
    "proxyip.oracle.fxxk.dedyn.io:443",
    "cdn.xn--b6gac.eu.org:443",
]


def render_worker_script(
    user_uuid: str,
    trojan_password: str,
    verified_proxyips: list[str] | None = None,
    operator_pools: dict | None = None,
    brand: str = "CFHub",
) -> str:
    safe_brand = brand.replace("'", "").replace('"', "").replace("\\", "")[:20] or "CFHub"
    safe_tpass = trojan_password.replace("'", "").replace('"', "").strip()
    trojan_hash = hashlib.sha224(safe_tpass.encode("utf-8")).hexdigest()

    proxies = list(dict.fromkeys([p.strip() for p in (verified_proxyips or []) + FALLBACK_PROXY_IPS if p.strip()]))[:10]
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
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/ws_tester.py
from __future__ import annotations

import asyncio
import base64
import hashlib
import os
import ssl
import struct
import time
import uuid as uuid_lib


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
    http_req = f"GET /generate_204 HTTP/1.1\r\nHost: {target_host}\r\nConnection: close\r\n\r\n".encode("ascii")
    return b"\x00" + uid_bytes + b"\x00\x01" + struct.pack("!H", target_port) + b"\x02" + bytes([len(dom)]) + dom + http_req


def build_trojan_test_packet(password: str, target_host: str = "www.gstatic.com", target_port: int = 80) -> bytes:
    pw_hash = hashlib.sha224(password.encode("utf-8")).hexdigest().encode("ascii")
    dom = target_host.encode("ascii")
    http_req = f"GET /generate_204 HTTP/1.1\r\nHost: {target_host}\r\nConnection: close\r\n\r\n".encode("ascii")
    return pw_hash + b"\r\n\x01\x03" + bytes([len(dom)]) + dom + struct.pack("!H", target_port) + b"\r\n" + http_req


async def test_worker_tunnel_e2e(
    worker_host: str,
    connect_ip: str | None,
    protocol: str,
    credential: str,
    proxy_ip: str | None = None,
    target_host: str = "www.gstatic.com",
    timeout_sec: float = 8.0,
) -> tuple[bool, float | None, str]:
    target_addr = connect_ip or worker_host
    ws_path = f"/proxyip={proxy_ip}" if proxy_ip else "/"
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    writer = None
    try:
        t0 = time.perf_counter()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(target_addr, 443, ssl=ssl_ctx, server_hostname=worker_host),
            timeout=timeout_sec,
        )
        ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
        upgrade = (
            f"GET {ws_path} HTTP/1.1\r\n"
            f"Host: {worker_host}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode("ascii")
        writer.write(upgrade)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)

        resp_head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout_sec)
        if b"101" not in resp_head.splitlines()[0]:
            return False, None, f"WS HTTP error: {resp_head.splitlines()[0].decode('latin1', 'ignore')}"

        payload = (
            build_trojan_test_packet(credential, target_host=target_host)
            if protocol == "trojan"
            else build_vless_test_packet(credential, target_host=target_host)
        )
        writer.write(_build_ws_frame(payload))
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)

        data = await _read_ws_frame(reader, timeout_sec=timeout_sec)
        rtt_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        body = data[2:] if (protocol == "vless" and len(data) >= 2 and data[0] == 0) else data

        if b"204" in body or b"HTTP/1.1 20" in body:
            return True, rtt_ms, "HTTP 204 OK"
        return False, rtt_ms, f"Unexpected response ({len(body)}B)"
    except Exception as exc:
        return False, None, str(exc)
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/operator_scanner.py
from __future__ import annotations

import asyncio
import ipaddress
import ssl
import time
from datetime import datetime, timezone
from typing import Any

import httpx

OPERATOR_DNS_SOURCES: dict[str, list[str]] = {
    "mci": ["mci.ircf.space", "mcic.ircf.space", "mci.cf.vfarid.com", "www.visa.com", "icook.hk", "time.is"],
    "mtn": ["mtn.ircf.space", "mtnc.ircf.space", "mtn.cf.vfarid.com", "www.shopify.com", "icook.tw", "ip.sb"],
    "mkh": ["mkh.ircf.space", "tci.ircf.space", "mkh.cf.vfarid.com", "www.visa.com.sg", "speed.cloudflare.com", "www.wto.org"],
}

FALLBACK_EDGE_IPS: dict[str, list[str]] = {
    "mci": ["104.16.132.229", "104.17.148.22", "104.18.32.47", "172.64.155.209"],
    "mtn": ["104.16.133.229", "104.17.147.22", "104.19.44.11", "172.67.70.10"],
    "mkh": ["104.16.51.111", "104.18.21.226", "104.21.48.84", "172.64.147.228"],
}

OPERATOR_LABELS: dict[str, str] = {
    "mci": "🔵 همراه اول",
    "mtn": "🟡 ایرانسل",
    "mkh": "🟢 مخابرات",
}

IRAN_PREFERRED_COLOS = {"DXB", "MCT", "DOH", "BAH", "KWI", "IST", "FRA", "AMS", "MRS", "VIE", "WAW", "BUD", "SOF", "ZRH", "MXP"}


async def resolve_doh_records(domain: str, qtype: str = "A", timeout_sec: float = 4.0) -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=timeout_sec) as client:
            r = await client.get(
                "https://cloudflare-dns.com/dns-query",
                params={"name": domain, "type": qtype},
                headers={"Accept": "application/dns-json"},
            )
            if r.status_code != 200:
                return []
            ips: list[str] = []
            for ans in (r.json().get("Answer") or []):
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
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    try:
        start = time.perf_counter()
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port, ssl=ssl_ctx, server_hostname="cloudflare.com"),
            timeout=timeout_sec,
        )
        writer.write(b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: cloudflare.com\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n")
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        raw = await asyncio.wait_for(reader.read(2048), timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - start) * 1000.0, 1)

        text = raw.decode("latin1", errors="ignore")
        if "200 OK" not in text and "colo=" not in text:
            return None
        colo = "CF"
        for line in text.splitlines():
            if line.startswith("colo="):
                colo = line.split("=", 1)[1].strip().upper()
                break
        bonus = 12.0 if colo in IRAN_PREFERRED_COLOS else 0.0
        return {
            "ip": ip,
            "port": port,
            "latency_ms": rtt_ms,
            "colo": colo,
            "score": round(max(10.0, min(100.0, 92.0 - (rtt_ms / 8.0) + bonus)), 1),
            "tested_at": datetime.now(timezone.utc).isoformat(),
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


async def refresh_operator_clean_pools(
    manual_overrides: dict[str, list[str]] | None = None,
    timeout_sec: float = 2.8,
) -> dict[str, list[dict[str, Any]]]:
    results: dict[str, list[dict[str, Any]]] = {"mci": [], "mtn": [], "mkh": []}
    sem = asyncio.Semaphore(18)

    async def _probe(ip: str, source: str):
        async with sem:
            res = await verify_cloudflare_edge_ip(ip, 443, timeout_sec=timeout_sec)
            if res:
                res["source"] = source
            return res

    for op in ("mci", "mtn", "mkh"):
        cmap: dict[str, str] = {}
        for mip in (manual_overrides or {}).get(op, []):
            try:
                cmap[str(ipaddress.ip_address(mip.strip()))] = "admin_manual"
            except ValueError:
                continue

        doms = OPERATOR_DNS_SOURCES.get(op, [])
        res_lists = await asyncio.gather(*(resolve_doh_records(d, "A") for d in doms))
        for dom, ips in zip(doms, res_lists):
            for ip in ips:
                cmap.setdefault(ip, dom)
        for fb in FALLBACK_EDGE_IPS.get(op, []):
            cmap.setdefault(fb, "cf_edge_fallback")

        probed = await asyncio.gather(*(_probe(ip, src) for ip, src in cmap.items()))
        valid = [p for p in probed if p is not None]
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
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/wg_handshake.py
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
    if len(key) > 64:
        key = _blake2s(key)
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
    def __init__(self, fut: asyncio.Future):
        self.fut = fut

    def datagram_received(self, data: bytes, addr):
        if not self.fut.done():
            self.fut.set_result(data)

    def error_received(self, exc):
        if not self.fut.done():
            self.fut.set_exception(exc)


async def probe_real_warp_handshake(host: str, port: int, priv: str, pub: str, reserved: list[int] | None = None, timeout_sec: float = 2.0) -> tuple[bool, float | None]:
    loop = asyncio.get_running_loop()
    transport = None
    try:
        clean = host.strip("[]")
        family = socket.AF_INET6 if ipaddress.ip_address(clean).version == 6 else socket.AF_INET
        pkt, sidx = build_wireguard_handshake_initiation(priv, pub, reserved=reserved)
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(
            loop.create_datagram_endpoint(lambda: _WGRespProto(fut), remote_addr=(clean, port), family=family),
            timeout=timeout_sec,
        )
        t0 = time.perf_counter()
        transport.sendto(pkt)
        resp: bytes = await asyncio.wait_for(fut, timeout=timeout_sec)
        rtt = round((time.perf_counter() - t0) * 1000.0, 1)
        if len(resp) >= 92 and resp[0] == 2 and struct.unpack("<I", resp[8:12])[0] == sidx:
            return True, rtt
        return False, None
    except Exception:
        return False, None
    finally:
        if transport is not None:
            transport.close()
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/warp_builder.py
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
WARP_REG_URLS = ["https://api.cloudflareclient.com/v0a2483/reg", "https://api.cloudflareclient.com/v0a2158/reg"]
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
                        act = await client.patch(f"{reg_url}/{dev_id}", json={"warp_enabled": True}, headers={**headers, "Authorization": f"Bearer {token}"})
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
    reg: WarpRegistration,
    ep_v4: str,
    ep_v6: str,
    platform: PlatformType,
    ip_mode: IPMode = "ipv6",
    ping_ms: float | None = None,
) -> dict:
    h4, p4 = split_endpoint(ep_v4)
    h6, p6 = split_endpoint(ep_v6)

    if ip_mode == "ipv6":
        primary_hp, secondary_hp = format_endpoint_hostport(h6, p6), format_endpoint_hostport(h4, p4)
        mode_tag = "IPv6"
        local_addrs = [a for a in [reg.ipv4, reg.ipv6] if a]
        allowed_ips = ["0.0.0.0/0", "::/0"]
        wg_dns = "2606:4700:4700::1111, 1.1.1.1"
    elif ip_mode == "dual":
        primary_hp, secondary_hp = format_endpoint_hostport(h4, p4), format_endpoint_hostport(h6, p6)
        mode_tag = "Dual"
        local_addrs = [a for a in [reg.ipv4, reg.ipv6] if a]
        allowed_ips = ["0.0.0.0/0", "::/0"]
        wg_dns = "1.1.1.1, 2606:4700:4700::1111"
    else:
        primary_hp, secondary_hp = format_endpoint_hostport(h4, p4), format_endpoint_hostport(h6, p6)
        mode_tag = "IPv4"
        local_addrs = [reg.ipv4]
        allowed_ips = ["0.0.0.0/0"]
        wg_dns = "1.1.1.1, 8.8.8.8"

    mtu = 1280
    reserved = reg.reserved or [0, 0, 0]
    plat_tag = {"ios": "🍏iOS", "android": "🤖Android", "windows": "🪟Win"}[platform]

    wg_label = format_beautiful_name("🛡️CFHub", f"WARP-{mode_tag}", ping_ms, plat_tag)
    wow_label = format_beautiful_name("🌀CFHub", f"WoW-{mode_tag}", ping_ms, plat_tag)
    auto_label = format_beautiful_name("🎯CFHub", f"Auto-{mode_tag}", None, plat_tag)

    wg_query = urlencode({"address": ",".join(local_addrs), "reserved": ",".join(str(x) for x in reserved), "publickey": reg.peer_public_key, "mtu": str(mtu)})
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{primary_hp}?{wg_query}#{quote(wg_label)}"
    warp_auto_uri = f"warp://auto?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(auto_label)}"
    wow_uri = f"warp://{primary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(wow_label)}&&detour=warp://{secondary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10#{quote('🌍Exit')}"

    amnezia_conf = "\n".join([
        f"# {wg_label}", "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {', '.join(local_addrs)}",
        f"DNS = {wg_dns}", f"MTU = {mtu}",
        "Jc = 4", "Jmin = 40", "Jmax = 70", "S1 = 0", "S2 = 0", "H1 = 1", "H2 = 2", "H3 = 3", "H4 = 4",
        "", "[Peer]",
        f"PublicKey = {reg.peer_public_key}",
        f"AllowedIPs = {', '.join(allowed_ips)}",
        f"Endpoint = {primary_hp}",
        "PersistentKeepalive = 25",
    ]) + "\n"

    return {
        "label": wg_label, "endpoint": primary_hp,
        "wireguard_uri": wireguard_uri, "warp_auto_uri": warp_auto_uri, "wow_uri": wow_uri,
        "amnezia_conf": amnezia_conf, "amnezia_filename": f"cfhub_warp_{ip_mode}_{platform}.conf",
        "reserved": reserved,
    }
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import logging
import random
from datetime import datetime, timezone
from typing import Any

from app.bot.operator_scanner import refresh_operator_clean_pools
from app.bot.proxyip_scanner import discover_and_verify_proxyips
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
        ("162.159.192.1", 2408), ("162.159.192.8", 854), ("162.159.193.1", 2408), ("162.159.193.10", 894),
        ("162.159.195.1", 2408), ("162.159.195.5", 908), ("188.114.96.1", 2408), ("188.114.97.1", 1074),
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
    3-Phase Real Autonomous Scanner:
      1) Operator Clean IPs (MCI / Irancell / Mokhaberat) verified via TLS /cdn-cgi/trace
      2) Live ProxyIP Discovery & Verification (community pools + admin manual ProxyIPs)
      3) Real WireGuard Noise_IKpsk2 UDP Handshake (IPv4 + IPv6)
    """

    def __init__(self, store):
        self.store = store
        self._loop_task: asyncio.Task | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.last_scan_at: str | None = None

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v8")

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
        dev = {"private_key": reg.private_key, "peer_public_key": reg.peer_public_key or OFFICIAL_WARP_PEER_PUBKEY, "reserved": reg.reserved or [0, 0, 0]}
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
                logger.exception("V8 background scan error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def refresh_proxyip_pool_only(self) -> list[dict[str, Any]]:
        manual = self.store.data.get("manual_proxyips", [])
        timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 3.0))
        verified = await discover_and_verify_proxyips(manual_proxyips=manual, timeout_sec=timeout_sec)
        if verified:
            self.store.data["proxyip_pool"] = verified
            best_addr = verified[0]["address"]
            for panel in self.store.data.get("panels", {}).values():
                if panel.get("auto_proxyip", True):
                    panel["proxy_ip"] = best_addr
            self.store.save()
        return self.store.data.get("proxyip_pool", [])

    async def run_full_cycle(self, trigger: str = "manual") -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async with self._scan_lock:
            self.is_scanning = True
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.8))
            try:
                # Phase 1: Operator Clean IPs
                self.current_stage = "operator_ips"
                manual_ops = self.store.data.get("manual_operator_ips", {})
                op_pools = await refresh_operator_clean_pools(manual_overrides=manual_ops, timeout_sec=timeout_sec)
                for op in ("mci", "mtn", "mkh"):
                    if op_pools.get(op):
                        self.store.data["operator_pools"][op] = op_pools[op]

                # Phase 2: Real Verified ProxyIPs
                self.current_stage = "proxyip_pool"
                await self.refresh_proxyip_pool_only()

                # Auto-apply freshest Clean IP + ProxyIP to panels
                if self.store.data["settings"].get("auto_apply_ip", True):
                    best_proxy = self.get_best_proxyip()
                    for panel in self.store.data.get("panels", {}).values():
                        if panel.get("auto_ip", True):
                            best = self.get_best_operator_ips(panel.get("operator", "mci"), 1)
                            if best:
                                panel["clean_ip"] = best[0]["ip"]
                        if panel.get("auto_proxyip", True) and best_proxy:
                            panel["proxy_ip"] = best_proxy["address"]

                # Phase 3: Real WARP IPv4 + IPv6 UDP Handshake
                self.current_stage = "warp_udp"
                probe_dev = await self._ensure_probe_device()
                now = datetime.now(timezone.utc)
                if probe_dev:
                    sem = asyncio.Semaphore(12)

                    async def _test_pair(host: str, port: int, version: int):
                        async with sem:
                            ok, rtt = await probe_real_warp_handshake(
                                host, port, probe_dev["private_key"], probe_dev["peer_public_key"],
                                reserved=probe_dev["reserved"], timeout_sec=timeout_sec,
                            )
                            if not ok or rtt is None:
                                return None
                            return {"endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}", "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat()}

                    v4_res, v6_res = await asyncio.gather(
                        asyncio.gather(*(_test_pair(h, p, 4) for h, p in generate_warp_v4_candidates(28))),
                        asyncio.gather(*(_test_pair(*split_endpoint(ep), 6) for ep in OFFICIAL_WARP_IPV6_ENDPOINTS)),
                    )
                    v4_ok = sorted([x for x in v4_res if x], key=lambda x: x["latency_ms"])[:20]
                    v6_ok = sorted([x for x in v6_res if x], key=lambda x: x["latency_ms"])[:10]
                    if v4_ok:
                        self.store.data["warp_v4_pool"] = v4_ok
                    if v6_ok:
                        self.store.data["warp_v6_pool"] = v6_ok

                self.last_scan_at = now.isoformat()
                self.store.save()
                return {
                    "mci": len(self.store.data["operator_pools"].get("mci", [])),
                    "mtn": len(self.store.data["operator_pools"].get("mtn", [])),
                    "mkh": len(self.store.data["operator_pools"].get("mkh", [])),
                    "proxyips": len(self.store.data.get("proxyip_pool", [])),
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    def get_best_operator_ips(self, op: str = "mci", count: int = 5) -> list[dict[str, Any]]:
        items = list(self.store.data.get("operator_pools", {}).get(op, []))[:count]
        for it in items:
            it["operator"] = op
        return items

    def get_best_proxyips(self, count: int = 8) -> list[dict[str, Any]]:
        return list(self.store.data.get("proxyip_pool", []))[:count]

    def get_best_proxyip(self) -> dict[str, Any] | None:
        pool = self.store.data.get("proxyip_pool", [])
        return pool[0] if pool else None

    def get_best_warp_endpoints(self) -> tuple[str, str, float | None]:
        v4 = self.store.data.get("warp_v4_pool", [])
        v6 = self.store.data.get("warp_v6_pool", [])
        ep4 = v4[0]["endpoint"] if v4 else "162.159.192.1:2408"
        ep6 = v6[0]["endpoint"] if v6 else OFFICIAL_WARP_IPV6_ENDPOINTS[0]
        ping = v4[0]["latency_ms"] if v4 else (v6[0]["latency_ms"] if v6 else None)
        return ep4, ep6, ping
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/store.py
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
            "proxyip_pool": [],
            "manual_proxyips": [],
            "warp_v4_pool": [],
            "warp_v6_pool": [],
            "warp_probe_device": None,
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "maintenance_mode": False,
                "auto_apply_ip": True,
                "auto_scan_enabled": True,
                "auto_scan_interval_hours": 6,
                "scan_timeout_sec": 2.8,
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
                    "lang": "fa", "is_banned": False, "joined_at": now, "last_seen": now,
                    "configs_generated": 0, "warp_generated": 0,
                }
                self.data["users"][key] = u
            else:
                u["username"] = username or u.get("username", "")
                u["full_name"] = full_name or u.get("full_name", "")
                u["last_seen"] = now
                u.setdefault("lang", "fa")
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
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/cf_manager.py
from __future__ import annotations

import asyncio
import json
import random
import string
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urlencode

import httpx

from app.bot.operator_scanner import OPERATOR_LABELS
from app.bot.warp_builder import format_beautiful_name
from app.bot.worker_template import render_worker_script
from app.bot.ws_tester import test_worker_tunnel_e2e


@dataclass
class CloudflareDeployResult:
    ok: bool
    account_id: str | None = None
    account_name: str | None = None
    script_name: str | None = None
    worker_host: str | None = None
    sub_url: str | None = None
    vless_verified: bool = False
    vless_ms: float | None = None
    trojan_verified: bool = False
    trojan_ms: float | None = None
    error: str | None = None


class CloudflarePanelService:
    BASE = "https://api.cloudflare.com/client/v4"

    async def deploy_dual_worker(
        self,
        api_token: str,
        user_uuid: str,
        trojan_password: str,
        script_name: str,
        verified_proxyips: list[str] | None = None,
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
                        return CloudflareDeployResult(ok=False, error="لطفاً یک‌بار در کلودفلر وارد Workers & Pages شوید تا ساب‌دامنه رایگان workers.dev ساخته شود.")

                worker_js = render_worker_script(
                    user_uuid=user_uuid,
                    trojan_password=trojan_password,
                    verified_proxyips=verified_proxyips,
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

                await asyncio.sleep(2.0)
                top_proxy = verified_proxyips[0] if verified_proxyips else None
                (v_ok, v_ms, _), (t_ok, t_ms, _) = await asyncio.gather(
                    test_worker_tunnel_e2e(worker_host, None, "vless", user_uuid, proxy_ip=top_proxy),
                    test_worker_tunnel_e2e(worker_host, None, "trojan", trojan_password, proxy_ip=top_proxy),
                )

                return CloudflareDeployResult(
                    ok=True,
                    account_id=account_id,
                    account_name=account_name,
                    script_name=script_name,
                    worker_host=worker_host,
                    sub_url=sub_url,
                    vless_verified=v_ok,
                    vless_ms=v_ms,
                    trojan_verified=t_ok,
                    trojan_ms=t_ms,
                )
        except Exception as exc:
            return CloudflareDeployResult(ok=False, error=f"خطا در اتصال به کلودفلر: {exc}")

    @staticmethod
    def _ws_path(proxy_ip: str | None) -> str:
        clean_proxy = (proxy_ip or "").strip()
        if clean_proxy:
            return f"/proxyip={clean_proxy}?ed=2560"
        return "/?ed=2560"

    @staticmethod
    def build_vless_uri(
        panel: dict[str, Any],
        ip: str,
        operator: str = "mci",
        ping_ms: float | None = None,
        colo: str = "",
        proxy_ip: str | None = None,
    ) -> str:
        host_part = f"[{ip}]" if ":" in ip else ip
        params = {
            "encryption": "none",
            "security": "tls",
            "type": "ws",
            "host": panel["host"],
            "sni": panel["sni"],
            "path": CloudflarePanelService._ws_path(proxy_ip or panel.get("proxy_ip")),
            "fp": "chrome",
            "alpn": "http/1.1",
        }
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        tag = format_beautiful_name(op_lbl, "VLESS", ping_ms, colo)
        return f"vless://{panel['uuid']}@{host_part}:443?{urlencode(params)}#{quote(tag)}"

    @staticmethod
    def build_trojan_uri(
        panel: dict[str, Any],
        ip: str,
        operator: str = "mci",
        ping_ms: float | None = None,
        colo: str = "",
        proxy_ip: str | None = None,
    ) -> str:
        host_part = f"[{ip}]" if ":" in ip else ip
        params = {
            "security": "tls",
            "type": "ws",
            "host": panel["host"],
            "sni": panel["sni"],
            "path": CloudflarePanelService._ws_path(proxy_ip or panel.get("proxy_ip")),
            "fp": "chrome",
            "alpn": "http/1.1",
        }
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        tag = format_beautiful_name(op_lbl, "Trojan", ping_ms, colo)
        tpass = quote(panel["trojan_password"], safe="")
        return f"trojan://{tpass}@{host_part}:443?{urlencode(params)}#{quote(tag)}"
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/ui.py
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
    "%5D&accountId=*&zoneId=all&name=CFHubV8"
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
            [btn("📶 Clean IPs by Operator", callback_data="m:isp", style="primary")],
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

    top = (
        [btn("🎛️ پنل من (VLESS + Trojan)", callback_data="m:mypanel", style="success")]
        if has_panel
        else [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")]
    )
    rows = [
        top,
        [btn("🛡️ کانفیگ WARP و WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
        [btn("📶 آی‌پی تمیز اپراتورها", callback_data="m:isp", style="primary")],
        [
            btn("📱 برنامه‌ها", callback_data="m:apps", style="primary"),
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
    return kb([[btn("🔙 بازگشت" if lang == "fa" else "🔙 Back", callback_data=back_cb, style="primary")]])
__CFHUB_V8_EOF__

cat <<'__CFHUB_V8_EOF__' > backend/app/bot/bot.py
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
from app.bot.ws_tester import test_worker_tunnel_e2e
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
    waiting_support_msg = State()
    adm_import_op_ips = State()
    adm_import_proxyips = State()
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


async def _send_safe_qr(target_msg: Message, payload: str, short_caption: str) -> None:
    """Sends QR photo with a guaranteed short (<200 char) safe caption so Telegram HTML parser NEVER crashes."""
    try:
        uri = generate_qr_png_base64(payload)
        if uri.startswith("data:image/png;base64,"):
            raw = base64.b64decode(uri.split(",", 1)[1])
            await target_msg.answer_photo(
                photo=BufferedInputFile(raw, filename="qr.png"),
                caption=short_caption[:200],
                parse_mode="HTML",
            )
    except Exception as exc:
        logger.warning("QR delivery skipped safely: %s", exc)


def _home_text(tg_id: int) -> str:
    pools = store.data.get("operator_pools", {})
    proxies = store.data.get("proxyip_pool", [])
    panel = store.data.get("panels", {}).get(str(tg_id))
    panel_line = (
        f"🎛️ پنل شما: 🟢 <b>فعال</b> (<code>{html.escape(panel['host'])}</code>)"
        if panel
        else "🎛️ پنل شما: ⚪ هنوز ساخته نشده"
    )
    proxy_line = (
        f"🔁 ProxyIP سالم: <b>{len(proxies)}</b> (برترین: <b>{proxies[0]['latency_ms']}ms • {proxies[0]['colo']}</b>)"
        if proxies
        else "🔁 ProxyIP سالم: در حال تست خودکار..."
    )
    return (
        "⚡ <b>Cloudflare Config Hub — کانفیگ رایگان و تست‌شده</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> | 🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> | 🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b>\n"
        f"{proxy_line}\n"
        f"🛡️ رله WARP سالم: <b>{len(store.data.get('warp_v4_pool', []))}</b> IPv4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> IPv6\n"
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
    t, m = _build_admin_dashboard()
    await message.answer(t, reply_markup=m, parse_mode="HTML")


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


# ==================== 1. PANEL DEPLOY (DIRECT CF TOKEN -> REAL E2E VERIFIED VLESS + TROJAN) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    uid = cb.from_user.id
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت پنل رایگان (VLESS + Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلودفلر نداری، اول ثبت‌نام کن.\n"
        "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن (تمام دسترسی‌ها آماده است).\n"
        "3️⃣ در کلودفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "🔐 <i>پیام توکن بلافاصله پاک و رمزنگاری می‌شود و بهترین ProxyIP تست‌شده به‌طور خودکار روی کانفیگ‌ها سوار می‌شود.</i>"
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

    wait_msg = await message.answer("⏳ <b>در حال دیپلوی واقعی Worker دوپروتکله (VLESS + Trojan) + نصب خودکار ProxyIP...</b>", parse_mode="HTML")

    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    script_name = old.get("script_name") or f"cfhub-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"

    # Ensure we have live verified ProxyIPs before deploying
    proxy_objs = bg_engine.get_best_proxyips(8)
    if not proxy_objs:
        proxy_objs = await bg_engine.refresh_proxyip_pool_only()
    verified_proxies = [x["address"] for x in proxy_objs[:8]]

    dep = await cf_service.deploy_dual_worker(
        api_token=raw_token,
        user_uuid=panel_uuid,
        trojan_password=trojan_pass,
        script_name=script_name,
        verified_proxyips=verified_proxies,
        operator_pools=store.data.get("operator_pools", {}),
        brand="CFHub",
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
    top_proxy = verified_proxies[0] if verified_proxies else "proxyip.cmliussss.net:443"

    store.data["panels"][str(uid)] = {
        "uuid": panel_uuid,
        "trojan_password": trojan_pass,
        "script_name": dep.script_name,
        "host": dep.worker_host,
        "sni": dep.worker_host,
        "sub_url": dep.sub_url,
        "operator": old.get("operator", "mci"),
        "clean_ip": clean_ip,
        "proxy_ip": top_proxy,
        "auto_ip": True,
        "auto_proxyip": True,
        "worker_version": "v8",
        "created_at": old.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    v_badge = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else "🟡 در انتظار انتشار"
    t_badge = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else "🟡 در انتظار انتشار"
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"🎉 <b>پنل شما با موفقیت دیپلوی شد!</b>\n"
        f"🩺 VLESS: <b>{v_badge}</b> | Trojan: <b>{t_badge}</b>\n\n{text}",
        parse_mode="HTML",
        reply_markup=markup,
    )


# ==================== 2. MY PANEL (FIXED OPERATOR DELIVERY + AUTO PROXYIP BUTTON + NO RENAME CLUTTER) ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return (
            "🎛️ <b>پنل من</b>\n━━━━━━━━━━━━━━━━━━━━\nهنوز پنل رایگان نساخته‌اید. روی دکمه سبز زیر بزنید:",
            kb([
                [btn("🚀 ساخت پنل رایگان (VLESS + Trojan)", callback_data="m:turbo", style="success")],
                [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
            ]),
        )

    op = panel.get("operator", "mci")
    best_p = bg_engine.get_best_proxyip()
    active_proxy = panel.get("proxy_ip") or (best_p["address"] if best_p else "proxyip.cmliussss.net:443")
    ver_note = "" if panel.get("worker_version") == "v8" else "\n⚠️ <i>یک‌بار دکمه <b>♻️ آپدیت Worker</b> را بزنید تا نسخه سالم V8 فعال شود.</i>\n"

    text = (
        "🎛️ <b>پنل اختصاصی من (VLESS + Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 Worker: <code>{html.escape(panel['host'])}</code>\n"
        f"📶 اپراتور فعال: <b>{OPERATOR_LABELS.get(op, op)}</b>\n"
        f"🟢 IP تمیز فعال: <code>{html.escape(panel.get('clean_ip', '-'))}</code>\n"
        f"🔁 ProxyIP خودکار: <code>{html.escape(active_proxy)}</code>\n"
        f"🔗 لینک سابسکریپشن (همه اپراتورها):\n<code>{html.escape(panel.get('sub_url', ''))}</code>\n"
        f"{ver_note}"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 اپراتور خود را بزنید تا کانفیگ سالم <b>VLESS + Trojan</b> دریافت کنید:"
    )
    markup = kb([
        [
            btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
            btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
            btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
        ],
        [btn("🚀 نصب خودکار قوی‌ترین ProxyIP (یک‌کلیک)", callback_data="cf:auto_proxyip", style="success")],
        [
            btn("🩺 تست واقعی تونل", callback_data="cf:e2e_test", style="primary"),
            btn("♻️ آپدیت Worker", callback_data="cf:redeploy", style="primary"),
        ],
        [btn("🗑️ حذف پنل", callback_data="cf:disconnect", style="danger")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    t, m = _render_personal_panel(cb.from_user.id)
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("cf:getop:"))
async def cb_cf_get_by_op(cb: CallbackQuery) -> None:
    """
    FIXED V8 DELIVERY:
    Never truncates HTML inside an answer_photo caption!
    Sends full guaranteed HTML text message (4096-char safe) + separate short-caption QR photo + full try/except.
    """
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await cb.answer("⚠️ ابتدا پنل خود را بسازید.", show_alert=True)
        return

    await cb.answer(f"⚡ آماده‌سازی کانفیگ {OPERATOR_LABELS.get(op, op)}...")
    try:
        # 1) Pick best verified IP for this exact Iran operator
        best_ips = bg_engine.get_best_operator_ips(op, 6)
        if best_ips:
            idx = int(panel.get(f"idx_{op}", 0)) % len(best_ips)
            panel[f"idx_{op}"] = idx + 1
            chosen = best_ips[idx]
            ip = chosen["ip"]
            ping_ms = chosen.get("latency_ms")
            colo = chosen.get("colo", "CF")
        else:
            ip = panel.get("clean_ip") or "104.16.132.229"
            ping_ms = None
            colo = "CF"

        # 2) Auto-mount the fastest verified ProxyIP onto the config!
        best_proxy = bg_engine.get_best_proxyip()
        active_proxy = (best_proxy["address"] if best_proxy and panel.get("auto_proxyip", True) else panel.get("proxy_ip")) or "proxyip.cmliussss.net:443"
        proxy_badge = f"<code>{html.escape(active_proxy)}</code>"
        if best_proxy and best_proxy["address"] == active_proxy:
            proxy_badge += f" (🟢{best_proxy['latency_ms']}ms • {best_proxy['colo']})"

        panel["operator"] = op
        panel["clean_ip"] = ip
        panel["proxy_ip"] = active_proxy
        if not panel.get("trojan_password"):
            panel["trojan_password"] = secrets.token_urlsafe(12)
        store.save()
        store.increment_stat(uid, "configs_generated")

        vless_uri = cf_service.build_vless_uri(panel, ip, op, ping_ms, colo, proxy_ip=active_proxy)
        trojan_uri = cf_service.build_trojan_uri(panel, ip, op, ping_ms, colo, proxy_ip=active_proxy)
        op_sub = f"{panel.get('sub_url', '')}?op={op}"
        op_lbl = OPERATOR_LABELS.get(op, op)

        # Send full clean TEXT message (NEVER hits 1024-char photo caption truncation!)
        msg_text = (
            f"✅ <b>کانفیگ‌های سالم {op_lbl} آماده شد</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"🟢 IP تمیز اپراتور: <code>{html.escape(ip)}</code>" + (f" (<b>{ping_ms}ms • {colo}</b>)" if ping_ms else "") + "\n"
            f"🔁 ProxyIP خودکار: {proxy_badge}\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"1️⃣ <b>کانفیگ VLESS (برای کپی لمس کنید):</b>\n"
            f"<code>{html.escape(vless_uri)}</code>\n\n"
            f"2️⃣ <b>کانفیگ Trojan (برای کپی لمس کنید):</b>\n"
            f"<code>{html.escape(trojan_uri)}</code>\n\n"
            f"🔗 <b>لینک سابسکریپشن {op_lbl}:</b>\n"
            f"<code>{html.escape(op_sub)}</code>"
        )
        nav = kb([
            [btn(f"🔄 IP دیگر برای {op_lbl}", callback_data=f"cf:getop:{op}", style="success")],
            [btn("🚀 تعویض خودکار ProxyIP", callback_data="cf:auto_proxyip", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ])
        await cb.message.answer(msg_text, parse_mode="HTML", disable_web_page_preview=True, reply_markup=nav)

        # Send clean QR code in a separate short-caption message
        await _send_safe_qr(cb.message, vless_uri, f"📱 <b>QR Code — {op_lbl} (VLESS)</b>")
    except Exception as exc:
        logger.exception("Failed delivering operator config: %s", exc)
        await cb.message.answer(
            f"❌ خطایی هنگام ارسال کانفیگ رخ داد: <code>{html.escape(str(exc))}</code>",
            parse_mode="HTML",
            reply_markup=back_home_kb("m:mypanel"),
        )


@router.callback_query(F.data == "cf:auto_proxyip")
async def cb_cf_auto_proxyip(cb: CallbackQuery) -> None:
    """One-click live ProxyIP verifier & auto-mounter! Finds the best working ProxyIP via real E2E test against cp.cloudflare.com."""
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await cb.answer("⚠️ ابتدا پنل خود را بسازید.", show_alert=True)
        return

    await cb.answer("🚀 در حال یافتن قوی‌ترین ProxyIP...")
    wait = await cb.message.answer("⏳ <b>در حال بررسی زنده لیست ProxyIPهای سالم و تست واقعی پینگ با کلودفلر...</b>", parse_mode="HTML")

    try:
        pool = bg_engine.get_best_proxyips(12)
        if not pool:
            pool = await bg_engine.refresh_proxyip_pool_only()

        # Test top candidates E2E through user's OWN Worker targeting cp.cloudflare.com (forces ProxyIP!)
        chosen_addr = None
        chosen_ms = None
        chosen_colo = "CF"
        for cand in pool[:6]:
            ok, ms, _ = await test_worker_tunnel_e2e(
                panel["host"],
                panel.get("clean_ip"),
                "vless",
                panel["uuid"],
                proxy_ip=cand["address"],
                target_host="cp.cloudflare.com",
                timeout_sec=5.5,
            )
            if ok and ms is not None:
                chosen_addr = cand["address"]
                chosen_ms = ms
                chosen_colo = cand.get("colo", "CF")
                break

        if not chosen_addr and pool:
            # Rotate to next verified ProxyIP from TLS trace pool
            p_idx = int(panel.get("proxy_idx", 0)) % len(pool)
            panel["proxy_idx"] = p_idx + 1
            chosen = pool[p_idx]
            chosen_addr = chosen["address"]
            chosen_ms = chosen.get("latency_ms")
            chosen_colo = chosen.get("colo", "CF")

        if not chosen_addr:
            await wait.edit_text(
                "⚠️ در این لحظه ProxyIP سالمی در استخر یافت نشد. چند ثانیه بعد دوباره امتحان کنید.",
                reply_markup=back_home_kb("m:mypanel"),
            )
            return

        panel["proxy_ip"] = chosen_addr
        panel["auto_proxyip"] = True
        store.save()

        op = panel.get("operator", "mci")
        await wait.edit_text(
            f"✅ <b>قوی‌ترین ProxyIP سالم انتخاب و به‌صورت خودکار روی کانفیگ‌های شما سوار شد!</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"🔁 ProxyIP فعال: <code>{html.escape(chosen_addr)}</code>\n"
            f"⚡ پینگ تاییدشده: <b>{chosen_ms}ms</b> | دیتاسنتر: <b>{chosen_colo}</b>\n\n"
            f"👇 الان روی دکمه اپراتور خود بزنید تا کانفیگ جدید با همین ProxyIP ارسال شود:",
            parse_mode="HTML",
            reply_markup=kb([
                [
                    btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
                    btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
                    btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
                ],
                [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
            ]),
        )
    except Exception as exc:
        logger.exception("Auto ProxyIP error: %s", exc)
        await wait.edit_text(f"❌ خطا: <code>{html.escape(str(exc))}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:mypanel"))


@router.callback_query(F.data == "cf:e2e_test")
async def cb_cf_e2e_test(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer("🩺 در حال تست واقعی...")
    wait = await cb.message.answer("⏳ در حال تست واقعی VLESS، Trojan و ProxyIP از طریق Worker شما...")
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)
        store.save()

    p_ip = panel.get("proxy_ip")
    (v_ok, v_ms, v_m), (t_ok, t_ms, t_m), (p_ok, p_ms, p_m) = await asyncio.gather(
        test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "vless", panel["uuid"], proxy_ip=p_ip),
        test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "trojan", panel["trojan_password"], proxy_ip=p_ip),
        test_worker_tunnel_e2e(panel["host"], panel["clean_ip"], "vless", panel["uuid"], proxy_ip=p_ip, target_host="cp.cloudflare.com"),
    )
    v_l = f"🟢 <b>موفق</b> ({v_ms}ms)" if v_ok else f"🔴 ناموفق ({html.escape(v_m)})"
    t_l = f"🟢 <b>موفق</b> ({t_ms}ms)" if t_ok else f"🔴 ناموفق ({html.escape(t_m)})"
    p_l = f"🟢 <b>موفق</b> ({p_ms}ms)" if p_ok else f"🔴 ناموفق ({html.escape(p_m)})"

    await wait.edit_text(
        f"🩺 <b>نتیجه تست سرتاسری پنل شما</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 VLESS: {v_l}\n"
        f"🔐 Trojan: {t_l}\n"
        f"🔁 ProxyIP (<code>{html.escape(str(p_ip or '-'))}</code>): {p_l}",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("🚀 نصب خودکار قوی‌ترین ProxyIP", callback_data="cf:auto_proxyip", style="success")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel or not cb.message:
        await cb.answer("⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return
    await cb.answer("♻️ در حال آپدیت Worker...")
    try:
        token = store.decrypt_secret(cf["encrypted_token"])
    except Exception:
        await cb.answer("❌ لطفاً توکن را مجدد وارد کنید.", show_alert=True)
        return
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    verified_proxies = [x["address"] for x in bg_engine.get_best_proxyips(8)]
    dep = await cf_service.deploy_dual_worker(
        api_token=token,
        user_uuid=panel["uuid"],
        trojan_password=panel["trojan_password"],
        script_name=panel.get("script_name", f"cfhub-{uid % 9999}"),
        verified_proxyips=verified_proxies,
        operator_pools=store.data.get("operator_pools", {}),
        brand="CFHub",
    )
    if dep.ok:
        panel["host"] = dep.worker_host
        panel["sni"] = dep.worker_host
        panel["sub_url"] = dep.sub_url
        panel["worker_version"] = "v8"
        if verified_proxies:
            panel["proxy_ip"] = verified_proxies[0]
        store.save()
        v_s = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else "🟡 تست مجدد"
        t_s = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else "🟡 تست مجدد"
        text, markup = _render_personal_panel(uid)
        await _edit(cb, f"✅ <b>Worker با کد سالم V8 و ProxyIPهای تاییدشده آپدیت شد!</b>\nVLESS: <b>{v_s}</b> | Trojan: <b>{t_s}</b>\n\n{text}", markup)
    else:
        await cb.message.answer(f"❌ خطا در آپدیت: <code>{html.escape(dep.error or '')}</code>", parse_mode="HTML")


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await cb.answer("🗑️ پنل حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid)))


# ==================== 3. WARP / WIREGUARD (WORKING CORE) ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    ep4, ep6, _ = bg_engine.get_best_warp_endpoints()
    text = (
        "🛡️ <b>کانفیگ‌های WARP و WireGuard (سالم و تست‌شده)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 رله IPv4: <code>{html.escape(ep4)}</code>\n"
        f"🌐 رله IPv6: <code>{html.escape(ep6)}</code>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "نسخه IP مورد نظر را انتخاب کنید:"
    )
    markup = kb([
        [btn("🌐 IPv6 (پرسرعت و ضد اختلال)", callback_data="warp:mode:ipv6", style="success")],
        [btn("⚡ Dual-Stack (IPv4 + IPv6)", callback_data="warp:mode:dual", style="primary")],
        [btn("🌐 IPv4 (سازگار با همه خطوط)", callback_data="warp:mode:ipv4", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:mode:"))
async def cb_warp_plat(cb: CallbackQuery) -> None:
    await cb.answer()
    mode = cb.data.split(":")[2]
    text = f"🛡️ <b>WARP ({mode.upper()})</b>\n━━━━━━━━━━━━━━━━━━━━\nدستگاه خود را انتخاب کنید:"
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:go:{mode}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:go:{mode}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:go:{mode}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:go:"))
async def cb_warp_go(cb: CallbackQuery) -> None:
    _, _, ip_mode, platform = cb.data.split(":")
    await cb.answer("⏳ ثبت کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return

    wait = await cb.message.answer("⏳ در حال ساخت کلید اختصاصی WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(f"❌ خطا: <code>{html.escape(reg.error or '')}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:warp"))
        return

    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping)  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    await wait.delete()

    txt = (
        f"✅ <b>کانفیگ WARP آماده شد</b>\n"
        f"🏷️ <b>{html.escape(b['label'])}</b>\n"
        f"🎯 رله: <code>{html.escape(b['endpoint'])}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>پیشنهاد اول (Hiddify / Streisand — اسکن خودکار روی اینترنت شما):</b>\n"
        f"<code>{html.escape(b['warp_auto_uri'])}</code>\n\n"
        f"2️⃣ <b>لینک دولایه WoW (Hiddify / Karing):</b>\n"
        f"<code>{html.escape(b['wow_uri'])}</code>\n\n"
        f"3️⃣ <b>لینک WireGuard ({ip_mode.upper()} — v2rayNG / MahsaNG):</b>\n"
        f"<code>{html.escape(b['wireguard_uri'])}</code>"
    )
    await cb.message.answer(txt, parse_mode="HTML")
    await cb.message.answer_document(
        document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
        caption=f"🛡️ <b>فایل آماده AmneziaWG ({ip_mode.upper()})</b>",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("🔄 ساخت کلید جدید", callback_data=cb.data, style="success")],
            [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
        ]),
    )


# ==================== 4. CLEAN IPS BY OPERATOR ====================
@router.callback_query(F.data == "m:isp")
async def cb_isp(cb: CallbackQuery) -> None:
    await cb.answer()
    pools = store.data.get("operator_pools", {})
    text = (
        "📶 <b>آی‌پی‌های تمیز دسته‌بندی‌شده بر اساس اپراتور</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> IP\n"
        f"🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> IP\n"
        f"🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b> IP"
    )
    markup = kb([
        [btn("🔵 همراه اول", callback_data="isp:show:mci", style="primary")],
        [btn("🟡 ایرانسل", callback_data="isp:show:mtn", style="primary")],
        [btn("🟢 مخابرات", callback_data="isp:show:mkh", style="success")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("isp:show:"))
async def cb_isp_show(cb: CallbackQuery) -> None:
    await cb.answer()
    op = cb.data.split(":")[2]
    ips = bg_engine.get_best_operator_ips(op, 10)
    lbl = OPERATOR_LABELS.get(op, op)
    body = "\n".join(
        f"{i+1}. <code>{x['ip']}</code> | 🟢<b>{x['latency_ms']}ms</b> | {x.get('colo', 'CF')}"
        for i, x in enumerate(ips)
    ) or "⏳ در حال دریافت لیست..."
    rows = []
    if _has_panel(cb.from_user.id):
        rows.append([btn(f"⚡ دریافت VLESS + Trojan روی {lbl}", callback_data=f"cf:getop:{op}", style="success")])
    rows.append([btn("🔙 اپراتورها", callback_data="m:isp", style="primary")])
    await _edit(cb, f"📶 <b>IP تمیز {lbl}</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


# ==================== 5. APPS, GUIDE & SUPPORT ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await cb.answer()
    markup = kb([
        [btn("🔥 Hiddify (اندروید / آیفون / ویندوز — پیشنهادی)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (ضد فیلتر WARP)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (اندروید)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (آیفون)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (ویندوز)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, "📱 <b>اپلیکیشن‌های پیشنهادی:</b>", markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📖 <b>راهنمای اتصال سریع</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>پنل VLESS + Trojan:</b>\n"
        "• توکن کلودفلر را یک‌بار ارسال کنید تا پنل شما ساخته شود.\n"
        "• داخل «🎛️ پنل من» اپراتور خود را بزنید تا لینک <b>VLESS</b> و <b>Trojan</b> با ProxyIP خودکار برایتان ارسال شود.\n"
        "• در صورت افت سرعت، دکمه <b>🚀 نصب خودکار قوی‌ترین ProxyIP</b> را بزنید.\n\n"
        "2️⃣ <b>کانفیگ WARP:</b>\n"
        "• لینک <code>warp://auto...</code> را در <b>Hiddify</b> یا فایل <code>.conf</code> را در <b>AmneziaWG</b> باز کنید."
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
        rows.append([btn(f"💬 چت مستقیم (@{sup_u})", url=f"https://t.me/{sup_u}", style="success")])
        line = f"👤 پشتیبانی: @{html.escape(sup_u)}"
    elif sup_id:
        rows.append([btn("💬 چت مستقیم با مدیریت", url=f"tg://user?id={sup_id}", style="success")])
        line = f"👤 شناسه پشتیبانی: <code>{sup_id}</code>"
    else:
        line = "👤 پشتیبانی آنلاین فعال است."
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
    await message.answer(f"✅ تیکت <b>#{tno}</b> ثبت شد.", parse_mode="HTML", reply_markup=back_home_kb("m:home"))


# ==================== 6. CLEAN PRO ADMIN PANEL (WITH PROXYIP POOL MANAGEMENT) ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    proxies = store.data.get("proxyip_pool", [])
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        "🛠️ <b>پنل مدیریت V8</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | آخرین اسکن: <code>{last_s}</code>\n"
        f"📶 IP اپراتورها: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))}\n"
        f"🔁 استخر ProxyIP سالم: <b>{len(proxies)}</b>\n"
        f"🛡️ WARP سالم: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل فعال: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [btn("▶️ اسکن فوری (اپراتورها + ProxyIP + WARP)", callback_data="adm:scan_now", style="success")],
        [
            btn("🔁 استخر ProxyIP سالم", callback_data="adm:proxyips", style="success"),
            btn("👥 مدیریت کاربران", callback_data="adm:users:0", style="primary"),
        ],
        [
            btn("🔵 IP همراه اول", callback_data="adm:addop:mci", style="primary"),
            btn("🟡 IP ایرانسل", callback_data="adm:addop:mtn", style="primary"),
            btn("🟢 IP مخابرات", callback_data="adm:addop:mkh", style="primary"),
        ],
        [
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
            btn("⚙️ تنظیمات", callback_data="adm:settings", style="primary"),
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
    t, m = _build_admin_dashboard()
    await _edit(cb, t, m)


@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    if bg_engine.is_scanning:
        await cb.answer("⏳ در حال اجراست.", show_alert=True)
        return
    asyncio.create_task(bg_engine.run_full_cycle(trigger="admin"))
    await cb.answer("🚀 اسکن کامل اپراتورها، ProxyIP و WARP شروع شد!", show_alert=True)
    await asyncio.sleep(0.4)
    t, m = _build_admin_dashboard()
    await _edit(cb, t, m)


@router.callback_query(F.data == "adm:proxyips")
async def cb_adm_proxyips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    pool = bg_engine.get_best_proxyips(12)
    body = "\n".join(
        f"{i+1}. <code>{x['address']}</code> | 🟢<b>{x['latency_ms']}ms</b> | {x.get('colo', 'CF')} ({x.get('source', '')[:16]})"
        for i, x in enumerate(pool)
    ) or "⏳ در حال تست استخر ProxyIP..."
    await _edit(
        cb,
        f"🔁 <b>استخر ProxyIPهای سالم و تاییدشده ({len(store.data.get('proxyip_pool', []))})</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}",
        kb([
            [btn("🔄 تست و رفرش فوری ProxyIPها", callback_data="adm:refresh_proxy", style="success")],
            [btn("➕ افزودن ProxyIP اختصاصی", callback_data="adm:add_proxy", style="primary")],
            [btn("🔙 پنل مدیریت", callback_data="adm:home", style="danger")],
        ]),
    )


@router.callback_query(F.data == "adm:refresh_proxy")
async def cb_adm_refresh_proxy(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer("⏳ در حال تست ProxyIPها...")
    await bg_engine.refresh_proxyip_pool_only()
    await cb_adm_proxyips(cb)


@router.callback_query(F.data == "adm:add_proxy")
async def cb_adm_add_proxy(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_import_proxyips)
    await _edit(cb, "➕ آدرس‌های ProxyIP (به‌صورت <code>IP:443</code> یا دامنه) را ارسال کنید:", kb([[btn("❌ انصراف", callback_data="adm:proxyips", style="danger")]]))


@router.message(Flow.adm_import_proxyips)
async def handle_adm_add_proxy(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    items = [x.strip() for x in (message.text or "").replace(",", " ").split() if x.strip()]
    added = 0
    for it in items:
        if it not in store.data["manual_proxyips"]:
            store.data["manual_proxyips"].append(it)
            added += 1
    store.save()
    await state.clear()
    asyncio.create_task(bg_engine.refresh_proxyip_pool_only())
    await message.answer(f"✅ {added} مورد اضافه شد و تست زنده آغاز گردید.", reply_markup=back_home_kb("adm:proxyips"))


@router.callback_query(F.data.startswith("adm:addop:"))
async def cb_adm_addop(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    op = cb.data.split(":")[2]
    await state.update_data(target_op=op)
    await state.set_state(Flow.adm_import_op_ips)
    await _edit(cb, f"➕ IPهای تمیز {OPERATOR_LABELS.get(op, op)} را ارسال کنید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_import_op_ips)
async def handle_adm_import_op(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    import ipaddress
    op = (await state.get_data()).get("target_op", "mci")
    added = 0
    for item in (message.text or "").replace(",", " ").split():
        try:
            ip_s = str(ipaddress.ip_address(item.strip()))
            if ip_s not in store.data["manual_operator_ips"][op]:
                store.data["manual_operator_ips"][op].append(ip_s)
                added += 1
        except ValueError:
            continue
    store.save()
    await state.clear()
    asyncio.create_task(bg_engine.run_full_cycle(trigger=f"manual_{op}"))
    await message.answer(f"✅ {added} IP به {OPERATOR_LABELS.get(op, op)} اضافه شد.", reply_markup=back_home_kb("adm:home"))


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
    await _edit(cb, "🔎 آیدی یا <code>@username</code> را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:users:0", style="danger")]]))


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
    logger.info("Starting V8 Background Engine (Operator Clean IPs + Verified ProxyIP Pool + WARP IPv4/IPv6)...")
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
    logger.info("Starting Cloudflare Config Hub V8 Pro Bot.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V8_EOF__

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
'

echo ">>> Rebuilding and restarting telegram_bot..."
docker compose up -d --build telegram_bot
sleep 4
docker compose logs --tail=30 telegram_bot
echo ">>> V8 Upgrade complete! Send /start -> My Panel -> Update Worker -> Tap your Operator."
