import unittest
from types import SimpleNamespace

try:
    import onnx
except ImportError:
    raise unittest.SkipTest("Decoder tooling requires the isolated conversion environment")
import numpy as np
from coreml_decoder_probe import validate_inputs, input_contracts, OUTPUT_INDICES


def cached_inputs(length=3):
    return [np.zeros((1, 3), np.int64)] + [
        np.zeros((1, 16, length if i in (0, 1, 4, 5) else 144, 24), np.float32) for i in range(8)]


class CoreMLDecoderTests(unittest.TestCase):
    def test_valid_boundary_shapes(self):
        for length in [3, 6, 1020]:
            validate_inputs(cached_inputs(length), "cached")
        validate_inputs([np.array([[1, 2, 49999]], np.int64), np.zeros((1, 144, 2048), np.float32)], "prefill")

    def test_invalid_tokens_and_nonfinite_values(self):
        values = cached_inputs()
        for token in [-1, 50000]:
            values[0][0, 0] = token
            with self.assertRaisesRegex(ValueError, "tokens"):
                validate_inputs(values, "cached")
        values = cached_inputs()
        values[1][0, 0, 0, 0] = np.nan
        with self.assertRaisesRegex(ValueError, "tensor"):
            validate_inputs(values, "cached")

    def test_inconsistent_or_unbounded_cache_fails(self):
        for length in [0, 1, 4, 1023]:
            with self.assertRaisesRegex(ValueError, "cache length"):
                validate_inputs(cached_inputs(length), "cached")
        values = cached_inputs()
        values[2] = np.zeros((1, 16, 6, 24), np.float32)
        with self.assertRaisesRegex(ValueError, "tensor"):
            validate_inputs(values, "cached")
        with self.assertRaisesRegex(ValueError, "input count"):
            validate_inputs(values[:-1], "cached")

    def test_coreml_ranges_only_apply_to_self_attention_cache(self):
        fake_ct = SimpleNamespace(RangeDim=lambda **kw: kw, TensorType=lambda **kw: kw)
        model = SimpleNamespace(graph=SimpleNamespace(input=[SimpleNamespace(name=str(i)) for i in range(9)]))
        contracts = input_contracts(model, cached_inputs(), fake_ct)
        self.assertEqual(contracts[0]["dtype"], np.int32)
        for i in [1, 2, 5, 6]:
            self.assertEqual(contracts[i]["shape"][2], {"lower_bound": 3, "upper_bound": 1020, "default": 3})
        for i in [3, 4, 7, 8]:
            self.assertEqual(contracts[i]["shape"][2], 144)
        self.assertEqual(OUTPUT_INDICES, (0, 1, 2, 5, 6))


if __name__ == "__main__":
    unittest.main()
