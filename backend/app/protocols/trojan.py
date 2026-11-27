from __future__ import annotations

from typing import Any
from urllib.parse import quote, urlencode

from app.core.enums import ProtocolType
from app.protocols.base import ConfigBuildOutput, ProtocolAdapter, ValidationResult


class TrojanAdapter(ProtocolAdapter):
    """Trojan URI builder & validator. Never fabricates server passwords."""

    protocol = ProtocolType.TROJAN

    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        errors: list[str] = []
        warnings: list[str] = []

        password = str(params.get("password", "")).strip()
        if len(password) < 8:
            errors.append("User-provided Trojan server password (min 8 chars) is required.")
        address = str(params.get("address", "")).strip()
        if not address:
            errors.append("Server address is required.")
        port = int(params.get("port", 443))
        if not (1 <= port <= 65535):
            errors.append("Port must be between 1 and 65535.")
        if not params.get("sni"):
            errors.append("TLS SNI is required for Trojan.")
        return ValidationResult(valid=not errors, errors=errors, warnings=warnings)

    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        val = self.validate_params(params)
        if not val.valid:
            raise ValueError("; ".join(val.errors))

        query: dict[str, str] = {
            "security": "tls",
            "sni": str(params["sni"]).strip(),
            "type": str(params.get("transport", "tcp")).lower(),
        }
        if params.get("host"):
            query["host"] = str(params["host"]).strip()
        if params.get("path"):
            query["path"] = str(params["path"]).strip()
        if params.get("fp"):
            query["fp"] = str(params["fp"]).strip()

        host_part = f"[{params['address']}]" if ":" in str(params["address"]) else str(params["address"])
        uri = f"trojan://{quote(params['password'].strip(), safe='')}@{host_part}:{int(params.get('port', 443))}?{urlencode(query)}#{quote(name)}"
        return ConfigBuildOutput(
            protocol=self.protocol,
            name=name,
            serialized=uri,
            export_extension=".txt",
            supported_clients=["Clash Meta / Mihomo", "Sing-box", "v2rayNG", "Hiddify", "Shadowrocket"],
            provenance={
                "password": "user_provided",
                "address": params.get("address_provenance", "user_provided"),
                "sni": "user_provided",
                "uri_format": "generated",
            },
            warnings=val.warnings,
        )
