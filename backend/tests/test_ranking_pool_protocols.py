from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone

import pytest

from app.core.enums import CandidateLifecycleState, ProtocolType
from app.pool.manager import AutomatedCandidatePool
from app.protocols.registry import get_adapter
from app.ranking.endpoint_ranker import EndpointMetricsInput, SmartEndpointRanker
from app.ranking.ip_ranker import CandidateMetricsInput, SelectionPreset, SmartIPRanker
from app.scanners.protocol_tests import ProtocolCompatibilityTester
from app.services.optimizer import ConfigurationOptimizer, OptimizationCandidate


def test_ranker_prefers_stable_over_unstable_low_latency():
    now = datetime.now(timezone.utc)
    ranker = SmartIPRanker()
    unstable_fast = CandidateMetricsInput(
        identifier="1.1.1.1", port=443, success_rate=0.45,
        avg_latency_ms=22.0, min_latency_ms=15.0, max_latency_ms=190.0,
        jitter_ms=55.0, stability_score=28.0, total_observations=10,
        failed_observations=5, compatible_protocols=["vless"], last_tested_at=now,
    )
    stable_moderate = CandidateMetricsInput(
        identifier="1.0.0.1", port=443, success_rate=0.98,
        avg_latency_ms=95.0, min_latency_ms=88.0, max_latency_ms=102.0,
        jitter_ms=4.0, stability_score=94.0, total_observations=10,
        failed_observations=0, compatible_protocols=["vless"], last_tested_at=now,
    )
    ranked = ranker.rank_and_select([unstable_fast, stable_moderate], preset=SelectionPreset.BALANCED)
    assert ranked[0].identifier == "1.0.0.1"
    assert ranked[0].overall_score > ranked[1].overall_score
    assert ranked[1].explanation["penalty_applied"] == "yes"


def test_endpoint_ranker_enforces_protocol_compatibility():
    now = datetime.now(timezone.utc)
    er = SmartEndpointRanker()
    eps = [
        EndpointMetricsInput("edge1.example.com", 443, True, True, 0.99, 60.0, 5.0, 95.0, 8, 0, ["vless"], last_tested_at=now),
        EndpointMetricsInput("edge2.example.com", 443, True, True, 0.99, 40.0, 3.0, 97.0, 8, 0, ["trojan"], last_tested_at=now),
    ]
    selected = er.rank_endpoints(eps, required_protocol="vless")
    assert [s.identifier for s in selected] == ["edge1.example.com"]


def test_pool_never_fabricates_or_lowers_thresholds():
    now = datetime.now(timezone.utc)
    pool = AutomatedCandidatePool("ip_pool", target_count=100, min_quality_score=65.0)
    ingest = pool.ingest_candidates([("1.1.1.1", 443), ("1.1.1.1", 443), ("127.0.0.1", 443)])
    assert ingest == {"added": 1, "duplicates": 1, "invalid": 1}

    good = CandidateMetricsInput("1.1.1.1", 443, 0.98, 70.0, 65.0, 75.0, 3.0, 95.0, 8, 0, ["vless"], last_tested_at=now)
    weak = CandidateMetricsInput("8.8.8.8", 443, 0.30, 420.0, 300.0, 600.0, 90.0, 15.0, 6, 4, [], last_tested_at=now)
    report = pool.apply_scan_results([good, weak], now=now)
    assert report.verified_passing_count == 1
    assert report.rejected_below_threshold == 1
    assert report.target_met is False
    assert len(pool.get_healthy_entries(now=now)) == 1
    assert "NOT lowered" in report.note


def test_all_five_protocol_adapters_and_strict_compatibility():
    valid_key = base64.b64encode(b"A" * 32).decode()

    wg = get_adapter(ProtocolType.WIREGUARD).build("wg-home", {
        "private_key": valid_key, "peer_public_key": valid_key,
        "endpoint": "198.51.100.10:51820", "addresses": ["10.66.66.2/32"], "mtu": 1360,
    })
    assert "[Interface]" in wg.serialized and "[Peer]" in wg.serialized

    warp = get_adapter(ProtocolType.WARP).build("warp-dev", {
        "device_private_key": valid_key, "peer_public_key": valid_key,
        "interface_ipv4": "172.16.0.2/32", "reserved": [12, 34, 56],
    })
    assert "engage.cloudflareclient.com" in warp.serialized

    masque = get_adapter(ProtocolType.MASQUE).build("masque-h3", {
        "endpoint": "162.159.192.1:443", "sni": "consumer-masque.cloudflareclient.com",
        "auth_token": "registered-masque-token", "alpn": ["h3"],
    })
    assert "RFC 9298" in masque.serialized

    vless = get_adapter(ProtocolType.VLESS).build("vless-ws", {
        "uuid": "550e8400-e29b-41d4-a716-446655440000", "address": "1.1.1.1",
        "port": 443, "transport": "ws", "security": "tls", "sni": "cdn.example.com", "path": "/ws",
    })
    assert vless.serialized.startswith("vless://550e8400-e29b-41d4-a716-446655440000@1.1.1.1:443?")

    trojan = get_adapter(ProtocolType.TROJAN).build("trojan-tls", {
        "password": "StrongPassword123", "address": "edge.example.com", "port": 443, "sni": "edge.example.com",
    })
    assert trojan.serialized.startswith("trojan://StrongPassword123@edge.example.com:443?")

    # Protocol compatibility tester never equates HTTP/TCP reachability with tunnel verification
    compat = ProtocolCompatibilityTester().evaluate(ProtocolType.WIREGUARD, syntax_valid=True, tcp_reachable=True, http_ok=True)
    assert compat.tunnel_handshake_verified is False
    assert compat.recommended_lifecycle_state != CandidateLifecycleState.CONNECTION_VERIFIED
    assert any("does NOT verify WireGuard" in w for w in compat.warnings)


def test_optimizer_never_claims_measured_rank_without_tests():
    opt = ConfigurationOptimizer()
    diags = opt.analyze([
        OptimizationCandidate(
            profile_id="p1", name="vless-untested", protocol=ProtocolType.VLESS,
            params={"uuid": "550e8400-e29b-41d4-a716-446655440000", "address": "1.1.1.1", "port": 443, "security": "tls", "sni": "a.example.com"},
            measured_metrics=None,
        )
    ])
    assert diags[0].syntax_valid is True
    assert diags[0].measured_score is None
    assert any("No live measurements" in r for r in diags[0].recommendations)
