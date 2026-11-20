"""Arithmetic in the finite field GF(2^4), primitive polynomial p(x) = x^4 + x + 1.

An element is a 4-bit integer 0..15 in polynomial basis: bit i is the coefficient
of alpha^i, where alpha is a root of p(x). Addition is XOR. Multiplication is
polynomial multiplication followed by reduction modulo p(x).

The non-zero elements are all powers of alpha (alpha^0 .. alpha^14), so the
EXP/LOG tables give a second, independent way to multiply which the tests use to
cross-check the bitwise multiplier.
"""

PRIM_POLY = 0b10011  # x^4 + x + 1
ORDER = 15           # number of non-zero elements


def _build_tables():
    exp = [0] * (2 * ORDER)
    log = [None] * 16
    x = 1
    for i in range(ORDER):
        exp[i] = x
        log[x] = i
        x <<= 1
        if x & 0x10:
            x ^= PRIM_POLY
    # second copy so EXP[LOG[a] + LOG[b]] never needs a modulo
    for i in range(ORDER, 2 * ORDER):
        exp[i] = exp[i - ORDER]
    return exp, log


EXP, LOG = _build_tables()


def add(a, b):
    return a ^ b


def mul(a, b):
    """Shift-and-add multiply followed by reduction (the structure of an RTL multiplier)."""
    product = 0
    for i in range(4):
        if (b >> i) & 1:
            product ^= a << i
    # the product has degree <= 6; reduce the x^6, x^5, x^4 terms
    for i in (6, 5, 4):
        if (product >> i) & 1:
            product ^= PRIM_POLY << (i - 4)
    return product


def mul_log(a, b):
    """Multiply via log/antilog tables (reference used to check mul)."""
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]


def inv(a):
    """Multiplicative inverse. inv(0) is defined as 0, matching the hardware block."""
    if a == 0:
        return 0
    return EXP[(ORDER - LOG[a]) % ORDER]


def power(a, n):
    """a**n in the field (n may be negative for non-zero a)."""
    if a == 0:
        return 1 if n == 0 else 0
    return EXP[(LOG[a] * n) % ORDER]


def alpha_pow(n):
    """alpha**n for any integer n."""
    return EXP[n % ORDER]


# Precomputed tables for speed in the BCH decoder and for exporting truth tables.
MUL_TABLE = [[mul(a, b) for b in range(16)] for a in range(16)]
INV_TABLE = [inv(a) for a in range(16)]
