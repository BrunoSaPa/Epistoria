import unittest

try:
    import onnx
except ImportError:
    raise unittest.SkipTest("Neural decoder tooling requires the isolated conversion environment")
from onnx import helper as h, TensorProto as T
from neural_decoder_probe import prune, specialize_cache_branch, verify_specialization, generate_tokens, paddle_predictor
from types import SimpleNamespace
from pathlib import Path
import tempfile


def value(name, dtype=T.FLOAT):
    return h.make_tensor_value_info(name, dtype, [])


def branch_fixture():
    branches = {}
    for branch, operation in [("then_branch", "Add"), ("else_branch", "Sub")]:
        branches[branch] = h.make_graph([h.make_node(operation, ["x", "weight"], [branch])],
                                       branch, [], [value(branch)])
    graph = h.make_graph([
        h.make_node("Constant", [], ["weight"], value=h.make_tensor("w", T.FLOAT, [], [2.])),
        h.make_node("Constant", [], ["unused"], value=h.make_tensor("u", T.FLOAT, [], [9.])),
        h.make_node("If", ["condition"], ["result"], **branches),
        h.make_node("Identity", ["unused"], ["bookkeeping"]),
    ], "test", [value("x"), value("condition", T.BOOL)], [value("result"), value("bookkeeping")])
    return h.make_model(graph, opset_imports=[h.make_opsetid("", 18)], ir_version=9)


class NeuralDecoderTests(unittest.TestCase):
    def test_prune_keeps_branch_captures_and_excludes_bookkeeping(self):
        model = branch_fixture()
        before = model.SerializeToString()
        result = prune(model, [value("result")])
        self.assertEqual(model.SerializeToString(), before)
        self.assertEqual([n.op_type for n in result.graph.node], ["Constant", "If"])
        self.assertEqual(result.graph.node[0].output[0], "weight")
        self.assertEqual([v.name for v in result.graph.input], ["x", "condition"])

    def test_missing_dependency_fails(self):
        with self.assertRaisesRegex(ValueError, "Unresolved neural dependency"):
            prune(branch_fixture(), [value("missing")])

    def test_both_specializations_preserve_values_and_check_conditions(self):
        try:
            import onnxruntime
            import numpy as np
        except ImportError:
            self.skipTest("ONNX Runtime is required for numeric parity")
        neural = prune(branch_fixture(), [value("result")])
        for cached in [False, True]:
            specialized, conditions = specialize_cache_branch(neural, cached)
            self.assertNotIn("If", [n.op_type for n in specialized.graph.node])
            self.assertEqual([v.name for v in specialized.graph.input], ["x"])
            inputs = {"x": np.array(5., np.float32), "condition": np.array(cached)}
            outputs, error = verify_specialization(neural, specialized, conditions, inputs, cached)
            self.assertEqual(error, 0)
            self.assertEqual(float(outputs[0]), 7. if cached else 3.)
            inputs["condition"] = np.array(not cached)
            with self.assertRaisesRegex(ValueError, "branch conditions"):
                verify_specialization(neural, specialized, conditions, inputs, cached)

    def test_generation_retains_final_group_and_enforces_bound(self):
        import numpy as np
        body = SimpleNamespace(input=[SimpleNamespace(name=f"state_{i}") for i in range(31)])
        inputs = {"state_4": np.zeros((1, 3), np.int64), "state_6": np.zeros((1, 3), np.int64)}
        class FakeSession:
            def __init__(self, tokens):
                self.tokens = tokens
            def get_inputs(self):
                return [SimpleNamespace(name="state_6")]
            def run(self, _, feed):
                logits = np.zeros((1, 3, 50000), np.float32)
                for index, token in enumerate(self.tokens):
                    logits[0, index, token] = 1
                cache = np.zeros((1, 16, feed["state_6"].shape[1], 24), np.float32)
                return [logits] + [cache] * 8
        initial, cached = FakeSession([8, 9, 10]), FakeSession([11, 2, 12])
        result = generate_tokens(initial, cached, inputs, body, max_steps=2)
        np.testing.assert_array_equal(result, [[0, 0, 0, 8, 9, 10, 11, 2, 12]])
        self.assertEqual(inputs["state_6"].shape, (1, 3))
        with self.assertRaisesRegex(ValueError, "without EOS"):
            generate_tokens(initial, initial, inputs, body, max_steps=1)
        with self.assertRaisesRegex(ValueError, "generation limit"):
            generate_tokens(initial, cached, inputs, body, max_steps=342)

    def test_invalid_generation_logits_fail(self):
        import numpy as np
        body = SimpleNamespace(input=[SimpleNamespace(name=f"state_{i}") for i in range(31)])
        inputs = {"state_4": np.zeros((1, 3), np.int64), "state_6": np.zeros((1, 3), np.int64)}
        invalid = SimpleNamespace(get_inputs=lambda: [],
                                  run=lambda *_: [np.full((1, 3, 50000), np.nan, np.float32)])
        with self.assertRaisesRegex(ValueError, "Invalid generation logits"):
            generate_tokens(invalid, invalid, inputs, body)

    def test_native_reference_requires_verified_model_files(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "pinned verification"):
                paddle_predictor(Path(directory))


if __name__ == "__main__":
    unittest.main()
