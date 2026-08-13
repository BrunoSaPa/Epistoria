import stat
from uuid import uuid4

from epistoria_worker.outbox import CachedCompletion, EncryptedOutbox


def test_ciphertext_outbox_is_atomic_private_and_round_trips(tmp_path) -> None:
    outbox = EncryptedOutbox(tmp_path / "outbox")
    completion = CachedCompletion(
        job_id=uuid4(), artifact_entity_id=uuid4(), mutations=[{"sealed": "opaque"}]
    )
    outbox.save(completion)
    assert outbox.load(completion.job_id) == completion
    mode = stat.S_IMODE((tmp_path / "outbox" / f"{completion.job_id}.json").stat().st_mode)
    assert mode == 0o600
    outbox.delete(completion.job_id)
    assert outbox.load(completion.job_id) is None
