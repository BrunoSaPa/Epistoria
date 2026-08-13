from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel


def json_bytes(value: BaseModel | dict[str, Any] | list[Any]) -> bytes:
    serializable: Any
    if isinstance(value, BaseModel):
        serializable = value.model_dump(mode="json", by_alias=True, exclude_none=True)
    else:
        serializable = value
    return json.dumps(
        serializable,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
