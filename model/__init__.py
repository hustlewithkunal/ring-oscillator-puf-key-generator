"""Golden model for the RO-PUF key generator with a code-offset fuzzy extractor.

Bit-ordering convention used everywhere in this package (and expected from the RTL):
  * A bit vector is a numpy uint8 array of 0/1 values; element i is "bit i".
  * When a bit vector is packed into an integer or hex string, bit i is the
    coefficient of 2**i (bit 0 = LSB).
  * Response bit i is the comparison of RO pair i: 1 if count(RO 2i) > count(RO 2i+1).
"""
