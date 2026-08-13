from __future__ import annotations

import base64
import binascii
import re

_CANONICAL = re.compile(r"^[A-Za-z0-9_-]+$")


class Base64UrlError(ValueError):
    """Raised when a value is not canonical unpadded base64url."""


def encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def decode(value: str, *, field: str = "value", allow_empty: bool = False) -> bytes:
    if value == "" and allow_empty:
        return b""
    if not value or _CANONICAL.fullmatch(value) is None:
        raise Base64UrlError(f"{field} must be unpadded base64url")
    try:
        decoded = base64.b64decode(
            value + "=" * ((4 - len(value) % 4) % 4), altchars=b"-_", validate=True
        )
    except (binascii.Error, ValueError) as error:
        raise Base64UrlError(f"{field} must be unpadded base64url") from error
    if encode(decoded) != value:
        raise Base64UrlError(f"{field} is not canonical base64url")
    return decoded
