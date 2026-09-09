"""Convert only the pinned FormulaNet visual encoder; the autoregressive decoder is excluded."""
import argparse
import copy
import json
from pathlib import Path

import onnx
from onnx import helper, TensorProto


ENCODER_OUTPUT = "p2o.pd_op.transpose.0.0"


def extract_encoder(model):
    producers = {name: node for node in model.graph.node for name in node.output}
    if ENCODER_OUTPUT not in producers:
        raise ValueError("Not the pinned encoder graph")
    needed = {ENCODER_OUTPUT}
    pending = [ENCODER_OUTPUT]
    while pending:
        name = pending.pop()
        node = producers.get(name)
        if node is None:
            continue
        for input_name in node.input:
            if input_name and input_name not in needed:
                needed.add(input_name)
                pending.append(input_name)
    nodes, weights = [], []
    for node in model.graph.node:
        if not any(name in needed for name in node.output):
            continue
        if node.op_type in ("Loop", "If"):
            raise ValueError("Encoder boundary crosses control flow")
        # The Paddle export represents weights as Constant nodes. onnx2torch Conv expects
        # initializer tensors. This is a representation change, not a weight transformation.
        if node.op_type == "Constant" and len(node.attribute) == 1 and node.attribute[0].type == onnx.AttributeProto.TENSOR:
            tensor = copy.deepcopy(node.attribute[0].t)
            tensor.name = node.output[0]
            weights.append(tensor)
        else:
            nodes.append(copy.deepcopy(node))
    input_info = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 1, 384, 384])
    output_info = helper.make_tensor_value_info(ENCODER_OUTPUT, TensorProto.FLOAT, [None, None, None])
    graph = helper.make_graph(nodes, "epistoria-formula-encoder", [input_info], [output_info], weights)
    result = helper.make_model(graph, opset_imports=model.opset_import, ir_version=model.ir_version)
    result = onnx.shape_inference.infer_shapes(result, strict_mode=True)
    onnx.checker.check_model(result)
    return result


def explicit_padding(model):
    """Lower SAME_UPPER using inferred static spatial sizes, with no changed image contract."""
    result = copy.deepcopy(model)
    shapes = {value.name: [d.dim_value for d in value.type.tensor_type.shape.dim]
              for value in list(model.graph.input) + list(model.graph.value_info)}
    weights = {tensor.name: list(tensor.dims) for tensor in model.graph.initializer}
    for node in result.graph.node:
        attributes = {item.name: helper.get_attribute_value(item) for item in node.attribute}
        if attributes.get("auto_pad") != b"SAME_UPPER":
            continue
        shape = shapes.get(node.input[0], [])
        kernel = attributes.get("kernel_shape", weights.get(node.input[1] if len(node.input) > 1 else "", [])[2:])
        strides = attributes.get("strides", [1, 1])
        dilations = attributes.get("dilations", [1, 1])
        if len(shape) != 4 or len(kernel) != 2 or (min(shape[2:]) <= 0 and strides != [1, 1]):
            raise ValueError("Cannot lower strided padding with unknown spatial shape")
        pads = []
        for size, width, stride, dilation in zip(shape[2:], kernel, strides, dilations):
            total = (width - 1) * dilation if stride == 1 else max(0,
                ((size + stride - 1) // stride - 1) * stride + (width - 1) * dilation + 1 - size)
            pads.append((total // 2, total - total // 2))
        retained = [item for item in node.attribute if item.name not in ("auto_pad", "pads")]
        del node.attribute[:]
        node.attribute.extend(retained)
        node.attribute.extend([helper.make_attribute("auto_pad", "NOTSET"),
                               helper.make_attribute("pads", [pads[0][0], pads[1][0], pads[0][1], pads[1][1]])])
    onnx.checker.check_model(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = {"stage": "extract-encoder", "productionApproved": False, "decoder": "not converted"}
    try:
        model = extract_encoder(onnx.load(args.onnx))
        onnx.save(model, args.output_dir / "encoder.onnx")
        model = explicit_padding(model)
        onnx.save(model, args.output_dir / "encoder-explicit-padding.onnx")
        report["stage"] = "encoder-to-torch"
        import torch
        from onnx2torch import convert
        import coremltools as ct
        import numpy as np
        torch.set_num_threads(2)
        converted = convert(model).eval()
        example = torch.zeros(1, 1, 384, 384)
        with torch.inference_mode():
            expected = converted(example).numpy()
            report["outputShape"] = list(expected.shape)
            report["stage"] = "encoder-trace"
            traced = torch.jit.trace(converted, example)
        report["stage"] = "encoder-coreml"
        coreml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=example.shape)],
                            minimum_deployment_target=ct.target.iOS18,
                            compute_precision=ct.precision.FLOAT32,
                            compute_units=ct.ComputeUnit.CPU_ONLY)
        coreml.save(str(args.output_dir / "encoder.mlpackage"))
        report["stage"] = "encoder-smoke-parity"
        output = next(iter(coreml.predict({"image": example.numpy()}).values()))
        report["maxAbsoluteError"] = float(np.max(np.abs(output - expected)))
        report["stage"] = "encoder-converted-not-production"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:2000]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
