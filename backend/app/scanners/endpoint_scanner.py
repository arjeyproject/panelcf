from __future__ import annotations

import asyncio
import socket
import ssl
import time
from dataclasses import dataclass

from app.scanners.base import AggregatedScanMetrics, BoundedAdaptiveRunner, ProbeSample, aggregate_samples
from app.security.ssrf import parse_and_validate_endpoint, validate_ip_target


@dataclass
class EndpointScanOptions:
    timeout_sec: float = 3.5
    repeated_attempts: int = 3
    interval_sec: float = 0.2
    verify_tls: bool = True
    test_http: bool = False
    max_concurrency: int = 24
    allow_private: bool = False
    allowed_cidrs: list[str] | None = None


@dataclass
class EndpointScanReport:
    raw_endpoint: str
    host: str
    port: int
    scheme: str
    dns_resolved: bool
    resolved_ips: list[str]
    metrics: AggregatedScanMetrics


class EndpointScanner:
    """Engine B: Independent DNS + TCP + TLS + HTTP endpoint validation engine."""

    async def resolve_host(self, host: str, port: int, opts: EndpointScanOptions) -> list[str]:
        loop = asyncio.get_running_loop()
        infos = await asyncio.wait_for(
            loop.getaddrinfo(host, port, type=socket.SOCK_STREAM),
            timeout=opts.timeout_sec,
        )
        valid_ips: list[str] = []
        for info in infos:
            ip = info[4][0]
            validate_ip_target(ip, allow_private=opts.allow_private, allowed_cidrs=opts.allowed_cidrs)
            if ip not in valid_ips:
                valid_ips.append(ip)
        return valid_ips

    async def probe_once(self, host: str, target_ip: str, port: int, opts: EndpointScanOptions) -> ProbeSample:
        start = time.perf_counter()
        tls_ok: bool | None = None
        http_status: int | None = None
        try:
            ssl_ctx = ssl.create_default_context() if opts.verify_tls else None
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(
                    target_ip,
                    port,
                    ssl=ssl_ctx,
                    server_hostname=host if opts.verify_tls else None,
                ),
                timeout=opts.timeout_sec,
            )
            elapsed_ms = round((time.perf_counter() - start) * 1000.0, 3)
            if opts.verify_tls:
                tls_ok = True

            if opts.test_http:
                writer.write(f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
                await asyncio.wait_for(writer.drain(), timeout=opts.timeout_sec)
                line = await asyncio.wait_for(reader.readline(), timeout=opts.timeout_sec)
                parts = line.decode("latin1", errors="ignore").split()
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

    async def scan_endpoint(self, raw_endpoint: str, opts: EndpointScanOptions) -> EndpointScanReport:
        host, port, scheme = parse_and_validate_endpoint(
            raw_endpoint,
            allow_private=opts.allow_private,
            allowed_cidrs=opts.allowed_cidrs,
            resolve_dns=False,
        )
        try:
            resolved_ips = await self.resolve_host(host, port, opts)
        except Exception as exc:
            empty = aggregate_samples(host, port, [ProbeSample(success=False, error=str(exc))])
            return EndpointScanReport(raw_endpoint, host, port, scheme, False, [], empty)

        target_ip = resolved_ips[0]
        samples: list[ProbeSample] = []
        for idx in range(max(1, opts.repeated_attempts)):
            if idx > 0:
                await asyncio.sleep(opts.interval_sec)
            sample = await self.probe_once(host, target_ip, port, opts)
            samples.append(sample)
            if idx == 0 and not sample.success:
                break

        return EndpointScanReport(
            raw_endpoint=raw_endpoint,
            host=host,
            port=port,
            scheme=scheme,
            dns_resolved=True,
            resolved_ips=resolved_ips,
            metrics=aggregate_samples(host, port, samples),
        )

    async def scan_batch(
        self,
        raw_endpoints: list[str],
        opts: EndpointScanOptions,
        runner: BoundedAdaptiveRunner | None = None,
        on_progress=None,
    ) -> list[EndpointScanReport]:
        deduped = list(dict.fromkeys(e.strip() for e in raw_endpoints if e.strip()))
        exec_runner = runner or BoundedAdaptiveRunner(max_concurrency=opts.max_concurrency)
        return await exec_runner.run_batch(deduped, lambda ep: self.scan_endpoint(ep, opts), on_progress=on_progress)
