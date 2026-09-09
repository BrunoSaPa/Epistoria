import unittest

try:
    import cv2
    import onnx
except ImportError:
    raise unittest.SkipTest("Corpus tooling requires the isolated conversion environment")
import numpy as np
from formula_image_probe import fixture_images, expanded_fixture_images, FONT_PATH, ITALIC_FONT_PATH


@unittest.skipUnless(FONT_PATH.is_file() and ITALIC_FONT_PATH.is_file(), "Corpus uses recorded macOS system fonts")
class FormulaConditionTests(unittest.TestCase):
    def test_conditions_do_not_change_expected_answers(self):
        expected = {name: answers for name, _, answers in fixture_images()}
        cases = expanded_fixture_images()
        self.assertEqual(len(cases), 25)
        self.assertEqual(len({name for name, _, _ in cases}), 25)
        for name, image, answers in cases:
            self.assertEqual(answers, expected[name.split('/')[1]])
            self.assertEqual(image.mode, "RGB")

    def test_color_variants_preserve_white_paper_and_geometry(self):
        cases = {name: np.asarray(image) for name, image, _ in expanded_fixture_images()}
        regular = cases["regular/linear"]
        paper = np.all(regular == 255, axis=2)
        for condition in ["red", "blue", "low-contrast"]:
            variant = cases[f"{condition}/linear"]
            self.assertEqual(variant.shape, regular.shape)
            self.assertTrue(np.all(variant[paper] == 255))
            self.assertFalse(np.array_equal(variant, regular))
