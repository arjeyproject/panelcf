# Cloudflare Config Hub (V2)

Production-grade network diagnostics, real IP & endpoint scanning, multi-stage ranking, automated pools, and multi-protocol configuration management accessible via **Telegram Bot**, **Telegram Mini App (Persian RTL + English LTR)**, and **Web Admin Dashboard**.

See [README_EN.md](./README_EN.md) for English documentation and [README_FA.md](./README_FA.md) for Persian (فارسی) documentation.

## Repository Layout
- `backend/` — Python 3.12+, FastAPI, aiogram 3.x, SQLAlchemy 2.x, Alembic, Scanners (IP/Endpoint/Protocol/Proxy), 7-Stage Ranker, Pools, WireGuard/WARP/MASQUE/VLESS/Trojan adapters, Optimizer, RBAC & SSRF Security, Pytest suite.
- `frontend/miniapp/` — React + TypeScript + Vite + Tailwind CSS Telegram Mini App with Persian RTL/English LTR and Graphite/Cyan/Emerald dark UI.
- `frontend/admin_dashboard/` — React + TypeScript + Recharts Web Admin Console.
- `infrastructure/` & `scripts/` — Docker Compose, Nginx reverse proxy, Prometheus config, PostgreSQL backup/restore scripts.
- `docs/` — Architecture, Security, Protocol Limitations, and Deployment guides.
