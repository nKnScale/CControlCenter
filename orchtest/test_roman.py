"""Acceptance and boundary tests for Roman numerals."""

import unittest

from orchtest.roman import to_roman


class RomanTests(unittest.TestCase):
    def test_requested_examples(self):
        expected = {1: "I", 4: "IV", 1994: "MCMXCIV", 3999: "MMMCMXCIX"}
        for n, result in expected.items():
            with self.subTest(n=n):
                self.assertEqual(to_roman(n), result)

    def test_subtractive_forms(self):
        expected = {
            9: "IX", 40: "XL", 90: "XC", 400: "CD", 900: "CM",
            14: "XIV", 49: "XLIX", 444: "CDXLIV", 2024: "MMXXIV",
        }
        for n, result in expected.items():
            with self.subTest(n=n):
                self.assertEqual(to_roman(n), result)

    def test_out_of_range_is_refused_with_reason(self):
        for n in (0, -1, -3999, 4000, 10**30):
            with self.subTest(n=n):
                with self.assertRaisesRegex(ValueError, "between 1 and 3999"):
                    to_roman(n)

    def test_non_integers_are_refused_with_reason(self):
        for n in (1.0, 1.5, "1", None, True, False, [], {}, 1j):
            with self.subTest(n=n):
                with self.assertRaisesRegex(ValueError, "must be an integer"):
                    to_roman(n)


if __name__ == "__main__":
    unittest.main()
