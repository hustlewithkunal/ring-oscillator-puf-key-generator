# Phase 6: RV32 SoC with Challenge–Response Authentication

**Deliverable:** "RV32 challenge–response authentication program; helper data in SoC memory." The key is used only internally (keyed MAC) and is never readable over the bus.

---

## 1. Architecture

```
            JTAG (USB)                         Zynq-7010 PL, 125 MHz
 PC ─────────────────────► VIO mailbox ──┐
 (Vivado Tcl host:                        │   ┌──────────────────────── soc ──────────────────────────┐
  scripts/hw/soc_host.tcl,                └──►│ mailbox regs ◄──► rv32_core ◄──► 8 KB RAM (firmware,   │
  soc_demo.tcl)                               │                      │           stack, HELPER DATA)  │
                                              │                      ▼                                 │
                                              │   GPIO (LEDs, SW, BTN, cycles)   fuzzy_extractor      │
                                              │                                  (REP 3, SipHash MAC, │
                                              │                                   lock) — key inside  │
                                              └────────────────── puf_* ports ──────────┬─────────────┘
                                                                                         ▼
                                                       u_puf: puf_measure, 3 RO arrays (placed, Pblock)
```

| Block | File | Notes |
|-------|------|-------|
| RV32I core | `rtl/soc/rv32_core.v` | Our own multi-cycle core. Full RV32I except CSRs. PicoRV32-style valid/ready bus. About 5 cycles per instruction |
| RAM | `rtl/soc/soc_ram.v` | 8 KB block RAM with byte enables, initialised from `sw/firmware.mem` |
| SoC | `rtl/soc/soc.v` | Bus decoder, key-generator registers, PUF arbitration, mailbox, GPIO |
| Top level | `rtl/top/top_soc.v` | Clock, reset and switch synchronisers, VIO mailbox, PUF arrays |
| Assembler | `sw/rvasm.py` | Two-pass RV32I assembler written for the project (Vivado ships no RISC-V compiler) |
| Firmware | `sw/firmware.S` | Command loop, about 900 bytes |

### Why our own core, assembler and JTAG link

| Choice | Reason |
|--------|--------|
| Own RV32I core | No external IP needed. Small, fully verified, and the project controls every line |
| Own assembler | No RISC-V GCC is installed with Vivado 2024.2 (only the MicroBlaze compiler) |
| JTAG + VIO mailbox | On the Zybo Z7 the USB-UART is wired to the ARM processing system only. JTAG is already connected and fully scriptable from Vivado Tcl |

## 2. Memory map

| Address | Register | Access |
|---------|----------|--------|
| `0x0000_0000` | RAM 8 KB. Helper data at `0x1800` (17 words: offset, KCV, configuration) | RW |
| `0x1000_0000` | `FE_CMD`: key-generator command | W |
| `0x1000_0004` | `FE_STATUS` {kcv_ok, ecc_ok, key_valid, locked, cmd_err, done, busy} | R |
| `0x1000_0008/0C` | `ENROL_MSG0/1`: random BCH messages | W |
| `0x1000_0010..20` | `HELPER_IN[0..3]`, `KCV_IN` | W |
| `0x1000_0024/28` | `CHAL0/1` | W |
| `0x1000_0030..48` | `HELPER_OUT[0..3]`, `KCV_OUT`, `TAG0/1` | R |
| `0x1000_0050` | `PUF_CTRL`: start SELECT / {select_done, busy} | RW |
| `0x1000_0054` | `DEV_SEL`: RO array (0..2) | RW |
| `0x1000_0080..AC` | `PAIR_CFG[0..11]`: RO configuration, 384 bits | RW |
| `0x1000_00C0..EC` | `CFG_BEST[0..11]`: SELECT result | R |
| `0x2000_0000` | Mailbox: `H2D_SEQ`, `H2D_CMD`, `H2D_ARG[0..23]` / `D2H_SEQ`, `D2H_STATUS`, `D2H_DATA[0..23]` | R / W |
| `0x3000_0000` | GPIO: LEDs, {buttons, switches}, cycle counter | RW / R |

**There is no address for the key.** It exists only inside `fuzzy_extractor`, which has no key port. Firmware, and therefore the host, can only obtain helper data, status and MAC tags.

## 3. Firmware commands (`sw/firmware.S`)

| Cmd | Name | Arguments → result |
|-----|------|--------------------|
| 1 | PING | → `'RV32'`, version |
| 2 | ENROL | BCH messages, flags (bit 0 = configurable RO), device → helper data (also stored in RAM) |
| 3 | LOAD_HELPER | 17 helper words → RAM |
| 4 | RECONSTRUCT | device (0..2, `0xFF` = switches) → status (`key_valid`) |
| 5 | AUTH | 64-bit challenge → 64-bit SipHash tag, or refused without a valid key |
| 6 | LOCK | |
| 7 | STATUS | → switches, device, last authentication |
| 8 | ECHO | 24 words → the same 24 words (link test) |

**Mailbox protocol:**
1. The host writes the arguments and the command, then changes `H2D_SEQ` *last*.
2. The firmware echoes the sequence number in `D2H_SEQ` when it has finished.
3. At boot the firmware writes a non-zero status (`0xB007…`) and echoes the current sequence number. The host sends nothing until then, so a command can't be lost while the firmware boots.

This last rule fixed a race that the system simulation found.

**Configurable-RO enrolment (research enhancement).** For flag bit 0 = 1, the firmware first runs the PUF's SELECT mode, which picks the most stable of 8 configurations for every pair. It stores the chosen configuration (384 bits) as part of the helper data. Reconstruction loads it back into the PUF before measuring.

## 4. Verification in simulation

| Test | What | Result |
|------|------|--------|
| `tb_rv32_core` + `sw/tests/core_selftest.S` | Every RV32I instruction class checked by the program itself (ALU, shifts, compares, all 6 branches taken / not taken, JAL/JALR links, byte/half/word loads and stores with sign and zero extension, `x0`) | ✅ PASS: 209 instructions, CPI 5.1 |
| Assembler | Encodings compared with RISC-V reference values (R/I/S/B/U/J formats, `ebreak`) | ✅ 14/14 |
| `tb_soc`: whole system (core + firmware + fuzzy extractor + 2 RO arrays with the behavioural RO model) driven through the mailbox | PING; ENROL device 0; RECONSTRUCT → key valid; AUTH ×2 → equal tags, different challenge → different tag; 2nd ENROL refused; **device 1 with device 0's helper → key invalid, AUTH refused**; reset; configurable ENROL; LOAD_HELPER from host; RECONSTRUCT → valid; AUTH | ✅ PASS |

**Bugs found by these tests before the hardware:**
- **The arithmetic shift was a logical shift.** Verilog makes a `?:` expression unsigned if either operand is unsigned, so `>>>` turned into `>>`.
- **Lost commands at boot.** The race described in section 3.

## 5. Implementation on the Zybo Z7-10

| Metric | Value |
|--------|-------|
| Slice LUTs | 9,156 / 17,600 (52 %) — of which 3,072 are the 768 ring oscillators |
| Flip-flops | 9,365 / 35,200 (27 %) |
| Block RAM | 2 / 60 (firmware RAM) |
| Clock / timing | 125 MHz, **WNS +0.055 ns** after routing |

**Timing fix:** the first build missed 125 MHz by 0.019 ns. The path ran from the CPU's instruction register through the operand/subtract decode and a 32-bit adder into the register file (14 levels). Registering `is_imm` and `sub` in the DECODE state, one cycle earlier, made the EXEC path start at flip-flops. The CPI is unchanged (5.13).

**Bring-up bug (host side):** Vivado names the three 256-bit slices of one VIO bus (`d2h_data`, `d2h_data_1`, `d2h_data_2`) in an arbitrary port order. The ECHO test cannot detect that, because the same permutation applies in both directions. PING's known answer exposed it. The host scripts now select every probe by its port number (`probe_port`).

## 6. Demo results on the board

`scripts/hw/soc_demo.tcl` (logs in `data/hw_soc/demo_base.txt` and `demo_cfg.txt`), with all switches off and the die at about 43 °C:

| Step | Baseline RO-PUF | Configurable RO-PUF |
|------|-----------------|---------------------|
| Link test (ECHO 24 words), PING | ✅ `'RV32'` v1.0 | ✅ |
| ENROL device 0 | ✅ helper data returned, locked | ✅ helper data + 384-bit configuration |
| Second ENROL | ✅ **refused** (locked) | ✅ **refused** |
| Factory reconstruction, 8 challenge–response pairs recorded | ✅ key valid (`ecc_ok`, `kcv_ok`) | ✅ |
| Field: SoC reset, helper restored by the host, reconstruction | ✅ key valid | ✅ key valid |
| AUTH with 4 unused challenges | ✅ **4/4 → AUTHENTICATED** | ✅ **4/4 → AUTHENTICATED** |
| Impostor: device 1 with device 0's helper data | ✅ key invalid → **REJECTED** | ✅ **REJECTED** |
| Impostor: device 2 | ✅ **REJECTED** | ✅ **REJECTED** |
| Reliability: 100 field reconstructions | ✅ **100/100** valid keys, 100/100 correct tags | ✅ **100/100**, 100/100 |

*Device 1 and device 2 are the other two RO arrays: different regions of the silicon, used as virtual devices because only one board is available. A second Zybo running the same bitstream would behave the same way. Its RO arrays are different silicon, so its PUF responses differ.*

**One-time lock across a reset.** SW3 emulates a burned fuse (`boot_locked`). With SW3 on, the key generator starts locked and every ENROL is refused, while RECONSTRUCT and AUTH still work. This was seen on the board: SW3 was on at first power-up, and ENROL was refused with status `locked=1, cmd_err=1`.
