from __future__ import annotations

import base64
import hashlib
import json

CURRENT_WORKER_VERSION = "v24"

# Curated ProxyIP pool (ONLY used when user explicitly enables ProxyIP!)
CURATED_PROXY_IPS = [
    "proxyip.cmliussss.net",
    "proxyip.fxxk.dedyn.io",
    "proxyip.oracle.fxxk.dedyn.io",
    "proxyip.digitalocean.fxxk.dedyn.io",
    "bpb.yousef.isegaro.com",
    "cdn.xn--b6gac.eu.org",
    "proxyip.sg.fxxk.dedyn.io",
    "proxyip.us.fxxk.dedyn.io",
]

# Backward-compat alias
DEFAULT_PROXY_IPS = CURATED_PROXY_IPS

# V24 Ultra-Clean Pure-ASCII ES Module for Cloudflare Pages (`_worker.js`) & Workers (`index.js`):
#   1) DIRECT-FIRST & ZERO PUBLIC PROXY INTERFERENCE: By default (`r: []`), never hangs on dead public ProxyIPs!
#   2) INSTANT OPTIONAL PROXYIP: If client WS URL passes `?proxyip=host[:port]` (or `?relay=...`), enables clean
#      fast-failover relay ONLY for that request — zero redeploy needed when user toggles ProxyIP ON/OFF!
#   3) ZERO-RACE UPLOAD QUEUE: Eliminates early-data / concurrent write corruption (`ready` gate after initData flush).
#   4) Dual-DoH DNS (1.1.1.1 + dns.google fallback) + clean `allowHalfOpen: false` socket lifecycle.
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const EMBEDDED_B64 = '__CFG_B64__';
const WS_OPEN = 1;
const WS_CLOSING = 2;
const FIRST_BYTE_TIMEOUT_MS = 2400;

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
  return { u: '', h: '', r: [], v: 'v24' };
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
            v: cfg.v || 'v24',
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

      const rawProxy = (url.searchParams.get('proxyip') || url.searchParams.get('relay') || url.searchParams.get('r') || '').trim();
      return handleStream(request, cfg, rawProxy);
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
  remoteBox.ready = false;
  try { if (remoteBox.writer) remoteBox.writer.releaseLock(); } catch (_) {}
  remoteBox.writer = null;
  try { if (remoteBox.sock) remoteBox.sock.close(); } catch (_) {}
  remoteBox.sock = null;
}

function handleStream(request, cfg, rawProxy) {
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  const remoteBox = { sock: null, writer: null, ready: false };
  let isDns = false;
  let dnsFn = null;
  let closed = false;

  // Direct by default! Only populate relays when explicitly enabled via ?proxyip=... or baked into cfg.r
  let relayList = [];
  if (rawProxy && rawProxy !== 'off' && rawProxy !== 'none') {
    relayList = rawProxy.split(',').map((x) => x.trim()).filter(Boolean);
  }
  if (Array.isArray(cfg.r) && cfg.r.length > 0 && rawProxy !== 'off') {
    for (const x of cfg.r) {
      if (x && !relayList.includes(x)) relayList.push(x);
    }
  }

  let chain = Promise.resolve();

  function enqueue(raw) {
    chain = chain.then(async () => {
      if (closed) return;
      const u8 = toU8(raw);
      if (isDns && dnsFn) {
        await dnsFn(u8);
        return;
      }
      if (remoteBox.ready && remoteBox.writer) {
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
      readLoop(sock, remoteBox, ws, respHead, nextRetry).catch(() => safeClose(ws));
    } catch (_) {
      await tryRelay(idx + 1);
    }
  }

  try {
    const sock = await openAndSend(host, port);
    const fallback = relays.length > 0 ? () => tryRelay(0) : null;
    readLoop(sock, remoteBox, ws, respHead, fallback).catch(() => safeClose(ws));
  } catch (_) {
    if (relays.length > 0) {
      await tryRelay(0).catch(() => safeClose(ws));
    } else {
      closeRemote(remoteBox);
      safeClose(ws);
    }
  }
}

async function readLoop(sock, remoteBox, ws, respHead, onEmptyRetry) {
  let head = respHead;
  let gotData = false;
  let reader = null;
  let timer = null;

  try {
    reader = sock.readable.getReader();
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
    """
    V24: By default `proxy_ip=""` -> `r: []` (pure direct mode, ZERO public ProxyIP interference!).
    Users can enable ProxyIP per-config via WS query `?proxyip=...` at any time without redeploying.
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
