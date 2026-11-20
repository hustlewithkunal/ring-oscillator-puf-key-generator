"""Analysis of the PUF measurements taken on the Zybo Z7-10 (scripts/hw/char_collect.tcl).

Inputs:
  data/hw_counts/arr<a>_cfg0.csv          raw counts of every RO pair (baseline configuration)
  data/hw_base/arr<a>/{room,warm}.txt     100 responses each, baseline RO-PUF
  data/hw_cfg/arr<a>/{room,warm}.txt      100 responses each, configurable RO-PUF
Outputs:
  docs/figures/hw_frequency_map.png, hw_flip_vs_gap.png, hw_hd.png
  docs/reports/hw_characterisation.txt

The three RO arrays sit in different regions of the same die and are treated as three
independent "virtual devices" (only one board is available).

Run from the project root:   python -m model.hw_analysis
"""

import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from . import analysis
from .fuzzy_extractor import FEParams

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIG = os.path.join(ROOT, "docs", "figures")
REPORT = os.path.join(ROOT, "docs", "reports", "hw_characterisation.txt")
ARRAYS = (0, 1, 2)
COLS, PAIRS_PER_COL = 8, 16


def load_counts(a):
    rows = np.loadtxt(os.path.join(ROOT, "data", "hw_counts", "arr{}_cfg0.csv".format(a)),
                      delimiter=",", skiprows=1, dtype=int)
    return rows[:, 1], rows[:, 2]


def load_reads(kind, a, cond):
    path = os.path.join(ROOT, "data", kind, "arr{}".format(a), cond + ".txt")
    if not os.path.exists(path):
        return None, []
    temps = [float(t) for t in re.findall(r"temp\s+([\d.]+)", open(path).read())]
    return analysis.load_responses(path), temps


def frequency_grid(cnt_a, cnt_b):
    """Counts as an image: 8 columns x 32 rows (RO 2p at row 2(p%16), RO 2p+1 above it)."""
    g = np.zeros((2 * PAIRS_PER_COL, COLS))
    for p in range(128):
        c, r = divmod(p, PAIRS_PER_COL)
        g[2 * r, c] = cnt_a[p]
        g[2 * r + 1, c] = cnt_b[p]
    return g


def main():
    os.makedirs(FIG, exist_ok=True)
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    out = []

    def log(s=""):
        print(s)
        out.append(s)

    # ------------------------------------------------------------ frequencies
    window_s = 2 ** 13 / 125e6
    log("== RO frequencies (baseline configuration, window 2^13 cycles = 65.5 us) ==")
    fig, axes = plt.subplots(1, 3, figsize=(10, 5))
    for a, ax in zip(ARRAYS, axes):
        ca, cb = load_counts(a)
        f = 2 * np.concatenate([ca, cb]) / window_s / 1e6        # count = (f_RO / 2) * T
        rel = np.abs(ca - cb) / ((ca + cb) / 2) * 100
        log("array {}: RO frequency mean {:.1f} MHz, std {:.2f} MHz ({:.2f} %), min {:.1f}, max {:.1f}; "
            "pair gap median {:.2f} %, max {:.2f} %".format(
                a, f.mean(), f.std(), 100 * f.std() / f.mean(), f.min(), f.max(), np.median(rel), rel.max()))
        im = ax.imshow(frequency_grid(2 * ca / window_s / 1e6, 2 * cb / window_s / 1e6),
                       origin="lower", aspect="auto", cmap="viridis")
        ax.set_title("array {} (rows {}..{})".format(a, [0, 34, 68][a], [0, 34, 68][a] + 31))
        ax.set_xlabel("column (SLICE X14..X27)")
        ax.set_ylabel("row within array")
        fig.colorbar(im, ax=ax, label="RO frequency (MHz)")
    fig.suptitle("Measured RO frequency map, Zybo Z7-10")
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "hw_frequency_map.png"), dpi=150)
    plt.close(fig)

    # --------------------------------------------- flips vs. frequency gap
    fig, ax = plt.subplots(figsize=(7, 4))
    for a in ARRAYS:
        ca, cb = load_counts(a)
        reads, _ = load_reads("hw_base", a, "room")
        p1 = reads.mean(axis=0)
        flip = np.minimum(p1, 1 - p1)                 # probability of the minority value
        gap = (ca.astype(float) - cb) / ((ca + cb) / 2) * 100
        ax.scatter(np.abs(gap), flip * 100, s=10, label="array {}".format(a))
    ax.set_xscale("symlog", linthresh=0.01)
    ax.set_xlabel("|frequency gap| of the pair (%)")
    ax.set_ylabel("bit flip rate over 100 reads (%)")
    ax.set_title("Unstable bits come from pairs with nearly equal frequencies")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "hw_flip_vs_gap.png"), dpi=150)
    plt.close(fig)

    # --------------------------------------------------------- PUF metrics
    results = {}
    for kind, label in (("hw_base", "baseline RO-PUF"), ("hw_cfg", "configurable RO-PUF")):
        log()
        log("== {} ==".format(label))
        refs = []
        for a in ARRAYS:
            room, troom = load_reads(kind, a, "room")
            warm, twarm = load_reads(kind, a, "warm")
            ref = room[0]
            refs.append(ref)
            # majority vote over the room reads: a reference free of single-read noise
            maj = (room.mean(axis=0) > 0.5).astype(np.uint8)
            for cond, reads, temps in (("room", room[1:], troom), ("warm", warm, twarm)):
                if reads is None or len(reads) == 0:
                    continue
                hd = analysis.intra_hd(ref, reads)
                ber = hd.mean()
                ber_maj = analysis.intra_hd(maj, reads).mean()
                results[(kind, a, cond)] = ber
                log("array {} {:<4} {:5.1f}-{:5.1f} C: intra-HD mean {:.2f} % max {:.2f} % "
                    "(vs majority reference {:.2f} %), "
                    "raw key failure {:.0f} %, ECC r=1 {:.0f} %, r=3 {:.0f} %".format(
                        a, cond, min(temps), max(temps), 100 * ber, 100 * hd.max(), 100 * ber_maj,
                        100 * analysis.raw_failure_rate(ref, reads),
                        100 * analysis.ecc_failure_rate(ref, reads, FEParams(rep=1)),
                        100 * analysis.ecc_failure_rate(ref, reads, FEParams(rep=3))))
        uq, hds = analysis.uniqueness(np.array(refs))
        alias = analysis.bit_aliasing(np.array(refs))
        log("uniqueness (inter-array HD) mean {:.2f} % (pairs: {})".format(
            100 * uq, ", ".join("{:.1f} %".format(100 * h) for h in hds)))
        log("uniformity {}, bit-aliasing mean {:.3f}".format(
            ", ".join("{:.3f}".format(analysis.uniformity(r)) for r in refs), alias.mean()))
        results[(kind, "uq")] = (uq, hds)

    # ---------------------------------------- ECC choice from measured BER
    log()
    log("== Predicted key-failure probability with the measured worst-case BER ==")
    for kind, label in (("hw_base", "baseline"), ("hw_cfg", "configurable")):
        worst = max(v for k, v in results.items() if k[0] == kind and len(k) == 3)
        line = "{:<13} worst BER {:.3f} %:".format(label, 100 * worst)
        for r in (1, 3, 5):
            line += "  r={} -> {:.1e}".format(r, analysis.key_failure_analytic(max(worst, 1e-6), FEParams(rep=r)))
        log(line)

    # -------------------------------------------------------- HD histograms
    fig, axes = plt.subplots(1, 2, figsize=(11, 4), sharey=True)
    bins = np.linspace(0, 0.6, 61)
    for ax, (kind, label) in zip(axes, (("hw_base", "baseline RO-PUF"), ("hw_cfg", "configurable RO-PUF"))):
        for a in ARRAYS:
            room, _ = load_reads(kind, a, "room")
            warm, _ = load_reads(kind, a, "warm")
            intra = analysis.intra_hd(room[0], np.vstack([room[1:]] + ([warm] if warm is not None else [])))
            ax.hist(intra, bins=bins, alpha=0.6, label="intra, array {}".format(a))
        ax.hist(results[(kind, "uq")][1], bins=bins, color="k", label="inter-array")
        ax.set_title(label)
        ax.set_xlabel("fractional Hamming distance")
        ax.set_yscale("log")
        ax.legend(fontsize=8)
    axes[0].set_ylabel("count (log)")
    fig.suptitle("Measured on the Zybo Z7-10: 100 room + 100 warm reads per array")
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "hw_hd.png"), dpi=150)
    plt.close(fig)

    with open(REPORT, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("\nsaved docs/figures/hw_*.png and", os.path.relpath(REPORT, ROOT))


if __name__ == "__main__":
    main()
