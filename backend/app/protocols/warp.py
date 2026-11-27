from __future__ import annotations

import json
from typing import Any

from app.core.enums import ProtocolType
from app.protocols.base import ConfigBuildOutput, ProtocolAdapter, ValidationResult
from app.protocols.wireguard import is_valid_wg_key


class CloudflareWARPAdapter(ProtocolAdapter):
    """
    Documented Cloudflare WARP profile workflow.
    Strictly separates official WARP device credentials & WARP endpoints from Cloudflare HTTP anycast IPs.
    """

    protocol = ProtocolType.WARP
    OFFICIAL_WARP_ENDPOINT_DEFAULT = "engage.cloudflareclient.com:2408"

    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        errors: list[str] = []
        warnings: list[str] = []

        if not params.get("device_private_key") or not is_valid_wg_key(params["device_private_key"]):
            errors.append("Valid device_private_key from a registered WARP device is required.")
        if not params.get("peer_public_key") or not is_valid_wg_key(params["peer_public_key"]):
            errors.append("Valid Cloudflare WARP peer_public_key from device registration is required.")
        if not params.get("interface_ipv4"):
            errors.append("Registered WARP interface_ipv4 (e.g. 172.16.0.2/32) is required.")
        endpoint = params.get("endpoint", self.OFFICIAL_WARP_ENDPOINT_DEFAULT)
        if ":" not in str(endpoint):
            errors.append("WARP endpoint must be host:port (e.g. engage.cloudflareclient.com:2408).")

        reserved = params.get("reserved")
        if reserved is not None:
            if not (isinstance(reserved, list) and len(reserved) == 3 and all(isinstance(x, int) and 0 <= x <= 255 for x in reserved)):
                errors.append("reserved must be a 3-byte integer array [0..255, 0..255, 0..255].")

        warnings.append("Cloudflare HTTP/HTTPS edge IPs are NOT WARP WireGuard endpoints; use documented WARP UDP endpoints only.")
        return ValidationResult(valid=not errors, errors=errors, warnings=warnings)

    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        val = self.validate_params(params)
        if not val.valid:
            raise ValueError("; ".join(val.errors))

        endpoint = params.get("endpoint", self.OFFICIAL_WARP_ENDPOINT_DEFAULT)
        host, port_str = endpoint.rsplit(":", 1)
        profile = {
            "type": "wireguard",
            "tag": name,
            "server": host.strip("[]"),
            "server_port": int(port_str),
            "local_address": [a for a in [params.get("interface_ipv4"), params.get("interface_ipv6")] if a],
            "private_key": params["device_private_key"].strip(),
            "peer_public_key": params["peer_public_key"].strip(),
            "reserved": params.get("reserved", [0, 0, 0]),
            "mtu": int(params.get("mtu", 1280)),
        }
        return ConfigBuildOutput(
            protocol=self.protocol,
            name=name,
            serialized=json.dumps(profile, indent=2),
            export_extension=".json",
            supported_clients=["Cloudflare WARP Client (registered device)", "Sing-box WireGuard/WARP Outbound"],
            provenance={
                "device_private_key": "user_provided",
                "peer_public_key": "user_provided",
                "endpoint": "user_provided",
            },
            warnings=val.warnings,
        )
