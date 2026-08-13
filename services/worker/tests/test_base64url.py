import pytest

from epistoria_worker import base64url


def test_round_trip_and_reject_noncanonical_values() -> None:
    assert base64url.encode(b"\xfb\xff\x00") == "-_8A"
    assert base64url.decode("-_8A") == b"\xfb\xff\x00"
    for invalid in ["", "-_8A=", "+/8A", "a b", "é"]:
        with pytest.raises(base64url.Base64UrlError):
            base64url.decode(invalid)
