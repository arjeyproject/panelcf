from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

from app.api.deps import require_admin_permission
from app.api.state import active_scan_jobs, audit_events, endpoint_pool, ip_pool, saved_profiles
from app.cloudflare.client import CloudflareAPIClient
from app.core.config import get_settings
from app.core.enums import ProtocolType
from app.protocols.base import generate_qr_png_base64
from app.protocols.registry import get_adapter
from app.ranking.ip_ranker import CandidateMetricsInput, SelectionPreset
from app.scanners.ip_scanner import IPCandidateScanner, IPScanOptions
from app.scanners.protocol_tests import ProtocolCompatibilityTester
from app.services.monitoring import collect_system_health, render_prometheus_metrics
from app.services.optimizer import ConfigurationOptimizer, OptimizationCandidate

router = APIRouter(prefix="/api/v1")


class ConfigGenerateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    protocol: ProtocolType
    params: dict[str, Any]
    include_qr: bool = True


class PoolIngestRequest(BaseModel):
    targets: list[str] = Field(min_length=1, max_length=500)
    default_port: int = Field(default=443, ge=1, le=65535)
    source: str = "manual"


class CloudflareVerifyRequest(BaseModel):
    api_token: str = Field(min_length=10)


class IPScanRequest(BaseModel):
    ips: list[str] = Field(min_length=1, max_length=200)
    port: int = Field(default=443, ge=1, le=65535)
    test_tls: bool = True
    test_http: bool = False
    repeated_attempts: int = Field(default=3, ge=1, le=10)


@router.get("/health")
async def health():
    return {
        "service": "cloudflare-config-hub",
        "system": collect_system_health(),
        "pools": {"ip": ip_pool.stats(), "endpoint": endpoint_pool.stats()},
        "active_jobs": len(active_scan_jobs),
    }


@router.get("/metrics", response_class=PlainTextResponse)
async def metrics():
    return render_prometheus_metrics(ip_pool.stats(), endpoint_pool.stats(), len(active_scan_jobs))


@router.post("/configs/generate")
async def generate_config(req: ConfigGenerateRequest):
    adapter = get_adapter(req.protocol)
    try:
        output = adapter.build(req.name, req.params)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    compat = ProtocolCompatibilityTester().evaluate(req.protocol, syntax_valid=True)
    profile_id = str(uuid.uuid4())
    record = {
        "id": profile_id,
        "name": output.name,
        "protocol": output.protocol.value,
        "serialized": output.serialized,
        "export_extension": output.export_extension,
        "supported_clients": output.supported_clients,
        "provenance": output.provenance,
        "raw_params": req.params,
        "lifecycle_state": compat.recommended_lifecycle_state.value,
        "verified_checks": compat.verified_checks,
        "unverified_checks": compat.unverified_checks,
        "warnings": output.warnings + compat.warnings,
        "qr_data_uri": generate_qr_png_base64(output.serialized) if req.include_qr else None,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    saved_profiles[profile_id] = record
    return record


@router.get("/configs")
async def list_configs():
    return {"items": list(saved_profiles.values()), "total": len(saved_profiles)}


@router.post("/optimizer/analyze")
async def optimize_configs(preset: SelectionPreset = Query(default=SelectionPreset.BALANCED)):
    optimizer = ConfigurationOptimizer()
    candidates = [
        OptimizationCandidate(
            profile_id=p["id"],
            name=p["name"],
            protocol=ProtocolType(p["protocol"]),
            params=p.get("raw_params", {}),
            measured_metrics=None,
        )
        for p in saved_profiles.values()
    ]
    return {"preset": preset.value, "results": [d.__dict__ for d in optimizer.analyze(candidates, preset=preset)]}


@router.get("/pools/{pool_type}")
async def get_pool(pool_type: str, export_fmt: str | None = None):
    pool = ip_pool if pool_type == "ip" else endpoint_pool if pool_type == "endpoint" else None
    if pool is None:
        raise HTTPException(status_code=404, detail="Unknown pool type. Use 'ip' or 'endpoint'.")
    if export_fmt in {"json", "csv", "txt"}:
        return PlainTextResponse(pool.export(export_fmt))
    return {"stats": pool.stats(), "healthy": [e.__dict__ for e in pool.get_healthy_entries()]}


@router.post("/pools/{pool_type}/ingest")
async def ingest_pool(
    pool_type: str,
    req: PoolIngestRequest,
    admin=Depends(require_admin_permission("pools:manage")),
):
    pool = ip_pool if pool_type == "ip" else endpoint_pool if pool_type == "endpoint" else None
    if pool is None:
        raise HTTPException(status_code=404, detail="Unknown pool type.")
    parsed_items = []
    for raw in req.targets:
        if ":" in raw and not raw.startswith("[") and raw.count(":") == 1:
            host, p = raw.rsplit(":", 1)
            parsed_items.append((host, int(p) if p.isdigit() else req.default_port))
        else:
            parsed_items.append((raw, req.default_port))
    summary = pool.ingest_candidates(parsed_items, source=req.source)
    audit_events.append({
        "actor": admin.get("sub"),
        "action": f"pool.ingest.{pool_type}",
        "summary": summary,
        "at": datetime.now(timezone.utc).isoformat(),
    })
    return {"pool": pool_type, "ingested": summary, "stats": pool.stats()}


@router.post("/scanners/ip/run")
async def run_ip_scan(req: IPScanRequest):
    settings = get_settings()
    job_id = str(uuid.uuid4())
    active_scan_jobs[job_id] = {"status": "running", "total": len(req.ips), "completed": 0}
    scanner = IPCandidateScanner()
    opts = IPScanOptions(
        port=req.port,
        timeout_sec=settings.scanner_default_timeout_sec,
        repeated_attempts=req.repeated_attempts,
        test_tls=req.test_tls,
        test_http=req.test_http,
        max_concurrency=min(settings.scanner_max_concurrency, 16),
        allow_private=settings.scanner_allow_private_networks,
        allowed_cidrs=settings.scanner_allowed_cidrs or None,
    )
    try:
        results = await scanner.scan_candidates(req.ips, opts)
        metrics_inputs = [
            CandidateMetricsInput(
                identifier=r.target,
                port=r.port,
                success_rate=r.success_rate,
                avg_latency_ms=r.avg_latency_ms,
                min_latency_ms=r.min_latency_ms,
                max_latency_ms=r.max_latency_ms,
                jitter_ms=r.jitter_ms,
                stability_score=r.stability_score,
                total_observations=r.total_attempts,
                failed_observations=r.failure_count,
                testing_diversity=1 + int(r.tls_verified) + int(r.http_verified),
                last_tested_at=datetime.now(timezone.utc),
            )
            for r in results
        ]
        refresh_report = ip_pool.apply_scan_results(metrics_inputs)
        return {
            "job_id": job_id,
            "tested": len(results),
            "pool_report": refresh_report.__dict__,
            "results": [
                {
                    "ip": r.target,
                    "port": r.port,
                    "success_rate": r.success_rate,
                    "avg_latency_ms": r.avg_latency_ms,
                    "jitter_ms": r.jitter_ms,
                    "stability_score": r.stability_score,
                    "tls_verified": r.tls_verified,
                }
                for r in results
            ],
        }
    finally:
        active_scan_jobs.pop(job_id, None)


@router.post("/cloudflare/verify-token")
async def verify_cloudflare_token(req: CloudflareVerifyRequest):
    client = CloudflareAPIClient()
    status = await client.verify_token(req.api_token)
    return status.__dict__


@router.get("/admin/audit-logs")
async def get_audit_logs(admin=Depends(require_admin_permission("security:audit"))):
    return {"actor": admin.get("sub"), "events": audit_events[-200:]}
