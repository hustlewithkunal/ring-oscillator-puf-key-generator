# RO-PUF Key Generator with Fuzzy Extractor: Build and Re-run Guide

**VL401 Course Project P04**, Ring-Oscillator PUF Key Generator with Fuzzy Extractor, on the Digilent **Zybo Z7-10** (Zynq-7010, `xc7z010clg400-1`).

This folder holds everything needed to rebuild the project and re-run every analysis, simulation, synthesis study and board measurement on a fresh computer:
- all source code (RTL, testbenches, firmware, Python models, scripts)
- the test vectors, board measurements and constraints
- prebuilt bitstreams
- the report and the documentation

This guide says what to install, then how to reproduce each result, with the numbers you should expect.

---

## Contents

- [Quick start on Windows: double-click launchers](#quick-start-on-windows-double-click-launchers)
1. [What is in this folder](#1-what-is-in-this-folder)
2. [What to install first](#2-what-to-install-first)
3. [Quick check of the installation](#3-quick-check-of-the-installation)
4. [Re-run all analyses (Python)](#4-re-run-all-analyses-python)
5. [Re-run all simulations (Vivado xsim)](#5-re-run-all-simulations-vivado-xsim)
6. [Re-run the synthesis studies](#6-re-run-the-synthesis-studies)
7. [Build the bitstreams](#7-build-the-bitstreams)
8. [Run on the board: demo and PUF measurements](#8-run-on-the-board-demo-and-puf-measurements)
9. [Rebuild ESPRESSO (optional)](#9-rebuild-espresso-optional)
10. [Compile the report](#10-compile-the-report)
11. [Summary of expected results](#11-summary-of-expected-results)
12. [Troubleshooting](#12-troubleshooting)
13. [Where to read more](#13-where-to-read-more)

**All commands are run from the top of this folder** (the folder containing this `README.md`), in Command Prompt, PowerShell or Git Bash.

---

## Quick start on Windows: double-click launchers

Three `.bat` files in the top folder run the board demos with no typing. Connect the board (PROG/UART USB port, powered on, **SW0–SW3 all OFF**), close any open Vivado Hardware Manager, and double-click one:

| File | What it does | Time |
|---|---|---|
| `Run_Baseline_Demo.bat` | Full demo with the **baseline** RO-PUF: enrolment, lock, authentication after a reset, two impostor devices, 100 reconstructions. Ends with a PASS/FAIL list. | about 1 min |
| `Run_Configurable_Demo.bat` | The same demo with the **configurable** RO-PUF (the research enhancement). | about 1 min |
| `Show_Key.bat` | Asks B (baseline) or C (configurable); after 15 s it picks baseline. It enrols the board and shows the stored helper data and the 128-bit key, then checks that this key is the one inside the FPGA. | about 30 s |

Each launcher first:
1. Finds Vivado. It looks at `VIVADO_BIN`, then `XILINX_VIVADO`, then `PATH`, then the standard install folders on drives C:, D: and E:. It prefers 2024.2 and otherwise takes the newest version it finds (see [2.5](#25-other-vivado-versions)).
2. Finds Python 3.
3. Checks for `build\top_soc.bit` and `build\top_soc.ltx`. **If either is missing, it builds them** with `scripts\build_soc.tcl`, which takes 15–20 minutes and creates the Vivado project on a fresh system. If `sw\firmware.mem` is missing, it assembles the firmware first.

The bitstream is built only once; later runs reuse it. Delete `build\top_soc.bit` to force a rebuild.

**Logs and results:**
- Vivado logs: `build\logs\` (`build_soc_<time>.log`, `demo_<mode>_<time>.log`, `key_<mode>_<time>.log`).
- Results of each run: `build\runs\<time>_<mode>\` (demo log, helper data, key record and key report).

The results shipped in `data\hw_soc\` are never overwritten. The launchers point the scripts at `build\runs` through the `PUF_OUT_DIR` environment variable.

**How `Show_Key.bat` shows the key.** The FPGA has no command that outputs the key, and that does not change here. The host chose the enrolment secret (the random BCH messages) and the helper data is public. From these, `scripts\show_key.py` recomputes the enrolled PUF response `w` and the key `K = KDF(w)` with the golden model. It then proves that this is the key inside the chip:
- the KCV the FPGA wrote into the helper data equals `SipHash(K, "KCV")`
- the FPGA's MAC tags for 4 random challenges equal `SipHash(K, challenge)`, both before and after a SoC reset
- the other two RO arrays cannot rebuild the key

On the baseline PUF, an unstable response bit can read differently during enrolment. Re-enrolling then gives a different key. We saw this on 20 Nov 2026: two runs gave KCV `79d398eb` and `995cb7b3`, and their responses differed in one bit. The error correction guarantees only that every reconstruction reproduces the key that was enrolled.

If the result is FAIL, the launcher prints the likely cause: board not found on JTAG, firmware not answering, or SW3 ON (enrolment locked).

---

## 1. What is in this folder

```
RO_PUF_Key_Generator/
├── README.md               this guide
├── PROGRESS_REPORT.md      project progress report (status of every phase and objective)
├── requirements.txt        Python packages
├── Run_Baseline_Demo.bat   double-click: build if needed + board demo, baseline RO-PUF
├── Run_Configurable_Demo.bat  double-click: the same with the configurable RO-PUF
├── Show_Key.bat            double-click: enrol, show the key and prove it is the key in the FPGA
├── report/                 final report: VL401_GXX_P04.tex / .pdf and its figures
├── docs/                   design documents per phase, live-demo guide, glossary, figures/, reports/
├── rtl/                    Verilog source
│   ├── gf/                   GF(2^4) multiplier / inverse (ESPRESSO-generated and XOR form)
│   ├── ecc/                  BCH syndrome, Chien ROM, hand-HLS decoders, BCH encoder, repetition codec
│   ├── crypto/               SipHash-2-4 core
│   ├── fe/                   fuzzy extractor + sequencer + one-time lock
│   ├── puf/                  ring-oscillator cell, arrays, measurement unit, heater; sim/ = RO model
│   ├── soc/                  RV32I core, RAM, SoC
│   └── top/                  top_soc (secure SoC) and top_char (PUF characterisation)
├── tb/                     self-checking testbenches + SystemVerilog assertions (fe_sva.sv)
├── sw/                     rvasm.py (RV32I assembler), firmware.S (+ assembled .mem), tests/
├── model/                  Python golden model, BDD package, CTL model checker, QM, analysis; tests/, vectors/
├── constraints/            board pins, generated RO placement, locked RO routes
├── scripts/                run_sims.py, run_analysis.py, show_key.py, build and synthesis Tcl, ESPRESSO/BDD flows;
│                             hw/ = board scripts, win/ = shared part of the .bat launchers
├── data/                   all PUF measurements from the board, demo logs and helper data
├── prebuilt/               the bitstreams used for the reported results (+ reference routed design)
└── tools/                  ESPRESSO: prebuilt Windows binary, patched source, Windows patch
```

**Not included:**
- the Vivado project folder, which the build scripts create automatically
- intermediate build files
- the teammate's earlier 16-RO prototype (`RO/`), which is not used by the final design

---

## 2. What to install first

### 2.1 Required

| Tool | Version used | Needed for | Notes |
|------|--------------|------------|-------|
| **AMD/Xilinx Vivado** | **2024.2** (64-bit) | simulation (xsim), synthesis, bitstreams, programming the board | The free *Vivado ML Standard* edition supports the Zynq-7010. Install it with "Zynq-7000" device support. It includes the simulator, `hw_server` and the JTAG cable drivers. Other versions are handled automatically; see [2.5](#25-other-vivado-versions) |
| **Python** | **3.8.10** (3.8 or newer) | golden model, all analyses, assembler, test runners | Any CPython ≥ 3.8 |
| **NumPy** | 1.24.4 | golden model, analysis | `pip install -r requirements.txt` |
| **Matplotlib** | 3.7.5 | plots | `pip install -r requirements.txt` |

Install the Python packages:

```bash
python -m pip install -r requirements.txt
```

### 2.2 Optional

| Tool | Version used | Needed for |
|------|--------------|------------|
| **LaTeX**: MiKTeX or TeX Live | MiKTeX 25.12 (pdfTeX 4.23) | compiling the report. Packages used: `lmodern geometry amsmath amssymb graphicx booktabs tabularx multirow array xcolor enumitem listings caption float fancyhdr tikz hyperref` (MiKTeX installs missing ones automatically) |
| **MinGW gcc** (Windows) or gcc + make (Linux) | MinGW.org GCC 6.3.0 | **only** for rebuilding ESPRESSO. A prebuilt Windows binary is included in `tools/espresso/` |
| **Digilent Zybo Z7-10** + micro-USB cable | – | everything in Section 8 (the board) |

### 2.3 Operating system

Everything was developed and tested on **Windows 11**.
- The Python scripts, the Tcl scripts and `run_sims.py` are written to work on Linux too: `run_sims.py` calls `xvlog` instead of `xvlog.bat` there.
- On Linux, ESPRESSO must be built from `tools/espresso-src` (Section 9).

### 2.4 Make Vivado reachable

The guide writes `vivado` for the Vivado command. Either:
- run `C:\Xilinx\Vivado\2024.2\settings64.bat` once in your Command Prompt (it puts `vivado`, `xvlog`, … on the PATH), **or**
- write the full path: `C:\Xilinx\Vivado\2024.2\bin\vivado.bat`.

`scripts/run_sims.py` finds the simulator by itself: it checks `VIVADO_BIN`, `XILINX_VIVADO`, then `PATH`, and finally the standard install folders. Like the launchers, it prefers 2024.2 and otherwise takes the newest version. If Vivado is elsewhere, set `VIVADO_BIN` to its `bin` folder.


### 2.5 Other Vivado versions

The project was developed, built and measured with **Vivado 2024.2**, and only that version was tested. The scripts also work with other versions:

- **Finding Vivado.** The launchers and `run_sims.py` search the standard install folders: `<drive>:\Xilinx\Vivado\<ver>`, `<drive>:\Xilinx\<ver>\Vivado` and `<drive>:\AMDDesignTools\<ver>\Vivado`. They use 2024.2 if it is installed, otherwise the newest version, and print a note when it is not 2024.2. To force one version, set `VIVADO_BIN` to its `bin` folder.
- **VIO debug core.** `scripts/vivado_compat.tcl` creates the core from whichever VIO version the installed Vivado provides. An existing core locked to another version is upgraded.
- **Vivado project.** If `RTL_Project_Vivado` was saved by a different Vivado version, it is left untouched: an older Vivado cannot open a newer project, and a newer one would upgrade it in place. The build then uses a separate project, `RTL_Project_Vivado_v<version>` (for example `RTL_Project_Vivado_v2025_1`).
- **What changes with another version.** The RO placement and routes are locked, but the placer puts the rest of the design elsewhere. Like any rebuild, this changes some PUF response bits. The demo still works because it enrols and reconstructs on the same bitstream. The exact numbers in the report (resource counts, slack, measured responses) come from the 2024.2 build. Other versions will give slightly different values, and timing at 125 MHz could fail by a small margin.
- **Prebuilt bitstreams.** The files in `prebuilt/` can be programmed with any recent Vivado Hardware Manager. That is the way to reproduce the reported board results exactly.

---

## 3. Quick check of the installation

```bash
python -m unittest discover -s model/tests -t .
```

**Expected:** `Ran 35 tests ... OK`. These are the golden-model tests (including exhaustive BCH and the official SipHash vectors), the BDD package tests and the CTL model-checker tests.

---

## 4. Re-run all analyses (Python)

```bash
python scripts/run_analysis.py          # about 1-2 minutes
python scripts/run_analysis.py --list   # list of steps
```

| Step | What it does | Main output |
|------|--------------|-------------|
| `tests` | 35 unit tests | – |
| `vectors` | regenerates all test vectors (deterministic) | `model/vectors/*.mem`, ESPRESSO `.pla` files |
| `curves` | key-failure probability vs. bit-error rate | `docs/figures/key_failure_vs_ber.png` |
| `simboards` | analysis flow on simulated boards | `docs/figures/sim_characterisation.png` |
| `espresso` | ESPRESSO **exact** → Verilog, exhaustive check | `rtl/gf/gf16_mul_sop.v`, `gf16_inv_sop.v` |
| `qm` | our Quine–McCluskey + exact cover | `docs/reports/qm_results.txt` |
| `bdd` | BDD equivalence proof + all 40,320 variable orders (~1 min) | `docs/figures/bdd_ordering.png`, `docs/reports/phase3_bdd.txt` |
| `ctl` | CTL proofs and mutant counterexamples | `docs/reports/ctl_proofs.txt` |
| `hardware` | analysis of the board measurements in `data/` | `docs/figures/hw_*.png`, `docs/reports/hw_characterisation.txt` |

**Expected:** every step reports `OK`. All regenerated files are identical to the ones supplied.

> The ESPRESSO step uses exact mode on purpose. Without `--exact`, `scripts/espresso_flow.py` writes the heuristic version of the GF Verilog, which is functionally identical but is *not* the logic in the reported bitstream.

Single analyses can also be run directly, for example `python -m model.fe_fsm_model` or `python -m model.hw_analysis`.

---

## 5. Re-run all simulations (Vivado xsim)

```bash
python scripts/run_sims.py --quick   # 11 tests, about 4 minutes
python scripts/run_sims.py           # all 12 tests, about 8 minutes (adds the slow RO-model test)
python scripts/run_sims.py soc gf    # only some tests;  --list shows all names
```

Each test runs in `build/sim/<name>/`, where the log is kept as `run.log`. The runner copies the test vectors there, assembles any firmware with `sw/rvasm.py`, compiles and runs. A test passes only if its PASS line appears and **no assertion failed**.

| Test | Testbench | Expected result |
|------|-----------|-----------------|
| `gf` | `tb_gf16_sop` | multiplier 256/256 (SOP and XOR forms), inverse 16/16 |
| `bch_dec` | `tb_bch_dec` | 4 decoders (1/2 multipliers × SOP/XOR) on 17,488 vectors, 0 mismatches. Latencies 34 and 18 cycles |
| `siphash` | `tb_siphash24` | 278/278 vectors, latency 3 × blocks + 5 cycles |
| `ecc_blocks` | `tb_ecc_blocks` | BCH encoder 128/128, repetition codec on every input |
| `fe_r1`, `fe_r3`, `fe_r5` | `tb_fuzzy_extractor` + 12 SVA assertions | 24 life cycles each, bit-exact with the golden model, 0 assertion failures |
| `fsm_trace` | `tb_fuzzy_extractor -d FSM_TRACE` + CTL model | RTL conformance: 3,527 cycles, 76 distinct transitions, **0 not in the model** |
| `rv32_core` | `tb_rv32_core` + `sw/tests/core_selftest.S` | RV32I self-test passed, 209 instructions, CPI 5.13 |
| `bch_sw` | `tb_bch_sw` + `sw/tests/bch_sw.S` | software BCH decoder: 64 decodes, 0 mismatches, **4,542 cycles per decode** |
| `soc` | `tb_soc` (CPU + firmware + fuzzy extractor + RO model) | full demo scenario in simulation: enrol, lock, reconstruct, authenticate, other device rejected |
| `puf_measure` *(slow, ~3.5 min)* | `tb_puf_measure` (behavioural RO model) | correct bits on all separated pairs, SELECT optimal on 128/128 pairs |

> Run Section 4 **before** Section 5 if you want `docs/reports/ctl_proofs.txt` to include the RTL-conformance line. The `fsm_trace` test rewrites that report with it.

**Code coverage (optional):** add `-cc_type sbct -cc_db cov -cc_dir ./cov` to the `xelab` options, then run `xcrg -cc_dir ./cov -cc_db cov -report_dir rep -report_format html`. Our result for `fuzzy_extractor` was statement / branch / condition = 95.4 / 88.6 / 100%.

---

## 6. Re-run the synthesis studies

Out-of-context synthesis on the Zynq-7010. Each takes a few minutes, writes its reports to `docs/reports/<name>/` and prints a summary table.

```bash
vivado -mode batch -nojournal -nolog -source scripts/synth_gf.tcl            # GF(2^4) blocks
vivado -mode batch -nojournal -nolog -source scripts/synth_bch.tcl           # hand-HLS design points
vivado -mode batch -nojournal -nolog -source scripts/synth_siphash.tcl       # SipHash core
vivado -mode batch -nojournal -nolog -source scripts/synth_fe.tcl            # fuzzy extractor, r = 1/3/5
vivado -mode batch -nojournal -nolog -source scripts/synth_fsm_encoding.tcl  # state encodings
```

| Script | Expected summary |
|--------|------------------|
| `synth_gf` | SOP multiplier 16 LUTs; XOR (Mastrovito) multiplier 8 LUTs; inverse 4 LUTs |
| `synth_bch` (hierarchical) | 1 multiplier: 110 LUTs, 62 FFs, 34 cycles. 2 multipliers: 125 LUTs, 57 FFs, 18 cycles (ESPRESSO multiplier) |
| `synth_siphash` | 659 LUTs, 397 FFs, WNS +0.786 ns at 125 MHz |
| `synth_fe` | r = 1: 1,519 LUTs; r = 3: 1,306; r = 5: 1,233; all WNS +0.786 ns |
| `synth_fsm_encoding` | binary 1,346 / one-hot 1,520 / sequential 1,320 / Gray 1,327 / Johnson 1,397 LUTs, all 138.6 MHz |

**RTL lint:** `synth_design -top soc -part xc7z010clg400-1 -lint` on the SoC sources reports 0 errors and 5 intentional messages (listed in the report, Section 6.1).

---

## 7. Build the bitstreams

> ⚠️ **Read this first: a PUF is tied to its bitstream.**
> - The RO placement (`constraints/puf_placement.xdc`) and the routes inside every RO (`constraints/puf_routes.xdc`) are locked, so every build has identical RO loops.
> - Even so, the logic *around* the ROs changes between builds, and a rebuilt bitstream flips about **7–10% of the PUF response bits**.
> - So helper data enrolled with one bitstream only works with that bitstream.
>
> The reported results and the helper data in `data/hw_soc/` belong to the bitstreams in **`prebuilt/`**. To re-run the board demo with our numbers, use the prebuilt files (Section 8). Rebuilding is fine, but then enrol again on the new bitstream.

```bash
# 1. assemble the firmware (already done: sw/firmware.mem is included)
python sw/rvasm.py sw/firmware.S sw/firmware.mem --list sw/firmware.lst

# 2. secure SoC bitstream (about 10 minutes)
vivado -mode batch -nojournal -nolog -source scripts/build_soc.tcl
#    -> build/top_soc.bit, build/top_soc.ltx, reports in docs/reports/soc/
#    expected last line similar to: BUILD_OK top_soc LUTs=9156 FFs=9365 WNS=0.055

# 3. PUF characterisation bitstream (about 7 minutes)
vivado -mode batch -nojournal -nolog -source scripts/build_char.tcl
#    -> build/top_char.bit, build/top_char.ltx, reports in docs/reports/char/
```

**What the build scripts do:**
- On a fresh system they **create** the Vivado project `RTL_Project_Vivado/` with part `xc7z010clg400-1`.
- They add the sources from this folder by reference, create and configure the VIO IP core, then run synthesis, implementation and bitstream generation.
- Both use the same project, so build them one after the other, not in parallel. `WNS` must be ≥ 0.

**Optional: check that the RO routes really are the locked ones** in a routed design. Expect `2304 identical, 0 different`:

```bash
vivado -mode batch -nojournal -nolog -source scripts/check_puf_routes.tcl -tclargs RTL_Project_Vivado/RTL_Project_Vivado.runs/impl_1/top_soc_routed.dcp
```

`scripts/export_puf_routes.tcl` regenerates `constraints/puf_routes.xdc` from a routed design. The reference design it was made from is `prebuilt/top_soc_reference_routed.dcp`.

---

## 8. Run on the board: demo and PUF measurements

**Set up the board:**
1. Connect the Zybo Z7-10's **PROG/UART** micro-USB port to the PC.
2. Power the board on.
3. Set slide switches **SW0–SW3 all OFF**. SW3 ON emulates a burned one-time fuse, which blocks enrolment.

The scripts program the FPGA over JTAG and talk to it through a VIO core. No UART terminal is needed.

The board scripts load `build/<name>.bit`. To use the **prebuilt** bitstreams, copy them there first:

Command Prompt:

```bat
mkdir build
copy prebuilt\top_soc.*  build\
copy prebuilt\top_char.* build\
```

Git Bash / Linux:

```bash
mkdir -p build && cp prebuilt/top_soc.* prebuilt/top_char.* build/
```

### 8.1 Challenge–response demo (secure SoC)

```bash
vivado -mode batch -nojournal -nolog -source scripts/hw/soc_demo.tcl -tclargs base 100   # baseline RO-PUF
vivado -mode batch -nojournal -nolog -source scripts/hw/soc_demo.tcl -tclargs cfg 100    # configurable RO-PUF
```

**Expected** (also logged to `data/hw_soc/demo_<mode>.txt`):

```
ENROL device 0: ... locked=1 ...             ENROL again: ... -> REFUSED (locked)
AUTH device 0: 4/4 unused challenges answered correctly -> AUTHENTICATED
IMPOSTOR device 1: ... AUTH REJECTED          IMPOSTOR device 2: ... AUTH REJECTED
RELIABILITY: 100/100 reconstructions gave a valid key, 100/100 answered the reference challenge correctly
```

The same demos run with a double-click: `Run_Baseline_Demo.bat`, `Run_Configurable_Demo.bat` and `Show_Key.bat` (see [Quick start](#quick-start-on-windows-double-click-launchers)).

`docs/Live_Demo_Guide.md` explains every step and an interactive, step-by-step version for a live demonstration.

### 8.2 PUF characterisation (raw responses, warm test)

> ⚠️ These commands **overwrite** `data/hw_base`, `data/hw_cfg` and `data/hw_counts`. Copy the folders first if you want to keep the supplied measurements.

```bash
vivado -mode batch -nojournal -nolog -source scripts/hw/char_smoke.tcl                    # quick look
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs counts   # RO counts
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs room 100 # 100 reads + SELECT
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs warm 100 # heater on until the die temperature settles (a few minutes)
python -m model.hw_analysis                                                                # figures + report
```

**Expected on our board** (final build, `docs/reports/hw_characterisation.txt`):

| | Baseline | Configurable RO |
|---|---|---|
| Bit-error rate, room | 0.7–1.9% | 0.00% |
| Bit-error rate, warm (+7 °C) | 0.2–3.3% | 0.00% |
| Key failures with rep-3 + BCH | 0 / 600 reads | 0 / 600 reads |

**Other board scripts in `scripts/hw/`:**

| Script | Purpose |
|--------|---------|
| `char_cfg_check.tcl` | checks the RO-configuration load path |
| `char_stability.tcl` | the rebuild-stability test |
| `soc_debug.tcl` | mailbox diagnostics |

**A different board:** the same bitstream on another Zybo Z7-10 gives that chip's own PUF. Running `char_collect.tcl` on it and pooling with our data measures true chip-to-chip uniqueness, which we could not measure with a single board.

---

## 9. Rebuild ESPRESSO (optional)

A prebuilt Windows binary is in `tools/espresso/espresso.exe`. The scripts find it automatically. To rebuild it, use the patched source in `tools/espresso-src/`; the patch is also kept separately as `tools/espresso-windows.patch`.

```bash
# Windows (MinGW gcc)
gcc -O2 -w -o tools/espresso/espresso.exe tools/espresso-src/espresso-src/*.c

# Linux / macOS
make -C tools/espresso-src/espresso-src        # binary: tools/espresso-src/bin/espresso
export ESPRESSO=$PWD/tools/espresso-src/bin/espresso
```

The Windows patch makes `getrusage()`/`setrlimit()` optional, so the source compiles with MinGW. See `docs/ESPRESSO_Setup.md`.

---

## 10. Compile the report

```bash
cd report
pdflatex VL401_GXX_P04.tex
pdflatex VL401_GXX_P04.tex      # second run for the table of contents and references
```

Before submitting:
- fill in the group number, name and roll numbers at the top of the `.tex` file
- rename the files to `VL401_G<no>_P04.tex/.pdf`

---

## 11. Summary of expected results

| Area | Result |
|------|--------|
| Golden model | 35 unit tests pass. BCH tested exhaustively (128 codewords × 121 error patterns) |
| ESPRESSO | multiplier 129 terms / 781 literals (exact, multi-output). Our QM matches ESPRESSO on all 8 single outputs |
| BDD | ESPRESSO = truth table = Mastrovito (same nodes). Best variable order 82 nodes (1,152 of 40,320 orders) |
| Hand HLS | BCH decoder 34 cycles (1 multiplier, 110 LUTs) / 18 cycles (2 multipliers, 125 LUTs) |
| HW vs SW | 4,542 cycles in software vs 18 in hardware (about 252×) |
| Simulation | all 12 testbenches pass. 12 assertions, 0 failures |
| CTL | 7 properties hold. Liveness without fairness fails (as expected). 3 mutants caught. RTL conformance 0 mismatches |
| FPGA | SoC 9,156 LUTs (52%), 125 MHz, WNS +0.055 ns |
| PUF on the board | uniqueness 48.9% (pooled). Baseline BER 0.2–3.3%. Configurable RO 0 errors in 1,800 reads |
| Demo | enrolled device authenticated 4/4. Other devices rejected. 100/100 reconstructions |

The full results with their sources are in `report/VL401_GXX_P04.pdf` and `PROGRESS_REPORT.md`.

---

### 11.1 Verification of this package (20 November 2026)

This folder was tested by following this guide on the development PC, starting with no Vivado project and no build outputs, then with the Zybo Z7-10 connected (all switches off). Die temperature 28–33 °C.

| Check | Result |
|-------|--------|
| `python scripts/run_analysis.py` | 9/9 steps OK. All regenerated vectors, ESPRESSO Verilog and reports byte-identical to the supplied ones |
| `python scripts/run_sims.py` | 12/12 testbenches pass, including the slow RO-model test |
| `scripts/build_soc.tcl` with no existing project | project created automatically. `BUILD_OK top_soc LUTs=9156 FFs=9365 WNS=0.054` |
| `scripts/check_puf_routes.tcl` on that build | 2,304 / 2,304 RO nets identical to the locked routes |
| `char_smoke.tcl`, `char_cfg_check.tcl` (prebuilt `top_char`) | PUF reads as before. Configuration load path: 0 bits difference, 23 bits for the swapped control |
| Stored configurations `data/hw_cfg/arr*/cfg.txt` reloaded on the board | responses identical (**0 bits**, all 3 arrays, 5 reads each) to those recorded on 15 November at 42 °C |
| `soc_demo.tcl base 100` and `cfg 100` (prebuilt `top_soc`) | both: second enrolment refused, device 0 authenticated 4/4, devices 1 and 2 rejected, 100/100 reconstructions. Baseline key-check value identical to the 15 November run (same key from the PUF) |
| `soc_demo.tcl base 50` on the freshly built bitstream | authenticated 4/4, devices 1 and 2 rejected, 50/50 reconstructions |

One problem was found and fixed during this test. `scripts/hw/char_cfg_check.tcl` still read the two configuration halves by probe *name*, which gave a false failure. It now reads them by VIO port, like all other scripts. The supplied measurements were collected with the port-based path and are unaffected, as the reload test above confirms.

**Launchers (same day).** With no `build\` folder, `Run_Baseline_Demo.bat` built the bitstream by itself (`BUILD_OK top_soc LUTs=9156 FFs=9365 WNS=0.054`) and then passed all 5 checks:
- second enrolment refused
- device 0 authenticated
- devices 1 and 2 rejected
- 100/100 reconstructions

`Show_Key.bat` then passed all 11 checks: the key recomputed on the host matched the FPGA's KCV and 4/4 MAC tags, before and after a reset. In the main project folder, `Run_Configurable_Demo.bat` and both `Show_Key.bat` modes also passed.

One result worth noting from the demo: on device 1 the BCH decoder reported success (`ecc_ok=1`), but the KCV check rejected the key (`kcv_ok=0`). The noise had pushed a block onto a wrong codeword, and the key-check value caught it, which is exactly what it is for.

---

## 12. Troubleshooting

| Problem | Fix |
|---------|-----|
| `Vivado not found` from `run_sims.py` | Set `VIVADO_BIN` to Vivado's `bin` folder, e.g. `set VIVADO_BIN=C:\Xilinx\Vivado\2024.2\bin` |
| `xelab` error about `REP=1` on Windows | Use `run_sims.py`, which passes generics through an options file; a Windows batch file splits arguments at `=` |
| Build fails creating the VIO IP | `scripts/vivado_compat.tcl` picks the VIO version of your Vivado. If it still fails, check that the Vivado installation includes Zynq-7000 support. |
| `COMPAT: ... was saved by Vivado ...` in the build log | Not an error: the project was made with another Vivado version, so a separate `RTL_Project_Vivado_v<version>` project is used (Section 2.5) |
| `UnicodeDecodeError` in a Python script | Set `PYTHONUTF8=1` (Python on Windows otherwise uses the ANSI code page) |
| The board is not found | Use the PROG/UART micro-USB port, power the board on, close other Vivado hardware sessions. Cable drivers: `C:\Xilinx\Vivado\2024.2\data\xicom\cable_drivers` |
| ENROL refused right after reset | SW3 is ON (emulated fuse). Switch it off and reset |
| `key_valid=0` for device 0 with old helper data | The bitstream was rebuilt (the PUF changed). Enrol again, or use the prebuilt bitstream |
| `no VIO probe ...` | The `.ltx` file is not from the same build as the `.bit` |
| `ERROR: [Chipscope 16-302] Could not generate core for dbg_hub ... temporary directory path ... exceeds 146 characters` | The folder sits in too deep a path, for example `Downloads\...-main\...-main\`. The `.bat` launchers handle this: for paths over 40 characters they build through a temporary drive letter (`subst`). When running `build_soc.tcl` by hand, move the folder to a short path such as `C:\RO_PUF` |

---

## 13. Where to read more

| Document | Contents |
|----------|----------|
| `report/VL401_GXX_P04.pdf` | the course report |
| `PROGRESS_REPORT.md` | status of all phases and objectives, with results |
| `docs/Implementation_Plan.md` | objectives, architecture, plan |
| `docs/Phase4_BCH_HLS.md` | hand HLS of the BCH decoder |
| `docs/Phase5_Fuzzy_Extractor.md` | SipHash, fuzzy extractor, sequencer and lock |
| `docs/Phase2_8_9_PUF_Hardware.md` | RO-PUF hardware, placement and route locking, characterisation, research enhancement |
| `docs/Phase6_SoC.md` | RV32I core, SoC, firmware, board demo |
| `docs/Phase7_CTL_Proofs.md` | CTL model checking |
| `docs/Live_Demo_Guide.md` | step-by-step live demo |
| `docs/ESPRESSO_Setup.md`, `docs/Glossary.md`, `model/README.md` | ESPRESSO setup, terms explained, golden model |
