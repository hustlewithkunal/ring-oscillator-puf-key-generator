"""Run every self-checking testbench of the project with the Vivado simulator (xsim).

Run from the project root:
    python scripts/run_sims.py            # all tests (about 8 minutes)
    python scripts/run_sims.py --quick    # skip the slow RO-model PUF test (about 4 minutes)
    python scripts/run_sims.py gf soc     # only the named tests
    python scripts/run_sims.py --list     # show the test names

Each test runs in build/sim/<name>/: the test vectors (.mem) are copied there, firmware
images are assembled with sw/rvasm.py, then xvlog / xelab / xsim are called. A test passes
when its PASS line appears and no SystemVerilog assertion failed.

Vivado is found through the VIVADO_BIN environment variable (the folder containing xvlog),
then XILINX_VIVADO (set by Vivado's settings64 script), then PATH, then the default
C:/Xilinx/Vivado/2024.2/bin.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIN = os.name == "nt"

GF = ["rtl/gf/gf16_mul_sop.v", "rtl/gf/gf16_mul_xor.v", "rtl/gf/gf16_inv_sop.v", "rtl/gf/gf16_mul.v"]
FE = GF + ["rtl/ecc/bch_syndrome.v", "rtl/ecc/bch_chien_x.v", "rtl/ecc/bch_dec_2mul.v",
           "rtl/ecc/bch_enc.v", "rtl/ecc/rep_codec.v", "rtl/crypto/siphash24.v", "rtl/fe/fuzzy_extractor.v"]
PUF_SIM = ["rtl/puf/sim/ro_cell_sim.v", "rtl/puf/ro_array.v", "rtl/puf/puf_measure.v"]
SOC = ["rtl/soc/rv32_core.v", "rtl/soc/soc_ram.v", "rtl/soc/soc.v"]


def fe_test(rep, trace=False):
    return dict(src=FE + ["tb/tb_fuzzy_extractor.v"], sv=["tb/fe_sva.sv"],
                top=["tb_fuzzy_extractor", "fe_sva_bind"], generic="REP={}".format(rep),
                mem=["model/vectors/fe_r{}.mem".format(rep)], define="FSM_TRACE" if trace else None,
                ok=r"PASS: fuzzy_extractor")


TESTS = {
    "gf":         dict(src=GF[:3] + ["tb/tb_gf16_sop.v"], top=["tb_gf16_sop"],
                       mem=["model/vectors/gf_mul.mem", "model/vectors/gf_inv.mem"], ok=r"^PASS"),
    "bch_dec":    dict(src=GF + ["rtl/ecc/bch_syndrome.v", "rtl/ecc/bch_chien_x.v", "rtl/ecc/bch_dec_1mul.v",
                                 "rtl/ecc/bch_dec_2mul.v", "tb/tb_bch_dec.v"],
                       top=["tb_bch_dec"], mem=["model/vectors/bch_dec.mem"], ok=r"^PASS"),
    "siphash":    dict(src=["rtl/crypto/siphash24.v", "tb/tb_siphash24.v"], top=["tb_siphash24"],
                       mem=["model/vectors/siphash.mem"], ok=r"^PASS"),
    "ecc_blocks": dict(src=["rtl/ecc/bch_enc.v", "rtl/ecc/rep_codec.v", "tb/tb_ecc_blocks.v"],
                       top=["tb_ecc_blocks"], mem=["model/vectors/bch_enc.mem"], ok=r"^PASS"),
    "fe_r1":      fe_test(1),
    "fe_r3":      fe_test(3),
    "fe_r5":      fe_test(5),
    "fsm_trace":  dict(fe_test(3, trace=True), post="conformance"),
    "rv32_core":  dict(src=["rtl/soc/rv32_core.v", "rtl/soc/soc_ram.v", "tb/tb_rv32_core.v"], top=["tb_rv32_core"],
                       asm=[("sw/tests/core_selftest.S", "core_selftest.mem")], ok=r"PASS: RV32I"),
    "bch_sw":     dict(src=["rtl/soc/rv32_core.v", "rtl/soc/soc_ram.v", "tb/tb_bch_sw.v"], top=["tb_bch_sw"],
                       asm=[("sw/tests/bch_sw.S", "bch_sw.mem")], ok=r"BCH_SW: 64 decodes, 0 mismatches"),
    "soc":        dict(src=PUF_SIM + FE + SOC + ["tb/tb_soc.v"], top=["tb_soc"],
                       asm=[("sw/firmware.S", "firmware.mem")], ok=r"^PASS"),
    "puf_measure": dict(src=PUF_SIM + ["tb/tb_puf_measure.v"], top=["tb_puf_measure"], ok=r"^PASS", slow=True),
}


def find_vivado_bin():
    for cand in (os.environ.get("VIVADO_BIN"),
                 os.path.join(os.environ["XILINX_VIVADO"], "bin") if os.environ.get("XILINX_VIVADO") else None):
        if cand and os.path.isdir(cand):
            return cand
    exe = shutil.which("xvlog")
    if exe:
        return os.path.dirname(exe)
    default = "C:/Xilinx/Vivado/2024.2/bin"
    if os.path.isdir(default):
        return default
    sys.exit("Vivado not found: set VIVADO_BIN to the folder that contains xvlog")


def tool(vbin, name):
    return os.path.join(vbin, name + (".bat" if WIN else ""))


def run(cmd, cwd, log):
    res = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True, errors="replace")
    with open(log, "a", encoding="utf-8") as f:
        f.write("$ " + " ".join(cmd) + "\n" + res.stdout + "\n")
    return res.stdout


def run_test(name, t, vbin):
    wd = os.path.join(ROOT, "build", "sim", name)
    shutil.rmtree(wd, ignore_errors=True)
    os.makedirs(wd)
    log = os.path.join(wd, "run.log")
    for m in t.get("mem", []):
        shutil.copy(os.path.join(ROOT, m), wd)
    for src, out in t.get("asm", []):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "sw", "rvasm.py"), os.path.join(ROOT, src),
                            os.path.join(wd, out)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True)
        if r.returncode:
            return False, "assembler failed: " + r.stdout.strip()
    xvlog = [tool(vbin, "xvlog")] + (["-d", t["define"]] if t.get("define") else [])
    out = run(xvlog + [os.path.join(ROOT, s) for s in t["src"]], wd, log)
    if t.get("sv"):
        out += run([tool(vbin, "xvlog"), "-sv"] + [os.path.join(ROOT, s) for s in t["sv"]], wd, log)
    # xelab arguments go through an options file: Windows batch files split "REP=3" at '='
    opts = " ".join(t["top"]) + " -s snap"
    if t.get("generic"):
        opts += ' -generic_top "{}"'.format(t["generic"])
    with open(os.path.join(wd, "elab.opt"), "w") as f:
        f.write(opts + "\n")
    out += run([tool(vbin, "xelab"), "-f", "elab.opt"], wd, log)
    if re.search(r"^ERROR:", out, re.M):
        return False, "compile/elaborate error (see {})".format(os.path.relpath(log, ROOT))
    sim = run([tool(vbin, "xsim"), "snap", "-R"], wd, log)
    passed = re.search(t["ok"], sim, re.M) is not None
    asserts = len(re.findall(r"Assertion failed", sim))
    summary = next((l.strip() for l in sim.splitlines() if re.search(t["ok"], l)), "")
    if asserts:
        return False, "{} assertion failures".format(asserts)
    if not passed:
        fail = next((l.strip() for l in sim.splitlines() if "FAIL" in l or "MISMATCH" in l or "ERROR" in l), "")
        return False, fail or "no PASS line (see {})".format(os.path.relpath(log, ROOT))
    if t.get("post") == "conformance":
        r = subprocess.run([sys.executable, "-m", "model.fe_fsm_model", "--trace", os.path.join(wd, "fsm_trace.txt")],
                           cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        line = next((l for l in r.stdout.splitlines() if "RTL conformance" in l), "")
        return r.returncode == 0, line.strip() or "conformance check failed"
    return True, summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", help="test names (default: all)")
    ap.add_argument("--quick", action="store_true", help="skip slow tests")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for n, t in TESTS.items():
            print(n + ("  (slow)" if t.get("slow") else ""))
        return
    names = args.tests or [n for n, t in TESTS.items() if not (args.quick and t.get("slow"))]
    unknown = [n for n in names if n not in TESTS]
    if unknown:
        sys.exit("unknown test(s): " + ", ".join(unknown))
    vbin = find_vivado_bin()
    print("Vivado tools:", vbin)
    results = []
    for n in names:
        t0 = time.time()
        print("running {:<12}".format(n), end="", flush=True)
        ok, msg = run_test(n, TESTS[n], vbin)
        results.append(ok)
        print("{:<5} {:>5.0f} s  {}".format("PASS" if ok else "FAIL", time.time() - t0, msg[:110]))
    print("\n{}/{} tests passed".format(sum(results), len(results)))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
