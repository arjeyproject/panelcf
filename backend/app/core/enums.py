from __future__ import annotations

from enum import Enum


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
