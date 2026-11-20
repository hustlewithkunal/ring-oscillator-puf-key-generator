"""Minimal two-pass RV32I assembler (no RISC-V toolchain is installed with Vivado).

Usage:  python sw/rvasm.py <source.S> <output.mem> [--words N] [--list listing.txt]

Supported:
  * all RV32I instructions (no CSR), operands as in the ISA manual: add rd, rs1, rs2 /
    addi rd, rs1, imm / lw rd, off(rs1) / sw rs2, off(rs1) / beq rs1, rs2, label / ...
  * registers x0..x31 and ABI names (zero ra sp gp tp t0-t6 s0-s11 fp a0-a7)
  * pseudo-instructions: nop li la mv not neg j jr ret call tail beqz bnez blez bgez
    bltz bgtz bgt ble bgtu bleu seqz snez
  * directives: .org ADDR, .align N (2^N bytes), .word EXPR[, EXPR...], .equ NAME, EXPR,
    .space BYTES
  * expressions: decimal / 0x hex / 'c' / labels / .equ names joined with + - * << >> | &,
    plus %hi(EXPR) and %lo(EXPR)
  * comments start with # or //
Output: one 32-bit hex word per line (for $readmemh), padded to --words words.
"""

import argparse
import re
import sys

ABI = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7,
       "s0": 8, "fp": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14,
       "a5": 15, "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22,
       "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27, "t3": 28, "t4": 29, "t5": 30,
       "t6": 31}

R_OPS = {  # name: (funct7, funct3)
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2), "sltu": (0x00, 3),
    "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5), "or": (0x00, 6), "and": (0x00, 7)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_I = {"slli": (0x00, 1), "srli": (0x00, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


def reg(tok):
    tok = tok.strip().lower()
    if tok in ABI:
        return ABI[tok]
    m = re.fullmatch(r"x(\d+)", tok)
    if m and int(m.group(1)) < 32:
        return int(m.group(1))
    raise AsmError("bad register '{}'".format(tok))


def split_operands(text):
    return [t.strip() for t in text.split(",")] if text.strip() else []


class Assembler:
    def __init__(self):
        self.symbols = {}
        self.items = []          # (addr, kind, payload, lineno, text)

    # ------------------------------------------------------------ expressions
    def value(self, expr, lineno, need=True):
        expr = expr.strip()
        m = re.fullmatch(r"%(hi|lo)\((.*)\)", expr)
        if m:
            v = self.value(m.group(2), lineno, need)
            if v is None:
                return None
            lo = ((v & 0xFFF) ^ 0x800) - 0x800
            return ((v - lo) >> 12) & 0xFFFFF if m.group(1) == "hi" else lo
        without_numbers = re.sub(r"\b0[xX][0-9a-fA-F]+\b|\b\d+\b|'.'", " ", expr)
        names = re.findall(r"[A-Za-z_.][A-Za-z0-9_.]*", without_numbers)
        env = {}
        for n in names:
            if n in self.symbols:
                env[n] = self.symbols[n]
            elif need:
                raise AsmError("line {}: undefined symbol '{}'".format(lineno, n))
            else:
                return None
        py = re.sub(r"'(.)'", lambda c: str(ord(c.group(1))), expr)
        if not re.fullmatch(r"[\w\s+\-*<>|&()x.]*", py):
            raise AsmError("line {}: bad expression '{}'".format(lineno, expr))
        try:
            return int(eval(py, {"__builtins__": {}}, env))
        except Exception:
            raise AsmError("line {}: cannot evaluate '{}'".format(lineno, expr))

    # ------------------------------------------------------------------ pass 1
    def size_of(self, mnem, ops, lineno):
        if mnem == "li":
            v = self.value(ops[1], lineno, need=False)
            return 4 if v is not None and -2048 <= v < 2048 else 8
        if mnem in ("la", "call", "tail"):
            return 8
        return 4

    def pass1(self, lines):
        addr = 0
        for lineno, raw in enumerate(lines, 1):
            line = re.split(r"#|//", raw, 1)[0].strip()
            while True:
                m = re.match(r"([A-Za-z_.][A-Za-z0-9_.]*)\s*:(.*)", line)
                if not m:
                    break
                if m.group(1) in self.symbols:
                    raise AsmError("line {}: duplicate label {}".format(lineno, m.group(1)))
                self.symbols[m.group(1)] = addr
                line = m.group(2).strip()
            if not line:
                continue
            parts = line.split(None, 1)
            mnem = parts[0].lower()
            ops = split_operands(parts[1] if len(parts) > 1 else "")
            if mnem == ".equ":
                self.symbols[ops[0]] = self.value(ops[1], lineno)
            elif mnem == ".org":
                addr = self.value(ops[0], lineno)
            elif mnem == ".align":
                a = 1 << self.value(ops[0], lineno)
                addr = (addr + a - 1) // a * a
            elif mnem == ".space":
                self.items.append((addr, "space", self.value(ops[0], lineno), lineno, raw))
                addr += self.value(ops[0], lineno)
            elif mnem == ".word":
                for o in ops:
                    self.items.append((addr, "word", o, lineno, raw))
                    addr += 4
            else:
                if addr % 4:
                    raise AsmError("line {}: instruction not word aligned".format(lineno))
                self.items.append((addr, "insn", (mnem, ops), lineno, raw))
                addr += self.size_of(mnem, ops, lineno)
        self.end = addr

    # ----------------------------------------------------------------- encoders
    @staticmethod
    def r(f7, rs2, rs1, f3, rd, op):
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def i(imm, rs1, f3, rd, op, lineno):
        if not -2048 <= imm < 2048:
            raise AsmError("line {}: immediate {} out of range".format(lineno, imm))
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def s(imm, rs2, rs1, f3, lineno):
        if not -2048 <= imm < 2048:
            raise AsmError("line {}: offset {} out of range".format(lineno, imm))
        imm &= 0xFFF
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

    @staticmethod
    def b(off, rs2, rs1, f3, lineno):
        if off % 2 or not -4096 <= off < 4096:
            raise AsmError("line {}: branch target out of range".format(lineno))
        off &= 0x1FFF
        return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
               (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63

    @staticmethod
    def u(imm20, rd, op):
        return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

    @staticmethod
    def j(off, rd, lineno):
        if off % 2 or not -(1 << 20) <= off < (1 << 20):
            raise AsmError("line {}: jump target out of range".format(lineno))
        off &= 0x1FFFFF
        return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) | \
               (((off >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

    def mem_operand(self, text, lineno):
        m = re.fullmatch(r"(.*)\((\w+)\)", text.strip())
        if not m:
            raise AsmError("line {}: expected offset(reg), got '{}'".format(lineno, text))
        off = self.value(m.group(1), lineno) if m.group(1).strip() else 0
        return off, reg(m.group(2))

    def encode(self, addr, mnem, ops, lineno):
        v = lambda e: self.value(e, lineno)
        rel = lambda e: v(e) - addr
        # ---- pseudo-instructions
        if mnem == "nop":
            return self.encode(addr, "addi", ["x0", "x0", "0"], lineno)
        if mnem == "li":
            val = v(ops[1]) & 0xFFFFFFFF
            sval = val - (1 << 32) if val & 0x80000000 else val
            if -2048 <= sval < 2048 and self.size_of("li", ops, lineno) == 4:
                return self.encode(addr, "addi", [ops[0], "x0", str(sval)], lineno)
            lo = ((val & 0xFFF) ^ 0x800) - 0x800
            hi = ((val - lo) >> 12) & 0xFFFFF
            return self.u(hi, reg(ops[0]), 0x37) + \
                   (self.i(lo, reg(ops[0]), 0, reg(ops[0]), 0x13, lineno) << 32)
        if mnem == "la":
            val = v(ops[1]) - addr
            lo = ((val & 0xFFF) ^ 0x800) - 0x800
            hi = ((val - lo) >> 12) & 0xFFFFF
            return self.u(hi, reg(ops[0]), 0x17) + \
                   (self.i(lo, reg(ops[0]), 0, reg(ops[0]), 0x13, lineno) << 32)
        if mnem in ("call", "tail"):
            rd = 1 if mnem == "call" else 0
            val = v(ops[0]) - addr
            lo = ((val & 0xFFF) ^ 0x800) - 0x800
            hi = ((val - lo) >> 12) & 0xFFFFF
            scratch = 1 if mnem == "call" else 6
            return self.u(hi, scratch, 0x17) + (self.i(lo, scratch, 0, rd, 0x67, lineno) << 32)
        alias = {
            "mv": lambda: ("addi", [ops[0], ops[1], "0"]),
            "not": lambda: ("xori", [ops[0], ops[1], "-1"]),
            "neg": lambda: ("sub", [ops[0], "x0", ops[1]]),
            "seqz": lambda: ("sltiu", [ops[0], ops[1], "1"]),
            "snez": lambda: ("sltu", [ops[0], "x0", ops[1]]),
            "j": lambda: ("jal", ["x0", ops[0]]),
            "jr": lambda: ("jalr", ["x0", ops[0], "0"]),
            "ret": lambda: ("jalr", ["x0", "ra", "0"]),
            "beqz": lambda: ("beq", [ops[0], "x0", ops[1]]),
            "bnez": lambda: ("bne", [ops[0], "x0", ops[1]]),
            "blez": lambda: ("bge", ["x0", ops[0], ops[1]]),
            "bgez": lambda: ("bge", [ops[0], "x0", ops[1]]),
            "bltz": lambda: ("blt", [ops[0], "x0", ops[1]]),
            "bgtz": lambda: ("blt", ["x0", ops[0], ops[1]]),
            "bgt": lambda: ("blt", [ops[1], ops[0], ops[2]]),
            "ble": lambda: ("bge", [ops[1], ops[0], ops[2]]),
            "bgtu": lambda: ("bltu", [ops[1], ops[0], ops[2]]),
            "bleu": lambda: ("bgeu", [ops[1], ops[0], ops[2]]),
        }
        if mnem in alias:
            m2, o2 = alias[mnem]()
            return self.encode(addr, m2, o2, lineno)
        if mnem == "jal" and len(ops) == 1:
            ops = ["ra"] + ops
        if mnem == "jalr" and len(ops) == 1:
            ops = ["ra", ops[0], "0"]
        if mnem == "jalr" and len(ops) == 2:
            off, rs1 = self.mem_operand(ops[1], lineno)
            ops = [ops[0], "x{}".format(rs1), str(off)]
        # ---- base instructions
        if mnem in R_OPS:
            f7, f3 = R_OPS[mnem]
            return self.r(f7, reg(ops[2]), reg(ops[1]), f3, reg(ops[0]), 0x33)
        if mnem in I_OPS:
            return self.i(v(ops[2]), reg(ops[1]), I_OPS[mnem], reg(ops[0]), 0x13, lineno)
        if mnem in SHIFT_I:
            f7, f3 = SHIFT_I[mnem]
            sh = v(ops[2])
            if not 0 <= sh < 32:
                raise AsmError("line {}: shift amount out of range".format(lineno))
            return self.r(f7, sh, reg(ops[1]), f3, reg(ops[0]), 0x13)
        if mnem in LOADS:
            off, rs1 = self.mem_operand(ops[1], lineno)
            return self.i(off, rs1, LOADS[mnem], reg(ops[0]), 0x03, lineno)
        if mnem in STORES:
            off, rs1 = self.mem_operand(ops[1], lineno)
            return self.s(off, reg(ops[0]), rs1, STORES[mnem], lineno)
        if mnem in BRANCHES:
            return self.b(rel(ops[2]), reg(ops[1]), reg(ops[0]), BRANCHES[mnem], lineno)
        if mnem == "lui":
            return self.u(v(ops[1]), reg(ops[0]), 0x37)
        if mnem == "auipc":
            return self.u(v(ops[1]), reg(ops[0]), 0x17)
        if mnem == "jal":
            return self.j(rel(ops[1]), reg(ops[0]), lineno)
        if mnem == "jalr":
            return self.i(v(ops[2]), reg(ops[1]), 0, reg(ops[0]), 0x67, lineno)
        if mnem == "fence":
            return 0x0FF0000F
        if mnem == "ecall":
            return 0x00000073
        if mnem == "ebreak":
            return 0x00100073
        raise AsmError("line {}: unknown instruction '{}'".format(lineno, mnem))

    # ------------------------------------------------------------------ pass 2
    def assemble(self, text, n_words):
        self.pass1(text.splitlines())
        if self.end > 4 * n_words:
            raise AsmError("program ({} bytes) does not fit in {} words".format(self.end, n_words))
        mem = [0] * n_words
        listing = []
        for addr, kind, payload, lineno, raw in self.items:
            if kind == "space":
                continue
            if kind == "word":
                words = [self.value(payload, lineno) & 0xFFFFFFFF]
            else:
                code = self.encode(addr, payload[0], payload[1], lineno)
                words = [code & 0xFFFFFFFF] + ([code >> 32] if code >> 32 else [])
                if len(words) * 4 != self.size_of(payload[0], payload[1], lineno):
                    words.append(0x00000013) if len(words) * 4 < self.size_of(payload[0], payload[1], lineno) else None
            for k, w in enumerate(words):
                mem[addr // 4 + k] = w
                listing.append("{:08x}  {:08x}  {}".format(addr + 4 * k, w, raw.strip() if k == 0 else ""))
        return mem, listing


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--words", type=int, default=2048)
    ap.add_argument("--list")
    args = ap.parse_args()
    asm = Assembler()
    try:
        with open(args.source) as f:
            mem, listing = asm.assemble(f.read(), args.words)
    except AsmError as e:
        sys.exit("rvasm: " + str(e))
    with open(args.output, "w", newline="\n") as f:
        f.write("\n".join("{:08x}".format(w) for w in mem) + "\n")
    if args.list:
        with open(args.list, "w", newline="\n") as f:
            f.write("\n".join(listing) + "\n")
            f.write("\n# symbols\n" + "\n".join("{:<24} 0x{:08x}".format(k, v)
                                                for k, v in sorted(asm.symbols.items(), key=lambda t: t[1])) + "\n")
    print("rvasm: {} bytes used of {} ({} words)".format(asm.end, 4 * args.words, args.words))


if __name__ == "__main__":
    main()
