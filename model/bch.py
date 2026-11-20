"""Binary BCH(15, 7, t=2) code over GF(2^4).

Codeword layout (15-bit integer, bit i = coefficient of x^i):
    bits 14..8 : message (7 bits)      -- systematic part
    bits  7..0 : parity  (8 bits)      -- remainder of m(x)*x^8 mod g(x)

Generator g(x) = m1(x) * m3(x) = (x^4 + x + 1)(x^4 + x^3 + x^2 + x + 1)
              = x^8 + x^7 + x^6 + x^4 + 1
so every codeword has alpha, alpha^2, alpha^3, alpha^4 as roots, which gives
minimum distance 5 and corrects any 2 bit errors.

Decoding (the steps the RTL implements):
  1. Syndromes   S1 = r(alpha), S3 = r(alpha^3)   (S2 = S1^2 and S4 = S1^4 are implied)
  2. Peterson    Lambda(x) = 1 + L1 x + L2 x^2 with
                     L1 = S1
                     L2 = S3 * S1^-1 + S1^2       (= (S3 + S1^3) / S1, rewritten so both
                                                    products can run in parallel)
                 S1 = 0, S3 = 0  -> no errors
                 S1 = 0, S3 != 0 -> more than 2 errors (uncorrectable)
                 L2 = 0          -> exactly one error
  3. Chien search: bit i is in error iff Lambda(alpha^-i) = 0
  4. Success check: number of roots found must equal deg(Lambda), otherwise the
     error pattern was beyond the code's capability and decoding fails.
"""

from collections import namedtuple

from . import gf16 as gf

N = 15
K = 7
T = 2
GEN_POLY = 0b111010001  # x^8 + x^7 + x^6 + x^4 + 1
PARITY_BITS = N - K


def _poly_mod(a, g):
    """Remainder of binary polynomial a divided by g (both as integers)."""
    deg_g = g.bit_length() - 1
    while a.bit_length() - 1 >= deg_g:
        a ^= g << (a.bit_length() - 1 - deg_g)
    return a


def encode(message):
    """7-bit message -> 15-bit systematic codeword."""
    if not 0 <= message < (1 << K):
        raise ValueError("message must be a 7-bit value")
    shifted = message << PARITY_BITS
    return shifted | _poly_mod(shifted, GEN_POLY)


def syndrome(received, j):
    """S_j = r(alpha^j) = XOR of alpha^(j*i) over every set bit i."""
    s = 0
    for i in range(N):
        if (received >> i) & 1:
            s ^= gf.alpha_pow(j * i)
    return s


def peterson(s1, s3):
    """Error-locator coefficients from the syndromes.

    Returns (L1, L2, degree); degree = -1 flags an uncorrectable syndrome.
    """
    if s1 == 0:
        if s3 == 0:
            return 0, 0, 0
        return 0, 0, -1
    l1 = s1
    l2 = gf.MUL_TABLE[s3][gf.INV_TABLE[s1]] ^ gf.MUL_TABLE[s1][s1]
    return l1, l2, (2 if l2 else 1)


def chien_search(l1, l2):
    """Bit mask of positions i where Lambda(alpha^-i) = 0."""
    mask = 0
    for i in range(N):
        x = gf.alpha_pow(-i)
        value = 1 ^ gf.MUL_TABLE[l1][x] ^ gf.MUL_TABLE[l2][gf.MUL_TABLE[x][x]]
        if value == 0:
            mask |= 1 << i
    return mask


DecodeResult = namedtuple(
    "DecodeResult",
    ["received", "s1", "s3", "l1", "l2", "degree", "error_mask", "corrected", "ok"],
)
DecodeResult.__doc__ = """Every intermediate value of one decode, so the RTL can be checked stage by stage.

On failure (ok = False) error_mask is 0 and corrected equals received.
"""


def decode(received):
    if not 0 <= received < (1 << N):
        raise ValueError("received word must be a 15-bit value")
    s1 = syndrome(received, 1)
    s3 = syndrome(received, 3)
    l1, l2, degree = peterson(s1, s3)
    ok = False
    error_mask = 0
    if degree == 0:
        ok = True
    elif degree > 0:
        roots = chien_search(l1, l2)
        if bin(roots).count("1") == degree:
            ok = True
            error_mask = roots
    corrected = received ^ error_mask
    return DecodeResult(received, s1, s3, l1, l2, degree, error_mask, corrected, ok)


def message_of(codeword):
    return codeword >> PARITY_BITS


ALL_CODEWORDS = [encode(m) for m in range(1 << K)]
