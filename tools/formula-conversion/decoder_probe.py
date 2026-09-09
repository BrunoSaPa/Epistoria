"""Expose the pinned ONNX generation body as a step; verify before Core ML porting."""
import argparse
import copy
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

from encoder_probe import ENCODER_OUTPUT


def free_names(graph):
    """Include lexical captures in nested branches, including direct graph outputs."""
    defined = {v.name for v in graph.input} | {v.name for v in graph.initializer}
    defined |= {name for node in graph.node for name in node.output}
    used = {name for node in graph.node for name in node.input if name}
    used |= {v.name for v in graph.output}
    for node in graph.node:
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.GRAPH:
                used |= free_names(attribute.g)
            elif attribute.type == onnx.AttributeProto.GRAPHS:
                for child in attribute.graphs:
                    used |= free_names(child)
    return used - defined


def split_decoder(model):
    loops = [node for node in model.graph.node if node.op_type == "Loop"]
    if len(loops) != 1:
        raise ValueError("Expected one top-level generation loop")
    loop = loops[0]
    body = copy.deepcopy(next(a.g for a in loop.attribute if a.name == "body"))
    if len(body.output) != len(body.input) - 1:
        raise ValueError("Scan outputs are not supported by this probe")
    producers = {name: node for node in model.graph.node for name in node.output}
    captures = sorted(free_names(body))
    dynamic = []
    for name in captures:
        node = producers.get(name)
        if node is not None and node.op_type == "Constant" and len(node.attribute) == 1 and node.attribute[0].type == onnx.AttributeProto.TENSOR:
            weight = copy.deepcopy(node.attribute[0].t)
            weight.name = name
            body.initializer.append(weight)
        elif name == ENCODER_OUTPUT:
            dynamic.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, [1, 144, 2048]))
        else:
            raise ValueError(f"Unrecognized decoder capture: {name}")
    body.input.extend(dynamic)
    # Several exported state outputs alias the same tensor. Give each slot an explicit name.
    for index, output in enumerate(body.output):
        alias = f"epistoria_step_output_{index}"
        body.node.append(helper.make_node("Identity", [output.name], [alias]))
        output.name = alias
    step = helper.make_model(body, opset_imports=model.opset_import, ir_version=model.ir_version)
    onnx.checker.check_model(step)

    values = []
    for external, internal in zip(loop.input[1:], body.input[1:len(loop.input)]):
        value = copy.deepcopy(internal)
        value.name = external
        values.append(value)
    values.extend(dynamic)
    needed = {value.name for value in values}
    pending = list(needed)
    while pending:
        node = producers.get(pending.pop())
        if node is None:
            continue
        if node.op_type in ("Loop", "If"):
            raise ValueError("Initialization crosses control flow")
        for name in node.input:
            if name and name not in needed:
                needed.add(name)
                pending.append(name)
    nodes = [copy.deepcopy(n) for n in model.graph.node if any(x in needed for x in n.output)]
    graph = helper.make_graph(nodes, "decoder-initialization", model.graph.input, values, model.graph.initializer)
    initialization = helper.make_model(graph, opset_imports=model.opset_import, ir_version=model.ir_version)
    onnx.checker.check_model(initialization)
    # Exported diagnostic slots are carried out but never read. Their initial scalars have
    # misleading rank annotations; do not expose unused inputs as decoder requirements.
    inputs = list(step.graph.input)
    del step.graph.input[:]
    used = free_names(step.graph)
    step.graph.input.extend(value for value in inputs if value.name in used)
    onnx.checker.check_model(step)
    return initialization, step, loop


def bounded_reference(model, limit):
    reference = copy.deepcopy(model)
    loop = next(n for n in reference.graph.node if n.op_type == "Loop")
    reference.graph.initializer.append(numpy_helper.from_array(np.array(limit, dtype=np.int64), "epistoria_step_limit"))
    loop.input[0] = "epistoria_step_limit"
    body = next(a.g for a in loop.attribute if a.name == "body")
    del reference.graph.output[:]
    for name, internal in zip(loop.output, body.output[1:]):
        value = copy.deepcopy(internal)
        value.name = name
        reference.graph.output.append(value)
    onnx.checker.check_model(reference)
    return reference


def verify(model, initialization, step, limit):
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.log_severity_level = 4
    def session(graph):
        return ort.InferenceSession(graph.SerializeToString(), options, providers=["CPUExecutionProvider"])
    init_session, step_session = session(initialization), session(step)
    reference_session = session(bounded_reference(model, limit))
    state_count = len(step.graph.output)
    loop = next(n for n in model.graph.node if n.op_type == "Loop")
    original_body = next(a.g for a in loop.attribute if a.name == "body")
    input_names = [value.name for value in original_body.input] + [ENCODER_OUTPUT]
    records = []
    for label, pixels in [("zeros", np.zeros((1, 1, 384, 384), np.float32)),
                          ("seeded-noise", np.random.default_rng(42).uniform(-1, 1, (1, 1, 384, 384)).astype(np.float32))]:
        try:
            expected = reference_session.run(None, {"x": pixels})
        except Exception as error:
            raise RuntimeError(f"Original bounded ONNX loop cannot execute ({label}); parity not established: {error}") from error
        state = init_session.run(None, {"x": pixels})
        captures = state[state_count:]
        state = state[:state_count]
        steps = 0
        while bool(np.asarray(state[0]).item()) and steps < limit:
            inputs = [np.array([steps], dtype=np.int64)] + state + captures
            available = dict(zip(input_names, inputs))
            state = step_session.run(None, {info.name: available[info.name] for info in step.graph.input})
            steps += 1
        errors = []
        for actual, original in zip(state[1:], expected):
            if actual.shape != original.shape:
                raise ValueError("Decoder state shape mismatch")
            if np.issubdtype(actual.dtype, np.floating):
                np.testing.assert_allclose(actual, original, atol=1e-5, rtol=1e-5)
                errors.append(float(np.max(np.abs(actual - original))) if actual.size else 0.0)
            else:
                np.testing.assert_array_equal(actual, original)
        records.append({"fixture": label, "steps": steps, "stateSlots": len(expected),
                        "maxAbsoluteError": max(errors, default=0.0), "passed": True})
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--steps", type=int, choices=range(1, 9), default=3)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, mode=0o700, exist_ok=False)
    report = {"productionApproved": False, "coreMLDecoder": "not converted", "stage": "split-decoder"}
    try:
        model = onnx.load(args.onnx)
        initialization, step, _ = split_decoder(model)
        report["stepInputs"] = [v.name for v in step.graph.input]
        report["stepOutputs"] = len(step.graph.output)
        report["capturedWeights"] = len(step.graph.initializer)
        onnx.save(initialization, args.output_dir / "initialization.onnx")
        onnx.save(step, args.output_dir / "decoder-step.onnx")
        report["stage"] = "step-parity"
        report["parity"] = verify(model, initialization, step, args.steps)
        report["stage"] = "onnx-step-verified-not-production"
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:2000]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
