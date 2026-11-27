from __future__ import annotations

import base64
import io
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from app.core.enums import ProtocolType


@dataclass
class ValidationResult:
    valid: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


@dataclass
class ConfigBuildOutput:
    protocol: ProtocolType
    name: str
    serialized: str
    export_extension: str
    supported_clients: list[str]
    provenance: dict[str, str]
    warnings: list[str] = field(default_factory=list)


def generate_qr_png_base64(content: str) -> str:
    """Generate a PNG QR code encoded as base64 data URI."""
    try:
        import qrcode
        qr = qrcode.QRCode(border=2, box_size=6)
        qr.add_data(content)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception:
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="220" height="40"><text x="8" y="24" font-size="12">QR payload ({len(content)} bytes)</text></svg>'
        return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode("ascii")


class ProtocolAdapter(ABC):
    protocol: ProtocolType

    @abstractmethod
    def validate_params(self, params: dict[str, Any]) -> ValidationResult:
        ...

    @abstractmethod
    def build(self, name: str, params: dict[str, Any]) -> ConfigBuildOutput:
        ...
