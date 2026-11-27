from __future__ import annotations

import hashlib
import hmac
import json
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qsl


class TelegramAuthError(ValueError):
    pass


@dataclass(frozen=True)
class VerifiedTelegramUser:
    telegram_id: int
    username: str | None
    first_name: str | None
    last_name: str | None
    language_code: str | None
    auth_date: int
    raw_user: dict[str, Any]


def verify_telegram_webapp_init_data(
    init_data: str,
    bot_token: str,
    max_age_seconds: int = 86400,
    now_ts: int | None = None,
) -> VerifiedTelegramUser:
    """Validate Telegram Mini App initData per official HMAC-SHA256 specification."""
    if not init_data or not bot_token:
        raise TelegramAuthError("Missing initData or bot token.")

    parsed = dict(parse_qsl(init_data, strict_parsing=True))
    received_hash = parsed.pop("hash", None)
    if not received_hash:
        raise TelegramAuthError("Missing hash in initData.")

    auth_date_str = parsed.get("auth_date")
    if not auth_date_str or not auth_date_str.isdigit():
        raise TelegramAuthError("Missing or invalid auth_date.")

    auth_date = int(auth_date_str)
    current_ts = int(now_ts if now_ts is not None else time.time())
    if current_ts - auth_date > max_age_seconds or auth_date > current_ts + 300:
        raise TelegramAuthError("Telegram authentication payload has expired or has invalid clock skew.")

    data_check_string = "\n".join(f"{k}={v}" for k, v in sorted(parsed.items()))
    secret_key = hmac.new(b"WebAppData", bot_token.encode("utf-8"), hashlib.sha256).digest()
    computed_hash = hmac.new(secret_key, data_check_string.encode("utf-8"), hashlib.sha256).hexdigest()

    if not hmac.compare_digest(computed_hash, received_hash):
        raise TelegramAuthError("Invalid Telegram WebApp HMAC signature.")

    user_raw = parsed.get("user")
    if not user_raw:
        raise TelegramAuthError("Missing user object in initData.")

    try:
        user_obj = json.loads(user_raw)
        telegram_id = int(user_obj["id"])
    except Exception as exc:
        raise TelegramAuthError("Malformed user JSON in initData.") from exc

    return VerifiedTelegramUser(
        telegram_id=telegram_id,
        username=user_obj.get("username"),
        first_name=user_obj.get("first_name"),
        last_name=user_obj.get("last_name"),
        language_code=user_obj.get("language_code"),
        auth_date=auth_date,
        raw_user=user_obj,
    )
