"""Noise models for re-reading a PUF response."""

import numpy as np


def bsc(bits, p, rng):
    """Binary symmetric channel: flip each bit independently with probability p."""
    bits = np.asarray(bits, dtype=np.uint8)
    flips = (rng.random(bits.shape) < p).astype(np.uint8)
    return bits ^ flips


def flip_positions(bits, positions):
    """Flip exactly the given bit positions (for directed tests)."""
    out = np.array(bits, dtype=np.uint8, copy=True)
    for i in positions:
        out[i] ^= 1
    return out
