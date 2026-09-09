from io import BytesIO
import unittest
from unittest.mock import patch

try:
    import cv2
except ImportError:
    raise unittest.SkipTest("Image preprocessing requires isolated OpenCV dependency")
import numpy as np
from PIL import Image, ImageDraw
from formula_preprocess import prepare_image


def encode(image, **kwargs):
    buffer = BytesIO()
    image.save(buffer, format="PNG", **kwargs)
    return buffer.getvalue()


class FormulaPreprocessTests(unittest.TestCase):
    def test_deployed_float_grayscale_channel_order(self):
        image = Image.new("RGB", (100, 60), "white")
        ImageDraw.Draw(image).rectangle((20, 20, 79, 39), fill=(255, 0, 0))
        pixels, info = prepare_image(encode(image))
        expected = (0.114 - 0.7931) / 0.1738
        self.assertAlmostEqual(float(pixels[0, 0, 192, 192]), expected, places=5)
        self.assertEqual(info["version"], "paddlex-formula-bounded/v2")

    def test_crop_normalization_shape_and_black_padding(self):
        image = Image.new("RGB", (100, 60), "white")
        ImageDraw.Draw(image).rectangle((20, 20, 79, 39), fill="black")
        pixels, info = prepare_image(encode(image))
        self.assertEqual(info["cropPixels"], [20, 20, 80, 40])
        self.assertEqual(pixels.shape, (1, 1, 384, 384))
        self.assertEqual(pixels.dtype, np.float32)
        self.assertTrue(pixels.flags.c_contiguous)
        self.assertAlmostEqual(float(pixels[0, 0, 0, 0]), -0.7931 / 0.1738, places=5)
        self.assertEqual(image.size, (100, 60))

    def test_rejects_blank_corrupt_and_oversized_input(self):
        for encoded in [b"", b"invalid", encode(Image.new("RGB", (10, 10), "white"))]:
            with self.assertRaises(ValueError):
                prepare_image(encoded)
        with patch("formula_preprocess.MAX_BYTES", 1), self.assertRaises(ValueError):
            prepare_image(b"xx")
        with patch("formula_preprocess.MAX_PIXELS", 20), self.assertRaises(ValueError):
            prepare_image(encode(Image.new("RGB", (10, 10), "white")))

    def test_rejects_unvalidated_orientation_and_transparency(self):
        with self.assertRaisesRegex(ValueError, "opaque"):
            prepare_image(encode(Image.new("RGBA", (10, 10), (0, 0, 0, 0))))
        image = Image.new("RGB", (10, 10), "white")
        exif = Image.Exif()
        exif[274] = 6
        with self.assertRaisesRegex(ValueError, "orientation"):
            prepare_image(encode(image, exif=exif))

    def test_rejects_intermediate_resize_memory_growth(self):
        image = Image.new("RGB", (1000, 30), "white")
        ImageDraw.Draw(image).rectangle((10, 10, 909, 14), fill="black")
        with self.assertRaisesRegex(ValueError, "Intermediate"):
            prepare_image(encode(image))
