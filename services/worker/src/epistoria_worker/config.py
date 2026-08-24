from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from uuid import UUID


class ConfigurationError(ValueError):
    """Raised when worker configuration is absent or unsafe."""


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ConfigurationError(f"{name} is required")
    return value


def _optional_float(name: str) -> float | None:
    value = os.environ.get(name, "").strip()
    if not value:
        return None
    try:
        parsed = float(value)
    except ValueError as error:
        raise ConfigurationError(f"{name} must be a number") from error
    if parsed < 0:
        raise ConfigurationError(f"{name} cannot be negative")
    return parsed


@dataclass(frozen=True, slots=True)
class WorkerSettings:
    api_url: str
    account_id: UUID
    device_id: UUID
    device_token: str = field(repr=False)
    provider: str = "openai"
    openai_api_key: str | None = field(default=None, repr=False)
    session_digest_model: str = "gpt-5.6-terra"
    prompt_version: str = "session-digest/v1"
    input_usd_per_million: float | None = None
    output_usd_per_million: float | None = None
    transcription_model: str = "whisper-1"
    transcription_usd_per_minute: float | None = 0.006
    poll_seconds: float = 10.0
    maximum_asset_bytes: int = 268_435_456
    keychain_service: str = "com.epistoria.worker.account-key"
    provider_keychain_service: str = "com.epistoria.worker.provider-profile"
    outbox_directory: Path = Path.home() / "Library/Application Support/EpistoriaWorker/outbox"
    cost_ledger_path: Path = (
        Path.home() / "Library/Application Support/EpistoriaWorker/cost-ledger.json"
    )
    monthly_soft_budget_usd: float = 5.0

    @classmethod
    def from_environment(cls) -> WorkerSettings:
        try:
            account_id = UUID(_required("EPISTORIA_ACCOUNT_ID"))
            device_id = UUID(_required("EPISTORIA_DEVICE_ID"))
        except ValueError as error:
            raise ConfigurationError("account and device IDs must be UUIDs") from error
        token = _required("EPISTORIA_DEVICE_TOKEN")
        if len(token) < 32:
            raise ConfigurationError("EPISTORIA_DEVICE_TOKEN is unexpectedly short")
        provider = os.environ.get("EPISTORIA_AI_PROVIDER", "openai").strip().lower()
        if provider not in {"openai", "fake"}:
            raise ConfigurationError("EPISTORIA_AI_PROVIDER must be openai or fake")
        poll_seconds = float(os.environ.get("EPISTORIA_POLL_SECONDS", "10"))
        if poll_seconds < 1 or poll_seconds > 300:
            raise ConfigurationError("EPISTORIA_POLL_SECONDS must be between 1 and 300")
        maximum_asset_bytes = int(os.environ.get("EPISTORIA_MAXIMUM_ASSET_BYTES", "268435456"))
        if maximum_asset_bytes < 1 or maximum_asset_bytes > 536_870_912:
            raise ConfigurationError(
                "EPISTORIA_MAXIMUM_ASSET_BYTES must be between 1 and 536870912"
            )
        default_outbox = Path.home() / "Library/Application Support/EpistoriaWorker/outbox"
        default_ledger = (
            Path.home() / "Library/Application Support/EpistoriaWorker/cost-ledger.json"
        )
        monthly_soft_budget = _optional_float("AI_MONTHLY_SOFT_BUDGET_USD")
        return cls(
            api_url=os.environ.get("EPISTORIA_API_URL", "http://127.0.0.1:3000").rstrip("/"),
            account_id=account_id,
            device_id=device_id,
            device_token=token,
            provider=provider,
            openai_api_key=(
                os.environ.get("EPISTORIA_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY")
            ),
            session_digest_model=os.environ.get("EPISTORIA_SESSION_DIGEST_MODEL", "gpt-5.6-terra"),
            prompt_version=os.environ.get(
                "EPISTORIA_SESSION_DIGEST_PROMPT_VERSION", "session-digest/v1"
            ),
            input_usd_per_million=_optional_float("EPISTORIA_MODEL_INPUT_USD_PER_MILLION"),
            output_usd_per_million=_optional_float("EPISTORIA_MODEL_OUTPUT_USD_PER_MILLION"),
            transcription_model=os.environ.get(
                "EPISTORIA_TRANSCRIPTION_MODEL", "whisper-1"
            ).strip(),
            transcription_usd_per_minute=(
                _optional_float("EPISTORIA_TRANSCRIPTION_USD_PER_MINUTE")
                if os.environ.get("EPISTORIA_TRANSCRIPTION_USD_PER_MINUTE", "").strip()
                else 0.006
            ),
            poll_seconds=poll_seconds,
            maximum_asset_bytes=maximum_asset_bytes,
            keychain_service=os.environ.get(
                "EPISTORIA_KEYCHAIN_SERVICE", "com.epistoria.worker.account-key"
            ),
            provider_keychain_service=os.environ.get(
                "EPISTORIA_PROVIDER_KEYCHAIN_SERVICE",
                "com.epistoria.worker.provider-profile",
            ),
            outbox_directory=Path(
                os.environ.get("EPISTORIA_OUTBOX_DIRECTORY", str(default_outbox))
            ).expanduser(),
            cost_ledger_path=Path(
                os.environ.get("EPISTORIA_COST_LEDGER_PATH", str(default_ledger))
            ).expanduser(),
            monthly_soft_budget_usd=(
                monthly_soft_budget if monthly_soft_budget is not None else 5.0
            ),
        )
