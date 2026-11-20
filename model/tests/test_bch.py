import random
import unittest
from itertools import combinations

from model import bch


def error_patterns(max_weight):
    for w in range(max_weight + 1):
        for positions in combinations(range(bch.N), w):
            mask = 0
            for p in positions:
                mask |= 1 << p
            yield mask


class TestBCH(unittest.TestCase):
    def test_codewords_are_valid(self):
        self.assertEqual(len(set(bch.ALL_CODEWORDS)), 128)
        for m, cw in enumerate(bch.ALL_CODEWORDS):
            self.assertEqual(bch.message_of(cw), m)
            self.assertEqual(bch._poly_mod(cw, bch.GEN_POLY), 0)
            for j in (1, 2, 3, 4):
                self.assertEqual(bch.syndrome(cw, j), 0)

    def test_minimum_distance_is_5(self):
        weights = [bin(cw).count("1") for cw in bch.ALL_CODEWORDS if cw]
        self.assertEqual(min(weights), 5)

    def test_corrects_every_pattern_up_to_two_errors(self):
        # 128 codewords x 121 patterns, exhaustive
        for cw in bch.ALL_CODEWORDS:
            for e in error_patterns(2):
                res = bch.decode(cw ^ e)
                self.assertTrue(res.ok, (cw, e))
                self.assertEqual(res.error_mask, e)
                self.assertEqual(res.corrected, cw)
                self.assertEqual(res.degree, bin(e).count("1"))

    def test_three_errors_never_pass_as_original(self):
        # with 3 errors the decoder must either flag failure or land on a
        # different codeword (miscorrection); it can never "fix" it correctly
        rng = random.Random(1)
        outcomes = {"fail": 0, "miscorrect": 0}
        for _ in range(3000):
            cw = rng.choice(bch.ALL_CODEWORDS)
            e = 0
            for p in rng.sample(range(bch.N), 3):
                e |= 1 << p
            res = bch.decode(cw ^ e)
            if res.ok:
                self.assertIn(res.corrected, bch.ALL_CODEWORDS)
                self.assertNotEqual(res.corrected, cw)
                outcomes["miscorrect"] += 1
            else:
                self.assertEqual(res.corrected, cw ^ e)
                outcomes["fail"] += 1
        self.assertGreater(outcomes["fail"], 0)
        self.assertGreater(outcomes["miscorrect"], 0)

    def test_peterson_special_cases(self):
        self.assertEqual(bch.peterson(0, 0), (0, 0, 0))
        self.assertEqual(bch.peterson(0, 5)[2], -1)
        # single error at position 4: S1 = alpha^4, S3 = alpha^12 = S1^3 -> L2 = 0
        res = bch.decode(bch.encode(0) ^ (1 << 4))
        self.assertEqual(res.l2, 0)
        self.assertEqual(res.degree, 1)


if __name__ == "__main__":
    unittest.main()
