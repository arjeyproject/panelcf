from __future__ import annotations

from app.core.enums import ProtocolType
from app.protocols.base import ProtocolAdapter
from app.protocols.masque import MASQUEAdapter
from app.protocols.trojan import TrojanAdapter
from app.protocols.vless import VLESSAdapter
from app.protocols.warp import CloudflareWARPAdapter
from app.protocols.wireguard import WireGuardAdapter

ADAPTERS: dict[ProtocolType, ProtocolAdapter] = {
    ProtocolType.WIREGUARD: WireGuardAdapter(),
    ProtocolType.WARP: CloudflareWARPAdapter(),
    ProtocolType.MASQUE: MASQUEAdapter(),
    ProtocolType.VLESS: VLESSAdapter(),
    ProtocolType.TROJAN: TrojanAdapter(),
}


def get_adapter(protocol: ProtocolType | str) -> ProtocolAdapter:
    proto = ProtocolType(protocol)
    return ADAPTERS[proto]
