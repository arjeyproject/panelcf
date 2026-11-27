from __future__ import annotations

from enum import Enum


class RoleName(str, Enum):
    OWNER = "owner"
    ADMIN = "admin"
    MODERATOR = "moderator"
    USER = "user"


ROLE_PERMISSIONS: dict[RoleName, set[str]] = {
    RoleName.OWNER: {
        "*",
        "users:read", "users:manage", "users:delete",
        "scanners:control", "pools:manage", "cloudflare:manage",
        "channels:manage", "broadcasts:send", "system:manage",
        "security:audit", "admins:manage", "backups:manage",
    },
    RoleName.ADMIN: {
        "users:read", "users:manage",
        "scanners:control", "pools:manage", "cloudflare:manage",
        "channels:manage", "broadcasts:send", "security:audit",
    },
    RoleName.MODERATOR: {
        "users:read", "users:manage", "channels:manage", "support:manage",
    },
    RoleName.USER: {
        "self:read", "self:configs", "self:scan",
    },
}


def has_permission(role: str, permission: str) -> bool:
    try:
        role_enum = RoleName(role)
    except ValueError:
        return False
    perms = ROLE_PERMISSIONS.get(role_enum, set())
    return "*" in perms or permission in perms
