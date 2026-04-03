#!/usr/bin/env python3
"""Unit tests for mq-metrics.py — stdlib unittest only, uses existing fixtures."""

import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
mq_metrics = __import__("mq-metrics")

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
EXCLUDE = re.compile(r"^SYSTEM\.|^AMQ\.")


def _fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()


class TestExtractKV(unittest.TestCase):
    def test_pairs(self):
        kv = mq_metrics._extract_kv("   QUEUE(APP.ORDERS.IN)                    TYPE(QLOCAL)")
        self.assertEqual(kv["QUEUE"], "APP.ORDERS.IN")
        self.assertEqual(kv["TYPE"], "QLOCAL")

    def test_numeric(self):
        kv = mq_metrics._extract_kv("   CURDEPTH(17)                            MAXDEPTH(10000)")
        self.assertEqual(kv["CURDEPTH"], "17")

    def test_empty_value(self):
        kv = mq_metrics._extract_kv("   LGETDATE( )                             LGETTIME( )")
        self.assertEqual(kv["LGETDATE"], " ")

    def test_qtime_comma(self):
        kv = mq_metrics._extract_kv("   QTIME(12345, 67890)                     UNCOM(NO)")
        self.assertEqual(kv["QTIME"], "12345, 67890")

    def test_no_match(self):
        self.assertEqual(mq_metrics._extract_kv("One MQSC command read."), {})


class TestDiscoverQmgrs(unittest.TestCase):
    """Test dspmq output parsing via discover_qmgrs internals."""
    def test_fixture(self):
        raw = _fixture("dspmq-output.txt")
        qmgrs = [kv["QMNAME"]
                  for line in raw.splitlines()
                  for kv in [mq_metrics._extract_kv(line)]
                  if kv.get("STATUS") == "Running" and "QMNAME" in kv]
        self.assertEqual(qmgrs, ["QM1"])


class TestParseMqsc(unittest.TestCase):
    def test_qlocal(self):
        raw = _fixture("qlocal-output.txt")
        queues = mq_metrics._parse_mqsc(raw, EXCLUDE, ("CURDEPTH", "MAXDEPTH"))
        self.assertEqual(len(queues), 3)
        self.assertIn("APP.ORDERS.IN", queues)
        self.assertNotIn("SYSTEM.DEFAULT.LOCAL.QUEUE", queues)
        self.assertEqual(queues["APP.ORDERS.IN"]["CURDEPTH"], "17")
        self.assertEqual(queues["APP.ORDERS.IN"]["MAXDEPTH"], "10000")
        self.assertEqual(queues["APP.PAYMENTS.IN"]["CURDEPTH"], "250")

    def test_qstatus(self):
        raw = _fixture("qstatus-output.txt")
        fields = ("LPUTDATE", "LPUTTIME", "LGETDATE", "LGETTIME",
                  "MSGAGE", "QTIME", "IPPROCS", "OPPROCS", "UNCOM")
        queues = mq_metrics._parse_mqsc(raw, EXCLUDE, fields)
        self.assertEqual(len(queues), 3)
        oi = queues["APP.ORDERS.IN"]
        self.assertEqual(oi["LPUTDATE"], "2026-04-03")
        self.assertEqual(oi["LPUTTIME"], "15.24.19")
        self.assertEqual(oi["MSGAGE"], "462")
        self.assertEqual(oi["QTIME"], "12345, 67890")
        self.assertEqual(oi["IPPROCS"], "1")
        self.assertEqual(oi["UNCOM"], "NO")
        # Empty MONQ
        oo = queues["APP.ORDERS.OUT"]
        self.assertEqual(oo["LPUTDATE"], " ")
        self.assertEqual(oo["QTIME"], " , ")
        # UNCOM YES
        self.assertEqual(queues["APP.PAYMENTS.IN"]["UNCOM"], "YES")

    def test_no_exclude(self):
        raw = _fixture("qlocal-output.txt")
        queues = mq_metrics._parse_mqsc(raw, re.compile(r"^$"), ("CURDEPTH", "MAXDEPTH"))
        self.assertEqual(len(queues), 4)


class TestMqToIso(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(mq_metrics.mq_to_iso("2026-04-03", "15.24.19"), "2026-04-03T15:24:19Z")

    def test_blank(self):
        self.assertIsNone(mq_metrics.mq_to_iso(" ", "15.24.19"))
        self.assertIsNone(mq_metrics.mq_to_iso("2026-04-03", " "))
        self.assertIsNone(mq_metrics.mq_to_iso("", ""))


class TestElapsedSeconds(unittest.TestCase):
    def test_basic(self):
        import calendar
        ts = calendar.timegm((2026, 4, 3, 15, 24, 19, 0, 0, 0))
        self.assertEqual(mq_metrics.elapsed_seconds("2026-04-03T15:24:19Z", ts + 100), 100)

    def test_none(self):
        self.assertIsNone(mq_metrics.elapsed_seconds(None, 100))
        self.assertIsNone(mq_metrics.elapsed_seconds("", 100))

    def test_future(self):
        import calendar
        ts = calendar.timegm((2026, 4, 3, 15, 24, 19, 0, 0, 0))
        self.assertEqual(mq_metrics.elapsed_seconds("2026-04-03T15:24:19Z", ts - 10), 0)


class TestBuildQueue(unittest.TestCase):
    def _ql(self, cur, mx):
        return {"CURDEPTH": str(cur), "MAXDEPTH": str(mx)}

    def test_basic_mode(self):
        q = mq_metrics._build_queue("Q1", self._ql(17, 10000), None, False, 0)
        self.assertEqual(q["depth"], 17)
        self.assertNotIn("depth_percent", q)

    def test_depth_percent_017(self):
        q = mq_metrics._build_queue("Q1", self._ql(17, 10000), {}, True, 0)
        self.assertEqual(q["depth_percent"], 0.17)

    def test_depth_percent_050(self):
        q = mq_metrics._build_queue("Q1", self._ql(250, 50000), {}, True, 0)
        self.assertEqual(q["depth_percent"], 0.50)

    def test_depth_percent_000(self):
        q = mq_metrics._build_queue("Q1", self._ql(0, 5000), {}, True, 0)
        self.assertEqual(q["depth_percent"], 0.0)

    def test_advanced_full(self):
        qs = {"IPPROCS": "1", "OPPROCS": "2", "UNCOM": "NO", "MSGAGE": "462",
              "QTIME": "12345, 67890", "LPUTDATE": "2026-04-03", "LPUTTIME": "15.24.19",
              "LGETDATE": "2026-04-03", "LGETTIME": "14.30.05"}
        import calendar
        now = calendar.timegm((2026, 4, 3, 15, 30, 0, 0, 0, 0))
        q = mq_metrics._build_queue("Q1", self._ql(17, 10000), qs, True, now)
        self.assertEqual(q["input_handles"], 1)
        self.assertEqual(q["output_handles"], 2)
        self.assertFalse(q["uncommitted"])
        self.assertEqual(q["oldest_message_age"], 462)
        self.assertEqual(q["queue_time_short"], 12345)
        self.assertEqual(q["queue_time_long"], 67890)
        self.assertEqual(q["last_put_timestamp"], "2026-04-03T15:24:19Z")
        self.assertEqual(q["last_get_timestamp"], "2026-04-03T14:30:05Z")
        self.assertIsInstance(q["last_put_elapsed_seconds"], int)

    def test_uncommitted_true(self):
        q = mq_metrics._build_queue("Q1", self._ql(1, 100), {"UNCOM": "YES"}, True, 0)
        self.assertTrue(q["uncommitted"])

    def test_empty_monq_omitted(self):
        qs = {"IPPROCS": "0", "OPPROCS": "0", "UNCOM": "NO",
              "LPUTDATE": " ", "LPUTTIME": " ", "LGETDATE": " ", "LGETTIME": " ",
              "MSGAGE": "0", "QTIME": " , "}
        q = mq_metrics._build_queue("Q1", self._ql(0, 5000), qs, True, 0)
        self.assertNotIn("last_put_timestamp", q)
        self.assertNotIn("queue_time_short", q)


class TestBuildDoc(unittest.TestCase):
    def test_structure(self):
        q = {"name": "Q1", "type": "local", "depth": 5, "max_depth": 1000}
        doc = mq_metrics._build_doc("2026-04-03T15:30:00Z", "test-host", "QM1", q)
        self.assertEqual(doc["ecs"]["version"], "8.11.0")
        self.assertEqual(doc["event"]["kind"], "metric")
        self.assertEqual(doc["agent"]["name"], "mq-metrics")
        self.assertEqual(doc["mq"]["queue"]["depth"], 5)
        # Verify JSON round-trip
        self.assertEqual(json.loads(json.dumps(doc))["mq"]["queue_manager"]["name"], "QM1")


if __name__ == "__main__":
    unittest.main()
