import pytest

from epistoria_worker.recovery import (
    RecoveryError,
    account_key_from_words,
    words_from_account_key,
)


def test_24_words_encode_the_account_key_itself() -> None:
    key = bytes(range(32))
    words = words_from_account_key(key)
    assert len(words.split()) == 24
    assert account_key_from_words(words) == key


def test_changed_word_fails_checksum() -> None:
    words = words_from_account_key(bytes(range(32))).split()
    words[-1] = "abandon" if words[-1] != "abandon" else "ability"
    with pytest.raises(RecoveryError):
        account_key_from_words(" ".join(words))
