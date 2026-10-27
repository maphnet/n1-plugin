import unittest

from src.price import total


class TotalTest(unittest.TestCase):
    def test_total(self):
        self.assertEqual(total([10, 20]), 30)


if __name__ == "__main__":
    unittest.main()
