import unittest

try:
    import onnx
except ImportError:
    raise unittest.SkipTest("Decoder tooling requires the isolated conversion environment")
from onnx import helper as h, TensorProto as T
from decoder_probe import free_names, split_decoder, bounded_reference


def value(name, dtype=T.FLOAT, shape=()):
    return h.make_tensor_value_info(name, dtype, list(shape))


def fixture():
    body = h.make_graph([
        h.make_node("Identity", ["condition"], ["next_condition"]),
        h.make_node("Add", ["state", "increment"], ["next_state"]),
    ], "body", [value("iteration", T.INT64), value("condition", T.BOOL), value("state")],
        [value("next_condition", T.BOOL), value("next_state")])
    graph = h.make_graph([
        h.make_node("Constant", [], ["increment"], value=h.make_tensor("one", T.FLOAT, [], [1.0])),
        h.make_node("Constant", [], ["start_condition"], value=h.make_tensor("true", T.BOOL, [], [True])),
        h.make_node("ReduceMean", ["x"], ["initial_state"], keepdims=0),
        h.make_node("Loop", ["", "start_condition", "initial_state"], ["result"], body=body),
    ], "test", [value("x", shape=(1, 1, 384, 384))], [value("result")])
    return h.make_model(graph, opset_imports=[h.make_opsetid("", 18)], ir_version=9)


class DecoderTests(unittest.TestCase):
    def test_nested_branch_outputs_are_captures(self):
        branch = h.make_graph([], "branch", [], [value("external")])
        graph = h.make_graph([h.make_node("If", ["condition"], ["result"],
                                         then_branch=branch, else_branch=branch)], "outer",
                             [value("condition", T.BOOL)], [value("result")])
        self.assertEqual(free_names(graph), {"external"})

    def test_split_promotes_weights_and_removes_unused_iteration(self):
        original = fixture()
        before = original.SerializeToString()
        initialization, step, _ = split_decoder(original)
        self.assertEqual(original.SerializeToString(), before)
        self.assertEqual([v.name for v in step.graph.initializer], ["increment"])
        self.assertEqual([v.name for v in step.graph.input], ["condition", "state"])
        self.assertFalse(any(n.op_type == "Loop" for n in initialization.graph.node))
        self.assertEqual([v.name for v in step.graph.output],
                         ["epistoria_step_output_0", "epistoria_step_output_1"])
        onnx.checker.check_model(bounded_reference(original, 3))

    def test_unknown_capture_fails_closed(self):
        original = fixture()
        original.graph.node[0].op_type = "UnsupportedWeightProducer"
        with self.assertRaisesRegex(ValueError, "Unrecognized decoder capture"):
            split_decoder(original)

    def test_repeated_steps_match_bounded_loop(self):
        try:
            import onnxruntime as ort
            import numpy as np
        except ImportError:
            self.skipTest("ONNX Runtime is required for numeric parity")
        original = fixture()
        initialization, step, _ = split_decoder(original)
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        def session(model):
            return ort.InferenceSession(model.SerializeToString(), options, providers=["CPUExecutionProvider"])
        pixels = np.zeros((1, 1, 384, 384), dtype=np.float32)
        condition, state = session(initialization).run(None, {"x": pixels})
        decoder = session(step)
        for _ in range(3):
            condition, state = decoder.run(None, {"condition": condition, "state": state})
        expected = session(bounded_reference(original, 3)).run(None, {"x": pixels})[0]
        np.testing.assert_array_equal(state, expected)
        self.assertEqual(float(state), 3.0)


if __name__ == "__main__":
    unittest.main()
