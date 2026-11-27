from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

import httpx


@dataclass
class CloudflareTokenStatus:
    valid: bool
    token_id: str | None
    status: str
    fingerprint: str
    expires_on: str | None = None
    error: str | None = None


class CloudflareAPIClient:
    """Official Cloudflare API v4 client with token validation, rate-limit inspection, and zero secret logging."""

    BASE_URL = "https://api.cloudflare.com/client/v4"

    @staticmethod
    def fingerprint(token: str) -> str:
        return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]

    async def verify_token(self, api_token: str, timeout_sec: float = 10.0) -> CloudflareTokenStatus:
        fp = self.fingerprint(api_token)
        headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}
        try:
            async with httpx.AsyncClient(timeout=timeout_sec) as client:
                resp = await client.get(f"{self.BASE_URL}/user/tokens/verify", headers=headers)
                data = resp.json()
                if resp.status_code == 200 and data.get("success"):
                    res = data.get("result") or {}
                    return CloudflareTokenStatus(
                        valid=res.get("status") == "active",
                        token_id=res.get("id"),
                        status=res.get("status", "unknown"),
                        fingerprint=fp,
                        expires_on=res.get("expires_on"),
                    )
                errors = data.get("errors") or [{"message": f"HTTP {resp.status_code}"}]
                return CloudflareTokenStatus(
                    valid=False,
                    token_id=None,
                    status="invalid",
                    fingerprint=fp,
                    error=errors[0].get("message", "Token verification failed"),
                )
        except Exception as exc:
            return CloudflareTokenStatus(
                valid=False, token_id=None, status="unreachable", fingerprint=fp, error=str(exc)
            )

    async def list_zones(self, api_token: str, page: int = 1, per_page: int = 20) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                f"{self.BASE_URL}/zones",
                headers=headers,
                params={"page": page, "per_page": per_page},
            )
            return {
                "status_code": resp.status_code,
                "rate_limit_remaining": resp.headers.get("X-RateLimit-Remaining"),
                "payload": resp.json(),
            }
