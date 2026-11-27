from __future__ import annotations

from datetime import datetime, timezone
from app.core.enums import CandidateLifecycleState, ProtocolType  # noqa: F401

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    JSON,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class CandidateLifecycleState(str, Enum):
    CANDIDATE = "candidate"
    DISCOVERED = "discovered"
    VALIDATED = "validated"
    TESTED = "tested"
    COMPATIBLE = "compatible"
    PERFORMANCE_RANKED = "performance_ranked"
    CONFIGURATION_GENERATED = "configuration_generated"
    CONNECTION_VERIFIED = "connection_verified"


class ProtocolType(str, Enum):
    WIREGUARD = "wireguard"
    WARP = "warp"
    MASQUE = "masque"
    VLESS = "vless"
    TROJAN = "trojan"


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    telegram_id: Mapped[int] = mapped_column(BigInteger, unique=True, index=True, nullable=False)
    username: Mapped[str | None] = mapped_column(String(64), index=True)
    first_name: Mapped[str | None] = mapped_column(String(128))
    last_name: Mapped[str | None] = mapped_column(String(128))
    language: Mapped[str] = mapped_column(String(8), default="fa", nullable=False)
    role: Mapped[str] = mapped_column(String(24), default="user", nullable=False)
    is_banned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_restricted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    referral_code: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    referred_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    reward_points: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    youtube_promo_acknowledged: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_active_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)

    configs: Mapped[list[ConfigurationProfile]] = relationship(back_populates="user", cascade="all, delete-orphan")


class AdminAccount(Base):
    __tablename__ = "admin_accounts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(256), nullable=False)
    role: Mapped[str] = mapped_column(String(24), default="admin", nullable=False)
    telegram_id: Mapped[int | None] = mapped_column(BigInteger, unique=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class CloudflareCredential(Base):
    __tablename__ = "cloudflare_credentials"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    label: Mapped[str] = mapped_column(String(64), default="default")
    encrypted_token: Mapped[str] = mapped_column(Text, nullable=False)
    token_fingerprint: Mapped[str] = mapped_column(String(32), nullable=False)
    status: Mapped[str] = mapped_column(String(24), default="unverified", nullable=False)
    permissions_json: Mapped[dict] = mapped_column(JSON, default=dict)
    last_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class IPCandidate(Base):
    __tablename__ = "ip_candidates"
    __table_args__ = (
        UniqueConstraint("ip_address", "port", name="uq_ip_candidate_ip_port"),
        Index("ix_ip_candidates_score_state", "lifecycle_state", "overall_score"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ip_address: Mapped[str] = mapped_column(String(64), index=True, nullable=False)
    ip_version: Mapped[int] = mapped_column(Integer, default=4, nullable=False)
    port: Mapped[int] = mapped_column(Integer, default=443, nullable=False)
    source: Mapped[str] = mapped_column(String(64), default="manual", nullable=False)
    asn: Mapped[str | None] = mapped_column(String(32))
    country: Mapped[str | None] = mapped_column(String(8))
    lifecycle_state: Mapped[str] = mapped_column(String(32), default=CandidateLifecycleState.CANDIDATE, index=True)
    overall_score: Mapped[float] = mapped_column(Float, default=0.0, index=True)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    avg_latency_ms: Mapped[float | None] = mapped_column(Float)
    jitter_ms: Mapped[float | None] = mapped_column(Float)
    success_rate: Mapped[float] = mapped_column(Float, default=0.0)
    stability_score: Mapped[float] = mapped_column(Float, default=0.0)
    compatible_protocols: Mapped[list] = mapped_column(JSON, default=list)
    total_tests: Mapped[int] = mapped_column(Integer, default=0)
    successful_tests: Mapped[int] = mapped_column(Integer, default=0)
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class EndpointCandidate(Base):
    __tablename__ = "endpoint_candidates"
    __table_args__ = (
        UniqueConstraint("host", "port", "protocol_hint", name="uq_endpoint_host_port_proto"),
        Index("ix_endpoint_score_state", "lifecycle_state", "overall_score"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    host: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    port: Mapped[int] = mapped_column(Integer, default=443, nullable=False)
    scheme: Mapped[str] = mapped_column(String(16), default="tls", nullable=False)
    protocol_hint: Mapped[str] = mapped_column(String(32), default="generic", nullable=False)
    source: Mapped[str] = mapped_column(String(64), default="manual", nullable=False)
    dns_resolved: Mapped[bool] = mapped_column(Boolean, default=False)
    tls_verified: Mapped[bool] = mapped_column(Boolean, default=False)
    lifecycle_state: Mapped[str] = mapped_column(String(32), default=CandidateLifecycleState.CANDIDATE, index=True)
    overall_score: Mapped[float] = mapped_column(Float, default=0.0, index=True)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    avg_latency_ms: Mapped[float | None] = mapped_column(Float)
    jitter_ms: Mapped[float | None] = mapped_column(Float)
    success_rate: Mapped[float] = mapped_column(Float, default=0.0)
    stability_score: Mapped[float] = mapped_column(Float, default=0.0)
    compatible_protocols: Mapped[list] = mapped_column(JSON, default=list)
    total_tests: Mapped[int] = mapped_column(Integer, default=0)
    successful_tests: Mapped[int] = mapped_column(Integer, default=0)
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class ProxyCandidate(Base):
    __tablename__ = "proxy_candidates"
    __table_args__ = (UniqueConstraint("host", "port", "proxy_type", name="uq_proxy_host_port_type"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    host: Mapped[str] = mapped_column(String(255), nullable=False)
    port: Mapped[int] = mapped_column(Integer, nullable=False)
    proxy_type: Mapped[str] = mapped_column(String(16), default="http", nullable=False)
    source: Mapped[str] = mapped_column(String(64), default="manual")
    is_untrusted: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    lifecycle_state: Mapped[str] = mapped_column(String(32), default=CandidateLifecycleState.CANDIDATE)
    overall_score: Mapped[float] = mapped_column(Float, default=0.0)
    avg_latency_ms: Mapped[float | None] = mapped_column(Float)
    success_rate: Mapped[float] = mapped_column(Float, default=0.0)
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class ConfigurationProfile(Base):
    __tablename__ = "configuration_profiles"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    protocol: Mapped[str] = mapped_column(String(24), index=True, nullable=False)
    lifecycle_state: Mapped[str] = mapped_column(String(32), default=CandidateLifecycleState.CONFIGURATION_GENERATED)
    parameters_json: Mapped[dict] = mapped_column(JSON, default=dict)
    serialized_config: Mapped[str] = mapped_column(Text, nullable=False)
    provenance_json: Mapped[dict] = mapped_column(JSON, default=dict)
    quality_score: Mapped[float | None] = mapped_column(Float)
    is_favorite: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    user: Mapped[User] = relationship(back_populates="configs")


class ScanJob(Base):
    __tablename__ = "scan_jobs"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    job_type: Mapped[str] = mapped_column(String(32), index=True)  # ip_scan, endpoint_scan, proxy_scan, pool_refresh
    initiated_by_user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    status: Mapped[str] = mapped_column(String(24), default="queued", index=True)
    total_targets: Mapped[int] = mapped_column(Integer, default=0)
    completed_targets: Mapped[int] = mapped_column(Integer, default=0)
    passed_targets: Mapped[int] = mapped_column(Integer, default=0)
    failed_targets: Mapped[int] = mapped_column(Integer, default=0)
    config_json: Mapped[dict] = mapped_column(JSON, default=dict)
    error_message: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class ScanResult(Base):
    __tablename__ = "scan_results"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    job_id: Mapped[str] = mapped_column(ForeignKey("scan_jobs.id", ondelete="CASCADE"), index=True)
    target: Mapped[str] = mapped_column(String(255), index=True)
    target_type: Mapped[str] = mapped_column(String(24))
    success: Mapped[bool] = mapped_column(Boolean, default=False)
    latency_ms: Mapped[float | None] = mapped_column(Float)
    jitter_ms: Mapped[float | None] = mapped_column(Float)
    metrics_json: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class RequiredChannel(Base):
    __tablename__ = "required_channels"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    platform: Mapped[str] = mapped_column(String(16), default="telegram")  # telegram | youtube_promo
    channel_identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    title: Mapped[str] = mapped_column(String(128), nullable=False)
    join_url: Mapped[str] = mapped_column(String(256), nullable=False)
    is_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    enforce_verification: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Broadcast(Base):
    __tablename__ = "broadcasts"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    admin_id: Mapped[int | None] = mapped_column(ForeignKey("admin_accounts.id", ondelete="SET NULL"))
    audience: Mapped[str] = mapped_column(String(32), default="all")
    message_text: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(24), default="draft")
    sent_count: Mapped[int] = mapped_column(Integer, default=0)
    failed_count: Mapped[int] = mapped_column(Integer, default=0)
    scheduled_for: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class SupportTicket(Base):
    __tablename__ = "support_tickets"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    subject: Mapped[str] = mapped_column(String(160), nullable=False)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(24), default="open", index=True)
    admin_reply: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    actor_type: Mapped[str] = mapped_column(String(24), nullable=False)  # admin | user | system
    actor_id: Mapped[str] = mapped_column(String(64), index=True)
    action: Mapped[str] = mapped_column(String(96), index=True, nullable=False)
    resource: Mapped[str] = mapped_column(String(96), nullable=False)
    details_json: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class SystemSetting(Base):
    __tablename__ = "system_settings"

    key: Mapped[str] = mapped_column(String(96), primary_key=True)
    value_json: Mapped[dict] = mapped_column(JSON, default=dict)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
