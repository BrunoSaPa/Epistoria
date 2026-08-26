from __future__ import annotations

from collections.abc import Iterable
from typing import Any
from uuid import UUID

import httpx

from .models import AIJobLease


class APIError(RuntimeError):
    def __init__(self, message: str, *, status_code: int | None = None, retryable: bool = True):
        super().__init__(message)
        self.status_code = status_code
        self.retryable = retryable


class EpistoriaAPI:
    def __init__(
        self,
        *,
        base_url: str,
        device_token: str,
        device_id: UUID,
        timeout_seconds: float = 30,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._device_token = device_token
        self.device_id = device_id
        self._client = httpx.Client(
            base_url=base_url.rstrip("/") + "/",
            timeout=httpx.Timeout(timeout_seconds, connect=10),
            follow_redirects=False,
            headers={"User-Agent": "epistoria-worker/0.1"},
            transport=transport,
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> EpistoriaAPI:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        headers = dict(kwargs.pop("headers", {}))
        headers["Authorization"] = f"Bearer {self._device_token}"
        try:
            response = self._client.request(method, path, headers=headers, **kwargs)
        except httpx.HTTPError as error:
            raise APIError("Epistoria API is unreachable", retryable=True) from error
        if response.is_error:
            retryable = response.status_code in {408, 425, 429} or response.status_code >= 500
            raise APIError(
                f"Epistoria API returned HTTP {response.status_code}",
                status_code=response.status_code,
                retryable=retryable,
            )
        return response

    def health(self) -> dict[str, Any]:
        try:
            response = self._client.get("health")
            response.raise_for_status()
        except httpx.HTTPError as error:
            raise APIError("Epistoria API health check failed") from error
        payload = response.json()
        if not isinstance(payload, dict):
            raise APIError("Epistoria API health response is invalid", retryable=False)
        return payload

    def claim_job(self, *, lease_seconds: int = 900) -> AIJobLease | None:
        body = self._request("POST", "ai-jobs/claim", json={"leaseSeconds": lease_seconds}).json()
        raw_job = body.get("job")
        return None if raw_job is None else AIJobLease.model_validate(raw_job)

    def job_status(self, job_id: UUID) -> str:
        payload = self._request("GET", f"ai-jobs/{job_id}").json()
        status = payload.get("status")
        if not isinstance(status, str):
            raise APIError("AI job status response is invalid", retryable=False)
        return status

    def fail_job(self, job_id: UUID, *, error_code: str, retryable: bool) -> None:
        self._request(
            "POST",
            f"ai-jobs/{job_id}/fail",
            json={"errorCode": error_code, "retryable": retryable},
        )

    def complete_job(self, job_id: UUID, *, artifact_entity_id: UUID) -> None:
        self._request(
            "POST",
            f"ai-jobs/{job_id}/complete",
            json={"artifactEntityId": str(artifact_entity_id)},
        )

    def push_mutations(self, mutations: Iterable[dict[str, Any]]) -> None:
        mutation_list = list(mutations)
        response = self._request(
            "POST",
            "sync/push",
            json={
                "wireVersion": 1,
                "deviceId": str(self.device_id),
                "mutations": mutation_list,
            },
        ).json()
        results = response.get("results", [])
        if len(results) != len(mutation_list) or any(
            result.get("status") != "ACCEPTED" for result in results
        ):
            raise APIError(
                "encrypted artifact synchronization produced a conflict", retryable=False
            )

    def download_encrypted_asset(self, asset_id: UUID, *, maximum_bytes: int) -> bytes:
        descriptor = self._request("GET", f"assets/{asset_id}/download").json()
        url = descriptor.get("url")
        if not isinstance(url, str):
            raise APIError("asset download descriptor is invalid", retryable=False)
        try:
            with self._client.stream("GET", url) as response:
                response.raise_for_status()
                content_length = response.headers.get("content-length")
                if content_length is not None and int(content_length) > maximum_bytes:
                    raise APIError(
                        "encrypted asset exceeds the worker memory limit", retryable=False
                    )
                output = bytearray()
                for chunk in response.iter_bytes():
                    output.extend(chunk)
                    if len(output) > maximum_bytes:
                        raise APIError(
                            "encrypted asset exceeds the worker memory limit", retryable=False
                        )
                return bytes(output)
        except APIError:
            raise
        except (httpx.HTTPError, ValueError) as error:
            raise APIError("encrypted asset download failed", retryable=True) from error
