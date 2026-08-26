from __future__ import annotations

import base64
import io
import platform
import re
import threading
from importlib import metadata
from pathlib import Path
from typing import Any, Protocol
from uuid import uuid4

from PIL import Image

from .local_models import PP_FORMULANET_PLUS_S, LocalModelManager
from .models import LocalOCRRegionV1, LocalOCRRequestV1, LocalOCRResponseV1, SourceRectangleV1


class LocalOCRError(RuntimeError):
    def __init__(self, message: str, *, code: str, retryable: bool):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class OCREngine(Protocol):
    def recognize(self, request: LocalOCRRequestV1) -> LocalOCRResponseV1: ...


def decode_image(value: str) -> bytes:
    try:
        data = base64.b64decode(value, validate=True)
        image = Image.open(io.BytesIO(data))
        width, height = image.size
        if (
            width <= 0
            or height <= 0
            or width > 4_096
            or height > 4_096
            or width * height > 12_000_000
        ):
            raise ValueError("image dimensions exceed the local OCR limit")
        image.verify()
    except Exception as error:
        raise LocalOCRError(
            "OCR input is not a valid bounded image",
            code="LOCAL_OCR_IMAGE_INVALID",
            retryable=False,
        ) from error
    if not data or len(data) > 825_000:
        raise LocalOCRError(
            "OCR input exceeds the local image limit",
            code="LOCAL_OCR_IMAGE_TOO_LARGE",
            retryable=False,
        )
    return data


class AppleVisionTextOCREngine:
    def recognize(self, request: LocalOCRRequestV1) -> LocalOCRResponseV1:
        if platform.system() != "Darwin":
            raise LocalOCRError(
                "Apple Vision OCR requires macOS",
                code="LOCAL_TEXT_OCR_UNAVAILABLE",
                retryable=False,
            )
        data = decode_image(request.image_content)
        try:
            import Foundation  # type: ignore[import-not-found]
            import Vision  # type: ignore[import-not-found]
        except ImportError as error:
            raise LocalOCRError(
                "install the macOS OCR runtime before processing Source scans",
                code="LOCAL_TEXT_OCR_RUNTIME_MISSING",
                retryable=False,
            ) from error

        recognized: list[LocalOCRRegionV1] = []

        def completed(vision_request: Any, recognition_error: Any) -> None:
            if recognition_error is not None:
                return
            for observation in vision_request.results() or []:
                candidates = observation.topCandidates_(3)
                if not candidates:
                    continue
                primary = candidates[0]
                bounds = observation.boundingBox()
                alternatives = [str(item.string()) for item in candidates[1:]]
                recognized.append(
                    LocalOCRRegionV1(
                        id=uuid4(),
                        kind="TEXT",
                        text=str(primary.string()),
                        confidence=float(primary.confidence()),
                        alternatives=alternatives,
                        rectangles=[
                            SourceRectangleV1(
                                x=float(bounds.origin.x),
                                y=float(1 - bounds.origin.y - bounds.size.height),
                                width=float(bounds.size.width),
                                height=float(bounds.size.height),
                            )
                        ],
                    )
                )

        request_handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(
            Foundation.NSData.dataWithBytes_length_(data, len(data)), {}
        )
        vision_request = Vision.VNRecognizeTextRequest.alloc().initWithCompletionHandler_(completed)
        vision_request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
        vision_request.setUsesLanguageCorrection_(True)
        if request.preferred_languages:
            vision_request.setRecognitionLanguages_(request.preferred_languages)
        outcome = request_handler.performRequests_error_([vision_request], None)
        if isinstance(outcome, tuple):
            ok, handler_error = outcome
        else:
            ok, handler_error = bool(outcome), None
        if not ok or handler_error is not None:
            raise LocalOCRError(
                "Apple Vision could not recognize the image",
                code="LOCAL_TEXT_OCR_FAILED",
                retryable=True,
            )
        return LocalOCRResponseV1(
            engine="APPLE_VISION",
            engine_version=metadata.version("pyobjc-framework-Vision"),
            regions=recognized,
            warnings=[] if recognized else ["No readable text was detected."],
        )


class PaddleFormulaOCREngine:
    _lock = threading.Lock()

    def __init__(self, manager: LocalModelManager) -> None:
        self._manager = manager
        self._model = None

    def recognize(self, request: LocalOCRRequestV1) -> LocalOCRResponseV1:
        data = decode_image(request.image_content)
        status = self._manager.status(PP_FORMULANET_PLUS_S)
        if status.state != "INSTALLED" or status.directory is None:
            raise LocalOCRError(
                "Local Math OCR is not installed",
                code="LOCAL_MATH_OCR_MODEL_MISSING",
                retryable=False,
            )
        with self._lock:
            model = self._loaded_model(status.directory)
            image = Image.open(io.BytesIO(data)).convert("RGB")
            try:
                import numpy as np  # type: ignore[import-not-found]

                outputs = list(model.predict(input=np.asarray(image), batch_size=1))
            except Exception as error:
                raise LocalOCRError(
                    "the local formula model could not process this selection",
                    code="LOCAL_MATH_OCR_FAILED",
                    retryable=True,
                ) from error
        latex = ""
        if outputs:
            payload = getattr(outputs[0], "json", None)
            if callable(payload):
                payload = payload()
            if isinstance(payload, dict):
                result = payload.get("res", payload)
                if isinstance(result, dict):
                    latex = str(result.get("rec_formula", "")).strip()
        if not latex:
            raise LocalOCRError(
                "the local formula model returned no expression",
                code="LOCAL_MATH_OCR_EMPTY",
                retryable=False,
            )
        normalized = re.sub(r"\s+", " ", latex).strip()
        return LocalOCRResponseV1(
            engine="PP_FORMULANET_PLUS_S",
            engine_version=metadata.version("paddleocr"),
            model_version=PP_FORMULANET_PLUS_S.revision,
            regions=[
                LocalOCRRegionV1(
                    id=uuid4(),
                    kind="FORMULA",
                    text=normalized,
                    latex=latex,
                    normalized_expression=normalized,
                    confidence=None,
                    rectangles=[SourceRectangleV1(x=0, y=0, width=1, height=1)],
                )
            ],
            warnings=["Formula confidence is unavailable; review the LaTeX before using it."],
        )

    def _loaded_model(self, directory: Path) -> Any:
        if self._model is not None:
            return self._model
        try:
            from paddleocr import FormulaRecognition  # type: ignore[import-not-found]
        except ImportError as error:
            raise LocalOCRError(
                "install the optional PaddleOCR runtime before enabling Local Math OCR",
                code="LOCAL_MATH_OCR_RUNTIME_MISSING",
                retryable=False,
            ) from error
        # A verified local directory is mandatory. PaddleOCR never receives a model name that
        # could trigger its own network download.
        self._model = FormulaRecognition(model_dir=str(directory), device="cpu")
        return self._model


class CompositeLocalOCREngine:
    def __init__(self, text: OCREngine, formula: OCREngine) -> None:
        self._text = text
        self._formula = formula

    def recognize(self, request: LocalOCRRequestV1) -> LocalOCRResponseV1:
        if request.mode == "TEXT":
            return self._text.recognize(request)
        if request.mode == "FORMULA":
            return self._formula.recognize(request)
        text_result = self._text.recognize(request)
        warnings = list(text_result.warnings)
        regions = list(text_result.regions)
        try:
            formula_result = self._formula.recognize(request)
            regions.extend(formula_result.regions)
            warnings.extend(formula_result.warnings)
        except LocalOCRError as error:
            warnings.append(f"Formula recognition unavailable ({error.code}).")
        return LocalOCRResponseV1(
            engine="APPLE_VISION",
            engine_version=text_result.engine_version,
            model_version=PP_FORMULANET_PLUS_S.revision,
            regions=regions,
            warnings=warnings,
        )


class DeterministicLocalOCREngine:
    def recognize(self, request: LocalOCRRequestV1) -> LocalOCRResponseV1:
        decode_image(request.image_content)
        formula = request.mode in {"FORMULA", "MIXED"}
        return LocalOCRResponseV1(
            engine="DETERMINISTIC",
            engine_version="local-ocr-fixture/v1",
            regions=[
                LocalOCRRegionV1(
                    id=uuid4(),
                    kind="FORMULA" if formula else "TEXT",
                    text="x^2 - 4 = 0" if formula else "Recognized local text",
                    latex="x^2 - 4 = 0" if formula else None,
                    normalized_expression="x^2 - 4 = 0" if formula else None,
                    confidence=None if formula else 0.99,
                    rectangles=[SourceRectangleV1(x=0.1, y=0.1, width=0.8, height=0.3)],
                )
            ],
            warnings=["Synthetic OCR result."] if formula else [],
        )
