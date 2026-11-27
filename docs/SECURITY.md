# Security Model

1. **SSRF & Scan Scope Defense (`app/security/ssrf.py`):** Blocks RFC1918, loopback, link-local, CG-NAT (`100.64.0.0/10`), multicast, reserved ranges, and cloud metadata (`169.254.169.254`) by default; defends against DNS rebinding by validating resolved IPs prior to connecting.
2. **Telegram Mini App Authentication (`app/security/telegram_auth.py`):** Verifies `initData` via official `WebAppData` HMAC-SHA256 derivation and enforces `auth_date` freshness on the server.
3. **Secret Management (`app/security/crypto.py`, `app/core/logging.py`):** Encrypts stored Cloudflare API tokens with Fernet symmetric encryption and redacts Bearer tokens, passwords, and Telegram bot tokens from structured JSON logs.
4. **Untrusted Proxy Isolation (`app/scanners/proxy_scanner.py`):** Public proxy candidates are strictly isolated and never used to transmit credentials or administrative requests.
5. **RBAC & Audit Logs (`app/security/rbac.py`):** Enforces `owner`, `admin`, `moderator`, and `user` permissions server-side on all administrative endpoints.
