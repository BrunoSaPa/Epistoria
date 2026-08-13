from __future__ import annotations

from uuid import UUID

import httpx

from epistoria_worker.api import EpistoriaAPI


def test_base_url_keeps_v1_path_and_asset_descriptor_uses_url() -> None:
    requests: list[httpx.Request] = []
    asset_id = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url == httpx.URL("https://sync.example.test/v1/health"):
            return httpx.Response(200, json={"status": "ok"})
        if request.url == httpx.URL(
            f"https://sync.example.test/v1/assets/{asset_id}/download"
        ):
            return httpx.Response(
                200,
                json={
                    "assetId": str(asset_id),
                    "encryptedByteSize": "6",
                    "url": "https://objects.example.test/signed-object",
                    "expiresInSeconds": 900,
                },
            )
        if request.url == httpx.URL("https://objects.example.test/signed-object"):
            return httpx.Response(200, content=b"sealed")
        return httpx.Response(404)

    with EpistoriaAPI(
        base_url="https://sync.example.test/v1",
        device_token="t" * 43,
        device_id=UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        transport=httpx.MockTransport(handler),
    ) as api:
        assert api.health() == {"status": "ok"}
        assert api.download_encrypted_asset(asset_id, maximum_bytes=1024) == b"sealed"

    assert requests[0].headers.get("authorization") is None
    assert requests[1].headers["authorization"] == "Bearer " + "t" * 43
    assert requests[2].headers.get("authorization") is None
