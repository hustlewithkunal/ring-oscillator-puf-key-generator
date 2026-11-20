import unittest

import numpy as np

from model import bch, repetition
from model.fuzzy_extractor import FEParams, enrol, reconstruct, mac
from model.noise import flip_positions


class TestRepetition(unittest.TestCase):
    def test_roundtrip_and_majority(self):
        bits = np.array([1, 0, 1, 1], dtype=np.uint8)
        enc = repetition.encode(bits, 3)
        self.assertEqual(list(enc), [1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        enc[0] ^= 1   # one error per group is corrected
        enc[4] ^= 1
        self.assertTrue(np.array_equal(repetition.decode(enc, 3), bits))

    def test_even_factor_rejected(self):
        with self.assertRaises(ValueError):
            repetition.encode([1], 2)


class TestFuzzyExtractor(unittest.TestCase):
    def setUp(self):
        self.rng = np.random.default_rng(42)
        self.w = self.rng.integers(0, 2, 128, dtype=np.uint8)

    def test_parameters(self):
        self.assertEqual((FEParams(rep=1).n_blocks, FEParams(rep=1).used_bits), (8, 120))
        self.assertEqual((FEParams(rep=3).n_blocks, FEParams(rep=3).used_bits), (2, 90))
        self.assertEqual((FEParams(rep=5).n_blocks, FEParams(rep=5).used_bits), (1, 75))

    def test_noiseless_reconstruction(self):
        for r in (1, 3, 5):
            p = FEParams(rep=r)
            e = enrol(self.w, p, rng=self.rng)
            res = reconstruct(self.w, e.helper, p)
            self.assertTrue(res.key_valid)
            self.assertEqual(res.key, e.key)

    def test_two_errors_in_every_block_corrected_r1(self):
        p = FEParams(rep=1)
        e = enrol(self.w, p, rng=self.rng)
        positions = [b * 15 + k for b in range(p.n_blocks) for k in (3, 11)]
        res = reconstruct(flip_positions(self.w, positions), e.helper, p)
        self.assertTrue(res.key_valid)
        self.assertEqual(res.key, e.key)

    def test_repetition_absorbs_errors_r3(self):
        # one flip in every repetition group, plus two groups fully wrong per block
        p = FEParams(rep=3)
        e = enrol(self.w, p, rng=self.rng)
        positions = [g * 3 for g in range(p.n_blocks * 15)]
        for b in range(p.n_blocks):
            for g in (b * 15 + 2, b * 15 + 9):
                positions += [g * 3 + 1, g * 3 + 2]
        res = reconstruct(flip_positions(self.w, positions), e.helper, p)
        self.assertTrue(res.key_valid)
        self.assertEqual(res.key, e.key)

    def test_unused_bits_do_not_matter(self):
        p = FEParams(rep=1)
        e = enrol(self.w, p, rng=self.rng)
        res = reconstruct(flip_positions(self.w, range(120, 128)), e.helper, p)
        self.assertEqual(res.key, e.key)

    def test_other_board_fails(self):
        p = FEParams(rep=1)
        e = enrol(self.w, p, rng=self.rng)
        for _ in range(50):
            other = self.rng.integers(0, 2, 128, dtype=np.uint8)
            res = reconstruct(other, e.helper, p)
            self.assertFalse(res.key_valid)
            self.assertEqual(res.key, 0)

    def test_three_errors_in_a_block_never_give_wrong_valid_key(self):
        p = FEParams(rep=1)
        e = enrol(self.w, p, rng=self.rng)
        for _ in range(200):
            pos = self.rng.choice(15, size=3, replace=False)
            res = reconstruct(flip_positions(self.w, pos), e.helper, p)
            self.assertFalse(res.key_valid and res.key != e.key)

    def test_helper_is_offset_of_codeword(self):
        p = FEParams(rep=3)
        e = enrol(self.w, p, rng=self.rng)
        self.assertTrue(np.array_equal(e.helper.offset ^ e.codeword, self.w[:p.used_bits]))
        cw0 = bch.encode(e.messages[0])
        self.assertEqual(int(e.codeword[0]), cw0 & 1)

    def test_mac_depends_on_key_and_challenge(self):
        p = FEParams()
        k1 = enrol(self.w, p, rng=self.rng).key
        k2 = enrol(1 - self.w, p, rng=self.rng).key
        self.assertNotEqual(mac(k1, 7), mac(k2, 7))
        self.assertNotEqual(mac(k1, 7), mac(k1, 8))


if __name__ == "__main__":
    unittest.main()
