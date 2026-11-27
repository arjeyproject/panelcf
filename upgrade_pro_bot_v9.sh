#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V9 (Fixes HTTP 403 Error 1010 + Zero-500 Stealth Worker + Auto Custom Domain)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import hashlib
import json

# Production ES Module Cloudflare Worker (V9 — Zero-403 / Zero-500 Stealth Dual-Protocol Core)
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const UID = '__UUID__';
const T_PASS = '__TROJAN_PASS__';
const T_HASH = '__TROJAN_HASH__';
const RELAYS = __PROXY_IPS_JSON__;
const OP_POOLS = __OPERATOR_IPS_JSON__;
const BRAND = '__PANEL_BRAND__';

const WS_OPEN = 1;
const WS_CLOSING = 2;

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const upgrade = (request.headers.get('Upgrade') || '').toLowerCase();

      if (upgrade !== 'websocket') {
        if (url.pathname === '/health') {
          return new Response(JSON.stringify({
            ok: true,
            v: 'v9',
            brand: BRAND,
            relays: RELAYS.length,
            ts: Date.now()
          }), {
            status: 200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'cache-control': 'no-store'
            }
          });
        }

        if (url.pathname === `/sub/${UID}` || url.pathname === `/${UID}`) {
          const host = request.headers.get('Host') || url.hostname;
          const op = (url.searchParams.get('op') || 'mci').toLowerCase();
          const subText = buildSub(host, op);
          const b64 = btoa(unescape(encodeURIComponent(subText)));
          const names = { mci: 'همراه اول', mtn: 'ایرانسل', mkh: 'مخابرات', all: 'همه اپراتورها' };
          return new Response(b64, {
            status: 200,
            headers: {
              'content-type': 'text/plain; charset=utf-8',
              'profile-title': 'base64:' + btoa(unescape(encodeURIComponent(`⚡ ${BRAND} • ${names[op] || 'VIP'}`))),
              'profile-update-interval': '6',
              'cache-control': 'no-store'
            }
          });
        }

        return new Response('<!doctype html><html><head><title>Welcome</title></head><body><h1>200 OK</h1></body></html>', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      let overrideRelay = url.searchParams.get('proxyip') || url.searchParams.get('relay') || '';
      const m = url.pathname.match(/(?:proxyip|relay)=([^/&?#]+)/i);
      if (m && m[1]) overrideRelay = decodeURIComponent(m[1]);

      return handleWS(request, overrideRelay);
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: String(err && err.message || err) }), {
        status: 500,
        headers: { 'content-type': 'application/json; charset=utf-8' }
      });
    }
  }
};

function buildSub(host, opFilter) {
  const metaMap = {
    mci: { label: '🔵همراه اول', list: OP_POOLS.mci || [] },
    mtn: { label: '🟡ایرانسل', list: OP_POOLS.mtn || [] },
    mkh: { label: '🟢مخابرات', list: OP_POOLS.mkh || [] },
  };
  const keys = opFilter === 'all' ? ['mci', 'mtn', 'mkh'] : [metaMap[opFilter] ? opFilter : 'mci'];
  const wsPath = encodeURIComponent('/ws?ed=2560');
  const out = [];

  for (const k of keys) {
    const meta = metaMap[k];
    const arr = meta.list.length ? meta.list : [{ ip: host, latency_ms: 0, colo: 'CF' }];
    const i1 = arr[0];
    const i2 = arr[1] || arr[0];
    const hp = (it) => {
      const s = typeof it === 'string' ? it : it.ip;
      return s.includes(':') ? `[${s}]` : s;
    };
    const pg = (it) => (it && it.latency_ms) ? `🟢${Math.round(it.latency_ms)}ms` : '⚡Auto';
    const co = (it) => (it && it.colo) ? `•${it.colo}` : '';

    out.push(`vless://${UID}@${hp(i1)}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${encodeURIComponent(`${meta.label} • VLESS-1 • ${pg(i1)}${co(i1)} • ${BRAND}`)}`);
    out.push(`vless://${UID}@${hp(i2)}:2053?encryption=none&security=tls&sni=${host}&fp=randomized&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${encodeURIComponent(`${meta.label} • VLESS-2 • ${pg(i2)}${co(i2)} • ${BRAND}`)}`);
    const tp = encodeURIComponent(T_PASS);
    out.push(`trojan://${tp}@${hp(i1)}:443?security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${encodeURIComponent(`${meta.label} • Trojan-1 • ${pg(i1)}${co(i1)} • ${BRAND}`)}`);
    out.push(`trojan://${tp}@${hp(i2)}:2083?security=tls&sni=${host}&fp=randomized&type=ws&host=${host}&path=${wsPath}&alpn=http%2F1.1#${encodeURIComponent(`${meta.label} • Trojan-2 • ${pg(i2)}${co(i2)} • ${BRAND}`)}`);
  }
  return out.join('\n');
}

function parseHostPort(raw, defPort) {
  const s = String(raw || '').trim();
  if (!s) return [null, defPort];
  if (s.startsWith('[')) {
    const end = s.indexOf(']');
    if (end !== -1) {
      const rest = s.slice(end + 1);
      return [s.slice(1, end), (rest.startsWith(':') ? Number(rest.slice(1)) : defPort) || defPort];
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

function handleWS(request, overrideRelay) {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  const earlyHdr = request.headers.get('sec-websocket-protocol') || '';
  const readableWS = wsToReadable(server, earlyHdr);
  const remoteBox = { value: null };
  let isDns = false;
  let dnsFn = null;

  const relayList = overrideRelay
    ? [overrideRelay, ...RELAYS.filter(r => r !== overrideRelay)]
    : [...RELAYS];

  readableWS.pipeTo(new WritableStream({
    async write(chunk) {
      const u8 = toU8(chunk);
      if (isDns && dnsFn) {
        await dnsFn(u8);
        return;
      }
      if (remoteBox.value) {
        const w = remoteBox.value.writable.getWriter();
        try { await w.write(u8); } finally { w.releaseLock(); }
        return;
      }

      let parsed = parseTrojan(u8);
      let respHead = null;
      if (parsed.err) {
        const vl = parseVless(u8, UID);
        if (vl.err) throw new Error(vl.msg);
        parsed = vl;
        respHead = new Uint8Array([vl.ver, 0]);
      }

      const initData = u8.slice(parsed.idx);
      if (parsed.udp) {
        if (parsed.port === 53) {
          isDns = true;
          dnsFn = makeDns(server, respHead);
          await dnsFn(initData);
          return;
        }
        throw new Error('UDP port unsupported');
      }

      await openOutbound(remoteBox, parsed.host, parsed.port, initData, server, respHead, relayList);
    },
    close() {},
    abort() {}
  })).catch(() => closeWS(server));

  return new Response(null, { status: 101, webSocket: client });
}

async function openOutbound(remoteBox, host, port, initData, ws, respHead, relays) {
  async function dial(h, p) {
    const sock = connect({ hostname: h, port: Number(p) });
    if (sock.opened && sock.opened.catch) sock.opened.catch(() => {});
    if (sock.closed && sock.closed.catch) sock.closed.catch(() => {});
    remoteBox.value = sock;
    const w = sock.writable.getWriter();
    try {
      if (initData && initData.byteLength > 0) await w.write(initData);
    } finally {
      w.releaseLock();
    }
    return sock;
  }

  async function tryRelay(i) {
    if (i >= relays.length) {
      closeWS(ws);
      return;
    }
    const [rh, rp] = parseHostPort(relays[i], port);
    if (!rh) {
      await tryRelay(i + 1);
      return;
    }
    try {
      const sock = await dial(rh, rp);
      pumpToWS(sock, ws, respHead, () => tryRelay(i + 1)).catch(() => closeWS(ws));
    } catch (_) {
      await tryRelay(i + 1);
    }
  }

  try {
    const sock = await dial(host, port);
    pumpToWS(sock, ws, respHead, () => tryRelay(0)).catch(() => closeWS(ws));
  } catch (_) {
    await tryRelay(0).catch(() => closeWS(ws));
  }
}

async function pumpToWS(sock, ws, respHead, onEmptyRetry) {
  let head = respHead;
  let received = false;

  try {
    await sock.readable.pipeTo(new WritableStream({
      async write(chunk) {
        received = true;
        if (ws.readyState !== WS_OPEN) throw new Error('ws closed');
        const data = toU8(chunk);
        if (head) {
          const merged = new Uint8Array(head.byteLength + data.byteLength);
          merged.set(head, 0);
          merged.set(data, head.byteLength);
          ws.send(merged);
          head = null;
        } else {
          ws.send(data);
        }
      },
      abort() {}
    }));
  } catch (_) {}

  if (!received && onEmptyRetry) {
    await onEmptyRetry();
  } else {
    closeWS(ws);
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
        out[plen] = (ans.byteLength >> 8) & 0xff;
        out[plen + 1] = ans.byteLength & 0xff;
        out.set(ans, plen + 2);
        if (ws.readyState === WS_OPEN) ws.send(out);
      }
    } catch (_) {}
  };
}

function parseTrojan(u8) {
  if (u8.byteLength < 64 || u8[56] !== 13 || u8[57] !== 10) return { err: true, msg: 'not trojan' };
  const h = new TextDecoder().decode(u8.subarray(0, 56)).toLowerCase();
  if (h !== T_HASH.toLowerCase()) return { err: true, msg: 'bad trojan hash' };
  const cmd = u8[58];
  if (cmd !== 1 && cmd !== 3) return { err: true, msg: 'bad cmd' };
  const atyp = u8[59];
  let idx = 60, host = '';
  if (atyp === 1) {
    if (idx + 4 > u8.byteLength) return { err: true, msg: 'short v4' };
    host = `${u8[idx]}.${u8[idx+1]}.${u8[idx+2]}.${u8[idx+3]}`;
    idx += 4;
  } else if (atyp === 3) {
    const dl = u8[idx++];
    if (idx + dl > u8.byteLength) return { err: true, msg: 'short dom' };
    host = new TextDecoder().decode(u8.subarray(idx, idx + dl));
    idx += dl;
  } else if (atyp === 4) {
    if (idx + 16 > u8.byteLength) return { err: true, msg: 'short v6' };
    const p = [];
    for (let i = 0; i < 8; i++) p.push(((u8[idx + i*2] << 8) | u8[idx + i*2 + 1]).toString(16));
    host = p.join(':');
    idx += 16;
  } else return { err: true, msg: 'bad atyp' };
  if (idx + 2 > u8.byteLength) return { err: true, msg: 'short port' };
  const port = (u8[idx] << 8) | u8[idx + 1];
  idx += 2;
  if (idx + 2 <= u8.byteLength && u8[idx] === 13 && u8[idx + 1] === 10) idx += 2;
  return { err: false, host, port, idx, udp: cmd === 3 };
}

function parseVless(u8, uid) {
  if (u8.byteLength < 24) return { err: true, msg: 'short vless' };
  const ver = u8[0];
  if (toUuid(u8.subarray(1, 17)).toLowerCase() !== uid.toLowerCase()) return { err: true, msg: 'bad uuid' };
  const opt = u8[17];
  const cmd = u8[18 + opt];
  if (cmd !== 1 && cmd !== 2) return { err: true, msg: 'bad cmd' };
  const pi = 19 + opt;
  const port = (u8[pi] << 8) | u8[pi + 1];
  const at = u8[pi + 2];
  let idx = pi + 3, host = '';
  if (at === 1) {
    host = `${u8[idx]}.${u8[idx+1]}.${u8[idx+2]}.${u8[idx+3]}`;
    idx += 4;
  } else if (at === 2) {
    const dl = u8[idx++];
    host = new TextDecoder().decode(u8.subarray(idx, idx + dl));
    idx += dl;
  } else if (at === 3) {
    const p = [];
    for (let i = 0; i < 8; i++) p.push(((u8[idx + i*2] << 8) | u8[idx + i*2 + 1]).toString(16));
    host = p.join(':');
    idx += 16;
  } else return { err: true, msg: 'bad at' };
  return { err: false, host, port, idx, ver, udp: cmd === 2 };
}

function wsToReadable(ws, earlyHdr) {
  let canceled = false;
  return new ReadableStream({
    start(ctrl) {
      ws.addEventListener('message', (e) => { if (!canceled) ctrl.enqueue(e.data); });
      ws.addEventListener('close', () => { closeWS(ws); if (!canceled) { try { ctrl.close(); } catch (_) {} } });
      ws.addEventListener('error', (e) => { try { ctrl.error(e); } catch (_) {} });
      const early = b64ToU8(earlyHdr);
      if (early) ctrl.enqueue(early);
    },
    cancel() { canceled = true; closeWS(ws); }
  });
}

function b64ToU8(b64) {
  if (!b64) return null;
  try {
    const bin = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch (_) { return null; }
}

const HEX = Array.from({ length: 256 }, (_, i) => (i + 0x100).toString(16).slice(1));
function toUuid(a) {
  return `${HEX[a[0]]}${HEX[a[1]]}${HEX[a[2]]}${HEX[a[3]]}-${HEX[a[4]]}${HEX[a[5]]}-${HEX[a[6]]}${HEX[a[7]]}-${HEX[a[8]]}${HEX[a[9]]}-${HEX[a[10]]}${HEX[a[11]]}${HEX[a[12]]}${HEX[a[13]]}${HEX[a[14]]}${HEX[a[15]]}`;
}

function closeWS(ws) {
  try { if (ws.readyState === WS_OPEN || ws.readyState === WS_CLOSING) ws.close(); } catch (_) {}
}
""".strip()

DEFAULT_PROXY_IPS = [
    "proxyip.cmliussss.net",
    "bpb.yousef.isegaro.com",
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
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/ws_tester.py
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


async def check_ip_routes_worker(worker_host: str, connect_ip: str, port: int = 443, timeout_sec: float = 4.0) -> tuple[bool, float | None, str]:
    """
    Verifies a Clean IP routes `Host: worker_host` to `/health` -> HTTP 200 using realistic browser headers.
    """
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
    """
    Real end-to-end VLESS / Trojan over WebSocket tunnel test.
    CRITICAL FIX: Includes Chrome User-Agent + Origin + Accept-Language headers to bypass Cloudflare Error 1010 (403 Forbidden)!
    """
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

        if b"204" in body or b"HTTP/1.1 20" in body:
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
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/operator_scanner.py
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

OPERATOR_DNS_SOURCES: dict[str, list[str]] = {
    "mci": ["mci.ircf.space", "mcic.ircf.space", "mci.cf.vfarid.com"],
    "mtn": ["mtn.ircf.space", "mtnc.ircf.space", "mtn.cf.vfarid.com"],
    "mkh": ["mkh.ircf.space", "tci.ircf.space", "mkh.cf.vfarid.com"],
}

FALLBACK_EDGE_IPS: dict[str, list[str]] = {
    "mci": ["104.16.132.229", "104.17.148.22", "104.18.32.47", "172.64.155.209", "188.114.96.3", "162.159.135.42"],
    "mtn": ["104.16.133.229", "104.17.147.22", "104.19.44.11", "172.67.70.10", "188.114.97.3", "162.159.136.42"],
    "mkh": ["104.16.51.111", "104.18.21.226", "104.21.48.84", "172.64.147.228", "188.114.98.3", "162.159.137.42"],
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

        colo_bonus = 12.0 if colo in IRAN_PREFERRED_COLOS else 0.0
        score = round(max(10.0, min(100.0, 92.0 - (rtt_ms / 8.0) + colo_bonus)), 2)
        return {
            "ip": ip, "port": port, "ip_version": ipaddress.ip_address(ip).version,
            "latency_ms": rtt_ms, "colo": colo or "CF", "score": score,
            "verified_trace": True, "tested_at": datetime.now(timezone.utc).isoformat(),
        }
    except Exception:
        return None


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
        candidate_map: dict[str, str] = {}
        for mip in (manual_overrides or {}).get(op, []):
            try:
                candidate_map[str(ipaddress.ip_address(mip.strip()))] = "admin_manual"
            except ValueError:
                continue

        dns_domains = OPERATOR_DNS_SOURCES.get(op, [])
        resolved_lists = await asyncio.gather(*(resolve_doh_records(d, "A") for d in dns_domains))
        for dom, ips in zip(dns_domains, resolved_lists):
            for ip in ips:
                candidate_map.setdefault(ip, dom)

        for fb in FALLBACK_EDGE_IPS.get(op, []):
            candidate_map.setdefault(fb, "cf_edge_clean")

        probed = await asyncio.gather(*(_probe(ip, src) for ip, src in candidate_map.items()))
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
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/wg_handshake.py
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
    return _blake2s(bytes(b ^ 0x5C for b in key) + _blake2s(bytes(b ^ 0x36 for b in key) + data))


def _kdf2(key: bytes, inp: bytes) -> tuple[bytes, bytes]:
    t0 = _hmac_blake2s(key, inp)
    t1 = _hmac_blake2s(t0, b"\x01")
    t2 = _hmac_blake2s(t0, t1 + b"\x02")
    return t1, t2


def _aead_encrypt(key: bytes, counter: int, plaintext: bytes, aad: bytes) -> bytes:
    return ChaCha20Poly1305(key).encrypt(b"\x00\x00\x00\x00" + struct.pack("<Q", counter), plaintext, aad)


def _tai64n_now() -> bytes:
    ns = time.time_ns()
    return struct.pack(">QI", (ns // 1_000_000_000) + 4611686018427387914, ns % 1_000_000_000)


def build_wireguard_handshake_initiation(
    client_private_key_b64: str,
    peer_public_key_b64: str,
    reserved: list[int] | None = None,
) -> tuple[bytes, int]:
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


async def probe_real_warp_handshake(
    host: str,
    port: int,
    client_private_key_b64: str,
    peer_public_key_b64: str,
    reserved: list[int] | None = None,
    timeout_sec: float = 2.0,
) -> tuple[bool, float | None]:
    loop = asyncio.get_running_loop()
    transport = None
    try:
        clean = host.strip("[]")
        family = socket.AF_INET6 if ipaddress.ip_address(clean).version == 6 else socket.AF_INET
        pkt, sidx = build_wireguard_handshake_initiation(client_private_key_b64, peer_public_key_b64, reserved=reserved)
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(
            loop.create_datagram_endpoint(lambda: _WGRespProto(fut), remote_addr=(clean, port), family=family),
            timeout=timeout_sec,
        )
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
        if transport is not None:
            transport.close()
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/warp_builder.py
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
                        act = await client.patch(
                            f"{reg_url}/{dev_id}",
                            json={"warp_enabled": True},
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
    reg: WarpRegistration,
    ep_v4: str,
    ep_v6: str,
    platform: PlatformType,
    ip_mode: IPMode = "ipv6",
    ping_ms: float | None = None,
    brand: str = "CFHub",
) -> dict:
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

    wg_label = format_beautiful_name(f"🛡️{brand}", f"WARP-{mode_tag}", ping_ms, plat_tag)
    wow_label = format_beautiful_name(f"🌀{brand}", f"WoW-{mode_tag}", ping_ms, plat_tag)
    auto_label = format_beautiful_name(f"🎯{brand}", f"Auto-{mode_tag}", None, plat_tag)

    wg_query = urlencode({"address": ",".join(local_addrs), "reserved": reserved_csv, "publickey": reg.peer_public_key, "mtu": str(mtu)})
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{primary_hp}?{wg_query}#{quote(wg_label)}"
    warp_auto_uri = f"warp://auto?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(auto_label)}"
    wow_uri = (
        f"warp://{primary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(wow_label)}"
        f"&&detour=warp://{secondary_hp}?ifp=10-20&ifps=20-60&ifpd=5-10#{quote(f'🌍Exit•{brand}')}"
    )

    amnezia_conf = "\n".join([
        f"# {wg_label}", "[Interface]", f"PrivateKey = {reg.private_key}", f"Address = {', '.join(local_addrs)}",
        f"DNS = {wg_dns}", f"MTU = {mtu}", "Jc = 4", "Jmin = 40", "Jmax = 70", "S1 = 0", "S2 = 0", "H1 = 1", "H2 = 2", "H3 = 3", "H4 = 4",
        "", "[Peer]", f"PublicKey = {reg.peer_public_key}", f"AllowedIPs = {', '.join(allowed_ips)}",
        f"Endpoint = {primary_hp}", "PersistentKeepalive = 25",
    ]) + "\n"

    return {
        "label": wg_label, "endpoint": primary_hp, "wireguard_uri": wireguard_uri,
        "warp_auto_uri": warp_auto_uri, "wow_uri": wow_uri,
        "amnezia_conf": amnezia_conf, "amnezia_filename": f"cfhub_warp_{ip_mode}_{platform}.conf", "reserved": reserved,
    }
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/bg_engine.py
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


class BackgroundScannerEngine:
    def __init__(self, store):
        self.store = store
        self._loop_task: asyncio.Task | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.last_scan_at: str | None = None

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_v9")

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
                logger.exception("V9 background scan error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_full_cycle(self, trigger: str = "manual") -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async with self._scan_lock:
            self.is_scanning = True
            timeout_sec = float(self.store.data["settings"].get("scan_timeout_sec", 2.6))
            try:
                self.current_stage = "operator_ips"
                manual = self.store.data.get("manual_operator_ips", {})
                op_pools = await refresh_operator_clean_pools(manual_overrides=manual, timeout_sec=timeout_sec)
                for op in ("mci", "mtn", "mkh"):
                    if op_pools.get(op):
                        self.store.data["operator_pools"][op] = op_pools[op]

                if self.store.data["settings"].get("auto_apply_ip", True):
                    for panel in self.store.data.get("panels", {}).values():
                        if panel.get("auto_ip", True):
                            best = self.get_best_operator_ips(panel.get("operator", "mci"), 1)
                            if best:
                                panel["clean_ip"] = best[0]["ip"]

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
                            return {
                                "endpoint": f"[{host}]:{port}" if version == 6 else f"{host}:{port}",
                                "ip_version": version, "latency_ms": rtt, "tested_at": now.isoformat(),
                            }

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
                    "warp_v4": len(self.store.data.get("warp_v4_pool", [])),
                    "warp_v6": len(self.store.data.get("warp_v6_pool", [])),
                }
            finally:
                self.is_scanning = False
                self.current_stage = "idle"

    def get_best_operator_ips(self, op: str = "mci", count: int = 8) -> list[dict[str, Any]]:
        items = list(self.store.data.get("operator_pools", {}).get(op, []))[:count]
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
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/store.py
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
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/cf_manager.py
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
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e


@dataclass
class CloudflareDeployResult:
    ok: bool
    account_id: str | None = None
    account_name: str | None = None
    script_name: str | None = None
    worker_host: str | None = None
    custom_domain_bound: bool = False
    sub_url: str | None = None
    vless_verified: bool = False
    vless_ms: float | None = None
    vless_msg: str = ""
    trojan_verified: bool = False
    trojan_ms: float | None = None
    trojan_msg: str = ""
    error: str | None = None


class CloudflarePanelService:
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
                        return CloudflareDeployResult(ok=False, error="لطفاً یک‌بار در کلودفلر وارد Workers & Pages شوید تا ساب‌دامنه رایگان workers.dev ساخته شود.")

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
                custom_bound = False

                # BONUS: If the user's Cloudflare account has an active custom Zone, auto-bind `edge.<zone>`
                # to eliminate `workers.dev` SNI filtering in Iran completely!
                try:
                    r_z = await client.get(f"{self.BASE}/zones", headers=headers, params={"status": "active", "per_page": 3})
                    zones = r_z.json().get("result") or [] if r_z.status_code == 200 else []
                    if zones:
                        zone = zones[0]
                        zone_id = zone["id"]
                        custom_host = f"{script_name}.{zone['name']}"
                        # Bind custom Worker Domain directly via Cloudflare Workers Domains API
                        r_dom = await client.put(
                            f"{self.BASE}/accounts/{account_id}/workers/domains",
                            headers={**headers, "Content-Type": "application/json"},
                            json={
                                "environment": "production",
                                "hostname": custom_host,
                                "service": script_name,
                                "zone_id": zone_id,
                            },
                        )
                        if r_dom.status_code in (200, 201) and r_dom.json().get("success"):
                            worker_host = custom_host
                            custom_bound = True
                except Exception:
                    pass

                sub_url = f"https://{worker_host}/sub/{user_uuid}"

                await asyncio.sleep(2.5)
                (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg) = await asyncio.gather(
                    test_worker_tunnel_e2e(worker_host, None, "vless", user_uuid),
                    test_worker_tunnel_e2e(worker_host, None, "trojan", trojan_password),
                )

                return CloudflareDeployResult(
                    ok=True,
                    account_id=account_id,
                    account_name=account_name,
                    script_name=script_name,
                    worker_host=worker_host,
                    custom_domain_bound=custom_bound,
                    sub_url=sub_url,
                    vless_verified=v_ok,
                    vless_ms=v_ms,
                    vless_msg=v_msg,
                    trojan_verified=t_ok,
                    trojan_ms=t_ms,
                    trojan_msg=t_msg,
                )
        except Exception as exc:
            return CloudflareDeployResult(ok=False, error=f"خطا در اتصال به کلودفلر: {exc}")

    @staticmethod
    async def pick_two_verified_worker_ips(worker_host: str, candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not candidates:
            return [{"ip": worker_host, "latency_ms": None, "colo": "CF"}]
        checked = await asyncio.gather(
            *(check_ip_routes_worker(worker_host, c["ip"], 443, timeout_sec=3.0) for c in candidates[:8])
        )
        passing = []
        for cand, (ok, ms, _) in zip(candidates[:8], checked):
            if ok:
                item = dict(cand)
                if ms is not None:
                    item["latency_ms"] = ms
                passing.append(item)
        if len(passing) >= 2:
            return passing[:2]
        if len(passing) == 1:
            return [passing[0], passing[0]]
        return [{"ip": worker_host, "latency_ms": None, "colo": "Direct"}, {"ip": worker_host, "latency_ms": None, "colo": "Direct"}]

    @staticmethod
    def build_four_clean_configs(panel: dict[str, Any], ip_pair: list[dict[str, Any]], operator: str = "mci") -> dict[str, Any]:
        it1 = ip_pair[0]
        it2 = ip_pair[1] if len(ip_pair) > 1 else ip_pair[0]
        op_lbl = OPERATOR_LABELS.get(operator, "⚡CF")
        brand = panel.get("name", "CFHub")
        tpass = quote(panel["trojan_password"], safe="")

        def _hp(ip: str) -> str:
            return f"[{ip}]" if ":" in ip else ip

        def _vless(it: dict, idx: int, port: int, fp: str) -> str:
            params = {
                "encryption": "none", "security": "tls", "type": "ws",
                "host": panel["host"], "sni": panel["sni"], "path": "/ws?ed=2560",
                "fp": fp, "alpn": "http/1.1",
            }
            extra = f"{it.get('colo')}•{brand}" if it.get("colo") else brand
            tag = format_beautiful_name(op_lbl, f"VLESS-{idx}", it.get("latency_ms"), extra)
            return f"vless://{panel['uuid']}@{_hp(it['ip'])}:{port}?{urlencode(params)}#{quote(tag)}"

        def _trojan(it: dict, idx: int, port: int, fp: str) -> str:
            params = {
                "security": "tls", "type": "ws",
                "host": panel["host"], "sni": panel["sni"], "path": "/ws?ed=2560",
                "fp": fp, "alpn": "http/1.1",
            }
            extra = f"{it.get('colo')}•{brand}" if it.get("colo") else brand
            tag = format_beautiful_name(op_lbl, f"Trojan-{idx}", it.get("latency_ms"), extra)
            return f"trojan://{tpass}@{_hp(it['ip'])}:{port}?{urlencode(params)}#{quote(tag)}"

        return {
            "vless_1": _vless(it1, 1, 443, "chrome"),
            "vless_2": _vless(it2, 2, 2053, "randomized"),
            "trojan_1": _trojan(it1, 1, 443, "chrome"),
            "trojan_2": _trojan(it2, 2, 2083, "randomized"),
        }
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/ui.py
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
    "%5D&accountId=*&zoneId=all&name=CFHubV9"
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
            [btn("🎛️ My Panel (2 VLESS + 2 Trojan)", callback_data="m:mypanel", style="success")]
            if has_panel
            else [btn("🚀 Create Free Panel (VLESS + Trojan)", callback_data="m:turbo", style="success")]
        )
        rows = [
            top,
            [btn("🛡️ WARP / WireGuard (IPv4 + IPv6)", callback_data="m:warp", style="primary")],
            [btn("📶 Clean IPs by Operator", callback_data="m:isp", style="primary")],
            [btn("📱 Apps", callback_data="m:apps", style="primary"), btn("📖 Guide", callback_data="m:guide", style="primary")],
            [btn("💬 Support", callback_data="m:support", style="primary"), btn("🇮🇷 فارسی", callback_data="m:lang", style="primary")],
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
        [btn("📱 برنامه‌ها", callback_data="m:apps", style="primary"), btn("📖 آموزش اتصال", callback_data="m:guide", style="primary")],
        [btn("💬 پشتیبانی", callback_data="m:support", style="primary"), btn("🌐 English", callback_data="m:lang", style="primary")],
    ]
    if is_admin:
        rows.append([btn("🛠️ پنل مدیریت", callback_data="adm:home", style="danger")])
    return kb(rows)


def back_home_kb(back_cb: str = "m:home", lang: str = "fa") -> InlineKeyboardMarkup:
    return kb([[btn("🔙 بازگشت" if lang == "fa" else "🔙 Back", callback_data=back_cb, style="primary")]])
__CFHUB_V9_EOF__

cat <<'__CFHUB_V9_EOF__' > backend/app/bot/bot.py
from __future__ import annotations

import asyncio
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
from app.bot.ws_tester import check_ip_routes_worker, test_worker_tunnel_e2e
from app.core.config import get_settings
from app.core.logging import configure_logging
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


def _home_text(tg_id: int) -> str:
    pools = store.data.get("operator_pools", {})
    panel = store.data.get("panels", {}).get(str(tg_id))
    panel_line = (
        f"🎛️ پنل شما: 🟢 <b>فعال</b> (<code>{html.escape(panel['host'])}</code>)"
        if panel
        else "🎛️ پنل شما: ⚪ هنوز ساخته نشده"
    )
    return (
        "⚡ <b>Cloudflare Config Hub — کانفیگ رایگان و تست‌شده</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🔵 همراه اول: <b>{len(pools.get('mci', []))}</b> | 🟡 ایرانسل: <b>{len(pools.get('mtn', []))}</b> | 🟢 مخابرات: <b>{len(pools.get('mkh', []))}</b>\n"
        f"🛡️ رله WARP سالم: <b>{len(store.data.get('warp_v4_pool', []))}</b> IPv4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> IPv6\n"
        f"{panel_line}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "👇 گزینه مورد نظر را انتخاب کنید:"
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


# ==================== 1. PANEL DEPLOY (DIRECT CF TOKEN -> V9 STEALTH WORKER + AUTO CUSTOM DOMAIN) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    uid = cb.from_user.id
    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت پنل رایگان (۲ VLESS + ۲ Trojan)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلودفلر نداری، اول ثبت‌نام کن.\n"
        "2️⃣ دکمه سبز <b>دریافت مستقیم توکن</b> را بزن (دسترسی‌ها آماده است).\n"
        "3️⃣ در کلودفلر روی <b>Continue to summary</b> و سپس <b>Create Token</b> بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "🔐 <i>اگر دامنه شخصی روی اکانت کلودفلر شما باشد، خودکار متصل می‌شود تا فیلتر workers.dev هم دور زده شود.</i>"
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

    wait_msg = await message.answer("⏳ <b>در حال دیپلوی موتور V9 و تست واقعی اتصال VLESS و Trojan...</b>", parse_mode="HTML")

    old = store.data["panels"].get(str(uid)) or {}
    panel_uuid = old.get("uuid") or str(uuid.uuid4())
    trojan_pass = old.get("trojan_password") or secrets.token_urlsafe(12)
    script_name = old.get("script_name") or f"cfhub-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"
    brand = old.get("name") or "CFHub"
    proxy_ip = old.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.cmliussss.net")

    dep = await cf_service.deploy_dual_worker(
        api_token=raw_token,
        user_uuid=panel_uuid,
        trojan_password=trojan_pass,
        script_name=script_name,
        proxy_ip=proxy_ip,
        operator_pools=store.data.get("operator_pools", {}),
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
        "custom_domain": dep.custom_domain_bound,
        "sub_url": dep.sub_url,
        "operator": old.get("operator", "mci"),
        "clean_ip": clean_ip,
        "proxy_ip": proxy_ip,
        "auto_ip": True,
        "worker_version": "v9",
        "created_at": old.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    v_badge = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:75])}"
    t_badge = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:75])}"
    dom_note = " (دامنه شخصی متصل شد ✅)" if dep.custom_domain_bound else ""
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"🎉 <b>پنل V9 شما دیپلوی شد!{dom_note}</b>\n"
        f"🔷 VLESS: <b>{v_badge}</b>\n🔐 Trojan: <b>{t_badge}</b>\n\n{text}",
        parse_mode="HTML",
        reply_markup=markup,
    )


# ==================== 2. MY PANEL — EXACT 4 CLEAN CONFIGS (2 VLESS + 2 TROJAN) ====================
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
    ver_note = "" if panel.get("worker_version") == "v9" else "\n⚠️ <i>لطفاً یک‌بار دکمه سبز <b>♻️ آپدیت Worker به V9</b> را بزنید.</i>\n"
    text = (
        "🎛️ <b>پنل اختصاصی من</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 Worker: <code>{html.escape(panel['host'])}</code>\n"
        f"📶 اپراتور فعال: <b>{OPERATOR_LABELS.get(op, op)}</b>\n"
        f"🔗 لینک سابسکریپشن (۴ کانفیگ مرتب):\n<code>{html.escape(panel.get('sub_url', ''))}</code>\n"
        f"{ver_note}"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "اپراتور خود را بزنید تا <b>۴ کانفیگ سالم و تست‌شده (۲ VLESS + ۲ Trojan)</b> دریافت کنید:"
    )
    markup = kb([
        [
            btn("🔵 همراه اول", callback_data="cf:getop:mci", style="success"),
            btn("🟡 ایرانسل", callback_data="cf:getop:mtn", style="success"),
            btn("🟢 مخابرات", callback_data="cf:getop:mkh", style="success"),
        ],
        [
            btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary"),
            btn("♻️ آپدیت Worker به V9", callback_data="cf:redeploy", style="success"),
        ],
        [
            btn("🏷️ تغییر نام", callback_data="cf:edit_name", style="primary"),
            btn("🔁 تغییر ProxyIP", callback_data="cf:edit_proxyip", style="primary"),
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
    op = cb.data.split(":")[2]
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer(f"⏳ انتخاب ۲ IP تاییدشده برای {OPERATOR_LABELS.get(op, op)}...")

    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)

    pool = bg_engine.get_best_operator_ips(op, 8)
    offset = int(panel.get(f"rot_{op}", 0)) % max(1, len(pool))
    rotated = pool[offset:] + pool[:offset]
    panel[f"rot_{op}"] = offset + 2

    verified_pair = await cf_service.pick_two_verified_worker_ips(panel["host"], rotated)
    panel["operator"] = op
    panel["clean_ip"] = verified_pair[0]["ip"]
    store.save()
    store.increment_stat(uid, "configs_generated")

    c4 = cf_service.build_four_clean_configs(panel, verified_pair, operator=op)
    op_lbl = OPERATOR_LABELS.get(op, op)
    op_sub = f"{panel.get('sub_url', '')}?op={op}"

    msg = (
        f"⚡ <b>۴ کانفیگ اختصاصی {op_lbl}</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔷 <b>VLESS #1 (پورت 443):</b>\n"
        f"<code>{html.escape(c4['vless_1'])}</code>\n\n"
        f"🔷 <b>VLESS #2 (پورت 2053):</b>\n"
        f"<code>{html.escape(c4['vless_2'])}</code>\n\n"
        f"🔐 <b>Trojan #1 (پورت 443):</b>\n"
        f"<code>{html.escape(c4['trojan_1'])}</code>\n\n"
        f"🔐 <b>Trojan #2 (پورت 2083):</b>\n"
        f"<code>{html.escape(c4['trojan_2'])}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🔗 <b>لینک سابسکریپشن {op_lbl}:</b>\n"
        f"<code>{html.escape(op_sub)}</code>"
    )
    await _edit(
        cb,
        msg,
        kb([
            [btn(f"🔄 تعویض با ۲ IP جدید ({op_lbl})", callback_data=f"cf:getop:{op}", style="success")],
            [btn("🩺 تست سرتاسری پنل", callback_data="cf:e2e_test", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:e2e_test")
async def cb_cf_e2e_test(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    await cb.answer("🩺 در حال تست سرتاسری...")
    wait = await cb.message.answer("⏳ در حال تست واقعی پنل (با هدر استاندارد مرورگر Chrome)...")
    if not panel.get("trojan_password"):
        panel["trojan_password"] = secrets.token_urlsafe(12)
        store.save()

    (h_ok, h_ms, h_msg), (v_ok, v_ms, v_msg), (t_ok, t_ms, t_msg), (p_ok, p_ms, p_msg) = await asyncio.gather(
        check_ip_routes_worker(panel["host"], panel["clean_ip"], 443),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "trojan", panel["trojan_password"], target_host="www.gstatic.com"),
        test_worker_tunnel_e2e(panel["host"], None, "vless", panel["uuid"], target_host="cp.cloudflare.com"),
    )

    h_l = f"🟢 <b>سالم</b> ({h_ms}ms)" if h_ok else f"🔴 <b>خطا</b> ({html.escape(h_msg[:95])})"
    v_l = f"🟢 <b>سالم</b> ({v_ms}ms)" if v_ok else f"🔴 <b>خطا</b> ({html.escape(v_msg[:110])})"
    t_l = f"🟢 <b>سالم</b> ({t_ms}ms)" if t_ok else f"🔴 <b>خطا</b> ({html.escape(t_msg[:110])})"
    p_l = f"🟢 <b>سالم</b> ({p_ms}ms)" if p_ok else f"🟡 <b>نیاز به ProxyIP</b> ({html.escape(p_msg[:95])})"

    hint = "" if (v_ok and t_ok) else "\n\n💡 روی دکمه سبز <b>♻️ آپدیت Worker به V9</b> بزنید و دوباره تست بگیرید."
    await wait.edit_text(
        f"🩺 <b>نتیجه تست سرتاسری پنل شما (V9)</b>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🌐 روتینگ IP تمیز (<code>{html.escape(panel['clean_ip'])}</code>): {h_l}\n"
        f"🔷 تونل واقعی VLESS: {v_l}\n"
        f"🔐 تونل واقعی Trojan: {t_l}\n"
        f"🔁 فالبک ProxyIP: {p_l}{hint}",
        parse_mode="HTML",
        reply_markup=kb([
            [btn("♻️ آپدیت Worker به V9", callback_data="cf:redeploy", style="success")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]),
    )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await cb.answer("⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return
    await cb.answer("♻️ در حال آپدیت Worker به V9...")
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
        panel["custom_domain"] = dep.custom_domain_bound
        panel["worker_version"] = "v9"
        store.save()
        v_s = f"🟢 {dep.vless_ms}ms" if dep.vless_verified else f"🔴 {html.escape(dep.vless_msg[:60])}"
        t_s = f"🟢 {dep.trojan_ms}ms" if dep.trojan_verified else f"🔴 {html.escape(dep.trojan_msg[:60])}"
        text, markup = _render_personal_panel(uid)
        await _edit(cb, f"✅ <b>Worker به نسخه V9 آپدیت شد!</b>\n🔷 VLESS: <b>{v_s}</b>\n🔐 Trojan: <b>{t_s}</b>\n\n{text}", markup)
    else:
        await cb.message.answer(f"❌ خطا در آپدیت Worker: <code>{html.escape(dep.error or '')}</code>", parse_mode="HTML")


@router.callback_query(F.data == "cf:edit_name")
async def cb_cf_edit_name(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_name)
    await _edit(cb, "🏷️ نام دلخواه جدید برای کانفیگ‌ها بفرستید:", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_name)
async def handle_panel_name(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    name = (message.text or "").strip()[:20]
    if str(uid) in store.data["panels"] and name:
        store.data["panels"][str(uid)]["name"] = name
        store.save()
    await state.clear()
    t, m = _render_personal_panel(uid)
    await message.answer(f"✅ نام ذخیره شد.\n\n{t}", parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(cb, "🔁 آدرس ProxyIP جدید بفرستید (پیشنهاد: <code>proxyip.cmliussss.net</code> یا <code>bpb.yousef.isegaro.com</code>):", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    pip = (message.text or "").strip()
    if str(uid) in store.data["panels"] and pip:
        store.data["panels"][str(uid)]["proxy_ip"] = pip
        store.save()
    await state.clear()
    t, m = _render_personal_panel(uid)
    await message.answer(f"✅ ProxyIP ذخیره شد (دکمه آپدیت Worker به V9 را بزنید تا اعمال شود).\n\n{t}", parse_mode="HTML", reply_markup=m)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await cb.answer("🗑️ پنل حذف شد.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid)))


# ==================== 3. WARP / WIREGUARD (WORKING CORE, ZERO JSON) ====================
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
    brand = store.data.get("panels", {}).get(str(uid), {}).get("name", "CFHub")
    b = build_warp_bundle(reg, ep4, ep6, platform, ip_mode=ip_mode, ping_ms=ping, brand=brand)  # type: ignore[arg-type]
    store.increment_stat(uid, "warp_generated")
    await wait.delete()

    txt = (
        f"✅ <b>کانفیگ WARP آماده شد</b>\n"
        f"🏷️ <b>{html.escape(b['label'])}</b>\n"
        f"🎯 رله: <code>{html.escape(b['endpoint'])}</code>\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"1️⃣ <b>پیشنهاد اول (Hiddify / Streisand):</b>\n"
        f"<code>{html.escape(b['warp_auto_uri'])}</code>\n\n"
        f"2️⃣ <b>لینک دولایه WoW (Hiddify / Karing):</b>\n"
        f"<code>{html.escape(b['wow_uri'])}</code>\n\n"
        f"3️⃣ <b>لینک WireGuard ({ip_mode.upper()}):</b>\n"
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
        rows.append([btn(f"⚡ دریافت ۴ کانفیگ {lbl}", callback_data=f"cf:getop:{op}", style="success")])
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
        "• توکن کلودفلر را بفرستید تا Worker واقعی شما ساخته شود.\n"
        "• داخل «🎛️ پنل من» اپراتور خود را بزنید تا ۴ کانفیگ مرتب (۲ VLESS + ۲ Trojan) بگیرید.\n"
        "• روی اینترنت‌های حساس به SNI، در تنظیمات Hiddify یا v2rayNG گزینه <b>TLS Fragment</b> را روشن کنید.\n\n"
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


# ==================== 6. CLEAN ADMIN PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    pools = store.data.get("operator_pools", {})
    users = store.data.get("users", {})
    scan_st = f"⏳ {bg_engine.current_stage}" if bg_engine.is_scanning else "🟢 آماده"
    last_s = bg_engine.last_scan_at[:16].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        "🛠️ <b>پنل مدیریت V9</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_st}</b> | آخرین اسکن: <code>{last_s}</code>\n"
        f"📶 IP اپراتورها: 🔵{len(pools.get('mci', []))} | 🟡{len(pools.get('mtn', []))} | 🟢{len(pools.get('mkh', []))}\n"
        f"🛡️ WARP تاییدشده: <b>{len(store.data.get('warp_v4_pool', []))}</b> v4 • <b>{len(store.data.get('warp_v6_pool', []))}</b> v6\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 پنل فعال: <b>{len(store.data.get('panels', {}))}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b>"
    )
    markup = kb([
        [btn("▶️ اسکن فوری اپراتورها + WARP", callback_data="adm:scan_now", style="success")],
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
    await cb.answer("🚀 اسکن شروع شد!", show_alert=True)
    await asyncio.sleep(0.4)
    t, m = _build_admin_dashboard()
    await _edit(cb, t, m)


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
    logger.info("Starting V9 Background Engine...")
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
    logger.info("Starting Cloudflare Config Hub V9 Zero-403/Zero-500 Pro Bot.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V9_EOF__

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
echo ">>> V9 Upgrade complete! Send /start -> My Panel -> Update Worker to V9."
