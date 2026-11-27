from __future__ import annotations

import hashlib
import hmac
import json
import time
from urllib.parse import urlencode

import pytest

from app.core.logging import redact_secrets
from app.security.crypto import SecretVault, create_access_token, decode_access_token, hash_password, verify_password
from app.security.rbac import has_permission
from app.security.ssrf import TargetPolicyError, parse_and_validate_endpoint, validate_ip_target
from app.security.telegram_auth import TelegramAuthError, verify_telegram_webapp_init_data


def _sign_init_data(bot_token: str, user: dict, auth_date: int) -> str:
    payload = {"auth_date": str(auth_date), "query_id": "AAHdF6IQAAAAAN0XohDhrOrc", "user": json.dumps(user, separators=(",", ":"))}
    dcs = "\n".join(f"{k}={v}" for k, v in sorted(payload.items()))
    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    payload["hash"] = hmac.new(secret, dcs.encode(), hashlib.sha256).hexdigest()
    return urlencode(payload)


def test_ssrf_blocks_private_and_metadata_targets():
    for blocked in ("127.0.0.1", "10.0.0.5", "192.168.1.1", "169.254.169.254", "100.64.0.1", "::1"):
        with pytest.raises(TargetPolicyError):
            validate_ip_target(blocked)
    assert str(validate_ip_target("1.1.1.1")) == "1.1.1.1"
    with pytest.raises(TargetPolicyError):
        parse_and_validate_endpoint("http://169.254.169.254/latest/meta-data/")


def test_telegram_init_data_hmac_validation():
    bot_token = "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ123456789"
    now = int(time.time())
    init_data = _sign_init_data(bot_token, {"id": 998877, "username": "cybermux", "language_code": "fa"}, now)
    verified = verify_telegram_webapp_init_data(init_data, bot_token, now_ts=now)
    assert verified.telegram_id == 998877
    assert verified.username == "cybermux"

    # Tampered signature must fail
    tampered = init_data[:-4] + "0000"
    with pytest.raises(TelegramAuthError):
        verify_telegram_webapp_init_data(tampered, bot_token, now_ts=now)

    # Expired payload must fail
    with pytest.raises(TelegramAuthError):
        verify_telegram_webapp_init_data(init_data, bot_token, max_age_seconds=60, now_ts=now + 120)


def test_crypto_vault_passwords_jwt_and_redaction():
    vault = SecretVault("super-strong-master-secret-key")
    ct = vault.encrypt("cf_live_secret_token_xyz")
    assert "cf_live_secret_token_xyz" not in ct
    assert vault.decrypt(ct) == "cf_live_secret_token_xyz"

    hashed = hash_password("AdminPass!2026")
    assert verify_password("AdminPass!2026", hashed)
    assert not verify_password("WrongPass", hashed)

    tok = create_access_token("admin1", "admin", "jwt-secret")
    claims = decode_access_token(tok, "jwt-secret")
    assert claims["sub"] == "admin1"
    assert has_permission("owner", "backups:manage")
    assert not has_permission("moderator", "backups:manage")

    redacted = redact_secrets("Authorization: Bearer abcdef12345 token=mysecret999")
    assert "abcdef12345" not in redacted
    assert "mysecret999" not in redacted
