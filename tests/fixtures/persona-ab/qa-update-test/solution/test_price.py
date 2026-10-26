import unittest

from src.price import total


class TotalTest(unittest.TestCase):
    def test_default_tax(self):
        self.assertEqual(total([10, 20]), 33.0)

    def test_explicit_tax(self):
        self.assertEqual(total([10], tax=0.2), 12.0)


if __name__ == "__main__":
    unittest.main()
