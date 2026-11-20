#!/usr/bin/env python3
"""Host test for scripts/gateway-comparison.py. Needs no AWS access:

    python scripts/test/gateway-comparison-test.py

The sample file is made up. Its EUIs, counters and signal values belong to no real device.
It holds the four input forms the script accepts and these cases:
  node ...0a01: FCnt 10, 11, 12 (logged twice, a repeat), 14 (13 lost), then a reset to 0, 1
  node ...0b02: FCnt 5, 6, 8 (7 lost), heard by one gateway only
"""
import importlib.util
import io
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE = os.path.join(HERE, "gateway-comparison-sample.jsonl")
spec = importlib.util.spec_from_file_location("gwcmp", os.path.join(HERE, "..", "gateway-comparison.py"))
gwcmp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gwcmp)


class GatewayComparison(unittest.TestCase):
    def setUp(self):
        self.records = gwcmp.read_file(SAMPLE)
        self.result = gwcmp.compare(self.records)

    def test_all_four_input_forms_are_read(self):
        self.assertEqual(len(self.records), 10)   # 11 lines, one is a "delivery" event that is not an uplink
        self.assertTrue(all(len(r["node"]) == 4 for r in self.records))
        self.assertTrue(all(len(g["gw"]) == 4 for r in self.records for g in r["gateways"]))

    def test_frames_sent_from_counter_gaps_and_reset(self):
        a, b = self.result["nodes"]["0a01"], self.result["nodes"]["0b02"]
        self.assertEqual((a["sent"], a["resets"], a["logged"]), (7, 1, 6))
        self.assertEqual((b["sent"], b["resets"], b["logged"]), (4, 0, 3))
        self.assertEqual(self.result["sent"], 11)

    def test_per_gateway_numbers(self):
        pi, ref = self.result["gateways"]["11aa"], self.result["gateways"]["22bb"]
        self.assertEqual((pi["uplinks"], ref["uplinks"]), (5, 8))
        self.assertAlmostEqual(gwcmp.mean(pi["rssi"]), -84.0)
        self.assertAlmostEqual(gwcmp.mean(pi["snr"]), 8.0)
        self.assertAlmostEqual(gwcmp.mean(ref["rssi"]), -83.0)
        self.assertAlmostEqual(gwcmp.mean(ref["snr"]), 7.875)
        self.assertEqual((len(pi["nodes"]), len(ref["nodes"])), (1, 2))

    def test_repeat_is_one_frame_with_both_gateways(self):
        frames = gwcmp.merge_frames(self.records)["0a01"]
        twelve = [f for f in frames if f["fcnt"] == 12]
        self.assertEqual(len(twelve), 1)
        self.assertEqual(sorted(twelve[0]["gateways"]), ["11aa", "22bb"])

    def test_large_step_is_a_reset_not_lost_frames(self):
        frames = [{"fcnt": 1}, {"fcnt": 2}, {"fcnt": 5000}, {"fcnt": 5001}]
        self.assertEqual(gwcmp.frames_sent(frames), (4, 1))
        self.assertEqual(gwcmp.frames_sent(frames, max_gap=10000), (5001, 0))
        self.assertEqual(gwcmp.frames_sent([]), (0, 0))

    def test_window_and_node_filter(self):
        start = gwcmp.parse_time("2026-01-01T00:15:00Z")
        r = gwcmp.compare(self.records, start=start, nodes={"0a01"})
        self.assertEqual(list(r["nodes"]), ["0a01"])
        self.assertEqual(r["nodes"]["0a01"]["sent"], 3)   # 14, then the reset: 0, 1

    def test_table_output(self):
        text = gwcmp.render(self.result, {"11aa": "Pi", "22bb": "Reference"}, None, None, markdown=True)
        self.assertIn("| Pi (…11aa) | 5 | 45.5 % | -84.0 dBm | 8.0 dB | 1 |", text)
        self.assertIn("| Reference (…22bb) | 8 | 72.7 % | -83.0 dBm | 7.9 dB | 2 |", text)
        self.assertIn("Nodes: 2 (heard by every gateway: 1). Frames sent by them, from frame counters: 11. Counter resets: 1.", text)
        self.assertNotIn("00000000", text)   # never a full EUI

    def test_gateway_that_heard_nothing_still_gets_a_row(self):
        text = gwcmp.render(self.result, {"33cc": "Silent"}, None, None)
        self.assertRegex(text, r"Silent \(…33cc\)\s+0\s+0\.0 %\s+n/a\s+n/a\s+0")

    def test_command_line_and_save(self):
        out = os.path.join(HERE, "gateway-comparison-test-out.jsonl")
        old, sys.stdout = sys.stdout, type("O", (), {"buffer": io.BytesIO()})()
        try:
            self.assertEqual(gwcmp.main(["--file", SAMPLE, "--save", out, "--hours", "24"]), 0)
            printed = sys.stdout.buffer.getvalue().decode("utf-8")
        finally:
            sys.stdout = old
        self.assertIn("45.5 %", printed)
        again = gwcmp.compare(gwcmp.read_file(out))
        os.remove(out)
        self.assertEqual(again["sent"], 11)
        self.assertEqual(again["gateways"]["22bb"]["uplinks"], 8)


if __name__ == "__main__":
    unittest.main(verbosity=2)
