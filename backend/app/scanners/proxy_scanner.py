from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass

from app.scanners.base import AggregatedScanMetrics, ProbeSample, aggregate_samples
from app.security.ssrf import parse_and_validate_endpoint


@dataclass
class ProxyCandidateInput:
    host: str
    port: int
    proxy_type: str = "http"  # http | https | socks5


class UntrustedProxyScanner:
    """
    Dedicated candidate proxy tester.
    Security invariant: Public proxies are ALWAYS treated as untrusted infrastructure.
    Never transmit user credentials, API tokens, or internal cookies through proxy candidates.
    """

    async def test_proxy_connect(self, candidate: ProxyCandidateInput, timeout_sec: float = 4.0) -> AggregatedScanMetrics:
        host, port, _ = parse_and_validate_endpoint(f"{candidate.host}:{candidate.port}", allow_private=False, resolve_dns=True)
        samples: list[ProbeSample] = []
        for _ in range(2):
            start = time.perf_counter()
            try:
                reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=timeout_sec)
                if candidate.proxy_type == "socks5":
                    # RFC 1928 greeting: VER=5, NMETHODS=1, METHOD=0 (no auth)
                    writer.write(b"\x05\x01\x00")
                    await asyncio.wait_for(writer.drain(), timeout=timeout_sec)
                    resp = await asyncio.wait_for(reader.readexactly(2), timeout=timeout_sec)
                    ok = resp[0] == 5 and resp[1] == 0
                else:
                    ok = True
                elapsed = round((time.perf_counter() - start) * 1000.0, 3)
                writer.close()
                try:
                    await writer.wait_closed()
                except Exception:
                    pass
                samples.append(ProbeSample(success=ok, latency_ms=elapsed))
            except Exception as exc:
                samples.append(ProbeSample(success=False, error=str(exc)))
        return aggregate_samples(host, port, samples)
