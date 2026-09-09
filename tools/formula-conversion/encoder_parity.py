"""Synthetic tensor parity, not handwriting accuracy. Reads no notebook content."""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime as ort


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--encoder-dir", type=Path, required=True)
    args = parser.parse_args()
    root = args.encoder_dir
    output_path = root / "parity.json"
    if output_path.exists():
        parser.error("Existing parity report; preserve it before rerunning")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    original = ort.InferenceSession(str(root / "encoder.onnx"), options, providers=["CPUExecutionProvider"])
    lowered = ort.InferenceSession(str(root / "encoder-explicit-padding.onnx"), options, providers=["CPUExecutionProvider"])
    coreml = ct.models.MLModel(str(root / "encoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    rng = np.random.default_rng(42)
    fixtures = {"zero": np.zeros((1, 1, 384, 384), dtype=np.float32),
                "one": np.ones((1, 1, 384, 384), dtype=np.float32),
                "noise": rng.uniform(-1, 1, (1, 1, 384, 384)).astype(np.float32)}
    report = {"productionApproved": False, "decoder": "not converted", "fixtures": {}}
    for name, image in fixtures.items():
        expected = original.run(None, {"x": image})[0]
        padded = lowered.run(None, {"x": image})[0]
        predicted = next(iter(coreml.predict({"image": image}).values()))
        report["fixtures"][name] = {
            "shape": list(expected.shape),
            "paddingMaxAbsoluteError": float(np.max(np.abs(padded - expected))),
            "coreMLMaxAbsoluteError": float(np.max(np.abs(predicted - expected))),
            "paddingPassed": bool(np.allclose(padded, expected, atol=1e-5, rtol=1e-5)),
            "coreMLPassed": bool(np.allclose(predicted, expected, atol=1e-3, rtol=1e-3)),
        }
    report["passed"] = all(item["paddingPassed"] and item["coreMLPassed"] for item in report["fixtures"].values())
    output_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
