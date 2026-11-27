# Cloudflare Config Hub — Engineering Guide (English)

## Core Guarantees
1. **Strict Lifecycle Transparency:** Every candidate tracks explicit states (`candidate` → `discovered` → `validated` → `tested` → `compatible` → `performance_ranked` → `configuration_generated` → `connection_verified`).
2. **Zero Fabricated Metrics:** Pool refresh cycles target 100 tested IPs and 100 tested endpoints every 24 hours, report exact verified counts, and never lower quality thresholds to pad numbers.
3. **Protocol Honesty:**
   - HTTP/TCP reachability never claims WireGuard/WARP UDP compatibility.
   - TLS handshake success never claims VLESS UUID or Trojan password authentication succeeded.
   - Cloudflare HTTP anycast IPs are never treated as WireGuard or WARP server credentials.
   - YouTube promotional workflows use explicit user acknowledgment rather than falsely claiming Telegram API verifies YouTube subscriptions.

## Quick Start
```bash
cp .env.example .env
# Edit .env with real secrets and TELEGRAM_BOT_TOKEN
docker compose up -d --build
```
