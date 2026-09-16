import struct
import unittest
import core_5k_relay as r


class RelayTests(unittest.TestCase):
    def test_forwards_headers_but_withholds_requests_and_blocks_above_boundary(self):
        boundary = r.Boundary("00" * 32)
        previous = bytes(32)
        headers = []
        for i in range(5001):
            header = struct.pack("<I", 1) + previous + bytes(32) + struct.pack("<III", i, 1, 1)
            previous = r.sha256d(header)
            headers.append(header)
        for start in range(0, 5001, 2000):
            batch = headers[start:start + 2000]
            payload = r.encode_compact(len(batch)) + b"".join(h + b"\0" for h in batch)
            self.assertEqual(boundary.transform(b"headers", payload, True), payload)
        allowed, blocked = headers[4999], headers[5000]
        self.assertEqual(boundary.transform(b"block", allowed, True), allowed)
        self.assertIsNone(boundary.transform(b"block", blocked, True))
        entries = [struct.pack("<I", 0x40000002) + r.sha256d(h) for h in (allowed, blocked)]
        self.assertEqual(boundary.transform(b"getdata", b"\x02" + b"".join(entries), False), b"\x01" + entries[0])
        self.assertIsNone(boundary.transform(b"getdata", b"\x01" + entries[1], False))
        self.assertEqual(boundary.transform(b"ping", b"12345678", True), b"12345678")
        self.assertEqual(len(boundary.heights), 5001)

    def test_malformed_headers_and_inventory_fail_closed(self):
        boundary = r.Boundary("00" * 32)
        for command, payload, upstream in [(b"headers", b"\x01short", True),
                                            (b"getdata", b"\x01short", False)]:
            with self.assertRaises(ValueError):
                boundary.transform(command, payload, upstream)


if __name__ == "__main__":
    unittest.main()
