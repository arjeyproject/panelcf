#!/usr/bin/env bash
set -euo pipefail

echo ">>> Upgrading Cloudflare Config Hub Bot to V5 (Real Worker Deploy + Real WireGuard Handshake Scanner + VIP Panel)..."
mkdir -p backend/app/bot data
chmod 777 data

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/worker_template.py
from __future__ import annotations

import json

# Production ES Module Cloudflare Worker for VLESS over WebSocket using `cloudflare:sockets`
# Includes:
#  - Real VLESS v0 frame parser (IPv4 / Domain / IPv6 TCP forwarding + WebSocket Early Data `sec-websocket-protocol`)
#  - Automatic ProxyIP fallback when direct Cloudflare-to-Cloudflare connect() is blocked
#  - Dynamic `/?proxyip=host:port` path override
#  - Built-in `/health` verification endpoint (used by bot after deploy to guarantee HTTP 200 LIVE)
#  - Built-in `/sub/{UUID}` live subscription endpoint delivering Base64 VLESS nodes with beautiful emoji names
WORKER_JS_TEMPLATE = r"""
import { connect } from 'cloudflare:sockets';

const USER_ID = '__UUID__';
const DEFAULT_PROXY_IP = '__PROXY_IP__';
const CLEAN_IPS = __CLEAN_IPS_JSON__;
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
            service: 'cfhub-turbo-worker',
            brand: PANEL_BRAND,
            clean_ips: CLEAN_IPS.length,
            timestamp: new Date().toISOString()
          }), {
            status: 200,
            headers: { 'content-type': 'application/json; charset=utf-8' }
          });
        }
        if (url.pathname === `/sub/${USER_ID}` || url.pathname === `/${USER_ID}`) {
          const host = request.headers.get('Host') || url.hostname;
          const subText = buildSubscription(host);
          const encoded = btoa(unescape(encodeURIComponent(subText)));
          return new Response(encoded, {
            status: 200,
            headers: {
              'content-type': 'text/plain; charset=utf-8',
              'profile-title': 'base64:' + btoa(unescape(encodeURIComponent(`⚡ ${PANEL_BRAND} VIP`))),
              'profile-update-interval': '6',
            }
          });
        }
        return new Response('Welcome to nginx!', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      // Extract optional ?proxyip= from path or query
      let proxyIP = url.searchParams.get('proxyip') || DEFAULT_PROXY_IP;
      const pathMatch = url.pathname.match(/proxyip=([^/&?#]+)/i);
      if (pathMatch && pathMatch[1]) {
        proxyIP = decodeURIComponent(pathMatch[1]);
      }

      return await handleVlessWebSocket(request, proxyIP);
    } catch (err) {
      return new Response(String(err), { status: 500 });
    }
  }
};

function buildSubscription(host) {
  const ips = CLEAN_IPS.length ? CLEAN_IPS : [{ ip: host, latency_ms: 0 }];
  const lines = [];
  for (let i = 0; i < ips.length; i++) {
    const item = ips[i];
    const ip = typeof item === 'string' ? item : item.ip;
    const ping = item.latency_ms ? `🟢${Math.round(item.latency_ms)}ms` : '⚡Auto';
    const tag = encodeURIComponent(`⚡${PANEL_BRAND} • ${ping} • 🚀Turbo-#${i + 1}`);
    const path = encodeURIComponent('/?ed=2048');
    lines.push(
      `vless://${USER_ID}@${ip}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${path}&alpn=http%2F1.1#${tag}`
    );
  }
  return lines.join('\n');
}

async function handleVlessWebSocket(request, proxyIP) {
  const wsPair = new WebSocketPair();
  const [client, server] = Object.values(wsPair);
  server.accept();

  let address = '';
  let portWithRandomLog = '';
  const earlyDataHeader = request.headers.get('sec-websocket-protocol') || '';
  const readableWS = makeReadableWebSocketStream(server, earlyDataHeader);

  let remoteSocketWrapper = { value: null };
  let isDns = false;

  readableWS.pipeTo(new WritableStream({
    async write(chunk) {
      if (isDns) return;
      if (remoteSocketWrapper.value) {
        const writer = remoteSocketWrapper.value.writable.getWriter();
        await writer.write(chunk);
        writer.releaseLock();
        return;
      }

      const parsed = parseVlessHeader(chunk, USER_ID);
      if (parsed.hasError) {
        throw new Error(parsed.message);
      }

      address = parsed.addressRemote;
      portWithRandomLog = `${parsed.portRemote}`;
      const vlessRespHeader = new Uint8Array([parsed.vlessVersion[0], 0]);
      const rawClientData = chunk.slice(parsed.rawDataIndex);

      if (parsed.isUDP) {
        if (parsed.portRemote === 53) {
          isDns = true;
          await handleDnsOverHttps(rawClientData, server, vlessRespHeader);
          return;
        }
        throw new Error('UDP only supported on port 53 (DNS)');
      }

      await handleTCPOutBound(remoteSocketWrapper, address, parsed.portRemote, rawClientData, server, vlessRespHeader, proxyIP);
    },
    close() {},
    abort() {}
  })).catch(() => {
    safeCloseWebSocket(server);
  });

  return new Response(null, { status: 101, webSocket: client });
}

async function handleTCPOutBound(remoteSocketWrapper, addressRemote, portRemote, rawClientData, webSocket, vlessRespHeader, proxyIP) {
  async function connectAndWrite(host, port) {
    const tcpSocket = connect({ hostname: host, port: port });
    remoteSocketWrapper.value = tcpSocket;
    const writer = tcpSocket.writable.getWriter();
    if (rawClientData && rawClientData.byteLength > 0) {
      await writer.write(rawClientData);
    }
    writer.releaseLock();
    return tcpSocket;
  }

  async function retryViaProxyIP() {
    if (!proxyIP) {
      safeCloseWebSocket(webSocket);
      return;
    }
    const [pHost, pPort] = proxyIP.includes(':') ? proxyIP.split(':') : [proxyIP, String(portRemote)];
    const tcpSocket = await connectAndWrite(pHost, Number(pPort) || portRemote);
    tcpSocket.closed.catch(() => {}).finally(() => safeCloseWebSocket(webSocket));
    await remoteSocketToWS(tcpSocket, webSocket, vlessRespHeader, null);
  }

  const tcpSocket = await connectAndWrite(addressRemote, portRemote);
  await remoteSocketToWS(tcpSocket, webSocket, vlessRespHeader, retryViaProxyIP);
}

async function remoteSocketToWS(remoteSocket, webSocket, vlessRespHeader, retryFn) {
  let hasIncomingData = false;
  let headerSent = false;

  await remoteSocket.readable.pipeTo(new WritableStream({
    async write(chunk) {
      hasIncomingData = true;
      if (webSocket.readyState !== WS_READY_STATE_OPEN) {
        throw new Error('WebSocket closed');
      }
      if (!headerSent) {
        headerSent = true;
        const combined = new Uint8Array(vlessRespHeader.byteLength + chunk.byteLength);
        combined.set(vlessRespHeader, 0);
        combined.set(new Uint8Array(chunk), vlessRespHeader.byteLength);
        webSocket.send(combined.buffer);
      } else {
        webSocket.send(chunk);
      }
    }
  })).catch(() => {});

  if (!hasIncomingData && retryFn) {
    await retryFn();
  } else {
    safeCloseWebSocket(webSocket);
  }
}

async function handleDnsOverHttps(rawClientData, webSocket, vlessRespHeader) {
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
    const out = new Uint8Array(vlessRespHeader.byteLength + 2 + ans.byteLength);
    out.set(vlessRespHeader, 0);
    out[vlessRespHeader.byteLength] = (ans.byteLength >> 8) & 0xff;
    out[vlessRespHeader.byteLength + 1] = ans.byteLength & 0xff;
    out.set(ans, vlessRespHeader.byteLength + 2);
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


def render_worker_script(
    user_uuid: str,
    proxy_ip: str = "proxyip.cmliussss.net",
    clean_ips: list[dict] | None = None,
    brand: str = "CFHub",
) -> str:
    safe_brand = brand.replace("'", "").replace('"', "").replace("\\", "")[:24] or "CFHub"
    safe_proxy = proxy_ip.replace("'", "").replace('"', "").strip()
    top_clean = [{"ip": x["ip"], "latency_ms": x.get("latency_ms", 0)} for x in (clean_ips or [])[:8]]
    return (
        WORKER_JS_TEMPLATE
        .replace("__UUID__", user_uuid.strip())
        .replace("__PROXY_IP__", safe_proxy)
        .replace("__CLEAN_IPS_JSON__", json.dumps(top_clean))
        .replace("__PANEL_BRAND__", safe_brand)
    )
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/wg_handshake.py
from __future__ import annotations

import asyncio
import base64
import hashlib
import os
import struct
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

# Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s constants (WireGuard Whitepaper §5.4)
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
    """
    Construct a genuine 148-byte WireGuard Type-1 Handshake Initiation packet
    with Cloudflare WARP's 3-byte `reserved` client identifier in bytes [1..3].
    """
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

    # Initial chaining key & hash
    ck = _blake2s(_CONSTRUCTION)
    h = _blake2s(ck + _IDENTIFIER)
    h = _blake2s(h + r_pub_bytes)

    # Ephemeral public key
    ck = _hmac_blake2s(_hmac_blake2s(ck, e_pub_bytes), b"\x01")
    h = _blake2s(h + e_pub_bytes)

    # DH(e_priv, r_pub) -> encrypt static public key
    dh1 = e_priv.exchange(r_pub)
    ck, k = _kdf2(ck, dh1)
    encrypted_static = _aead_encrypt(k, 0, s_pub_bytes, h)
    h = _blake2s(h + encrypted_static)

    # DH(s_priv, r_pub) -> encrypt TAI64N timestamp
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
    mac2 = b"\x00" * 16
    packet = body + mac1 + mac2
    assert len(packet) == 148
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
    """
    Sends a real WireGuard Handshake Initiation (Type 1) over UDP to a Cloudflare WARP endpoint
    and verifies a genuine Type 2 Handshake Response (92 bytes, matching receiver_index).
    Returns (handshake_verified, udp_rtt_ms).
    """
    loop = asyncio.get_running_loop()
    transport = None
    try:
        packet, sender_idx = build_wireguard_handshake_initiation(
            client_private_key_b64, peer_public_key_b64, reserved=reserved
        )
        fut = loop.create_future()
        transport, _ = await asyncio.wait_for(
            loop.create_datagram_endpoint(lambda: _WGRespProto(fut), remote_addr=(host, port)),
            timeout=timeout_sec,
        )
        start = time.perf_counter()
        transport.sendto(packet)
        resp: bytes = await asyncio.wait_for(fut, timeout=timeout_sec)
        rtt_ms = round((time.perf_counter() - start) * 1000.0, 2)
        # Valid WireGuard Handshake Response is Type 2 (byte 0 == 2) and 92 bytes long
        # Receiver index is bytes [8..12]
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
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/ui.py
from __future__ import annotations

from typing import Literal

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

ButtonStyle = Literal["primary", "success", "danger"]

# Direct Cloudflare API Token URL with ALL required permissions pre-checked
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
    "%5D&accountId=*&zoneId=all&name=CFHubTurbo"
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
        top_row = (
            [btn("🎛️ My Turbo Panel (LIVE)", callback_data="m:mypanel", style="success")]
            if has_panel
            else [btn("🚀 Deploy Live Turbo Panel", callback_data="m:turbo", style="success")]
        )
        rows = [
            top_row,
            [
                btn("⚡ Quick Config + Sub", callback_data="cf:get_one", style="success")
                if has_panel
                else btn("🎛️ My Panel", callback_data="m:mypanel", style="primary"),
                btn("💎 VIP Toolkit", callback_data="m:vip", style="primary"),
            ],
            [btn("🛡️ WARP / WireGuard / WoW (Verified)", callback_data="m:warp", style="primary")],
            [btn("📱 Recommended Apps", callback_data="m:apps", style="primary")],
            [
                btn("📖 Connection Guide", callback_data="m:guide", style="primary"),
                btn("💬 Support", callback_data="m:support", style="primary"),
            ],
            [
                btn("🔴 Free Tested Config", callback_data="m:free", style="primary"),
                btn("🎁 Invite Friends", callback_data="m:invite", style="primary"),
            ],
            [
                btn("❤️ Support Us", callback_data="m:donate", style="primary"),
                btn("🇮🇷 فارسی", callback_data="m:lang", style="primary"),
            ],
        ]
        if is_admin:
            rows.append([btn("🛠️ Admin Control Center", callback_data="adm:home", style="danger")])
        return kb(rows)

    # Persian RTL — My Panel promoted directly to Page 1 + VIP Toolkit
    if has_panel:
        rows = [
            [btn("🎛️ پنل من (فعال و زنده) — مدیریت و کانفیگ", callback_data="m:mypanel", style="success")],
            [
                btn("⚡ دریافت فوری کانفیگ", callback_data="cf:get_one", style="success"),
                btn("💎 امکانات ویژه VIP", callback_data="m:vip", style="primary"),
            ],
        ]
    else:
        rows = [
            [btn("🚀 ساخت و دیپلوی واقعی پنل توربو", callback_data="m:turbo", style="success")],
            [
                btn("🎛️ پنل من", callback_data="m:mypanel", style="primary"),
                btn("💎 امکانات ویژه VIP", callback_data="m:vip", style="primary"),
            ],
        ]

    rows.extend([
        [btn("🛡️ ساخت WARP / WireGuard / WoW (تست‌شده)", callback_data="m:warp", style="primary")],
        [btn("📱 برنامه‌ها و دانلود", callback_data="m:apps", style="primary")],
        [
            btn("📖 راهنمای اتصال", callback_data="m:guide", style="primary"),
            btn("💬 پشتیبانی", callback_data="m:support", style="primary"),
        ],
        [
            btn("🔴 کانفیگ رایگان", callback_data="m:free", style="primary"),
            btn("🎁 دعوت دوستان", callback_data="m:invite", style="primary"),
        ],
        [
            btn("❤️ حمایت از ما", callback_data="m:donate", style="primary"),
            btn("🌐 English", callback_data="m:lang", style="primary"),
        ],
    ])
    if is_admin:
        rows.append([btn("🛠️ پنل مدیریت", callback_data="adm:home", style="danger")])
    return kb(rows)


def back_home_kb(
    back_cb: str = "m:home",
    lang: str = "fa",
    extra_rows: list[list[InlineKeyboardButton]] | None = None,
) -> InlineKeyboardMarkup:
    rows = list(extra_rows) if extra_rows else []
    label = "🔙 بازگشت" if lang == "fa" else "🔙 Back"
    rows.append([btn(label, callback_data=back_cb, style="primary")])
    return kb(rows)
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/store.py
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.core.config import get_settings
from app.security.crypto import SecretVault


def _resolve_writable_store_path() -> Path:
    candidates = [
        Path(os.getenv("HUB_STATE_PATH", "/app/data/hub_state.json")),
        Path("/tmp/cfhub_data/hub_state.json"),
    ]
    for path in candidates:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            probe = path.parent / ".write_test"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            return path
        except Exception:
            continue
    return Path("/tmp/hub_state.json")


class PersistentHubStore:
    """Thread-safe persistent store with Fernet AES encryption for Cloudflare API tokens & scanner probe device."""

    def __init__(self, path: str | None = None):
        self.path = Path(path) if path else _resolve_writable_store_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        settings = get_settings()
        master = settings.encryption_master_key or settings.jwt_secret_key or "cfhub-default-fallback-key"
        self._vault = SecretVault(master)
        self.data: dict[str, Any] = self._load()

    def _default_state(self) -> dict[str, Any]:
        settings = get_settings()
        owner_id = settings.owner_telegram_ids[0] if settings.owner_telegram_ids else 0
        return {
            "users": {},
            "cf_accounts": {},
            "panels": {},
            "ip_pool": [],
            "endpoint_pool": [],
            "warp_probe_device": None,
            "custom_cidrs": [],
            "free_configs": [],
            "scan_history": [],
            "support_tickets": [],
            "settings": {
                "support_username": os.getenv("SUPPORT_USERNAME", "").lstrip("@"),
                "support_user_id": owner_id,
                "default_proxy_ip": "proxyip.cmliussss.net",
                "donate_text": "❤️ این سرویس رایگان است و رایگان می‌ماند.\nبهترین حمایت شما معرفی ربات به دوستانتان است!",
                "maintenance_mode": False,
                "auto_apply_ip": True,
                "auto_scan_enabled": True,
                "auto_scan_interval_hours": 6,
                "ip_sample_size": 48,
                "min_quality_score": 55.0,
                "scan_timeout_sec": 2.5,
                "scan_concurrency": 24,
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
                    "name_style": "luxury",
                    "is_banned": False,
                    "referrals": [],
                    "referred_by": None,
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
                u.setdefault("name_style", "luxury")
                u.setdefault("referrals", [])
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

    def record_referral(self, referrer_id: int, new_user_id: int) -> bool:
        if referrer_id == new_user_id:
            return False
        with self._lock:
            ref_u = self.data["users"].get(str(referrer_id))
            new_u = self.data["users"].get(str(new_user_id))
            if not ref_u or not new_u or new_u.get("referred_by"):
                return False
            refs = ref_u.setdefault("referrals", [])
            if new_user_id not in refs:
                refs.append(new_user_id)
                new_u["referred_by"] = referrer_id
                self.save()
                return True
            return False

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
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/warp_builder.py
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

OFFICIAL_WARP_PEER_PUBKEY = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

WARP_REG_URLS = [
    "https://api.cloudflareclient.com/v0a2483/reg",
    "https://api.cloudflareclient.com/v0a2158/reg",
]


@dataclass
class WarpRegistration:
    ok: bool
    private_key: str = ""
    public_key: str = ""
    peer_public_key: str = OFFICIAL_WARP_PEER_PUBKEY
    ipv4: str = "172.16.0.2/32"
    ipv6: str = ""
    reserved: list[int] | None = None
    client_id_b64: str = ""
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
    """Register AND explicitly activate a real Cloudflare WARP WireGuard device."""
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
                    client_id_b64=client_id_b64,
                    device_id=dev_id,
                    token=token,
                    warp_activated=warp_activated,
                )
            except Exception as exc:
                last_err = str(exc)

    return WarpRegistration(ok=False, error=f"خطا در ثبت دستگاه WARP: {last_err}")


def format_beautiful_name(
    brand: str,
    mode: str,
    ping_ms: float | None,
    platform: str = "",
    style: str = "luxury",
) -> str:
    """Create clean, eye-catching config names with ping badge & emojis for clients."""
    if ping_ms is not None and ping_ms > 0:
        p = int(round(ping_ms))
        dot = "🟢" if p < 120 else ("🟡" if p < 240 else "🟠")
        ping_tag = f"{dot}{p}ms"
    else:
        ping_tag = "⚡Auto"

    plat_icon = {"ios": "🍏iOS", "android": "🤖Android", "windows": "🪟Win"}.get(platform, "")
    parts = [f"⚡{brand}", ping_tag, mode]
    if plat_icon:
        parts.append(plat_icon)
    if style == "luxury":
        parts.append("💎VIP")
    return " • ".join(parts)


def build_verified_warp_bundle(
    reg: WarpRegistration,
    primary_ep: str,
    secondary_ep: str,
    platform: PlatformType,
    ping_ms: float | None = None,
    brand: str = "CFHub",
    name_style: str = "luxury",
) -> dict:
    """
    Generates 100% client-compliant, verified WARP configs:
      1) Clean standard `wireguard://` URI (ZERO invalid extra query params so v2rayNG/Streisand/Karing never reject it!)
      2) Hiddify `warp://` + Warp-in-Warp (WoW `&&detour=`) URI with official `ifp/ifps/ifpd/ifpm=m4` anti-DPI noise!
      3) Hiddify `warp://auto` Smart Scanner URI (automatically scans on user's own Iran ISP!)
      4) Full Xray-core WireGuard + UDP Noise JSON (importable directly into v2rayNG / v2rayN for anti-DPI!)
      5) AmneziaWG `.conf` (Jc/Jmin/Jmax + S1=0,S2=0,H1-H4=1..4 + MTU=1280 + IPv4-safe routing)
    """
    host1, port1_s = primary_ep.rsplit(":", 1)
    port1 = int(port1_s)
    host2, port2_s = secondary_ep.rsplit(":", 1)
    port2 = int(port2_s)
    mtu = 1280
    reserved = reg.reserved or [0, 0, 0]
    reserved_csv = ",".join(str(x) for x in reserved)

    wg_label = format_beautiful_name(brand, "🛡️WARP-WG", ping_ms, platform, name_style)
    wow_label = format_beautiful_name(brand, "🌀WoW-Pro", ping_ms, platform, name_style)
    auto_label = format_beautiful_name(brand, "🎯WARP-Auto", ping_ms, platform, name_style)

    # 1) STRICTLY VALID standard wireguard:// URI (works in v2rayNG, MahsaNG, Hiddify, Streisand, Karing, V2Box)
    wg_query = urlencode({
        "address": reg.ipv4,
        "reserved": reserved_csv,
        "publickey": reg.peer_public_key,
        "mtu": str(mtu),
    })
    wireguard_uri = f"wireguard://{quote(reg.private_key, safe='')}@{host1}:{port1}?{wg_query}#{quote(wg_label)}"

    # 2) Hiddify Warp-in-Warp (WoW) with official ifp/ifps/ifpd/ifpm=m4 anti-DPI packet padding
    wow_uri = (
        f"warp://{host1}:{port1}?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(wow_label)}"
        f"&&detour=warp://{host2}:{port2}?ifp=10-20&ifps=20-60&ifpd=5-10#{quote(f'🌍Exit • {brand}')}"
    )

    # 3) Hiddify Smart Auto-Scan WARP URI (scans user's exact ISP locally!)
    warp_auto_uri = f"warp://auto?ifp=10-20&ifps=20-60&ifpd=5-10&ifpm=m4#{quote(auto_label)}"

    # 4) Full Xray-core JSON with WireGuard + UDP Noise (for v2rayNG / v2rayN "Import custom config")
    xray_json = json.dumps(
        {
            "remarks": wg_label,
            "log": {"loglevel": "warning"},
            "dns": {
                "servers": ["https://1.1.1.1/dns-query", "8.8.8.8"],
                "queryStrategy": "UseIPv4",
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
                        "address": [reg.ipv4],
                        "peers": [
                            {
                                "publicKey": reg.peer_public_key,
                                "allowedIPs": ["0.0.0.0/0"],
                                "endpoint": f"{host1}:{port1}",
                                "keepAlive": 25,
                            }
                        ],
                        "reserved": reserved,
                        "mtu": mtu,
                        "noKernelTun": True,
                    },
                    "streamSettings": {
                        "sockopt": {"dialerProxy": "noise-out"}
                    },
                },
                {
                    "tag": "noise-out",
                    "protocol": "freedom",
                    "settings": {
                        "noises": [
                            {"type": "rand", "packet": "10-30", "delay": "10-25", "applyTo": "ipv4"}
                        ]
                    },
                },
                {"tag": "direct", "protocol": "freedom"},
            ],
        },
        indent=2,
        ensure_ascii=False,
    )

    # 5) AmneziaWG .conf (S1=0, S2=0, H1..H4=1..4 preserves Cloudflare WARP compatibility while adding Jc junk packets)
    amnezia_conf = "\n".join([
        f"# {wg_label}",
        "[Interface]",
        f"PrivateKey = {reg.private_key}",
        f"Address = {reg.ipv4}",
        "DNS = 1.1.1.1, 8.8.8.8",
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
        "AllowedIPs = 0.0.0.0/0",
        f"Endpoint = {host1}:{port1}",
        "PersistentKeepalive = 25",
    ]) + "\n"

    clients = {
        "ios": "Hiddify (پیشنهاد اول با لینک WoW) / Streisand / Karing / AmneziaWG",
        "android": "Hiddify (پیشنهاد اول با لینک WoW) / v2rayNG (فایل JSON) / AmneziaWG",
        "windows": "Hiddify (پیشنهاد اول) / v2rayN (فایل JSON) / AmneziaWG",
    }

    return {
        "label": wg_label,
        "wireguard_uri": wireguard_uri,
        "wow_uri": wow_uri,
        "warp_auto_uri": warp_auto_uri,
        "xray_json": xray_json,
        "xray_filename": f"cfhub_warp_noise_{platform}.json",
        "amnezia_conf": amnezia_conf,
        "amnezia_filename": f"cfhub_amneziawg_{platform}.conf",
        "reserved": reserved,
        "endpoint": f"{host1}:{port1}",
        "secondary_endpoint": f"{host2}:{port2}",
        "recommended_clients": clients[platform],
    }


def format_warp_masque(
    reg: WarpRegistration,
    endpoint: str,
    platform: PlatformType,
    ping_ms: float | None = None,
    brand: str = "CFHub",
) -> dict:
    host, _ = endpoint.rsplit(":", 1)
    masque_endpoint = f"{host}:443"
    label = format_beautiful_name(brand, "🌀MASQUE-H3", ping_ms, platform)
    profile = {
        "name": label,
        "schema": "cfhub.masque.v1",
        "platform": platform,
        "protocol": "masque-connect-udp",
        "rfc": "RFC 9298",
        "transport": "quic",
        "alpn": ["h3"],
        "endpoint": masque_endpoint,
        "sni": "consumer-masque.cloudflareclient.com",
        "device_id": reg.device_id,
        "local_address": [reg.ipv4],
        "mtu": 1280,
        "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/",
    }
    serialized = json.dumps(profile, indent=2, ensure_ascii=False)
    clients = {
        "ios": "Cloudflare WARP (حالت MASQUE در Advanced → Connection) / Hiddify 2.5+",
        "android": "Cloudflare WARP (حالت MASQUE) / Hiddify 2.5+",
        "windows": "Cloudflare WARP Desktop (warp-cli tunnel protocol set MASQUE)",
    }
    return {
        "label": label,
        "filename": f"cfhub_masque_{platform}.json",
        "file_content": serialized,
        "endpoint": masque_endpoint,
        "recommended_clients": clients[platform],
    }
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/bg_engine.py
from __future__ import annotations

import asyncio
import ipaddress
import logging
import random
from datetime import datetime, timezone
from typing import Any

from app.bot.warp_builder import OFFICIAL_WARP_PEER_PUBKEY, register_real_warp_device
from app.bot.wg_handshake import probe_real_warp_handshake
from app.ranking.ip_ranker import CandidateMetricsInput, SmartIPRanker
from app.scanners.base import BoundedAdaptiveRunner
from app.scanners.ip_scanner import IPCandidateScanner, IPScanOptions

logger = logging.getLogger(__name__)

# Official Cloudflare public Edge IPv4 ranges for VLESS/WS Clean IPs
DEFAULT_CF_CIDRS = [
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "162.159.0.0/16",
    "188.114.96.0/20",
]

# Official Cloudflare WARP WireGuard UDP prefixes + known responsive UDP ports
WARP_UDP_PREFIXES = [
    "162.159.192",
    "162.159.193",
    "162.159.195",
    "188.114.96",
    "188.114.97",
    "188.114.98",
    "188.114.99",
]
WARP_UDP_PORTS = [2408, 854, 859, 864, 878, 880, 890, 891, 894, 903, 908, 928, 934, 939, 942, 943, 945, 955, 1002, 1018, 1074, 1701, 1843, 2371, 4500]


def sample_ips_from_cidrs(cidrs: list[str], total_samples: int = 48) -> list[str]:
    networks = []
    for raw in cidrs:
        try:
            net = ipaddress.ip_network(raw.strip(), strict=False)
            if net.version == 4 and net.is_global:
                networks.append(net)
        except ValueError:
            continue
    if not networks:
        return []
    result: set[str] = set()
    per_net = max(2, total_samples // len(networks))
    for net in networks:
        num = net.num_addresses
        if num <= 4:
            for ip in net.hosts():
                result.add(str(ip))
        else:
            for _ in range(per_net * 2):
                if len(result) >= total_samples:
                    break
                offset = random.randint(1, num - 2)
                result.add(str(net.network_address + offset))
    return list(result)[:total_samples]


def generate_warp_endpoint_candidates(count: int = 32) -> list[tuple[str, int]]:
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
        pref = random.choice(WARP_UDP_PREFIXES)
        octet = random.randint(1, 250)
        port = random.choice(WARP_UDP_PORTS)
        pair = (f"{pref}.{octet}", port)
        if pair not in seen:
            seen.add(pair)
            base.append(pair)
    return base


class BackgroundScannerEngine:
    """
    Autonomous real scanner engine:
      - Phase 1: Real multi-round TCP + TLS Cloudflare Clean IP scanner.
      - Phase 2: Real WireGuard Noise_IKpsk2 UDP Handshake (Type 1 -> Type 2) WARP endpoint scanner!
    """

    def __init__(self, store):
        self.store = store
        self._ip_scanner = IPCandidateScanner()
        self._ranker = SmartIPRanker()
        self._loop_task: asyncio.Task | None = None
        self._active_runner: BoundedAdaptiveRunner | None = None
        self._scan_lock = asyncio.Lock()
        self.is_scanning: bool = False
        self.current_stage: str = "idle"
        self.progress_done: int = 0
        self.progress_total: int = 0
        self.last_scan_at: str | None = None
        self.last_error: str | None = None

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._loop_task = asyncio.create_task(self._scheduler_loop(), name="cfhub_bg_scanner_v5")

    async def stop(self) -> None:
        self.cancel_current_scan()
        if self._loop_task and not self._loop_task.done():
            self._loop_task.cancel()
            try:
                await self._loop_task
            except asyncio.CancelledError:
                pass

    def cancel_current_scan(self) -> None:
        if self._active_runner:
            self._active_runner.cancel()

    async def _ensure_probe_device(self) -> dict | None:
        dev = self.store.data.get("warp_probe_device")
        if dev and dev.get("private_key") and dev.get("peer_public_key"):
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
        await asyncio.sleep(3)
        while True:
            try:
                auto_on = bool(self.store.data["settings"].get("auto_scan_enabled", True))
                if auto_on and not self.is_scanning:
                    await self.run_full_cycle(trigger="auto")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception("Background scanner cycle error: %s", exc)
            hours = max(1, int(self.store.data["settings"].get("auto_scan_interval_hours", 6)))
            await asyncio.sleep(hours * 3600)

    async def run_full_cycle(self, trigger: str = "manual", custom_ips: list[str] | None = None) -> dict[str, Any]:
        if self._scan_lock.locked():
            return {"status": "already_running"}

        async with self._scan_lock:
            self.is_scanning = True
            self.last_error = None
            cfg = self.store.data["settings"]
            timeout_sec = float(cfg.get("scan_timeout_sec", 2.5))
            concurrency = int(cfg.get("scan_concurrency", 24))
            min_score = float(cfg.get("min_quality_score", 55.0))
            sample_size = int(cfg.get("ip_sample_size", 48))

            try:
                # --- PHASE 1: Real TCP+TLS Cloudflare Clean IP Scan ---
                self.current_stage = "ip_scan"
                cidrs = list(DEFAULT_CF_CIDRS) + list(self.store.data.get("custom_cidrs", []))
                targets = list(custom_ips) if custom_ips else sample_ips_from_cidrs(cidrs, total_samples=sample_size)
                existing_top = [x["ip"] for x in self.store.data.get("ip_pool", [])[:15]]
                targets = list(dict.fromkeys(existing_top + targets))

                self.progress_done = 0
                self.progress_total = len(targets)
                runner = BoundedAdaptiveRunner(max_concurrency=concurrency)
                self._active_runner = runner

                async def _on_prog(done: int, total: int):
                    self.progress_done = done
                    self.progress_total = total

                opts = IPScanOptions(
                    port=443,
                    timeout_sec=timeout_sec,
                    screening_attempts=1,
                    repeated_attempts=3,
                    interval_sec=0.12,
                    test_tls=True,
                    tls_sni="cloudflare.com",
                    max_concurrency=concurrency,
                    allow_private=False,
                )
                metrics_list = await self._ip_scanner.scan_candidates(targets, opts, runner=runner, on_progress=_on_prog)

                now = datetime.now(timezone.utc)
                scored_ips: list[dict[str, Any]] = []
                for m in metrics_list:
                    if m.success_count <= 0:
                        continue
                    ranked = self._ranker.score_candidate(
                        CandidateMetricsInput(
                            identifier=m.target,
                            port=m.port,
                            success_rate=m.success_rate,
                            avg_latency_ms=m.avg_latency_ms,
                            min_latency_ms=m.min_latency_ms,
                            max_latency_ms=m.max_latency_ms,
                            jitter_ms=m.jitter_ms,
                            stability_score=m.stability_score,
                            total_observations=m.total_attempts,
                            failed_observations=m.failure_count,
                            testing_diversity=2 if m.tls_verified else 1,
                            compatible_protocols=["vless", "trojan"],
                            last_tested_at=now,
                        ),
                        now=now,
                    )
                    if ranked.overall_score >= min_score:
                        scored_ips.append({
                            "ip": ranked.identifier,
                            "port": ranked.port,
                            "score": ranked.overall_score,
                            "confidence": ranked.confidence,
                            "latency_ms": ranked.avg_latency_ms,
                            "jitter_ms": ranked.jitter_ms,
                            "success_rate": ranked.success_rate,
                            "tls_ok": m.tls_verified,
                            "tested_at": now.isoformat(),
                        })

                scored_ips.sort(key=lambda x: (x["score"], -(x["latency_ms"] or 9999)), reverse=True)
                if scored_ips:
                    self.store.data["ip_pool"] = scored_ips[:100]
                    if cfg.get("auto_apply_ip", True):
                        top_clean = scored_ips[0]["ip"]
                        for panel in self.store.data.get("panels", {}).values():
                            if panel.get("auto_ip", True):
                                panel["clean_ip"] = top_clean

                # --- PHASE 2: Real WireGuard UDP Handshake (Type 1 -> Type 2) WARP Endpoint Scan ---
                self.current_stage = "warp_udp_handshake"
                probe_dev = await self._ensure_probe_device()
                ep_candidates = generate_warp_endpoint_candidates(count=36)
                self.progress_done = 0
                self.progress_total = len(ep_candidates)

                ep_results: list[dict[str, Any]] = []
                if probe_dev:
                    sem = asyncio.Semaphore(12)

                    async def _test_ep(pair: tuple[str, int]):
                        host, port = pair
                        if runner.cancel_event.is_set():
                            return None
                        async with sem:
                            rtts: list[float] = []
                            for _ in range(2):
                                ok, rtt = await probe_real_warp_handshake(
                                    host,
                                    port,
                                    probe_dev["private_key"],
                                    probe_dev["peer_public_key"],
                                    reserved=probe_dev["reserved"],
                                    timeout_sec=timeout_sec,
                                )
                                if ok and rtt is not None:
                                    rtts.append(rtt)
                                await asyncio.sleep(0.08)
                            self.progress_done += 1
                            if not rtts:
                                return None
                            avg_lat = round(sum(rtts) / len(rtts), 2)
                            sr = round(len(rtts) / 2.0, 2)
                            jitter = round(max(rtts) - min(rtts), 2) if len(rtts) > 1 else 0.0
                            score = round(max(0.0, min(100.0, sr * 68.0 + max(0.0, 32.0 - avg_lat / 10.0) - jitter * 0.25)), 2)
                            return {
                                "endpoint": f"{host}:{port}",
                                "host": host,
                                "port": port,
                                "protocol": "wireguard",
                                "handshake_verified": True,
                                "score": score,
                                "latency_ms": avg_lat,
                                "jitter_ms": jitter,
                                "success_rate": sr,
                                "tested_at": now.isoformat(),
                            }

                    gathered = await asyncio.gather(*(_test_ep(p) for p in ep_candidates))
                    ep_results = [r for r in gathered if r is not None]
                    ep_results.sort(key=lambda x: (x["score"], -(x["latency_ms"] or 9999)), reverse=True)
                    if ep_results:
                        self.store.data["endpoint_pool"] = ep_results[:50]

                self.last_scan_at = now.isoformat()
                summary = {
                    "trigger": trigger,
                    "finished_at": self.last_scan_at,
                    "ips_tested": len(targets),
                    "healthy_ips": len(self.store.data["ip_pool"]),
                    "healthy_endpoints": len(self.store.data["endpoint_pool"]),
                }
                self.store.data["scan_history"] = (self.store.data.get("scan_history", []) + [summary])[-20:]
                self.store.save()
                return summary
            finally:
                self.is_scanning = False
                self.current_stage = "idle"
                self._active_runner = None

    def get_best_ips(self, count: int = 5) -> list[dict[str, Any]]:
        return list(self.store.data.get("ip_pool", []))[:count]

    def get_best_endpoints(self, count: int = 2) -> list[dict[str, Any]]:
        return list(self.store.data.get("endpoint_pool", []))[:count]
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/cf_manager.py
from __future__ import annotations

import json
import random
import string
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote, urlencode

import httpx

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
    zones: list[str] | None = None
    error: str | None = None


class CloudflarePanelService:
    """
    Real Cloudflare API v4 Worker Deployer & Personal Turbo Panel Manager.
    ACTUALLY uploads & activates a live VLESS-over-WS ES Module Worker to the user's Cloudflare account
    and verifies `/health` HTTP 200 before delivering configs (eliminates red/dead pings!).
    """

    BASE = "https://api.cloudflare.com/client/v4"

    async def deploy_live_turbo_worker(
        self,
        api_token: str,
        user_uuid: str,
        script_name: str,
        proxy_ip: str = "proxyip.cmliussss.net",
        clean_ips: list[dict] | None = None,
        brand: str = "CFHub",
    ) -> CloudflareDeployResult:
        token = api_token.strip()
        headers = {"Authorization": f"Bearer {token}"}
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                # 1. Verify Token
                r_ver = await client.get(f"{self.BASE}/user/tokens/verify", headers=headers)
                d_ver = r_ver.json()
                if r_ver.status_code != 200 or not d_ver.get("success"):
                    err = (d_ver.get("errors") or [{"message": f"HTTP {r_ver.status_code}"}])[0].get("message")
                    return CloudflareDeployResult(ok=False, error=f"توکن نامعتبر: {err}")
                if (d_ver.get("result") or {}).get("status") != "active":
                    return CloudflareDeployResult(ok=False, error="توکن کلودفلر غیرفعال یا منقضی است.")

                # 2. Fetch Account ID
                r_acc = await client.get(f"{self.BASE}/accounts", headers=headers, params={"per_page": 5})
                d_acc = r_acc.json()
                accs = d_acc.get("result") or []
                if r_acc.status_code != 200 or not accs:
                    return CloudflareDeployResult(ok=False, error="دسترسی خواندن Account در توکن یافت نشد. لطفاً از دکمه مستقیم توکن بسازید.")
                account_id = accs[0]["id"]
                account_name = accs[0].get("name") or "Cloudflare"

                # 3. Get or auto-register workers.dev subdomain
                subdomain = None
                r_sub = await client.get(f"{self.BASE}/accounts/{account_id}/workers/subdomain", headers=headers)
                if r_sub.status_code == 200 and r_sub.json().get("success"):
                    subdomain = (r_sub.json().get("result") or {}).get("subdomain")

                if not subdomain:
                    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
                    candidate_sub = f"cfhub-{suffix}"
                    r_create_sub = await client.put(
                        f"{self.BASE}/accounts/{account_id}/workers/subdomain",
                        headers={**headers, "Content-Type": "application/json"},
                        json={"subdomain": candidate_sub},
                    )
                    if r_create_sub.status_code in (200, 201) and r_create_sub.json().get("success"):
                        subdomain = (r_create_sub.json().get("result") or {}).get("subdomain", candidate_sub)
                    else:
                        return CloudflareDeployResult(
                            ok=False,
                            error="ساب‌دامنه workers.dev در اکانت شما فعال نیست. یک‌بار در داشبورد کلودفلر وارد Workers & Pages شوید و ساب‌دامنه رایگان بسازید.",
                        )

                # 4. Upload real ES Module VLESS Worker script via multipart/form-data
                worker_code = render_worker_script(
                    user_uuid=user_uuid,
                    proxy_ip=proxy_ip,
                    clean_ips=clean_ips,
                    brand=brand,
                )
                metadata = json.dumps({
                    "main_module": "worker.js",
                    "compatibility_date": "2024-11-01",
                })
                files = {
                    "metadata": (None, metadata, "application/json"),
                    "worker.js": ("worker.js", worker_code.encode("utf-8"), "application/javascript+module"),
                }
                r_put = await client.put(
                    f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}",
                    headers=headers,
                    files=files,
                )
                d_put = r_put.json()
                if r_put.status_code not in (200, 201) or not d_put.get("success"):
                    err = (d_put.get("errors") or [{"message": f"HTTP {r_put.status_code}"}])[0].get("message")
                    return CloudflareDeployResult(ok=False, error=f"خطا در دیپلوی Worker (دسترسی Workers Scripts:Edit را چک کنید): {err}")

                # 5. Enable workers.dev public route for this Worker!
                await client.post(
                    f"{self.BASE}/accounts/{account_id}/workers/scripts/{script_name}/subdomain",
                    headers={**headers, "Content-Type": "application/json"},
                    json={"enabled": True},
                )

                # 6. Fetch Zones (optional custom domains)
                zones: list[str] = []
                r_z = await client.get(f"{self.BASE}/zones", headers=headers, params={"per_page": 10})
                if r_z.status_code == 200 and r_z.json().get("success"):
                    zones = [z["name"] for z in (r_z.json().get("result") or []) if z.get("name")]

                worker_host = f"{script_name}.{subdomain}.workers.dev"
                sub_url = f"https://{worker_host}/sub/{user_uuid}"

                # 7. Real Live Health Verification Probe!
                health_ok, latency_ms = await self.verify_worker_live(worker_host)

                return CloudflareDeployResult(
                    ok=True,
                    account_id=account_id,
                    account_name=account_name,
                    script_name=script_name,
                    worker_host=worker_host,
                    sub_url=sub_url,
                    health_verified=health_ok,
                    health_latency_ms=latency_ms,
                    zones=zones,
                )
        except Exception as exc:
            return CloudflareDeployResult(ok=False, error=f"خطا در اتصال به کلودفلر: {exc}")

    @staticmethod
    async def verify_worker_live(worker_host: str) -> tuple[bool, float | None]:
        import time
        url = f"https://{worker_host}/health"
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                t0 = time.perf_counter()
                r = await client.get(url)
                ms = round((time.perf_counter() - t0) * 1000.0, 1)
                if r.status_code == 200 and r.json().get("ok") is True:
                    return True, ms
        except Exception:
            pass
        return False, None

    @staticmethod
    def build_vless_uri(
        panel: dict[str, Any],
        override_ip: str | None = None,
        ping_ms: float | None = None,
        with_fragment: bool = False,
        label_mode: str = "🚀Turbo",
        name_style: str = "luxury",
    ) -> str:
        ip = override_ip or panel["clean_ip"]
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
            "fp": panel.get("fp", "chrome"),
            "alpn": panel.get("alpn", "http/1.1"),
        }
        if with_fragment:
            params["fragment"] = "10-100,10-20,tlshello"

        label = format_beautiful_name(
            brand=panel.get("name", "CFHub"),
            mode=label_mode,
            ping_ms=ping_ms,
            style=name_style,
        )
        return f"vless://{panel['uuid']}@{host_part}:{panel.get('port', 443)}?{urlencode(params)}#{quote(label)}"

    @staticmethod
    def build_xray_fragment_json(
        panel: dict[str, Any],
        override_ip: str | None = None,
        ping_ms: float | None = None,
        name_style: str = "luxury",
    ) -> str:
        """Full Xray-core JSON with TLS ClientHello Fragment (fixes red ping on SNI-filtered ISPs in v2rayNG/v2rayN)."""
        ip = override_ip or panel["clean_ip"]
        path = panel.get("path", "/?ed=2048")
        if panel.get("proxy_ip") and "proxyip=" not in path.lower():
            sep = "&" if "?" in path else "?"
            path = f"{path}{sep}proxyip={panel['proxy_ip']}"

        label = format_beautiful_name(panel.get("name", "CFHub"), "🧩Fragment-VIP", ping_ms, style=name_style)
        cfg = {
            "remarks": label,
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
                    "protocol": "vless",
                    "settings": {
                        "vnext": [
                            {
                                "address": ip,
                                "port": int(panel.get("port", 443)),
                                "users": [{"id": panel["uuid"], "encryption": "none"}],
                            }
                        ]
                    },
                    "streamSettings": {
                        "network": "ws",
                        "security": "tls",
                        "tlsSettings": {
                            "serverName": panel["sni"],
                            "fingerprint": panel.get("fp", "chrome"),
                            "alpn": ["http/1.1"],
                        },
                        "wsSettings": {"path": path, "headers": {"Host": panel["host"]}},
                        "sockopt": {"dialerProxy": "fragment-out", "tcpKeepAliveIdle": 100},
                    },
                },
                {
                    "tag": "fragment-out",
                    "protocol": "freedom",
                    "settings": {
                        "fragment": {
                            "packets": "tlshello",
                            "length": "10-50",
                            "interval": "10-20",
                        }
                    },
                },
                {"tag": "direct", "protocol": "freedom"},
            ],
        }
        return json.dumps(cfg, indent=2, ensure_ascii=False)
__CFHUB_V5_EOF__

cat <<'__CFHUB_V5_EOF__' > backend/app/bot/bot.py
from __future__ import annotations

import asyncio
import base64
import csv
import html
import io
import logging
import random
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
from app.bot.store import PersistentHubStore
from app.bot.ui import (
    CLOUDFLARE_DIRECT_TOKEN_URL,
    CLOUDFLARE_SIGNUP_URL,
    back_home_kb,
    btn,
    kb,
    main_menu_kb,
)
from app.bot.warp_builder import (
    build_verified_warp_bundle,
    format_warp_masque,
    register_real_warp_device,
)
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
    waiting_panel_custom_host = State()
    waiting_support_msg = State()
    adm_add_cidr = State()
    adm_custom_scan = State()
    adm_user_search = State()
    adm_dm_text = State()
    adm_broadcast = State()
    adm_set_support = State()
    adm_add_free_cfg = State()


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
    lang = store.get_lang(tg_id)
    ip_pool = store.data.get("ip_pool", [])
    ep_pool = store.data.get("endpoint_pool", [])
    cfg = store.data["settings"]
    panel = store.data.get("panels", {}).get(str(tg_id))

    best_ip_ping = f"{ip_pool[0]['latency_ms']}ms" if ip_pool and ip_pool[0].get("latency_ms") else "در حال اسکن..."
    best_wg_ping = f"{ep_pool[0]['latency_ms']}ms" if ep_pool and ep_pool[0].get("latency_ms") else "در حال تست UDP..."
    scan_badge = f"🔄 اسکن ({bg_engine.current_stage})" if bg_engine.is_scanning else "🟢 آنلاین"

    if panel:
        p_live = "🟢 LIVE و فعال" if panel.get("worker_deployed") else "🟡 آماده دیپلوی"
        my_panel_block = (
            f"\n🎛️ <b>پنل اختصاصی شما:</b> <code>{html.escape(panel['host'])}</code> ({p_live})\n"
            f"🟢 IP تمیز فعال: <code>{html.escape(panel['clean_ip'])}</code>\n"
        )
    else:
        my_panel_block = "\n🎛️ <b>پنل اختصاصی شما:</b> ⚪ هنوز ساخته نشده (با دکمه سبز زیر در ۳۰ ثانیه دیپلوی کنید)\n"

    if lang == "en":
        return (
            "⚡ <b>Cloudflare Config Hub V5 — Live Status</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            f"🏆 Best Clean IP: <b>{best_ip_ping}</b> ({len(ip_pool)} verified)\n"
            f"🛡️ WARP Handshake Relays: <b>{len(ep_pool)}</b> (Best UDP: <b>{best_wg_ping}</b>)\n"
            f"🤖 Auto-Heal IP: <b>{'ON' if cfg.get('auto_apply_ip', True) else 'OFF'}</b> | Engine: <b>{scan_badge}</b>"
            f"{my_panel_block}"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "💚 Free forever. Choose an action below:"
        )

    return (
        "⚡ <b>وضعیت زنده این لحظه (نسخه V5 حرفه‌ای)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🏆 بهترین پینگ IP تمیز: <b>{best_ip_ping}</b> (<b>{len(ip_pool)}</b> تاییدشده)\n"
        f"🛡️ رلهٔ WARP واقعی (UDP Handshake): <b>{len(ep_pool)}</b> (پینگ: <b>{best_wg_ping}</b>)\n"
        f"🤖 خودترمیم آی‌پی: <b>{'روشن' if cfg.get('auto_apply_ip', True) else 'خاموش'}</b> | موتور: <b>{scan_badge}</b>"
        f"{my_panel_block}"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "💚 رایگان است و رایگان می‌ماند. از دکمه‌های زیر شروع کن:"
    )


# ==================== START, HOME & LANGUAGE ====================
@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    user = message.from_user
    if not user:
        return
    store.touch_user(user.id, user.username, user.full_name)
    parts = (message.text or "").split()
    if len(parts) > 1 and parts[1].startswith("ref_"):
        ref_s = parts[1].removeprefix("ref_")
        if ref_s.isdigit():
            store.record_referral(int(ref_s), user.id)

    if store.is_banned(user.id) and not _is_admin(user.id):
        await message.answer("🚫 دسترسی شما مسدود شده است.")
        return
    if store.data["settings"].get("maintenance_mode") and not _is_admin(user.id):
        await message.answer("🛠️ ربات موقتاً در حال به‌روزرسانی است.")
        return

    await message.answer(
        _home_text(user.id),
        reply_markup=main_menu_kb(_is_admin(user.id), _has_panel(user.id), store.get_lang(user.id)),
        parse_mode="HTML",
    )


@router.message(Command("admin"))
async def cmd_admin(message: Message, state: FSMContext) -> None:
    await state.clear()
    if not message.from_user or not _is_admin(message.from_user.id):
        await message.answer("⛔ این بخش فقط مخصوص مدیریت ربات است.")
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


# ==================== 1. REAL TURBO PANEL DEPLOYER (1-CLICK CF API TOKEN -> REAL LIVE WORKER) ====================
@router.callback_query(F.data == "m:turbo")
async def cb_turbo(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    uid = cb.from_user.id
    if store.is_banned(uid) and not _is_admin(uid):
        await cb.answer("🚫 حساب شما مسدود است.", show_alert=True)
        return

    await state.set_state(Flow.waiting_cf_token)
    text = (
        "🚀 <b>ساخت و دیپلوی واقعی پنل توربو روی کلودفلر</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ اگر اکانت کلادفلر نداری، اول ثبت نام کن.\n"
        "2️⃣ دکمهٔ سبز <b>دریافت مستقیم توکن</b> را بزن (تمام دسترسی‌ها از قبل انتخاب شده).\n"
        "3️⃣ در صفحه کلادفلر فقط <b>Continue to summary</b> و بعد <b>Create Token</b> را بزن.\n"
        "4️⃣ توکن را کپی کن و <b>همینجا بفرست</b>.\n\n"
        "🔥 <b>چه اتفاقی می‌افتد؟</b>\n"
        "ربات به‌صورت <b>کاملاً واقعی و خودکار</b> یک اسکریپت VLESS WebSocket + لینک سابسکریپشن اختصاصی روی Cloudflare Workers شما دیپلوی می‌کند، سلامت HTTP 200 آن را زنده تست می‌گیرد و کانفیگ‌های سبز و آماده را تحویل می‌دهد!\n"
        "🔐 <i>پیام توکن بلافاصله برای امنیت از چت پاک می‌شود.</i>"
    )
    rows = [
        [btn("🔑 دریافت مستقیم توکن (دسترسی‌ها آماده)", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
        [btn("🌐 ثبت‌نام رایگان کلادفلر", url=CLOUDFLARE_SIGNUP_URL, style="primary")],
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
            "⚠️ فرمت توکن نامعتبر است. از دکمه سبز زیر توکن را بسازید و بدون فاصله اینجا بفرستید:",
            reply_markup=kb([
                [btn("🔑 دریافت مستقیم توکن", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    wait_msg = await message.answer(
        "⏳ <b>در حال دیپلوی واقعی Worker اختصاصی روی اکانت کلودفلر شما...</b>\n"
        "1️⃣ اعتبارسنجی توکن\n2️⃣ آپلود کد VLESS WebSocket روی Workers\n3️⃣ فعال‌سازی دامنه workers.dev و تست زنده /health",
        parse_mode="HTML",
    )

    existing_panel = store.data["panels"].get(str(uid)) or {}
    panel_uuid = existing_panel.get("uuid") or str(uuid.uuid4())
    script_name = existing_panel.get("script_name") or f"cfhub-{''.join(random.choices(string.ascii_lowercase + string.digits, k=6))}"
    brand = existing_panel.get("name") or "CFHub"
    proxy_ip = existing_panel.get("proxy_ip") or store.data["settings"].get("default_proxy_ip", "proxyip.cmliussss.net")
    best_ips = bg_engine.get_best_ips(8)

    dep = await cf_service.deploy_live_turbo_worker(
        api_token=raw_token,
        user_uuid=panel_uuid,
        script_name=script_name,
        proxy_ip=proxy_ip,
        clean_ips=best_ips,
        brand=brand,
    )
    if not dep.ok:
        await wait_msg.edit_text(
            f"❌ <b>دیپلوی ناموفق بود!</b>\nدلیل: <code>{html.escape(dep.error or 'Unknown error')}</code>\n\n"
            "لطفاً با دکمه سبز زیر توکن جدید با دسترسی کامل بسازید و مجدد بفرستید:",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔑 ساخت توکن مستقیم", url=CLOUDFLARE_DIRECT_TOKEN_URL, style="success")],
                [btn("❌ انصراف", callback_data="m:home", style="danger")],
            ]),
        )
        return

    now = datetime.now(timezone.utc).isoformat()
    store.data["cf_accounts"][str(uid)] = {
        "encrypted_token": store.encrypt_secret(raw_token),
        "account_id": dep.account_id,
        "account_name": dep.account_name,
        "zones": dep.zones or [],
        "connected_at": now,
    }
    clean_ip = best_ips[0]["ip"] if best_ips else "104.16.132.229"
    store.data["panels"][str(uid)] = {
        "name": brand,
        "uuid": panel_uuid,
        "script_name": dep.script_name,
        "host": dep.worker_host,
        "sni": dep.worker_host,
        "sub_url": dep.sub_url,
        "clean_ip": clean_ip,
        "proxy_ip": proxy_ip,
        "port": 443,
        "path": "/?ed=2048",
        "fp": "chrome",
        "alpn": "http/1.1",
        "auto_ip": True,
        "ip_index": 0,
        "worker_deployed": True,
        "health_verified": dep.health_verified,
        "health_latency_ms": dep.health_latency_ms,
        "created_at": existing_panel.get("created_at", now),
        "updated_at": now,
    }
    store.save()
    await state.clear()

    health_str = f"🟢 تایید شد ({dep.health_latency_ms}ms)" if dep.health_verified else "🟡 در حال انتشار DNS (۳۰ ثانیه صبر کنید)"
    text, markup = _render_personal_panel(uid)
    await wait_msg.edit_text(
        f"🎉 <b>پنل توربو شما به‌صورت واقعی روی کلودفلر دیپلوی شد!</b>\n"
        f"🩺 تست زنده Worker: <b>{health_str}</b>\n\n{text}",
        parse_mode="HTML",
        reply_markup=markup,
    )


# ==================== 2. MY PANEL (PROMOTED TO HOME SCREEN) ====================
def _render_personal_panel(uid: int) -> tuple[str, object]:
    panel = store.data["panels"].get(str(uid))
    if not panel:
        text = (
            "🎛️ <b>پنل اختصاصی من</b>\n"
            "━━━━━━━━━━━━━━━━━━━━\n"
            "هنوز پنل توربو روی کلودفلر نساخته‌اید!\n"
            "با یک کلیک روی دکمه سبز زیر، ربات یک Worker واقعی VLESS + لینک سابسکریپشن روی اکانت کلودفلر شما دیپلوی می‌کند:"
        )
        return text, kb([
            [btn("🚀 ساخت و دیپلوی واقعی پنل توربو", callback_data="m:turbo", style="success")],
            [btn("🔙 منوی اصلی", callback_data="m:home", style="primary")],
        ])

    best_ips = bg_engine.get_best_ips(5)
    best_ping = f"{best_ips[0]['latency_ms']}ms" if best_ips and best_ips[0].get("latency_ms") else "تست‌نشده"
    live_badge = "🟢 LIVE (دیپلوی‌شده)" if panel.get("worker_deployed") else "🔴 دیپلوی‌نشده"
    auto_badge = "🟢 روشن" if panel.get("auto_ip", True) else "🔴 خاموش"

    text = (
        "🎛️ <b>پنل اختصاصی توربو من</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"📡 وضعیت سرور Worker: <b>{live_badge}</b>\n"
        f"🏷️ نام نمایشی کانفیگ: <b>{html.escape(panel['name'])}</b>\n"
        f"🌐 دامنه Worker: <code>{html.escape(panel['host'])}</code>\n"
        f"🟢 IP تمیز فعال: <code>{html.escape(panel['clean_ip'])}</code> (بهترین استخر: {best_ping})\n"
        f"🔁 ProxyIP کمکی: <code>{html.escape(panel.get('proxy_ip', '-'))}</code>\n"
        f"🌀 خودترمیم IP: <b>{auto_badge}</b>\n"
        f"🔗 لینک سابسکریپشن زنده:\n<code>{html.escape(panel.get('sub_url', ''))}</code>\n"
        "━━━━━━━━━━━━━━━━━━━━"
    )
    markup = kb([
        [btn("⚡ دریافت کانفیگ پرسرعت + QR", callback_data="cf:get_one", style="success")],
        [
            btn("🧩 کانفیگ Fragment ضد فیلتر", callback_data="cf:get_frag", style="success"),
            btn("📦 پکیج ۵ آی‌پی برتر", callback_data="cf:get_bundle", style="primary"),
        ],
        [
            btn("🔄 تعویض فوری IP تمیز", callback_data="cf:swap_ip", style="primary"),
            btn("🩺 تست سلامت زنده Worker", callback_data="cf:health_check", style="primary"),
        ],
        [
            btn("🏷️ تغییر نام زیبا", callback_data="cf:edit_name", style="primary"),
            btn("🔁 تغییر ProxyIP", callback_data="cf:edit_proxyip", style="primary"),
        ],
        [
            btn("♻️ آپدیت و Re-Deploy Worker", callback_data="cf:redeploy", style="success"),
            btn("🌀 خودترمیم IP", callback_data="cf:toggle_autoip", style="primary"),
        ],
        [btn("🗑️ حذف پنل و قطع اتصال", callback_data="cf:disconnect", style="danger")],
        [btn("🔙 بازگشت به صفحه اول", callback_data="m:home", style="primary")],
    ])
    return text, markup


@router.callback_query(F.data == "m:mypanel")
async def cb_mypanel(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    text, markup = _render_personal_panel(cb.from_user.id)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:get_one")
async def cb_cf_get_one(cb: CallbackQuery) -> None:
    await cb.answer("⚡ ساخت کانفیگ...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        await _edit(cb, "⚠️ ابتدا پنل توربو بسازید.", back_home_kb("m:turbo"))
        return

    best_ips = bg_engine.get_best_ips(1)
    ping_ms = None
    if best_ips:
        if panel.get("auto_ip", True):
            panel["clean_ip"] = best_ips[0]["ip"]
            store.save()
        ping_ms = best_ips[0].get("latency_ms")

    style = store.data.get("users", {}).get(str(uid), {}).get("name_style", "luxury")
    uri_std = cf_service.build_vless_uri(panel, ping_ms=ping_ms, with_fragment=False, label_mode="🚀Turbo-WS", name_style=style)
    uri_frag = cf_service.build_vless_uri(panel, ping_ms=ping_ms, with_fragment=True, label_mode="🧩Frag-VIP", name_style=style)
    store.increment_stat(uid, "configs_generated")

    caption = (
        f"🚀 <b>کانفیگ پرسرعت زنده آماده شد!</b>\n"
        f"🟢 IP تمیز: <code>{html.escape(panel['clean_ip'])}</code>"
        + (f" (<b>{ping_ms}ms</b>)" if ping_ms else "")
        + f"\n\n1️⃣ <b>کانفیگ استاندارد (v2rayNG / Hiddify / Streisand):</b>\n<code>{html.escape(uri_std)}</code>\n\n"
        f"2️⃣ <b>کانفیگ Fragment ضد اختلال (Hiddify / Streisand):</b>\n<code>{html.escape(uri_frag)}</code>\n\n"
        f"🔗 <b>لینک سابسکریپشن خودکار (به‌روزرسانی خودکار):</b>\n<code>{html.escape(panel.get('sub_url', ''))}</code>"
    )
    if cb.message:
        await _send_qr(cb.message, uri_std, caption, kb([
            [btn("🧩 دریافت فایل JSON فرگمنت (مخصوص v2rayNG)", callback_data="cf:get_frag", style="success")],
            [btn("🔄 تعویض IP تمیز", callback_data="cf:swap_ip", style="primary")],
            [btn("🎛️ بازگشت به پنل من", callback_data="m:mypanel", style="primary")],
        ]))


@router.callback_query(F.data == "cf:get_frag")
async def cb_cf_get_frag(cb: CallbackQuery) -> None:
    await cb.answer("🧩 در حال ساخت JSON ضد فیلتر...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    best_ips = bg_engine.get_best_ips(1)
    ping_ms = best_ips[0].get("latency_ms") if best_ips else None
    style = store.data.get("users", {}).get(str(uid), {}).get("name_style", "luxury")
    frag_json = cf_service.build_xray_fragment_json(panel, ping_ms=ping_ms, name_style=style)
    store.increment_stat(uid, "configs_generated")

    await cb.message.answer_document(
        document=BufferedInputFile(frag_json.encode("utf-8"), filename=f"{panel['name']}_Fragment_VIP.json"),
        caption=(
            "🧩 <b>فایل کانفیگ Xray Fragment VIP (ضد فیلتر SNI)</b>\n"
            "• در <b>v2rayNG</b>: دکمه + → <i>Import custom config from local</i>\n"
            "• در <b>Hiddify</b>: ایمپورت مستقیم فایل یا QR\n"
            "• قطعه قطعه کردن ClientHello (`tlshello` 10-50 byte) باعث سبز شدن پینگ روی اینترنت‌های فیلترشده می‌شود."
        ),
        parse_mode="HTML",
        reply_markup=back_home_kb("m:mypanel"),
    )


@router.callback_query(F.data == "cf:get_bundle")
async def cb_cf_get_bundle(cb: CallbackQuery) -> None:
    await cb.answer("📦 ساخت پکیج...")
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel or not cb.message:
        return
    best_ips = bg_engine.get_best_ips(5)
    style = store.data.get("users", {}).get(str(uid), {}).get("name_style", "luxury")
    items = best_ips if best_ips else [{"ip": panel["clean_ip"], "latency_ms": None}]
    uris = [
        cf_service.build_vless_uri(
            panel,
            override_ip=it["ip"],
            ping_ms=it.get("latency_ms"),
            label_mode=f"🚀Turbo-#{i+1}",
            name_style=style,
        )
        for i, it in enumerate(items)
    ]
    store.increment_stat(uid, "configs_generated")
    await cb.message.answer_document(
        document=BufferedInputFile("\n".join(uris).encode("utf-8"), filename=f"{panel['name']}_Top5_VIP.txt"),
        caption=f"📦 <b>پکیج {len(uris)} کانفیگ با نام‌گذاری زیبا و برترین IPهای سالم</b>",
        parse_mode="HTML",
        reply_markup=back_home_kb("m:mypanel"),
    )


@router.callback_query(F.data == "cf:health_check")
async def cb_cf_health_check(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if not panel:
        return
    await cb.answer("🩺 در حال تست زنده Worker...")
    ok, ms = await cf_service.verify_worker_live(panel["host"])
    panel["health_verified"] = ok
    panel["health_latency_ms"] = ms
    store.save()
    if ok:
        await cb.message.answer(
            f"🟢 <b>Worker شما کاملاً زنده و سالم است!</b>\n🌐 آدرس: <code>{html.escape(panel['host'])}</code>\n⚡ پاسخ سرور: <b>{ms}ms (HTTP 200)</b>",
            parse_mode="HTML",
        )
    else:
        await cb.message.answer(
            f"🔴 <b>Worker پاسخ نداد!</b>\nاحتمالاً Worker حذف شده یا هنوز دیپلوی نشده است. روی دکمه <b>♻️ آپدیت و Re-Deploy Worker</b> در پنل من بزنید.",
            parse_mode="HTML",
        )


@router.callback_query(F.data == "cf:redeploy")
async def cb_cf_redeploy(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    cf = store.data["cf_accounts"].get(str(uid))
    panel = store.data["panels"].get(str(uid))
    if not cf or not panel:
        await cb.answer("⚠️ اکانت کلودفلر یافت نشد.", show_alert=True)
        return
    await cb.answer("♻️ در حال Re-Deploy با جدیدترین IPها...")
    try:
        token = store.decrypt_secret(cf["encrypted_token"])
    except Exception:
        await cb.answer("❌ توکن قابل رمزگشایی نیست؛ مجدد متصل شوید.", show_alert=True)
        return
    dep = await cf_service.deploy_live_turbo_worker(
        api_token=token,
        user_uuid=panel["uuid"],
        script_name=panel.get("script_name", f"cfhub-{uid % 9999}"),
        proxy_ip=panel.get("proxy_ip", "proxyip.cmliussss.net"),
        clean_ips=bg_engine.get_best_ips(8),
        brand=panel.get("name", "CFHub"),
    )
    if dep.ok:
        panel["host"] = dep.worker_host
        panel["sni"] = dep.worker_host
        panel["sub_url"] = dep.sub_url
        panel["worker_deployed"] = True
        panel["health_verified"] = dep.health_verified
        panel["health_latency_ms"] = dep.health_latency_ms
        store.save()
        text, markup = _render_personal_panel(uid)
        await _edit(cb, f"✅ <b>Worker با جدیدترین IPها و ProxyIP مجدداً دیپلوی شد!</b>\n\n{text}", markup)
    else:
        await cb.message.answer(f"❌ خطا در Re-Deploy: <code>{html.escape(dep.error or '')}</code>", parse_mode="HTML")


@router.callback_query(F.data == "cf:swap_ip")
async def cb_cf_swap_ip(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    pool = store.data.get("ip_pool", [])
    if not panel or not pool:
        await cb.answer("⏳ استخر IP در حال تکمیل است.", show_alert=True)
        return
    nxt = (int(panel.get("ip_index", 0)) + 1) % min(len(pool), 25)
    chosen = pool[nxt]
    panel["ip_index"] = nxt
    panel["clean_ip"] = chosen["ip"]
    store.save()
    await cb.answer(f"✅ IP تغییر کرد: {chosen['ip']} ({chosen['latency_ms']}ms)")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:toggle_autoip")
async def cb_cf_toggle_autoip(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    panel = store.data["panels"].get(str(uid))
    if panel:
        panel["auto_ip"] = not bool(panel.get("auto_ip", True))
        store.save()
    await cb.answer("✅ تغییر یافت.")
    text, markup = _render_personal_panel(uid)
    await _edit(cb, text, markup)


@router.callback_query(F.data == "cf:edit_name")
async def cb_cf_edit_name(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_name)
    await _edit(cb, "🏷️ نام برند اختصاصی برای نمایش داخل کلاینت (مثال: <code>CyberMux</code>) را بفرستید:", kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]))


@router.message(Flow.waiting_panel_name)
async def handle_panel_name(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    name = (message.text or "").strip()[:24]
    panel = store.data["panels"].get(str(uid))
    if panel and name:
        panel["name"] = name
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ نام نمایشی به <b>{html.escape(name)}</b> تغییر یافت.\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:edit_proxyip")
async def cb_cf_edit_proxyip(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_panel_proxyip)
    await _edit(
        cb,
        "🔁 <b>تغییر ProxyIP کمکی</b>\n\nیک ProxyIP معتبر بفرستید (پیشنهادها: <code>proxyip.cmliussss.net</code> یا <code>proxyip.fxxk.dedyn.io</code>):",
        kb([[btn("❌ انصراف", callback_data="m:mypanel", style="danger")]]),
    )


@router.message(Flow.waiting_panel_proxyip)
async def handle_panel_proxyip(message: Message, state: FSMContext) -> None:
    uid = message.from_user.id
    pip = (message.text or "").strip()
    panel = store.data["panels"].get(str(uid))
    if panel and pip:
        panel["proxy_ip"] = pip
        store.save()
    await state.clear()
    text, markup = _render_personal_panel(uid)
    await message.answer(f"✅ ProxyIP به <code>{html.escape(pip)}</code> تغییر یافت.\n(برای اعمال روی لینک Sub دکمه Re-Deploy را بزنید)\n\n{text}", parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "cf:disconnect")
async def cb_cf_disconnect(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    store.data["cf_accounts"].pop(str(uid), None)
    store.data["panels"].pop(str(uid), None)
    store.save()
    await cb.answer("🗑️ پنل و توکن حذف شدند.", show_alert=True)
    await _edit(cb, _home_text(uid), main_menu_kb(_is_admin(uid), False, store.get_lang(uid)))


# ==================== 3. VIP TOOLKIT (SPECIAL PRO FEATURES) ====================
@router.callback_query(F.data == "m:vip")
async def cb_vip(cb: CallbackQuery) -> None:
    await cb.answer()
    uid = cb.from_user.id
    u = store.data.get("users", {}).get(str(uid), {})
    cur_style = u.get("name_style", "luxury")
    style_fa = "💎 لوکس (ایموجی + پینگ + VIP)" if cur_style == "luxury" else "✨ مینیمال (پینگ + نام)"
    text = (
        "💎 <b>بخش امکانات ویژه VIP (رایگان برای همه)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🎨 سبک نام‌گذاری کانفیگ شما: <b>{style_fa}</b>\n\n"
        "• <b>🌀 Warp-on-Warp (WoW) دولایه:</b> اتصال دو مرحله‌ای ضد فیلتر برای Hiddify و Streisand\n"
        "• <b>🧩 Xray Fragment VIP:</b> عبور از فیلتر SNI در v2rayNG و v2rayN\n"
        "• <b>🏆 لیست زنده ۵ IP برتر اسکن‌شده:</b> کپی سریع برای هر کلاینت\n"
        "• <b>🎨 شخصی‌سازی سبک نام‌گذاری ایموجی:</b> نمایش پینگ و ایموجی زیبا در اپلیکیشن"
    )
    markup = kb([
        [btn("🌀 دریافت فوری Warp-in-Warp (WoW) دولایه", callback_data="warp:build:wg:android", style="success")],
        [btn("🧩 دریافت کانفیگ Fragment ضد فیلتر", callback_data="cf:get_frag", style="success")],
        [
            btn("🏆 لیست زنده ۵ IP تمیز برتر", callback_data="vip:top_ips", style="primary"),
            btn("🎨 تغییر سبک نام‌گذاری", callback_data="vip:tog_style", style="primary"),
        ],
        [btn("🩺 تست سلامت زنده پنل من", callback_data="cf:health_check", style="primary")],
        [btn("🔙 بازگشت به صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data == "vip:tog_style")
async def cb_vip_tog_style(cb: CallbackQuery) -> None:
    uid = cb.from_user.id
    u = store.data["users"].setdefault(str(uid), {"telegram_id": uid, "name_style": "luxury"})
    u["name_style"] = "minimal" if u.get("name_style", "luxury") == "luxury" else "luxury"
    store.save()
    await cb.answer("🎨 سبک نام‌گذاری تغییر کرد!")
    await cb_vip(cb)


@router.callback_query(F.data == "vip:top_ips")
async def cb_vip_top_ips(cb: CallbackQuery) -> None:
    await cb.answer()
    top = bg_engine.get_best_ips(10)
    if top:
        lines = [
            f"{i+1}. <code>{x['ip']}</code> | 🟢 <b>{x['latency_ms']}ms</b> | ⭐ {x['score']} | پایداری {int(x['success_rate']*100)}%"
            for i, x in enumerate(top)
        ]
        body = "\n".join(lines)
    else:
        body = "⏳ موتور اسکن در حال تست اولین دور IPها است؛ ۱ دقیقه دیگر بررسی کنید."
    await _edit(cb, f"🏆 <b>برترین IPهای تمیز تاییدشده این لحظه</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", back_home_kb("m:vip"))


# ==================== 4. WARP / WIREGUARD / WoW / MASQUE (VERIFIED UDP HANDSHAKE!) ====================
@router.callback_query(F.data == "m:warp")
async def cb_warp_menu(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    eps = bg_engine.get_best_endpoints(2)
    ep1_txt = f"<code>{eps[0]['endpoint']}</code> (🟢 <b>{eps[0]['latency_ms']}ms</b> — Handshake تاییدشده ✅)" if eps else "<code>162.159.192.1:2408</code> (در حال تکمیل اسکن UDP)"

    text = (
        "🛡️ <b>ساخت WARP / WireGuard / WoW (تست واقعی UDP Handshake)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"🎯 برترین رله تاییدشده:\n{ep1_txt}\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "🔥 <b>ارتقای بزرگ V5:</b>\n"
        "• ربات با پکت واقعی <b>WireGuard Noise_IKpsk2</b> از رله‌ها تست UDP Handshake می‌گیرد.\n"
        "• تحویل هم‌زمان: <b>لینک WoW دولایه (Hiddify)</b> + <b>لینک استاندارد wireguard://</b> + <b>فایل Xray Noise JSON (مخصوص v2rayNG)</b> + <b>فایل AmneziaWG</b> با نام‌گذاری زیبا!"
    )
    markup = kb([
        [btn("⚡ WireGuard / WoW / AmneziaWG (پیشنهادی)", callback_data="warp:proto:wg", style="success")],
        [btn("🌀 MASQUE (پروتکل جدید HTTP/3 QUIC)", callback_data="warp:proto:masque", style="primary")],
        [btn("🔙 بازگشت به صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:proto:"))
async def cb_warp_platform(cb: CallbackQuery) -> None:
    await cb.answer()
    proto = cb.data.split(":")[2]
    title = "⚡ WARP / WireGuard / WoW ضد فیلتر" if proto == "wg" else "🌀 MASQUE (HTTP/3 QUIC)"
    text = f"<b>{title}</b>\n━━━━━━━━━━━━━━━━━━━━\nسیستم‌عامل دستگاه خود را انتخاب کنید:"
    markup = kb([
        [btn("🍏 آیفون (iOS)", callback_data=f"warp:build:{proto}:ios", style="primary")],
        [btn("🤖 اندروید (Android)", callback_data=f"warp:build:{proto}:android", style="success")],
        [btn("🪟 ویندوز (Windows)", callback_data=f"warp:build:{proto}:windows", style="primary")],
        [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
    ])
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("warp:build:"))
async def cb_warp_build(cb: CallbackQuery) -> None:
    _, _, proto, platform = cb.data.split(":")
    await cb.answer("⏳ ثبت کلید واقعی WARP...")
    uid = cb.from_user.id
    if not cb.message:
        return

    wait = await cb.message.answer("⏳ در حال ساخت کلید X25519، ثبت و فعال‌سازی دستگاه واقعی روی Cloudflare WARP...")
    reg = await register_real_warp_device()
    if not reg.ok:
        await wait.edit_text(
            f"❌ <b>خطا در ارتباط با API کلودفلر WARP:</b>\n<code>{html.escape(reg.error or '')}</code>",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 تلاش مجدد", callback_data=cb.data, style="success")],
                [btn("🔙 بازگشت", callback_data="m:warp", style="primary")],
            ]),
        )
        return

    eps = bg_engine.get_best_endpoints(2)
    ep1 = eps[0]["endpoint"] if len(eps) >= 1 else "162.159.192.1:2408"
    ep2 = eps[1]["endpoint"] if len(eps) >= 2 else "188.114.97.1:1074"
    ping_ms = eps[0].get("latency_ms") if eps else None

    u = store.data.get("users", {}).get(str(uid), {})
    panel = store.data.get("panels", {}).get(str(uid), {})
    brand = panel.get("name", "CFHub")
    style = u.get("name_style", "luxury")
    store.increment_stat(uid, "warp_generated")

    await wait.delete()

    if proto == "wg":
        b = build_verified_warp_bundle(reg, ep1, ep2, platform, ping_ms=ping_ms, brand=brand, name_style=style)  # type: ignore[arg-type]
        msg_txt = (
            f"✅ <b>پکیج کامل WARP تست‌شده آماده شد!</b>\n"
            f"🏷️ نام: <b>{html.escape(b['label'])}</b>\n"
            f"🎯 رله اصلی: <code>{html.escape(b['endpoint'])}</code> | رله دوم (WoW): <code>{html.escape(b['secondary_endpoint'])}</code>\n"
            f"🔑 Reserved: <code>{b['reserved']}</code> | MTU: <code>1280</code>\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"1️⃣ <b>پیشنهاد اول برای Hiddify / Streisand (اسکن خودکار روی اینترنت خودتان — بالاترین شانس سبز شدن پینگ):</b>\n"
            f"<code>{html.escape(b['warp_auto_uri'])}</code>\n\n"
            f"2️⃣ <b>لینک Warp-in-Warp (WoW) دولایه ضد فیلتر (Hiddify / Karing):</b>\n"
            f"<code>{html.escape(b['wow_uri'])}</code>\n\n"
            f"3️⃣ <b>لینک استاندارد wireguard:// (v2rayNG / MahsaNG / Streisand):</b>\n"
            f"<code>{html.escape(b['wireguard_uri'])}</code>"
        )
        await cb.message.answer(msg_txt, parse_mode="HTML")

        # File 1: Xray-core JSON with UDP Noise (best for v2rayNG / v2rayN!)
        await cb.message.answer_document(
            document=BufferedInputFile(b["xray_json"].encode("utf-8"), filename=b["xray_filename"]),
            caption="🔥 <b>فایل Xray WireGuard + Noise JSON (مخصوص v2rayNG / v2rayN)</b>\nدر v2rayNG با گزینه <i>Import custom config from local</i> وارد کنید.",
            parse_mode="HTML",
        )
        # File 2: AmneziaWG .conf
        await cb.message.answer_document(
            document=BufferedInputFile(b["amnezia_conf"].encode("utf-8"), filename=b["amnezia_filename"]),
            caption=f"🛡️ <b>فایل AmneziaWG ضد DPI</b>\n📲 {html.escape(b['recommended_clients'])}",
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 ساخت کلید جدید", callback_data=cb.data, style="success")],
                [btn("📱 دانلود Hiddify و AmneziaWG", callback_data="m:apps", style="primary")],
                [btn("🔙 بازگشت به صفحه اول", callback_data="m:home", style="primary")],
            ]),
        )
    else:
        m = format_warp_masque(reg, ep1, platform, ping_ms=ping_ms, brand=brand)  # type: ignore[arg-type]
        await cb.message.answer_document(
            document=BufferedInputFile(m["file_content"].encode("utf-8"), filename=m["filename"]),
            caption=(
                f"✅ <b>پروفایل MASQUE (HTTP/3 QUIC)</b>\n"
                f"🏷️ نام: <b>{html.escape(m['label'])}</b>\n"
                f"🎯 اندپوینت: <code>{html.escape(m['endpoint'])}</code>\n"
                f"📲 {html.escape(m['recommended_clients'])}"
            ),
            parse_mode="HTML",
            reply_markup=kb([
                [btn("🔄 پروفایل جدید", callback_data=cb.data, style="success")],
                [btn("🔙 بازگشت", callback_data="m:home", style="primary")],
            ]),
        )


# ==================== 5. APPS, GUIDE, SUPPORT, FREE, INVITE, DONATE ====================
@router.callback_query(F.data == "m:apps")
async def cb_apps(cb: CallbackQuery) -> None:
    await cb.answer()
    markup = kb([
        [btn("🔥 Hiddify (پیشنهاد اول برای WARP WoW و Fragment)", url="https://github.com/hiddify/hiddify-app/releases/latest", style="success")],
        [btn("🛡️ AmneziaWG (ضد فیلتر WireGuard)", url="https://github.com/amnezia-vpn/amneziawg-android/releases/latest", style="primary")],
        [btn("🤖 v2rayNG (اندروید)", url="https://github.com/2dust/v2rayNG/releases/latest", style="primary")],
        [btn("🍏 Streisand (آیفون — App Store)", url="https://apps.apple.com/app/streisand/id6450534064", style="primary")],
        [btn("🪟 v2rayN (ویندوز)", url="https://github.com/2dust/v2rayN/releases/latest", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ])
    await _edit(cb, "📱 <b>بهترین اپلیکیشن‌ها برای پینگ سبز و اتصال پایدار:</b>", markup)


@router.callback_query(F.data == "m:guide")
async def cb_guide(cb: CallbackQuery) -> None:
    await cb.answer()
    text = (
        "📖 <b>راهنمای اتصال تضمینی (رفع پینگ قرمز)</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        "1️⃣ <b>پنل توربو (Cloudflare Worker واقعی):</b>\n"
        "• با دکمه سبز «🚀 ساخت و دیپلوی واقعی پنل توربو» توکن را بفرستید تا Worker واقعی روی اکانت شما آپلود شود.\n"
        "• اگر روی اینترنت شما پینگ استاندارد قرمز بود، از دکمه <b>🧩 کانفیگ Fragment ضد فیلتر</b> در پنل من استفاده کنید.\n\n"
        "2️⃣ <b>وارپ (WARP / WoW):</b>\n"
        "• بهترین روش در ایران: اپلیکیشن <b>Hiddify</b> را نصب کرده و لینک <code>warp://auto...</code> یا <code>WoW</code> را کپی و اضافه کنید.\n"
        "• در <b>v2rayNG</b>: فایل <code>.json</code> فرستاده‌شده (دارای Noise) را با <i>Import custom config</i> وارد کنید."
    )
    await _edit(cb, text, back_home_kb("m:home"))


@router.callback_query(F.data == "m:support")
async def cb_support(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await cb.answer()
    cfg = store.data["settings"]
    sup_user = cfg.get("support_username", "").lstrip("@")
    sup_id = cfg.get("support_user_id") or (get_settings().owner_telegram_ids[0] if get_settings().owner_telegram_ids else 0)
    rows = []
    if sup_user:
        rows.append([btn(f"💬 چت مستقیم (@{sup_user})", url=f"https://t.me/{sup_user}", style="success")])
        line = f"👤 آیدی پشتیبانی: @{html.escape(sup_user)}"
    elif sup_id:
        rows.append([btn("💬 چت مستقیم با مدیریت", url=f"tg://user?id={sup_id}", style="success")])
        line = f"👤 شناسه پشتیبانی: <code>{sup_id}</code>"
    else:
        line = "👤 پشتیبانی آنلاین فعال است."
    rows.append([btn("✉️ ارسال تیکت داخل ربات", callback_data="sup:ticket", style="primary")])
    rows.append([btn("🔙 صفحه اول", callback_data="m:home", style="primary")])
    await _edit(cb, f"💬 <b>پشتیبانی رسمی</b>\n━━━━━━━━━━━━━━━━━━━━\n{line}", kb(rows))


@router.callback_query(F.data == "sup:ticket")
async def cb_sup_ticket(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.answer()
    await state.set_state(Flow.waiting_support_msg)
    await _edit(cb, "✉️ پیام خود را بنویسید:", kb([[btn("❌ انصراف", callback_data="m:support", style="danger")]]))


@router.message(Flow.waiting_support_msg)
async def handle_support_msg(message: Message, state: FSMContext) -> None:
    user = message.from_user
    if not user:
        return
    tno = len(store.data.get("support_tickets", [])) + 1
    store.data["support_tickets"].append({"id": tno, "user_id": user.id, "text": message.text or "", "at": datetime.now(timezone.utc).isoformat()})
    store.save()
    await state.clear()
    for owner_id in get_settings().owner_telegram_ids:
        try:
            await message.bot.send_message(
                owner_id,
                f"📩 <b>تیکت #{tno}</b> از <a href='tg://user?id={user.id}'>{html.escape(user.full_name)}</a> (<code>{user.id}</code>):\n{html.escape(message.text or '')}",
                parse_mode="HTML",
            )
        except Exception:
            pass
    await message.answer(f"✅ تیکت <b>#{tno}</b> ارسال شد.", parse_mode="HTML", reply_markup=back_home_kb("m:home"))


@router.callback_query(F.data == "m:free")
async def cb_free(cb: CallbackQuery) -> None:
    await cb.answer()
    free_list = store.data.get("free_configs", [])
    if free_list:
        body = "\n\n".join(f"🔹 <code>{html.escape(c)}</code>" for c in free_list[-5:])
        text = f"🔴 <b>کانفیگ‌های رایگان ({len(free_list)})</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}"
    else:
        text = "🔴 <b>کانفیگ رایگان اختصاصی</b>\nبهترین سرعت رایگان را با ساخت WARP تست‌شده یا دیپلوی رایگان پنل توربو دریافت کنید:"
    await _edit(cb, text, kb([
        [btn("🛡️ ساخت فوری WARP تست‌شده", callback_data="m:warp", style="success")],
        [btn("🚀 دیپلوی پنل توربو رایگان", callback_data="m:turbo", style="primary")],
        [btn("🔙 صفحه اول", callback_data="m:home", style="primary")],
    ]))


@router.callback_query(F.data == "m:invite")
async def cb_invite(cb: CallbackQuery) -> None:
    await cb.answer()
    uid = cb.from_user.id
    me = await cb.bot.get_me()
    link = f"https://t.me/{me.username}?start=ref_{uid}"
    refs = len(store.data.get("users", {}).get(str(uid), {}).get("referrals", []))
    await _edit(cb, f"🎁 <b>دعوت دوستان</b>\n━━━━━━━━━━━━━━━━━━━━\n👥 دعوت‌های شما: <b>{refs}</b>\n\nلینک شما:\n<code>{link}</code>", back_home_kb("m:home"))


@router.callback_query(F.data == "m:donate")
async def cb_donate(cb: CallbackQuery) -> None:
    await cb.answer()
    await _edit(cb, f"❤️ <b>حمایت از ما</b>\n━━━━━━━━━━━━━━━━━━━━\n{html.escape(store.data['settings'].get('donate_text', ''))}", back_home_kb("m:home"))


# ==================== 6. PRO ADMIN & USER MANAGEMENT PANEL ====================
def _build_admin_dashboard() -> tuple[str, object]:
    sys_h = collect_system_health()
    cfg = store.data["settings"]
    users = store.data.get("users", {})
    ip_cnt = len(store.data.get("ip_pool", []))
    ep_cnt = len(store.data.get("endpoint_pool", []))
    deployed_cnt = sum(1 for p in store.data.get("panels", {}).values() if p.get("worker_deployed"))
    scan_status = f"⏳ {bg_engine.current_stage} ({bg_engine.progress_done}/{bg_engine.progress_total})" if bg_engine.is_scanning else "🟢 آماده"
    last_scan = bg_engine.last_scan_at[:19].replace("T", " ") if bg_engine.last_scan_at else "در انتظار"

    text = (
        "🛠️ <b>پنل مدیریت حرفه‌ای V5</b>\n"
        "━━━━━━━━━━━━━━━━━━━━\n"
        f"⚙️ اسکنر: <b>{scan_status}</b> | آخرین اسکن: <code>{last_scan}</code>\n"
        f"🟢 IP سالم: <b>{ip_cnt}</b> | 🛡️ رله UDP Handshake سالم: <b>{ep_cnt}</b>\n"
        f"👥 کاربران: <b>{len(users)}</b> | 🚀 Worker دیپلوی‌شده: <b>{deployed_cnt}</b>\n"
        f"💻 سرور: CPU <b>{sys_h['cpu_percent']}%</b> | RAM <b>{sys_h['memory_percent']}%</b> | Disk <b>{sys_h['disk_percent']}%</b>\n"
        "━━━━━━━━━━━━━━━━━━━━"
    )
    scan_btn = btn("⛔ توقف اسکن", callback_data="adm:scan_stop", style="danger") if bg_engine.is_scanning else btn("▶️ شروع اسکن فوری IP + WARP UDP", callback_data="adm:scan_now", style="success")
    markup = kb([
        [scan_btn],
        [
            btn("👥 مدیریت کامل کاربران", callback_data="adm:users:0", style="primary"),
            btn("🔎 جستجوی کاربر", callback_data="adm:user_search", style="primary"),
        ],
        [
            btn("🌐 مدیریت IPهای سالم", callback_data="adm:ips", style="primary"),
            btn("🛡️ رله‌های WARP تاییدشده", callback_data="adm:eps", style="primary"),
        ],
        [
            btn("🧪 اسکن IP دلخواه", callback_data="adm:custom_scan", style="primary"),
            btn("➕ افزودن رنج CIDR", callback_data="adm:add_cidr", style="success"),
        ],
        [
            btn("🔴 کانفیگ رایگان", callback_data="adm:free_cfg", style="primary"),
            btn("📢 ارسال همگانی", callback_data="adm:broadcast", style="success"),
        ],
        [
            btn("⚙️ تنظیمات سیستم", callback_data="adm:settings", style="primary"),
            btn("🔄 رفرش زنده", callback_data="adm:home", style="primary"),
        ],
        [btn("🔙 منوی کاربر", callback_data="m:home", style="danger")],
    ])
    return text, markup


@router.callback_query(F.data == "adm:home")
async def cb_adm_home(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        await cb.answer("⛔ دسترسی غیرمجاز!", show_alert=True)
        return
    await state.clear()
    await cb.answer()
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:users:"))
async def cb_adm_users_page(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    page = int(cb.data.split(":")[2])
    per_page = 6
    all_users = sorted(store.data.get("users", {}).values(), key=lambda x: x.get("last_seen", ""), reverse=True)
    chunk = all_users[page * per_page : (page + 1) * per_page]
    rows = []
    for u in chunk:
        uid = u["telegram_id"]
        badge = "🚫" if u.get("is_banned") else ("🚀" if _has_panel(uid) else "👤")
        uname = f"@{u['username']}" if u.get("username") else (u.get("full_name") or str(uid))
        rows.append([btn(f"{badge} {uname[:20]} | {uid}", callback_data=f"adm:uview:{uid}", style="primary")])
    nav = []
    if page > 0:
        nav.append(btn("⬅️ قبلی", callback_data=f"adm:users:{page - 1}", style="primary"))
    if (page + 1) * per_page < len(all_users):
        nav.append(btn("بعدی ➡️", callback_data=f"adm:users:{page + 1}", style="primary"))
    if nav:
        rows.append(nav)
    rows.append([btn("🔎 جستجوی کاربر", callback_data="adm:user_search", style="success")])
    rows.append([btn("🔙 پنل مدیریت", callback_data="adm:home", style="danger")])
    await _edit(cb, f"👥 <b>مدیریت کاربران (صفحه {page + 1} | کل: {len(all_users)})</b>", kb(rows))


def _render_admin_user_profile(target_uid: int) -> tuple[str, object]:
    u = store.data.get("users", {}).get(str(target_uid))
    if not u:
        return "❌ کاربر یافت نشد.", back_home_kb("adm:users:0")
    panel = store.data.get("panels", {}).get(str(target_uid))
    text = (
        f"👤 <b>پروفایل کاربر</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 آیدی: <code>{target_uid}</code> | نام: <b>{html.escape(u.get('full_name') or '-')}</b>\n"
        f"🔗 یوزرنیم: @{html.escape(u.get('username') or 'ندارد')}\n"
        f"🚦 وضعیت: <b>{'🚫 مسدود' if u.get('is_banned') else '🟢 فعال'}</b>\n"
        f"🚀 Worker: <code>{html.escape(panel['host']) if panel else 'ندارد'}</code>\n"
        f"📊 تولید: <b>{u.get('configs_generated', 0)}</b> پنل | <b>{u.get('warp_generated', 0)}</b> WARP | دعوت: <b>{len(u.get('referrals', []))}</b>"
    )
    ban_btn = btn("✅ رفع مسدودی", callback_data=f"adm:uban:{target_uid}", style="success") if u.get("is_banned") else btn("🚫 مسدود کردن", callback_data=f"adm:uban:{target_uid}", style="danger")
    rows = [[ban_btn], [btn("✉️ پیام مستقیم به کاربر", callback_data=f"adm:udm:{target_uid}", style="primary")]]
    if panel:
        rows.append([btn("🗑️ حذف پنل و توکن کاربر", callback_data=f"adm:ureset:{target_uid}", style="danger")])
    rows.append([btn("🔙 لیست کاربران", callback_data="adm:users:0", style="primary")])
    return text, kb(rows)


@router.callback_query(F.data.startswith("adm:uview:"))
async def cb_adm_uview(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    text, markup = _render_admin_user_profile(int(cb.data.split(":")[2]))
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:uban:"))
async def cb_adm_uban(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    target = int(cb.data.split(":")[2])
    if _is_admin(target):
        await cb.answer("⚠️ غیرمجاز", show_alert=True)
        return
    store.set_ban(target, not store.is_banned(target))
    await cb.answer("✅ انجام شد.", show_alert=True)
    text, markup = _render_admin_user_profile(target)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:ureset:"))
async def cb_adm_ureset(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    target = int(cb.data.split(":")[2])
    store.data["cf_accounts"].pop(str(target), None)
    store.data["panels"].pop(str(target), None)
    store.save()
    await cb.answer("🗑️ پاک شد.", show_alert=True)
    text, markup = _render_admin_user_profile(target)
    await _edit(cb, text, markup)


@router.callback_query(F.data.startswith("adm:udm:"))
async def cb_adm_udm(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    target = int(cb.data.split(":")[2])
    await state.update_data(dm_target=target)
    await state.set_state(Flow.adm_dm_text)
    await _edit(cb, f"✉️ پیام برای <code>{target}</code> را بنویسید:", kb([[btn("❌ انصراف", callback_data=f"adm:uview:{target}", style="danger")]]))


@router.message(Flow.adm_dm_text)
async def handle_adm_dm(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    target = int((await state.get_data()).get("dm_target", 0))
    await state.clear()
    try:
        await message.bot.send_message(target, f"📩 <b>پیام مدیریت:</b>\n\n{html.escape(message.text or '')}", parse_mode="HTML")
        await message.answer("✅ ارسال شد.", reply_markup=back_home_kb(f"adm:uview:{target}"))
    except Exception as exc:
        await message.answer(f"❌ خطا: {exc}", reply_markup=back_home_kb(f"adm:uview:{target}"))


@router.callback_query(F.data == "adm:user_search")
async def cb_adm_user_search(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_user_search)
    await _edit(cb, "🔎 آیدی عددی یا <code>@username</code> را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_user_search)
async def handle_adm_user_search(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    u = store.find_user(message.text or "")
    await state.clear()
    if not u:
        await message.answer("❌ یافت نشد.", reply_markup=back_home_kb("adm:users:0"))
        return
    text, markup = _render_admin_user_profile(int(u["telegram_id"]))
    await message.answer(text, parse_mode="HTML", reply_markup=markup)


@router.callback_query(F.data == "adm:scan_now")
async def cb_adm_scan_now(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    if bg_engine.is_scanning:
        await cb.answer("⏳ اسکن در حال اجراست.", show_alert=True)
        return
    asyncio.create_task(bg_engine.run_full_cycle(trigger="admin_manual"))
    await cb.answer("🚀 اسکن واقعی IP و WireGuard UDP Handshake شروع شد!", show_alert=True)
    await asyncio.sleep(0.4)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:scan_stop")
async def cb_adm_scan_stop(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    bg_engine.cancel_current_scan()
    await cb.answer("⛔ توقف اسکن ارسال شد.", show_alert=True)
    text, markup = _build_admin_dashboard()
    await _edit(cb, text, markup)


@router.callback_query(F.data == "adm:ips")
async def cb_adm_ips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    pool = store.data.get("ip_pool", [])
    body = "\n".join(f"{i+1}. <code>{x['ip']}</code> | ⭐<b>{x['score']}</b> | 🟢{x['latency_ms']}ms | {int(x['success_rate']*100)}%" for i, x in enumerate(pool[:15])) or "استخر خالی است."
    await _edit(cb, f"🌐 <b>استخر IP سالم ({len(pool)})</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", kb([
        [btn("📥 خروجی TXT", callback_data="adm:exp_txt", style="success"), btn("📥 خروجی CSV", callback_data="adm:exp_csv", style="primary")],
        [btn("🗑️ پاک‌سازی", callback_data="adm:purge_ips", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data.in_({"adm:exp_txt", "adm:exp_csv"}))
async def cb_adm_exp(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id) or not cb.message:
        return
    await cb.answer()
    pool = store.data.get("ip_pool", [])
    if not pool:
        return
    if cb.data == "adm:exp_txt":
        raw, fname = "\n".join(f"{x['ip']}:{x['port']}" for x in pool).encode(), "healthy_ips.txt"
    else:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["ip", "port", "score", "latency_ms", "jitter_ms", "success_rate"])
        for x in pool:
            w.writerow([x["ip"], x["port"], x["score"], x["latency_ms"], x["jitter_ms"], x["success_rate"]])
        raw, fname = buf.getvalue().encode(), "healthy_ips.csv"
    await cb.message.answer_document(BufferedInputFile(raw, filename=fname))


@router.callback_query(F.data == "adm:purge_ips")
async def cb_adm_purge_ips(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["ip_pool"] = []
    store.save()
    await cb.answer("🗑️ پاک شد.", show_alert=True)
    await cb_adm_ips(cb)


@router.callback_query(F.data == "adm:eps")
async def cb_adm_eps(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    eps = store.data.get("endpoint_pool", [])
    body = "\n".join(f"{i+1}. <code>{e['endpoint']}</code> | 🟢<b>{e['latency_ms']}ms</b> | Handshake ✅" for i, e in enumerate(eps[:15])) or "هنوز رله تاییدشده‌ای نیست."
    await _edit(cb, f"🛡️ <b>رله‌های WARP تاییدشده با UDP Handshake ({len(eps)})</b>\n━━━━━━━━━━━━━━━━━━━━\n{body}", back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:add_cidr")
async def cb_adm_add_cidr(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_add_cidr)
    await _edit(cb, "➕ رنج IPv4 (مثال: <code>104.21.0.0/16</code>) بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_add_cidr)
async def handle_adm_add_cidr(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    import ipaddress
    try:
        net = ipaddress.ip_network((message.text or "").strip(), strict=False)
        if not net.is_global:
            raise ValueError("Private CIDR blocked")
    except Exception as exc:
        await message.answer(f"❌ نامعتبر: {exc}")
        return
    if str(net) not in store.data["custom_cidrs"]:
        store.data["custom_cidrs"].append(str(net))
        store.save()
    await state.clear()
    await message.answer(f"✅ رنج <code>{net}</code> اضافه شد.", parse_mode="HTML", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:custom_scan")
async def cb_adm_custom_scan(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_custom_scan)
    await _edit(cb, "🧪 لیست IPهای عمومی را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_custom_scan)
async def handle_adm_custom_scan(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    ips = [x.strip() for x in (message.text or "").replace(",", " ").split() if x.strip()][:100]
    await state.clear()
    if not ips:
        return
    wait = await message.answer(f"⏳ در حال اسکن {len(ips)} IP...")
    summary = await bg_engine.run_full_cycle(trigger="admin_custom", custom_ips=ips)
    await wait.edit_text(f"✅ تمام شد! تست‌شده: <b>{summary.get('ips_tested', 0)}</b> | سالم: <b>{summary.get('healthy_ips', 0)}</b>", parse_mode="HTML", reply_markup=back_home_kb("adm:ips"))


@router.callback_query(F.data == "adm:free_cfg")
async def cb_adm_free_cfg(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cnt = len(store.data.get("free_configs", []))
    await _edit(cb, f"🔴 <b>کانفیگ‌های رایگان ({cnt})</b>", kb([
        [btn("➕ افزودن کانفیگ", callback_data="adm:add_free_p", style="success")],
        [btn("🗑️ پاک‌سازی", callback_data="adm:clear_free", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:add_free_p")
async def cb_adm_add_free_p(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_add_free_cfg)
    await _edit(cb, "➕ لینک کانفیگ را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:free_cfg", style="danger")]]))


@router.message(Flow.adm_add_free_cfg)
async def handle_adm_add_free(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    val = (message.text or "").strip()
    if val:
        store.data.setdefault("free_configs", []).append(val)
        store.save()
    await state.clear()
    await message.answer("✅ اضافه شد.", reply_markup=back_home_kb("adm:free_cfg"))


@router.callback_query(F.data == "adm:clear_free")
async def cb_adm_clear_free(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["free_configs"] = []
    store.save()
    await cb.answer("🗑️ پاک شد.", show_alert=True)
    await cb_adm_free_cfg(cb)


@router.callback_query(F.data == "adm:broadcast")
async def cb_adm_broadcast(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_broadcast)
    await _edit(cb, f"📢 متن پیام برای {len(store.data.get('users', {}))} کاربر را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:home", style="danger")]]))


@router.message(Flow.adm_broadcast)
async def handle_adm_broadcast(message: Message, state: FSMContext) -> None:
    if not _is_admin(message.from_user.id):
        return
    text = message.text or ""
    await state.clear()
    sent, failed = 0, 0
    for uid_str in list(store.data.get("users", {}).keys()):
        try:
            await message.bot.send_message(int(uid_str), f"📢 <b>اطلاعیه:</b>\n\n{html.escape(text)}", parse_mode="HTML")
            sent += 1
            await asyncio.sleep(0.05)
        except Exception:
            failed += 1
    await message.answer(f"✅ ارسال تمام شد.\nموفق: <b>{sent}</b> | ناموفق: <b>{failed}</b>", parse_mode="HTML", reply_markup=back_home_kb("adm:home"))


@router.callback_query(F.data == "adm:settings")
async def cb_adm_settings(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    cfg = store.data["settings"]
    sup = f"@{cfg['support_username']}" if cfg.get("support_username") else f"ID:{cfg.get('support_user_id')}"
    text = (
        "⚙️ <b>تنظیمات سیستم</b>\n━━━━━━━━━━━━━━━━━━━━\n"
        f"💬 پشتیبانی: <b>{html.escape(str(sup))}</b>\n"
        f"🤖 خودترمیم IP: <b>{'🟢' if cfg.get('auto_apply_ip', True) else '🔴'}</b> | اسکن خودکار: <b>{'🟢' if cfg.get('auto_scan_enabled', True) else '🔴'}</b> (هر {cfg.get('auto_scan_interval_hours', 6)}h)\n"
        f"🛠️ تعمیرات: <b>{'🔴 روشن' if cfg.get('maintenance_mode') else '🟢 خاموش'}</b>"
    )
    await _edit(cb, text, kb([
        [btn("💬 تغییر آیدی پشتیبانی", callback_data="adm:set_sup", style="success")],
        [btn("🤖 خودترمیم IP", callback_data="adm:tog_autoip", style="primary"), btn("⏱️ بازه اسکن", callback_data="adm:cycle_int", style="primary")],
        [btn("🔄 اسکن خودکار", callback_data="adm:tog_autoscan", style="primary"), btn("🛠️ حالت تعمیرات", callback_data="adm:tog_maint", style="danger")],
        [btn("🔙 پنل مدیریت", callback_data="adm:home", style="primary")],
    ]))


@router.callback_query(F.data == "adm:tog_autoip")
async def cb_adm_tog_autoip(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    store.data["settings"]["auto_apply_ip"] = not bool(store.data["settings"].get("auto_apply_ip", True))
    store.save()
    await cb.answer("✅ انجام شد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:tog_autoscan")
async def cb_adm_tog_autoscan(cb: CallbackQuery) -> None:
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


@router.callback_query(F.data == "adm:cycle_int")
async def cb_adm_cycle_int(cb: CallbackQuery) -> None:
    if not _is_admin(cb.from_user.id):
        return
    opts = [3, 6, 12, 24]
    cur = int(store.data["settings"].get("auto_scan_interval_hours", 6))
    store.data["settings"]["auto_scan_interval_hours"] = opts[(opts.index(cur) + 1) % len(opts)] if cur in opts else 6
    store.save()
    await cb.answer("✅ بازه تغییر کرد.")
    await cb_adm_settings(cb)


@router.callback_query(F.data == "adm:set_sup")
async def cb_adm_set_sup(cb: CallbackQuery, state: FSMContext) -> None:
    if not _is_admin(cb.from_user.id):
        return
    await cb.answer()
    await state.set_state(Flow.adm_set_support)
    await _edit(cb, "💬 یوزرنیم پشتیبانی (مثال: <code>@YourID</code>) را بفرستید:", kb([[btn("❌ انصراف", callback_data="adm:settings", style="danger")]]))


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
    logger.info("Starting V5 BackgroundScannerEngine (Clean IP + Real WireGuard UDP Handshake)...")
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
    logger.info("Starting Cloudflare Config Hub V5 Pro Bot.")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(run_polling())
__CFHUB_V5_EOF__

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
echo ">>> V5 Upgrade complete! Send /start to your Telegram bot."
