from __future__ import annotations

import hashlib
from collections.abc import Iterator
from pathlib import Path

import httpx
import pytest

from epistoria_worker.local_models import (
    LocalModelError,
    LocalModelManager,
    LocalModelManifest,
    LocalModelPaused,
    ModelFile,
)


def manifest_for(content: bytes) -> LocalModelManifest:
    return LocalModelManifest(
        model_id="fixture-model",
        revision="fixture-revision",
        license="Apache-2.0",
        repository_url="https://models.invalid/fixture-model",
        files=(
            ModelFile(
                name="model.bin",
                byte_size=len(content),
                sha256=hashlib.sha256(content).hexdigest(),
            ),
        ),
    )


def test_verified_model_install_and_remove_are_atomic(tmp_path: Path) -> None:
    content = b"verified local model"

    def response(request: httpx.Request) -> httpx.Response:
        assert request.url.scheme == "https"
        return httpx.Response(
            200,
            content=content,
            headers={"content-length": str(len(content))},
        )

    client = httpx.Client(transport=httpx.MockTransport(response))
    manager = LocalModelManager(tmp_path / "Models", client=client)
    manifest = manifest_for(content)

    installed = manager.install(manifest)
    assert installed.state == "INSTALLED"
    assert installed.verified_bytes == len(content)
    assert installed.directory is not None
    assert installed.directory.stat().st_mode & 0o777 == 0o700
    assert (installed.directory / "model.bin").stat().st_mode & 0o777 == 0o600

    removed = manager.remove(manifest)
    assert removed.state == "NOT_INSTALLED"


def test_model_install_rejects_a_wrong_checksum(tmp_path: Path) -> None:
    expected = b"expected"
    client = httpx.Client(
        transport=httpx.MockTransport(
            lambda _request: httpx.Response(
                200,
                content=b"tampered",
                headers={"content-length": str(len(expected))},
            )
        )
    )
    manager = LocalModelManager(tmp_path / "Models", client=client)

    with pytest.raises(LocalModelError) as caught:
        manager.install(manifest_for(expected))

    assert caught.value.code == "LOCAL_MODEL_VERIFICATION_FAILED"
    assert manager.status(manifest_for(expected)).state == "NOT_INSTALLED"


def test_paused_download_resumes_from_preserved_partial_bytes(tmp_path: Path) -> None:
    content = b"0123456789"
    request_ranges: list[str | None] = []

    class ChunkedStream(httpx.SyncByteStream):
        def __init__(self, value: bytes) -> None:
            self.value = value

        def __iter__(self) -> Iterator[bytes]:
            midpoint = min(4, len(self.value))
            yield self.value[:midpoint]
            if midpoint < len(self.value):
                yield self.value[midpoint:]

    def response(request: httpx.Request) -> httpx.Response:
        range_header = request.headers.get("range")
        request_ranges.append(range_header)
        if range_header:
            offset = int(range_header.removeprefix("bytes=").removesuffix("-"))
            return httpx.Response(
                206,
                stream=ChunkedStream(content[offset:]),
                headers={"content-length": str(len(content) - offset)},
            )
        return httpx.Response(
            200,
            stream=ChunkedStream(content),
            headers={"content-length": str(len(content))},
        )

    client = httpx.Client(transport=httpx.MockTransport(response))
    manager = LocalModelManager(tmp_path / "Models", client=client)
    manifest = manifest_for(content)
    checks = 0

    def pause_after_first_chunk() -> bool:
        nonlocal checks
        checks += 1
        return checks == 3

    with pytest.raises(LocalModelPaused):
        manager.install(manifest, should_pause=pause_after_first_chunk)

    partials = list((tmp_path / "Models" / ".downloads").rglob("*.part"))
    assert len(partials) == 1
    assert partials[0].stat().st_size == 4

    installed = manager.install(manifest)
    assert installed.state == "INSTALLED"
    assert request_ranges == [None, "bytes=4-"]


def test_remove_discards_an_interrupted_download(tmp_path: Path) -> None:
    content = b"0123456789"

    class ChunkedStream(httpx.SyncByteStream):
        def __iter__(self) -> Iterator[bytes]:
            yield content[:4]
            yield content[4:]

    client = httpx.Client(
        transport=httpx.MockTransport(
            lambda _request: httpx.Response(
                200,
                stream=ChunkedStream(),
                headers={"content-length": str(len(content))},
            )
        )
    )
    manager = LocalModelManager(tmp_path / "Models", client=client)
    manifest = manifest_for(content)
    checks = 0

    def pause_after_first_chunk() -> bool:
        nonlocal checks
        checks += 1
        return checks == 3

    with pytest.raises(LocalModelPaused):
        manager.install(manifest, should_pause=pause_after_first_chunk)

    assert list((tmp_path / "Models" / ".downloads").rglob("*.part"))
    assert manager.remove(manifest).state == "NOT_INSTALLED"
    assert not list((tmp_path / "Models" / ".downloads").rglob("*.part"))


def test_model_install_rejects_invalid_content_length(tmp_path: Path) -> None:
    client = httpx.Client(
        transport=httpx.MockTransport(
            lambda _request: httpx.Response(
                200,
                content=b"expected",
                headers={"content-length": "invalid"},
            )
        )
    )
    manager = LocalModelManager(tmp_path / "Models", client=client)

    with pytest.raises(LocalModelError) as caught:
        manager.install(manifest_for(b"expected"))

    assert caught.value.code == "LOCAL_MODEL_VERIFICATION_FAILED"
