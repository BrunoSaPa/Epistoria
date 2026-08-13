from __future__ import annotations

import argparse
import getpass
import logging
import os
import signal
import sys
import threading
from uuid import UUID

from .api import APIError, EpistoriaAPI
from .config import ConfigurationError, WorkerSettings
from .cost_ledger import CostLedger, CostLedgerError
from .keychain import MacOSKeychain, SecretStoreError
from .outbox import EncryptedOutbox
from .processor import WorkerProcessor
from .providers import DeterministicDigestProvider, OpenAIDigestProvider
from .providers.base import DigestProvider
from .recovery import (
    RecoveryError,
    account_key_from_words,
    generate_account_key,
    words_from_account_key,
)

LOGGER = logging.getLogger("epistoria.worker")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="epistoria-worker")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING"])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="check API, provider, and Keychain readiness")
    commands.add_parser("once", help="claim at most one job")
    commands.add_parser("run", help="poll continuously")
    commands.add_parser("key-import", help="import 24 recovery words without command-line exposure")
    commands.add_parser(
        "key-create", help="create and store a new account key, displaying words once"
    )
    commands.add_parser("key-export", help="explicitly display recovery words for the stored key")
    return parser


def _key_context() -> tuple[UUID, MacOSKeychain]:
    raw_account = os.environ.get("EPISTORIA_ACCOUNT_ID", "")
    try:
        account_id = UUID(raw_account)
    except ValueError as error:
        raise ConfigurationError("EPISTORIA_ACCOUNT_ID must be a UUID") from error
    service = os.environ.get("EPISTORIA_KEYCHAIN_SERVICE", "com.epistoria.worker.account-key")
    return account_id, MacOSKeychain(service)


def _read_recovery_words() -> str:
    if sys.stdin.isatty():
        return getpass.getpass("Enter all 24 recovery words: ")
    return sys.stdin.readline()


def _key_command(command: str) -> int:
    account_id, store = _key_context()
    if command == "key-import":
        key = account_key_from_words(_read_recovery_words())
        store.set(account_id, key)
        print(f"Stored the account key for {account_id} in macOS Keychain.")
        return 0
    if command == "key-create":
        if store.get(account_id) is not None:
            raise SecretStoreError("an account key already exists; refusing to overwrite it")
        key = generate_account_key()
        store.set(account_id, key)
        print("Write these words down offline now. They will not be shown again automatically:\n")
        print(words_from_account_key(key))
        return 0
    if command == "key-export":
        confirmation = input(f"Type the account ID {account_id} to reveal recovery words: ")
        if confirmation.strip() != str(account_id):
            raise SecretStoreError("account ID confirmation did not match")
        stored_key = store.get(account_id)
        if stored_key is None:
            raise SecretStoreError("no account key exists in macOS Keychain")
        print(words_from_account_key(stored_key))
        return 0
    raise AssertionError("unreachable key command")


def _provider(settings: WorkerSettings) -> DigestProvider | None:
    if settings.provider == "fake":
        if os.environ.get("EPISTORIA_ENVIRONMENT") not in {"development", "test"}:
            raise ConfigurationError(
                "the fake provider requires EPISTORIA_ENVIRONMENT=development or test"
            )
        return DeterministicDigestProvider()
    if not settings.openai_api_key:
        return None
    return OpenAIDigestProvider(
        api_key=settings.openai_api_key,
        model=settings.session_digest_model,
        prompt_version=settings.prompt_version,
        input_usd_per_million=settings.input_usd_per_million,
        output_usd_per_million=settings.output_usd_per_million,
    )


def _runtime(command: str) -> int:
    settings = WorkerSettings.from_environment()
    ledger = CostLedger(
        settings.cost_ledger_path, soft_budget_usd=settings.monthly_soft_budget_usd
    )
    key = MacOSKeychain(settings.keychain_service).get(settings.account_id)
    if key is None:
        raise SecretStoreError("account key is not present in macOS Keychain")
    provider = _provider(settings)
    with EpistoriaAPI(
        base_url=settings.api_url,
        device_token=settings.device_token,
        device_id=settings.device_id,
    ) as api:
        if command == "doctor":
            health = api.health()
            cost = ledger.status()
            print(f"API: {health.get('status', 'unknown')}")
            print("Account key: available in macOS Keychain")
            print(f"Session digest provider: {'ready' if provider else 'disabled'}")
            print(f"Encrypted retry outbox: {settings.outbox_directory}")
            print(
                f"Estimated OpenAI spend ({cost.month}): ${cost.estimated_usd:.4f} / "
                f"${cost.soft_budget_usd:.2f} soft budget"
            )
            return 0
        processor = WorkerProcessor(
            account_id=settings.account_id,
            account_key=key,
            api=api,
            outbox=EncryptedOutbox(settings.outbox_directory),
            digest_provider=provider,
            maximum_asset_bytes=settings.maximum_asset_bytes,
            cost_ledger=ledger,
        )
        if command == "once":
            return 0 if processor.process_once() else 3

        stopped = threading.Event()

        def stop(_signum: int, _frame: object) -> None:
            stopped.set()

        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        LOGGER.info("worker started account=%s device=%s", settings.account_id, settings.device_id)
        while not stopped.is_set():
            try:
                processed = processor.process_once()
            except APIError:
                LOGGER.warning("API unavailable; retrying after poll interval")
                processed = False
            stopped.wait(0 if processed else settings.poll_seconds)
        LOGGER.info("worker stopped")
        return 0


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        if args.command.startswith("key-"):
            return _key_command(args.command)
        return _runtime(args.command)
    except (ConfigurationError, CostLedgerError, RecoveryError, SecretStoreError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
