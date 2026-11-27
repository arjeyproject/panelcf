from __future__ import annotations

from dataclasses import dataclass, field

from app.core.enums import CandidateLifecycleState, ProtocolType


@dataclass
class ProtocolCompatibilityReport:
    protocol: ProtocolType
    syntax_valid: bool
    transport_reachable: bool
    tls_handshake_ok: bool | None
    tunnel_handshake_verified: bool
    recommended_lifecycle_state: CandidateLifecycleState
    verified_checks: list[str] = field(default_factory=list)
    unverified_checks: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


class ProtocolCompatibilityTester:
    """
    Engine C: Strict protocol compatibility evaluator.
    Never conflates TCP/TLS/HTTP reachability with full tunnel verification.
    """

    def evaluate(
        self,
        protocol: ProtocolType,
        *,
        syntax_valid: bool,
        tcp_reachable: bool = False,
        udp_probe_ok: bool = False,
        tls_ok: bool = False,
        http_ok: bool = False,
        tunnel_verified: bool = False,
    ) -> ProtocolCompatibilityReport:
        verified: list[str] = []
        unverified: list[str] = []
        warnings: list[str] = []

        if syntax_valid:
            verified.append("configuration_syntax")
        else:
            return ProtocolCompatibilityReport(
                protocol=protocol,
                syntax_valid=False,
                transport_reachable=False,
                tls_handshake_ok=tls_ok,
                tunnel_handshake_verified=False,
                recommended_lifecycle_state=CandidateLifecycleState.CANDIDATE,
                warnings=["Configuration failed syntax/schema validation."],
            )

        if protocol in (ProtocolType.WIREGUARD, ProtocolType.WARP):
            if http_ok or tcp_reachable:
                warnings.append("HTTP/TCP reachability does NOT verify WireGuard/WARP UDP tunnel compatibility.")
            if udp_probe_ok:
                verified.append("udp_endpoint_reachable")
            else:
                unverified.append("wireguard_noise_handshake")
        elif protocol == ProtocolType.MASQUE:
            if tls_ok:
                verified.append("tls_endpoint_reachable")
            unverified.append("http3_connect_udp_masque_handshake")
            warnings.append("Full MASQUE verification requires an HTTP/3 QUIC CONNECT-UDP client exchange.")
        elif protocol == ProtocolType.VLESS:
            if tcp_reachable:
                verified.append("tcp_transport_reachable")
            if tls_ok:
                verified.append("tls_handshake")
            unverified.append("vless_uuid_application_handshake")
            warnings.append("TCP/TLS reachability alone does NOT verify VLESS UUID authentication or server routing.")
        elif protocol == ProtocolType.TROJAN:
            if tcp_reachable:
                verified.append("tcp_transport_reachable")
            if tls_ok:
                verified.append("tls_handshake")
            unverified.append("trojan_sha224_password_handshake")
            warnings.append("TLS handshake success does NOT verify Trojan server credentials or proxy forwarding.")

        if tunnel_verified:
            verified.append("end_to_end_tunnel_verified")
            unverified.clear()
            state = CandidateLifecycleState.CONNECTION_VERIFIED
        elif verified and (tcp_reachable or udp_probe_ok or tls_ok):
            state = CandidateLifecycleState.TESTED
        else:
            state = CandidateLifecycleState.VALIDATED

        return ProtocolCompatibilityReport(
            protocol=protocol,
            syntax_valid=syntax_valid,
            transport_reachable=tcp_reachable or udp_probe_ok,
            tls_handshake_ok=tls_ok if protocol in (ProtocolType.VLESS, ProtocolType.TROJAN, ProtocolType.MASQUE) else None,
            tunnel_handshake_verified=tunnel_verified,
            recommended_lifecycle_state=state,
            verified_checks=verified,
            unverified_checks=unverified,
            warnings=warnings,
        )
