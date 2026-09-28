"""Acceptance tests for percentage formatting."""

import unittest

from orchtest.percent import percent


class PercentTests(unittest.TestCase):
    def test_requested_examples(self):
        self.assertEqual(percent(1, 8), "12.5%")
        self.assertEqual(percent(1, 3), "33.3%")
        self.assertEqual(percent(2, 3, digits=0), "67%")
        self.assertEqual(percent(0, 5), "0.0%")

    def test_zero_whole_is_refused(self):
        for whole in (0, 0.0, -0.0):
            with self.subTest(whole=whole):
                with self.assertRaises(ValueError):
                    percent(1, whole)

    def test_negative_digits_are_refused(self):
        for digits in (-1, -5):
            with self.subTest(digits=digits):
                with self.assertRaises(ValueError):
                    percent(1, 8, digits=digits)

    def test_bools_are_refused(self):
        cases = (
            (True, 8, 1),
            (False, 5, 1),
            (1, True, 1),
            (1, False, 1),
            (1, 8, True),
            (1, 8, False),
        )
        for part, whole, digits in cases:
            with self.subTest(part=part, whole=whole, digits=digits):
                with self.assertRaises(ValueError):
                    percent(part, whole, digits)


if __name__ == "__main__":
    unittest.main()
