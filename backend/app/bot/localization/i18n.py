from __future__ import annotations

import json
from pathlib import Path

_DIR = Path(__file__).parent
_CACHE: dict[str, dict[str, str]] = {
    "fa": json.loads((_DIR / "fa.json").read_text(encoding="utf-8")),
    "en": json.loads((_DIR / "en.json").read_text(encoding="utf-8")),
}


def t(key: str, lang: str = "fa") -> str:
    bundle = _CACHE.get(lang, _CACHE["fa"])
    return bundle.get(key, _CACHE["en"].get(key, key))
