from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any
from uuid import UUID

from pydantic import Field

from .models import ContractModel


class CachedCompletion(ContractModel):
    job_id: UUID
    artifact_entity_id: UUID
    mutations: list[dict[str, Any]] = Field(min_length=1, max_length=100)


class EncryptedOutbox:
    """Durable ciphertext-only cache preventing duplicate paid provider calls."""

    def __init__(self, directory: Path) -> None:
        self._directory = directory

    def _path(self, job_id: UUID) -> Path:
        return self._directory / f"{job_id}.json"

    def load(self, job_id: UUID) -> CachedCompletion | None:
        path = self._path(job_id)
        try:
            raw = path.read_bytes()
        except FileNotFoundError:
            return None
        if len(raw) > 100 * 1024 * 1024:
            raise ValueError("encrypted outbox record exceeds the safety limit")
        completion = CachedCompletion.model_validate_json(raw)
        if completion.job_id != job_id:
            raise ValueError("encrypted outbox record has the wrong job ID")
        return completion

    def save(self, completion: CachedCompletion) -> None:
        self._directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self._directory, 0o700)
        payload = json.dumps(
            completion.model_dump(mode="json", by_alias=True),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        descriptor, temporary_name = tempfile.mkstemp(
            dir=self._directory, prefix=f".{completion.job_id}.", suffix=".tmp"
        )
        temporary = Path(temporary_name)
        try:
            os.chmod(temporary, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self._path(completion.job_id))
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def delete(self, job_id: UUID) -> None:
        try:
            self._path(job_id).unlink()
        except FileNotFoundError:
            return
