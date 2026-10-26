import unittest

from src.mathx import double


class DoubleTest(unittest.TestCase):
    def test_double(self):
        self.assertEqual(double(2), 4)


if __name__ == "__main__":
    unittest.main()
