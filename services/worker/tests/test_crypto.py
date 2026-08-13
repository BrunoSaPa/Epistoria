import json
from pathlib import Path
from uuid import UUID

import pytest

from epistoria_worker.base64url import encode
from epistoria_worker.crypto import (
    EncryptedEnvelope,
    EnvelopeError,
    decrypt_payload,
    encrypt_entity,
    entity_aad,
)

ACCOUNT_ID = UUID("11111111-1111-4111-8111-111111111111")
ENTITY_ID = UUID("22222222-2222-4222-8222-222222222222")
ACCOUNT_KEY = bytes(range(32))


def deterministic_envelope() -> EncryptedEnvelope:
    return encrypt_entity(
        b'{"schemaVersion":"note/v1","title":"Synthetic fixture"}',
        account_key=ACCOUNT_KEY,
        account_id=ACCOUNT_ID,
        entity_type="NOTE",
        entity_id=ENTITY_ID,
        content_version=1,
        dek=bytes(range(32, 64)),
        dek_nonce=bytes(range(64, 88)),
        content_nonce=bytes(range(88, 112)),
    )


def test_deterministic_envelope_round_trip() -> None:
    envelope = deterministic_envelope()
    plaintext = decrypt_payload(
        envelope,
        account_key=ACCOUNT_KEY,
        account_id=ACCOUNT_ID,
        aad=entity_aad(ACCOUNT_ID, "NOTE", ENTITY_ID, 1),
    )
    assert plaintext == b'{"schemaVersion":"note/v1","title":"Synthetic fixture"}'
    assert len(envelope.sealed_dek) == 72
    assert len(envelope.sealed_content) == envelope.payload_size + 40


def test_deterministic_envelope_matches_shared_golden_vector() -> None:
    fixture_path = Path(__file__).parents[3] / "packages/contracts/crypto-vectors.json"
    fixture = json.loads(fixture_path.read_text())
    envelope = deterministic_envelope()
    assert fixture["sealedDek"] == encode(envelope.sealed_dek)
    assert fixture["sealedContent"] == encode(envelope.sealed_content)
    assert fixture["payloadSize"] == envelope.payload_size


@pytest.mark.parametrize("target", ["dek", "content"])
def test_tampering_fails_authentication(target: str) -> None:
    envelope = deterministic_envelope()
    tampered = bytearray(envelope.sealed_dek if target == "dek" else envelope.sealed_content)
    tampered[-1] ^= 1
    changed = EncryptedEnvelope(
        crypto_version=1,
        content_version=1,
        sealed_dek=bytes(tampered) if target == "dek" else envelope.sealed_dek,
        sealed_content=bytes(tampered) if target == "content" else envelope.sealed_content,
        payload_size=envelope.payload_size,
    )
    with pytest.raises(EnvelopeError):
        decrypt_payload(
            changed,
            account_key=ACCOUNT_KEY,
            account_id=ACCOUNT_ID,
            aad=entity_aad(ACCOUNT_ID, "NOTE", ENTITY_ID, 1),
        )


def test_authenticated_metadata_cannot_be_changed() -> None:
    with pytest.raises(EnvelopeError):
        decrypt_payload(
            deterministic_envelope(),
            account_key=ACCOUNT_KEY,
            account_id=ACCOUNT_ID,
            aad=entity_aad(ACCOUNT_ID, "RESOURCE", ENTITY_ID, 1),
        )
