from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger

from app.core.config import get_settings

logger = logging.getLogger(__name__)


class DistributedJobLock:
    """Prevents overlapping scans and duplicate scheduled jobs (uses asyncio.Lock locally + Redis SET NX in cluster)."""

    def __init__(self, redis_client=None):
        self._redis = redis_client
        self._local_locks: dict[str, asyncio.Lock] = {}

    async def acquire(self, key: str, ttl_sec: int = 1800) -> bool:
        if self._redis is not None:
            return bool(await self._redis.set(f"cfhub:lock:{key}", "1", nx=True, ex=ttl_sec))
        lock = self._local_locks.setdefault(key, asyncio.Lock())
        if lock.locked():
            return False
        await lock.acquire()
        return True

    async def release(self, key: str) -> None:
        if self._redis is not None:
            await self._redis.delete(f"cfhub:lock:{key}")
            return
        lock = self._local_locks.get(key)
        if lock and lock.locked():
            lock.release()


def create_scheduler(ip_refresh_coro, endpoint_refresh_coro, cleanup_coro) -> AsyncIOScheduler:
    settings = get_settings()
    scheduler = AsyncIOScheduler(timezone=settings.timezone)
    scheduler.add_job(
        ip_refresh_coro,
        trigger=IntervalTrigger(hours=settings.pool_refresh_interval_hours),
        id="ip_pool_24h_refresh",
        max_instances=1,
        coalesce=True,
        replace_existing=True,
    )
    scheduler.add_job(
        endpoint_refresh_coro,
        trigger=IntervalTrigger(hours=settings.pool_refresh_interval_hours),
        id="endpoint_pool_24h_refresh",
        max_instances=1,
        coalesce=True,
        replace_existing=True,
    )
    scheduler.add_job(
        cleanup_coro,
        trigger=IntervalTrigger(hours=6),
        id="pool_and_job_cleanup",
        max_instances=1,
        coalesce=True,
        replace_existing=True,
    )
    logger.info("Scheduler configured at %s (24h IP & Endpoint pool refresh).", datetime.now(timezone.utc).isoformat())
    return scheduler
