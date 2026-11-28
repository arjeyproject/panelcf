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
