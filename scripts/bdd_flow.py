"""BDD analysis of the GF(2^4) multiplier and inverse.

  1. Equivalence: builds ROBDDs of (a) the golden-model truth table, (b) the
     ESPRESSO-minimised cover (*.min.pla) and (c) the XOR-based Mastrovito equations.
     With one shared variable order, equal functions must be the same BDD node.
  2. Variable ordering: shared BDD size for every possible order
     (8! = 40320 for the multiplier, 4! = 24 for the inverse).
  3. Outputs: docs/figures/bdd_ordering.png, docs/figures/bdd_gf_inv.dot,
     docs/reports/phase3_bdd.txt

Run from the project root (after scripts/espresso_flow.py):   python scripts/bdd_flow.py
"""

import os
import sys
from itertools import permutations

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from model import gf16 as gf  # noqa: E402
from model.bdd import BDD, FALSE, TRUE, node_count_for_order  # noqa: E402
from espresso_flow import parse_pla  # noqa: E402

PLA_DIR = os.path.join(ROOT, "model", "vectors", "espresso")
FIG_DIR = os.path.join(ROOT, "docs", "figures")
REPORT = os.path.join(ROOT, "docs", "reports", "phase3_bdd.txt")

MUL_IN = ["a3", "a2", "a1", "a0", "b3", "b2", "b1", "b0"]
INV_IN = ["a3", "a2", "a1", "a0"]

NAMED_MUL_ORDERS = {
    "separated MSB-first (a3..a0 b3..b0)": MUL_IN,
    "separated LSB-first (a0..a3 b0..b3)": ["a0", "a1", "a2", "a3", "b0", "b1", "b2", "b3"],
    "interleaved MSB-first (a3 b3 a2 b2 ..)": ["a3", "b3", "a2", "b2", "a1", "b1", "a0", "b0"],
    "interleaved LSB-first (a0 b0 a1 b1 ..)": ["a0", "b0", "a1", "b1", "a2", "b2", "a3", "b3"],
}


def mul_func(v):
    return gf.MUL_TABLE[v >> 4][v & 0xF]


def inv_func(v):
    return gf.INV_TABLE[v]


def table_of(func, n_in, n_out):
    return np.array([[(func(v) >> (n_out - 1 - k)) & 1 for k in range(n_out)]
                     for v in range(1 << n_in)], dtype=np.uint8)


def bdd_from_cover(m, ilb, cubes, n_out):
    roots = [FALSE] * n_out
    for inp, out in cubes:
        term = m.cube({name: int(ch) for name, ch in zip(ilb, inp) if ch != "-"})
        for k, ch in enumerate(out):
            if ch == "1":
                roots[k] = m.OR(roots[k], term)
    return roots


def bdd_mastrovito(m):
    a = {i: m.var("a%d" % i) for i in range(4)}
    b = {i: m.var("b%d" % i) for i in range(4)}
    c = [FALSE] * 7
    for i in range(4):
        for j in range(4):
            c[i + j] = m.XOR(c[i + j], m.AND(a[i], b[j]))
    p = [m.XOR(c[0], c[4]),
         m.XOR(m.XOR(c[1], c[4]), c[5]),
         m.XOR(m.XOR(c[2], c[5]), c[6]),
         m.XOR(c[3], c[6])]
    return [p[3], p[2], p[1], p[0]]          # same output order as the PLA: p3..p0


def load_cover(name):
    with open(os.path.join(PLA_DIR, name + ".min.pla")) as f:
        return parse_pla(f.read())


def main():
    out = []

    def log(line=""):
        print(line)
        out.append(line)

    # ---------------------------------------------------------- equivalence
    log("== 1. Equivalence checking (shared ROBDD, order a3..a0 b3..b0) ==")
    m = BDD(MUL_IN)
    ref = m.from_truth_table(MUL_IN, 4, mul_func)
    ilb, ob, cubes = load_cover("gf_mul")
    esp = bdd_from_cover(m, ilb, cubes, 4)
    mas = bdd_mastrovito(m)
    for k, name in enumerate(ob):
        log("  {}: reference node {:>4}, ESPRESSO node {:>4}, Mastrovito node {:>4} -> {}".format(
            name, ref[k], esp[k], mas[k],
            "EQUIVALENT" if ref[k] == esp[k] == mas[k] else "DIFFERENT"))
    mul_ok = ref == esp == mas
    log("  per-output BDD sizes: {}   shared total: {}".format(
        [m.count_nodes([r]) for r in ref], m.count_nodes(ref)))

    mi = BDD(INV_IN)
    ref_i = mi.from_truth_table(INV_IN, 4, inv_func)
    ilb_i, ob_i, cubes_i = load_cover("gf_inv")
    esp_i = bdd_from_cover(mi, ilb_i, cubes_i, 4)
    for k, name in enumerate(ob_i):
        log("  {}: reference node {:>4}, ESPRESSO node {:>4} -> {}".format(
            name, ref_i[k], esp_i[k], "EQUIVALENT" if ref_i[k] == esp_i[k] else "DIFFERENT"))
    inv_ok = ref_i == esp_i
    log("  multiplier: {}   inverse: {}".format("PROVEN EQUIVALENT" if mul_ok else "MISMATCH",
                                                 "PROVEN EQUIVALENT" if inv_ok else "MISMATCH"))

    # ----------------------------------------------------- variable ordering
    log()
    log("== 2. Variable ordering (shared nodes over all 4 outputs) ==")
    mul_table = table_of(mul_func, 8, 4)
    mul_sizes = {order: node_count_for_order(mul_table, MUL_IN, list(order)) for order in permutations(MUL_IN)}
    values = np.array(list(mul_sizes.values()))
    best = min(mul_sizes, key=mul_sizes.get)
    worst = max(mul_sizes, key=mul_sizes.get)
    log("  multiplier, all {} orders: min {}  median {:.0f}  max {}".format(
        len(values), values.min(), np.median(values), values.max()))
    log("    best order : {} ({} nodes, {} orders reach it)".format(
        " ".join(best), mul_sizes[best], int(np.sum(values == values.min()))))
    log("    worst order: {} ({} nodes)".format(" ".join(worst), mul_sizes[worst]))
    for label, order in NAMED_MUL_ORDERS.items():
        log("    {:<40} {} nodes".format(label, mul_sizes[tuple(order)]))

    inv_table = table_of(inv_func, 4, 4)
    inv_sizes = {order: node_count_for_order(inv_table, INV_IN, list(order)) for order in permutations(INV_IN)}
    best_i = min(inv_sizes, key=inv_sizes.get)
    log("  inverse, all {} orders: min {}  max {}   best {}".format(
        len(inv_sizes), min(inv_sizes.values()), max(inv_sizes.values()), " ".join(best_i)))

    # ---------------------------------------------------------------- outputs
    os.makedirs(FIG_DIR, exist_ok=True)
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.2), gridspec_kw={"width_ratios": [3, 2]})
    ax = axes[0]
    bins = np.arange(values.min() - 0.5, values.max() + 1.5, 1)
    ax.hist(values, bins=bins, color="C0")
    for (label, order), color in zip(NAMED_MUL_ORDERS.items(), ("C1", "C2", "C3", "C4")):
        ax.axvline(mul_sizes[tuple(order)], color=color, ls="--", lw=1.2,
                   label="{}: {} nodes".format(label, mul_sizes[tuple(order)]))
    ax.set_xlabel("shared BDD nodes (4 outputs)")
    ax.set_ylabel("number of variable orders")
    ax.set_title("GF(2^4) multiplier: BDD size over all 40320 variable orders")
    ax.legend(fontsize=7)
    ax = axes[1]
    labels = [" ".join(o) for o in sorted(inv_sizes, key=inv_sizes.get)]
    ax.barh(range(len(labels)), sorted(inv_sizes.values()), color="C0")
    ax.set_yticks(range(len(labels)))
    ax.set_yticklabels(labels, fontsize=6)
    ax.invert_yaxis()
    ax.set_xlabel("shared BDD nodes")
    ax.set_title("GF(2^4) inverse: all 24 orders")
    fig.tight_layout()
    fig_path = os.path.join(FIG_DIR, "bdd_ordering.png")
    fig.savefig(fig_path, dpi=150)

    mb = BDD(list(best_i))
    roots = mb.from_truth_table(INV_IN, 4, inv_func)
    dot_path = os.path.join(FIG_DIR, "bdd_gf_inv.dot")
    with open(dot_path, "w", newline="\n") as f:
        f.write(mb.to_dot({"y%d" % (3 - k): r for k, r in enumerate(roots)}))

    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("\nsaved", os.path.relpath(fig_path, ROOT), ",", os.path.relpath(dot_path, ROOT), ",",
          os.path.relpath(REPORT, ROOT))
    sys.exit(0 if mul_ok and inv_ok else 1)


if __name__ == "__main__":
    main()
