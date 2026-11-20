# Implementation Plan: Ring-Oscillator PUF Key Generator with Fuzzy Extractor

**Project:** P4. Ring-Oscillator PUF Key Generator with Fuzzy Extractor (Hardware Security)
**Target platform:** Digilent Zybo Z7-10 (Xilinx Zynq-7000 XC7Z010-1CLG400C), Vivado Design Suite
**Duration:** About 15 days (phase-based plan with no fixed dates)

---

## 1. Aim

Generate a stable, device-unique cryptographic key from ring-oscillator (RO) frequency variations on the FPGA. A code-offset fuzzy extractor corrects measurement noise. The key is used only inside the hardware, as the key of a keyed MAC, and is never readable over the system bus. A soft RV32 processor uses the key for challenge–response authentication.

---

## 2. Project Objectives

| ID | Objective | Measurable success criterion |
|----|-----------|------------------------------|
| **O1** | Build a placed RO array of 128–256 ROs using Pblock and LOC constraints | 256 ROs placed in a regular grid, survive implementation (no optimisation), and oscillate on hardware |
| **O2** | Build a counter-based pairwise measurement unit that produces a 128-bit response | 128 disjoint RO pairs compared, with a deterministic and repeatable measurement window |
| **O3** | Develop a golden model (Python) of the full fuzzy extractor: encode, add noise, decode | The model generates test vectors for every RTL block and predicts key-failure rate against bit-error rate |
| **O4** | Build a GF(2⁴) multiplier and inverse as ESPRESSO-minimised, BDD-verified logic blocks | Exhaustive equivalence: 256/256 multiplier cases and 16/16 inverse cases |
| **O5** | Build a BCH(15,7,t=2) syndrome and Peterson error-locator decoder with your own hand HLS, in two variants (1 and 2 GF multipliers) | Corrects every error pattern of weight ≤ 2 (exhaustive test). Area and latency comparison of the two variants is reported |
| **O6** | Implement a code-offset fuzzy extractor: repetition code concatenated with BCH(15,7,2) | Enrolment produces helper data. Reconstruction recovers the enrolled key under the measured noise |
| **O7** | Build an enrol/reconstruct/measure sequencer FSM with a one-time enrolment lock | Enrolment is impossible after lock. `key_valid` is asserted only after ECC success |
| **O8** | Prove the security properties with CTL model checking | Both mandatory properties pass in NuSMV/nuXmv: (a) key valid only after ECC success, (b) no enrolment after lock |
| **O9** | Integrate an RV32 SoC with a PUF/MAC peripheral and a challenge–response authentication program; helper data in SoC memory | The key is not reachable at any bus address. Authentication runs end to end over UART |
| **O10** | Characterise the PUF on ≥ 3 boards | Uniqueness (inter-chip HD ≈ 50%), reliability (≥ 100 reads plus a warm-board test), bit-aliasing, and key-failure rate before and after ECC |
| **O11** | Research, implement and evaluate one published RO-PUF improvement | Uniqueness, reliability and bit-aliasing compared with the baseline RO-PUF on the same boards |
| **O12** | Demonstrate the system | Authentication succeeds on the enrolled board and fails on a different board |

---

## 3. System Architecture

```
                         ┌─────────────────────────── Zynq-7010 PL ────────────────────────────┐
                         │                                                                     │
  PC (Python verifier)   │  ┌────────────┐   bus   ┌──────────────────────────────────────────┐ │
  ◄──── UART ──────────► │  │ RV32 core  │◄──────► │  PUF Key-Generator Peripheral            │ │
                         │  │ (PicoRV32) │         │                                          │ │
                         │  └─────┬──────┘         │  ┌──────────┐   ┌──────────────────────┐ │ │
                         │        │                │  │ Sequencer│──►│ RO Array (Pblock)    │ │ │
                         │  ┌─────▼──────┐         │  │   FSM    │   │ 256 ROs, 2×MUX,      │ │ │
                         │  │ BRAM: code │         │  │ + LOCK   │   │ 2 counters, window   │ │ │
                         │  │ + helper   │         │  └────┬─────┘   └──────────┬───────────┘ │ │
                         │  │   data     │         │       │        128-bit response          │ │
                         │  └────────────┘         │  ┌────▼───────────────────▼───────────┐  │ │
                         │                         │  │ Fuzzy Extractor (code-offset)      │  │ │
                         │                         │  │  Rep-r enc/dec ∘ BCH(15,7,2)       │  │ │
                         │                         │  │  Syndrome → Peterson → Chien       │  │ │
                         │                         │  │  GF(2⁴) mul/inv (ESPRESSO block)   │  │ │
                         │                         │  └────┬───────────────────────────────┘  │ │
                         │                         │       │ K (internal wires only)          │ │
                         │                         │  ┌────▼─────────┐                        │ │
                         │                         │  │ KDF + Keyed  │──► tag (readable)      │ │
                         │                         │  │ MAC (SipHash)│                        │ │
                         │                         │  └──────────────┘                        │ │
                         │                         └──────────────────────────────────────────┘ │
                         └─────────────────────────────────────────────────────────────────────┘
```

### 3.1 Key design decisions

| Area | Decision | Rationale |
|------|----------|-----------|
| **RO structure** | 1 NAND (enable) + 2 inverters (3 inversions) in LUT1/LUT2s, one RO per slice | Fits in one 7-series slice (4 LUTs). Identical intra-slice routing for every RO. Frequency stays in a range the counters can handle |
| **Placement** | Script-generated `LOC`/`BEL` constraints inside a dedicated Pblock, regular grid, `DONT_TOUCH` on all RO cells | Removes placement-induced systematic bias. Reproducible across builds and boards |
| **Pairing** | 256 ROs → 128 **disjoint, physically adjacent** pairs | Independent bits (no chain correlation). Adjacent pairs cancel global and systematic gradients |
| **Measurement** | Two 256:1 MUXes → two ripple/toggle-prescaled counters. Fixed gate window from the 125 MHz reference clock. Only the two selected ROs are enabled | Small area. Avoids cross-talk and self-heating. Counters are frozen before CDC sampling, so the readout is safe |
| **Error correction** | Code-offset construction: inner repetition code (rate 1/r), outer BCH(15,7,2). r ∈ {1,3,5} is a synthesis parameter that the measured BER determines | Required by the specification. The golden model sizes r from real data |
| **Key derivation** | Reconstruct the enrolled response *w* exactly, then K = KDF(w) (128 bits) | Gives a full-width 128-bit MAC key regardless of r. Residual entropy is reported honestly |
| **MAC** | SipHash-2-4 (128-bit key, 64-bit tag), reused as KDF with a fixed public key | Small ARX hardware. A 128-bit key matches the PUF key exactly |
| **ECC-success check** | Decoder flags failure when deg(Λ) ≠ number of Chien roots. Helper data also stores a key-check value (truncated hash of K) | Catches silent BCH mis-corrections when there are ≥ 3 errors, so `key_valid` cannot be asserted on a wrong key |
| **Enrolment lock** | Sticky lock register (only reset clears it) plus a lock word stored with the helper data | One-time lock behaviour without burning Zynq eFUSEs on shared lab boards |
| **Processor** | PicoRV32 (RV32IMC) soft core in PL with BRAM, UART and the PUF peripheral | Small, well-documented, standard RISC-V GCC toolchain |
| **Host link** | PL UART via Pmod USB-UART (preferred), or a minimal PS bare-metal bridge if no Pmod is available | The Zybo's on-board USB-UART is wired to PS MIO pins only |
| **Build variants** | `CHARACTERISATION=1` exposes raw responses for statistics. The secure build (`=0`) removes that path entirely | Data collection needs raw responses. The secure build must never expose key material |

### 3.2 Fuzzy-extractor parameter trade-off (128-bit response)

| Rep factor r | Response bits per BCH block | BCH blocks from 128 bits | Bits used | Helper data leakage (bits) | Residual entropy (ideal) |
|---|---|---|---|---|---|
| 1 | 15 | 8 | 120 | 64 | ≈ 56 bits |
| 3 | 45 | 2 | 90 | 76 | ≈ 14 bits |
| 5 | 75 | 1 | 75 | 68 | ≈ 7 bits |

The final value of r is chosen from the measured BER using the golden model: pick the smallest r that meets a key-failure target (for example ≤ 10⁻⁶). If more than r = 1 is needed, the report discusses the entropy limit. The research enhancement (Section 4, Phase 9) is the planned way to lower BER and allow a smaller r.

### 3.3 Peripheral register map (secure build)

| Register | Access | Description |
|----------|--------|-------------|
| `CTRL` | W | Commands: `MEASURE`, `ENROL`, `RECONSTRUCT`, `LOCK`, `MAC_START` |
| `STATUS` | R | `busy`, `ecc_ok`, `key_valid`, `locked`, `enrol_done`, `fail` |
| `HELPER[0..n]` | R/W | Helper data, written by software before `RECONSTRUCT` and readable after `ENROL` (public data) |
| `CHAL[0..1]` | W | 64-bit challenge / nonce |
| `TAG[0..1]` | R | 64-bit MAC tag |
| `TEMP` | R | XADC die temperature (for the warm-board test) |
| `RAW[0..3]` | R | **Characterisation build only.** Raw 128-bit response |

The key K, the reconstructed response and the codewords are never connected to the bus read multiplexer. This is checked by design review and by a netlist search (Section 6).

---

## 4. Implementation Phases

The phases are ordered by dependency. Phases in the same group can run in parallel across team members.

### Phase 0: Setup and specification freeze
- Create the Vivado project for the `xc7z010clg400-1` part with the Zybo Z7-10 master XDC. Set up the repository structure (Section 9).
- Install the toolchain: Vivado, the RISC-V GCC toolchain (`-march=rv32imc -mabi=ilp32`), Python 3 (numpy, matplotlib, `galois` optional), ESPRESSO, a BDD package (CUDD or Python `dd`), NuSMV/nuXmv, and optionally Yosys/SymbiYosys.
- Freeze the interface specs: response width, helper-data format, register map, command encodings, and FSM states.
- **Exit gate:** a "blinky" bitstream runs on every available board, and the toolchains are verified.

### Phase 1: Golden model (Python), O3
- Implement GF(2⁴) arithmetic with primitive polynomial x⁴ + x + 1, BCH(15,7,2) encoding with g(x) = x⁸ + x⁷ + x⁶ + x⁴ + 1, syndrome computation (S₁, S₃), the Peterson locator, Chien search, repetition encoding and majority decoding, the code-offset `Gen`/`Rep` procedures, and the KDF/MAC (SipHash reference).
- Add a noise model: a binary symmetric channel with BER p, plus a measured-data replay mode that uses real board responses.
- Produce key-failure-rate curves (simulated and analytical binomial) against p for r ∈ {1,3,5}.
- Export test vectors (`.hex`/`.mem`) for every RTL unit: GF tables, syndromes, locators, full decode, and SipHash.
- **Exit gate:** the model round-trips enrol → noise → reconstruct, and the failure curves are plotted.

### Phase 2 (parallel group A): RO array and measurement unit, O1, O2

*This is the critical-path hardware. Start it early, because the real BER drives the ECC parameters.*

- Write the RO cell RTL with `(* DONT_TOUCH = "TRUE", KEEP = "TRUE" *)` on the LUT primitives (instantiate `LUT1`/`LUT2` directly).
- Write a Tcl script that generates `LOC`/`BEL` constraints for 256 ROs in a regular grid inside a Pblock (for example a 16 × 16 slice region in one clock region).
- Handle Vivado combinational-loop DRCs: `set_property ALLOW_COMBINATORIAL_LOOPS TRUE` on the RO nets, `set_false_path` / asynchronous clock groups for RO-clocked counters.
- Build the measurement unit: pair selection MUXes, counters (with a toggle-flop prescaler if f_RO is above the counter's f_max), a gate-window timer, freeze-then-sample CDC, comparator, and a 128-bit response shift register.
- Build the characterisation readout path (UART dump of raw responses and raw counter values).
- Verify on hardware: check the RO frequency spread, confirm the placement in the Device view, and confirm that responses are stable and differ between boards.
- **Exit gate:** raw 128-bit responses and per-RO counts are collected from one board and fed into the golden model for an initial BER estimate.

### Phase 3 (parallel group B): GF(2⁴) arithmetic via ESPRESSO/BDD, O4
- Generate truth tables from the golden model: the multiplier (8 inputs, 4 outputs) and the inverse (4 inputs, 4 outputs, with inv(0) defined as 0).
- Write PLA files, minimise them with ESPRESSO, and auto-generate Verilog sum-of-products from the minimised cover.
- Build BDDs (reference and minimised forms) to verify equivalence and to compare node counts across variable orderings.
- Compare with an XOR-based (Mastrovito) multiplier: LUT count and depth after Vivado synthesis. This gives a short analysis of why XOR-heavy functions suit LUTs better than SOP.
- **Exit gate:** exhaustive self-checking testbench passes (256 + 16 cases), and the ESPRESSO/BDD report is written.

### Phase 4 (parallel group B): BCH decoder via hand HLS, O5
- **Algorithm → DFG:** syndrome S₁ = r(α), S₃ = r(α³) as constant XOR networks. Peterson for t = 2: Λ₁ = S₁, Λ₂ = S₃·S₁⁻¹ + S₁². This is algebraically rewritten from (S₃ + S₁³)/S₁ to shorten the critical path. The special cases are S₁ = S₃ = 0 (no error) and S₃ = S₁³ (single error).
- **Hand HLS steps:** write the data-flow graph, run ASAP/ALAP and list scheduling, bind resources, allocate registers, generate the controller FSM, and write the RTL by hand.
- **Variant A (1 GF multiplier)** and **variant B (2 GF multipliers)**:
  - Peterson stage: 2 multiply steps against 1.
  - Chien search (15 positions × 2 multiplies): about 30 cycles against about 15.
- Detect decoder failure when the Chien root count ≠ deg(Λ).
- Verify with an **exhaustive** test: every error pattern of weight ≤ 2 (1 + 15 + 105 = 121 patterns) on every codeword (128) for both variants. Run sampled weight-3 patterns to check failure detection and mis-correction behaviour.
- Report latency (cycles), f_max, LUT/FF counts and an area×latency product for A against B.
- **Exit gate:** both variants pass, and the comparison table is complete.

### Phase 5: Fuzzy extractor and sequencer FSM, O6, O7
- Fuzzy-extractor datapath:
  - **Enrol:** sample a random message m. A TRNG from RO jitter is optional; a PC-supplied seed is acceptable for the lab and should be documented. Compute c = Rep_r(BCH_enc(m)) and helper h = w ⊕ c. Store h and the key-check value.
  - **Reconstruct:** compute c' = w' ⊕ h, decode the repetition code by majority, decode BCH, re-encode to get c, compute w = c ⊕ h, then K = KDF(w) and verify the key-check value.
- Sequencer FSM states: `IDLE → MEASURE → {ENROL_ENC → STORE_HELPER → (LOCK)} | {LOAD_HELPER → REP_DEC → BCH_DEC → KDF → CHECK} → KEY_VALID / FAIL`.
- Lock logic: the `ENROL` command is ignored (and flagged) when `locked = 1`. Lock is sticky until reset.
- Key zeroisation: clear K on `FAIL`, on reset, and on a new `RECONSTRUCT`.
- **Exit gate:** a top-level simulation with the golden-model vectors passes for enrol and reconstruct, including injected noise and forced-failure cases.

### Phase 6: RV32 SoC and authentication, O9
- Build the SoC: PicoRV32, BRAM (code, data and the helper-data region), UART, the PUF/MAC peripheral and a simple memory-mapped bus.
- Write the SipHash-2-4 MAC core and check it against the published reference test vectors.
- Firmware (C, bare-metal):
  - **Enrolment mode:** measure, enrol, return the helper data to the PC, lock.
  - **Authentication mode:** load helper data, reconstruct, receive a challenge, return the MAC tag. Report ECC failure explicitly.
- PC verifier (Python):
  - At enrolment, store the helper data and a table of challenge–response pairs (challenge, tag) captured from the device. Tags are outputs and never the key.
  - At authentication, issue an unused challenge and compare tags.
- **Key-isolation check:** review the bus decode logic, and search the post-synthesis netlist to confirm that no path exists from the K register to the bus read MUX.
- **Exit gate:** a full authentication round trip works on one board.

### Phase 7: Formal verification with CTL, O8
- Model the sequencer FSM in NuSMV, either by hand or by generating it from RTL with Yosys `write_smv`. Model the ECC result as a free input.
- Mandatory CTL properties:
  - `AG (key_valid -> ecc_ok)`: the key is valid only after ECC success.
  - `AG (locked -> AG !(state = ENROL))`: no enrolment after lock.
- Supporting properties:
  - `AG (locked -> AG locked)`: lock is sticky.
  - `AG (!key_valid -> !mac_valid)`: no MAC output without a valid key.
  - `AG (state = FAIL -> key = 0)`: key is zeroised on failure.
  - `AG (busy -> AF done)`: liveness, under fairness.
- Optionally write matching SVA assertions and check them on the RTL itself with SymbiYosys or in simulation.
- Deliberately insert bugs (for example, allow enrol when locked) and show that the checker produces counterexamples.
- **Exit gate:** all properties pass, and the counterexample traces for the mutants are recorded.

### Phase 8: Characterisation on multiple boards, O10
- Use the same characterisation bitstream on **≥ 3 Zybo boards**.
- Data collection: ≥ 100 response reads per board at room temperature, and ≥ 100 reads under the warm-board condition. For the warm condition, use a controlled on-chip heater (a block of toggling flip-flops) and/or external warm air. Log the XADC die temperature and stay below the 85 °C junction limit.
- Metrics (Python scripts, with plots):
  - **Uniqueness:** average inter-chip HD = 2/(k(k−1)) · Σ HD(Rᵢ,Rⱼ)/n. Target ≈ 50%.
  - **Reliability:** intra-chip HD between the reference read and each later read, plus the worst case. Reliability = 100% − avg intra-HD.
  - **Bit-aliasing:** per-bit-position fraction of 1s across boards. Ideal is 50%.
  - **Uniformity:** fraction of 1s per response.
  - **Key-failure rate before ECC:** fraction of reads where the raw response ≠ the enrolled response.
  - **Key-failure rate after ECC:** fraction of reconstructions where `key_valid = 0` or K ≠ K_enrolled. Extrapolate to low rates with the binomial model and the measured BER.
- Feed the measured BER back to finalise the repetition factor r (Section 3.2).
- **Exit gate:** a metrics table and plots exist for every board and condition.

### Phase 9: Research enhancement, O11
- **Recommended paper:** A. Maiti and P. Schaumont, *"Improved Ring Oscillator PUF: An FPGA-friendly Secure Primitive,"* Journal of Cryptology, 2011 (configurable ROs).
  - Each RO stage selects between two LUT paths. At enrolment, the configuration that maximises |Δf| for each pair is chosen and stored in the helper data. This is reliability-aware helper data.
  - It reuses the same array and measurement unit with only a small change to the RO cell. It needs no extra ROs, so the 128-bit response is kept.
- **Alternatives:**
  - 1-out-of-k masking (Suh and Devadas, DAC 2007). Very reliable, but 256 ROs give only 256/k bits, which conflicts with the 128-bit response.
  - Temperature-aware cooperative RO-PUF (Yin and Qu, HOST 2009).
  - Regression-based entropy distiller (Yin and Qu).
- Evaluation: rerun Phase 8 with the identical protocol on the same boards. Report baseline against improved uniqueness, reliability, bit-aliasing, BER and the required repetition factor r.
- **Exit gate:** a comparison table and short analysis are written.

### Phase 10: Demonstration and documentation, O12
- Demo script:
  1. Enrol board A and lock it.
  2. Authenticate A (pass).
  3. Try to enrol A again (rejected).
  4. Run the same bitstream with A's helper data on board B. The result is an ECC failure or a tag mismatch, so authentication fails.
- Final report:
  - architecture
  - golden model
  - ESPRESSO/BDD results
  - hand-HLS scheduling and 1-vs-2-multiplier comparison
  - RO placement
  - CTL proofs
  - characterisation results
  - research comparison
  - resource utilisation and timing
  - security discussion (entropy, helper-data leakage, lab substitutes for eFUSE and TRNG)
  - limitations
- Also prepare a demo video or screenshots and a cleaned repository with build scripts.

---

## 5. Dependency Overview and Critical Path

```
Phase 0 ──► Phase 1 (golden model) ──────────────┬──► Phase 3 (GF blocks) ──► Phase 4 (BCH HLS) ──┐
        │                                        │                                                │
        └──► Phase 2 (RO array + measurement) ───┼──► early BER data ─────────────────────────────┼─► Phase 5 (FE + FSM) ─► Phase 6 (SoC + auth) ─► Phase 10 (demo)
                                                 │                                                │          │
                                                 └──► Phase 8 (characterisation, ≥3 boards) ◄─────┘          └─► Phase 7 (CTL proofs)
                                                                  │
                                                                  └──► Phase 9 (research enhancement)
```

**Critical path:** RO array on hardware → BER data → ECC parameter freeze → fuzzy extractor integration → SoC authentication → multi-board demo.

**Suggested workstreams for a team:**

| Workstream | Phases |
|------------|--------|
| A: PUF hardware | 2, 8, 9 |
| B: ECC and arithmetic | 1, 3, 4, 5 |
| C: SoC, firmware and verifier | 6, 10 |
| D: Verification and formal | 7, plus testbenches across all phases |

---

## 6. Verification Strategy

| Level | Method | Pass criterion |
|-------|--------|----------------|
| GF(2⁴) mul/inv | Exhaustive testbench against golden tables. BDD equivalence check | 272/272 cases match. BDDs are equivalent |
| BCH decoder (both variants) | Exhaustive error patterns of weight ≤ 2 on all codewords. Sampled weight-3 patterns | 100% correction for weight ≤ 2. Failure flag observed for detectable weight-3 patterns |
| Repetition code and fuzzy extractor | Golden-model vectors with injected BSC noise | Bit-exact match with the Python model |
| SipHash MAC/KDF | Reference test vectors | All vectors match |
| Sequencer FSM | Directed and random simulation. CTL model checking | All CTL/SVA properties hold |
| RO array | Post-implementation Device view check. On-board frequency dump | All 256 ROs present, placed as constrained, and oscillating |
| SoC | Firmware-driven simulation and hardware run | Authentication round trip passes |
| Key isolation | Bus-decode review. Netlist search for paths from the K register to the bus | No path exists |
| System | Multi-board characterisation and demo | Metrics in Section 7 met. Demo passes and fails as expected |

---

## 7. Acceptance Criteria (mapped to project deliverables)

| Deliverable (from the problem statement) | Acceptance criterion |
|------------------------------------------|----------------------|
| Uniqueness across ≥ 3 boards | Inter-chip HD reported for every board pair. Mean close to 50% (for example 40–60%) |
| Reliability over ≥ 100 reads plus a warm-board test | Intra-chip HD reported at room temperature and warm, with the die temperature logged by the XADC |
| Key-failure rate before and after ECC | Both measured empirically, plus a binomial extrapolation. After-ECC rate ≪ before-ECC rate |
| CTL proofs | Both mandatory properties proven. Mutant counterexamples shown |
| Demo | The enrolled board authenticates. A different board fails |
| Golden model | Full encode, noise and decode chain, used to generate all RTL test vectors |
| BCH plus Peterson via hand HLS (1 vs 2 multipliers) | Both variants implemented and verified, with a latency/area comparison table |
| Sequencer FSM | Enrol, reconstruct and measure modes plus the one-time lock, all verified |
| GF(2⁴) ESPRESSO/BDD block | Minimised logic generated, verified and compared |
| RO array with placement constraints | Pblock and LOC constraints used, with screenshots of the placed array |
| RV32 challenge–response program | Firmware and PC verifier work. Helper data held in SoC memory |
| Research | Paper implemented, with baseline and improved metrics compared |

---

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Vivado removes or merges RO logic, or fails DRC on combinational loops | RO array does not work | Instantiate LUT primitives. Use `DONT_TOUCH`/`KEEP`. Set `ALLOW_COMBINATORIAL_LOOPS`. Check the post-implementation netlist |
| RO frequency is too high for the counters | Wrong counts | 3-inversion RO length. Toggle-flop prescaler. Check counter timing on a test RO first |
| Systematic placement or routing bias gives poor uniqueness or bit-aliasing | Uniqueness well below 50% | Compare only physically adjacent pairs. Use an identical relative placement and a single Pblock region. Consider the configurable-RO enhancement |
| BER higher than BCH(15,7,2) can handle | High key-failure rate | Increase r (parameterised). Use reliability-aware helper data or configurable ROs (Phase 9) |
| Fewer than 3 boards available at once | Uniqueness deliverable at risk | Book lab boards early. Reuse the same characterisation bitstream and automated scripts so each board takes only a few minutes |
| No PL-accessible UART on the Zybo | No host communication | Pmod USB-UART, or a PS bare-metal UART bridge over AXI |
| Integration problems late in the project | Demo at risk | Integrate early and incrementally. Keep a working "baseline" bitstream at every gate |
| Time pressure | Incomplete deliverables | Use the priority tiers below. Keep the research phase decoupled so it can run in parallel |
| Irreversible eFUSE programming | Damages shared lab boards | Never program eFUSEs. Emulate the lock with a sticky register and a lock word, and document this |

### Priority tiers

| Tier | Scope |
|------|-------|
| **Must** | O1–O7, O9, O10 (baseline), O12 |
| **Should** | O8 (CTL), full 1-vs-2-multiplier comparison, warm-board test |
| **Could** | O11 extended evaluation, on-chip TRNG for enrolment, SVA on RTL with SymbiYosys |

O8 and O11 are graded deliverables, so plan to finish them. The tiers only set the order of work if time runs short.

---

## 9. Proposed Repository Structure

```
RTL_Project/
├── docs/                    # Plan, report, figures, register map
├── model/                   # Python golden model, vector generator, metrics scripts
├── rtl/
│   ├── puf/                 # ro_cell, ro_array, measure_unit
│   ├── gf/                  # ESPRESSO-generated gf_mul, gf_inv (+ Mastrovito reference)
│   ├── ecc/                 # rep_codec, bch_enc, bch_dec_1mul, bch_dec_2mul
│   ├── fe/                  # fuzzy_extractor, sequencer_fsm, lock
│   ├── crypto/              # siphash core (MAC + KDF)
│   └── soc/                 # picorv32 wrapper, bus, bram, uart, puf_periph, top
├── tb/                      # Self-checking testbenches + golden vectors
├── formal/                  # NuSMV models, CTL specs, (optional) SBY files
├── constraints/             # Zybo master XDC, Pblock/LOC generator Tcl, generated XDC
├── sw/                      # RV32 firmware (C, linker script, Makefile)
├── host/                    # Python verifier, UART tools, data capture
├── data/                    # Raw board measurements (per board / condition)
└── scripts/                 # Vivado non-project build Tcl, espresso/BDD flow
```

---

## 10. Final Deliverables Checklist

- [ ] Golden model with test-vector generation and failure-rate analysis
- [ ] ESPRESSO-minimised and BDD-verified GF(2⁴) multiplier and inverse
- [ ] BCH(15,7,2) decoder: hand-HLS documentation (DFG, schedules, binding) and 1-mul and 2-mul RTL with a comparison
- [ ] RO array with Pblock/LOC constraints and placement screenshots
- [ ] Measurement unit producing a 128-bit response
- [ ] Code-offset fuzzy extractor (repetition ∘ BCH) with enrolment and reconstruction modes
- [ ] Sequencer FSM with one-time enrolment lock
- [ ] SipHash keyed MAC/KDF. Key not readable over the bus (verified)
- [ ] RV32 SoC, challenge–response firmware and Python verifier. Helper data in SoC memory
- [ ] CTL proofs: key valid only after ECC success, and no enrolment after lock
- [ ] Characterisation on ≥ 3 boards: uniqueness, reliability (≥ 100 reads plus warm test), bit-aliasing, key-failure rate before and after ECC
- [ ] Research paper implementation with baseline comparison
- [ ] Live demo: enrolled board passes, other board fails
- [ ] Final report with resource utilisation, timing, security analysis and limitations
