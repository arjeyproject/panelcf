from __future__ import annotations

import uuid
from typing import Any
from urllib.parse import quote, urlencode

from app.core.enums import ProtocolType
from app.protocols.base import ConfigBuildOutput, ProtocolAdapter, ValidationResult


class VLESSAdapter(ProtocolAdapter):
    """VLESS URI & configuration builder with strict UUID, transport, and TLS/Reality validation."""

    protocol = ProtocolType.VLESS
    SUPPORTED_TRANSPORTS = {"tcp", "ws", "grpc", "httpupgrade", "xhttp"}
    SUPPORTED_SECURITY = {"tls", "reality", "none"}

    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        errors: list[str] = []
        warnings: list[str] = []

        raw_uuid = str(params.get("uuid", "")).strip()
        try:
            uuid.UUID(raw_uuid)
        except Exception:
            errors.append("Valid RFC 4122 UUID is required for VLESS.")

        address = str(params.get("address", "")).strip()
        if not address:
            errors.append("Server address (domain or IP) is required.")

        port = int(params.get("port", 443))
        if not (1 <= port <= 65535):
            errors.append("Port must be between 1 and 65535.")

        transport = str(params.get("transport", "ws")).lower()
        if transport not in self.SUPPORTED_TRANSPORTS:
            errors.append(f"Unsupported transport '{transport}'. Allowed: {sorted(self.SUPPORTED_TRANSPORTS)}")

        security = str(params.get("security", "tls")).lower()
        if security not in self.SUPPORTED_SECURITY:
            errors.append(f"Unsupported security '{security}'. Allowed: {sorted(self.SUPPORTED_SECURITY)}")
        if security == "none":
            warnings.append("Security is set to 'none'; traffic is unencrypted unless wrapped by another layer.")
        if security == "tls" and not params.get("sni"):
            errors.append("SNI is required when security='tls'.")
        if security == "reality" and (not params.get("pbk") or not params.get("sni")):
            errors.append("Reality requires both 'pbk' (public key) and 'sni'.")

        return ValidationResult(valid=not errors, errors=errors, warnings=warnings)

    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        val = self.validate_params(params)
        if not val.valid:
            raise ValueError("; ".join(val.errors))

        transport = str(params.get("transport", "ws")).lower()
        security = str(params.get("security", "tls")).lower()
        query: dict[str, str] = {
            "encryption": "none",
            "security": security,
            "type": transport,
        }
        if params.get("sni"):
            query["sni"] = str(params["sni"]).strip()
        if params.get("host"):
            query["host"] = str(params["host"]).strip()
        if params.get("path"):
            query["path"] = str(params["path"]).strip()
        if params.get("fp"):
            query["fp"] = str(params["fp"]).strip()
        if security == "reality":
            query["pbk"] = str(params["pbk"]).strip()
            if params.get("sid"):
                query["sid"] = str(params["sid"]).strip()

        host_part = f"[{params['address']}]" if ":" in str(params["address"]) else str(params["address"])
        uri = f"vless://{params['uuid'].strip()}@{host_part}:{int(params.get('port', 443))}?{urlencode(query)}#{quote(name)}"
        return ConfigBuildOutput(
            protocol=self.protocol,
            name=name,
            serialized=uri,
            export_extension=".txt",
            supported_clients=["v2rayNG", "Hiddify", "Sing-box", "Streisand", "V2Box", "Nekoray"],
            provenance={
                "uuid": "user_provided",
                "address": params.get("address_provenance", "user_provided"),
                "sni": "user_provided",
                "uri_format": "generated",
            },
            warnings=val.warnings,
        )
