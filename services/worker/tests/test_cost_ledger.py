import json
import stat
from datetime import UTC, datetime
from uuid import uuid4

from epistoria_worker.cost_ledger import CostLedger


def test_cost_ledger_is_atomic_private_monthly_and_idempotent(tmp_path) -> None:
    path = tmp_path / "cost-ledger.json"
    ledger = CostLedger(path, soft_budget_usd=5)
    job_id = uuid4()
    now = datetime(2026, 8, 9, 12, tzinfo=UTC)

    first = ledger.record(
        job_id=job_id,
        provider="openai",
        model="gpt-5.6-terra",
        prompt_version="session-digest/v1",
        input_tokens=20_000,
        output_tokens=2_000,
        estimated_cost_usd=0.125,
        provider_request_id="request-1",
        recorded_at=now,
    )
    repeated = ledger.record(
        job_id=job_id,
        provider="openai",
        model="gpt-5.6-terra",
        prompt_version="session-digest/v1",
        input_tokens=20_000,
        output_tokens=2_000,
        estimated_cost_usd=0.125,
        provider_request_id="request-1",
        recorded_at=now,
    )

    assert first.estimated_usd == 0.125
    assert repeated.estimated_usd == 0.125
    assert repeated.fraction == 0.025
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    document = json.loads(path.read_text())
    assert len(document["events"]) == 1
    assert document["events"][0]["inputTokens"] == 20_000
    assert document["events"][0]["promptVersion"] == "session-digest/v1"
    assert "plaintext" not in path.read_text()
