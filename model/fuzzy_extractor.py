"""Code-offset fuzzy extractor: repetition code (inner) concatenated with BCH(15,7,2) (outer).

Enrolment (once):
    m       = random 7-bit message per BCH block
    c       = Rep_r( BCH(m_0) || BCH(m_1) || ... )         (used_bits long)
    helper  = w_used XOR c                                   (public)
    K       = KDF(w_used)                                    (128-bit key)
    kcv     = low 32 bits of MAC(K, "KCV")                   (key-check value, public)

Reconstruction (every power-up):
    c'      = w'_used XOR helper                 c plus the PUF noise
    cw'     = majority-decode(c', r)             repetition decoding
    cw      = BCH-decode each 15-bit block       stop with FAIL if any block fails
    w       = Rep_r(cw) XOR helper               the exact enrolled response
    K       = KDF(w), accepted only if MAC(K, "KCV") matches kcv

The KCV catches the rare case where >2 errors in a block decode "successfully"
to the wrong codeword, so key_valid really means "this is the enrolled key".

Response bits beyond used_bits are not error-corrected and therefore never used.
"""

from dataclasses import dataclass, field
from typing import List

import numpy as np

from . import bch, repetition
from .bitutils import bits_to_bytes, bits_to_int, int_to_bits
from .siphash import siphash24

# Fixed, public SipHash key for the KDF ("RO-PUF-KDF-v1" padded with zeros).
KDF_KEY = b"RO-PUF-KDF-v1\x00\x00\x00"
KCV_MESSAGE = b"KCV"
KCV_BITS = 32


@dataclass(frozen=True)
class FEParams:
    rep: int = 1             # repetition factor r (odd)
    n_response: int = 128    # PUF response width

    @property
    def block_bits(self):
        """Response bits consumed by one BCH block."""
        return bch.N * self.rep

    @property
    def n_blocks(self):
        return self.n_response // self.block_bits

    @property
    def used_bits(self):
        return self.n_blocks * self.block_bits

    @property
    def secret_bits(self):
        return self.n_blocks * bch.K

    @property
    def leaked_bits(self):
        """Upper bound on response entropy revealed by the helper data."""
        return self.used_bits - self.secret_bits


@dataclass
class HelperData:
    offset: np.ndarray       # used_bits long, w_used XOR c
    kcv: int                 # 32-bit key-check value


@dataclass
class EnrolResult:
    helper: HelperData
    key: int                 # 128-bit key (never leaves the chip in hardware)
    messages: List[int]      # random BCH messages chosen at enrolment
    codeword: np.ndarray     # c, used_bits long


@dataclass
class ReconstructResult:
    key: int                 # 0 unless key_valid
    key_valid: bool
    ecc_ok: bool
    kcv_ok: bool
    rep_decoded: np.ndarray  # BCH input after majority vote (n_blocks*15 bits)
    blocks: List[bch.DecodeResult] = field(default_factory=list)


def derive_key(w_used):
    """128-bit key = SipHash(KDF_KEY, 0x01||w) | SipHash(KDF_KEY, 0x02||w) << 64."""
    data = bits_to_bytes(w_used)
    lo = siphash24(KDF_KEY, b"\x01" + data)
    hi = siphash24(KDF_KEY, b"\x02" + data)
    return lo | (hi << 64)


def key_bytes(key):
    return key.to_bytes(16, "little")


def key_check_value(key):
    return siphash24(key_bytes(key), KCV_MESSAGE) & ((1 << KCV_BITS) - 1)


def mac(key, challenge):
    """64-bit authentication tag for a 64-bit challenge."""
    return siphash24(key_bytes(key), challenge.to_bytes(8, "little"))


def _check_response(w, params):
    w = np.asarray(w, dtype=np.uint8)
    if w.shape != (params.n_response,):
        raise ValueError("response must have {} bits".format(params.n_response))
    if params.n_blocks == 0:
        raise ValueError("repetition factor too large for the response width")
    return w


def encode_messages(messages, params):
    """Messages -> concatenated codeword c (BCH, then repetition)."""
    cw_bits = np.concatenate([int_to_bits(bch.encode(m), bch.N) for m in messages])
    return repetition.encode(cw_bits, params.rep)


def enrol(w, params=FEParams(), rng=None, messages=None):
    w = _check_response(w, params)
    if messages is None:
        if rng is None:
            rng = np.random.default_rng()
        messages = rng.integers(0, 1 << bch.K, size=params.n_blocks)
    messages = [int(m) for m in messages]
    if len(messages) != params.n_blocks:
        raise ValueError("need one message per BCH block")
    c = encode_messages(messages, params)
    w_used = w[:params.used_bits]
    key = derive_key(w_used)
    helper = HelperData(offset=w_used ^ c, kcv=key_check_value(key))
    return EnrolResult(helper=helper, key=key, messages=messages, codeword=c)


def reconstruct(w_noisy, helper, params=FEParams()):
    w_noisy = _check_response(w_noisy, params)
    c_noisy = w_noisy[:params.used_bits] ^ helper.offset
    rep_decoded = repetition.decode(c_noisy, params.rep)

    blocks = []
    for b in range(params.n_blocks):
        received = bits_to_int(rep_decoded[b * bch.N:(b + 1) * bch.N])
        blocks.append(bch.decode(received))
    ecc_ok = all(d.ok for d in blocks)
    if not ecc_ok:
        # the sequencer goes straight to FAIL: no KDF, key stays zero
        return ReconstructResult(0, False, False, False, rep_decoded, blocks)

    cw_bits = np.concatenate([int_to_bits(d.corrected, bch.N) for d in blocks])
    w_hat = repetition.encode(cw_bits, params.rep) ^ helper.offset
    key = derive_key(w_hat)
    kcv_ok = key_check_value(key) == helper.kcv
    return ReconstructResult(key if kcv_ok else 0, kcv_ok, True, kcv_ok, rep_decoded, blocks)
