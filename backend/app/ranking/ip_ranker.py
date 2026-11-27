from __future__ import annotations

import ipaddress
import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum


class SelectionPreset(str, Enum):
    BALANCED = "balanced"
    LOWEST_LATENCY = "lowest_latency"
    MAX_STABILITY = "max_stability"
    HIGH_RELIABILITY = "high_reliability"
    IPV4 = "ipv4"
    IPV6 = "ipv6"
    COMPATIBLE = "compatible"
    MANUAL = "manual"


@dataclass(frozen=True)
class ScoringWeights:
    success_rate: float = 0.28
    latency: float = 0.16
    latency_consistency: float = 0.12
    jitter: float = 0.12
    stability: float = 0.12
    compatibility: float = 0.08
    historical: float = 0.07
    recency: float = 0.05


PRESET_WEIGHTS: dict[SelectionPreset, ScoringWeights] = {
    SelectionPreset.BALANCED: ScoringWeights(),
    SelectionPreset.LOWEST_LATENCY: ScoringWeights(
        success_rate=0.22, latency=0.34, latency_consistency=0.10,
        jitter=0.10, stability=0.08, compatibility=0.06, historical=0.05, recency=0.05,
    ),
    SelectionPreset.MAX_STABILITY: ScoringWeights(
        success_rate=0.26, latency=0.08, latency_consistency=0.18,
        jitter=0.18, stability=0.16, compatibility=0.05, historical=0.05, recency=0.04,
    ),
    SelectionPreset.HIGH_RELIABILITY: ScoringWeights(
        success_rate=0.36, latency=0.08, latency_consistency=0.10,
        jitter=0.10, stability=0.12, compatibility=0.08, historical=0.11, recency=0.05,
    ),
}


@dataclass
class CandidateMetricsInput:
    identifier: str
    port: int
    success_rate: float
    avg_latency_ms: float | None
    min_latency_ms: float | None = None
    max_latency_ms: float | None = None
    jitter_ms: float | None = None
    stability_score: float = 0.0
    total_observations: int = 0
    failed_observations: int = 0
    testing_diversity: int = 1
    compatible_protocols: list[str] = field(default_factory=list)
    historical_score: float | None = None
    last_tested_at: datetime | None = None


@dataclass
class RankedCandidate:
    identifier: str
    port: int
    overall_score: float
    confidence: float
    avg_latency_ms: float | None
    jitter_ms: float | None
    stability_score: float
    success_rate: float
    compatible_protocols: list[str]
    last_tested_at: datetime | None
    historical_trend: str
    explanation: dict[str, float | str]


def _latency_score(avg_ms: float | None) -> float:
    if avg_ms is None or avg_ms <= 0:
        return 0.0
    return round(max(0.0, min(100.0, 100.0 * math.exp(-avg_ms / 380.0))), 2)


def _jitter_score(jitter_ms: float | None, avg_ms: float | None) -> float:
    if jitter_ms is None or avg_ms is None:
        return 0.0
    ratio = jitter_ms / max(avg_ms, 10.0)
    return round(max(0.0, min(100.0, 100.0 * math.exp(-ratio * 2.2))), 2)


def _consistency_score(min_ms: float | None, max_ms: float | None, avg_ms: float | None) -> float:
    if avg_ms is None or min_ms is None or max_ms is None:
        return 50.0 if avg_ms is not None else 0.0
    spread = max(0.0, max_ms - min_ms)
    ratio = spread / max(avg_ms, 10.0)
    return round(max(0.0, min(100.0, 100.0 * math.exp(-ratio * 0.9))), 2)


def _recency_score(last_tested: datetime | None, now: datetime) -> float:
    if last_tested is None:
        return 0.0
    age_hours = max(0.0, (now - last_tested).total_seconds() / 3600.0)
    return round(max(0.0, min(100.0, 100.0 * math.exp(-age_hours / 36.0))), 2)


def compute_confidence(item: CandidateMetricsInput, now: datetime) -> float:
    if item.total_observations <= 0:
        return 0.0
    sample_factor = 1.0 - math.exp(-item.total_observations / 6.0)
    reliability_factor = max(0.0, min(1.0, item.success_rate))
    diversity_factor = min(1.0, 0.5 + 0.25 * max(0, item.testing_diversity - 1))
    recency_factor = _recency_score(item.last_tested_at, now) / 100.0
    raw = (0.35 * sample_factor + 0.30 * reliability_factor + 0.15 * diversity_factor + 0.20 * recency_factor) * 100.0
    return round(max(0.0, min(100.0, raw)), 2)


class SmartIPRanker:
    """Stages 4-7: Weighted quality scoring, statistical confidence, ranking, and preset selection."""

    def score_candidate(
        self,
        item: CandidateMetricsInput,
        weights: ScoringWeights | None = None,
        required_protocol: str | None = None,
        now: datetime | None = None,
    ) -> RankedCandidate:
        now = now or datetime.now(timezone.utc)
        w = weights or ScoringWeights()

        sr_pts = round(max(0.0, min(1.0, item.success_rate)) * 100.0, 2)
        lat_pts = _latency_score(item.avg_latency_ms)
        cons_pts = _consistency_score(item.min_latency_ms, item.max_latency_ms, item.avg_latency_ms)
        jit_pts = _jitter_score(item.jitter_ms, item.avg_latency_ms)
        stab_pts = round(max(0.0, min(100.0, item.stability_score)), 2)
        if required_protocol:
            compat_pts = 100.0 if required_protocol in item.compatible_protocols else 0.0
        else:
            compat_pts = min(100.0, len(item.compatible_protocols) * 35.0)
        hist_pts = item.historical_score if item.historical_score is not None else sr_pts
        rec_pts = _recency_score(item.last_tested_at, now)

        weighted_sum = (
            sr_pts * w.success_rate
            + lat_pts * w.latency
            + cons_pts * w.latency_consistency
            + jit_pts * w.jitter
            + stab_pts * w.stability
            + compat_pts * w.compatibility
            + hist_pts * w.historical
            + rec_pts * w.recency
        )

        # Penalize unstable candidates even if single-shot latency looks low
        if item.success_rate < 0.7:
            weighted_sum *= (0.4 + 0.6 * item.success_rate)

        overall = round(max(0.0, min(100.0, weighted_sum)), 2)
        confidence = compute_confidence(item, now)

        if item.historical_score is None:
            trend = "new"
        elif overall - item.historical_score >= 4.0:
            trend = "improving"
        elif item.historical_score - overall >= 4.0:
            trend = "degrading"
        else:
            trend = "stable"

        explanation = {
            "success_rate_pts": sr_pts,
            "latency_pts": lat_pts,
            "consistency_pts": cons_pts,
            "jitter_pts": jit_pts,
            "stability_pts": stab_pts,
            "compatibility_pts": compat_pts,
            "historical_pts": round(hist_pts, 2),
            "recency_pts": rec_pts,
            "penalty_applied": "yes" if item.success_rate < 0.7 else "no",
        }

        return RankedCandidate(
            identifier=item.identifier,
            port=item.port,
            overall_score=overall,
            confidence=confidence,
            avg_latency_ms=item.avg_latency_ms,
            jitter_ms=item.jitter_ms,
            stability_score=stab_pts,
            success_rate=item.success_rate,
            compatible_protocols=list(item.compatible_protocols),
            last_tested_at=item.last_tested_at,
            historical_trend=trend,
            explanation=explanation,
        )

    def rank_and_select(
        self,
        candidates: list[CandidateMetricsInput],
        preset: SelectionPreset = SelectionPreset.BALANCED,
        required_protocol: str | None = None,
        min_score: float = 0.0,
        limit: int = 20,
        now: datetime | None = None,
    ) -> list[RankedCandidate]:
        weights = PRESET_WEIGHTS.get(preset, ScoringWeights())
        filtered: list[CandidateMetricsInput] = []
        for c in candidates:
            if preset == SelectionPreset.IPV4:
                try:
                    if ipaddress.ip_address(c.identifier).version != 4:
                        continue
                except ValueError:
                    continue
            elif preset == SelectionPreset.IPV6:
                try:
                    if ipaddress.ip_address(c.identifier).version != 6:
                        continue
                except ValueError:
                    continue
            elif preset == SelectionPreset.COMPATIBLE and required_protocol:
                if required_protocol not in c.compatible_protocols:
                    continue
            filtered.append(c)

        scored = [
            self.score_candidate(c, weights=weights, required_protocol=required_protocol, now=now)
            for c in filtered
        ]
        scored = [s for s in scored if s.overall_score >= min_score]
        scored.sort(key=lambda r: (r.overall_score, r.confidence, -(r.avg_latency_ms or 99999.0)), reverse=True)
        return scored[:limit]
