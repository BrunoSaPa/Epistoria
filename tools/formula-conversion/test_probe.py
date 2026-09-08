import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from probe import download, operation_counts, verified


class ProbeTests(unittest.TestCase):
    def test_verified_download_and_wrong_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model"
            expected = {"bytes": 3, "sha256": hashlib.sha256(b"abc").hexdigest()}
            with patch("urllib.request.urlopen", return_value=io.BytesIO(b"abc")):
                download(path, expected, "https://example.invalid/model")
            self.assertTrue(verified(path, expected))
            self.assertFalse(verified(path, {"bytes": 3, "sha256": "0" * 64}))

    def test_oversized_or_truncated_input_never_installs(self):
        for content in [b"abcd", b"a", b"xyz"]:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "model"
                expected = {"bytes": 3, "sha256": hashlib.sha256(b"abc").hexdigest()}
                with patch("urllib.request.urlopen", return_value=io.BytesIO(content)):
                    with self.assertRaises(ValueError):
                        download(path, expected, "https://example.invalid/model")
                self.assertFalse(path.exists())
                self.assertFalse(path.with_suffix(".partial").exists())

    def test_partial_is_not_deleted_and_operations_are_recursive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model"
            partial = path.with_suffix(".partial")
            partial.touch()
            with self.assertRaises(ValueError):
                download(path, {}, "https://example.invalid/model")
            self.assertTrue(partial.exists())
        self.assertEqual(operation_counts({"#": "1.while", "O": [], "body": [
            {"#": "1.conv2d", "O": []}, {"#": "0.a_bool"}]}),
            {"1.while": 1, "1.conv2d": 1})


if __name__ == "__main__":
    unittest.main()
