"""Export test vectors for the RTL testbenches and truth tables for ESPRESSO.

Run from the project root:   python -m model.gen_vectors
Output goes to model/vectors/. Formats are documented in model/vectors/README.md
and in the header comment of every .mem file.
"""

import os
import random
from itertools import combinations

import numpy as np

from . import bch, gf16 as gf
from .bitutils import bits_to_int
from .fuzzy_extractor import FEParams, KCV_MESSAGE, KDF_KEY, enrol, reconstruct, mac
from .siphash import siphash24
from .noise import bsc, flip_positions

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")


def _write_mem(name, header_lines, rows):
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", newline="\n") as f:
        for line in header_lines:
            f.write("// " + line + "\n")
        for row in rows:
            f.write(row + "\n")
    print("wrote {:<28} {:>6} vectors".format(name, len(rows)))


def _write_pla(name, n_in, n_out, in_names, out_names, table):
    path = os.path.join(OUT_DIR, "espresso", name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n") as f:
        f.write(".i {}\n.o {}\n".format(n_in, n_out))
        f.write(".ilb {}\n.ob {}\n".format(" ".join(in_names), " ".join(out_names)))
        f.write(".type fr\n.p {}\n".format(len(table)))
        for inp, out in table:
            f.write("{} {}\n".format(format(inp, "0{}b".format(n_in)), format(out, "0{}b".format(n_out))))
        f.write(".e\n")
    print("wrote {:<28} {:>6} rows".format("espresso/" + name, len(table)))


def gen_gf():
    rows = ["{:x}{:x}{:x}".format(a, b, gf.MUL_TABLE[a][b]) for a in range(16) for b in range(16)]
    _write_mem("gf_mul.mem", [
        "GF(2^4) multiply, p(x) = x^4 + x + 1. One 12-bit word per line:",
        "[11:8] a  [7:4] b  [3:0] a*b",
    ], rows)
    rows = ["{:x}{:x}".format(a, gf.INV_TABLE[a]) for a in range(16)]
    _write_mem("gf_inv.mem", [
        "GF(2^4) inverse (inv(0) = 0). One 8-bit word per line:",
        "[7:4] a  [3:0] a^-1",
    ], rows)
    _write_pla("gf_mul.pla", 8, 4,
               ["a3", "a2", "a1", "a0", "b3", "b2", "b1", "b0"], ["p3", "p2", "p1", "p0"],
               [((a << 4) | b, gf.MUL_TABLE[a][b]) for a in range(16) for b in range(16)])
    _write_pla("gf_inv.pla", 4, 4, ["a3", "a2", "a1", "a0"], ["y3", "y2", "y1", "y0"],
               [(a, gf.INV_TABLE[a]) for a in range(16)])


def gen_bch():
    rows = ["{:02x}{:04x}".format(m, bch.encode(m)) for m in range(128)]
    _write_mem("bch_enc.mem", [
        "BCH(15,7) systematic encoder. One 24-bit word per line:",
        "[22:16] message  [14:0] codeword (bits 14..8 = message, 7..0 = parity)",
    ], rows)

    received = []
    for cw in bch.ALL_CODEWORDS:                      # exhaustive: weight 0, 1, 2
        for w in range(3):
            for pos in combinations(range(bch.N), w):
                received.append(cw ^ sum(1 << p for p in pos))
    rng = random.Random(2026)                         # sampled weight-3 patterns
    for _ in range(2000):
        cw = rng.choice(bch.ALL_CODEWORDS)
        received.append(cw ^ sum(1 << p for p in rng.sample(range(bch.N), 3)))

    rows = []
    for r in received:
        d = bch.decode(r)
        rows.append("{:04x}{:x}{:x}{:x}{:x}{:04x}{:04x}{:x}".format(
            d.received, d.s1, d.s3, d.l1, d.l2, d.error_mask, d.corrected, int(d.ok)))
    _write_mem("bch_dec.mem", [
        "BCH(15,7,2) decoder, every intermediate value. One 68-bit word per line:",
        "[66:52] received  [51:48] S1  [47:44] S3  [43:40] Lambda1  [39:36] Lambda2",
        "[34:20] error_mask  [18:4] corrected  [0] ok",
        "On failure (ok=0): error_mask = 0, corrected = received, Lambda = 0 if S1 = 0.",
        "First 15488 lines: all codewords x all patterns of weight <= 2 (ok must be 1).",
        "Remaining 2000 lines: random weight-3 patterns (fail or miscorrection).",
    ], rows)


def gen_fuzzy_extractor():
    rng = np.random.default_rng(7)
    for r in (1, 3, 5):
        params = FEParams(rep=r)
        rows = []
        for case in range(24):
            w = rng.integers(0, 2, 128, dtype=np.uint8)
            e = enrol(w, params, rng=rng)
            if case < 4:
                w_noisy = w.copy()                                   # no noise
            elif case < 8:              # 2 BCH-level errors per block (all r copies flipped)
                pos = [b * params.block_bits + k * r + j
                       for b in range(params.n_blocks) for k in (1, 9) for j in range(r)]
                w_noisy = flip_positions(w, pos)
            elif case < 20:
                w_noisy = bsc(w, 0.03, rng)                          # typical noise
            else:
                w_noisy = rng.integers(0, 2, 128, dtype=np.uint8)   # different board
            res = reconstruct(w_noisy, e.helper, params)
            challenge = int(rng.integers(0, 1 << 63)) * 2 + int(rng.integers(0, 2))
            tag = mac(res.key, challenge) if res.key_valid else 0
            msgs = sum(m << (7 * i) for i, m in enumerate(e.messages))
            fields = [
                ("w (enrolment response)", bits_to_int(w), 32),
                ("BCH messages, block i at [7i+6:7i] of this field", msgs, 14),
                ("helper offset (used bits, zero padded)", bits_to_int(e.helper.offset), 32),
                ("KCV", e.helper.kcv, 8),
                ("w' (re-read response)", bits_to_int(w_noisy), 32),
                ("key (0 if invalid)", res.key, 32),
                ("key_valid", int(res.key_valid), 1),
                ("challenge", challenge, 16),
                ("tag = MAC(key, challenge), 0 if invalid", tag, 16),
            ]
            rows.append("".join(format(v, "0{}x".format(n)) for _, v, n in fields))
        _write_mem("fe_r{}.mem".format(r), [
            "Fuzzy extractor end-to-end, rep factor r = {}, {} BCH blocks, {} used bits.".format(
                r, params.n_blocks, params.used_bits),
            "Cases 0-3 no noise, 4-7 two errors per BCH block, 8-19 BSC p=0.03, 20-23 other board.",
        ] + _field_layout(fields), rows)


def gen_siphash():
    """SipHash-2-4 vectors: the 64 reference vectors (key 00..0f, message 00..n-1),
    random keys/messages, and the exact message shapes used by the design."""
    rng = random.Random(24)
    cases = [(bytes(range(16)), bytes(range(n))) for n in range(64)]
    for _ in range(200):
        cases.append((bytes(rng.getrandbits(8) for _ in range(16)),
                      bytes(rng.getrandbits(8) for _ in range(rng.randrange(64)))))
    # design usage: KDF (0x01/0x02 || used response bytes), KCV ("KCV"), MAC (8-byte challenge)
    for params in (FEParams(rep=1), FEParams(rep=3), FEParams(rep=5)):
        w = bytes(rng.getrandbits(8) for _ in range((params.used_bits + 7) // 8))
        cases += [(KDF_KEY, b"\x01" + w), (KDF_KEY, b"\x02" + w)]
    for _ in range(4):
        key = bytes(rng.getrandbits(8) for _ in range(16))
        cases += [(key, KCV_MESSAGE), (key, bytes(rng.getrandbits(8) for _ in range(8)))]

    fields = [("key (byte 0 = bits [7:0])", 32), ("message length in bytes", 2),
              ("message, byte j = bits [8j+7:8j], zero padded", 128), ("expected tag", 16)]
    rows = ["{:032x}{:02x}{:0128x}{:016x}".format(
        int.from_bytes(k, "little"), len(m), int.from_bytes(m, "little"), siphash24(k, m))
        for k, m in cases]
    _write_mem("siphash.mem", [
        "SipHash-2-4. Lines 0-63: reference vectors (key 00..0f, message 00 01 .. n-1);",
        "then 200 random cases; then KDF/KCV/MAC messages exactly as the design uses them.",
    ] + _field_layout([(n, 0, w) for n, w in fields]), rows)


def _field_layout(fields):
    """Header lines giving the [msb:lsb] slice of each hex field, packed MSB first."""
    total = 4 * sum(n for _, _, n in fields)
    lines = ["One {}-bit word per line:".format(total)]
    msb = total - 1
    for name, _, n in fields:
        lines.append("  [{}:{}] {}".format(msb, msb - 4 * n + 1, name))
        msb -= 4 * n
    return lines


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    gen_gf()
    gen_bch()
    gen_fuzzy_extractor()
    gen_siphash()


if __name__ == "__main__":
    main()
