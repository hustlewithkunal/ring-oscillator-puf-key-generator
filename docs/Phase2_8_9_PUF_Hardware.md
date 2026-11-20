# Phases 2, 8, 9: RO-PUF on the Zybo Z7-10 — Hardware, Characterisation, Research Enhancement

**Deliverables covered:**
- RO array with placement constraints and measurement counters
- Uniqueness, reliability (≥ 100 reads + warm-board test), bit-aliasing
- Key-failure rate before and after ECC
- Research: implement an RO-PUF improvement and compare it with the baseline

**Headline results (measured on the board):**
- **Uniqueness ≈ 49–50%** (pooled over 9 array pairs).
- **Baseline bit-error rate 0.2–3.3%.**
- **The configurable RO-PUF had zero bit errors in 1,800 reads**, room and warm, over three builds.
- **Key failure with rep-3 + BCH: 0 / 1,800.** Without ECC: 34–100% per array.

---

## 1. Hardware (Phase 2)

### 1.1 RO cell: `rtl/puf/ro_cell.v`

**One RO per slice:**

| Stage | LUT | Function |
|-------|-----|----------|
| 0 | A6LUT, LUT4 | `~(en & (cfg0 ? I1 : I0))` |
| 1 | B6LUT, LUT3 | `~(cfg1 ? I1 : I0)` |
| 2 | C6LUT, LUT3 | `~(cfg2 ? I1 : I0)` |
| toggle | D6LUT + DFF | divide by 2, clocked by the RO |

In every stage, I0 and I1 carry the *same* signal through different physical LUT pins (A2 or A5). The 3 configuration bits therefore select one of 8 slightly different loops at **no extra LUT cost**: the configurable RO of Maiti and Schaumont (2011). Configuration 000 is the baseline RO.

Measured frequency: **≈ 290 MHz** (2–3% spread). The counted toggle signal runs at ≈ 145 MHz.

### 1.2 Arrays and placement

`scripts/gen_puf_xdc.py` generates `constraints/puf_placement.xdc`:
- **3 arrays × 256 ROs = 768 slices.** All are SLICEL slices in CLBLL tiles (columns X14/15, X18/19, X22/23, X26/27).
- Array 0 occupies rows 0–31, array 1 rows 34–65, array 2 rows 68–99.
- **Pair p** = RO 2p and RO 2p+1, in vertically adjacent slices of the same column (the same slice type, a few µm apart).
- **Constraints:** LOC + BEL for every LUT and the flip-flop, and **LOCK_PINS** for every LUT input. A Pblock with **EXCLUDE_PLACEMENT** keeps all other logic out of the RO slices.
- **Routing is locked too.** `constraints/puf_routes.xdc` holds **FIXED_ROUTE** for all 2,304 RO-internal nets (see §1.4).

### 1.3 Measurement unit: `rtl/puf/puf_measure.v`

For each pair, the unit measures both ROs at the same time:
1. Enable only the two ROs of the pair.
2. Let them settle (32 cycles).
3. Clear both counters.
4. Open the gate for 2¹³ cycles of the 125 MHz clock (65.5 µs). Each counter runs in its RO's own clock domain, with the gate synchronised in.
5. Close the gate, stop the ROs, and read the now-static counts.
6. Bit p = (count A > count B).

One 128-bit response takes about 8.6 ms.

**SELECT mode** (for the configurable RO) measures all 8 configurations per pair and keeps the one with the largest |count A − count B|. That takes about 69 ms.

The unit is verified in simulation (`tb/tb_puf_measure.v`) against a behavioural RO model with random process variation and jitter (`rtl/puf/sim/ro_cell_sim.v`). It gives the physically correct bit on 98/98 well-separated pairs, counts within 0.1% of theory, and SELECT is optimal on 128/128 pairs.

### 1.4 Finding: the PUF changed with every rebuild, so the routing is now locked

LOC/BEL/LOCK_PINS fix *where* the LUTs are, but the router still picks the wires *between* them. On this device the stage-to-stage wire, which goes through a switchbox bounce, is a large part of the loop delay. The measured effect:

| Comparison | Response bits changed | RO frequency change |
|------------|-----------------------|---------------------|
| Same bitstream, repeated reads (noise) | 0.3–0.9% | – |
| **Build A → build B** (unrelated logic changed) | **17–21%** | mean 1.0%, **max 20.6%** |

So without further measures, any rebuild (a firmware change, for example) would silently change the PUF and invalidate the enrolled key. The fix:
1. `scripts/export_puf_routes.tcl` exports the routes of all RO nets from the reference SoC build as FIXED_ROUTE constraints.
2. Both the characterisation and the SoC builds use them.
3. `scripts/check_puf_routes.tcl` confirms on a routed design that **2,304 / 2,304 RO nets are identical** to the reference, both for the SoC and for the characterisation build.

The characterisation results in §2 were therefore measured on *exactly* the RO loops the SoC uses.

**How much does locking help? A rebuild test.** The characterisation design was rebuilt with an unrelated change (heater 2,048 → 2,000 flip-flops). The route check confirmed 2,304/2,304 RO nets identical, and the PUF was read again (`scripts/hw/char_stability.tcl`, data in `data/hw_rebuild_check/`):

| Rebuild | Per-RO frequency change | Response bits changed |
|---------|-------------------------|-----------------------|
| Routes **not** locked (build A → B) | mean 1.0%, max **20.6%** | 17–21% |
| Routes **locked** (build C → D) | std **0.2%**, max 0.87% | **7–10%** |

Locking the routes makes each RO 5–25 times more stable across builds. The remaining ~0.2% comes from the RO's *surroundings*: other nets now routed through the same interconnect tiles (coupling) and a changed local supply load. Placement and routing constraints cannot freeze that. Because the median pair gap is only ~0.6%, it still flips the closest 7–10% of pairs.

**Consequence: a PUF instance is tied to its bitstream.** Firmware updates must not re-implement the design. The firmware RAM can be replaced inside the existing bitstream with Vivado's `updatemem` (or `write_bitstream` after `set_property INIT`), which leaves every RO bit-identical. This is how the SoC's firmware should be updated after enrolment.

### 1.5 Host access

The characterisation bitstream (`rtl/top/top_char.v`) has:
- a VIO core over JTAG, driven by `scripts/hw/puf_host.tcl` and `char_collect.tcl`
- the raw response and counts readable, which is acceptable for this build only
- the XADC die temperature, read over JTAG
- an on-chip **heater**: 2,000 toggle flip-flops plus 64 DSP48 multiply-accumulators

**Heater iterations:**
1. The first heater had a fixed point (all ones) and stopped toggling immediately: no heating at all.
2. The second used 25×18 *unsigned* multipliers. Each needed three DSPs, the excess spilled into LUTs, and the build needed 39k LUTs.
3. The final heater raises the die by **≈ +7 °C** (42.5 → 49.5 °C).

## 2. Characterisation (Phase 8)

**Protocol, per array (= virtual device):**
- Counts of all 256 ROs.
- 100 reads at room temperature. The die runs at 42–44 °C, the PL self-heating with the board in still air.
- Heater on until the die temperature is stable, then 100 warm reads.
- All of this for both the baseline and the configurable RO.

**References:** the reliability reference is the majority vote of the room reads (`hw_analysis.py` also reports the first-read reference). The uniqueness reference is the majority response of each array.

Data: `data/hw_counts/`, `data/hw_base/`, `data/hw_cfg/`. Analysis: `python -m model.hw_analysis` (output in `docs/reports/hw_characterisation.txt`).

> **Uniqueness with one board.** Only one Zybo is available, so the three arrays (three distinct regions of the die, each with its own independent process variation) act as three virtual devices. This shows the response is unique *to the silicon region*. True chip-to-chip uniqueness additionally needs other boards, and the same bitstream can be run on any other Zybo Z7-10 to measure it.

### 2.1 Results: final build (locked routes)

| Metric | Array 0 | Array 1 | Array 2 | Ideal |
|--------|---------|---------|---------|-------|
| RO frequency (mean ± std) | 293.4 ± 5.0 MHz | 291.1 ± 7.8 MHz | 291.4 ± 6.8 MHz | – |
| **Baseline BER, room (42.5 °C)** | 0.88% | 1.86% | 0.67% | 0% |
| **Baseline BER, warm (49.3 °C)** | 0.17% | 3.30% | 1.26% | 0% |
| Worst single read (baseline) | 2.3% | 6.3% | 3.1% | 0% |
| **Configurable BER, room / warm** | **0.00% / 0.00%** | **0.00% / 0.00%** | **0.00% / 0.00%** | 0% |
| Uniformity (baseline) | 0.516 | 0.508 | 0.594 | 0.5 |

Uniqueness and bit-aliasing over the three measured routings:

| Build | Baseline uniqueness | Configurable uniqueness | Baseline BER (mean / max) | Configurable BER |
|-------|---------------------|-------------------------|---------------------------|------------------|
| A (first build) | 50.5% | 51.0% | 0.82% / 1.35% | 0.00% |
| B | 53.1% | 52.6% | 0.74% / 1.44% | 0.00% |
| Final (locked routes) | 43.2% | 46.9% | 1.36% / 3.30% | 0.00% |
| **Pooled, 9 pairs** | **48.9%** | **50.2%** | | |

Bit-aliasing (mean fraction of 1s per bit position) is 0.52–0.55 for the baseline and 0.50–0.53 for the configurable RO.

*With 3 devices × 128 bits, one inter-device HD has a standard deviation of about 4.4%. The spread between builds (43–53%) is consistent with that, and the pooled value is close to the ideal 50%.*

### 2.2 Why bits flip

`docs/figures/hw_flip_vs_gap.png` plots each bit's flip rate over 100 reads against its pair's frequency gap. **Every unstable bit belongs to a pair whose frequencies differ by less than about 0.13%.** Every pair with a larger gap was stable in all 100 reads. This is what the configurable RO exploits.

### 2.3 Key-failure rate before and after ECC (deliverable)

| | Baseline RO-PUF | Configurable RO-PUF |
|---|---|---|
| **Before ECC:** reads not bit-exact (key would fail) | 78% / 98% / 86% room, 96% / 100% / 85% warm | 0% |
| After ECC, BCH only (r = 1), replayed in the golden model | 0% / 5% / 0% room, 0% / 7% / 0% warm | 0% |
| **After ECC, rep-3 + BCH (r = 3, the SoC setting)** | **0 / 600** | **0 / 600** |
| Predicted, worst measured BER (3.3%), r = 3 / r = 5 | 3.7 × 10⁻⁵ / 2.7 × 10⁻⁸ | < 10⁻¹⁵ |
| **On the board, SoC reconstructions** (`docs/Phase6_SoC.md`) | **100 / 100 valid keys** | **100 / 100** |

**Conclusion:**
- Error correction is essential: without it, almost every read gives a wrong key.
- BCH alone (r = 1) is not enough for the noisiest array.
- **r = 3 is the right choice for the baseline PUF.** No failures were seen, and the prediction is about 4 × 10⁻⁵ at the worst measured BER. r = 5 would reach 10⁻⁸, at the price of entropy.

## 3. Research enhancement: configurable RO (Phase 9)

**Paper:** A. Maiti and P. Schaumont, *"Improved Ring Oscillator PUF: An FPGA-friendly Secure Primitive,"* Journal of Cryptology, 2011.

**Idea:** each RO can take one of several slightly different paths. At enrolment, every pair gets the configuration that maximises its frequency difference, and that choice is stored as public helper data. Near-ties, the only source of bit errors (§2.2), are avoided.

**Our implementation:**
- **Hardware cost: zero LUTs.** Each LUT stage chooses between two physical input pins (A2/A5) via a configuration input, giving 8 configurations per RO.
- **Small control cost:** the SELECT mode in `puf_measure` and 384 bits of configuration register.
- **Helper data** grows by 384 bits (12 words). It is stored in SoC RAM next to the offset and KCV.
- **Enrolment time** grows from 8.6 ms to 77 ms (SELECT + measurement).

**Comparison on the same silicon, same arrays, same protocol:**

| Metric | Baseline | Configurable | Better |
|--------|----------|--------------|--------|
| BER, room (mean over arrays and builds) | 0.3–1.9% | **0.00%** | ✅ |
| BER, warm (+7 °C) | 0.2–3.3% | **0.00%** | ✅ |
| Reads with any bit error (before ECC) | 34–100% | **0%** | ✅ |
| Uniqueness, pooled | 48.9% | **50.2%** | ✅ (closer to 50%) |
| Bit-aliasing (mean) | 0.518–0.547 | **0.500–0.526** | ✅ |
| Helper data | 160 bits | 544 bits | ✗ |
| Enrolment time | 8.6 ms | 77 ms | ✗ |

**Security note.** The configuration helper data reveals *which* path each pair uses, but not which RO of the pair is faster, so it leaks no response bits directly. Repeated SELECT runs pick a different but equally good configuration for some pairs; this is harmless because the stored choice is reused.

**Practical consequence.** With the configurable RO, the measured BER is 0, so even r = 1 (BCH only) would be reliable on this board. That would raise the residual key entropy from ≈ 14 bits (r = 3) to ≈ 56 bits (r = 1), assuming fully random responses. The SoC keeps r = 3 for the baseline mode. A configurable-only build could use r = 1, which is an option for future work.

## 4. Files

| File | Contents |
|------|----------|
| `rtl/puf/ro_cell.v`, `ro_array.v`, `puf_measure.v`, `heater.v` | PUF hardware |
| `rtl/puf/sim/ro_cell_sim.v`, `tb/tb_puf_measure.v` | Behavioural RO model and testbench |
| `rtl/top/top_char.v`, `scripts/build_char.tcl` | Characterisation bitstream |
| `scripts/gen_puf_xdc.py` → `constraints/puf_placement.xdc` | Placement |
| `scripts/export_puf_routes.tcl` → `constraints/puf_routes.xdc`, `scripts/check_puf_routes.tcl` | Route locking and its check |
| `scripts/hw/puf_host.tcl`, `char_collect.tcl`, `char_cfg_check.tcl`, `char_stability.tcl` | Host side (JTAG/VIO) |
| `model/hw_analysis.py` | Analysis and figures |
| `data/` | All raw measurements: `hw_*` (final build), `hw_build_b/`, `hw_prev_build/` (earlier routings) |
