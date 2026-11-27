from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "Cloudflare Config Hub"
    app_version: str = "2.0.0"
    environment: Literal["development", "staging", "production"] = "production"
    debug: bool = False
    timezone: str = "Asia/Tehran"

    # API & Security
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    cors_origins: list[str] = Field(default_factory=lambda: ["https://miniapp.example.com", "https://admin.example.com"])
    jwt_secret_key: str = Field(default_factory=lambda: secrets.token_urlsafe(48))
    jwt_algorithm: str = "HS256"
    jwt_access_expire_minutes: int = 60
    encryption_master_key: str = Field(default="")

    # Database & Cache
    database_url: str = "postgresql+asyncpg://cfhub:changeme@postgres:5432/cfhub"
    redis_url: str = "redis://redis:6379/0"

    # Telegram
    telegram_bot_token: str = ""
    telegram_bot_mode: Literal["polling", "webhook"] = "polling"
    telegram_webhook_url: str = ""
    telegram_webhook_secret: str = ""
    telegram_miniapp_url: str = "https://miniapp.example.com"
    telegram_init_data_max_age_seconds: int = 86400
    owner_telegram_ids: list[int] = Field(default_factory=list)

    # Scanner & Pool Policy
    scanner_max_concurrency: int = 32
    scanner_default_timeout_sec: float = 3.0
    scanner_max_targets_per_job: int = 500
    scanner_allow_private_networks: bool = False
    scanner_allowed_cidrs: list[str] = Field(default_factory=list)
    pool_refresh_interval_hours: int = 24
    pool_target_tested_ips: int = 100
    pool_target_tested_endpoints: int = 100
    pool_min_quality_score: float = 55.0
    pool_candidate_ttl_hours: int = 72

    # Rate limits
    api_rate_limit_per_minute: int = 120
    bot_rate_limit_per_minute: int = 30
    auth_rate_limit_per_minute: int = 10

    # Engagement & Maintenance
    maintenance_mode: bool = False
    daily_reward_points: int = 25
    referral_reward_points: int = 50

    @field_validator("cors_origins", "scanner_allowed_cidrs", mode="before")
    @classmethod
    def split_csv(cls, value):
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @field_validator("owner_telegram_ids", mode="before")
    @classmethod
    def split_int_csv(cls, value):
        if isinstance(value, str):
            return [int(item.strip()) for item in value.split(",") if item.strip()]
        return value


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
