import unittest

from src.strutil import is_palindrome


class IsPalindromeTest(unittest.TestCase):
    def test_simple(self):
        self.assertTrue(is_palindrome("level"))
        self.assertFalse(is_palindrome("levels"))

    def test_ignores_case_and_spaces(self):
        self.assertTrue(is_palindrome("Race car"))


if __name__ == "__main__":
    unittest.main()
