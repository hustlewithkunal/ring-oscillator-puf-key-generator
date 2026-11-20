"""Repetition code of odd length r: each bit is sent r times, decoded by majority vote.

Layout: input bit j occupies output positions j*r .. j*r + r - 1 (copies are adjacent).
"""

import numpy as np


def _check_rep(r):
    if r < 1 or r % 2 == 0:
        raise ValueError("repetition factor must be odd and >= 1")


def encode(bits, r):
    _check_rep(r)
    return np.repeat(np.asarray(bits, dtype=np.uint8), r)


def decode(bits, r):
    _check_rep(r)
    groups = np.asarray(bits, dtype=np.uint8).reshape(-1, r)
    return (groups.sum(axis=1) > r // 2).astype(np.uint8)
