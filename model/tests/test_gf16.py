import unittest

from model import gf16 as gf


class TestGF16(unittest.TestCase):
    def test_alpha_generates_all_nonzero_elements(self):
        self.assertEqual(sorted(gf.EXP[:15]), list(range(1, 16)))
        self.assertEqual(gf.alpha_pow(15), 1)

    def test_bitwise_mul_matches_log_tables(self):
        for a in range(16):
            for b in range(16):
                self.assertEqual(gf.mul(a, b), gf.mul_log(a, b), (a, b))

    def test_field_axioms(self):
        for a in range(16):
            self.assertEqual(gf.mul(a, 1), a)
            self.assertEqual(gf.mul(a, 0), 0)
            for b in range(16):
                self.assertEqual(gf.mul(a, b), gf.mul(b, a))
                for c in range(16):
                    self.assertEqual(gf.mul(a, b ^ c), gf.mul(a, b) ^ gf.mul(a, c))
                    self.assertEqual(gf.mul(gf.mul(a, b), c), gf.mul(a, gf.mul(b, c)))

    def test_inverse(self):
        self.assertEqual(gf.inv(0), 0)
        for a in range(1, 16):
            self.assertEqual(gf.mul(a, gf.inv(a)), 1, a)

    def test_known_products(self):
        # alpha^3 * alpha = alpha^4 = alpha + 1
        self.assertEqual(gf.mul(0b1000, 0b0010), 0b0011)
        # alpha^14 * alpha = 1
        self.assertEqual(gf.mul(gf.alpha_pow(14), 0b0010), 1)


if __name__ == "__main__":
    unittest.main()
