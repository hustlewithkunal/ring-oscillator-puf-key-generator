"""Re-run every Python analysis of the project and report pass/fail.

Run from the project root:
    python scripts/run_analysis.py            # everything (about 2 minutes)
    python scripts/run_analysis.py --list     # show the steps
    python scripts/run_analysis.py bdd ctl    # only some steps

Outputs (regenerated in place, deterministic):
    model/vectors/*.mem, *.pla       test vectors for the testbenches
    docs/figures/*.png               plots
    docs/reports/*.txt               BDD, CTL, QM, hardware characterisation reports
    rtl/gf/gf16_*_sop.v              ESPRESSO-generated GF(2^4) logic (exact mode, as used in the bitstream)
"""

import argparse
import subprocess
import sys
import time
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable

STEPS = [
    ("tests",    "golden model, BDD and CTL-checker unit tests",
                 [PY, "-m", "unittest", "discover", "-s", "model/tests", "-t", "."]),
    ("vectors",  "test vectors for every testbench",            [PY, "-m", "model.gen_vectors"]),
    ("curves",   "key-failure vs. BER (choice of r)",           [PY, "-m", "model.failure_curves"]),
    ("simboards", "analysis flow on simulated boards",           [PY, "-m", "model.characterise", "--simulate"]),
    ("espresso", "ESPRESSO exact -> Verilog, exhaustive check", [PY, "scripts/espresso_flow.py", "--exact"]),
    ("qm",       "own Quine-McCluskey + exact cover",           [PY, "-m", "model.qm"]),
    ("bdd",      "BDD equivalence + all 40,320 orderings",      [PY, "scripts/bdd_flow.py"]),
    ("ctl",      "CTL proofs and mutant counterexamples",       [PY, "-m", "model.fe_fsm_model"]),
    ("hardware", "board measurements -> figures and report",    [PY, "-m", "model.hw_analysis"]),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("steps", nargs="*")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for name, desc, _ in STEPS:
            print("{:<10} {}".format(name, desc))
        return
    chosen = [s for s in STEPS if not args.steps or s[0] in args.steps]
    env = dict(os.environ, PYTHONUTF8="1", MPLBACKEND="Agg")
    ok_all = True
    for name, desc, cmd in chosen:
        t0 = time.time()
        r = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, errors="replace")
        ok = r.returncode == 0
        ok_all &= ok
        last = [l for l in r.stdout.strip().splitlines() if l.strip()]
        print("{:<10} {:<5} {:>5.0f} s  {}".format(name, "OK" if ok else "FAIL", time.time() - t0, desc))
        if not ok:
            print("\n".join("           | " + l for l in last[-15:]))
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
