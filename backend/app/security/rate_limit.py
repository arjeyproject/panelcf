from __future__ import annotations

import time
from collections import defaultdict, deque


class SlidingWindowRateLimiter:
    """In-memory sliding window limiter (production deployments pair with Redis atomic Lua script)."""

    def __init__(self, max_requests: int, window_seconds: int = 60):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._buckets: dict[str, deque[float]] = defaultdict(deque)

    def allow(self, key: str, now: float | None = None) -> tuple[bool, int]:
        ts = now if now is not None else time.monotonic()
        cutoff = ts - self.window_seconds
        q = self._buckets[key]
        while q and q[0] <= cutoff:
            q.popleft()
        if len(q) >= self.max_requests:
            return False, 0
        q.append(ts)
        return True, self.max_requests - len(q)
