"""SipHash-2-4 (Aumasson & Bernstein, 2012): 128-bit key, 64-bit output.

Used as the keyed MAC and, with a fixed public key, as the key-derivation function.
The key is 16 bytes; words are read little-endian, as in the reference implementation.
"""

MASK64 = (1 << 64) - 1


def _rotl(x, b):
    return ((x << b) | (x >> (64 - b))) & MASK64


def _sipround(v0, v1, v2, v3):
    v0 = (v0 + v1) & MASK64
    v1 = _rotl(v1, 13) ^ v0
    v0 = _rotl(v0, 32)
    v2 = (v2 + v3) & MASK64
    v3 = _rotl(v3, 16) ^ v2
    v0 = (v0 + v3) & MASK64
    v3 = _rotl(v3, 21) ^ v0
    v2 = (v2 + v1) & MASK64
    v1 = _rotl(v1, 17) ^ v2
    v2 = _rotl(v2, 32)
    return v0, v1, v2, v3


def siphash24(key, message):
    """key: 16 bytes, message: bytes -> 64-bit integer tag."""
    if len(key) != 16:
        raise ValueError("SipHash key must be 16 bytes")
    k0 = int.from_bytes(key[:8], "little")
    k1 = int.from_bytes(key[8:], "little")
    v0 = k0 ^ 0x736F6D6570736575
    v1 = k1 ^ 0x646F72616E646F6D
    v2 = k0 ^ 0x6C7967656E657261
    v3 = k1 ^ 0x7465646279746573

    full = len(message) // 8 * 8
    for offset in range(0, full, 8):
        m = int.from_bytes(message[offset:offset + 8], "little")
        v3 ^= m
        for _ in range(2):
            v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
        v0 ^= m

    # last block: remaining bytes plus the message length in the top byte
    m = ((len(message) & 0xFF) << 56) | int.from_bytes(message[full:], "little")
    v3 ^= m
    for _ in range(2):
        v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    v0 ^= m

    v2 ^= 0xFF
    for _ in range(4):
        v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    return v0 ^ v1 ^ v2 ^ v3
