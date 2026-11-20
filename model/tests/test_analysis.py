import unittest

import numpy as np

from model import analysis
from model.fuzzy_extractor import FEParams
from model.puf_sim import SimulatedBoard


class TestAnalysis(unittest.TestCase):
    def test_metrics_on_known_inputs(self):
        a = np.zeros(8, dtype=np.uint8)
        b = np.array([1, 1, 0, 0, 0, 0, 0, 0], dtype=np.uint8)
        self.assertAlmostEqual(analysis.fractional_hd(a, b), 0.25)
        mean, hds = analysis.uniqueness([a, b, 1 - a])
        self.assertEqual(len(hds), 3)
        self.assertAlmostEqual(mean, (0.25 + 1.0 + 0.75) / 3)
        self.assertAlmostEqual(analysis.reliability(a, [a, b]), 1 - 0.125)
        self.assertAlmostEqual(analysis.raw_failure_rate(a, [a, b]), 0.5)

    def test_analytic_formulas(self):
        self.assertAlmostEqual(analysis.rep_bit_error(0.1, 1), 0.1)
        self.assertAlmostEqual(analysis.rep_bit_error(0.1, 3), 3 * 0.01 * 0.9 + 0.001)
        self.assertEqual(analysis.key_failure_analytic(0.0, FEParams()), 0.0)

    def test_monte_carlo_agrees_with_analytic(self):
        params = FEParams(rep=1)
        p = 0.06
        res = analysis.monte_carlo(params, p, 3000, np.random.default_rng(3))
        expected = analysis.key_failure_analytic(p, params)
        measured = res["fail"] / res["trials"]
        self.assertLess(abs(measured - expected), 0.04)
        self.assertEqual(res["wrong"], 0)

    def test_simulated_boards_look_like_a_puf(self):
        boards = [SimulatedBoard(seed) for seed in range(5)]
        refs = [b.read() for b in boards]
        mean, _ = analysis.uniqueness(refs)
        self.assertTrue(0.35 < mean < 0.65, mean)
        reads = [boards[0].read() for _ in range(50)]
        self.assertGreater(analysis.reliability(refs[0], reads), 0.9)


if __name__ == "__main__":
    unittest.main()
