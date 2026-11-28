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
