from __future__ import annotations

import ipaddress
import socket
from urllib.parse import urlparse

BLOCKED_NETWORKS = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),      # CGNAT
    ipaddress.ip_network("127.0.0.0/8"),        # Loopback
    ipaddress.ip_network("169.254.0.0/16"),     # Link-local / Cloud Metadata
    ipaddress.ip_network("172.16.0.0/12"),      # RFC1918
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("192.168.0.0/16"),     # RFC1918
    ipaddress.ip_network("224.0.0.0/4"),        # Multicast
    ipaddress.ip_network("240.0.0.0/4"),        # Reserved
    ipaddress.ip_network("::/128"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),           # ULA
    ipaddress.ip_network("fe80::/10"),          # Link-local
    ipaddress.ip_network("ff00::/8"),           # Multicast
]


class TargetPolicyError(ValueError):
    pass


def validate_ip_target(
    ip_str: str,
    allow_private: bool = False,
    allowed_cidrs: list[str] | None = None,
) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
    try:
        ip_obj = ipaddress.ip_address(ip_str.strip())
    except ValueError as exc:
        raise TargetPolicyError(f"Malformed IP address: {ip_str!r}") from exc

    if not allow_private:
        for net in BLOCKED_NETWORKS:
            if ip_obj.version == net.version and ip_obj in net:
                raise TargetPolicyError(f"Target IP {ip_obj} is in a restricted/private network ({net}).")
        if not ip_obj.is_global:
            raise TargetPolicyError(f"Target IP {ip_obj} is not a globally routable address.")

    if allowed_cidrs:
        networks = [ipaddress.ip_network(c, strict=False) for c in allowed_cidrs]
        if not any(ip_obj.version == n.version and ip_obj in n for n in networks):
            raise TargetPolicyError(f"Target IP {ip_obj} is outside the configured authorized scan scope.")

    return ip_obj


def parse_and_validate_endpoint(
    raw_endpoint: str,
    allow_private: bool = False,
    allowed_cidrs: list[str] | None = None,
    resolve_dns: bool = False,
) -> tuple[str, int, str]:
    """
    Validate an endpoint string (host:port, [ipv6]:port, or https://host:port) against SSRF rules.
    Returns (host, port, scheme).
    """
    value = raw_endpoint.strip()
    if not value:
        raise TargetPolicyError("Empty endpoint.")

    if "://" in value:
        parsed = urlparse(value)
        scheme = parsed.scheme.lower()
        if scheme not in {"http", "https", "tcp", "tls", "udp", "quic", "masque"}:
            raise TargetPolicyError(f"Unsupported endpoint scheme: {scheme}")
        host = parsed.hostname
        port = parsed.port or (443 if scheme in {"https", "tls", "quic", "masque"} else 80)
    else:
        scheme = "tcp"
        parsed = urlparse(f"tcp://{value}")
        host = parsed.hostname
        port = parsed.port

    if not host or not port or not (1 <= port <= 65535):
        raise TargetPolicyError(f"Invalid host or port in endpoint: {raw_endpoint!r}")

    if host.lower() in {"localhost", "metadata.google.internal", "169.254.169.254"}:
        raise TargetPolicyError(f"Blocked internal hostname: {host}")

    # Check if host is a literal IP
    try:
        validate_ip_target(host, allow_private=allow_private, allowed_cidrs=allowed_cidrs)
    except TargetPolicyError as exc:
        if "Malformed IP" not in str(exc):
            raise
        # Hostname validation & DNS rebinding defense
        if len(host) > 253 or ".." in host or host.startswith("-") or host.endswith("-"):
            raise TargetPolicyError(f"Invalid hostname syntax: {host}")
        if resolve_dns:
            try:
                infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            except socket.gaierror as gerr:
                raise TargetPolicyError(f"DNS resolution failed for {host}") from gerr
            for info in infos:
                resolved_ip = info[4][0]
                validate_ip_target(resolved_ip, allow_private=allow_private, allowed_cidrs=allowed_cidrs)

    return host, int(port), scheme
