"""PUF characterisation: uniqueness, reliability, bit-aliasing, key failure before/after ECC.

Real data (from the RO array) -- one folder per board, one file per condition:
    data/<board>/room.txt    >= 100 responses, one 32-digit hex per line (bit 0 = LSB)
    data/<board>/warm.txt    optional, same format, taken on the heated board
The first line of room.txt is the enrolment reference.

Run from the project root:
    python -m model.characterise --data data          # real measurements
    python -m model.characterise --simulate           # simulated boards (dry run)
Writes plots to docs/figures/ (prefix "sim_" for simulated data).
"""

import argparse
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from . import analysis
from .fuzzy_extractor import FEParams
from .puf_sim import SimulatedBoard

FIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "figures")
CONDITIONS = ("room", "warm")


def load_dataset(folder):
    data = {}
    for board in sorted(os.listdir(folder)):
        path = os.path.join(folder, board)
        if not os.path.isdir(path):
            continue
        conds = {}
        for c in CONDITIONS:
            f = os.path.join(path, c + ".txt")
            if os.path.exists(f):
                conds[c] = analysis.load_responses(f)
        if "room" in conds:
            data[board] = conds
    return data


def simulate_dataset(n_boards, n_reads, warm_delta_c):
    data = {}
    for i in range(n_boards):
        b = SimulatedBoard(seed=100 + i)
        ref_t = b.config.ref_temp_c
        data["sim{}".format(i)] = {
            "room": np.array([b.read(ref_t) for _ in range(n_reads)]),
            "warm": np.array([b.read(ref_t + warm_delta_c) for _ in range(n_reads)]),
        }
    return data


def report(data, prefix):
    boards = list(data)
    refs = np.array([data[b]["room"][0] for b in boards])

    print("\n== Per-board metrics ==")
    print("{:<10} {:<5} {:>5} {:>10} {:>11} {:>10} {:>9} {:>9} {:>9}".format(
        "board", "cond", "reads", "uniformity", "intra-HD avg", "max", "raw fail",
        "ECC r=1", "ECC r=3"))
    intra = {}
    for b, ref in zip(boards, refs):
        for c, reads in data[b].items():
            reads_cmp = reads[1:] if c == "room" else reads   # skip the reference itself
            hd = analysis.intra_hd(ref, reads_cmp)
            intra[(b, c)] = hd
            ecc = [analysis.ecc_failure_rate(ref, reads_cmp, FEParams(rep=r)) for r in (1, 3)]
            print("{:<10} {:<5} {:>5} {:>10.3f} {:>11.2%} {:>10.2%} {:>9.2%} {:>9.2%} {:>9.2%}".format(
                b, c, len(reads_cmp), analysis.uniformity(ref), hd.mean(), hd.max(),
                analysis.raw_failure_rate(ref, reads_cmp), ecc[0], ecc[1]))

    if len(boards) >= 2:
        mean, hds = analysis.uniqueness(refs)
        print("\n== Uniqueness ({} boards, {} pairs) ==".format(len(boards), len(hds)))
        print("inter-chip HD mean {:.2%}  min {:.2%}  max {:.2%}  (ideal 50%)".format(
            mean, min(hds), max(hds)))
        alias = analysis.bit_aliasing(refs)
        stuck = int(np.sum((alias == 0) | (alias == 1)))
        chance = len(alias) * 2.0 ** (1 - len(boards))
        print("bit-aliasing: mean {:.3f}, bits equal on every board: {} (expected by chance: {:.1f})".format(
            alias.mean(), stuck, chance))
    else:
        hds, alias = [], None
        print("\n(need >= 2 boards for uniqueness / bit-aliasing)")

    os.makedirs(FIG_DIR, exist_ok=True)
    fig, axes = plt.subplots(1, 2 if alias is not None else 1, figsize=(11, 4), squeeze=False)
    ax = axes[0][0]
    bins = np.linspace(0, 0.6, 61)
    for (b, c), hd in intra.items():
        ax.hist(hd, bins=bins, alpha=0.5, label="intra {} {}".format(b, c))
    if hds:
        ax.hist(hds, bins=bins, alpha=0.7, color="k", label="inter-chip")
    ax.set_xlabel("fractional Hamming distance")
    ax.set_ylabel("count")
    ax.set_title("Intra- vs inter-chip HD")
    ax.legend(fontsize=7)
    if alias is not None:
        ax = axes[0][1]
        ax.bar(np.arange(len(alias)), alias, width=1.0)
        ax.axhline(0.5, color="r", lw=0.8)
        ax.set_xlabel("response bit")
        ax.set_ylabel("fraction of boards = 1")
        ax.set_title("Bit-aliasing")
    fig.tight_layout()
    out = os.path.join(FIG_DIR, prefix + "characterisation.png")
    fig.savefig(out, dpi=150)
    print("\nsaved", out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--data", help="folder with one sub-folder per board")
    src.add_argument("--simulate", action="store_true", help="use simulated boards")
    parser.add_argument("--boards", type=int, default=3)
    parser.add_argument("--reads", type=int, default=100)
    parser.add_argument("--warm-delta", type=float, default=30.0, help="simulated heating, deg C")
    args = parser.parse_args()

    if args.simulate:
        print("SIMULATED data (assumed parameters, not measurements)")
        report(simulate_dataset(args.boards, args.reads, args.warm_delta), "sim_")
    else:
        data = load_dataset(args.data)
        if not data:
            parser.error("no board folders with room.txt found in " + args.data)
        report(data, "")


if __name__ == "__main__":
    main()
