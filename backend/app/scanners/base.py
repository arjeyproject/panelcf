from __future__ import annotations

import asyncio
import statistics
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Awaitable, Callable


@dataclass
class ProbeSample:
    success: bool
    latency_ms: float | None = None
    tls_ok: bool | None = None
    http_status: int | None = None
    error: str | None = None
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class AggregatedScanMetrics:
    target: str
    port: int
    total_attempts: int
    success_count: int
    failure_count: int
    success_rate: float
    avg_latency_ms: float | None
    min_latency_ms: float | None
    max_latency_ms: float | None
    jitter_ms: float | None
    stability_score: float
    tls_verified: bool
    http_verified: bool
    samples: list[ProbeSample] = field(default_factory=list)


def compute_jitter_ms(latencies: list[float]) -> float | None:
    if len(latencies) < 2:
        return 0.0 if len(latencies) == 1 else None
    diffs = [abs(latencies[i] - latencies[i - 1]) for i in range(1, len(latencies))]
    return round(sum(diffs) / len(diffs), 3)


def filter_iqr_outliers(latencies: list[float]) -> list[float]:
    if len(latencies) < 4:
        return latencies
    sorted_vals = sorted(latencies)
    q1, _, q3 = statistics.quantiles(sorted_vals, n=4, method="inclusive")
    iqr = q3 - q1
    lower, upper = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    cleaned = [v for v in sorted_vals if lower <= v <= upper]
    return cleaned or sorted_vals


def aggregate_samples(target: str, port: int, samples: list[ProbeSample]) -> AggregatedScanMetrics:
    total = len(samples)
    successes = [s for s in samples if s.success]
    success_count = len(successes)
    failure_count = total - success_count
    success_rate = (success_count / total) if total else 0.0
    latencies = [s.latency_ms for s in successes if s.latency_ms is not None]
    cleaned = filter_iqr_outliers(latencies)
    avg_lat = round(sum(cleaned) / len(cleaned), 3) if cleaned else None
    min_lat = round(min(cleaned), 3) if cleaned else None
    max_lat = round(max(cleaned), 3) if cleaned else None
    jitter = compute_jitter_ms(latencies)

    if avg_lat is not None and jitter is not None:
        rel_jitter = jitter / max(avg_lat, 1.0)
        stability = max(0.0, min(100.0, (success_rate * 100.0) * max(0.0, 1.0 - min(rel_jitter, 1.0) * 0.6)))
    else:
        stability = 0.0

    return AggregatedScanMetrics(
        target=target,
        port=port,
        total_attempts=total,
        success_count=success_count,
        failure_count=failure_count,
        success_rate=round(success_rate, 4),
        avg_latency_ms=avg_lat,
        min_latency_ms=min_lat,
        max_latency_ms=max_lat,
        jitter_ms=jitter,
        stability_score=round(stability, 2),
        tls_verified=any(s.tls_ok is True for s in successes),
        http_verified=any(s.http_status is not None and 100 <= s.http_status < 500 for s in successes),
        samples=samples,
    )


class BoundedAdaptiveRunner:
    """Runs async scan tasks with bounded concurrency, cancellation, and progress reporting."""

    def __init__(self, max_concurrency: int = 32):
        self.max_concurrency = max(1, max_concurrency)
        self.cancel_event = asyncio.Event()

    def cancel(self) -> None:
        self.cancel_event.set()

    async def run_batch(
        self,
        items: list,
        worker: Callable[[object], Awaitable[object]],
        on_progress: Callable[[int, int], Awaitable[None]] | None = None,
    ) -> list:
        semaphore = asyncio.Semaphore(self.max_concurrency)
        total = len(items)
        completed = 0
        lock = asyncio.Lock()

        async def _guarded(item):
            nonlocal completed
            if self.cancel_event.is_set():
                return None
            async with semaphore:
                if self.cancel_event.is_set():
                    return None
                res = await worker(item)
                async with lock:
                    completed += 1
                    if on_progress:
                        await on_progress(completed, total)
                return res

        results = await asyncio.gather(*(_guarded(item) for item in items), return_exceptions=False)
        return [r for r in results if r is not None]
