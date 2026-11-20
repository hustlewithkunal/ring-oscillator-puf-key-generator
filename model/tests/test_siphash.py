import unittest

from model.siphash import siphash24

KEY = bytes(range(16))


class TestSipHash(unittest.TestCase):
    # reference vectors from the SipHash paper / reference implementation (vectors.h)
    def test_empty_message(self):
        self.assertEqual(siphash24(KEY, b""), 0x726FDB47DD0E0E31)

    def test_paper_example_15_bytes(self):
        self.assertEqual(siphash24(KEY, bytes(range(15))), 0xA129CA6149BE45E5)

    def test_rejects_bad_key(self):
        with self.assertRaises(ValueError):
            siphash24(b"short", b"")


if __name__ == "__main__":
    unittest.main()
