from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

try:
    import onnx
except ImportError:
    raise unittest.SkipTest("Pipeline tooling requires the isolated conversion environment")
import numpy as np
from coreml_pipeline_probe import generate, package_fingerprint


def models(eos=True):
    encoder = SimpleNamespace(predict=lambda _: {"features": np.zeros((1, 144, 2048), np.float32)})
    def logits(tokens):
        values = np.zeros((1, 3, 50000), np.float32)
        for index, token in enumerate(tokens):
            values[0, index, token] = 1
        return values
    def prefill(_):
        return {"output_0": logits([4, 5, 6]), **{
            f"output_{i + 1}": np.full((1, 16, 3 if i in (0, 1, 4, 5) else 144, 24), i, np.float32)
            for i in range(8)}}
    def cached(inputs):
        assert inputs["input_0"].dtype == np.int32
        for input_index, marker in [(3, 2), (4, 3), (7, 6), (8, 7)]:
            np.testing.assert_array_equal(inputs[f"input_{input_index}"], marker)
        length = inputs["input_1"].shape[2] + 3
        return {"output_0": logits([7, 2 if eos else 8, 9]), **{
            f"output_{i}": np.zeros((1, 16, length, 24), np.float32) for i in range(1, 5)}}
    return encoder, SimpleNamespace(predict=prefill), SimpleNamespace(predict=cached)


class CoreMLPipelineTests(unittest.TestCase):
    def test_generation_preserves_final_group_and_cross_caches(self):
        pixels = np.zeros((1, 1, 384, 384), np.float32)
        result, timings = generate(*models(), pixels, max_steps=2)
        np.testing.assert_array_equal(result, [[0, 0, 0, 4, 5, 6, 7, 2, 9]])
        self.assertEqual(len(timings), 2)
        np.testing.assert_array_equal(pixels, 0)

    def test_generation_limit_and_cancellation(self):
        pixels = np.zeros((1, 1, 384, 384), np.float32)
        with self.assertRaisesRegex(ValueError, "without EOS"):
            generate(*models(False), pixels, max_steps=2)
        with self.assertRaisesRegex(ValueError, "generation limit"):
            generate(*models(), pixels, max_steps=342)
        with self.assertRaises(InterruptedError):
            generate(*models(), pixels, cancelled=lambda: True)
        calls = 0
        def cancelled():
            nonlocal calls
            calls += 1
            return calls == 3  # After first decoder prediction; do not publish its result.
        with self.assertRaises(InterruptedError):
            generate(*models(), pixels, cancelled=cancelled)

    def test_bad_encoder_and_decoder_outputs_fail(self):
        encoder, prefill, cached = models()
        pixels = np.zeros((1, 1, 384, 384), np.float32)
        with self.assertRaisesRegex(ValueError, "encoder features"):
            generate(SimpleNamespace(predict=lambda _: {"features": np.zeros((1,), np.float32)}), prefill, cached, pixels)
        with self.assertRaisesRegex(ValueError, "output contract"):
            generate(encoder, SimpleNamespace(predict=lambda _: {}), cached, pixels)
        bad = SimpleNamespace(predict=lambda _: {"output_0": np.full((1, 3, 50000), np.nan, np.float32),
                                                **{f"output_{i}": np.zeros((1,), np.float32) for i in range(1, 10)}})
        with self.assertRaises(ValueError):
            generate(encoder, bad, cached, pixels)

    def test_fingerprint_covers_names_contents_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaisesRegex(ValueError, "Empty"):
                package_fingerprint(directory)
            source = directory / "model"
            source.write_bytes(b"one")
            first = package_fingerprint(directory)
            source.write_bytes(b"two")
            self.assertNotEqual(first["sha256"], package_fingerprint(directory)["sha256"])
            previous = package_fingerprint(directory)
            source.rename(directory / "renamed")
            self.assertNotEqual(previous["sha256"], package_fingerprint(directory)["sha256"])
            (directory / "link").symlink_to(directory / "renamed")
            with self.assertRaisesRegex(ValueError, "symbolic"):
                package_fingerprint(directory)


if __name__ == "__main__":
    unittest.main()
