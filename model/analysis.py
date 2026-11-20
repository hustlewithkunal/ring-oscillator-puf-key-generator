"""PUF quality metrics and key-failure-rate analysis.

Metric definitions (all as fractions of the response width n):
  uniqueness     mean pairwise HD between the reference responses of k boards
                 = 2 / (k(k-1)) * sum_{i<j} HD(R_i, R_j) / n          ideal 0.5
  reliability    1 - mean HD(reference, re-read) / n on one board        ideal 1.0
  bit-aliasing   per bit position, fraction of boards giving a 1          ideal 0.5
  uniformity     fraction of 1s in one response                          ideal 0.5
"""

from itertools import combinations
from math import comb

import numpy as np

from . import bch
from .bitutils import hex_to_bits
from .fuzzy_extractor import FEParams, enrol, reconstruct
from .noise import bsc


# ---------------------------------------------------------------- PUF metrics

def fractional_hd(a, b):
    return float(np.mean(np.asarray(a) != np.asarray(b)))


def uniqueness(responses):
    """responses: (k_boards, n) array. Returns (mean, list of pairwise HDs)."""
    responses = np.asarray(responses)
    hds = [fractional_hd(responses[i], responses[j])
           for i, j in combinations(range(len(responses)), 2)]
    return float(np.mean(hds)), hds


def intra_hd(reference, reads):
    """Fractional HD of each re-read against the reference response."""
    reads = np.asarray(reads)
    return np.mean(reads != np.asarray(reference)[None, :], axis=1)


def reliability(reference, reads):
    return 1.0 - float(np.mean(intra_hd(reference, reads)))


def bit_aliasing(responses):
    return np.mean(np.asarray(responses), axis=0)


def uniformity(response):
    return float(np.mean(response))


def raw_failure_rate(reference, reads, n_bits=None):
    """Key failure without ECC: fraction of reads that are not bit-exact."""
    reads = np.asarray(reads)[:, :n_bits]
    reference = np.asarray(reference)[:n_bits]
    return float(np.mean(np.any(reads != reference[None, :], axis=1)))


def ecc_failure_rate(reference, reads, params, rng=None):
    """Key failure with ECC: enrol on the reference, reconstruct from every read."""
    enrolled = enrol(reference, params, rng=rng or np.random.default_rng(0))
    fails = 0
    for r in reads:
        res = reconstruct(r, enrolled.helper, params)
        if not res.key_valid or res.key != enrolled.key:
            fails += 1
    return fails / len(reads)


# ----------------------------------------------- analytic failure probability
# These assume independent bit errors with probability p (binary symmetric channel).

def _binom_tail(n, p, k_min):
    """P(X >= k_min) for X ~ Binomial(n, p)."""
    return sum(comb(n, k) * p ** k * (1 - p) ** (n - k) for k in range(k_min, n + 1))


def rep_bit_error(p, r):
    """Probability that majority decoding of r copies is wrong."""
    return _binom_tail(r, p, r // 2 + 1)


def bch_block_failure(q):
    """Probability that a 15-bit block has more than t=2 errors."""
    return _binom_tail(bch.N, q, bch.T + 1)


def key_failure_analytic(p, params):
    q = rep_bit_error(p, params.rep)
    return 1.0 - (1.0 - bch_block_failure(q)) ** params.n_blocks


def raw_failure_analytic(p, n_bits):
    return 1.0 - (1.0 - p) ** n_bits


def max_ber_for_target(params, target, lo=0.0, hi=0.5, iters=60):
    """Largest BER for which the analytic key-failure rate stays below target."""
    for _ in range(iters):
        mid = (lo + hi) / 2
        if key_failure_analytic(mid, params) <= target:
            lo = mid
        else:
            hi = mid
    return lo


def monte_carlo(params, p, trials, rng):
    """Simulate enrol + noisy reconstructions with random responses.

    Returns counts: raw (response not bit-exact), fail (key_valid = 0),
    wrong (key_valid = 1 but wrong key; the KCV should keep this at 0).
    """
    w = rng.integers(0, 2, params.n_response, dtype=np.uint8)
    enrolled = enrol(w, params, rng=rng)
    raw = fail = wrong = 0
    for _ in range(trials):
        w_noisy = bsc(w, p, rng)
        if np.any(w_noisy[:params.used_bits] != w[:params.used_bits]):
            raw += 1
        res = reconstruct(w_noisy, enrolled.helper, params)
        if not res.key_valid:
            fail += 1
        elif res.key != enrolled.key:
            wrong += 1
    return {"trials": trials, "raw": raw, "fail": fail, "wrong": wrong}


# ------------------------------------------------------------ measurement I/O

def load_responses(path, n_bits=128):
    """Read a measurement file: one response per line as hex (bit 0 = LSB).

    Blank lines and lines starting with '#' are ignored.
    """
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                rows.append(hex_to_bits(line, n_bits))
    return np.array(rows, dtype=np.uint8)
