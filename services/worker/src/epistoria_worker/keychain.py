from __future__ import annotations

import subprocess
from collections.abc import MutableMapping
from dataclasses import dataclass, field
from typing import Protocol
from uuid import UUID

from . import base64url


class SecretStoreError(RuntimeError):
    """Raised when secure key storage cannot complete an operation."""


class AccountKeyStore(Protocol):
    def get(self, account_id: UUID) -> bytes | None: ...

    def set(self, account_id: UUID, account_key: bytes) -> None: ...

    def delete(self, account_id: UUID) -> None: ...


@dataclass(slots=True)
class MacOSKeychain:
    service: str

    def get(self, account_id: UUID) -> bytes | None:
        result = subprocess.run(  # noqa: S603 -- absolute trusted system executable
            [
                "/usr/bin/security",
                "find-generic-password",
                "-a",
                str(account_id),
                "-s",
                self.service,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 44:
            return None
        if result.returncode != 0:
            raise SecretStoreError("macOS Keychain could not read the Epistoria account key")
        try:
            key = base64url.decode(result.stdout.strip(), field="Keychain account key")
        except ValueError as error:
            raise SecretStoreError("Keychain contains an invalid Epistoria account key") from error
        if len(key) != 32:
            raise SecretStoreError("Keychain contains an invalid Epistoria account key")
        return key

    def set(self, account_id: UUID, account_key: bytes) -> None:
        if len(account_key) != 32:
            raise SecretStoreError("account key must be 32 bytes")
        # A trailing -w asks security(1) to read the secret from stdin, keeping it out
        # of process arguments and shell history.
        result = subprocess.run(  # noqa: S603 -- absolute trusted system executable
            [
                "/usr/bin/security",
                "add-generic-password",
                "-U",
                "-a",
                str(account_id),
                "-s",
                self.service,
                "-l",
                f"Epistoria account {account_id}",
                "-w",
            ],
            input=base64url.encode(account_key) + "\n",
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            raise SecretStoreError("macOS Keychain could not store the Epistoria account key")

    def delete(self, account_id: UUID) -> None:
        result = subprocess.run(  # noqa: S603 -- absolute trusted system executable
            [
                "/usr/bin/security",
                "delete-generic-password",
                "-a",
                str(account_id),
                "-s",
                self.service,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode not in {0, 44}:
            raise SecretStoreError("macOS Keychain could not remove the Epistoria account key")


@dataclass(slots=True)
class MemoryAccountKeyStore:
    values: MutableMapping[UUID, bytes] = field(default_factory=dict)

    def get(self, account_id: UUID) -> bytes | None:
        return self.values.get(account_id)

    def set(self, account_id: UUID, account_key: bytes) -> None:
        if len(account_key) != 32:
            raise SecretStoreError("account key must be 32 bytes")
        self.values[account_id] = account_key

    def delete(self, account_id: UUID) -> None:
        self.values.pop(account_id, None)
