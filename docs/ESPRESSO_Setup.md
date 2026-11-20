# ESPRESSO Setup (Windows)

ESPRESSO is the Berkeley two-level logic minimiser. We use it to build the GF(2⁴) multiplier and inverse (Phase 3).

## 1. Source

The third-party source is not stored in this repository. Fetch it into `tools/espresso-src/` at the commit we tested, then apply our Windows patch:

```sh
git clone https://github.com/classabbyamp/espresso-logic.git tools/espresso-src
git -C tools/espresso-src checkout 85265139e9598852f9388d293658a1977a829a01
git -C tools/espresso-src apply ../espresso-windows.patch
```

The patch (`tools/espresso-windows.patch`) changes two files so the source builds with MinGW gcc on Windows. Every change is marked `RTL_Project patch`:

| File | Change |
|------|--------|
| `espresso-src/cpu_time.c` | Use `clock()` on Windows instead of `getrusage()`, which Windows doesn't have. This only affects the optional timing printout. |
| `espresso-src/util_signature.c` | Skip `#include <sys/resource.h>` on Windows, and make `set_time_limit()` a no-op there. It only sets a CPU-time limit for the optional signature-based exact mode, so minimisation results are unchanged. |

## 2. Build (one command, from the project root)

```sh
mkdir -p tools/espresso && gcc -O2 -w -o tools/espresso/espresso.exe tools/espresso-src/espresso-src/*.c
```

`-w` hides the many warnings from this old 1980s C code. They are harmless.

Check the build:

```sh
tools/espresso/espresso.exe tools/espresso-src/examples/<any example file>
```

**Linux / macOS / WSL:** run `make -C tools/espresso-src/espresso-src`. The binary appears in `tools/espresso-src/bin/espresso`. Then set `ESPRESSO=<that path>` or copy it to `tools/espresso/`.

## 3. Run our flow

```sh
python scripts/espresso_flow.py           # heuristic minimisation (default)
python scripts/espresso_flow.py --exact   # exact minimisation, for comparison
```

For each function this does the following:
1. Minimises `model/vectors/espresso/gf_mul.pla` and `gf_inv.pla`, writing `*.min.pla`.
2. Checks the minimised logic against the golden model for **every** input (256 and 16 cases).
3. Generates `rtl/gf/gf16_mul_sop.v` and `rtl/gf/gf16_inv_sop.v`.
4. Prints the product-term and literal counts for the report.

## 4. Simulate in Vivado

- **Design sources:** `rtl/gf/gf16_mul_sop.v`, `rtl/gf/gf16_inv_sop.v`
- **Simulation sources:** `tb/tb_gf16_sop.v`, plus `model/vectors/gf_mul.mem` and `gf_inv.mem`. Add the `.mem` files too, so `$readmemh` finds them.
- Run Behavioural Simulation. The console must print:
  `PASS: gf16_mul_sop (256/256) and gf16_inv_sop (16/16) match the golden model`

To run it from the command line instead, go to a folder that contains `gf_mul.mem` and `gf_inv.mem`:

```sh
xvlog rtl/gf/gf16_mul_sop.v rtl/gf/gf16_inv_sop.v tb/tb_gf16_sop.v
xelab tb_gf16_sop -s tb_gf16
xsim tb_gf16 -R
```

## 5. Results

| Function | Truth-table ON-set rows | ESPRESSO heuristic: terms / literals | ESPRESSO exact: terms / literals | Python check | Vivado xsim |
|----------|-------------------------|--------------------------------------|----------------------------------|--------------|-------------|
| Multiplier (8 in, 4 out) | 225 | 135 / 810 | **129 / 781** | 256/256 ✅ | PASS ✅ |
| Inverse (4 in, 4 out) | 15 | 15 / 51 | **14 / 50** | 16/16 ✅ | PASS ✅ |

The checked-in RTL is the exact (`--exact`) result.

**Observation for the report:** the multiplier needs about 130 product terms. Each output bit is an XOR of several aᵢ·bⱼ terms, and XOR is the worst case for two-level AND-OR logic: an n-input XOR needs 2ⁿ⁻¹ product terms. The next step (Phase 3) compares this with an XOR-based Mastrovito multiplier and with BDD sizes, using post-synthesis LUT counts from Vivado.
