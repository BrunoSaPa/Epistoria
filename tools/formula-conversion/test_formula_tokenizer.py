import unittest
from pathlib import Path
from types import SimpleNamespace
import tempfile
import numpy as np
from formula_tokenizer import content_ids, decode_generated, load_tokenizer


class FormulaTokenizerTests(unittest.TestCase):
    def test_stops_at_eos_not_end_of_group(self):
        self.assertEqual(content_ids([0, 0, 0, 4, 2, 99]), [4])
        self.assertEqual(content_ids([[0, 0, 0, 1, 4, 2]]), [4])

    def test_rejects_truncated_invalid_or_unknown_tokens(self):
        for values in [[0, 0, 0, 4, 5, 6], [0, 0, 0, -1, 4, 2], [0, 0, 0, 50000, 4, 2],
                       [0, 0, 0, 3, 4, 2], [0, 0, 0, 0, 4, 2], [0, 0, 0, 4, 2],
                       [0, 0, 0, 4, 2, 5, 6, 7, 8], [1, 0, 0, 4, 5, 2],
                       [0., 0., 0., 4., 5., 2.], [0] * 1029]:
            with self.subTest(values=values[:9]), self.assertRaises(ValueError):
                content_ids(values)

    def test_decoding_preserves_text_without_repair(self):
        text = r"\text{área de un círculo} = \pi r^2"
        tokenizer = SimpleNamespace(decode=lambda ids, skip_special_tokens: text if ids == [4] else "")
        self.assertEqual(decode_generated(tokenizer, [0, 0, 0, 4, 2, 99]), text)
        for text in ["", " ", "\ufffd"]:
            tokenizer = SimpleNamespace(decode=lambda *args, **kwargs: text)
            with self.assertRaises(ValueError):
                decode_generated(tokenizer, [0, 0, 0, 4, 2, 99])

    def test_configuration_requires_pinned_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text("{}")
            with self.assertRaisesRegex(ValueError, "pinned verification"):
                load_tokenizer(path)
