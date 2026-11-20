import unittest

from model.ctl import Model
from model import fe_fsm_model as fsm


def tiny():
    # 0 -> 1 -> 2 -> 2 (self loop), 0 -> 3 -> 3 (self loop)
    # p holds in 1, 2; q holds in 2; r holds in 3
    succ = {0: [1, 3], 1: [2], 2: [2], 3: [3]}
    props = {"p": lambda s: s in (1, 2), "q": lambda s: s == 2, "r": lambda s: s == 3}
    return Model([0], lambda s: succ[s], props)


ap = lambda n: ("ap", n)


class TestCTL(unittest.TestCase):
    def test_operators_on_known_structure(self):
        m = tiny()
        idx = lambda states: {m.index[s] for s in states}
        self.assertEqual(m.sat(("EX", ap("p"))), idx([0, 1, 2]))
        self.assertEqual(m.sat(("AX", ap("p"))), idx([1, 2]))
        self.assertEqual(m.sat(("EF", ap("q"))), idx([0, 1, 2]))
        self.assertEqual(m.sat(("AF", ap("q"))), idx([1, 2]))          # 0 can go to 3 forever
        self.assertEqual(m.sat(("EG", ap("p"))), idx([1, 2]))
        self.assertEqual(m.sat(("AG", ("!", ap("q")))), idx([3]))
        self.assertEqual(m.sat(("EU", ap("p"), ap("q"))), idx([1, 2]))
        self.assertEqual(m.sat(("AU", ("true",), ap("r"))), idx([3]))
        self.assertTrue(m.holds(("EF", ap("r"))))
        self.assertFalse(m.holds(("AF", ap("r"))))

    def test_counterexample_is_a_real_path(self):
        m = tiny()
        f = ("AG", ("!", ap("q")))
        path = m.counterexample(f)
        self.assertEqual(path, [0, 1, 2])

    def test_sequencer_properties_hold_and_mutants_fail(self):
        model = Model(fsm.initial_states(), fsm.successors, fsm.PROPS)
        for name, f in fsm.PROPERTIES:
            self.assertTrue(model.holds(f), name)
        for mutant, prop in (("no_lock_check", 1), ("no_kcv_check", 3), ("ignore_ecc", 0)):
            m = Model(fsm.initial_states(), lambda s, mu=mutant: fsm.successors(s, mu), fsm.PROPS)
            self.assertFalse(m.holds(fsm.PROPERTIES[prop][1]), mutant)


if __name__ == "__main__":
    unittest.main()
