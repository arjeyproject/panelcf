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
