"""Verify bounded end-to-end Core ML token generation against pinned native Paddle."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import time

import numpy as np

from coreml_decoder_probe import validate_inputs
from neural_decoder_probe import paddle_predictor
from formula_tokenizer import load_tokenizer, decode_generated, verify_reference_vectors


def checked_tensor(value, shape, label):
    if not isinstance(value, np.ndarray) or value.dtype != np.float32 or value.shape != shape or not np.isfinite(value).all():
        raise ValueError(f"Invalid {label}")
    return value


def generate(encoder, prefill, cached, pixels, *, max_steps=341, cancelled=lambda: False):
    """Run batch-one inference. Preserve the final EOS group for reference comparison."""
    if not 1 <= max_steps <= 341:
        raise ValueError("Invalid generation limit")
    checked_tensor(pixels, (1, 1, 384, 384), "image tensor")
    if cancelled():
        raise InterruptedError("Recognition cancelled")
    encoded = encoder.predict({"image": pixels})
    if len(encoded) != 1:
        raise ValueError("Unexpected encoder output contract")
    features = checked_tensor(next(iter(encoded.values())), (1, 144, 2048), "encoder features")
    tokens = np.zeros((1, 3), np.int64)
    history = [tokens]
    caches = []
    timings = []
    for iteration in range(max_steps):
        if cancelled():
            raise InterruptedError("Recognition cancelled")
        values = [tokens, features] if iteration == 0 else [tokens] + caches
        validate_inputs(values, "prefill" if iteration == 0 else "cached")
        started = time.perf_counter()
        result = (prefill if iteration == 0 else cached).predict({
            f"input_{index}": value.astype(np.int32) if value.dtype == np.int64 else value
            for index, value in enumerate(values)})
        timings.append(time.perf_counter() - started)
        if cancelled():
            raise InterruptedError("Recognition cancelled")
        expected_count = 9 if iteration == 0 else 5
        if set(result) != {f"output_{i}" for i in range(expected_count)}:
            raise ValueError("Unexpected decoder output contract")
        logits = checked_tensor(result["output_0"], (1, 3, 50000), "decoder logits")
        length = (iteration + 1) * 3
        if iteration == 0:
            caches = [checked_tensor(result[f"output_{i + 1}"],
                                     (1, 16, length if i in (0, 1, 4, 5) else 144, 24), "initial cache")
                      for i in range(8)]
        else:
            for output_index, cache_index in enumerate((0, 1, 4, 5), start=1):
                caches[cache_index] = checked_tensor(result[f"output_{output_index}"], (1, 16, length, 24), "updated cache")
        tokens = np.argmax(logits, axis=-1).astype(np.int64)
        history.append(tokens)
        if np.any(tokens == 2):
            return np.concatenate(history, axis=1), timings
    raise ValueError("Generation reached its bound without EOS")


def package_fingerprint(directory):
    """Digest relative names and complete file contents; refuse links outside the package."""
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("Expected a local model package directory")
    digest, total, count = hashlib.sha256(), 0, 0
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError("Model package must not contain symbolic links")
        if not path.is_file():
            continue
        relative = path.relative_to(directory).as_posix().encode()
        size = path.stat().st_size
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(size.to_bytes(8, "big"))
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        total += size
        count += 1
    if not count:
        raise ValueError("Empty model package")
    return {"sha256": digest.hexdigest(), "bytes": total, "files": count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--prefill", type=Path, required=True)
    parser.add_argument("--cached", type=Path, required=True)
    parser.add_argument("--paddle-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = {"productionApproved": False, "stage": "load", "physicalIPadValidation": "not run",
              "formulaAccuracy": "not measured", "cases": []}
    try:
        import coremltools as ct
        report["runtimeVersions"] = {name: importlib.metadata.version(name) for name in
                                     ("coremltools", "numpy", "paddlepaddle", "tokenizers")}
        report["packages"] = {name: package_fingerprint(path) for name, path in
                              [("encoder", args.encoder), ("prefill", args.prefill), ("cached", args.cached)]}
        models = [ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
                  for path in (args.encoder, args.prefill, args.cached)]
        native = paddle_predictor(args.paddle_dir)
        tokenizer = load_tokenizer(args.paddle_dir / "config.json")
        report["tokenizerVectors"] = verify_reference_vectors(tokenizer)
        report["stage"] = "complete-token-parity"
        for label, pixels in [("zeros", np.zeros((1, 1, 384, 384), np.float32)),
                              ("seeded-noise", np.random.default_rng(42).uniform(-1, 1, (1, 1, 384, 384)).astype(np.float32))]:
            print(f"Checking {label}", flush=True)
            started = time.perf_counter()
            actual, timings = generate(*models, pixels)
            elapsed = time.perf_counter() - started
            native.get_input_handle(native.get_input_names()[0]).copy_from_cpu(pixels)
            native.run()
            expected = native.get_output_handle(native.get_output_names()[0]).copy_to_cpu()
            match = actual.shape == expected.shape and np.array_equal(actual, expected)
            entry = {"fixture": label, "exactRawTokenMatch": match,
                     "coreMLTokenCount": int(actual.size), "paddleTokenCount": int(expected.size),
                     "macCPUSeconds": elapsed, "decoderCalls": len(timings),
                     "macCPUStepP95Seconds": float(np.percentile(timings, 95))}
            report["cases"].append(entry)
            if not match:
                overlap = min(actual.size, expected.size)
                different = np.flatnonzero(actual.reshape(-1)[:overlap] != expected.reshape(-1)[:overlap])
                entry["firstDifferentTokenIndex"] = int(different[0]) if different.size else overlap
                raise ValueError("Complete Core ML tokens differ from native Paddle")
            actual_text = decode_generated(tokenizer, actual)
            expected_text = decode_generated(tokenizer, expected)
            if actual_text != expected_text:
                raise ValueError("Decoded text differs from native output")
            entry["exactDecodedTextMatch"] = True
            entry["decodedCharacterCount"] = len(actual_text)
            entry["mathNormalization"] = "not applied"
        report["stage"] = "complete-synthetic-token-parity-passed-not-production"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:1500]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
