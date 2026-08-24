from __future__ import annotations

import json
import subprocess
from collections.abc import MutableMapping
from dataclasses import dataclass, field
from typing import Any, Protocol
from uuid import UUID

from . import base64url


class SecretStoreError(RuntimeError):
    """Raised when secure key storage cannot complete an operation."""


class AccountKeyStore(Protocol):
    def get(self, account_id: UUID) -> bytes | None: ...

    def set(self, account_id: UUID, account_key: bytes) -> None: ...

    def delete(self, account_id: UUID) -> None: ...


@dataclass(frozen=True, slots=True)
class StoredProviderProfile:
    profile_id: UUID
    configuration_revision_id: UUID
    display_name: str
    adapter: str
    base_url: str
    api_key: str | None = field(default=None, repr=False)
    text_model: str = ""
    transcription_model: str | None = None
    capabilities: tuple[str, ...] = ()
    structured_output: bool = True
    input_usd_per_million: float | None = None
    output_usd_per_million: float | None = None
    transcription_usd_per_minute: float | None = None

    def encoded(self) -> str:
        return json.dumps(
            {
                "profileId": str(self.profile_id),
                "configurationRevisionId": str(self.configuration_revision_id),
                "displayName": self.display_name,
                "adapter": self.adapter,
                "baseURL": self.base_url,
                "apiKey": self.api_key,
                "textModel": self.text_model,
                "transcriptionModel": self.transcription_model,
                "capabilities": list(self.capabilities),
                "structuredOutput": self.structured_output,
                "inputUSDPerMillion": self.input_usd_per_million,
                "outputUSDPerMillion": self.output_usd_per_million,
                "transcriptionUSDPerMinute": self.transcription_usd_per_minute,
            },
            separators=(",", ":"),
            sort_keys=True,
        )

    @classmethod
    def decoded(cls, value: str) -> StoredProviderProfile:
        try:
            raw: Any = json.loads(value)
            if not isinstance(raw, dict):
                raise ValueError
            capabilities = raw.get("capabilities", [])
            if not isinstance(capabilities, list) or not all(
                isinstance(item, str) for item in capabilities
            ):
                raise ValueError
            api_key = raw.get("apiKey")
            if api_key is not None and not isinstance(api_key, str):
                raise ValueError
            transcription_model = raw.get("transcriptionModel")
            if transcription_model is not None and not isinstance(transcription_model, str):
                raise ValueError
            return cls(
                profile_id=UUID(str(raw["profileId"])),
                configuration_revision_id=UUID(
                    str(raw.get("configurationRevisionId", raw["profileId"]))
                ),
                display_name=str(raw["displayName"]),
                adapter=str(raw["adapter"]),
                base_url=str(raw["baseURL"]),
                api_key=api_key,
                text_model=str(raw["textModel"]),
                transcription_model=transcription_model,
                capabilities=tuple(capabilities),
                structured_output=bool(raw.get("structuredOutput", True)),
                input_usd_per_million=_optional_number(raw.get("inputUSDPerMillion")),
                output_usd_per_million=_optional_number(raw.get("outputUSDPerMillion")),
                transcription_usd_per_minute=_optional_number(
                    raw.get("transcriptionUSDPerMinute")
                ),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise SecretStoreError("Keychain contains an invalid provider profile") from error


def _optional_number(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ValueError
    return float(value)


class ProviderProfileStore(Protocol):
    def get(self, account_id: UUID, profile_id: UUID) -> StoredProviderProfile | None: ...

    def set(self, account_id: UUID, profile: StoredProviderProfile) -> None: ...

    def delete(self, account_id: UUID, profile_id: UUID) -> None: ...

    def active(self, account_id: UUID) -> UUID | None: ...

    def set_active(self, account_id: UUID, profile_id: UUID | None) -> None: ...

    def managed(self, account_id: UUID) -> bool: ...

    def mark_managed(self, account_id: UUID) -> None: ...


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


@dataclass(slots=True)
class MacOSProviderProfileStore:
    service: str = "com.epistoria.worker.provider-profile"

    def get(self, account_id: UUID, profile_id: UUID) -> StoredProviderProfile | None:
        value = self._read(self._profile_account(account_id, profile_id))
        return None if value is None else StoredProviderProfile.decoded(value)

    def set(self, account_id: UUID, profile: StoredProviderProfile) -> None:
        self._write(
            self._profile_account(account_id, profile.profile_id),
            profile.encoded(),
            "Epistoria AI provider profile",
        )

    def delete(self, account_id: UUID, profile_id: UUID) -> None:
        self._delete(self._profile_account(account_id, profile_id))
        if self.active(account_id) == profile_id:
            self.set_active(account_id, None)

    def active(self, account_id: UUID) -> UUID | None:
        value = self._read(f"{account_id}:active")
        if value is None:
            return None
        try:
            return UUID(value)
        except ValueError as error:
            raise SecretStoreError("Keychain contains an invalid active provider ID") from error

    def set_active(self, account_id: UUID, profile_id: UUID | None) -> None:
        account = f"{account_id}:active"
        if profile_id is None:
            self._delete(account)
        else:
            self._write(account, str(profile_id), "Epistoria active AI provider")

    def managed(self, account_id: UUID) -> bool:
        return self._read(f"{account_id}:managed") == "1"

    def mark_managed(self, account_id: UUID) -> None:
        self._write(f"{account_id}:managed", "1", "Epistoria managed AI providers")

    def _read(self, account: str) -> str | None:
        result = subprocess.run(  # noqa: S603
            [
                "/usr/bin/security", "find-generic-password", "-a", account,
                "-s", self.service, "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 44:
            return None
        if result.returncode != 0:
            raise SecretStoreError("macOS Keychain could not read an AI provider profile")
        return result.stdout.rstrip("\n")

    def _write(self, account: str, value: str, label: str) -> None:
        result = subprocess.run(  # noqa: S603
            [
                "/usr/bin/security", "add-generic-password", "-U", "-a", account,
                "-s", self.service, "-l", label, "-w",
            ],
            input=value + "\n",
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            raise SecretStoreError("macOS Keychain could not store an AI provider profile")

    def _delete(self, account: str) -> None:
        result = subprocess.run(  # noqa: S603
            [
                "/usr/bin/security", "delete-generic-password", "-a", account,
                "-s", self.service,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode not in {0, 44}:
            raise SecretStoreError("macOS Keychain could not remove an AI provider profile")

    @staticmethod
    def _profile_account(account_id: UUID, profile_id: UUID) -> str:
        return f"{account_id}:profile:{profile_id}"


@dataclass(slots=True)
class MemoryProviderProfileStore:
    profiles: MutableMapping[tuple[UUID, UUID], StoredProviderProfile] = field(
        default_factory=dict
    )
    active_profiles: MutableMapping[UUID, UUID] = field(default_factory=dict)
    managed_accounts: set[UUID] = field(default_factory=set)

    def get(self, account_id: UUID, profile_id: UUID) -> StoredProviderProfile | None:
        return self.profiles.get((account_id, profile_id))

    def set(self, account_id: UUID, profile: StoredProviderProfile) -> None:
        self.profiles[(account_id, profile.profile_id)] = profile

    def delete(self, account_id: UUID, profile_id: UUID) -> None:
        self.profiles.pop((account_id, profile_id), None)
        if self.active_profiles.get(account_id) == profile_id:
            self.active_profiles.pop(account_id, None)

    def active(self, account_id: UUID) -> UUID | None:
        return self.active_profiles.get(account_id)

    def set_active(self, account_id: UUID, profile_id: UUID | None) -> None:
        if profile_id is None:
            self.active_profiles.pop(account_id, None)
        else:
            self.active_profiles[account_id] = profile_id

    def managed(self, account_id: UUID) -> bool:
        return account_id in self.managed_accounts

    def mark_managed(self, account_id: UUID) -> None:
        self.managed_accounts.add(account_id)
