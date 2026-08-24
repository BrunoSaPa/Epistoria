from __future__ import annotations

from uuid import uuid4

import pytest

from epistoria_worker.keychain import MemoryProviderProfileStore, StoredProviderProfile
from epistoria_worker.models import ProviderConfigurationRequestV1, ProviderRouteSnapshotV1
from epistoria_worker.providers.base import ProviderError
from epistoria_worker.providers.fake import DeterministicDigestProvider
from epistoria_worker.providers.manager import (
    ProviderConfigurationError,
    ProviderManager,
    safe_provider_base_url,
)


def request(*, account_id, profile_id, job_id=None, api_key="secret-value"):
    return ProviderConfigurationRequestV1(
        account_id=account_id,
        job_id=job_id or uuid4(),
        operation="UPSERT",
        profile_id=profile_id,
        display_name="Local model",
        adapter="OPENAI_COMPATIBLE",
        base_url="http://127.0.0.1:11434/v1/",
        api_key=api_key,
        text_model="qwen3:8b",
        capabilities=["TEXT"],
        structured_output=True,
        make_active=True,
        disclosure_acknowledged=True,
    )


def route(profile: StoredProviderProfile) -> ProviderRouteSnapshotV1:
    return ProviderRouteSnapshotV1(
        profile_id=profile.profile_id,
        configuration_revision_id=profile.configuration_revision_id,
        display_name=profile.display_name,
        adapter=profile.adapter,
        base_url=profile.base_url,
        text_model=profile.text_model,
        transcription_model=profile.transcription_model,
        capabilities=list(profile.capabilities),
        structured_output=profile.structured_output,
    )


def test_configuration_stores_secret_but_artifact_does_not_expose_it() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    store = MemoryProviderProfileStore()
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)

    artifact = manager.apply_configuration(
        request(account_id=account_id, profile_id=profile_id)
    )

    stored = store.get(account_id, profile_id)
    assert stored is not None
    assert stored.api_key == "secret-value"
    assert store.active(account_id) == profile_id
    assert artifact.secret_stored is True
    assert "secret-value" not in artifact.model_dump_json()
    assert "apiKey" not in artifact.model_dump_json()


def test_profile_update_retains_existing_secret_when_key_is_omitted() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    store = MemoryProviderProfileStore()
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)
    manager.apply_configuration(request(account_id=account_id, profile_id=profile_id))

    update = request(account_id=account_id, profile_id=profile_id, api_key=None)
    update.text_model = "qwen3:14b"
    manager.apply_configuration(update)

    stored = store.get(account_id, profile_id)
    assert stored is not None
    assert stored.api_key == "secret-value"
    assert stored.text_model == "qwen3:14b"


def test_adapter_change_never_reuses_previous_provider_secret() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    store = MemoryProviderProfileStore()
    store.set(
        account_id,
        StoredProviderProfile(
            profile_id=profile_id,
            configuration_revision_id=profile_id,
            display_name="Hosted",
            adapter="OPENAI_RESPONSES",
            base_url="https://api.openai.com/v1",
            api_key="hosted-provider-secret",
            text_model="hosted-model",
            capabilities=("TEXT",),
        ),
    )
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)

    manager.apply_configuration(
        request(account_id=account_id, profile_id=profile_id, api_key=None)
    )

    stored = store.get(account_id, profile_id)
    assert stored is not None
    assert stored.adapter == "OPENAI_COMPATIBLE"
    assert stored.api_key is None


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("http://localhost:11434", "http://localhost:11434/v1"),
        ("http://192.168.1.20:1234/v1/", "http://192.168.1.20:1234/v1"),
        ("https://ai.example.com/openai/", "https://ai.example.com/openai"),
    ],
)
def test_safe_provider_url_accepts_local_http_and_remote_https(url: str, expected: str) -> None:
    assert safe_provider_base_url(url, adapter="OPENAI_COMPATIBLE") == expected


@pytest.mark.parametrize(
    "url",
    [
        "http://ai.example.com/v1",
        "http://10.example.com/v1",
        "http://0.0.0.0:11434/v1",
        "https://key@example.com/v1",
        "https://ai.example.com/v1?token=secret",
        "file:///tmp/model",
    ],
)
def test_safe_provider_url_rejects_unsafe_destinations(url: str) -> None:
    with pytest.raises(ProviderConfigurationError):
        safe_provider_base_url(url, adapter="OPENAI_COMPATIBLE")


def test_capability_is_enforced_before_provider_request() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    store = MemoryProviderProfileStore()
    store.set(
        account_id,
        StoredProviderProfile(
            profile_id=profile_id,
            configuration_revision_id=profile_id,
            display_name="Text only",
            adapter="OPENAI_COMPATIBLE",
            base_url="http://127.0.0.1:11434/v1",
            text_model="local",
            capabilities=("TEXT",),
        ),
    )
    store.set_active(account_id, profile_id)
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)

    with pytest.raises(ProviderError) as error:
        manager.transcribe_media(
            filename="lecture.mp3",
            mime_type="audio/mpeg",
            media=b"not-sent",
            language=None,
        )
    assert error.value.code == "PROVIDER_CAPABILITY_UNAVAILABLE"


def test_stored_profile_round_trip_keeps_secret_out_of_repr() -> None:
    profile = StoredProviderProfile(
        profile_id=uuid4(),
        configuration_revision_id=uuid4(),
        display_name="Private",
        adapter="OPENAI_RESPONSES",
        base_url="https://api.openai.com/v1",
        api_key="do-not-print",
        text_model="gpt-test",
        capabilities=("TEXT",),
    )

    decoded = StoredProviderProfile.decoded(profile.encoded())

    assert decoded == profile
    assert "do-not-print" not in repr(profile)


def test_removing_last_managed_profile_does_not_silently_restore_fallback() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    store = MemoryProviderProfileStore()
    manager = ProviderManager(
        account_id=account_id,
        store=store,
        fallback=DeterministicDigestProvider(),
    )
    manager.apply_configuration(request(account_id=account_id, profile_id=profile_id))
    manager.apply_configuration(
        ProviderConfigurationRequestV1(
            account_id=account_id,
            job_id=uuid4(),
            operation="DELETE",
            profile_id=profile_id,
            disclosure_acknowledged=True,
        )
    )

    assert store.managed(account_id)
    assert manager.is_ready is False


def test_reviewed_route_uses_selected_profile_after_active_profile_changes() -> None:
    account_id = uuid4()
    selected_id = uuid4()
    active_id = uuid4()
    selected = StoredProviderProfile(
        profile_id=selected_id,
        configuration_revision_id=uuid4(),
        display_name="Reviewed local model",
        adapter="OPENAI_COMPATIBLE",
        base_url="http://127.0.0.1:11434/v1",
        text_model="qwen3:8b",
        capabilities=("TEXT",),
    )
    active = StoredProviderProfile(
        profile_id=active_id,
        configuration_revision_id=uuid4(),
        display_name="New active model",
        adapter="OPENAI_COMPATIBLE",
        base_url="http://127.0.0.1:1234/v1",
        text_model="another-model",
        capabilities=("TEXT",),
    )
    store = MemoryProviderProfileStore()
    store.set(account_id, selected)
    store.set(account_id, active)
    store.set_active(account_id, active_id)
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)

    assert manager._profile_for_route(route(selected)) == selected


def test_reviewed_route_fails_closed_after_profile_edit_or_delete() -> None:
    account_id = uuid4()
    profile_id = uuid4()
    original = StoredProviderProfile(
        profile_id=profile_id,
        configuration_revision_id=uuid4(),
        display_name="Reviewed model",
        adapter="OPENAI_COMPATIBLE",
        base_url="http://127.0.0.1:11434/v1",
        text_model="qwen3:8b",
        capabilities=("TEXT",),
    )
    reviewed = route(original)
    store = MemoryProviderProfileStore()
    store.set(account_id, original)
    manager = ProviderManager(account_id=account_id, store=store, fallback=None)

    store.set(
        account_id,
        StoredProviderProfile(
            profile_id=profile_id,
            configuration_revision_id=uuid4(),
            display_name=original.display_name,
            adapter=original.adapter,
            base_url=original.base_url,
            text_model="qwen3:14b",
            capabilities=original.capabilities,
        ),
    )
    with pytest.raises(ProviderError) as changed:
        manager._profile_for_route(reviewed)
    assert changed.value.code == "PROVIDER_ROUTE_CHANGED"

    store.delete(account_id, profile_id)
    with pytest.raises(ProviderError) as revoked:
        manager._profile_for_route(reviewed)
    assert revoked.value.code == "PROVIDER_ROUTE_REVOKED"
