from __future__ import annotations

import base64
import ipaddress
import re
from typing import Any

from app.core.enums import ProtocolType
from app.protocols.base import ConfigBuildOutput, ProtocolAdapter, ValidationResult

_WG_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42,43}=$")


def is_valid_wg_key(value: str) -> bool:
    if not isinstance(value, str) or not _WG_KEY_RE.match(value.strip()):
        return False
    try:
        return len(base64.b64decode(value.strip(), validate=True)) == 32
    except Exception:
        return False


class WireGuardAdapter(ProtocolAdapter):
    """
    Genuine WireGuard configuration builder and validator.
    Never fabricates server-side keys or treats Cloudflare HTTP anycast IPs as WireGuard servers.
    """

    protocol = ProtocolType.WIREGUARD

    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        errors: list[str] = []
        warnings: list[str] = []

        for key_field in ("private_key", "peer_public_key"):
            val = params.get(key_field, "")
            if not is_valid_wg_key(val):
                errors.append(f"{key_field} must be a valid 32-byte base64 Curve25519 WireGuard key.")

        endpoint = str(params.get("endpoint", "")).strip()
        if ":" not in endpoint:
            errors.append("endpoint must be in host:port or [ipv6]:port format.")

        addresses = params.get("addresses") or []
        if not addresses:
            errors.append("At least one interface CIDR address (IPv4 or IPv6) is required.")
        for cidr in addresses:
            try:
                ipaddress.ip_interface(cidr)
            except ValueError:
                errors.append(f"Invalid interface address: {cidr}")

        mtu = int(params.get("mtu", 1280))
        if not (1280 <= mtu <= 1500):
            errors.append("mtu must be between 1280 and 1500.")

        allowed_ips = params.get("allowed_ips") or ["0.0.0.0/0", "::/0"]
        for net in allowed_ips:
            try:
                ipaddress.ip_network(net, strict=False)
            except ValueError:
                errors.append(f"Invalid AllowedIPs CIDR: {net}")

        warnings.append("Ensure the endpoint corresponds to a genuine WireGuard peer holding the matching private key.")
        return ValidationResult(valid=not errors, errors=errors, warnings=warnings)

    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        val = self.validate_params(params)
        if not val.valid:
            raise ValueError("; ".join(val.errors))

        addresses = ", ".join(params["addresses"])
        dns = ", ".join(params.get("dns") or ["1.1.1.1", "1.0.0.1"])
        mtu = int(params.get("mtu", 1280))
        allowed_ips = ", ".join(params.get("allowed_ips") or ["0.0.0.0/0", "::/0"])
        keepalive = int(params.get("persistent_keepalive", 25))

        lines = [
            f"# Profile: {name}",
            "[Interface]",
            f"PrivateKey = {params['private_key'].strip()}",
            f"Address = {addresses}",
            f"DNS = {dns}",
            f"MTU = {mtu}",
            "",
            "[Peer]",
            f"PublicKey = {params['peer_public_key'].strip()}",
            f"Endpoint = {params['endpoint'].strip()}",
            f"AllowedIPs = {allowed_ips}",
            f"PersistentKeepalive = {keepalive}",
        ]
        if params.get("preshared_key"):
            lines.insert(-2, f"PresharedKey = {params['preshared_key'].strip()}")

        return ConfigBuildOutput(
            protocol=self.protocol,
            name=name,
            serialized="\n".join(lines) + "\n",
            export_extension=".conf",
            supported_clients=["WireGuard Official (iOS/Android/Windows/macOS/Linux)", "AmneziaWG", "Sing-box"],
            provenance={
                "private_key": "user_provided",
                "peer_public_key": "user_provided",
                "endpoint": params.get("endpoint_provenance", "user_provided"),
                "mtu": "generated",
            },
            warnings=val.warnings,
        )
