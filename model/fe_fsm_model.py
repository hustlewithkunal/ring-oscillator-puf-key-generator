"""Formal model of the fuzzy-extractor sequencer (rtl/fe/fuzzy_extractor.v) and its
CTL proofs (Phase 7).

The model follows the RTL sequencer state by state. Everything that depends on data
or timing is a free (nondeterministic) input, so the checker covers every possible
combination: which command arrives and when, whether the PUF answers, whether each BCH
block decodes, whether the SipHash core is ready / at its last block, whether the
recomputed key-check value matches. The lock may start set or clear (boot_locked).

State = (state, op, job, blk, locked, key_valid, ecc_ok, kcv_ok, key_set)
  key_set = the key register holds a non-zero (derived) key

Conformance: tb_fuzzy_extractor (compiled with -d FSM_TRACE) writes the RTL values of
these variables every cycle; check_trace() confirms that every RTL transition is a
transition of this model, so the proofs are about the actual hardware behaviour.

Run from the project root:   python -m model.fe_fsm_model [--trace fsm_trace.txt]
"""

import argparse
import itertools
import os

from .ctl import Model, show

STATES = ["IDLE", "MEAS_REQ", "MEAS_WAIT", "ENC", "REPDEC", "BCH_START", "BCH_WAIT",
          "REBUILD", "H_INIT", "H_BLK", "H_WAIT", "FINISH"]
OPS = ["MEASURE", "ENROL", "RECON", "MAC"]
JOBS = ["KDF_LO", "KDF_HI", "KCV", "MAC"]
CMDS = [None, 1, 2, 3, 4, 5, 0]          # None = no command; 0 stands for any undefined code
NBLK = 2                                  # BCH blocks for REP = 3 (the value in the SoC)


def successors(s, mutant=None):
    state, op, job, blk, locked, kv, ecc, kcv, key = s
    out = set()

    def emit(state=state, op=op, job=job, blk=blk, locked=locked, kv=kv, ecc=ecc, kcv=kcv, key=key):
        out.add((state, op, job, blk, locked, kv, ecc, kcv, key))

    if state == "IDLE":
        for cmd in CMDS:
            if cmd is None:
                emit()
            elif cmd == 1:
                emit(state="MEAS_REQ", op="MEASURE")
            elif cmd == 2:
                if locked and mutant != "no_lock_check":
                    emit()                                     # rejected
                else:
                    emit(state="MEAS_REQ", op="ENROL", key=0, kv=0, ecc=0, kcv=0)
            elif cmd == 3:
                emit(state="MEAS_REQ", op="RECON", key=0, kv=0, ecc=0, kcv=0)
            elif cmd == 4:
                emit(locked=1)
            elif cmd == 5:
                if kv:
                    emit(state="H_INIT", op="MAC", job="MAC")
                else:
                    emit()                                     # rejected
            else:
                emit()                                         # undefined: rejected
    elif state == "MEAS_REQ":
        emit(state="MEAS_WAIT")
    elif state == "MEAS_WAIT":
        emit()                                                 # PUF not ready yet
        emit(state={"ENROL": "ENC", "RECON": "REPDEC"}.get(op, "FINISH"))
    elif state == "ENC":
        emit(state="H_INIT", job="KDF_LO")
    elif state == "REPDEC":
        emit(state="BCH_START", blk=0)
    elif state == "BCH_START":
        emit(state="BCH_WAIT")
    elif state == "BCH_WAIT":
        emit()                                                 # decoder busy
        emit(state="FINISH")                                   # block failed
        if blk == NBLK - 1:
            emit(state="REBUILD", ecc=1)
        else:
            emit(state="BCH_START", blk=blk + 1)
        if mutant == "ignore_ecc":
            emit(state="REBUILD")                              # carry on after a failure
    elif state == "REBUILD":
        emit(state="H_INIT", job="KDF_LO")
    elif state == "H_INIT":
        emit(state="H_BLK")
    elif state == "H_BLK":
        emit()                                                 # core busy / more blocks
        emit(state="H_WAIT")                                   # last block sent
    elif state == "H_WAIT":
        emit()                                                 # tag not ready
        if job == "KDF_LO":
            emit(state="H_INIT", job="KDF_HI", key=1)
        elif job == "KDF_HI":
            emit(state="H_INIT", job="KCV", key=1)
        elif job == "KCV":
            if op == "ENROL":
                emit(state="FINISH", key=0, locked=1)          # AUTO_LOCK, key zeroised
            else:
                for match in (0, 1):                           # does the recomputed KCV match?
                    if mutant == "no_kcv_check":
                        valid = ecc                            # comparison result ignored
                    elif mutant == "ignore_ecc":
                        valid = match                          # ecc_ok not required
                    else:
                        valid = match and ecc                  # RTL: tag == kcv_ref && ecc_ok
                    # kcv_ok records the comparison (the RTL sets it only on a full match)
                    kflag = match if mutant == "no_kcv_check" else int(bool(valid))
                    if valid:
                        emit(state="FINISH", kv=1, kcv=kflag)
                    else:
                        emit(state="FINISH", key=0, kcv=kflag)
        else:
            emit(state="FINISH")                               # MAC tag
    elif state == "FINISH":
        emit(state="IDLE")
    return out


def initial_states():
    return [("IDLE", "MEASURE", "KDF_LO", 0, lk, 0, 0, 0, 0) for lk in (0, 1)]


PROPS = {
    "idle":          lambda s: s[0] == "IDLE",
    "busy":          lambda s: s[0] != "IDLE",
    "locked":        lambda s: s[4] == 1,
    "key_valid":     lambda s: s[5] == 1,
    "ecc_ok":        lambda s: s[6] == 1,
    "kcv_ok":        lambda s: s[7] == 1,
    "key_set":       lambda s: s[8] == 1,
    "enrol_started": lambda s: s[0] == "MEAS_REQ" and s[1] == "ENROL",
    "mac_running":   lambda s: s[1] == "MAC" and s[0] != "IDLE",
}

ap = lambda name: ("ap", name)
PROPERTIES = [
    ("P1 key valid only after ECC success (spec)", ("AG", ("->", ap("key_valid"), ap("ecc_ok")))),
    ("P2 no enrolment after lock (spec)",          ("AG", ("->", ap("locked"), ("AG", ("!", ap("enrol_started")))))),
    ("P3 lock is sticky",                          ("AG", ("->", ap("locked"), ("AX", ap("locked"))))),
    ("P4 key valid only after the KCV matched",    ("AG", ("->", ap("key_valid"), ap("kcv_ok")))),
    ("P5 MAC only with a valid key",               ("AG", ("->", ap("mac_running"), ap("key_valid")))),
    ("P6 no key left behind when idle and invalid", ("AG", ("->", ("&", ap("idle"), ("!", ap("key_valid"))),
                                                          ("!", ap("key_set"))))),
    ("P7 every command can complete",              ("AG", ("->", ap("busy"), ("EF", ap("idle"))))),
    ("N1 non-vacuity: a valid key is reachable",   ("EF", ap("key_valid"))),
    ("N2 non-vacuity: enrolment can lock",         ("EF", ("&", ap("locked"), ("EF", ap("key_valid"))))),
]


def fmt(s):
    st, op, job, blk, lk, kv, ecc, kcv, key = s
    return "{:<9} op={:<7} job={:<6} blk={} locked={} key_valid={} ecc_ok={} kcv_ok={} key_set={}".format(
        st, op, job, blk, lk, kv, ecc, kcv, key)


def check_trace(path, model):
    """Every consecutive pair of RTL states (outside reset) must be a model transition."""
    rows = []
    with open(path) as f:
        for line in f:
            v = line.split()
            if len(v) != 10 or not all(x.isdigit() for x in v):     # e.g. 'x' before reset
                continue
            rst, st, op, job, lk, kv, ecc, kcv, key, blk = map(int, v)
            rows.append((rst, (STATES[st], OPS[op], JOBS[job], blk, lk, kv, ecc, kcv, key)))
    checked = bad = 0
    seen = set()
    first_bad = None
    for (r0, a), (r1, b) in zip(rows, rows[1:]):
        if r0 or r1:
            continue
        checked += 1
        seen.add((a, b))
        if a not in model.index or model.index[b] not in model.succ[model.index[a]]:
            bad += 1
            first_bad = first_bad or (a, b)
    return checked, len(seen), bad, first_bad


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--trace", nargs="*", default=[], help="RTL trace files from tb_fuzzy_extractor")
    args = parser.parse_args()
    out = []

    def log(s=""):
        print(s)
        out.append(s)

    model = Model(initial_states(), successors, PROPS)
    log("Model of the fuzzy-extractor sequencer: {} reachable states, {} transitions".format(
        model.n_states, model.n_transitions))
    log()
    all_ok = True
    for name, f in PROPERTIES:
        ok = model.holds(f)
        all_ok &= ok
        log("{:<46} {:<6} {}".format(name, "HOLDS" if ok else "FAILS", show(f)))

    log()
    log("Mutants (deliberate bugs) -- the checker must find counterexamples:")
    for mutant, prop in (("no_lock_check", 1), ("no_kcv_check", 3), ("ignore_ecc", 0)):
        m = Model(initial_states(), lambda s, mu=mutant: successors(s, mu), PROPS)
        name, f = PROPERTIES[prop]
        ok = m.holds(f)
        log("  mutant {:<14}: {} -> {}".format(mutant, name, "HOLDS (not detected!)" if ok else "FAILS, counterexample:"))
        if not ok:
            for k, s in enumerate(m.counterexample(f)):
                log("      {:>2}: {}".format(k, fmt(s)))

    for path in args.trace:
        checked, distinct, bad, first = check_trace(path, model)
        log()
        log("RTL conformance ({}): {} cycles, {} distinct transitions, {} not in the model".format(
            os.path.basename(path), checked, distinct, bad))
        if first:
            log("  first mismatch: {} -> {}".format(fmt(first[0]), fmt(first[1])))
        all_ok &= bad == 0

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rep = os.path.join(root, "docs", "reports", "ctl_proofs.txt")
    os.makedirs(os.path.dirname(rep), exist_ok=True)
    with open(rep, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("\nsaved", os.path.relpath(rep, root))
    raise SystemExit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
