"""Small owner-authored printed-equation smoke corpus, not a handwriting benchmark."""
import argparse
import hashlib
import importlib.metadata
from io import BytesIO
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from coreml_pipeline_probe import generate, package_fingerprint
from formula_preprocess import prepare_image
from formula_tokenizer import load_tokenizer, decode_generated
from neural_decoder_probe import paddle_predictor

FONT_PATH = Path("/System/Library/Fonts/Supplemental/Times New Roman.ttf")
ITALIC_FONT_PATH = FONT_PATH.with_name("Times New Roman Italic.ttf")


def fixture_images(font_path=FONT_PATH):
    font = ImageFont.truetype(str(font_path), 52)
    cases = [("linear", "x + 2 = 5", ["x+2=5"]),
             ("polynomial", "x² + y² = z²", ["x^{2}+y^{2}=z^{2}", "x^2+y^2=z^2"]),
             ("factorization", "(x + 1)(x − 1) = x² − 1", ["(x+1)(x-1)=x^{2}-1", "(x+1)(x-1)=x^2-1"]),
             ("greek", "α + β = γ", ["\\alpha+\\beta=\\gamma"])]
    results = []
    for name, text, expected in cases:
        image = Image.new("RGB", (900, 160), "white")
        ImageDraw.Draw(image).text((35, 35), text, font=font, fill="black")
        results.append((name, image, expected))
    image = Image.new("RGB", (500, 230), "white")
    draw = ImageDraw.Draw(image)
    draw.text((65, 25), "a + b", font=font, fill="black")
    draw.line((50, 100, 225, 100), fill="black", width=3)
    draw.text((110, 112), "c", font=font, fill="black")
    results.append(("fraction", image, ["\\frac{a+b}{c}"]))
    return results


def expanded_fixture_images():
    cases = [(f"regular/{name}", image, answers) for name, image, answers in fixture_images()]
    cases += [(f"italic/{name}", image, answers) for name, image, answers in fixture_images(ITALIC_FONT_PATH)]
    for variant, ink in [("blue", (20, 60, 200)), ("red", (200, 40, 20)), ("low-contrast", (155, 155, 155))]:
        for name, image, answers in fixture_images():
            intensity = np.asarray(image.convert("L"), dtype=np.float32)[..., None] / 255
            colored = np.rint(np.asarray(ink) + intensity * (255 - np.asarray(ink))).astype(np.uint8)
            cases.append((f"{variant}/{name}", Image.fromarray(colored), answers))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("encoder", "prefill", "cached", "paddle-dir", "output-dir"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--expanded", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"productionApproved": False, "corpus": "five-owner-authored-printed-equations/v1",
              "handwritingValidated": False, "cases": [],
              "metric": "Exact text ignoring ASCII spaces and using predefined alternatives; not semantic equivalence"}
    try:
        import coremltools as ct
        report["fontSHA256"] = hashlib.sha256(FONT_PATH.read_bytes()).hexdigest()
        if args.expanded:
            report["corpus"] = "five-expressions-five-rendering-conditions/v2"
            report["italicFontSHA256"] = hashlib.sha256(ITALIC_FONT_PATH.read_bytes()).hexdigest()
        report["uniqueExpressions"] = 5
        report["runtimeVersions"] = {name: importlib.metadata.version(name) for name in
                                     ["Pillow", "opencv-python-headless", "numpy", "coremltools", "paddlepaddle", "tokenizers"]}
        report["packages"] = {name: package_fingerprint(path) for name, path in
                              [("encoder", args.encoder), ("prefill", args.prefill), ("cached", args.cached)]}
        models = [ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
                  for path in (args.encoder, args.prefill, args.cached)]
        native = paddle_predictor(args.paddle_dir)
        tokenizer = load_tokenizer(args.paddle_dir / "config.json")
        fixtures = expanded_fixture_images() if args.expanded else fixture_images()
        for name, image, accepted in fixtures:
            image.save(args.output_dir / f"{name.replace('/', '-')}.png")  # Generated fixtures only.
            buffer = BytesIO()
            image.save(buffer, format="PNG")
            pixels, preparation = prepare_image(buffer.getvalue())
            print(f"Checking {name}", flush=True)
            native.get_input_handle(native.get_input_names()[0]).copy_from_cpu(pixels)
            native.run()
            reference = native.get_output_handle(native.get_output_names()[0]).copy_to_cpu()
            actual, _ = generate(*models, pixels)
            text, reference_text = decode_generated(tokenizer, actual), decode_generated(tokenizer, reference)
            report["cases"].append({"fixture": name, "preparation": preparation,
                                     "imageSHA256": hashlib.sha256(buffer.getvalue()).hexdigest(),
                                     "rawTokenParity": bool(np.array_equal(actual, reference)),
                                     "textParity": text == reference_text, "recognized": text,
                                     "expectedAlternatives": accepted,
                                     "expectedTextMatch": text.replace(" ", "") in accepted})
        report["parityPassed"] = all(case["rawTokenParity"] and case["textParity"] for case in report["cases"])
        report["expectedTextMatchCount"] = sum(case["expectedTextMatch"] for case in report["cases"])
        report["caseCount"] = len(report["cases"])
        report["byCondition"] = {}
        for case in report["cases"]:
            condition = case["fixture"].split("/")[0] if args.expanded else "regular"
            group = report["byCondition"].setdefault(condition, {"cases": 0, "expectedTextMatches": 0, "parityMatches": 0})
            group["cases"] += 1
            group["expectedTextMatches"] += int(case["expectedTextMatch"])
            group["parityMatches"] += int(case["rawTokenParity"] and case["textParity"])
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)[:1500]}
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if "failure" in report or not report.get("parityPassed") or report.get("expectedTextMatchCount") != report.get("caseCount") else 0


if __name__ == "__main__":
    raise SystemExit(main())
