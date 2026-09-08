"""Test the ONNX → PyTorch → Core ML bridge. Success is not recognition parity."""
import argparse
from collections import Counter
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    import onnx
    from onnx2torch import convert
    from onnx2torch.node_converters.registry import get_converter
    import torch
    import coremltools as ct

    model = onnx.load(args.onnx)
    report = {"stage": "onnx-check", "productionApproved": False}
    try:
        onnx.checker.check_model(model)
        report["operators"] = dict(Counter(node.op_type for node in model.graph.node))
        versions = {item.domain: item.version for item in model.opset_import}
        missing = set()
        def inspect(graph):
            for node in graph.node:
                try:
                    get_converter(node.op_type, versions[node.domain], node.domain)
                except NotImplementedError:
                    missing.add(node.op_type)
                for attribute in node.attribute:
                    if attribute.type == onnx.AttributeProto.GRAPH:
                        inspect(attribute.g)
        inspect(model.graph)
        report["unsupportedBridgeOperators"] = sorted(missing)
        report["stage"] = "onnx-to-torch"
        converted = convert(model).eval()
        report["stage"] = "trace"
        # Pinned PP-FormulaNet_plus-S input contract, not a production preprocessor.
        example = torch.zeros(1, 1, 384, 384)
        with torch.inference_mode():
            traced = torch.jit.trace(converted, example)
        report["stage"] = "coreml-conversion"
        coreml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=example.shape)],
                            minimum_deployment_target=ct.target.iOS18)
        coreml.save(str(args.output_dir / "candidate.mlpackage"))
        report["stage"] = "converted-not-validated"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:2000]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "operators"}))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
