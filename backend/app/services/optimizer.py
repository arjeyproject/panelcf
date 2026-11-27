from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.core.enums import ProtocolType
from app.protocols.registry import get_adapter
from app.ranking.ip_ranker import CandidateMetricsInput, SelectionPreset, SmartIPRanker


@dataclass
class OptimizationCandidate:
    profile_id: str
    name: str
    protocol: ProtocolType
    params: dict[str, Any]
    measured_metrics: CandidateMetricsInput | None = None


@dataclass
class OptimizationDiagnostic:
    profile_id: str
    name: str
    protocol: str
    syntax_valid: bool
    errors: list[str]
    warnings: list[str]
    measured_score: float | None
    confidence: float | None
    recommendations: list[str] = field(default_factory=list)


class ConfigurationOptimizer:
    """
    Unified Configuration Quality & Optimization Engine.
    Never fabricates throughput or claims optimization without measured evidence.
    """

    def __init__(self):
        self._ranker = SmartIPRanker()

    def analyze(
        self,
        candidates: list[OptimizationCandidate],
        preset: SelectionPreset = SelectionPreset.BALANCED,
    ) -> list[OptimizationDiagnostic]:
        diagnostics: list[OptimizationDiagnostic] = []
        for item in candidates:
            adapter = get_adapter(item.protocol)
            val = adapter.validate_params(item.params)
            recs: list[str] = []

            if not val.valid:
                recs.append("Fix syntax/parameter validation errors before deploying this profile.")
            if item.protocol == ProtocolType.WIREGUARD and int(item.params.get("mtu", 1280)) > 1420:
                recs.append("Consider lowering MTU to 1280-1380 to reduce fragmentation over PPPoE/mobile networks.")
            if item.protocol == ProtocolType.VLESS and item.params.get("security") == "none":
                recs.append("Enable TLS or Reality security to protect transport privacy.")

            score: float | None = None
            confidence: float | None = None
            if item.measured_metrics and item.measured_metrics.total_observations > 0:
                ranked = self._ranker.score_candidate(
                    item.measured_metrics,
                    required_protocol=item.protocol.value,
                )
                score = ranked.overall_score
                confidence = ranked.confidence
                if ranked.success_rate < 0.85:
                    recs.append(f"Observed success rate is {ranked.success_rate:.0%}; switch to a higher-reliability endpoint.")
                if (ranked.jitter_ms or 0.0) > 45.0:
                    recs.append(f"High jitter ({ranked.jitter_ms} ms) detected; prefer Maximum Stability preset.")
            else:
                recs.append("No live measurements recorded yet; run Configuration Tester before trusting performance rank.")

            diagnostics.append(
                OptimizationDiagnostic(
                    profile_id=item.profile_id,
                    name=item.name,
                    protocol=item.protocol.value,
                    syntax_valid=val.valid,
                    errors=val.errors,
                    warnings=val.warnings,
                    measured_score=score,
                    confidence=confidence,
                    recommendations=recs,
                )
            )

        diagnostics.sort(
            key=lambda d: (d.syntax_valid, d.measured_score if d.measured_score is not None else -1.0),
            reverse=True,
        )
        return diagnostics
