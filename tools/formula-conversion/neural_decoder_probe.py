"""Isolate neural logits and attention caches from FormulaNet generation bookkeeping."""
import argparse
import copy
import hashlib
import importlib.metadata
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, TensorProto

from decoder_probe import free_names, split_decoder

LOGITS = "p2o.sub_block.pd_op.matmul.17.0"
CACHE_OUTPUTS = [
    "p2o.sub_block.pd_op.concat.0.0", "p2o.sub_block.pd_op.concat.1.0",
    "p2o.sub_block.pd_op.if.0.0", "p2o.sub_block.pd_op.if.0.1",
    "p2o.sub_block.pd_op.concat.2.0", "p2o.sub_block.pd_op.concat.3.0",
    "p2o.sub_block.pd_op.if.1.0", "p2o.sub_block.pd_op.if.1.1",
]


def prune(model, outputs):
    """Dependency slice including nested lexical captures; never key by node name."""
    result = copy.deepcopy(model)
    producers = {name: node for node in result.graph.node for name in node.output}
    available = set(producers) | {v.name for v in result.graph.input} | {v.name for v in result.graph.initializer}
    needed = {v.name for v in outputs}
    pending = list(needed)
    while pending:
        name = pending.pop()
        if name not in available:
            raise ValueError(f"Unresolved neural dependency: {name}")
        node = producers.get(name)
        if node is None:
            continue
        dependencies = {name for name in node.input if name}
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.GRAPH:
                dependencies |= free_names(attribute.g)
            elif attribute.type == onnx.AttributeProto.GRAPHS:
                for child in attribute.graphs:
                    dependencies |= free_names(child)
        for dependency in dependencies - needed:
            needed.add(dependency)
            pending.append(dependency)
    for field, items in [("node", [n for n in result.graph.node if any(name in needed for name in n.output)]),
                         ("input", [v for v in result.graph.input if v.name in needed]),
                         ("initializer", [v for v in result.graph.initializer if v.name in needed])]:
        target = getattr(result.graph, field)
        del target[:]
        target.extend(items)
    del result.graph.value_info[:]
    del result.graph.output[:]
    result.graph.output.extend(outputs)
    onnx.checker.check_model(result)
    return result


def extract_neural(step):
    outputs = [helper.make_tensor_value_info(LOGITS, TensorProto.FLOAT, [1, None, 50000])]
    outputs += [helper.make_tensor_value_info(name, TensorProto.FLOAT, [1, 16, None, 24])
                for name in CACHE_OUTPUTS]
    result = prune(step, outputs)
    branches = [n for n in result.graph.node if n.op_type == "If"]
    if len(branches) != 2 or any(n.op_type in {"Loop", "ArgMax", "BitwiseAnd", "BitwiseNot"}
                                 for n in result.graph.node):
        raise ValueError("Pinned neural boundary no longer matches")
    return result


def specialize_cache_branch(model, cached):
    """Create distinct prefill/cached graphs. Caller must validate branch conditions."""
    result = copy.deepcopy(model)
    nodes, conditions = [], []
    for node in result.graph.node:
        if node.op_type != "If":
            nodes.append(copy.deepcopy(node))
            continue
        conditions.append(node.input[0])
        branch = next(a.g for a in node.attribute if a.name == ("then_branch" if cached else "else_branch"))
        if branch.input or branch.initializer or len(branch.output) != len(node.output):
            raise ValueError("Unsupported branch interface")
        nodes.extend(copy.deepcopy(list(branch.node)))
        nodes.extend(helper.make_node("Identity", [source.name], [target])
                     for source, target in zip(branch.output, node.output))
    del result.graph.node[:]
    result.graph.node.extend(nodes)
    return prune(result, list(result.graph.output)), conditions


def runtime_session(model):
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.log_severity_level = 4
    return ort.InferenceSession(model.SerializeToString(), options, providers=["CPUExecutionProvider"])


def verify_specialization(neural, specialized, conditions, inputs, cached):
    # Execute the untouched conditions as well, rather than assuming empty/nonempty cache behavior.
    inspected = copy.deepcopy(neural)
    inspected.graph.output.extend(helper.make_tensor_value_info(name, TensorProto.BOOL, []) for name in conditions)
    reference = runtime_session(inspected).run(None, {v.name: inputs[v.name] for v in inspected.graph.input})
    if not all(np.asarray(value).size == 1 and bool(np.asarray(value).item()) == cached
               for value in reference[len(neural.graph.output):]):
        raise ValueError("Cache specialization does not match original branch conditions")
    actual = runtime_session(specialized).run(None, {v.name: inputs[v.name] for v in specialized.graph.input})
    if len(actual) != len(neural.graph.output) or len(reference) != len(actual) + len(conditions):
        raise ValueError("Neural output count mismatch")
    errors = []
    for left, right in zip(actual, reference):
        if left.shape != right.shape or not np.isfinite(left).all() or not np.isfinite(right).all():
            raise ValueError("Invalid neural output shape or nonfinite output")
        np.testing.assert_allclose(left, right, atol=1e-5, rtol=1e-5)
        errors.append(float(np.max(np.abs(left - right))) if left.size else 0.0)
    return actual, max(errors, default=0.0)


def verify_torch(converted, model, inputs, expected):
    import torch
    with torch.inference_mode():
        actual = converted(*(torch.from_numpy(inputs[v.name].copy()) for v in model.graph.input))
    if not isinstance(actual, (tuple, list)) or len(actual) != len(expected):
        raise ValueError("Torch decoder output contract mismatch")
    errors = []
    for value, reference in zip(actual, expected):
        array = value.numpy()
        if array.shape != reference.shape or not np.isfinite(array).all():
            raise ValueError("Invalid Torch decoder output")
        np.testing.assert_allclose(array, reference, atol=1e-3, rtol=1e-3)
        errors.append(float(np.max(np.abs(array - reference))) if array.size else 0.0)
    return max(errors, default=0.0)


def generate_tokens(prefill_session, cached_session, inputs, body, max_steps=341):
    """Pinned batch-one, three-token greedy decoding. Never return truncated output as complete."""
    inputs = {name: value.copy() for name, value in inputs.items()}
    if inputs[body.input[4].name].shape != (1, 3):
        raise ValueError("Only pinned batch-one, three-token generation is supported")
    if not 1 <= max_steps <= 341:
        raise ValueError("Invalid generation limit")
    for iteration in range(max_steps):
        session = prefill_session if iteration == 0 else cached_session
        outputs = session.run(None, {info.name: inputs[info.name] for info in session.get_inputs()})
        logits = outputs[0]
        if logits.shape != (1, 3, 50000) or not np.isfinite(logits).all():
            raise ValueError("Invalid generation logits")
        tokens = np.argmax(logits, axis=-1).astype(np.int64)
        history = np.concatenate([inputs[body.input[6].name], tokens], axis=1)
        # The original batch-one loop stops once an EOS occurs anywhere in the appended
        # group. Preserve the complete final group for raw-token reference comparison.
        if np.any(tokens == 2):
            return history
        inputs[body.input[4].name] = tokens
        inputs[body.input[6].name] = history
        for name, output in zip([v.name for v in body.input[7:15]], outputs[1:]):
            inputs[name] = output
    raise ValueError("Generation reached its bound without EOS")


def paddle_predictor(directory):
    from probe import MANIFEST, verified
    manifest = json.loads(MANIFEST.read_text())
    for name, expected in manifest["files"].items():
        if not verified(directory / name, expected):
            raise ValueError(f"Native reference file failed pinned verification: {name}")
    import paddle.inference as pi
    config = pi.Config(str(directory / "inference.json"), str(directory / "inference.pdiparams"))
    config.disable_gpu()
    config.set_cpu_math_library_num_threads(2)
    config.disable_glog_info()
    return pi.create_predictor(config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--verify-torch", action="store_true")
    parser.add_argument("--verify-paddle", action="store_true",
                        help="Compare bounded host generation against sibling native Paddle model files")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = {"productionApproved": False, "stage": "neural-extraction", "nativePaddleParity": "not run",
              "coreMLDecoder": "not converted", "onnxTolerance": {"atol": 1e-5, "rtol": 1e-5},
              "torchTolerance": {"atol": 1e-3, "rtol": 1e-3}}
    try:
        with args.onnx.open("rb") as source:
            report["inputSHA256"] = hashlib.file_digest(source, "sha256").hexdigest()
        report["runtimeVersions"] = {name: importlib.metadata.version(name) for name in
                                     (["onnx", "onnxruntime", "numpy", "torch", "onnx2torch"] if args.verify_torch
                                      else ["onnx", "onnxruntime", "numpy"])}
        original = onnx.load(args.onnx)
        initialization, step, loop = split_decoder(original)
        neural = extract_neural(step)
        prefill, conditions = specialize_cache_branch(neural, cached=False)
        cached, _ = specialize_cache_branch(neural, cached=True)
        for name, model in [("neural", neural), ("prefill", prefill), ("cached", cached)]:
            onnx.save(model, args.output_dir / f"{name}.onnx")
        report["stage"] = "neural-parity"
        torch_models = {}
        if args.verify_torch:
            import torch
            from onnx2torch import convert
            torch.set_num_threads(2)
            torch_models = {"prefill": convert(prefill).eval(), "cached": convert(cached).eval()}
        report["fixtures"] = []
        initializer = runtime_session(initialization)
        native = paddle_predictor(args.onnx.parent) if args.verify_paddle else None
        generator_sessions = (runtime_session(prefill), runtime_session(cached)) if native else None
        if native:
            report["nativePaddleParity"] = "running"
            report["runtimeVersions"]["paddlepaddle"] = importlib.metadata.version("paddlepaddle")
            report["generationFixtures"] = []
        body = next(a.g for a in loop.attribute if a.name == "body")
        mapping = dict(zip(loop.input[1:], [v.name for v in body.input[1:]]))
        for label, pixels in [("zeros", np.zeros((1, 1, 384, 384), np.float32)),
                              ("seeded-noise", np.random.default_rng(42).uniform(-1, 1, (1, 1, 384, 384)).astype(np.float32))]:
            values = initializer.run(None, {"x": pixels})
            inputs = {mapping.get(info.name, info.name): value for info, value in zip(initialization.graph.output, values)}
            if native:
                generated = generate_tokens(*generator_sessions, inputs, body)
                native.get_input_handle(native.get_input_names()[0]).copy_from_cpu(pixels)
                native.run()
                reference = native.get_output_handle(native.get_output_names()[0]).copy_to_cpu()
                np.testing.assert_array_equal(generated, reference)
                report["generationFixtures"].append({"fixture": label, "rawTokenCount": int(generated.size),
                                                      "exactMatch": True})
            outputs, error = verify_specialization(neural, prefill, conditions, inputs, cached=False)
            report["fixtures"].append({"fixture": label, "phase": "prefill", "maxAbsoluteError": error,
                                       "outputShapes": [list(v.shape) for v in outputs], "passed": True})
            if args.verify_torch:
                report["fixtures"][-1]["torchMaxAbsoluteError"] = verify_torch(torch_models["prefill"], prefill, inputs, outputs)
            # Cache reuse validates branch specialization only. These are synthetic teacher inputs,
            # not a claim to implement FormulaNet's multi-token generation algorithm.
            for iteration in range(1, 4):
                for name, output in zip([v.name for v in body.input[7:15]], outputs[1:]):
                    inputs[name] = output
                inputs[body.input[4].name] = np.array([[4 + iteration, 17 + iteration, 39 + iteration]], dtype=np.int64)
                inputs[body.input[6].name] = np.concatenate(
                    [inputs[body.input[6].name], inputs[body.input[4].name]], axis=1)
                outputs, error = verify_specialization(neural, cached, conditions, inputs, cached=True)
                report["fixtures"].append({"fixture": label, "phase": "cache-reuse", "iteration": iteration,
                                           "maxAbsoluteError": error, "outputShapes": [list(v.shape) for v in outputs], "passed": True})
                if args.verify_torch:
                    report["fixtures"][-1]["torchMaxAbsoluteError"] = verify_torch(torch_models["cached"], cached, inputs, outputs)
        report["stage"] = "neural-torch-verified-not-production" if args.verify_torch else "neural-onnx-verified-not-production"
        if native:
            report["nativePaddleParity"] = "synthetic-raw-tokens-passed-not-accuracy"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:2000]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
