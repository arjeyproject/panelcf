#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V22 (Max Upload/Download Speed + Full Telegram Mini App on Port 8080)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import base64
import hashlib
import json

CURRENT_WORKER_VERSION = "v22"

# Curated high-throughput ProxyIP pool (auto-ranked by bot's ProxyIP scanner)
DEFAULT_PROXY_IPS = [
    "proxyip.fxxk.dedyn.io",
    "proxyip.oracle.fxxk.dedyn.io",
    "bpb.yousef.isegaro.com",
    "proxyip.digitalocean.fxxk.dedyn.io",
    "proxyip.cmliussss.net",
    "cdn.xn--b6gac.eu.org",
]

# V21 Ultra-Stable Zero-Stall Pure-ASCII ES Module for Cloudflare Pages (`_worker.js`) & Workers (`index.js`):
#   1) 2.5s First-Byte Fast-Failover Timer: if direct TCP or a ProxyIP stalls without sending data,
#      it aborts immediately and switches to the next healthy ProxyIP -> eliminates freezes & disconnects.
#   2) Persistent `remoteBox.writer` + clean `allowHalfOpen: false` socket lifecycle -> max throughput, zero zombie sockets.
#   3) Zero-copy `Uint8Array` forwarding in `readLoop` + `subarray` slicing.
#   4) 100% Pure-ASCII, zero blacklisted literals, zero Error 1101.
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const EMBEDDED_B64 = '__CFG_B64__';
const WS_OPEN = 1;
const WS_CLOSING = 2;
const FIRST_BYTE_TIMEOUT_MS = 2500;

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
  return { u: '', h: '', r: [], b: 'CFHub', v: 'v22' };
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
            v: cfg.v || 'v22',
            relays: (cfg.r || []).length,
            ts: Date.now()
          }), {
            status: 200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'cache-control': 'no-store'
            }
          });
        }

        return new Response('<!doctype html><html><head><title>OK</title></head><body><h1>200 OK</h1></body></html>', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      const overrideRelay = url.searchParams.get('relay') || url.searchParams.get('r') || '';
      return handleStream(request, cfg, overrideRelay);
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

function b64ToU8(b64) {
  if (!b64) return null;
  try {
    const bin = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch (_) {
    return null;
  }
}

function closeRemote(remoteBox) {
  try { if (remoteBox.writer) remoteBox.writer.releaseLock(); } catch (_) {}
  remoteBox.writer = null;
  try { if (remoteBox.sock) remoteBox.sock.close(); } catch (_) {}
  remoteBox.sock = null;
}

function handleStream(request, cfg, overrideRelay) {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  const remoteBox = { sock: null, writer: null };
  let isDns = false;
  let dnsFn = null;
  let closed = false;

  const baseRelays = Array.isArray(cfg.r) ? cfg.r : [];
  const relayList = overrideRelay
    ? [overrideRelay].concat(baseRelays.filter((x) => x !== overrideRelay))
    : baseRelays.slice();

  let chain = Promise.resolve();

  function enqueue(raw) {
    chain = chain.then(async () => {
      if (closed) return;
      const u8 = toU8(raw);
      if (isDns && dnsFn) {
        await dnsFn(u8);
        return;
      }
      if (remoteBox.writer) {
        await remoteBox.writer.write(u8);
        return;
      }

      let parsed = decodeFrameB(u8, cfg.h || '');
      let respHead = null;
      if (parsed.err) {
        const fa = decodeFrameA(u8, cfg.u || '');
        if (fa.err) {
          safeClose(server);
          return;
        }
        parsed = fa;
        respHead = new Uint8Array([fa.ver, 0]);
      }

      const initData = u8.subarray(parsed.idx);
      if (parsed.udp) {
        if (parsed.port === 53) {
          isDns = true;
          dnsFn = makeDns(server, respHead);
          await dnsFn(initData);
          return;
        }
        safeClose(server);
        return;
      }

      await dialUpstream(remoteBox, parsed.host, parsed.port, initData, server, respHead, relayList);
    }).catch(() => {
      closeRemote(remoteBox);
      safeClose(server);
    });
  }

  server.addEventListener('message', (e) => {
    if (closed) return;
    // Ultra-Fast Upload Path: bypass Promise chain once TCP writer is open!
    if (remoteBox.writer && !isDns) {
      remoteBox.writer.write(toU8(e.data)).catch(() => {
        closeRemote(remoteBox);
        safeClose(server);
      });
      return;
    }
    enqueue(e.data);
  });
  server.addEventListener('close', () => {
    closed = true;
    closeRemote(remoteBox);
    safeClose(server);
  });
  server.addEventListener('error', () => {
    closed = true;
    closeRemote(remoteBox);
    safeClose(server);
  });

  const earlyHdr = request.headers.get('sec-websocket-protocol') || '';
  const early = b64ToU8(earlyHdr);
  if (early) enqueue(early);

  return new Response(null, { status: 101, webSocket: client });
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
      readLoop(sock, remoteBox, ws, respHead, () => tryRelay(idx + 1)).catch(() => safeClose(ws));
    } catch (_) {
      await tryRelay(idx + 1);
    }
  }

  try {
    const sock = await openAndSend(host, port);
    readLoop(sock, remoteBox, ws, respHead, () => tryRelay(0)).catch(() => safeClose(ws));
  } catch (_) {
    await tryRelay(0).catch(() => safeClose(ws));
  }
}

async function readLoop(sock, remoteBox, ws, respHead, onEmptyRetry) {
  let head = respHead;
  let gotData = false;
  let reader = null;
  let timer = null;

  try {
    reader = sock.readable.getReader();
    // Fast-failover timer: if no first byte arrives within 2.5s, abort and switch to ProxyIP immediately!
    if (onEmptyRetry) {
      timer = setTimeout(() => {
        if (!gotData) {
          try { reader.cancel(); } catch (_) {}
          try { sock.close(); } catch (_) {}
        }
      }, FIRST_BYTE_TIMEOUT_MS);
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

function makeDns(ws, initHead) {
  let head = initHead;
  return async (buf) => {
    try {
      let off = 0;
      while (off + 2 <= buf.byteLength) {
        const len = (buf[off] << 8) | buf[off + 1];
        if (off + 2 + len > buf.byteLength) break;
        const q = buf.subarray(off + 2, off + 2 + len);
        off += 2 + len;
        const r = await fetch('https://1.1.1.1/dns-query', {
          method: 'POST',
          headers: { 'content-type': 'application/dns-message' },
          body: q
        });
        const ans = new Uint8Array(await r.arrayBuffer());
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

function decodeFrameB(u8, expectedHash) {
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

function decodeFrameA(u8, expectedUid) {
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
    safe_tpass = trojan_password.replace("'", "").replace('"', "").strip()
    trojan_hash = hashlib.sha224(safe_tpass.encode("utf-8")).hexdigest()
    proxies = [p for p in [proxy_ip.strip()] + DEFAULT_PROXY_IPS if p]
    proxies = list(dict.fromkeys(proxies))

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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/operator_scanner.py
from __future__ import annotations

import asyncio
import ipaddress
import logging
import random
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


OPERATOR_DNS_SOURCES: dict[str, list[str]] = {
    "mci": ["mci.ircf.space", "mcic.ircf.space", "mci.cf.vfarid.com", "cf.090227.xyz"],
    "mtn": ["mtn.ircf.space", "mtnc.ircf.space", "mtn.cf.vfarid.com", "cf.877774.xyz"],
    "mkh": ["mkh.ircf.space", "tci.ircf.space", "mkh.cf.vfarid.com", "cf.090227.xyz"],
}

# Diverse high-throughput Cloudflare CDN subnets (avoids putting all 3 configs on 1 throttled /16!)
OPERATOR_CIDRS: dict[str, list[str]] = {
    "mci": ["104.16.0.0/16", "104.18.0.0/16", "104.21.0.0/16", "172.64.155.0/24"],
    "mtn": ["104.17.0.0/16", "104.19.0.0/16", "104.22.0.0/16", "172.67.70.0/24"],
    "mkh": ["104.16.51.0/24", "104.18.21.0/24", "104.24.0.0/16", "172.64.150.0/24"],
}

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


def sample_operator_cidr_ips(op: str, count: int = 8) -> list[str]:
    cidrs = OPERATOR_CIDRS.get(op, ["104.16.0.0/16"])
    out: set[str] = set()
    for raw in cidrs:
        try:
            net = ipaddress.ip_network(raw, strict=False)
            num = net.num_addresses
            for _ in range(max(2, count // len(cidrs))):
                ip_s = str(net.network_address + random.randint(1, max(1, num - 2)))
                if not is_restricted_1034_ip(ip_s):
                    out.add(ip_s)
        except ValueError:
            continue
    return list(out)[:count]


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
            return [
                str(ans.get("data", "")).strip()
                for ans in (r.json().get("Answer") or [])
                if not is_restricted_1034_ip(str(ans.get("data", "")).strip())
            ]
    except Exception:
        return []


async def measure_edge_download_mbps(ip: str, byte_count: int = 524288, timeout_sec: float = 3.2) -> float:
    """Downloads 256KB from speed.cloudflare.com via the candidate Edge IP to filter out throttled IPs."""
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



async def measure_edge_upload_mbps(ip: str, byte_count: int = 131072, timeout_sec: float = 3.2) -> float:
    """Uploads 128KB to speed.cloudflare.com/__up via candidate Edge IP to measure real Upload bandwidth."""
    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, 443, ssl=ssl_ctx, server_hostname="speed.cloudflare.com"),
            timeout=timeout_sec,
        )
        body = b"0" * byte_count
        req = (
            f"POST /__up HTTP/1.1\r\n"
            f"Host: speed.cloudflare.com\r\n"
            f"User-Agent: Mozilla/5.0 Chrome/131.0.0.0\r\n"
            f"Content-Length: {byte_count}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("ascii")
        t0 = time.perf_counter()
        writer.write(req)
        writer.write(body)
        await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
        await asyncio.wait_for(reader.read(256), timeout=timeout_sec)
        elapsed = max(0.01, time.perf_counter() - t0)
        return round((byte_count * 8.0) / (elapsed * 1_000_000.0), 2)
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

        # Measure BOTH real Download (512KB) & Upload (128KB) throughput (Mbps)!
        dl_mbps, ul_mbps = await asyncio.gather(
            measure_edge_download_mbps(ip, byte_count=524288, timeout_sec=3.0),
            measure_edge_upload_mbps(ip, byte_count=131072, timeout_sec=3.0),
        )
        colo_bonus = 10.0 if colo in IRAN_PREFERRED_COLOS else 0.0
        speed_bonus = min(35.0, (dl_mbps * 1.1) + (ul_mbps * 0.9))
        score = round(max(10.0, min(100.0, 55.0 - (rtt_ms / 10.0) + colo_bonus + speed_bonus)), 2)
        return {
            "ip": ip, "port": port, "ip_version": 4,
            "latency_ms": rtt_ms, "speed_mbps": dl_mbps, "upload_mbps": ul_mbps,
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/ws_tester.py
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
    ws_path: str = "/ws",
    timeout_sec: float = 8.0,
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
        ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
        upgrade = (
            f"GET {ws_path} HTTP/1.1\r\n"
            f"Host: {worker_host}\r\n"
            f"User-Agent: {BROWSER_UA}\r\n"
            f"Origin: https://{worker_host}\r\n"
            f"Accept: */*\r\n"
            f"Accept-Language: en-US,en;q=0.9\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
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

        payload = (
            build_trojan_test_packet(credential, target_host=target_host)
            if protocol == "trojan"
            else build_vless_test_packet(credential, target_host=target_host)
        )
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/wg_handshake.py
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/warp_builder.py
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import logging
import random
import time
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

from app.bot.operator_scanner import (
    FALLBACK_EDGE_IPS,
    OPERATOR_DNS_SOURCES,
    is_restricted_1034_ip,
    resolve_doh_records,
    sample_operator_cidr_ips,
    verify_cloudflare_edge_ip,
)
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
            cleaned = [x for x in old if not is_restricted_1034_ip(x.get("ip", ""))]
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
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v21")

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
                logger.exception("V21 background scan error: %s", exc)
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
                    dns_domains = OPERATOR_DNS_SOURCES.get(op, [])
                    resolved = await asyncio.gather(*(resolve_doh_records(d, "A") for d in dns_domains))
                    for dom, ips in zip(dns_domains, resolved):
                        for ip in ips:
                            cand_map.setdefault(ip, dom)
                    for cip in sample_operator_cidr_ips(op, 8):
                        cand_map.setdefault(cip, "cidr_scan")
                    for fb in FALLBACK_EDGE_IPS.get(op, []):
                        cand_map.setdefault(fb, "cf_edge_clean")

                    probed = await asyncio.gather(*(_probe(ip, src) for ip, src in cand_map.items()))
                    valid = [p for p in probed if p is not None]
                    valid.sort(
                        key=lambda x: (
                            2 if x["source"] == "admin_manual" else (1 if "ircf" in x["source"] or "vfarid" in x["source"] else 0),
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/store.py
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
            "warp_v4_pool": [], "warp_v6_pool": [], "warp_probe_device": None,
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
                # Real Telegram Force-Join Lock
                "tg_lock_enabled": False,
                "tg_lock_channel": "",
                "tg_lock_text": "🔒 برای استفاده رایگان از ربات، ابتدا در کانال تلگرام ما عضو شوید و سپس دکمه «بررسی عضویت» را بزنید:",
                # Fake YouTube Channel Lock
                "yt_lock_enabled": False,
                "yt_lock_url": "https://youtube.com/@CyberMux",
                "yt_lock_text": "🎬 برای حمایت از ما و باز شدن ربات، لطفاً کانال یوتیوب ما را سابسکرایب کنید و سپس دکمه «تایید عضویت» را بزنید:",
                "webapp_url": os.getenv("WEBAPP_URL", "").strip(),
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/cf_manager.py
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
    if _ECH_CACHE["val"] and (now - _ECH_CACHE["ts"]) < 1800:
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
    ) -> dict[str, Any]:
        """
        V20 Maximum-Throughput 6-Config Pack (3 VLESS + 3 Trojan — ALL 6 on Port 443 + `alpn=http/1.1` + Live ECH!):
          - Fixes V19 speed bug: removes `alpn=h2` (which stalled WS on Cloudflare!) -> uses `alpn=http/1.1` on all 6.
          - #1 (Subnet A): `/ws?ed=2560` (Max 0-RTT Early Data) + Live ECH -> Fastest Ping & Instant Start
          - #2 (Subnet B): `/ws` (Pure WebSocket) + Live ECH -> Maximum Sustained Download Speed
          - #3 (Subnet C): `/ws?ed=2048` + Live ECH -> Balanced Anti-Throttle Backup Subnet
        """
        i1 = ip_list[0]
        i2 = ip_list[1] if len(ip_list) > 1 else i1
        i3 = ip_list[2] if len(ip_list) > 2 else i2
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        brand = "CFHub"
        tpass = quote(panel["trojan_password"], safe="")

        def _hp(ip: str) -> str:
            return f"[{ip}]" if ":" in ip else ip

        def _build(proto: str, it: dict, idx: int, ws_path: str, mode_lbl: str) -> str:
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
            if ech_b64:
                params["ech"] = ech_b64
            else:
                params["fp"] = "chrome"

            colo = it.get("colo") or "CF"
            mbps = it.get("speed_mbps") or 0
            spd_tag = f"•{int(round(mbps))}M" if mbps >= 1 else ""
            tag = format_beautiful_name(op_lbl, f"{'VLESS' if proto == 'vless' else 'Trojan'}-{idx}", it.get("latency_ms"), f"{colo}{spd_tag}•{mode_lbl}•{brand}")
            cred = panel["uuid"] if proto == "vless" else tpass
            return f"{proto}://{cred}@{_hp(it['ip'])}:443?{urlencode(params)}#{quote(tag)}"

        return {
            "vless_1": _build("vless", i1, 1, "/ws", "UltraStable"),
            "vless_2": _build("vless", i2, 2, "/ws", "MaxSpeed"),
            "vless_3": _build("vless", i3, 3, "/ws?ed=2048", "Fast0RTT"),
            "trojan_1": _build("trojan", i1, 1, "/ws", "UltraStable"),
            "trojan_2": _build("trojan", i2, 2, "/ws", "MaxSpeed"),
            "trojan_3": _build("trojan", i3, 3, "/ws?ed=2048", "Fast0RTT"),
            "ech_active": bool(ech_b64),
        }
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/webapp.py
from __future__ import annotations

import logging
import os
from aiohttp import web

from app.bot.cf_manager import fetch_live_cloudflare_ech_b64
from app.bot.operator_scanner import OPERATOR_LABELS

logger = logging.getLogger(__name__)

MINI_APP_HTML = r"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
<title>CFHub Mini App</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
  :root {
    --bg: #0b0e14;
    --card: #131823;
    --border: #232d42;
    --cyan: #00f0ff;
    --violet: #8b5cf6;
    --green: #10b981;
    --text: #e2e8f0;
    --muted: #94a3b8;
  }
  * { box-sizing: border-box; font-family: system-ui, -apple-system, Tahoma, sans-serif; }
  body { margin: 0; padding: 16px; background: var(--bg); color: var(--text); }
  .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
  .brand { font-size: 18px; font-weight: 800; background: linear-gradient(90deg, var(--cyan), var(--violet)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
  .badge { font-size: 11px; padding: 4px 10px; border-radius: 999px; background: rgba(16,185,129,.15); color: var(--green); border: 1px solid rgba(16,185,129,.35); }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 14px; margin-bottom: 12px; }
  .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; text-align: center; }
  .stat-box { background: rgba(255,255,255,.03); border-radius: 10px; padding: 10px 6px; border: 1px solid var(--border); }
  .stat-num { font-size: 16px; font-weight: 800; color: var(--cyan); }
  .stat-lbl { font-size: 11px; color: var(--muted); margin-top: 2px; }
  .ops { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 12px; }
  .op-btn { padding: 10px 6px; border-radius: 10px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-weight: 700; cursor: pointer; font-size: 13px; }
  .op-btn.active { border-color: var(--cyan); background: rgba(0,240,255,.12); color: var(--cyan); }
  .cfg-item { background: rgba(0,0,0,.28); border: 1px solid var(--border); border-radius: 10px; padding: 10px; margin-bottom: 8px; display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .cfg-title { font-size: 13px; font-weight: 700; }
  .cfg-sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
  .copy-btn { padding: 8px 14px; border-radius: 8px; border: none; background: linear-gradient(135deg, var(--cyan), var(--violet)); color: #05080f; font-weight: 800; font-size: 12px; cursor: pointer; white-space: nowrap; }
  .toast { position: fixed; bottom: 18px; left: 50%; transform: translateX(-50%); background: var(--green); color: #05080f; padding: 8px 18px; border-radius: 999px; font-weight: 800; font-size: 13px; display: none; z-index: 99; }
</style>
</head>
<body>
  <div class="header">
    <div class="brand">⚡ CFHub Turbo V22</div>
    <div id="statusBadge" class="badge">در حال اتصال...</div>
  </div>

  <div class="card">
    <div class="stats">
      <div class="stat-box"><div id="stMci" class="stat-num">-</div><div class="stat-lbl">🔵 همراه اول</div></div>
      <div class="stat-box"><div id="stMtn" class="stat-num">-</div><div class="stat-lbl">🟡 ایرانسل</div></div>
      <div class="stat-box"><div id="stMkh" class="stat-num">-</div><div class="stat-lbl">🟢 مخابرات</div></div>
    </div>
  </div>

  <div class="ops">
    <button class="op-btn active" onclick="loadConfigs('mci', this)">🔵 همراه اول</button>
    <button class="op-btn" onclick="loadConfigs('mtn', this)">🟡 ایرانسل</button>
    <button class="op-btn" onclick="loadConfigs('mkh', this)">🟢 مخابرات</button>
  </div>

  <div id="cfgContainer" class="card">
    <div style="text-align:center;color:var(--muted);padding:16px;">در حال دریافت ۶ کانفیگ پرسرعت ECH...</div>
  </div>

  <div id="toast" class="toast">✅ کپی شد!</div>

<script>
  const tg = window.Telegram && window.Telegram.WebApp ? window.Telegram.WebApp : null;
  if (tg) { tg.ready(); tg.expand(); }
  const userId = (tg && tg.initDataUnsafe && tg.initDataUnsafe.user) ? tg.initDataUnsafe.user.id : new URLSearchParams(location.search).get('uid') || '';

  function showToast(msg) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.style.display = 'block';
    setTimeout(() => { t.style.display = 'none'; }, 1800);
  }

  function copyText(val) {
    navigator.clipboard.writeText(val).then(() => showToast('✅ لینک کانفیگ کپی شد!')).catch(() => showToast('❌ خطا در کپی'));
  }

  async function loadConfigs(op, btnEl) {
    if (btnEl) {
      document.querySelectorAll('.op-btn').forEach(b => b.classList.remove('active'));
      btnEl.classList.add('active');
    }
    const box = document.getElementById('cfgContainer');
    box.innerHTML = '<div style="text-align:center;color:var(--muted);padding:16px;">⏳ در حال انتخاب سریع‌ترین آی‌پی‌ها...</div>';
    try {
      const r = await fetch(`/api/webapp/configs?uid=${encodeURIComponent(userId)}&op=${encodeURIComponent(op)}`);
      const d = await r.json();
      document.getElementById('stMci').textContent = d.pools.mci;
      document.getElementById('stMtn').textContent = d.pools.mtn;
      document.getElementById('stMkh').textContent = d.pools.mkh;
      document.getElementById('statusBadge').textContent = d.has_panel ? '🟢 پنل فعال' : '⚪ بدون پنل';
      if (!d.has_panel) {
        box.innerHTML = '<div style="text-align:center;padding:14px;">ابتدا در ربات روی دکمه <b>🚀 ساخت پنل رایگان</b> بزنید تا پنل شما فعال شود.</div>';
        return;
      }
      const items = [
        { k: 'vless_1', t: '🔷 VLESS #1 (UltraStable)', s: 'پورت 443 • ECH زنده' },
        { k: 'vless_2', t: '🔷 VLESS #2 (MaxSpeed)', s: 'پورت 443 • ECH زنده' },
        { k: 'vless_3', t: '🔷 VLESS #3 (Fast 0-RTT)', s: 'پورت 443 • ECH زنده' },
        { k: 'trojan_1', t: '🔐 Trojan #1 (UltraStable)', s: 'پورت 443 • ECH زنده' },
        { k: 'trojan_2', t: '🔐 Trojan #2 (MaxSpeed)', s: 'پورت 443 • ECH زنده' },
        { k: 'trojan_3', t: '🔐 Trojan #3 (Fast 0-RTT)', s: 'پورت 443 • ECH زنده' }
      ];
      box.innerHTML = '';
      items.forEach(it => {
        const uri = d.configs[it.k];
        if (!uri) return;
        const row = document.createElement('div');
        row.className = 'cfg-item';
        row.innerHTML = `<div><div class="cfg-title">${it.t}</div><div class="cfg-sub">${it.s}</div></div>`;
        const b = document.createElement('button');
        b.className = 'copy-btn';
        b.textContent = '📋 کپی';
        b.onclick = () => copyText(uri);
        row.appendChild(b);
        box.appendChild(row);
      });
    } catch (e) {
      box.innerHTML = '<div style="text-align:center;color:#f87171;padding:14px;">❌ خطا در ارتباط با سرور</div>';
    }
  }

  loadConfigs('mci');
</script>
</body>
</html>
"""


async def start_mini_app_server(store, bg_engine, cf_service, port: int = 8080) -> web.AppRunner:
    app = web.Application()

    async def handle_index(request: web.Request) -> web.Response:
        return web.Response(text=MINI_APP_HTML, content_type="text/html", charset="utf-8")

    async def handle_health(request: web.Request) -> web.Response:
        return web.json_response({"ok": True, "service": "cfhub_miniapp", "v": "v22"})

    async def handle_configs(request: web.Request) -> web.Response:
        uid = request.query.get("uid", "").strip()
        op = request.query.get("op", "mci").strip().lower()
        if op not in ("mci", "mtn", "mkh"):
            op = "mci"
        pools = store.data.get("operator_pools", {})
        pool_counts = {k: len(pools.get(k, [])) for k in ("mci", "mtn", "mkh")}
        panel = store.data.get("panels", {}).get(uid)
        if not panel:
            return web.json_response({"ok": True, "has_panel": False, "pools": pool_counts, "configs": {}})

        ips = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 8), operator=op, count=3)
        ech_b64 = await fetch_live_cloudflare_ech_b64()
        c6 = cf_service.build_six_ech_configs(panel, ips, operator=op, ech_b64=ech_b64)
        return web.json_response({
            "ok": True,
            "has_panel": True,
            "host": panel["host"],
            "operator": OPERATOR_LABELS.get(op, op),
            "pools": pool_counts,
            "configs": c6,
        })

    app.router.add_get("/", handle_index)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/api/webapp/configs", handle_configs)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    logger.info("Telegram Mini App server listening on http://0.0.0.0:%s", port)
    return runner
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/ui.py
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
    "%5D&accountId=*&zoneId=all&name=CFHubV22"
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
__CFHUB_V22_EOF__

cat <<'__CFHUB_V22_EOF__' > backend/app/bot/bot.py
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
    return (
        panel.get("worker_version") == CURRENT_WORKER_VERSION
        and bool(panel.get("last_health_ok", False))
    )




def _progress_bar(pct: int) -> str:
    filled = max(0, min(10, pct // 10))
    return f"[{'█' * filled}{'░' * (10 - filled)}] {pct}%"


async def _check_access_locks(bot: Bot, tg_id: int) -> tuple[bool, str, object | None]:
    """Enforces Real Telegram Channel Lock + Fake YouTube Channel Lock for non-admin users."""
    if _is_admin(tg_id):
        return True, "", None

    cfg = store.data["settings"]

    # 1) Real Telegram Channel Membership Check
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
                rows.append([btn("📢 عضویت در کانال تلگرام", url=join_url, style="primary")])
            rows.append([btn("🔄 بررسی عضویت", callback_data="lock:check", style="success")])
            txt = f"🔒 <b>قفل عضویت کانال تلگرام</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('tg_lock_text', ''))}"
            return False, txt, kb(rows)

    # 2) Fake YouTube Channel Lock (unlocks once user clicks confirm)
    if cfg.get("yt_lock_enabled") and not store.is_yt_verified(tg_id):
        yt_url = str(cfg.get("yt_lock_url") or "https://youtube.com").strip()
        if not yt_url.startswith("http"):
            yt_url = "https://" + yt_url
        rows = [
            [btn("▶️ ورود به کانال یوتیوب", url=yt_url, style="danger")],
            [btn("✅ عضو شدم / تایید", callback_data="lock:yt_confirm", style="success")],
        ]
        txt = f"🎬 <b>حمایت از کانال یوتیوب</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(cfg.get('yt_lock_text', ''))}"
        return False, txt, kb(rows)

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
    pools = store.data.get("operator_pools", {})
    panel = store.data.get("panels", {}).get(str(tg_id))
    if panel:
        st_lbl = "🟢 آپدیت و فعال" if _is_panel_updated(panel) else "🟡 نیاز به آپدیت"
        panel_line = f"🎛️ پنل شما: <b>{st_lbl}</b> (<code>{html.escape(panel['host'])}</code>)"
    else:
        panel_line = "🎛️ پنل شما: ⚪ هنوز ساخته نشده"
    return (
        "⚡ <b>Cloudflare Config Hub — کانفیگ رایگان و تست‌شده</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> | 🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> | 🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b>\n"
        f"🛡️ رله WARP سالم: <b>{len(store.data.get('warp_v4_pool', []))}</b> IPv4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> IPv6\n"
        f"{panel_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 گزینه مورد نظر را انتخاب کنید:"
    )


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
    ok_lock, lock_txt, lock_kb = await _check_access_locks(message.bot, u.id)
    if not ok_lock:
        await message.answer(lock_txt, reply_markup=lock_kb, parse_mode="HTML")
        return
    await message.answer(
        _home_text(u.id),
        reply_markup=main_menu_kb(_is_admin(u.id), _has_panel(u.id), store.get_lang(u.id), store.data["settings"].get("webapp_url", "")),
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
        await _safe_answer(cb, "⚠️ هنوز عضویت شما تایید نشد! ابتدا عضو شوید.", show_alert=True)
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ عضویت شما تایید شد! خوش آمدید.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


@router.callback_query(F.data == "lock:yt_confirm")
async def cb_lock_yt_confirm(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.set_yt_verified(uid, True)
    ok_lock, lock_txt, lock_kb = await _check_access_locks(cb.bot, uid)
    if not ok_lock:
        await _safe_answer(cb, "✅ تایید شد؛ مرحله بعد را انجام دهید.")
        await _edit(cb, lock_txt, lock_kb)
        return
    await _safe_answer(cb, "✅ ممنون از حمایت شما! ربات باز شد.", show_alert=True)
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
    await _safe_answer(cb, "EN" if lang == "en" else "فارسی")
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), _has_panel(uid), lang, store.data["settings"].get("webapp_url", "")))


# ==================== 1. PANEL DEPLOY (PRIMARY CLOUDFLARE PAGES `*.pages.dev` + WORKERS FALLBACK) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    uid = cb.from_user.id
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت پنل رایگان (۳ VLESS + ۳ Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلودفلر نداری، اول ثبت‌نام کن.\n"
        "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن (دسترسی‌های Pages و Workers آماده است).\n"
        "3️⃣ در کلودفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "🔐 <i>پیام توکن بلافاصله پاک و رمزنگاری می‌شود و پنل روی Cloudflare Pages (*.pages.dev) ساخته می‌شود.</i>"
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

    wait_msg = await message.answer("⏳ <b>در حال دیپلوی روی Cloudflare Pages (*.pages.dev) و تست واقعی VLESS و Trojan...</b>", parse_mode="HTML")

    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    proj_name = old.get("project_name") or _new_neutral_name()
    proxy_ip = old.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.cmliussss.net")

    dep = await cf_service.deploy_dual_panel(
        api_token=raw_token,
        user_uuid=panel_uuid,
        trojan_password=trojan_pass,
        project_name=proj_name,
        proxy_ip=proxy_ip,
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
    op = old.get("operator", "mci")
    pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
    is_healthy = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
    store.data["panels"][str(uid)] = {
        "engine": dep.engine,
        "uuid": panel_uuid,
        "trojan_password": trojan_pass,
        "project_name": dep.project_name,
        "host": dep.worker_host,
        "sni": dep.worker_host,
        "fallback_host": dep.fallback_host,
        "operator": op,
        "clean_ip": pair[0]["ip"],
        "proxy_ip": proxy_ip,
        "auto_ip": True,
        "worker_version": CURRENT_WORKER_VERSION,
        "last_health_ok": is_healthy,
        "created_at": old.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    v_badge = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:80])}"
    t_badge = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:80])}"
    diag = f"\nℹ️ {html.escape(dep.diag_note[:160])}" if dep.diag_note else ""
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"🎉 <b>پنل V22 ({dep.engine.upper()}) آماده شد!</b>\n"
        f"🔷 VLESS: <b>{v_badge}</b>\n🔐 Trojan: <b>{t_badge}</b>{diag}\n\n{text}",
        parse_mode="HTML",
        reply_markup=markup,
    )


# ==================== 2. MY PANEL — ULTRA-CLEAN (NO SUB LINK, NO RENAME BUTTON, QUOTE CONFIGS) ====================
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
    engine_lbl = "Cloudflare Pages" if panel.get("engine") == "pages" else "Cloudflare Workers"
    updated = _is_panel_updated(panel)
    ver_line = (
        f"📦 وضعیت نسخه: <b>✅ آپدیت هستید ({CURRENT_WORKER_VERSION.upper()})</b>"
        if updated
        else "📦 وضعیت نسخه: <b>⚠️ نیاز به آپدیت — دکمه «آپدیت کنید» را بزنید</b>"
    )
    update_btn = (
        btn("✅ آپدیت هستید", callback_data="cf:up_to_date", style="success")
        if updated
        else btn("🔄 آپدیت کنید", callback_data="cf:redeploy", style="danger")
    )

    text = (
        "🎛️ <b>پنل اختصاصی من</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚡ موتور فعال: <b>{engine_lbl}</b>\n"
        f"🌐 دامنه فعال: <code>{html.escape(panel['host'])}</code>\n"
        f"📶 اپراتور فعال: <b>{OPERATOR_LABELS.get(op, op)}</b>\n"
        f"{ver_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "اپراتور خود را انتخاب کنید تا <b>۶ کانفیگ پرسرعت ECH (۳ VLESS + ۳ Trojan)</b> دریافت کنید:"
    )
    markup = kb([
        [
            btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
            btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
            btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
        ],
        [
            btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary"),
            update_btn,
        ],
        [
            btn("🔁 تغییر ProxyIP", callback_data="cf:edit_proxyip", style="primary"),
            btn("🗑️ حذف پنل", callback_data="cf:disconnect", style="danger"),
        ],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
    t, m = _render_personal_panel(cb.from_user.id)
    await _edit(cb, t, m)


@router.callback_query(F.data == "cf:up_to_date")
async def cb_cf_up_to_date(cb: CallbackQuery) -> None:
    await _safe_answer(cb, f"✅ پنل شما روی آخرین نسخه ({CURRENT_WORKER_VERSION.upper()}) آپدیت و سالم است!", show_alert=True)


@router.callback_query(F.data.startswith("cf:getop:"))
async def cb_cf_get_by_op(cb: CallbackQuery) -> None:
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, f"⏳ انتخاب ۳ IP سالم برای {OPERATOR_LABELS.get(op, op)}...")

    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    pool = bg_engine.get_best_operator_ips(op, 8)
    offset = int(panel.get(f"rot_{op}", 0)) % max(1, len(pool))
    rotated = pool[offset:] + pool[:offset]
    panel[f"rot_{op}"] = offset + 2

    verified_ips = await cf_service.pick_best_verified_worker_ips(panel["host"], rotated, operator=op, count=3)
    panel["operator"] = op
    panel["clean_ip"] = verified_ips[0]["ip"]
    store.save()
    store.increment_stat(uid, "configs_generated")

    ech_b64 = await fetch_live_cloudflare_ech_b64()
    c6 = cf_service.build_six_ech_configs(panel, verified_ips, operator=op, ech_b64=ech_b64)
    op_lbl = OPERATOR_LABELS.get(op, op)

    msg = (
        f"🚀 <b>۶ کانفیگ پرسرعت ECH اختصاصی {op_lbl}</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 <b>VLESS #1 (UltraStable • ضد قطعی)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_1'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #2 (MaxSpeed • حداکثر سرعت)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_2'])}</code></blockquote>\n\n"
        f"🔷 <b>VLESS #3 (Fast 0-RTT • پینگ پایین)</b>\n"
        f"<blockquote><code>{html.escape(c6['vless_3'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #1 (UltraStable • ضد قطعی)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_1'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #2 (MaxSpeed • حداکثر سرعت)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_2'])}</code></blockquote>\n\n"
        f"🔐 <b>Trojan #3 (Fast 0-RTT • پینگ پایین)</b>\n"
        f"<blockquote><code>{html.escape(c6['trojan_3'])}</code></blockquote>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"⚡ <i>همه ۶ کانفیگ مجهز به کلید زنده ECH کلودفلر روی ۳ آی‌پی برتر و پورت 443 هستند.</i>"
    )
    await _edit(
        cb,
        msg,
        kb([
            [btn(f"🔄 تعویض با ۳ IP جدید ({op_lbl})", callback_data=f"cf:getop:{op}", style="success")],
            [btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:e2e_test")
async def cb_cf_e2e_test(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        await _safe_answer(cb)
        return
    await _safe_answer(cb, "🩺 در حال تست سرتاسری...")
    wait = await cb.message.answer("⏳ در حال اجرای تست سرتاسری پنل (Health + VLESS + Trojan + ProxyIP)...")
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    op = panel.get("operator", "mci")
    if is_restricted_1034_ip(panel.get("clean_ip", "")):
        pair = await cf_service.pick_best_verified_worker_ips(panel["host"], bg_engine.get_best_operator_ips(op, 8), operator=op)
        panel["clean_ip"] = pair[0]["ip"]
        store.save()

    (h_ok, h_ms, h_msg), (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg), (p_ok, p_ms, p_msg) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "trojan", panel["trojan_password"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="cp.cloudflare.com"),
    )

    all_good = bool(h_ok and v_ok and t_ok)
    panel["last_health_ok"] = all_good
    store.save()

    h_l = f"🟢 <b>سالم</b> ({h_ms}ms)" if h_ok else f"🔴 <b>خطا</b> ({html.escape(h_msg[:95])})"
    v_l = f"🟢 <b>سالم</b> ({v_ms}ms)" if v_ok else f"🔴 <b>خطا</b> ({html.escape(v_msg[:110])})"
    t_l = f"🟢 <b>سالم</b> ({t_ms}ms)" if t_ok else f"🔴 <b>خطا</b> ({html.escape(t_msg[:110])})"
    p_l = f"🟢 <b>سالم</b> ({p_ms}ms)" if p_ok else f"🟡 <b>نیاز به ProxyIP</b> ({html.escape(p_msg[:95])})"

    rows = []
    if not all_good:
        hint = "\n\n💡 دکمه <b>🔄 آپدیت کنید</b> زیر را بزنید تا پنل روی Cloudflare Pages (*.pages.dev) منتقل شود."
        rows.append([btn("🔄 آپدیت کنید (انتقال به Pages سالم)", callback_data="cf:redeploy", style="danger")])
    else:
        hint = "\n\n✅ <b>پنل شما کاملاً سالم و آپدیت است!</b>"
    rows.append([btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")])

    await wait.edit_text(
        f"🩺 <b>نتیجه تست سرتاسری پنل شما ({CURRENT_WORKER_VERSION.upper()})</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📡 دامنه فعال: <code>{html.escape(panel['host'])}</code>\n"
        f"🌐 روتینگ IP تمیز (<code>{html.escape(panel['clean_ip'])}</code>): {h_l}\n"
        f"🔷 تونل واقعی VLESS: {v_l}\n"
        f"🔐 تونل واقعی Trojan: {t_l}\n"
        f"🔁 فالبک ProxyIP: {p_l}{hint}",
        parse_mode="HTML",
        reply_markup=kb(rows),
    )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    if uid in _redeploy_locks:
        await _safe_answer(cb, "⏳ آپدیت هم‌اکنون در حال انجام است، لطفاً صبر کنید...", show_alert=True)
        return
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await _safe_answer(cb, "⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return

    _redeploy_locks.add(uid)
    try:
        await _safe_answer(cb, "🔄 در حال انتقال و آپدیت روی Cloudflare Pages...")
        await _edit(
            cb,
            "⏳ <b>در حال آپدیت پنل به نسخه V22 (موتور Cloudflare Pages)...</b>\n"
            "• ساخت پروژه جدید روی <code>*.pages.dev</code> (رفع کامل Error 1101)\n"
            "• دیپلوی مستقیم <code>_worker.js</code> دوپروتکله\n"
            "• تست واقعی VLESS و Trojan (حدود ۱۰ تا ۱۵ ثانیه صبر کنید)",
            kb([[btn("⏳ لطفاً صبر کنید...", callback_data="cf:noop", style="primary")]]),
        )
        try:
            token = store.decrypt_secret(cf["encrypted_token"])
        except Exception:
            await _edit(cb, "❌ توکن قابل رمزگشایی نیست؛ لطفاً از منوی اصلی دوباره متصل شوید.", back_home_kb("m:turbo"))
            return
        if not panel.get("trojan_password"):
            panel["trojan_password"] = secrets.token_urlsafe(12)

        dep = await cf_service.deploy_dual_panel(
            api_token=token,
            user_uuid=panel["uuid"],
            trojan_password=panel["trojan_password"],
            project_name=panel.get("project_name") or panel.get("script_name") or "",
            proxy_ip=panel.get("proxy_ip", "proxyip.cmliussss.net"),
            force_new_name=(panel.get("engine") != "pages"),
        )
        if dep.ok:
            op = panel.get("operator", "mci")
            pair = await cf_service.pick_best_verified_worker_ips(dep.worker_host, bg_engine.get_best_operator_ips(op, 8), operator=op)
            is_healthy = bool(dep.health_ok and (dep.vless_verified or dep.trojan_verified))
            panel["engine"] = dep.engine
            panel["project_name"] = dep.project_name
            panel["host"] = dep.worker_host
            panel["sni"] = dep.worker_host
            panel["fallback_host"] = dep.fallback_host
            panel["clean_ip"] = pair[0]["ip"]
            panel["worker_version"] = CURRENT_WORKER_VERSION
            panel["last_health_ok"] = is_healthy
            panel["updated_at"] = datetime.now(timezone.utc).isoformat()
            store.save()

            v_s = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:75])}"
            t_s = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:75])}"
            diag = f"\nℹ️ {html.escape(dep.diag_note[:160])}" if dep.diag_note else ""
            text, markup = _render_personal_panel(uid)
            await _edit(
                cb,
                f"✅ <b>آپدیت به نسخه {CURRENT_WORKER_VERSION.upper()} ({dep.engine.upper()}) انجام شد!</b>\n"
                f"🔷 VLESS: <b>{v_s}</b>\n🔐 Trojan: <b>{t_s}</b>{diag}\n\n{text}",
                markup,
            )
        else:
            await _edit(cb, f"❌ <b>خطا در آپدیت پنل:</b>\n<code>{html.escape(dep.error or '')}</code>", back_home_kb("m:mypanel"))
    finally:
        _redeploy_locks.discard(uid)


@router.callback_query(F.data == "cf:noop")
async def cb_noop(cb: CallbackQuery) -> None:
    await _safe_answer(cb, "⏳ در حال انجام عملیات...")


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    await _safe_answer(cb)
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(cb, "🔁 آدرس ProxyIP جدید بفرستید (پیشنهاد: <code>proxyip.cmliussss.net</code> یا <code>bpb.yousef.isegaro.com</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    pip = (message.text or "").strip()
    if str(uid) in store.data["panels"] and pip:
        store.data["panels"][str(uid)]["proxy_ip"] = pip
        store.data["panels"][str(uid)]["last_health_ok"] = False
        store.save()
    await state.clear()
    t, m = _render_personal_panel(uid)
    await message.answer(f"✅ ProxyIP ذخیره شد. برای اعمال روی کلودفلر دکمه <b>🔄 آپدیت کنید</b> را بزنید.\n\n{t}", parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await _safe_answer(cb, "🗑️ پنل حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid), store.data["settings"].get("webapp_url", "")))


# ==================== 3. WARP / WIREGUARD (WORKING CORE — LINKS IN QUOTE BLOCKS!) ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
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
        [btn("🔍 اسکن زنده اندپوینت‌های WARP", callback_data="warp:scan_live", style="success")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)



@router.callback_query(F.data == "warp:scan_live")
async def cb_warp_scan_live(cb: CallbackQuery) -> None:
    if bg_engine.is_scanning:
        await _safe_answer(cb, f"⏳ اسکن هم‌اکنون در حال اجراست ({bg_engine.progress_pct}%).", show_alert=True)
        return
    await _safe_answer(cb, "🔍 اسکن زنده اندپوینت‌های WARP شروع شد!")
    await _edit(
        cb,
        f"🔍 <b>اسکن زنده اندپوینت‌های WARP (IPv4 + IPv6)</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(10)}</code>\n"
        f"⏳ در حال آماده‌سازی...",
        kb([[btn("⏳ در حال اسکن...", callback_data="cf:noop", style="primary")]]),
    )

    async def _on_p(pct: int, msg: str) -> None:
        await _edit(
            cb,
            f"🔍 <b>اسکن زنده اندپوینت‌های WARP (IPv4 + IPv6)</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📊 پیشرفت: <code>{_progress_bar(pct)}</code>\n"
            f"🔄 وضعیت: <b>{html.escape(msg)}</b>",
            kb([[btn(f"⏳ {pct}% تکمیل شده...", callback_data="cf:noop", style="primary")]]),
        )

    res = await bg_engine.run_warp_only_scan(on_progress=_on_p)
    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    await _edit(
        cb,
        f"✅ <b>اسکن اندپوینت‌های WARP با موفقیت تمام شد!</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(100)}</code>\n"
        f"🌐 بهترین رله IPv4: <code>{html.escape(ep4)}</code> (<b>{res.get('warp_v4', 0)}</b> سالم)\n"
        f"🌐 بهترین رله IPv6: <code>{html.escape(ep6)}</code> (<b>{res.get('warp_v6', 0)}</b> سالم)\n"
        f"⚡ بهترین پینگ: <b>{ping or 'Auto'}ms</b>",
        kb([
            [btn("🛡️ ساخت کانفیگ با رله‌های جدید", callback_data="m:warp", style="success")],
            [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
        ]),
    )


@router.callback_query(F.data.startswith("warp:mode:"))
async def cb_warp_plat(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
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
    await _safe_answer(cb, "⏳ ثبت کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return
    wait = await cb.message.answer("⏳ در حال ساخت کلید اختصاصی WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(f"❌ خطا: <code>{html.escape(reg.error or '')}</code>", parse_mode="HTML", reply_markup=back_home_kb("m:warp"))
        return

    ep4, ep6, ping = bg_engine.get_best_warp_endpoints()
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand="CFHub")  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    try:
        await wait.delete()
    except Exception:
        pass

    txt = (
        f"✅ <b>کانفیگ WARP آماده شد</b>\n"
        f"🏷️ <b>{html.escape(b['label'])}</b>\n"
        f"🎯 رله: <code>{html.escape(b['endpoint'])}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>پیشنهاد اول — ضد فیلتر تهران/ایران (Hiddify / Karing):</b>\n"
        f"<blockquote><code>{html.escape(b['warp_auto_uri'])}</code></blockquote>\n\n"
        f"2️⃣ <b>لینک دولایه WoW (Hiddify / Karing):</b>\n"
        f"<blockquote><code>{html.escape(b['wow_uri'])}</code></blockquote>\n\n"
        f"3️⃣ <b>لینک WireGuard ضد DPI (v2rayNG / MahsaNG):</b>\n"
        f"<blockquote><code>{html.escape(b['wireguard_uri'])}</code></blockquote>"
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
    await _safe_answer(cb)
    pools = store.data.get("operator_pools", {})
    text = (
        "📶 <b>آی‌پی‌های تمیز بر اساس اپراتور</b>\n"
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
    await _safe_answer(cb)
    op = cb.data.split(":")[2]
    ips = bg_engine.get_best_operator_ips(op, 10)
    lbl = OPERATOR_LABELS.get(op, op)
    body = "\n".join(
        f"{i+1}. <code>{x['ip']}</code> | 🟢<b>{x.get('latency_ms') or 'Auto'}ms</b> | {x.get('colo', 'CF')}"
        for i, x in enumerate(ips)
    ) or "⏳ در حال دریافت لیست..."
    rows = []
    if _has_panel(cb.from_user.id):
        rows.append([btn(f"⚡ دریافت ۶ کانفیگ {lbl}", callback_data=f"cf:getop:{op}", style="success")])
    rows.append([btn("🔙 اپراتورها", callback_data="m:isp", style="primary")])
    await _edit(cb, f"📶 <b>IP تمیز {lbl}</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb(rows))


# ==================== 5. APPS, GUIDE & SUPPORT ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await _safe_answer(cb)
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
    await _safe_answer(cb)
    text = (
        "📖 <b>راهنمای اتصال سریع</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>پنل VLESS + Trojan:</b>\n"
        "• توکن کلودفلر را بفرستید تا پنل شما روی Cloudflare Pages ساخته شود.\n"
        "• داخل «🎛️ پنل من» اپراتور خود را بزنید تا ۶ کانفیگ مرتب (۳ VLESS + ۳ Trojan) بگیرید.\n"
        "• روی اینترنت‌های حساس به SNI، در تنظیمات Hiddify یا v2rayNG گزینه <b>TLS Fragment</b> را روشن کنید.\n\n"
        "2️⃣ <b>کانفیگ WARP:</b>\n"
        "• لینک <code>warp://auto...</code> را در <b>Hiddify</b> یا فایل <code>.conf</code> را در <b>AmneziaWG</b> باز کنید."
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _safe_answer(cb)
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
    await _safe_answer(cb)
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


# ==================== 6. CLEAN ADMIN PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        f"🛠️ <b>پنل مدیریت ({CURRENT_WORKER_VERSION.upper()})</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | آخرین اسکن: <code>{last_s}</code>\n"
        f"📶 IP اپراتورها: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))}\n"
        f"🛡️ WARP تاییدشده: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل فعال: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [
            btn("▶️ اسکن IP اپراتورها + WARP", callback_data="adm:scan_now", style="success"),
            btn("🛡️ اسکن زنده WARP", callback_data="warp:scan_live", style="primary"),
        ],
        [
            btn("🔵 افزودن IP همراه اول", callback_data="adm:addop:mci", style="primary"),
            btn("🟡 افزودن IP ایرانسل", callback_data="adm:addop:mtn", style="primary"),
        ],
        [
            btn("🟢 افزودن IP مخابرات", callback_data="adm:addop:mkh", style="success"),
            btn("👥 مدیریت کاربران", callback_data="adm:users:0", style="primary"),
        ],
        [btn("🔒 قفل کانال تلگرام و یوتیوب", callback_data="adm:locks", style="primary")],
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
        await _safe_answer(cb, f"⏳ اسکن هم‌اکنون در حال اجراست ({bg_engine.progress_pct}%).", show_alert=True)
        return
    await _safe_answer(cb, "🚀 اسکن زنده آغاز شد!")
    await _edit(
        cb,
        f"🔍 <b>جستجوی زنده آی‌پی‌های تمیز و رله‌های WARP</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(5)}</code>\n"
        f"⏳ در حال آماده‌سازی موتور اسکن...",
        kb([[btn("⏳ در حال اسکن...", callback_data="cf:noop", style="primary")]]),
    )

    async def _on_prog(pct: int, stage_msg: str) -> None:
        await _edit(
            cb,
            f"🔍 <b>جستجوی زنده آی‌پی‌های تمیز و رله‌های WARP</b>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📊 پیشرفت: <code>{_progress_bar(pct)}</code>\n"
            f"🔄 وضعیت: <b>{html.escape(stage_msg)}</b>",
            kb([[btn(f"⏳ {pct}% تکمیل شده...", callback_data="cf:noop", style="primary")]]),
        )

    res = await bg_engine.run_full_cycle(trigger="admin_live", on_progress=_on_prog)
    mci_top = bg_engine.get_best_operator_ips("mci", 1)[0]["ip"]
    mtn_top = bg_engine.get_best_operator_ips("mtn", 1)[0]["ip"]
    mkh_top = bg_engine.get_best_operator_ips("mkh", 1)[0]["ip"]
    await _edit(
        cb,
        f"✅ <b>اسکن کامل با موفقیت به پایان رسید!</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"📊 پیشرفت: <code>{_progress_bar(100)}</code>\n"
        f"🔵 همراه اول: <b>{res.get('mci', 0)}</b> IP (برتر: <code>{mci_top}</code>)\n"
        f"🟡 ایرانسل: <b>{res.get('mtn', 0)}</b> IP (برتر: <code>{mtn_top}</code>)\n"
        f"🟢 مخابرات: <b>{res.get('mkh', 0)}</b> IP (برتر: <code>{mkh_top}</code>)\n"
        f"🛡️ رله WARP سالم: <b>{res.get('warp_v4', 0)}</b> v4 • <b>{res.get('warp_v6', 0)}</b> v6\n\n"
        f"✨ <i>برترین آی‌پی‌ها به‌صورت خودکار روی پنل کاربران سوار شدند.</i>",
        kb([
            [btn("🔄 اسکن مجدد", callback_data="adm:scan_now", style="success")],
            [btn("🔙 بازگشت به پنل مدیریت", callback_data="adm:home", style="primary")],
        ]),
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
    await message.answer(f"✅ {added} IP معتبر به {OPERATOR_LABELS.get(op, op)} اضافه شد.", reply_markup=back_home_kb("adm:home"))


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
    await _safe_answer(cb)
    t, m = _render_user_card(int(cb.data.split(":")[2]))
    await _edit(cb, t, m)


@router.callback_query(F.data.startswith("adm:uban:"))
async def cb_adm_uban(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    tid = int(cb.data.split(":")[2])
    if _is_admin(tid):
        await _safe_answer(cb)
        return
    store.set_ban(tid, not store.is_banned(tid))
    await _safe_answer(cb, "✅ انجام شد.", show_alert=True)
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
    await _safe_answer(cb, "🗑️ پاک شد.", show_alert=True)
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
        await message.answer(f"❌ خطا: {exc}", reply_markup=back_home_kb(f"adm:uview:{tid}"))


@router.callback_query(F.data == "adm:usearch")
async def cb_adm_usearch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
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
    await _safe_answer(cb)
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
    await _safe_answer(cb)
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID:{cfg.get('support_user_id')}"
    text = (
        f"⚙️ <b>تنظیمات</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 پشتیبانی: <b>{html.escape(str(sup))}</b>\n"
        f"🔄 اسکن خودکار: <b>{'🟢' if cfg.get('auto_scan_enabled', True) else '🔴'}</b> | تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    await _edit(cb, text, kb([
        [btn("🌐 تنظیم لینک HTTPS مینی‌اپ", callback_data="adm:set_webapp", style="success")],
        [btn("💬 تغییر یوزرنیم پشتیبانی", callback_data="adm:set_sup", style="primary")],
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
    await _safe_answer(cb, "✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_maint")
async def cb_adm_tog_maint(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["maintenance_mode"] = not bool(store.data["settings"].get("maintenance_mode", False))
    store.save()
    await _safe_answer(cb, "✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
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



@router.callback_query(F.data == "adm:locks")
async def cb_adm_locks(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await state.clear()
    await _safe_answer(cb)
    cfg = store.data["settings"]
    tg_st = "🟢 روشن" if cfg.get("tg_lock_enabled") else "🔴 خاموش"
    yt_st = "🟢 روشن" if cfg.get("yt_lock_enabled") else "🔴 خاموش"
    tg_ch = cfg.get("tg_lock_channel") or "تنظیم نشده"
    yt_url = cfg.get("yt_lock_url") or "تنظیم نشده"

    text = (
        "🔒 <b>مدیریت قفل کانال تلگرام (واقعی) و یوتیوب (فیک)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"📢 <b>قفل تلگرام (واقعی):</b> {tg_st}\n"
        f"• کانال: <code>{html.escape(str(tg_ch))}</code>\n"
        f"• متن: <i>{html.escape(str(cfg.get('tg_lock_text', ''))[:90])}</i>\n\n"
        f"🎬 <b>قفل یوتیوب (فیک):</b> {yt_st}\n"
        f"• لینک: <code>{html.escape(str(yt_url))}</code>\n"
        f"• توضیحات: <i>{html.escape(str(cfg.get('yt_lock_text', ''))[:90])}</i>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "<i>نکته: برای کار کردن قفل واقعی تلگرام، ربات را در کانال خود ادمین کنید.</i>"
    )
    markup = kb([
        [
            btn(f"📢 قفل تلگرام: {tg_st}", callback_data="adm:tog_tg_lock", style="success" if cfg.get("tg_lock_enabled") else "danger"),
            btn(f"🎬 قفل یوتیوب: {yt_st}", callback_data="adm:tog_yt_lock", style="success" if cfg.get("yt_lock_enabled") else "danger"),
        ],
        [
            btn("✏️ تنظیم کانال تلگرام", callback_data="adm:set_tg_ch", style="primary"),
            btn("📝 متن قفل تلگرام", callback_data="adm:set_tg_txt", style="primary"),
        ],
        [
            btn("🔗 تنظیم لینک یوتیوب", callback_data="adm:set_yt_url", style="primary"),
            btn("📝 توضیحات یوتیوب", callback_data="adm:set_yt_txt", style="primary"),
        ],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ])
    await _edit(cb, text, markup)


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
    await _safe_answer(cb, "✅ وضعیت قفل تلگرام تغییر کرد.")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:tog_yt_lock")
async def cb_adm_tog_yt_lock(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["yt_lock_enabled"] = not bool(store.data["settings"].get("yt_lock_enabled", False))
    store.save()
    await _safe_answer(cb, "✅ وضعیت قفل یوتیوب تغییر کرد.")
    await cb_adm_locks(cb, state)


@router.callback_query(F.data == "adm:set_tg_ch")
async def cb_adm_set_tg_ch(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_channel)
    await _edit(cb, "📢 آیدی کانال تلگرام (مثال: <code>@MyChannel</code> یا آیدی عددی <code>-100...</code>) را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_channel)
async def handle_adm_set_tg_ch(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    store.data["settings"]["tg_lock_channel"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ کانال تلگرام روی <code>{html.escape(val)}</code> تنظیم شد.", parse_mode="HTML", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_tg_txt")
async def cb_adm_set_tg_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_tg_text)
    await _edit(cb, "📝 متن نمایشی قفل کانال تلگرام را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_tg_text)
async def handle_adm_set_tg_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["tg_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ متن قفل تلگرام ذخیره شد.", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_url")
async def cb_adm_set_yt_url(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_url)
    await _edit(cb, "🔗 لینک کانال یوتیوب را بفرستید (مثال: <code>https://youtube.com/@CyberMux</code>):", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_url)
async def handle_adm_set_yt_url(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    store.data["settings"]["yt_lock_url"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ لینک یوتیوب ذخیره شد: <code>{html.escape(val)}</code>", parse_mode="HTML", reply_markup=back_home_kb("adm:locks"))


@router.callback_query(F.data == "adm:set_yt_txt")
async def cb_adm_set_yt_txt(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_yt_text)
    await _edit(cb, "📝 توضیحات دستی قفل کانال یوتیوب را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:locks", style="danger")]]))


@router.message(Flow.adm_set_yt_text)
async def handle_adm_set_yt_txt(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    store.data["settings"]["yt_lock_text"] = (message.text or "").strip()
    store.save()
    await state.clear()
    await message.answer("✅ توضیحات قفل یوتیوب ذخیره شد.", reply_markup=back_home_kb("adm:locks"))



@router.callback_query(F.data == "adm:set_webapp")
async def cb_adm_set_webapp(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await _safe_answer(cb)
    await state.set_state(Flow.adm_set_webapp_url)
    cur = store.data["settings"].get("webapp_url") or "تنظیم نشده"
    await _edit(
        cb,
        f"🌐 <b>تنظیم لینک HTTPS مینی‌اپ تلگرام</b>\n"
        f"لینک فعلی: <code>{html.escape(cur)}</code>\n\n"
        f"لینک HTTPS مینی‌اپ خود را بفرستید (مثال: <code>https://app.prostoreshop.site</code>):",
        kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]),
    )


@router.message(Flow.adm_set_webapp_url)
async def handle_adm_set_webapp(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    if val and not val.startswith("https://"):
        await message.answer("⚠️ لینک مینی‌اپ تلگرام باید حتماً با <code>https://</code> شروع شود.", parse_mode="HTML")
        return
    store.data["settings"]["webapp_url"] = val
    store.save()
    await state.clear()
    await message.answer(f"✅ لینک مینی‌اپ ذخیره شد: <code>{html.escape(val)}</code>\nدکمه مینی‌اپ در منوی اصلی ربات فعال شد!", parse_mode="HTML", reply_markup=back_home_kb("adm:settings"))


# ==================== LIFECYCLE ====================
async def on_startup() -> None:
    global _webapp_runner
    logger.info("Starting V22 Background Engine + Telegram Mini App Server...")
    bg_engine.start()
    try:
        _webapp_runner = await start_mini_app_server(store, bg_engine, cf_service, port=8080)
    except Exception as exc:
        logger.warning("Mini App server could not bind port 8080: %s", exc)


async def on_shutdown() -> None:
    await bg_engine.stop()
    if _webapp_runner is not None:
        await _webapp_runner.cleanup()


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
    logger.info("Starting Cloudflare Config Hub V22 Pro Bot.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V22_EOF__

python3 -c '
from pathlib import Path
p = Path("docker-compose.yml")
txt = p.read_text(encoding="utf-8")
if "./data:/app/data" not in txt and "telegram_bot:" in txt:
    txt = txt.replace(
        "command: [\"python\", \"-m\", \"app.bot.bot\"]",
        "command: [\"python\", \"-m\", \"app.bot.bot\"]\n    volumes:\n      - ./data:/app/data"
    )
if "8080:8080" not in txt and "telegram_bot:" in txt:
    txt = txt.replace(
        "- ./data:/app/data",
        "- ./data:/app/data\n    ports:\n      - \"8080:8080\""
    )
p.write_text(txt, encoding="utf-8")
'

echo ">>> Rebuilding and restarting telegram_bot (with Mini App on port 8080)..."
docker compose up -d --build telegram_bot
sleep 4
docker compose logs --tail=30 telegram_bot
echo ">>> V22 Upgrade complete! Mini App running on port 8080."
