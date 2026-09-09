"""Convert a neural decoder step and test Core ML at multiple cache lengths."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

import numpy as np
import onnx

from decoder_probe import split_decoder
from neural_decoder_probe import runtime_session

OUTPUT_INDICES = (0, 1, 2, 5, 6)  # Cross-attention caches are immutable inputs, not new outputs.


def validate_inputs(values, phase):
    if phase not in ("cached", "prefill"):
        raise ValueError("Unknown decoder phase")
    if len(values) != (9 if phase == "cached" else 2):
        raise ValueError("Unexpected decoder input count")
    tokens = values[0]
    if tokens.shape != (1, 3) or tokens.dtype != np.int64 or np.any(tokens < 0) or np.any(tokens >= 50000):
        raise ValueError("Invalid decoder tokens")
    if phase == "prefill":
        shapes = [(1, 144, 2048)]
    else:
        if values[1].ndim != 4:
            raise ValueError("Invalid cache rank")
        length = values[1].shape[2]
        if not 3 <= length <= 1020 or length % 3:
            raise ValueError("Invalid cache length")
        shapes = [(1, 16, length if i in (0, 1, 4, 5) else 144, 24) for i in range(8)]
    for value, shape in zip(values[1:], shapes):
        if value.shape != shape or value.dtype != np.float32 or not np.isfinite(value).all():
            raise ValueError("Invalid decoder tensor")


def fixtures(original, model, prefill, phase="cached"):
    initialization, _, loop = split_decoder(original)
    body = next(a.g for a in loop.attribute if a.name == "body")
    mapping = dict(zip(loop.input[1:], [v.name for v in body.input[1:]]))
    initializer, first = runtime_session(initialization), runtime_session(prefill)
    cached = runtime_session(model)
    records = []
    for label, image in [("zeros", np.zeros((1, 1, 384, 384), np.float32)),
                         ("noise", np.random.default_rng(42).uniform(-1, 1, (1, 1, 384, 384)).astype(np.float32))]:
        values = initializer.run(None, {"x": image})
        inputs = {mapping.get(info.name, info.name): v for info, v in zip(initialization.graph.output, values)}
        outputs = first.run(None, {v.name: inputs[v.name] for v in prefill.graph.input})
        if phase == "prefill":
            records.append((label, [inputs[body.input[4].name].copy(), inputs["p2o.pd_op.transpose.0.0"].copy()], outputs))
            inputs[body.input[4].name] = np.array([[1, 2, 49999]], np.int64)
            outputs = first.run(None, {v.name: inputs[v.name] for v in prefill.graph.input})
            records.append((f"{label}-special-tokens", [inputs[body.input[4].name].copy(), inputs["p2o.pd_op.transpose.0.0"].copy()], outputs))
            continue
        for iteration in range(1, 4):
            for info, output in zip(body.input[7:15], outputs[1:]):
                inputs[info.name] = output
            inputs[body.input[4].name] = np.array([[5 + iteration, 17 + iteration, 39 + iteration]], np.int64)
            inputs[body.input[6].name] = np.concatenate([inputs[body.input[6].name], inputs[body.input[4].name]], axis=1)
            outputs = cached.run(None, {v.name: inputs[v.name] for v in model.graph.input})
            records.append((f"{label}-{iteration}", [inputs[v.name].copy() for v in model.graph.input], outputs))
        for info in body.input[7:15]:
            if info.name in (body.input[9].name, body.input[10].name, body.input[13].name, body.input[14].name):
                continue
            inputs[info.name] = np.resize(inputs[info.name], (1, 16, 1020, 24))
        inputs[body.input[4].name] = np.array([[1, 2, 49999]], np.int64)
        inputs[body.input[6].name] = np.zeros((1, 1023), np.int64)
        outputs = cached.run(None, {v.name: inputs[v.name] for v in model.graph.input})
        records.append((f"{label}-maximum-cache", [inputs[v.name].copy() for v in model.graph.input], outputs))
    return records


def input_contracts(model, example, ct):
    result = []
    for index, (info, value) in enumerate(zip(model.graph.input, example)):
        shape = list(value.shape)
        if value.ndim == 4 and value.shape[2] == 3:
            shape[2] = ct.RangeDim(lower_bound=3, upper_bound=1020, default=3)
        result.append(ct.TensorType(name=f"input_{index}", shape=tuple(shape),
                                    dtype=np.int32 if value.dtype == np.int64 else np.float32))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", required=True, type=Path)
    parser.add_argument("--neural-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--phase", choices=["cached", "prefill"], default="cached")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = {"productionApproved": False, "stage": "fixtures", "phase": args.phase,
              "tolerance": {"atol": 1e-3, "rtol": 1e-3}, "computeUnits": "CPU_ONLY",
              "precision": "FLOAT32", "physicalIPadValidation": "not run"}
    try:
        report["inputSHA256"] = {}
        for name, path in [("original", args.onnx), ("prefill", args.neural_dir / "prefill.onnx"),
                           ("cached", args.neural_dir / "cached.onnx")]:
            with path.open("rb") as stream:
                report["inputSHA256"][name] = hashlib.file_digest(stream, "sha256").hexdigest()
        report["runtimeVersions"] = {name: importlib.metadata.version(name) for name in
                                     ["torch", "onnx", "onnxruntime", "numpy", "coremltools"]}
        import torch
        from formula_decoder_torch import CachedFormulaDecoder, PrefillFormulaDecoder
        import coremltools as ct
        torch.set_num_threads(2)
        model = onnx.load(args.neural_dir / "cached.onnx")
        prefill = onnx.load(args.neural_dir / "prefill.onnx")
        cases = fixtures(onnx.load(args.onnx), model, prefill, args.phase)
        if args.phase == "cached":
            cases = [(label, [values[0]] + values[2:], outputs) for label, values, outputs in cases]
            del model.graph.input[1]  # History content is not consumed by this neural step.
        for _, values, _ in cases:
            validate_inputs(values, args.phase)
        indices = OUTPUT_INDICES if args.phase == "cached" else tuple(range(9))
        converted = (CachedFormulaDecoder(prefill) if args.phase == "cached" else PrefillFormulaDecoder(prefill)).eval()
        if args.phase == "prefill":
            del model.graph.input[:]
            model.graph.input.extend([onnx.helper.make_tensor_value_info("tokens", onnx.TensorProto.INT64, [1, 3]),
                                      onnx.helper.make_tensor_value_info("encoder", onnx.TensorProto.FLOAT, [1, 144, 2048])])
        class OutputsOnly(torch.nn.Module):
            def __init__(self, decoder):
                super().__init__()
                self.decoder = decoder
            def forward(self, *inputs):
                outputs = self.decoder(*inputs)
                return tuple(outputs[index] for index in indices)
        converted = OutputsOnly(converted).eval()
        report["stage"] = "trace"
        example = tuple(torch.from_numpy(v.copy()) for v in cases[0][1])
        with torch.inference_mode():
            traced = torch.jit.trace(converted, example, check_inputs=[tuple(torch.from_numpy(v.copy()) for v in cases[2][1])])
            for label, values, expected in cases:
                actual = traced(*(torch.from_numpy(v.copy()) for v in values))
                for left, right in zip(actual, [expected[i] for i in indices]):
                    np.testing.assert_allclose(left.numpy(), right, atol=1e-3, rtol=1e-3)
        report["stage"] = "coreml-conversion"
        report["inputs"] = [v.name for v in model.graph.input]
        report["referenceOutputIndices"] = list(indices)
        package = ct.convert(traced, inputs=input_contracts(model, cases[0][1], ct),
                             outputs=[ct.TensorType(name=f"output_{i}") for i in range(len(indices))],
                             minimum_deployment_target=ct.target.iOS18,
                             compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY)
        package.save(str(args.output_dir / f"{args.phase}.mlpackage"))
        report["packageBytes"] = sum(path.stat().st_size for path in (args.output_dir / f"{args.phase}.mlpackage").rglob("*") if path.is_file())
        report["stage"] = "coreml-parity"
        report["cases"] = []
        for label, values, expected in cases:
            inputs = {f"input_{i}": v.astype(np.int32) if v.dtype == np.int64 else v for i, v in enumerate(values)}
            actual = package.predict(inputs)
            errors = []
            for index, reference in enumerate([expected[i] for i in indices]):
                output = actual[f"output_{index}"]
                if output.shape != reference.shape or not np.isfinite(output).all():
                    raise ValueError("Invalid Core ML output")
                np.testing.assert_allclose(output, reference, atol=1e-3, rtol=1e-3)
                errors.append(float(np.max(np.abs(output - reference))))
            report["cases"].append({"fixture": label, "maxAbsoluteError": max(errors), "passed": True})
        report["stage"] = f"{args.phase}-coreml-verified-not-production"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:2000]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
