"""Isolated, opt-in export feasibility probe. Never loads notebook data or enables iPad OCR."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
import uuid

MANIFEST = Path(__file__).with_name("candidate.json")


def verified(path, expected):
    if not path.is_file() or path.stat().st_size != expected["bytes"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == expected["sha256"]


def download(path, expected, url):
    """Bound bytes during receipt; publish only a completely verified public model file."""
    staging = path.with_suffix(path.suffix + ".partial")
    if staging.exists():
        raise ValueError("Existing partial file: use a new work directory")
    try:
        with urllib.request.urlopen(url, timeout=180) as response, staging.open("xb") as target:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > expected["bytes"]:
                    raise ValueError("Model exceeds pinned byte count")
                target.write(chunk)
        if not verified(staging, expected):
            raise ValueError("Model size or checksum mismatch")
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)


def operation_counts(value):
    counts = Counter()
    if isinstance(value, dict):
        # PIR operation records have inputs/outputs; attributes also use '#'.
        if isinstance(value.get("#"), str) and "O" in value:
            counts[value["#"]] += 1
        for child in value.values():
            counts.update(operation_counts(child))
    elif isinstance(value, list):
        for child in value:
            counts.update(operation_counts(child))
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--download", action="store_true", help="Approve pinned public model download")
    parser.add_argument("--export-onnx", action="store_true", help="Run intermediate export, not Core ML conversion")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    root = args.work_dir.resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, expected in manifest["files"].items():
        destination = root / name
        if not verified(destination, expected):
            if not args.download:
                parser.error("Verified model missing. Pass --download to approve downloading it.")
            if destination.exists():
                parser.error("Existing invalid file: use a new work directory; nothing overwritten.")
            download(destination, expected,
                     f'https://huggingface.co/{manifest["repository"]}/resolve/{manifest["revision"]}/{name}')
    config = json.loads((root / "config.json").read_text())
    graph = json.loads((root / "inference.json").read_text())
    report = {
        "repository": manifest["repository"], "revision": manifest["revision"],
        "verified": True, "productionApproved": False,
        "operations": dict(operation_counts(graph)),
        "preprocessing": config["PreProcess"]["transform_ops"],
        "tokenizerDecoder": config["PostProcess"]["character_dict"]["fast_tokenizer_file"]["decoder"],
        "onnxExport": "not run", "coreMLConversion": "not run", "physicalValidation": "not run",
    }
    if args.export_onnx:
        output = root / "candidate.onnx"
        if output.exists():
            parser.error("Existing ONNX output: use a new work directory; nothing overwritten.")
        command = [str(Path(sys.executable).with_name("paddle2onnx")),
                   "--model_dir", str(root), "--model_filename", "inference.json",
                   "--params_filename", "inference.pdiparams", "--save_file", str(output),
                   "--opset_version", "18", "--enable_onnx_checker", "True",
                   "--optimize_tool", "None"]
        report["exportLog"] = f"export-{uuid.uuid4().hex}.log"
        with (root / report["exportLog"]).open("x") as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300)
                report["onnxExport"] = "passed" if result.returncode == 0 and output.is_file() else "failed"
                report["exportExitCode"] = result.returncode
            except subprocess.TimeoutExpired:
                report["onnxExport"] = "timeout"
    (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("verified", "onnxExport", "coreMLConversion", "productionApproved")}))
    return 1 if report["onnxExport"] in ("failed", "timeout") else 0


if __name__ == "__main__":
    sys.exit(main())
