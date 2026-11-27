from __future__ import annotations

import csv
import io
import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from app.core.enums import CandidateLifecycleState
from app.ranking.ip_ranker import CandidateMetricsInput, RankedCandidate, SmartIPRanker
from app.security.ssrf import validate_ip_target


@dataclass
class PoolEntry:
    identifier: str
    port: int
    source: str
    lifecycle_state: CandidateLifecycleState
    overall_score: float = 0.0
    confidence: float = 0.0
    avg_latency_ms: float | None = None
    jitter_ms: float | None = None
    success_rate: float = 0.0
    stability_score: float = 0.0
    compatible_protocols: list[str] = field(default_factory=list)
    last_tested_at: datetime | None = None
    expires_at: datetime | None = None


@dataclass
class PoolRefreshReport:
    pool_name: str
    target_count: int
    evaluated_count: int
    verified_passing_count: int
    rejected_below_threshold: int
    expired_removed_count: int
    refreshed_at: datetime
    target_met: bool
    note: str


class AutomatedCandidatePool:
    """
    Automated IP / Endpoint Pool Manager.
    Guarantees:
    - Never fabricates candidates or test results.
    - Never lowers quality threshold to hit target counts.
    - Reports exact verified counts honestly.
    """

    def __init__(
        self,
        name: str,
        target_count: int = 100,
        min_quality_score: float = 55.0,
        ttl_hours: int = 72,
        validate_as_ip: bool = True,
    ):
        self.name = name
        self.target_count = target_count
        self.min_quality_score = min_quality_score
        self.ttl_hours = ttl_hours
        self.validate_as_ip = validate_as_ip
        self._entries: dict[tuple[str, int], PoolEntry] = {}
        self._ranker = SmartIPRanker()
        self.last_refresh_at: datetime | None = None

    def ingest_candidates(self, items: list[tuple[str, int]], source: str = "manual") -> dict[str, int]:
        added = 0
        duplicates = 0
        invalid = 0
        for raw_id, port in items:
            if not (1 <= port <= 65535):
                invalid += 1
                continue
            ident = raw_id.strip()
            if self.validate_as_ip:
                try:
                    ident = str(validate_ip_target(ident))
                except ValueError:
                    invalid += 1
                    continue
            key = (ident, port)
            if key in self._entries:
                duplicates += 1
                continue
            self._entries[key] = PoolEntry(
                identifier=ident,
                port=port,
                source=source,
                lifecycle_state=CandidateLifecycleState.VALIDATED,
            )
            added += 1
        return {"added": added, "duplicates": duplicates, "invalid": invalid}

    def apply_scan_results(self, results: list[CandidateMetricsInput], now: datetime | None = None) -> PoolRefreshReport:
        now = now or datetime.now(timezone.utc)
        expired_removed = self.cleanup_expired(now=now)
        passing = 0
        rejected = 0

        for item in results:
            ranked: RankedCandidate = self._ranker.score_candidate(item, now=now)
            key = (item.identifier, item.port)
            existing = self._entries.get(key)
            source = existing.source if existing else "scanner"

            if ranked.overall_score >= self.min_quality_score and item.total_observations > 0:
                state = CandidateLifecycleState.PERFORMANCE_RANKED
                passing += 1
            else:
                state = CandidateLifecycleState.TESTED
                rejected += 1

            self._entries[key] = PoolEntry(
                identifier=item.identifier,
                port=item.port,
                source=source,
                lifecycle_state=state,
                overall_score=ranked.overall_score,
                confidence=ranked.confidence,
                avg_latency_ms=ranked.avg_latency_ms,
                jitter_ms=ranked.jitter_ms,
                success_rate=ranked.success_rate,
                stability_score=ranked.stability_score,
                compatible_protocols=ranked.compatible_protocols,
                last_tested_at=now,
                expires_at=now + timedelta(hours=self.ttl_hours),
            )

        self.last_refresh_at = now
        healthy_total = len(self.get_healthy_entries(now=now))
        target_met = healthy_total >= self.target_count
        note = (
            f"Target of {self.target_count} verified candidates met ({healthy_total} healthy)."
            if target_met
            else f"Reported actual verified count: {healthy_total}/{self.target_count}. Threshold ({self.min_quality_score}) was NOT lowered."
        )
        return PoolRefreshReport(
            pool_name=self.name,
            target_count=self.target_count,
            evaluated_count=len(results),
            verified_passing_count=passing,
            rejected_below_threshold=rejected,
            expired_removed_count=expired_removed,
            refreshed_at=now,
            target_met=target_met,
            note=note,
        )

    def cleanup_expired(self, now: datetime | None = None) -> int:
        now = now or datetime.now(timezone.utc)
        expired_keys = [k for k, v in self._entries.items() if v.expires_at and v.expires_at <= now]
        for k in expired_keys:
            del self._entries[k]
        return len(expired_keys)

    def get_healthy_entries(self, now: datetime | None = None) -> list[PoolEntry]:
        now = now or datetime.now(timezone.utc)
        healthy = [
            e for e in self._entries.values()
            if e.lifecycle_state in (CandidateLifecycleState.PERFORMANCE_RANKED, CandidateLifecycleState.CONNECTION_VERIFIED)
            and e.overall_score >= self.min_quality_score
            and (e.expires_at is None or e.expires_at > now)
        ]
        healthy.sort(key=lambda e: (e.overall_score, e.confidence), reverse=True)
        return healthy

    def stats(self) -> dict:
        total = len(self._entries)
        healthy = self.get_healthy_entries()
        untested = sum(1 for e in self._entries.values() if e.last_tested_at is None)
        return {
            "pool_name": self.name,
            "total_entries": total,
            "healthy_verified_entries": len(healthy),
            "untested_entries": untested,
            "target_count": self.target_count,
            "min_quality_score": self.min_quality_score,
            "last_refresh_at": self.last_refresh_at.isoformat() if self.last_refresh_at else None,
        }

    def export(self, fmt: str = "json") -> str:
        entries = self.get_healthy_entries()
        if fmt == "txt":
            return "\n".join(f"{e.identifier}:{e.port}" for e in entries)
        if fmt == "csv":
            buf = io.StringIO()
            writer = csv.writer(buf)
            writer.writerow(["identifier", "port", "score", "confidence", "latency_ms", "jitter_ms", "success_rate", "state"])
            for e in entries:
                writer.writerow([e.identifier, e.port, e.overall_score, e.confidence, e.avg_latency_ms, e.jitter_ms, e.success_rate, e.lifecycle_state])
            return buf.getvalue()
        return json.dumps([e.__dict__ for e in entries], default=str, indent=2)
