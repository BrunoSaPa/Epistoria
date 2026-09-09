import unittest

try:
    import onnx
except ImportError:
    raise unittest.SkipTest("Encoder tooling requires the isolated conversion environment")
from onnx import helper, TensorProto
from encoder_probe import ENCODER_OUTPUT, extract_encoder, explicit_padding


class EncoderTests(unittest.TestCase):
    def test_duplicate_node_names_do_not_include_decoder_weights(self):
        tensor = helper.make_tensor("weight", TensorProto.FLOAT, [], [1.0])
        nodes = [helper.make_node("Constant", [], ["needed"], value=tensor),
                 helper.make_node("Constant", [], ["unused"], value=tensor),
                 helper.make_node("Add", ["x", "needed"], ["added"]),
                 helper.make_node("ReduceMean", ["added"], [ENCODER_OUTPUT], axes=[1], keepdims=0)]
        graph = helper.make_graph(nodes, "test", [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 1, 384, 384])],
                                  [helper.make_tensor_value_info(ENCODER_OUTPUT, TensorProto.FLOAT, [1, 384, 384])])
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
        result = extract_encoder(model)
        self.assertEqual([tensor.name for tensor in result.graph.initializer], ["needed"])

    def test_unit_stride_padding_does_not_need_known_spatial_dimensions(self):
        node = helper.make_node("MaxPool", ["x"], ["y"], kernel_shape=[2, 2], strides=[1, 1], auto_pad="SAME_UPPER")
        graph = helper.make_graph([node], "test", [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 1, None, None])],
                                  [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 1, None, None])])
        result = explicit_padding(helper.make_model(graph))
        attrs = {a.name: helper.get_attribute_value(a) for a in result.graph.node[0].attribute}
        self.assertEqual(attrs["pads"], [0, 0, 1, 1])
        self.assertEqual(attrs["auto_pad"], b"NOTSET")


if __name__ == "__main__":
    unittest.main()
