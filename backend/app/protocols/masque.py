from __future__ import annotations

import json
from typing import Any

from app.core.enums import ProtocolType
from app.protocols.base import ConfigBuildOutput, ProtocolAdapter, ValidationResult


class MASQUEAdapter(ProtocolAdapter):
    """
    RFC 9298 / HTTP/3 CONNECT-UDP MASQUE configuration workflow.
    Does not relabel WireGuard/VLESS/Trojan as MASQUE.
    """

    protocol = ProtocolType.MASQUE

    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        errors: list[str] = []
        warnings: list[str] = []

        endpoint = str(params.get("endpoint", "")).strip()
        if not endpoint or ":" not in endpoint:
            errors.append("MASQUE endpoint (host:port, typically UDP/443) is required.")

        sni = str(params.get("sni", "")).strip()
        if not sni:
            errors.append("TLS SNI hostname is required for HTTP/3 QUIC MASQUE connections.")

        if not params.get("client_certificate_pem") and not params.get("auth_token"):
            errors.append("Either client_certificate_pem (mTLS) or a valid MASQUE auth_token is required.")

        alpn = params.get("alpn") or ["h3"]
        if "h3" not in alpn:
            errors.append("MASQUE requires HTTP/3 ('h3') in ALPN.")

        warnings.append("MASQUE requires a client with RFC 9298 HTTP/3 CONNECT-UDP support.")
        return ValidationResult(valid=not errors, errors=errors, warnings=warnings)

    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        val = self.validate_params(params)
        if not val.valid:
            raise ValueError("; ".join(val.errors))

        profile = {
            "schema": "cfhub.masque.v1",
            "name": name,
            "protocol": "masque-connect-udp",
            "rfc": "RFC 9298",
            "transport": "quic",
            "endpoint": params["endpoint"].strip(),
            "sni": params["sni"].strip(),
            "alpn": params.get("alpn") or ["h3"],
            "uri_template": params.get("uri_template") or "/.well-known/masque/udp/{target_host}/{target_port}/",
            "mtu": int(params.get("mtu", 1280)),
            "auth_mode": "mtls" if params.get("client_certificate_pem") else "bearer",
        }
        return ConfigBuildOutput(
            protocol=self.protocol,
            name=name,
            serialized=json.dumps(profile, indent=2),
            export_extension=".masque.json",
            supported_clients=["Cloudflare WARP (MASQUE mode)", "RFC 9298 HTTP/3 MASQUE Clients"],
            provenance={
                "endpoint": "user_provided",
                "sni": "user_provided",
                "uri_template": "generated",
            },
            warnings=val.warnings,
        )
