"""Acceptance tests for clamping a number to a closed range."""

import math
import unittest

from orchtest.clamp import clamp


class ClampTests(unittest.TestCase):
    def test_inside_and_on_the_range(self):
        cases = (
            (5, 0, 10, 5),
            (-1, 0, 10, 0),
            (11, 0, 10, 10),
            (3, 3, 3, 3),
        )
        for x, lo, hi, expected in cases:
            with self.subTest(x=x, lo=lo, hi=hi):
                self.assertEqual(clamp(x, lo, hi), expected)

    def test_inverted_range_is_refused(self):
        with self.assertRaises(ValueError):
            clamp(5, 10, 0)

    def test_nan_arguments_are_refused(self):
        nan = float("nan")
        cases = (
            (nan, 0, 10),
            (5, nan, 10),
            (5, 0, nan),
        )
        for x, lo, hi in cases:
            with self.subTest(x=x, lo=lo, hi=hi):
                with self.assertRaises(ValueError):
                    clamp(x, lo, hi)

    def test_math_nan_is_refused(self):
        with self.assertRaises(ValueError):
            clamp(math.nan, 0, 10)


if __name__ == "__main__":
    unittest.main()
