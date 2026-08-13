from __future__ import annotations

import secrets

from mnemonic import Mnemonic

ACCOUNT_KEY_BYTES = 32
WORD_COUNT = 24
_BIP39 = Mnemonic("english")


class RecoveryError(ValueError):
    """Raised for invalid Epistoria recovery material."""


def generate_account_key() -> bytes:
    return secrets.token_bytes(ACCOUNT_KEY_BYTES)


def words_from_account_key(account_key: bytes) -> str:
    if len(account_key) != ACCOUNT_KEY_BYTES:
        raise RecoveryError(f"account key must be {ACCOUNT_KEY_BYTES} bytes")
    return _BIP39.to_mnemonic(account_key)


def account_key_from_words(words: str) -> bytes:
    normalized = " ".join(words.strip().lower().split())
    if len(normalized.split()) != WORD_COUNT or not _BIP39.check(normalized):
        raise RecoveryError("recovery phrase must be a valid 24-word English BIP-39 phrase")
    entropy = _BIP39.to_entropy(normalized)
    if len(entropy) != ACCOUNT_KEY_BYTES:
        raise RecoveryError("recovery phrase does not encode a 256-bit Epistoria account key")
    return bytes(entropy)
