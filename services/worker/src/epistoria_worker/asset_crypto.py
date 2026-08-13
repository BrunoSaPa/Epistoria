from __future__ import annotations

import hashlib
import hmac
import io
import struct
from typing import BinaryIO
from uuid import UUID

from nacl.bindings import (
    crypto_secretstream_xchacha20poly1305_ABYTES,
    crypto_secretstream_xchacha20poly1305_HEADERBYTES,
    crypto_secretstream_xchacha20poly1305_init_pull,
    crypto_secretstream_xchacha20poly1305_init_push,
    crypto_secretstream_xchacha20poly1305_KEYBYTES,
    crypto_secretstream_xchacha20poly1305_pull,
    crypto_secretstream_xchacha20poly1305_push,
    crypto_secretstream_xchacha20poly1305_state,
    crypto_secretstream_xchacha20poly1305_TAG_FINAL,
    crypto_secretstream_xchacha20poly1305_TAG_MESSAGE,
)
from nacl.exceptions import CryptoError as SodiumCryptoError

from .crypto import dedupe_key

MAGIC = b"EPISTORIA-ASSET\x00"
FORMAT_VERSION = 1
CHUNK_BYTES = 64 * 1024
_PREFIX_BYTES = len(MAGIC) + 1 + crypto_secretstream_xchacha20poly1305_HEADERBYTES
_MAX_CIPHER_CHUNK = CHUNK_BYTES + crypto_secretstream_xchacha20poly1305_ABYTES


class AssetCryptoError(ValueError):
    """Raised when an encrypted asset is malformed, truncated, or unauthenticated."""


def _require_key(key: bytes) -> None:
    if len(key) != crypto_secretstream_xchacha20poly1305_KEYBYTES:
        raise AssetCryptoError("asset key must be 32 bytes")


def plaintext_dedupe_tag(plaintext: bytes, *, account_key: bytes, account_id: UUID | str) -> str:
    key = dedupe_key(account_key, account_id)
    return hmac.digest(key, hashlib.sha256(plaintext).digest(), "sha256").hex()


def encrypt_stream(source: BinaryIO, destination: BinaryIO, *, key: bytes) -> int:
    _require_key(key)
    state = crypto_secretstream_xchacha20poly1305_state()
    header = crypto_secretstream_xchacha20poly1305_init_push(state, key)
    destination.write(MAGIC)
    destination.write(bytes((FORMAT_VERSION,)))
    destination.write(header)
    written = _PREFIX_BYTES

    current = source.read(CHUNK_BYTES)
    while True:
        following = source.read(CHUNK_BYTES)
        is_final = following == b""
        tag = (
            crypto_secretstream_xchacha20poly1305_TAG_FINAL
            if is_final
            else crypto_secretstream_xchacha20poly1305_TAG_MESSAGE
        )
        encrypted = crypto_secretstream_xchacha20poly1305_push(state, current, ad=None, tag=tag)
        destination.write(struct.pack(">I", len(encrypted)))
        destination.write(encrypted)
        written += 4 + len(encrypted)
        if is_final:
            break
        current = following
    return written


def _read_exact(source: BinaryIO, count: int, *, label: str) -> bytes:
    value = source.read(count)
    if len(value) != count:
        raise AssetCryptoError(f"encrypted asset is truncated in {label}")
    return value


def decrypt_stream(source: BinaryIO, destination: BinaryIO, *, key: bytes) -> int:
    _require_key(key)
    if _read_exact(source, len(MAGIC), label="magic") != MAGIC:
        raise AssetCryptoError("encrypted asset magic does not match")
    version = _read_exact(source, 1, label="version")[0]
    if version != FORMAT_VERSION:
        raise AssetCryptoError(f"unsupported encrypted asset version {version}")
    header = _read_exact(
        source, crypto_secretstream_xchacha20poly1305_HEADERBYTES, label="stream header"
    )
    state = crypto_secretstream_xchacha20poly1305_state()
    try:
        crypto_secretstream_xchacha20poly1305_init_pull(state, header, key)
    except SodiumCryptoError as error:
        raise AssetCryptoError("encrypted asset header authentication failed") from error

    written = 0
    while True:
        raw_length = source.read(4)
        if raw_length == b"":
            raise AssetCryptoError("encrypted asset has no authenticated final chunk")
        if len(raw_length) != 4:
            raise AssetCryptoError("encrypted asset is truncated in chunk length")
        encrypted_length = struct.unpack(">I", raw_length)[0]
        if (
            not crypto_secretstream_xchacha20poly1305_ABYTES
            <= encrypted_length
            <= _MAX_CIPHER_CHUNK
        ):
            raise AssetCryptoError("encrypted asset chunk length is invalid")
        encrypted = _read_exact(source, encrypted_length, label="chunk")
        try:
            plaintext, tag = crypto_secretstream_xchacha20poly1305_pull(state, encrypted, ad=None)
        except SodiumCryptoError as error:
            raise AssetCryptoError("encrypted asset authentication failed") from error
        destination.write(plaintext)
        written += len(plaintext)
        if tag == crypto_secretstream_xchacha20poly1305_TAG_FINAL:
            if source.read(1) != b"":
                raise AssetCryptoError("encrypted asset has trailing data after final chunk")
            return written
        if tag != crypto_secretstream_xchacha20poly1305_TAG_MESSAGE:
            raise AssetCryptoError("encrypted asset uses an unsupported stream tag")


def encrypt_bytes(plaintext: bytes, *, key: bytes) -> bytes:
    destination = io.BytesIO()
    encrypt_stream(io.BytesIO(plaintext), destination, key=key)
    return destination.getvalue()


def decrypt_bytes(ciphertext: bytes, *, key: bytes) -> bytes:
    destination = io.BytesIO()
    decrypt_stream(io.BytesIO(ciphertext), destination, key=key)
    return destination.getvalue()
