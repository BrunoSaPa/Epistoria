from __future__ import annotations

import fcntl
import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast
from uuid import UUID, uuid4


class CostLedgerError(RuntimeError):
    """Raised when the local provider-cost ledger cannot be read or committed."""


@dataclass(frozen=True, slots=True)
class MonthlyCostStatus:
    month: str
    estimated_usd: float
    soft_budget_usd: float

    @property
    def fraction(self) -> float:
        if self.soft_budget_usd <= 0:
            return 0
        return self.estimated_usd / self.soft_budget_usd


class CostLedger:
    """Atomic, local-only ledger containing operational cost metadata and no content."""

    def __init__(self, path: Path, *, soft_budget_usd: float) -> None:
        if soft_budget_usd < 0:
            raise ValueError("soft budget cannot be negative")
        self._path = path
        self._lock_path = path.with_suffix(path.suffix + ".lock")
        self._soft_budget = soft_budget_usd

    def status(self, at: datetime | None = None) -> MonthlyCostStatus:
        current = (at or datetime.now(UTC)).astimezone(UTC)
        month = current.strftime("%Y-%m")
        with self._locked():
            document = self._read()
        estimated = sum(
            float(event["estimatedCostUsd"])
            for event in document["events"]
            if event["month"] == month
        )
        return MonthlyCostStatus(month, round(estimated, 8), self._soft_budget)

    def record(
        self,
        *,
        job_id: UUID,
        provider: str,
        model: str,
        prompt_version: str,
        input_tokens: int | None,
        output_tokens: int | None,
        estimated_cost_usd: float | None,
        provider_request_id: str | None,
        recorded_at: datetime | None = None,
    ) -> MonthlyCostStatus:
        if estimated_cost_usd is None:
            return self.status(recorded_at)
        if estimated_cost_usd < 0:
            raise ValueError("estimated cost cannot be negative")
        timestamp = (recorded_at or datetime.now(UTC)).astimezone(UTC)
        event_id = provider_request_id or str(uuid4())
        with self._locked():
            document = self._read()
            if not any(event["eventId"] == event_id for event in document["events"]):
                document["events"].append(
                    {
                        "eventId": event_id,
                        "jobId": str(job_id),
                        "provider": provider,
                        "model": model,
                        "promptVersion": prompt_version,
                        "inputTokens": input_tokens,
                        "outputTokens": output_tokens,
                        "month": timestamp.strftime("%Y-%m"),
                        "recordedAt": timestamp.isoformat(timespec="seconds").replace(
                            "+00:00", "Z"
                        ),
                        "estimatedCostUsd": round(estimated_cost_usd, 8),
                    }
                )
                self._write(document)
            estimated = sum(
                float(event["estimatedCostUsd"])
                for event in document["events"]
                if event["month"] == timestamp.strftime("%Y-%m")
            )
        return MonthlyCostStatus(
            timestamp.strftime("%Y-%m"), round(estimated, 8), self._soft_budget
        )

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self._path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self._lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        lock = os.fdopen(descriptor, "r+")
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            lock.close()

    def _read(self) -> dict[str, Any]:
        if not self._path.exists():
            return {"schemaVersion": "epistoria-cost-ledger/v1", "events": []}
        try:
            raw_document = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise CostLedgerError("provider cost ledger is unreadable") from error
        if not isinstance(raw_document, dict):
            raise CostLedgerError("provider cost ledger has an unsupported format")
        document = cast(dict[str, Any], raw_document)
        if document.get("schemaVersion") != "epistoria-cost-ledger/v1" or not isinstance(
            document.get("events"), list
        ):
            raise CostLedgerError("provider cost ledger has an unsupported format")
        for event in document["events"]:
            if (
                not isinstance(event, dict)
                or not isinstance(event.get("eventId"), str)
                or not isinstance(event.get("jobId"), str)
                or not isinstance(event.get("provider"), str)
                or not isinstance(event.get("model"), str)
                or not isinstance(event.get("promptVersion"), str)
                or not isinstance(event.get("month"), str)
                or not isinstance(event.get("recordedAt"), str)
                or not isinstance(event.get("estimatedCostUsd"), (int, float))
                or not (
                    event.get("inputTokens") is None
                    or isinstance(event.get("inputTokens"), int)
                )
                or not (
                    event.get("outputTokens") is None
                    or isinstance(event.get("outputTokens"), int)
                )
            ):
                raise CostLedgerError("provider cost ledger has an invalid event")
        return document

    def _write(self, document: dict[str, Any]) -> None:
        temporary = self._path.with_name(f".{self._path.name}.{uuid4()}.tmp")
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(document, output, sort_keys=True, separators=(",", ":"))
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self._path)
        except OSError as error:
            temporary.unlink(missing_ok=True)
            raise CostLedgerError("provider cost ledger could not be committed") from error
