import random
import unittest

import numpy as np

from model import gf16 as gf
from model.bdd import BDD, FALSE, TRUE, all_assignments, node_count_for_order

MUL_IN = ["a3", "a2", "a1", "a0", "b3", "b2", "b1", "b0"]


def mul_func(v):
    return gf.MUL_TABLE[v >> 4][v & 0xF]


MUL_TABLE = np.array([[(mul_func(v) >> (3 - k)) & 1 for k in range(4)] for v in range(256)], dtype=np.uint8)


class TestBDD(unittest.TestCase):
    def test_basic_operations(self):
        m = BDD(["x", "y"])
        x, y = m.var("x"), m.var("y")
        self.assertEqual(m.AND(x, m.NOT(x)), FALSE)
        self.assertEqual(m.OR(x, m.NOT(x)), TRUE)
        f = m.XOR(x, y)
        for asg in all_assignments(["x", "y"]):
            self.assertEqual(m.evaluate(f, asg), asg["x"] ^ asg["y"])
        # canonical: the same function built two ways is the same node
        g = m.OR(m.AND(x, m.NOT(y)), m.AND(m.NOT(x), y))
        self.assertEqual(f, g)

    def test_truth_table_build_evaluates_correctly(self):
        m = BDD(MUL_IN)
        roots = m.from_truth_table(MUL_IN, 4, mul_func)
        for v in range(256):
            asg = {n: (v >> (7 - i)) & 1 for i, n in enumerate(MUL_IN)}
            out = sum(m.evaluate(r, asg) << (3 - k) for k, r in enumerate(roots))
            self.assertEqual(out, mul_func(v))

    def test_fast_node_count_matches_real_bdd(self):
        rng = random.Random(5)
        orders = [MUL_IN, list(reversed(MUL_IN))] + [rng.sample(MUL_IN, 8) for _ in range(20)]
        for order in orders:
            m = BDD(order)
            roots = m.from_truth_table(MUL_IN, 4, mul_func)
            self.assertEqual(node_count_for_order(MUL_TABLE, MUL_IN, order), m.count_nodes(roots), order)

    def test_equivalence_detects_a_single_wrong_minterm(self):
        m = BDD(MUL_IN)
        ref = m.from_truth_table(MUL_IN, 4, mul_func)
        broken = m.from_truth_table(MUL_IN, 4, lambda v: mul_func(v) ^ (8 if v == 0x37 else 0))
        self.assertNotEqual(ref[0], broken[0])
        self.assertEqual(ref[1:], broken[1:])


if __name__ == "__main__":
    unittest.main()
