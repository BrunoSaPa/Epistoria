"""Bounded in-memory preprocessing for the pinned FormulaNet image contract.

Reference: PaddleX c50f5da858020db473a2285f089bb8c7bbd6afdc,
inference/models/formula_recognition/processors.py (Apache-2.0, PaddlePaddle Authors).
This implementation adds input bounds and rejects blank/extreme crops before inference.
"""
from io import BytesIO
import warnings

import cv2
import numpy as np
from PIL import Image, ImageOps

MAX_BYTES = 16 * 1024 * 1024
MAX_PIXELS = 16_000_000
MAX_SIDE = 8192


def prepare_image(encoded):
    if not isinstance(encoded, bytes) or not 0 < len(encoded) <= MAX_BYTES:
        raise ValueError("Invalid image byte count")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        try:
            with Image.open(BytesIO(encoded)) as opened:
                width, height = opened.size
                if opened.format not in ("PNG", "JPEG") or getattr(opened, "n_frames", 1) != 1:
                    raise ValueError("Only single-frame PNG and JPEG images are supported")
                if min(width, height) < 1 or max(width, height) > MAX_SIDE or width * height > MAX_PIXELS:
                    raise ValueError("Image dimensions exceed limits")
                # Refuse ambiguous orientation/transparency instead of silently choosing a
                # compositing or rotation policy that has not been validated against the model.
                if opened.getexif().get(274, 1) != 1:
                    raise ValueError("Image orientation must be normalized before recognition")
                if "A" in opened.getbands() or "transparency" in opened.info:
                    raise ValueError("Image must be composited onto opaque paper before recognition")
                image = opened.convert("RGB")
        except (OSError, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
            raise ValueError("Image could not be decoded safely") from error
    gray = np.asarray(image.convert("L"), dtype=np.uint8)
    low, high = int(gray.min()), int(gray.max())
    if low == high:
        raise ValueError("Image has no recognizable contrast")
    mask = (gray - low) / (high - low) * 255 < 200
    rows, columns = np.nonzero(mask)
    left, top, right, bottom = int(columns.min()), int(rows.min()), int(columns.max()) + 1, int(rows.max()) + 1
    width, height = right - left, bottom - top
    if max(width, height) / min(width, height) > 200:
        raise ValueError("Recognition crop has an extreme aspect ratio")
    image = image.crop((left, top, right, bottom))
    # Match the reference two-stage resize; a direct final-size resize has different pixels.
    short, long = min(width, height), max(width, height)
    new_long = int(384 * long / short)
    size = (384, new_long) if width <= height else (new_long, 384)
    if size[0] * size[1] > MAX_PIXELS:
        raise ValueError("Intermediate resize exceeds memory bounds")
    image = image.resize(size, Image.Resampling.BILINEAR)
    image.thumbnail((384, 384), Image.Resampling.BICUBIC)
    dx, dy = 384 - image.width, 384 - image.height
    image = ImageOps.expand(image, (dx // 2, dy // 2, dx - dx // 2, dy - dy // 2), fill=0)
    # Match the deployed PaddleX predictor, including its BGR grayscale conversion of the
    # RGB reader output. Changing this apparent channel mismatch changes model inputs.
    normalized = (np.asarray(image).astype(np.float32) * (1 / 255.0) - np.float32(0.7931)) / np.float32(0.1738)
    tensor = cv2.cvtColor(normalized, cv2.COLOR_BGR2GRAY)
    return np.ascontiguousarray(tensor[None, None]), {
        "cropPixels": [left, top, right, bottom], "preparedSize": [384, 384],
        "version": "paddlex-formula-bounded/v2",
    }
