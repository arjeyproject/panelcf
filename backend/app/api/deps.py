from __future__ import annotations

from fastapi import Header, HTTPException, status

from app.core.config import get_settings
from app.security.crypto import decode_access_token
from app.security.rbac import has_permission
from app.security.telegram_auth import TelegramAuthError, VerifiedTelegramUser, verify_telegram_webapp_init_data


def get_current_miniapp_user(x_telegram_init_data: str = Header(..., alias="X-Telegram-Init-Data")) -> VerifiedTelegramUser:
    settings = get_settings()
    try:
        return verify_telegram_webapp_init_data(
            init_data=x_telegram_init_data,
            bot_token=settings.telegram_bot_token,
            max_age_seconds=settings.telegram_init_data_max_age_seconds,
        )
    except TelegramAuthError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc


def require_admin_permission(permission: str):
    def _dep(authorization: str = Header(..., alias="Authorization")) -> dict:
        if not authorization.startswith("Bearer "):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing Bearer token.")
        token = authorization.removeprefix("Bearer ").strip()
        settings = get_settings()
        try:
            payload = decode_access_token(token, settings.jwt_secret_key, settings.jwt_algorithm)
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired admin token.") from exc
        role = str(payload.get("role", "user"))
        if not has_permission(role, permission):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Missing required permission: {permission}")
        return payload

    return _dep
