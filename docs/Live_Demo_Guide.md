# Live Demo Guide: RO-PUF Key Generator on the Zybo Z7-10

This guide takes you from a board in its box to a complete live demonstration. The demo shows that:

1. **the board enrols a device-unique key** from its ring-oscillator PUF,
2. **the same device reconstructs the same key** after a reset and proves it (challenge–response),
3. **a different device is rejected**, even with the correct helper data,
4. **enrolment is one-time**: a second enrolment is refused, and the lock can survive a reset,
5. **the key is never visible**: only helper data, status and MAC tags leave the chip.

**Time needed:**
- About 5 minutes for the automated demo (Part C).
- About 15 minutes for the step-by-step demo (Part D).
- About 10 minutes extra if the bitstream has to be built first (Part B).

---

## Contents

- [Part A: Equipment and one-time setup](#part-a-equipment-and-one-time-setup)
- [Part B: Build the bitstream (only if `build/top_soc.bit` is missing)](#part-b-build-the-bitstream-only-if-buildtop_socbit-is-missing)
- [Part C: Automated demo (one command)](#part-c-automated-demo-one-command)
- [Part D: Step-by-step interactive demo](#part-d-step-by-step-interactive-demo)
- [Part E: Showing the one-time lock with the board switches](#part-e-showing-the-one-time-lock-with-the-board-switches)
- [Part F: Optional: show the PUF itself (characterisation build)](#part-f-optional-show-the-puf-itself-characterisation-build)
- [Part G: Reading the status word, LEDs and outputs](#part-g-reading-the-status-word-leds-and-outputs)
- [Part H: Troubleshooting](#part-h-troubleshooting)
- [Part I: What to say during the demo (talking points)](#part-i-what-to-say-during-the-demo-talking-points)

---

## Part A: Equipment and one-time setup

### A.1 What you need

| Item | Notes |
|------|-------|
| Digilent **Zybo Z7-10** board | Zynq-7010, `xc7z010clg400-1` |
| Micro-USB cable | Into the **PROG/UART** micro-USB port. It carries JTAG and powers the board |
| PC with **Vivado 2024.2** | Installed at `C:\Xilinx\Vivado\2024.2`. Vivado includes the JTAG cable drivers and `hw_server` |
| Python 3.8+ with numpy | Only needed to assemble the firmware or analyse data |
| This repository | e.g. `D:\Sem-5\RTL_Project` |

No UART terminal, SD card or extra hardware is needed. All communication runs over JTAG through Vivado.

### A.2 Board settings before power-on

1. **Power source:** set the power-select jumper to USB, or connect the 5 V supply, then switch the board on.
2. **Boot-mode jumper:** set to **JTAG** (recommended). The demo also works in the other modes, because it programs the FPGA part directly over JTAG.
3. **Slide switches SW0–SW3: all OFF** (down, towards the board edge).

| Switch | Meaning in this design |
|--------|------------------------|
| SW1:SW0 | Device select (RO array 0..2) when a command passes device `0xFF` |
| SW2 | Unused |
| SW3 | **Emulated one-time fuse** (`boot_locked`). ON = the chip counts as already enrolled, and enrolment is refused from reset |

4. **Buttons:** BTN0 = reset of the SoC (not needed by the scripts).

### A.3 Check that the PC sees the board

Open a terminal (Git Bash or Command Prompt) in the project folder and run:

```bat
C:\Xilinx\Vivado\2024.2\bin\vivado.bat -mode tcl
```

In the `Vivado%` prompt:

```tcl
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
get_hw_devices                 ;# expect: arm_dap_0 xc7z010_1
refresh_hw_sysmon [lindex [get_hw_sysmons] 0]
get_property TEMPERATURE [lindex [get_hw_sysmons] 0]   ;# die temperature, e.g. 43
close_hw_target
exit
```

If `xc7z010_1` is listed, the setup is complete.

> **Tip:** to type just `vivado`, first run `C:\Xilinx\Vivado\2024.2\settings64.bat` in Command Prompt. The rest of this guide writes `vivado` for short.

---

## Part B: Build the bitstream (only if `build/top_soc.bit` is missing)

Bitstreams are **not** stored in git (`build/` is ignored). On the demo PC they normally already exist. Check with:

```bash
ls build/top_soc.bit build/top_soc.ltx
```

If they are missing, build them. All commands run from the project root.

```bash
# 1. assemble the RISC-V firmware (writes sw/firmware.mem, which goes into the FPGA RAM)
python sw/rvasm.py sw/firmware.S sw/firmware.mem --list sw/firmware.lst

# 2. synthesise, implement and generate the bitstream (about 10 minutes)
vivado -mode batch -nojournal -nolog -source scripts/build_soc.tcl
```

The last line printed must be similar to:

```
BUILD_OK top_soc LUTs=9156 FFs=9365 WNS=0.055
```

`WNS` must be ≥ 0, meaning timing is met at 125 MHz. The build uses the locked RO placement (`constraints/puf_placement.xdc`) and the locked RO routes (`constraints/puf_routes.xdc`).

> ⚠️ **Important:** a new build is a slightly different PUF. Nearby logic changes, and about 7–10% of the response bits move. **Helper data enrolled on one bitstream only works with that bitstream.** Never rebuild between enrolment and authentication in a demo. To change only the firmware of an enrolled design, use Vivado's `updatemem` instead of a rebuild.

---

## Part C: Automated demo (one command)

This runs the complete story in about 50 seconds and writes a log file.

```bash
vivado -mode batch -nojournal -nolog -source scripts/hw/soc_demo.tcl -tclargs base 100
```

- `base` = the baseline RO-PUF. Use `cfg` for the configurable-RO PUF (the research enhancement).
- `100` = the number of reconstructions in the reliability test.

### C.0 Even simpler: double-click launchers (Windows)

Three `.bat` files in the top folder run the board demos with no typing. Connect the board (PROG/UART USB port, powered on, **SW0–SW3 all OFF**), close any open Vivado Hardware Manager, and double-click one:

| File | What it does | Time |
|---|---|---|
| `Run_Baseline_Demo.bat` | Full demo with the **baseline** RO-PUF: enrolment, lock, authentication after a reset, two impostor devices, 100 reconstructions. Ends with a PASS/FAIL list. | about 1 min |
| `Run_Configurable_Demo.bat` | The same demo with the **configurable** RO-PUF (the research enhancement). | about 1 min |
| `Show_Key.bat` | Asks B (baseline) or C (configurable); after 15 s it picks baseline. It enrols the board and shows the stored helper data and the 128-bit key, then checks that this key is the one inside the FPGA. | about 30 s |

Each launcher first:
1. Finds Vivado. It looks at `VIVADO_BIN`, then `XILINX_VIVADO`, then `PATH`, then `C:\Xilinx\Vivado\2024.2\bin`.
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

### C.1 Expected output (real output from our board)

```
DEMO mode base, die temperature 43.4 C
DEMO LINK: echo of 24 words OK; PING 52563332 version 00010000
DEMO ENROL device 0: key_valid=0 locked=1 cmd_err=0 ecc_ok=0 kcv_ok=0
DEMO   helper data (offset, kcv, configuration): 5b01ea08 1e298868 015ef936 00000000 79d398eb 00000000 ...
DEMO ENROL again: key_valid=0 locked=1 cmd_err=1 ecc_ok=0 kcv_ok=0 -> REFUSED (locked)
DEMO RECONSTRUCT device 0 (factory): key_valid=1 locked=1 cmd_err=0 ecc_ok=1 kcv_ok=1
DEMO   recorded 8 challenge-response pairs
DEMO FIELD: SoC reset (switches 0); key_valid after reset = 0
DEMO RECONSTRUCT device 0 with restored helper data: key_valid=1 locked=0 cmd_err=0 ecc_ok=1 kcv_ok=1
DEMO AUTH device 0: 4/4 unused challenges answered correctly -> AUTHENTICATED
DEMO IMPOSTOR device 1: reconstruct key_valid=0 locked=0 cmd_err=0 ecc_ok=0 kcv_ok=0; AUTH REJECTED
DEMO IMPOSTOR device 2: reconstruct key_valid=0 locked=0 cmd_err=0 ecc_ok=0 kcv_ok=0; AUTH REJECTED
DEMO RELIABILITY: 100/100 reconstructions gave a valid key, 100/100 answered the reference challenge correctly; die temperature 43.2 C
```

The helper data and tags differ in every run, because the enrolment messages and challenges are random.

### C.2 What each line proves

| Line | What happened inside | What it proves |
|------|----------------------|----------------|
| `LINK ... PING 52563332` | The host wrote 24 words through the JTAG mailbox. The firmware echoed them and answered PING with `'RV32'` | The PC ↔ RISC-V firmware link works |
| `ENROL device 0` | Firmware → key generator: measure the 128-bit PUF response of RO array 0, encode random BCH messages, compute helper = response ⊕ codeword, derive key K, store the key-check value, **wipe K**, set the lock | Enrolment produces public helper data. `locked=1` = the one-time lock is set |
| `helper data` | 17 words: offset (4), KCV (1), RO configuration (12, all zero in `base` mode) | Only public data leaves the chip, never the key |
| `ENROL again ... REFUSED` | ENROL is rejected while `locked=1` (`cmd_err=1`) | **One-time enrolment lock** |
| `RECONSTRUCT (factory)` | Measure the PUF again (noisy), majority vote, BCH decode, rebuild the exact response, derive K, compare the KCV → `key_valid=1` | The noisy PUF is corrected into the same key (`ecc_ok=1`, `kcv_ok=1`) |
| `recorded 8 challenge-response pairs` | The host (verifier) sends 8 random 64-bit challenges and stores the returned 64-bit SipHash tags | The verifier's database at the "factory" |
| `FIELD: SoC reset` | The SoC is reset: RAM, key and lock are cleared (SW3 off) | The device "leaves the factory" and loses everything volatile |
| `RECONSTRUCT ... restored helper data` | The host sends the stored helper data back (LOAD_HELPER), and the chip reconstructs | The key is rebuilt from the silicon alone, plus public helper data |
| `AUTH device 0: 4/4 ... AUTHENTICATED` | 4 challenges *not used before*: the chip's tags equal the recorded ones | **Challenge–response authentication works** |
| `IMPOSTOR device 1/2 ... REJECTED` | Same helper data, but measuring RO array 1 or 2 (other silicon). BCH or KCV fails, `key_valid=0`, AUTH refused | **A different device cannot produce the key** |
| `RELIABILITY 100/100` | 100 reconstructions, each checked with a recorded challenge | The key is stable (failure rate after ECC: 0/100) |

The log is saved in `data/hw_soc/demo_base.txt` (or `demo_cfg.txt`), and the helper data in `data/hw_soc/helper_base.txt`.

### C.3 Same demo with the research enhancement

```bash
vivado -mode batch -nojournal -nolog -source scripts/hw/soc_demo.tcl -tclargs cfg 100
```

The difference is in ENROL: the firmware first runs **SELECT**, which measures all 8 RO configurations of every pair and keeps the most stable one. The 384-bit choice is the last 12 words of the helper data (non-zero now). Everything else behaves the same.

---

## Part D: Step-by-step interactive demo

Use this when the examiner wants to see each step, or to try their own challenges. You type commands into Vivado's Tcl prompt.

### D.1 Start, program the board and connect

```bat
cd D:/Sem-5/RTL_Project
vivado -mode tcl
```

```tcl
cd D:/Sem-5/RTL_Project
source scripts/hw/puf_host.tcl          ;# JTAG/VIO helpers (hw_connect, probe, temperature ...)
source scripts/hw/soc_host.tcl          ;# mailbox protocol (soc_cmd, st_text, soc_reset ...)
hw_connect build/top_soc.bit build/top_soc.ltx      ;# programs the FPGA (~10 s)
set_property OUTPUT_VALUE_RADIX HEX [probe h2d_seq] ;# required once after programming
soc_reset
temperature
```

**On the board:** LD3 blinks (the firmware is running). LD0–LD2 are off.

### D.2 Helper to print results

Paste this once:

```tcl
proc show {result} {
    lassign $result st data
    puts "status [format %08x $st]  ->  [st_text $st]"
    puts "data   [join [lmap w [lrange $data 0 7] {format %08x $w}] { }] ..."
}
```

### D.3 Talk to the firmware

| Command | Tcl | Expected |
|---------|-----|----------|
| PING | `show [soc_cmd 1]` | data starts with `52563332` (`'RV32'`) `00010000` (version 1.0) |
| STATUS | `show [soc_cmd 7]` | data0 = `{buttons, switches}`, e.g. `00000000` with all switches off |
| ECHO | `show [soc_cmd 8 {1 2 3 4}]` | data starts with `00000001 00000002 00000003 00000004` |

### D.4 Enrol device 0

```tcl
# arguments: BCH message bits [31:0], BCH message bits [55:32], flags (0 = baseline, 1 = configurable RO), device
set r [soc_cmd 2 [list 0x12345678 0x00ABCDEF 0 0]]
show $r
set helper [lrange [lindex $r 1] 0 16]     ;# keep the 17 helper words (public data)
puts [join [lmap w $helper {format %08x $w}] { }]
```

**Expected:** `key_valid=0 locked=1 cmd_err=0`. **LD1 (locked) turns on.**

Point out that the key is *not* valid after enrolment. The design wipes it on purpose; a key only becomes valid through reconstruction (proved formally in Phase 7).

Try to enrol again to show the lock:

```tcl
show [soc_cmd 2 [list 1 2 0 0]]            ;# -> cmd_err=1 : REFUSED
```

### D.5 Reconstruct the key and authenticate

```tcl
show [soc_cmd 4 [list 0]]                  ;# RECONSTRUCT on device 0 -> key_valid=1 ecc_ok=1 kcv_ok=1
```

**LD0 (key valid) turns on.**

Now let the examiner choose a challenge, for example 64 bits written as two 32-bit words:

```tcl
set chal [list 0xCAFEBABE 0x00C0FFEE]
set t1 [lrange [lindex [soc_cmd 5 $chal] 1] 0 1]
puts "tag = [format %08x%08x [lindex $t1 1] [lindex $t1 0]]"
```

**LD2 turns on** (last authentication answered). Then:
- **Same challenge again:** must give the **same** tag.
- **A different challenge:** must give a completely different tag.

```tcl
set t2 [lrange [lindex [soc_cmd 5 $chal] 1] 0 1];  puts [expr {$t1 eq $t2}]   ;# 1
set t3 [lrange [lindex [soc_cmd 5 [list 0xCAFEBABF 0x00C0FFEE]] 1] 0 1];  puts [expr {$t1 eq $t3}]   ;# 0
```

### D.6 Reset (power-cycle simulation) and prove it is the same device

```tcl
soc_reset                                  ;# key, RAM copy of the helper data and lock are gone
show [soc_cmd 7]                           ;# key_valid=0
show [soc_cmd 3 $helper]                   ;# LOAD_HELPER: the verifier gives the public helper data back
show [soc_cmd 4 [list 0]]                  ;# RECONSTRUCT -> key_valid=1
set t4 [lrange [lindex [soc_cmd 5 $chal] 1] 0 1];  puts [expr {$t1 eq $t4}]   ;# 1 : same key as before the reset
```

The tag after the reset equals the tag from before. The key was **re-created from the silicon**: it was never stored anywhere.

### D.7 Prove a different device fails

```tcl
show [soc_cmd 4 [list 1]]                  ;# RECONSTRUCT using RO array 1 = "another chip" -> key_valid=0
show [soc_cmd 5 $chal]                     ;# AUTH -> cmd_err=1, tag 00000000 : refused
show [soc_cmd 4 [list 2]]                  ;# array 2 -> key_valid=0 as well
show [soc_cmd 4 [list 0]]                  ;# back to device 0 -> key_valid=1 again
```

**Switch version, which is nice to show physically:** device `0xFF` means "read SW1:SW0".

```tcl
# set SW0 = ON (device 1) on the board, then:
show [soc_cmd 4 [list 0xFF]]               ;# -> key_valid=0 (the board now "is" another device)
# set SW0 = OFF (device 0), then:
show [soc_cmd 4 [list 0xFF]]               ;# -> key_valid=1
```

### D.8 Reliability on demand

```tcl
set ok 0
for {set k 0} {$k < 50} {incr k} {
    lassign [soc_cmd 4 [list 0]] st d
    if {[st_bit $st 4]} { incr ok }
}
puts "$ok / 50 reconstructions valid"      ;# expect 50 / 50
```

### D.9 Finish

```tcl
close_hw_target
exit
```

---

## Part E: Showing the one-time lock with the board switches

The lock register (`locked`) is set by ENROL or by the LOCK command, and **can never be cleared by software**. On a real product the lock would be a burned eFUSE. On the lab board, **SW3 emulates that fuse**: it is loaded into the lock at every reset.

1. Do Part D.4 (enrol). LD1 is on.
2. Set **SW3 = ON**, then press **BTN0** (reset) or run `soc_reset`.
3. LD1 is on again immediately after reset: the chip "remembers" it is enrolled.
4. `show [soc_cmd 2 [list 1 2 0 0]]` → **`cmd_err=1`, refused.**
5. Reconstruction and authentication still work: `soc_cmd 3 $helper`, `soc_cmd 4 [list 0]`, `soc_cmd 5 $chal`.
6. Set SW3 = OFF again after the demo (otherwise the next enrolment is refused).

> Without SW3 the lock lasts only until reset, because the FPGA has no non-volatile memory. We deliberately did **not** program the Zynq eFUSEs: it is irreversible on a lab board.

---

## Part F: Optional: show the PUF itself (characterisation build)

The secure SoC never shows raw PUF data. To show *why* it works, use the separate characterisation bitstream, which exposes raw responses and RO counts.

```bash
# program + quick look: two reads of each array, some raw counts, die temperature
vivado -mode batch -nojournal -nolog -source scripts/hw/char_smoke.tcl
```

Typical output:

```
ARRAY 0 read1 176f764c4ee0d6c8f62e8a1c5cff1b50
ARRAY 0 read2 176f764c4ee0d6c8f62e8a1e5cff3b50     <- 2 bits differ: PUF noise
ARRAY 1 read1 c2a3bd98d0a967c9262125e7ece3eed9     <- completely different: another "device"
PAIR 0 counts: 8623 9665                            <- RO frequencies ~290 MHz, a clear winner
PAIR 77 counts: 9636 9643                           <- a near-tie: this bit can flip
```

Full data collection and the plots/report:

```bash
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs counts
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs room 100
vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs warm 100   # heater on, ~3 min
python -m model.hw_analysis        # -> docs/figures/hw_*.png, docs/reports/hw_characterisation.txt
```

> ⚠️ `char_collect.tcl` overwrites `data/hw_base`, `data/hw_cfg` and `data/hw_counts`. Copy them first if you want to keep the original measurements.

Figures to show: `docs/figures/hw_hd.png` (intra- vs inter-device distance), `hw_flip_vs_gap.png` (why bits flip) and `hw_frequency_map.png`.

---

## Part G: Reading the status word, LEDs and outputs

### G.1 Status word (`D2H_STATUS`)

Bits 15..0 are the key-generator status. Bits 23..16 echo the command number (`0xEE` = unknown command, `0xB007` in bits 31..16 = firmware just booted).

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | busy | key generator working (always 0 in replies) |
| 1 | done | last command finished |
| 2 | **cmd_err** | **last command was refused** (ENROL while locked, AUTH without a valid key) |
| 3 | **locked** | **one-time enrolment lock is set** |
| 4 | **key_valid** | **a reconstructed key is present and verified** |
| 5 | ecc_ok | every BCH block decoded |
| 6 | kcv_ok | the recomputed key-check value matched |

Examples:
- `0004007a` = command 4 (RECONSTRUCT) with kcv_ok, ecc_ok, key_valid, locked and done set.
- `0002000e` = command 2 (ENROL) with locked, cmd_err and done set: **refused**.

### G.2 LEDs

| LED | Meaning |
|-----|---------|
| LD0 | key valid |
| LD1 | locked |
| LD2 | the last AUTH was answered (a tag was produced) |
| LD3 | heartbeat (~2 Hz): the RISC-V firmware is alive |

### G.3 Firmware commands (`soc_cmd <n> <args>`)

| n | Command | Arguments | Returns |
|---|---------|-----------|---------|
| 1 | PING | – | `'RV32'`, version |
| 2 | ENROL | msg[31:0], msg[55:32], flags (bit0 = configurable RO), device (0..2 / `0xFF` = switches) | 17 helper words |
| 3 | LOAD_HELPER | 17 helper words | – |
| 4 | RECONSTRUCT | device | status (`key_valid`) |
| 5 | AUTH | challenge[31:0], challenge[63:32] | tag[31:0], tag[63:32], or zeros if refused |
| 6 | LOCK | – | status |
| 7 | STATUS | – | {buttons, switches}, device, last AUTH ok |
| 8 | ECHO | up to 24 words | the same words |

---

## Part H: Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `get_hw_devices` shows nothing / "no target" | Cable in the wrong port, board off, or drivers missing | Use the PROG/UART micro-USB port. Power on. Reinstall the cable drivers from `C:\Xilinx\Vivado\2024.2\data\xicom\cable_drivers` if needed |
| `firmware not responding` | The SoC is held in reset or the firmware has not booted | Run `soc_reset`. Make sure the `.bit` and `.ltx` are from the same build |
| `no VIO probe ...` | The `.ltx` file does not match the `.bit` | Always pass the `.bit` and `.ltx` from the same build |
| ENROL returns `cmd_err=1` straight after a reset | **SW3 is ON** (emulated fuse) | Turn SW3 off, then `soc_reset` |
| RECONSTRUCT on device 0 gives `key_valid=0` | Wrong helper data (another device / another enrolment), or the bitstream was **rebuilt** after enrolment | Enrol again on this bitstream, or use the helper data saved with it |
| `key_valid=0` with SW0/SW1 on | Device `0xFF` reads the switches, so you are on array 1/2/3 (3 maps to 0) | Set the switches to the device you want |
| Tags differ before and after reset | Different challenge, or a rebuilt bitstream | Use exactly the same two challenge words |
| Vivado console very slow | Several Vivado sessions hold the JTAG cable | Close the other hardware sessions (only one may own the cable) |

---

## Part I: What to say during the demo (talking points)

1. **"The chip has a fingerprint."** 768 ring oscillators are placed slice by slice on the FPGA. Manufacturing variation makes every RO slightly faster or slower. Comparing 128 pairs gives a 128-bit response that differs between silicon regions and chips (≈ 50% Hamming distance).
2. **"The fingerprint is noisy, so we use a fuzzy extractor."** About 1–3% of bits flip between reads. At enrolment we store public helper data (response ⊕ codeword). At reconstruction, repetition-3 + BCH(15,7,2) error correction recovers the exact response, and SipHash turns it into a 128-bit key.
3. **"The key never leaves the chip."** It is not in the memory map. Software can only ask for a MAC tag of a challenge. Even after enrolment the key is wiped.
4. **"Authentication is challenge–response."** The verifier records challenge→tag pairs once. Later it asks unused challenges. Only the real device can answer, and replaying old answers does not help.
5. **"Safety properties are proved, not just tested."** CTL model checking proves *key valid ⇒ ECC succeeded* and *locked ⇒ never enrol again*, for every input sequence.
6. **"Research enhancement."** The configurable RO costs no extra LUTs. It picks the most stable of 8 paths per pair and gave **0 bit errors in 1,800 reads**, against 0.2–3.3% for the baseline.
7. **Honest limitations.**
   - Only one board, so devices 1/2 are other regions of the same die.
   - The lock persistence is emulated with SW3.
   - The PUF is tied to its bitstream (no rebuild after enrolment).
