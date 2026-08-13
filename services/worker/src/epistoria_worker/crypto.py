from __future__ import annotations

import hashlib
import hmac
import re
import secrets
from dataclasses import dataclass
from uuid import UUID

from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_ABYTES,
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_aead_xchacha20poly1305_ietf_encrypt,
    crypto_aead_xchacha20poly1305_ietf_KEYBYTES,
    crypto_aead_xchacha20poly1305_ietf_NPUBBYTES,
)
from nacl.exceptions import CryptoError as SodiumCryptoError

from . import base64url

ACCOUNT_KEY_BYTES = 32
DEK_BYTES = crypto_aead_xchacha20poly1305_ietf_KEYBYTES
NONCE_BYTES = crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
TAG_BYTES = crypto_aead_xchacha20poly1305_ietf_ABYTES
SEALED_OVERHEAD = NONCE_BYTES + TAG_BYTES
_CONTRACT_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")


class EnvelopeError(ValueError):
    """Raised for malformed or unauthenticated encrypted envelopes."""


@dataclass(frozen=True, slots=True)
class EncryptedEnvelope:
    crypto_version: int
    content_version: int
    sealed_dek: bytes
    sealed_content: bytes
    payload_size: int

    def to_wire(self) -> dict[str, int | str]:
        return {
            "cryptoVersion": self.crypto_version,
            "contentVersion": self.content_version,
            "sealedDek": base64url.encode(self.sealed_dek),
            "sealedContent": base64url.encode(self.sealed_content),
            "payloadSize": self.payload_size,
        }


def _require_key(key: bytes, *, name: str) -> None:
    if len(key) != ACCOUNT_KEY_BYTES:
        raise EnvelopeError(f"{name} must be {ACCOUNT_KEY_BYTES} bytes")


def _uuid(value: UUID | str) -> UUID:
    try:
        return value if isinstance(value, UUID) else UUID(value)
    except (ValueError, AttributeError) as error:
        raise EnvelopeError("invalid UUID in authenticated metadata") from error


def _name(value: str) -> str:
    if _CONTRACT_NAME.fullmatch(value) is None:
        raise EnvelopeError("contract type must be uppercase ASCII with underscores")
    return value


def _version(value: int) -> int:
    if value < 1 or value > 65_535:
        raise EnvelopeError("content version must be between 1 and 65535")
    return value


def entity_aad(
    account_id: UUID | str,
    entity_type: str,
    entity_id: UUID | str,
    content_version: int,
) -> bytes:
    return (
        f"epistoria|entity|v1|{_uuid(account_id)}|{_name(entity_type)}|"
        f"{_uuid(entity_id)}|{_version(content_version)}"
    ).encode()


def job_aad(
    account_id: UUID | str,
    job_type: str,
    job_id: UUID | str,
    content_version: int,
) -> bytes:
    return (
        f"epistoria|job|v1|{_uuid(account_id)}|{_name(job_type)}|"
        f"{_uuid(job_id)}|{_version(content_version)}"
    ).encode()


def hkdf_sha256(input_key: bytes, *, salt: bytes, info: bytes, length: int = 32) -> bytes:
    if length <= 0 or length > 255 * hashlib.sha256().digest_size:
        raise ValueError("invalid HKDF output length")
    pseudo_random_key = hmac.digest(salt, input_key, "sha256")
    output = bytearray()
    prior = b""
    counter = 1
    while len(output) < length:
        prior = hmac.digest(pseudo_random_key, prior + info + bytes((counter,)), "sha256")
        output.extend(prior)
        counter += 1
    return bytes(output[:length])


def wrapping_key(account_key: bytes, account_id: UUID | str) -> bytes:
    _require_key(account_key, name="account key")
    return hkdf_sha256(
        account_key,
        salt=_uuid(account_id).bytes,
        info=b"epistoria/entity-wrap/v1",
    )


def dedupe_key(account_key: bytes, account_id: UUID | str) -> bytes:
    _require_key(account_key, name="account key")
    return hkdf_sha256(
        account_key,
        salt=_uuid(account_id).bytes,
        info=b"epistoria/asset-dedupe/v1",
    )


def _seal(plaintext: bytes, *, key: bytes, aad: bytes, nonce: bytes | None = None) -> bytes:
    _require_key(key, name="encryption key")
    actual_nonce = nonce or secrets.token_bytes(NONCE_BYTES)
    if len(actual_nonce) != NONCE_BYTES:
        raise EnvelopeError(f"nonce must be {NONCE_BYTES} bytes")
    encrypted = crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, aad, actual_nonce, key)
    return actual_nonce + encrypted


def _open(sealed: bytes, *, key: bytes, aad: bytes) -> bytes:
    _require_key(key, name="encryption key")
    if len(sealed) < SEALED_OVERHEAD:
        raise EnvelopeError("sealed value is too short")
    nonce, encrypted = sealed[:NONCE_BYTES], sealed[NONCE_BYTES:]
    try:
        return crypto_aead_xchacha20poly1305_ietf_decrypt(encrypted, aad, nonce, key)
    except SodiumCryptoError as error:
        raise EnvelopeError("envelope authentication failed") from error


def encrypt_payload(
    plaintext: bytes,
    *,
    account_key: bytes,
    account_id: UUID | str,
    aad: bytes,
    content_version: int = 1,
    dek: bytes | None = None,
    dek_nonce: bytes | None = None,
    content_nonce: bytes | None = None,
) -> EncryptedEnvelope:
    actual_dek = dek or secrets.token_bytes(DEK_BYTES)
    _require_key(actual_dek, name="data encryption key")
    wrap = wrapping_key(account_key, account_id)
    return EncryptedEnvelope(
        crypto_version=1,
        content_version=_version(content_version),
        sealed_dek=_seal(actual_dek, key=wrap, aad=aad + b"|dek", nonce=dek_nonce),
        sealed_content=_seal(plaintext, key=actual_dek, aad=aad, nonce=content_nonce),
        payload_size=len(plaintext),
    )


def decrypt_payload(
    envelope: EncryptedEnvelope,
    *,
    account_key: bytes,
    account_id: UUID | str,
    aad: bytes,
) -> bytes:
    if envelope.crypto_version != 1:
        raise EnvelopeError(f"unsupported crypto version {envelope.crypto_version}")
    if len(envelope.sealed_dek) != DEK_BYTES + SEALED_OVERHEAD:
        raise EnvelopeError("wrapped DEK has the wrong length")
    if envelope.payload_size < 0:
        raise EnvelopeError("payload size cannot be negative")
    if len(envelope.sealed_content) != envelope.payload_size + SEALED_OVERHEAD:
        raise EnvelopeError("sealed content does not match payload size")
    wrap = wrapping_key(account_key, account_id)
    dek = _open(envelope.sealed_dek, key=wrap, aad=aad + b"|dek")
    if len(dek) != DEK_BYTES:
        raise EnvelopeError("opened DEK has the wrong length")
    plaintext = _open(envelope.sealed_content, key=dek, aad=aad)
    if len(plaintext) != envelope.payload_size:
        raise EnvelopeError("opened content does not match payload size")
    return plaintext


def encrypt_entity(
    plaintext: bytes,
    *,
    account_key: bytes,
    account_id: UUID | str,
    entity_type: str,
    entity_id: UUID | str,
    content_version: int = 1,
    dek: bytes | None = None,
    dek_nonce: bytes | None = None,
    content_nonce: bytes | None = None,
) -> EncryptedEnvelope:
    aad = entity_aad(account_id, entity_type, entity_id, content_version)
    return encrypt_payload(
        plaintext,
        account_key=account_key,
        account_id=account_id,
        aad=aad,
        content_version=content_version,
        dek=dek,
        dek_nonce=dek_nonce,
        content_nonce=content_nonce,
    )


def decrypt_job(
    envelope: EncryptedEnvelope,
    *,
    account_key: bytes,
    account_id: UUID | str,
    job_type: str,
    job_id: UUID | str,
) -> bytes:
    aad = job_aad(account_id, job_type, job_id, envelope.content_version)
    return decrypt_payload(
        envelope,
        account_key=account_key,
        account_id=account_id,
        aad=aad,
    )
