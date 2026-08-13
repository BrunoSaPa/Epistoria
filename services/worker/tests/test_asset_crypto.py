import struct
from uuid import UUID

import pytest

from epistoria_worker.asset_crypto import (
    MAGIC,
    AssetCryptoError,
    decrypt_bytes,
    encrypt_bytes,
    plaintext_dedupe_tag,
)

KEY = bytes(range(32))


@pytest.mark.parametrize("size", [0, 1, 65_536, 65_537, 131_072])
def test_asset_round_trip_at_chunk_boundaries(size: int) -> None:
    plaintext = bytes(index % 251 for index in range(size))
    assert decrypt_bytes(encrypt_bytes(plaintext, key=KEY), key=KEY) == plaintext


def test_asset_rejects_tampering_truncation_and_trailing_data() -> None:
    encrypted = encrypt_bytes(b"synthetic" * 10_000, key=KEY)
    tampered = bytearray(encrypted)
    tampered[-1] ^= 1
    for invalid in [bytes(tampered), encrypted[:-1], encrypted + b"x"]:
        with pytest.raises(AssetCryptoError):
            decrypt_bytes(invalid, key=KEY)


def test_asset_rejects_reordered_chunks() -> None:
    encrypted = encrypt_bytes(b"x" * 70_000, key=KEY)
    prefix_bytes = len(MAGIC) + 1 + 24
    first_length = struct.unpack(">I", encrypted[prefix_bytes : prefix_bytes + 4])[0]
    first_end = prefix_bytes + 4 + first_length
    reordered = encrypted[:prefix_bytes] + encrypted[first_end:] + encrypted[prefix_bytes:first_end]
    with pytest.raises(AssetCryptoError):
        decrypt_bytes(reordered, key=KEY)


def test_dedupe_tag_is_keyed_and_stable() -> None:
    account = UUID("11111111-1111-4111-8111-111111111111")
    tag = plaintext_dedupe_tag(b"same file", account_key=KEY, account_id=account)
    assert len(tag) == 64
    assert tag == plaintext_dedupe_tag(b"same file", account_key=KEY, account_id=account)
    assert tag != plaintext_dedupe_tag(b"other file", account_key=KEY, account_id=account)
