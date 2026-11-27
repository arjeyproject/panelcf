from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from app.ranking.ip_ranker import CandidateMetricsInput, RankedCandidate, ScoringWeights, SmartIPRanker


@dataclass
class EndpointMetricsInput:
    host: str
    port: int
    dns_resolved: bool
    tls_verified: bool
    success_rate: float
    avg_latency_ms: float | None
    jitter_ms: float | None
    stability_score: float
    total_observations: int
    failed_observations: int
    compatible_protocols: list[str]
    historical_score: float | None = None
    last_tested_at: datetime | None = None


class SmartEndpointRanker:
    """Compatibility-aware endpoint selector. Never selects incompatible endpoints for a protocol."""

    def __init__(self):
        self._base = SmartIPRanker()
        self._weights = ScoringWeights(
            success_rate=0.26, latency=0.15, latency_consistency=0.10,
            jitter=0.11, stability=0.12, compatibility=0.14, historical=0.07, recency=0.05,
        )

    def rank_endpoints(
        self,
        endpoints: list[EndpointMetricsInput],
        required_protocol: str | None = None,
        require_tls: bool = True,
        min_score: float = 50.0,
        limit: int = 20,
        now: datetime | None = None,
    ) -> list[RankedCandidate]:
        now = now or datetime.now(timezone.utc)
        eligible: list[CandidateMetricsInput] = []
        for ep in endpoints:
            if not ep.dns_resolved:
                continue
            if require_tls and not ep.tls_verified:
                continue
            if required_protocol and required_protocol not in ep.compatible_protocols:
                continue
            eligible.append(
                CandidateMetricsInput(
                    identifier=ep.host,
                    port=ep.port,
                    success_rate=ep.success_rate,
                    avg_latency_ms=ep.avg_latency_ms,
                    jitter_ms=ep.jitter_ms,
                    stability_score=ep.stability_score,
                    total_observations=ep.total_observations,
                    failed_observations=ep.failed_observations,
                    testing_diversity=3 if ep.tls_verified else 2,
                    compatible_protocols=ep.compatible_protocols,
                    historical_score=ep.historical_score,
                    last_tested_at=ep.last_tested_at,
                )
            )
        ranked = [
            self._base.score_candidate(e, weights=self._weights, required_protocol=required_protocol, now=now)
            for e in eligible
        ]
        ranked = [r for r in ranked if r.overall_score >= min_score]
        ranked.sort(key=lambda r: (r.overall_score, r.confidence), reverse=True)
        return ranked[:limit]
