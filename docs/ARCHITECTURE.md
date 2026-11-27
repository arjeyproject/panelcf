# System Architecture

- **Ingress:** Nginx terminates TLS and routes `/api/*` to FastAPI, `/admin/*` to Admin Dashboard, and `/` to the Telegram Mini App.
- **Application Layer:** FastAPI REST API v1 + aiogram 3.x Telegram Bot sharing core domain modules (`scanners`, `ranking`, `pool`, `protocols`, `services`, `security`).
- **Data Layer:** PostgreSQL 16 (SQLAlchemy 2.x async + Alembic) for durable entities and audit trails; Redis 7 for distributed job locks, rate limiting, and caching.
- **Automation:** APScheduler with Redis distributed locks runs 24h IP/Endpoint pool refreshes and 6h expiration cleanups without overlapping executions.
