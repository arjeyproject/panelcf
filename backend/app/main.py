from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.routes import router as v1_router
from app.api.state import api_rate_limiter
from app.core.config import get_settings
from app.core.logging import configure_logging


def create_app() -> FastAPI:
    configure_logging()
    settings = get_settings()
    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        docs_url="/api/docs",
        redoc_url="/api/redoc",
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def security_and_rate_limit(request: Request, call_next):
        client_ip = request.client.host if request.client else "unknown"
        allowed, remaining = api_rate_limiter.allow(f"ip:{client_ip}")
        if not allowed:
            return JSONResponse(status_code=429, content={"detail": "Rate limit exceeded."})
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["X-RateLimit-Remaining"] = str(remaining)
        return response

    app.include_router(v1_router)
    return app


app = create_app()
