"""Check bounded preprocessing against checksum-pinned deployed PaddleX operations."""
import argparse
import ast
import hashlib
import importlib.metadata
from io import BytesIO
import json
import math
from pathlib import Path
from typing import List, Tuple, Union, Optional

import cv2
import numpy as np
from PIL import Image, ImageOps

from formula_image_probe import expanded_fixture_images
from formula_preprocess import prepare_image

REFERENCE_SHA256 = "4a2c197634a210a90cca7bf3f417ce594b610db0058d2ccfa060dc2dcfb752eb"


def reference_decoder(path):
    if path.stat().st_size != 37283 or hashlib.sha256(path.read_bytes()).hexdigest() != REFERENCE_SHA256:
        raise ValueError("Upstream reference source failed checksum verification")
    # Only inspected inference classes are evaluated, after exact source verification. Avoid
    # importing unrelated training augmentations, optional dependencies and update checks.
    tree = ast.parse(path.read_text())
    names = {"UniMERNetImgDecode", "UniMERNetTestTransform", "LatexImageFormat"}
    selected = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name in names]
    if len(selected) != 3:
        raise ValueError("Missing reference classes")
    for node in selected:
        node.decorator_list = []  # Remove benchmark/dependency decorators, not image operations.
    scope = {"Image": Image, "ImageOps": ImageOps, "np": np, "cv2": cv2,
             "List": List, "Tuple": Tuple, "Union": Union, "Optional": Optional, "math": math}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), "exec"), scope)
    geometry = scope["UniMERNetImgDecode"]([384, 384])
    transform = scope["UniMERNetTestTransform"]()
    formatting = scope["LatexImageFormat"]()
    def predict(encoded):
        with Image.open(BytesIO(encoded)) as image:
            return formatting(transform(geometry([np.asarray(image.convert("RGB"))])))[0]
    return predict


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"productionApproved": False, "referenceSourceSHA256": REFERENCE_SHA256, "cases": []}
    try:
        report["runtimeVersions"] = {name: importlib.metadata.version(name) for name in
                                     ["numpy", "Pillow", "opencv-python-headless"]}
        decoder = reference_decoder(args.reference_source)
        for name, image, _ in expanded_fixture_images():
            buffer = BytesIO()
            image.save(buffer, format="PNG")
            actual, _ = prepare_image(buffer.getvalue())
            expected = decoder(buffer.getvalue())
            np.testing.assert_array_equal(actual, expected)
            report["cases"].append({"fixture": name, "maxAbsoluteError": float(np.max(np.abs(actual - expected))), "passed": True})
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:1500]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
