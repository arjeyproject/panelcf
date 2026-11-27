from __future__ import annotations

import asyncio
import ssl
import time
from dataclasses import dataclass

from app.scanners.base import AggregatedScanMetrics, BoundedAdaptiveRunner, ProbeSample, aggregate_samples
from app.security.ssrf import validate_ip_target


@dataclass
class IPScanOptions:
    port: int = 443
    timeout_sec: float = 3.0
    screening_attempts: int = 1
    repeated_attempts: int = 4
    interval_sec: float = 0.2
    test_tls: bool = True
    tls_sni: str | None = "cloudflare.com"
    test_http: bool = False
    http_host: str = "cloudflare.com"
    max_concurrency: int = 32
    allow_private: bool = False
    allowed_cidrs: list[str] | None = None


class IPCandidateScanner:
    """Engine A: Multi-stage real TCP / TLS / HTTP IP candidate scanner."""

    async def probe_once(self, ip: str, opts: IPScanOptions) -> ProbeSample:
        start = time.perf_counter()
        tls_ok: bool | None = None
        http_status: int | None = None
        try:
            ssl_ctx = None
            server_hostname = None
            if opts.test_tls:
                ssl_ctx = ssl.create_default_context()
                ssl_ctx.check_hostname = False
                ssl_ctx.verify_mode = ssl.CERT_NONE
                server_hostname = opts.tls_sni

            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(ip, opts.port, ssl=ssl_ctx, server_hostname=server_hostname),
                timeout=opts.timeout_sec,
            )
            elapsed_ms = round((time.perf_counter() - start) * 1000.0, 3)
            if opts.test_tls:
                tls_ok = True

            if opts.test_http:
                req = f"HEAD / HTTP/1.1\r\nHost: {opts.http_host}\r\nConnection: close\r\n\r\n".encode()
                writer.write(req)
                await asyncio.wait_for(writer.drain(), timeout=opts.timeout_sec)
                status_line = await asyncio.wait_for(reader.readline(), timeout=opts.timeout_sec)
                parts = status_line.decode("latin1", errors="ignore").split()
                if len(parts) >= 2 and parts[1].isdigit():
                    http_status = int(parts[1])

            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
            return ProbeSample(success=True, latency_ms=elapsed_ms, tls_ok=tls_ok, http_status=http_status)
        except Exception as exc:
            return ProbeSample(success=False, error=f"{type(exc).__name__}: {exc}")

    async def scan_ip(self, raw_ip: str, opts: IPScanOptions) -> AggregatedScanMetrics:
        ip_obj = validate_ip_target(raw_ip, allow_private=opts.allow_private, allowed_cidrs=opts.allowed_cidrs)
        ip = str(ip_obj)

        # Stage 2: Bounded initial screening
        screening_samples = [await self.probe_once(ip, opts) for _ in range(max(1, opts.screening_attempts))]
        if not any(s.success for s in screening_samples):
            return aggregate_samples(ip, opts.port, screening_samples)

        # Stage 3: Repeated measurements for shortlisted candidates
        all_samples = list(screening_samples)
        for _ in range(max(0, opts.repeated_attempts)):
            await asyncio.sleep(opts.interval_sec)
            all_samples.append(await self.probe_once(ip, opts))

        return aggregate_samples(ip, opts.port, all_samples)

    async def scan_candidates(
        self,
        raw_ips: list[str],
        opts: IPScanOptions,
        runner: BoundedAdaptiveRunner | None = None,
        on_progress=None,
    ) -> list[AggregatedScanMetrics]:
        # Stage 1: Validation & deduplication
        unique_ips: list[str] = []
        seen: set[str] = set()
        for raw in raw_ips:
            try:
                normalized = str(validate_ip_target(raw, allow_private=opts.allow_private, allowed_cidrs=opts.allowed_cidrs))
            except ValueError:
                continue
            if normalized not in seen:
                seen.add(normalized)
                unique_ips.append(normalized)

        exec_runner = runner or BoundedAdaptiveRunner(max_concurrency=opts.max_concurrency)
        return await exec_runner.run_batch(unique_ips, lambda ip: self.scan_ip(ip, opts), on_progress=on_progress)
