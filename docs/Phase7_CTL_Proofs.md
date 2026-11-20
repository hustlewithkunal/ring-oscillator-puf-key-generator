# Phase 7: CTL Proofs of the Key-Generator Sequencer

**Deliverable:** "CTL proofs: key valid only after ECC success; no enrolment after lock."

**Result:** both required properties, and five supporting ones, **hold** on a formal model of the fuzzy-extractor sequencer. Deliberately broken versions are caught with counterexample traces. The model is checked against the real RTL: every transition the hardware makes in simulation is a transition of the model.

---

## 1. Tooling

NuSMV/nuXmv are not installed, and running downloaded executables is blocked on this machine. So the project uses its own **explicit-state CTL model checker**, [`model/ctl.py`](../model/ctl.py), about 200 lines of Python:

- **State graph:** the reachable states are built by breadth-first search from the initial states.
- **Core operators:** the standard labelling algorithms (Clarke–Emerson–Sistla):
  - **EX f:** states with a successor in [f]
  - **E[f U g]:** least fixpoint, Z = [g] ∪ ([f] ∩ EX Z)
  - **EG f:** greatest fixpoint, Z = [f] ∩ EX Z
- **Derived operators:** AX f = ¬EX ¬f, EF f = E[true U f], AG f = ¬EF ¬f, AF f = ¬EG ¬f, and A[f U g] = ¬(E[¬g U (¬f ∧ ¬g)] ∨ EG ¬g).
- **Counterexamples:** for a failing `AG` property, the shortest path from an initial state is produced. For `AG(p → AG q)`, the path continues from the p-state to the state violating q.

The checker has its own tests (`model/tests/test_ctl.py`): every operator is checked against hand-computed answers on a small structure.

## 2. The model ([`model/fe_fsm_model.py`](../model/fe_fsm_model.py))

The model follows `rtl/fe/fuzzy_extractor.v` state by state.

**State variables:**

| Variable | Values |
|----------|--------|
| `state` | IDLE, MEAS_REQ, MEAS_WAIT, ENC, REPDEC, BCH_START, BCH_WAIT, REBUILD, H_INIT, H_BLK, H_WAIT, FINISH |
| `op` | MEASURE, ENROL, RECON, MAC |
| `job` | KDF_LO, KDF_HI, KCV, MAC |
| `blk` | BCH block index (2 blocks, REP = 3 as in the SoC) |
| `locked`, `key_valid`, `ecc_ok`, `kcv_ok` | status flags, exactly as in the RTL |
| `key_set` | the key register holds a derived (non-zero) key |

**Free (nondeterministic) inputs.** Everything that depends on data or timing is left free, so the proof covers every combination:
- which command arrives, and when (including undefined codes)
- whether the PUF has answered yet
- whether each BCH block decodes or fails
- whether the SipHash core is busy, or at its last block
- whether the recomputed key-check value matches
- whether the lock starts set (`boot_locked`)

Size: **238 reachable states, 448 transitions.**

## 3. Results

| Property | CTL formula | Result |
|----------|-------------|--------|
| **P1. Key valid only after ECC success (spec)** | `AG (key_valid → ecc_ok)` | ✅ holds |
| **P2. No enrolment after lock (spec)** | `AG (locked → AG ¬enrol_started)` | ✅ holds |
| P3. Lock is sticky | `AG (locked → AX locked)` | ✅ holds |
| P4. Key valid only after the KCV matched | `AG (key_valid → kcv_ok)` | ✅ holds |
| P5. MAC only with a valid key | `AG (mac_running → key_valid)` | ✅ holds |
| P6. No key left behind when idle and invalid (zeroisation) | `AG ((idle ∧ ¬key_valid) → ¬key_set)` | ✅ holds |
| P7. Every command can complete | `AG (busy → EF idle)` | ✅ holds |
| N1. Non-vacuity: a valid key is reachable | `EF key_valid` | ✅ holds |
| N2. Non-vacuity: enrolment can lock and a key can still be valid later | `EF (locked ∧ EF key_valid)` | ✅ holds |

`enrol_started` means the sequencer has just accepted an ENROL command (state MEAS_REQ with op = ENROL). The non-vacuity checks show that P1–P6 are not true only because the states they talk about are unreachable.

## 4. Mutants: the checker finds the bugs

| Mutant (deliberate bug) | Violated property | Counterexample |
|-------------------------|-------------------|----------------|
| ENROL lock check removed | P2 | 2 steps: IDLE with `locked = 1` → MEAS_REQ with op = ENROL |
| KCV comparison result ignored | P4 | 18 steps: a reconstruction with every block decoded, then a KCV mismatch, still ends with `key_valid = 1, kcv_ok = 0` |
| BCH decoder failure ignored (and `ecc_ok` not required) | P1 | 16 steps: block 0 fails (BCH_WAIT → REBUILD with `ecc_ok = 0`), then the key becomes valid |

The full traces are in [`docs/reports/ctl_proofs.txt`](reports/ctl_proofs.txt). The same two security mutants (lock and KCV) were also caught by simulation in Phase 5. The CTL proof adds the guarantee for *every* input sequence, not just the simulated ones.

## 5. Link to the RTL (conformance)

A model only proves something about the hardware if it really describes the hardware. With `-d FSM_TRACE`, the testbench `tb/tb_fuzzy_extractor.v` writes the RTL values of all model variables on every clock cycle. `check_trace()` then confirms that every consecutive pair of RTL states (outside reset) is a transition of the model:

| Trace | Cycles | Distinct transitions | Not in the model |
|-------|--------|----------------------|------------------|
| `tb_fuzzy_extractor`, REP = 3, 24 full life cycles + wrong-KCV + boot-lock | 3,527 | 76 | **0** |

## 6. How to run

```sh
python -m model.fe_fsm_model                                   # proofs + mutants
python -m unittest model.tests.test_ctl                         # checker self-test
# conformance: simulate tb_fuzzy_extractor with -d FSM_TRACE, then
python -m model.fe_fsm_model --trace <sim dir>/fsm_trace.txt
```

## 7. Limits

- **Reset is not modelled.** The proof covers one power cycle. Across a reset, the lock is restored from `boot_locked`, which emulates a fuse. Setting SW3 on the board makes the lock survive a reset.
- **Data correctness is out of scope.** The datapath is abstracted: the proofs are about *control*, meaning when `key_valid`, `locked` and the MAC are allowed to happen. That the key and tags are *correct* is shown by bit-exact simulation against the golden model (Phase 5) and on the board (Phase 6).
