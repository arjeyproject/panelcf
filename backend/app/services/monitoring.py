from __future__ import annotations

import os
import shutil
import time
from datetime import datetime, timezone

START_TIME = time.monotonic()


def collect_system_health() -> dict:
    disk = shutil.disk_usage("/")
    cpu_pct = 0.0
    mem_pct = 0.0
    try:
        import psutil
        cpu_pct = psutil.cpu_percent(interval=0.05)
        mem_pct = psutil.virtual_memory().percent
    except Exception:
        load = os.getloadavg()[0] if hasattr(os, "getloadavg") else 0.0
        cpu_pct = round(min(100.0, load * 25.0), 1)

    return {
        "status": "ok",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "uptime_seconds": round(time.monotonic() - START_TIME, 1),
        "cpu_percent": cpu_pct,
        "memory_percent": mem_pct,
        "disk_percent": round((disk.used / disk.total) * 100.0, 2) if disk.total else 0.0,
    }


def render_prometheus_metrics(ip_pool_stats: dict, endpoint_pool_stats: dict, active_jobs: int) -> str:
    sys_h = collect_system_health()
    lines = [
        "# HELP cfhub_uptime_seconds Process uptime in seconds",
        "# TYPE cfhub_uptime_seconds gauge",
        f"cfhub_uptime_seconds {sys_h['uptime_seconds']}",
        "# HELP cfhub_cpu_percent Host CPU usage percentage",
        "# TYPE cfhub_cpu_percent gauge",
        f"cfhub_cpu_percent {sys_h['cpu_percent']}",
        "# HELP cfhub_memory_percent Host memory usage percentage",
        "# TYPE cfhub_memory_percent gauge",
        f"cfhub_memory_percent {sys_h['memory_percent']}",
        "# HELP cfhub_ip_pool_healthy Verified healthy IP candidates in pool",
        "# TYPE cfhub_ip_pool_healthy gauge",
        f"cfhub_ip_pool_healthy {ip_pool_stats.get('healthy_verified_entries', 0)}",
        "# HELP cfhub_endpoint_pool_healthy Verified healthy endpoint candidates in pool",
        "# TYPE cfhub_endpoint_pool_healthy gauge",
        f"cfhub_endpoint_pool_healthy {endpoint_pool_stats.get('healthy_verified_entries', 0)}",
        "# HELP cfhub_active_scan_jobs Currently executing scan jobs",
        "# TYPE cfhub_active_scan_jobs gauge",
        f"cfhub_active_scan_jobs {active_jobs}",
    ]
    return "\n".join(lines) + "\n"
