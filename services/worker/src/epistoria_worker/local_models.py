from __future__ import annotations

import hashlib
import os
import shutil
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import httpx


class LocalModelError(RuntimeError):
    def __init__(self, message: str, *, code: str, retryable: bool):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class LocalModelPaused(RuntimeError):
    """Stops a download while preserving verified partial bytes for a later retry."""


@dataclass(frozen=True)
class ModelFile:
    name: str
    byte_size: int
    sha256: str


@dataclass(frozen=True)
class LocalModelManifest:
    model_id: str
    revision: str
    license: str
    repository_url: str
    files: tuple[ModelFile, ...]

    @property
    def expected_bytes(self) -> int:
        return sum(item.byte_size for item in self.files)


PP_FORMULANET_PLUS_S = LocalModelManifest(
    model_id="PP-FormulaNet_plus-S",
    revision="3d46f557e3a1752f4bf81202395af3b5ecfadfd2",
    license="Apache-2.0",
    repository_url="https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-S",
    files=(
        ModelFile(
            "config.json",
            3_951_676,
            "ddf1f951ceeb10c2b9de3ae255b62de59299b1028f87878177e86c9604fe3610",
        ),
        ModelFile(
            "inference.json",
            506_956,
            "01238434e33df83588e2627f350559b576e34551d2b2ffea148345032de56c00",
        ),
        ModelFile(
            "inference.pdiparams",
            256_845_006,
            "e464f94412feaa98f8791eacc84684f887b3569e30e80c52b8112e9cf7d4069b",
        ),
        ModelFile(
            "inference.yml",
            2_244_564,
            "96062655d94c21d39274328dbc82c1a487e66addb8425f5a7fd5b7dfb2421ec3",
        ),
    ),
)


@dataclass(frozen=True)
class LocalModelStatus:
    state: Literal["NOT_INSTALLED", "INSTALLED", "INVALID"]
    expected_bytes: int
    verified_bytes: int
    directory: Path | None


class LocalModelManager:
    """Installs public model files without ever accepting an unverified runtime download."""

    def __init__(self, root: Path, *, client: httpx.Client | None = None) -> None:
        self._root = root
        self._client = client

    def status(self, manifest: LocalModelManifest = PP_FORMULANET_PLUS_S) -> LocalModelStatus:
        directory = self._directory(manifest)
        if not directory.is_dir() or directory.is_symlink():
            return LocalModelStatus("NOT_INSTALLED", manifest.expected_bytes, 0, None)
        verified = 0
        for item in manifest.files:
            path = directory / item.name
            if not path.is_file() or path.is_symlink() or path.stat().st_size != item.byte_size:
                return LocalModelStatus("INVALID", manifest.expected_bytes, verified, None)
            if self._sha256(path) != item.sha256:
                return LocalModelStatus("INVALID", manifest.expected_bytes, verified, None)
            verified += item.byte_size
        return LocalModelStatus("INSTALLED", manifest.expected_bytes, verified, directory)

    def install(
        self,
        manifest: LocalModelManifest = PP_FORMULANET_PLUS_S,
        *,
        should_pause: Callable[[], bool] | None = None,
    ) -> LocalModelStatus:
        current = self.status(manifest)
        if current.state == "INSTALLED":
            return current
        if current.state == "INVALID":
            raise LocalModelError(
                "the installed model failed verification; remove it before reinstalling",
                code="LOCAL_MODEL_INVALID",
                retryable=False,
            )
        self._root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self._root, 0o700)
        downloads = self._root / ".downloads"
        downloads.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(downloads, 0o700)
        staging = downloads / manifest.model_id / manifest.revision
        staging.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(staging, 0o700)
        client = self._client or httpx.Client(follow_redirects=True, timeout=120)
        owns_client = self._client is None
        try:
            for item in manifest.files:
                self._download_file(
                    client,
                    manifest,
                    item,
                    staging / item.name,
                    should_pause=should_pause,
                )
            if should_pause is not None and should_pause():
                raise LocalModelPaused()
            target = self._directory(manifest)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if target.exists():
                raise LocalModelError(
                    "the model target appeared during installation",
                    code="LOCAL_MODEL_INSTALL_CONFLICT",
                    retryable=True,
                )
            os.replace(staging, target)
            status = self.status(manifest)
            if status.state != "INSTALLED":
                raise LocalModelError(
                    "the installed model did not pass final verification",
                    code="LOCAL_MODEL_INVALID",
                    retryable=False,
                )
            return status
        except LocalModelPaused:
            raise
        except LocalModelError:
            raise
        except (httpx.HTTPError, OSError) as error:
            raise LocalModelError(
                "the verified model download failed",
                code="LOCAL_MODEL_DOWNLOAD_FAILED",
                retryable=True,
            ) from error
        finally:
            if owns_client:
                client.close()
            if staging.exists() and self.status(manifest).state == "INSTALLED":
                shutil.rmtree(staging)

    def remove(self, manifest: LocalModelManifest = PP_FORMULANET_PLUS_S) -> LocalModelStatus:
        directory = self._directory(manifest)
        expected_parent = self._root / manifest.model_id
        if directory.parent != expected_parent or directory.name != manifest.revision:
            raise LocalModelError(
                "refusing to remove an unexpected model path",
                code="LOCAL_MODEL_PATH_INVALID",
                retryable=False,
            )
        if directory.exists():
            if directory.is_symlink() or not directory.is_dir():
                raise LocalModelError(
                    "refusing to remove a non-directory model target",
                    code="LOCAL_MODEL_PATH_INVALID",
                    retryable=False,
                )
            shutil.rmtree(directory)
        staging = self._root / ".downloads" / manifest.model_id / manifest.revision
        expected_staging_parent = self._root / ".downloads" / manifest.model_id
        if staging.parent != expected_staging_parent or staging.name != manifest.revision:
            raise LocalModelError(
                "refusing to remove an unexpected model staging path",
                code="LOCAL_MODEL_PATH_INVALID",
                retryable=False,
            )
        if staging.exists():
            if staging.is_symlink() or not staging.is_dir():
                raise LocalModelError(
                    "refusing to remove a non-directory model staging target",
                    code="LOCAL_MODEL_PATH_INVALID",
                    retryable=False,
                )
            shutil.rmtree(staging)
        return self.status(manifest)

    def _directory(self, manifest: LocalModelManifest) -> Path:
        return self._root / manifest.model_id / manifest.revision

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    @staticmethod
    def _download_file(
        client: httpx.Client,
        manifest: LocalModelManifest,
        item: ModelFile,
        destination: Path,
        *,
        should_pause: Callable[[], bool] | None = None,
    ) -> None:
        if should_pause is not None and should_pause():
            raise LocalModelPaused()
        if destination.is_file() and not destination.is_symlink():
            if destination.stat().st_size == item.byte_size \
                    and LocalModelManager._sha256(destination) == item.sha256:
                return
            destination.unlink()
        partial = destination.with_suffix(destination.suffix + ".part")
        if partial.is_symlink():
            raise LocalModelError(
                "refusing to resume an unexpected model path",
                code="LOCAL_MODEL_PATH_INVALID",
                retryable=False,
            )
        written = partial.stat().st_size if partial.exists() else 0
        if written > item.byte_size:
            partial.unlink()
            written = 0
        digest = hashlib.sha256()
        if written:
            with partial.open("rb") as existing:
                for chunk in iter(lambda: existing.read(1024 * 1024), b""):
                    digest.update(chunk)
        url = f"{manifest.repository_url}/resolve/{manifest.revision}/{item.name}"
        headers = {"Range": f"bytes={written}-"} if written else {}
        with client.stream("GET", url, headers=headers) as response:
            response.raise_for_status()
            if written and response.status_code != 206:
                written = 0
                digest = hashlib.sha256()
                partial.unlink(missing_ok=True)
            declared = response.headers.get("content-length")
            if declared is not None:
                try:
                    declared_bytes = int(declared)
                except ValueError as error:
                    raise LocalModelError(
                        "the model server declared an invalid file size",
                        code="LOCAL_MODEL_VERIFICATION_FAILED",
                        retryable=False,
                    ) from error
                expected_response_bytes = item.byte_size - written
                if declared_bytes != expected_response_bytes:
                    raise LocalModelError(
                        "the model server declared an unexpected file size",
                        code="LOCAL_MODEL_VERIFICATION_FAILED",
                        retryable=False,
                    )
            flags = os.O_WRONLY | os.O_CREAT | (os.O_APPEND if written else os.O_TRUNC)
            descriptor = os.open(partial, flags, 0o600)
            with os.fdopen(descriptor, "ab" if written else "wb") as handle:
                for chunk in response.iter_bytes():
                    if should_pause is not None and should_pause():
                        handle.flush()
                        os.fsync(handle.fileno())
                        raise LocalModelPaused()
                    written += len(chunk)
                    if written > item.byte_size:
                        raise LocalModelError(
                            "a model file exceeded its manifest size",
                            code="LOCAL_MODEL_VERIFICATION_FAILED",
                            retryable=False,
                        )
                    digest.update(chunk)
                    handle.write(chunk)
                handle.flush()
                os.fsync(handle.fileno())
        if written != item.byte_size or digest.hexdigest() != item.sha256:
            partial.unlink(missing_ok=True)
            raise LocalModelError(
                "a model file did not match its pinned manifest",
                code="LOCAL_MODEL_VERIFICATION_FAILED",
                retryable=False,
            )
        os.replace(partial, destination)
        os.chmod(destination, 0o600)
