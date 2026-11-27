from __future__ import annotations

from app.core.config import get_settings
from app.pool.manager import AutomatedCandidatePool
from app.security.rate_limit import SlidingWindowRateLimiter

settings = get_settings()

ip_pool = AutomatedCandidatePool(
    name="ip_pool",
    target_count=settings.pool_target_tested_ips,
    min_quality_score=settings.pool_min_quality_score,
    ttl_hours=settings.pool_candidate_ttl_hours,
    validate_as_ip=True,
)
endpoint_pool = AutomatedCandidatePool(
    name="endpoint_pool",
    target_count=settings.pool_target_tested_endpoints,
    min_quality_score=settings.pool_min_quality_score,
    ttl_hours=settings.pool_candidate_ttl_hours,
    validate_as_ip=False,
)
api_rate_limiter = SlidingWindowRateLimiter(max_requests=settings.api_rate_limit_per_minute, window_seconds=60)
active_scan_jobs: dict[str, dict] = {}
saved_profiles: dict[str, dict] = {}
audit_events: list[dict] = []
