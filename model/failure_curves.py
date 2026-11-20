"""Key-failure rate vs. PUF bit-error rate, used to choose the repetition factor r.

Run from the project root:   python -m model.failure_curves [--trials N]
Writes docs/figures/key_failure_vs_ber.png and prints a parameter table.
"""

import argparse
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from . import analysis
from .fuzzy_extractor import FEParams

FIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "figures")
TARGET = 1e-6
REPS = (1, 3, 5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=int, default=2000, help="Monte Carlo trials per point")
    args = parser.parse_args()

    print("{:>3} {:>7} {:>9} {:>7} {:>8} {:>13}".format(
        "r", "blocks", "used bits", "leaked", "residual", "max BER @1e-6"))
    for r in REPS:
        p = FEParams(rep=r)
        print("{:>3} {:>7} {:>9} {:>7} {:>8} {:>12.2%}".format(
            r, p.n_blocks, p.used_bits, p.leaked_bits, p.secret_bits,
            analysis.max_ber_for_target(p, TARGET)))

    ber = np.logspace(-3, np.log10(0.3), 80)
    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.plot(ber, [analysis.raw_failure_analytic(b, 128) for b in ber], "k--", label="no ECC (128 bits)")
    rng = np.random.default_rng(1)
    mc_points = (0.02, 0.05, 0.1, 0.15)
    for r, color in zip(REPS, ("C0", "C1", "C2")):
        p = FEParams(rep=r)
        ax.plot(ber, [max(analysis.key_failure_analytic(b, p), 1e-12) for b in ber],
                color=color, label="rep-{} + BCH(15,7,2)".format(r))
        for b in mc_points:
            res = analysis.monte_carlo(p, b, args.trials, rng)
            rate = res["fail"] / res["trials"]
            if rate > 0:
                ax.plot(b, rate, "o", color=color, markersize=4)
            if res["wrong"]:
                print("WARNING: r={} p={}: {} wrong keys accepted".format(r, b, res["wrong"]))
    ax.axhline(TARGET, color="grey", lw=0.8, ls=":")
    ax.text(1.1e-3, TARGET * 2, "target 1e-6", color="grey", fontsize=8)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_ylim(1e-10, 1.5)
    ax.set_xlabel("PUF bit-error rate p")
    ax.set_ylabel("key-failure probability")
    ax.set_title("Key failure vs. BER (lines: analytic, dots: Monte Carlo)")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="lower right", fontsize=8)
    fig.tight_layout()
    os.makedirs(FIG_DIR, exist_ok=True)
    out = os.path.join(FIG_DIR, "key_failure_vs_ber.png")
    fig.savefig(out, dpi=150)
    print("saved", out)


if __name__ == "__main__":
    main()
