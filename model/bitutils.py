"""Conversions between bit vectors, integers, bytes and hex (LSB-first everywhere)."""

import numpy as np


def int_to_bits(value, n):
    """Integer -> uint8 array of n bits, element i = bit i of value."""
    return np.array([(value >> i) & 1 for i in range(n)], dtype=np.uint8)


def bits_to_int(bits):
    """uint8 bit array -> integer, element i becomes bit i."""
    value = 0
    for i, b in enumerate(bits):
        if b:
            value |= 1 << i
    return value


def bits_to_bytes(bits):
    """Pack bits LSB-first: byte k holds bits 8k..8k+7, bit 8k is the byte's LSB."""
    n_bytes = (len(bits) + 7) // 8
    return bits_to_int(bits).to_bytes(n_bytes, "little")


def hamming(a, b):
    """Number of differing bits between two equal-length bit arrays."""
    return int(np.count_nonzero(np.asarray(a) != np.asarray(b)))


def hex_to_bits(text, n):
    """Hex string (as written in measurement files) -> n-bit array."""
    return int_to_bits(int(text, 16), n)


def bits_to_hex(bits, n_hex=None):
    """Bit array -> zero-padded hex string."""
    if n_hex is None:
        n_hex = (len(bits) + 3) // 4
    return format(bits_to_int(bits), "0{}x".format(n_hex))
