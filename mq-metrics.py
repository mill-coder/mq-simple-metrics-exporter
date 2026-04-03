#!/usr/bin/env python3
"""mq-metrics.py - Collect IBM MQ queue metrics and push to Elasticsearch (ECS format).

Python equivalent of mq-metrics.ksh. Requires Python 3.6+, no external packages.

Configuration (environment variables):
  MQ_METRICS_ELASTIC_URL        - Elasticsearch base URL (empty = dry-run to stdout)
  MQ_METRICS_ELASTIC_API_KEY    - Elastic API key for authentication
  MQ_METRICS_ELASTIC_INDEX      - Target index/data-stream (default: metrics-mq.queue-default)
  MQ_METRICS_QMGR_LIST          - Comma-separated QM names (auto-discovers via dspmq if unset)
  MQ_METRICS_EXCLUDE_QUEUES     - Regex of queues to skip (default: ^SYSTEM\\.|^AMQ\\.)
  MQ_METRICS_ADVANCED           - Set to 1 to enable QSTATUS collection and derived fields
  MQ_METRICS_FILTER_WEBSPHERE   - Set to 0 to disable WHERE(DESCR NL 'WebSphere MQ') filter
"""

import calendar
import json
import logging
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

if sys.version_info < (3, 6):
    sys.stderr.write("ERROR: Python 3.6 or later is required.\n")
    sys.exit(2)

_KV_RE = re.compile(r'([A-Z][A-Z0-9_]*)\(([^)]*)\)')

log = logging.getLogger("mq-metrics")


def _extract_kv(line):
    """Extract all KEY(VALUE) pairs from a runmqsc output line."""
    return dict(_KV_RE.findall(line))


def _runmqsc(qmgr, mqsc_cmd):
    """Pipe an MQSC command into runmqsc, return (returncode, stdout)."""
    r = subprocess.run(["runmqsc", qmgr], input=mqsc_cmd + "\n",
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       universal_newlines=True)
    return r.returncode, r.stdout


def _parse_mqsc(raw_output, exclude_re, fields):
    """Generic state-machine parser for runmqsc DISPLAY output.
    Accumulates specified fields between QUEUE() markers.
    Returns {queue_name: {field: raw_value, ...}}."""
    queues = {}
    cur_queue = None
    cur = {}
    for line in raw_output.splitlines():
        kv = _extract_kv(line)
        if "QUEUE" in kv:
            if cur_queue and not exclude_re.search(cur_queue):
                queues[cur_queue] = cur
            cur_queue = kv["QUEUE"]
            cur = {}
        for f in fields:
            if f in kv:
                cur[f] = kv[f]
    if cur_queue and not exclude_re.search(cur_queue):
        queues[cur_queue] = cur
    return queues


def discover_qmgrs():
    """Discover running queue managers via dspmq."""
    r = subprocess.run(["dspmq"], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True)
    return [kv["QMNAME"] for line in r.stdout.splitlines()
            for kv in [_extract_kv(line)]
            if kv.get("STATUS") == "Running" and "QMNAME" in kv]


def mq_to_iso(date_str, time_str):
    """Convert MQ date+time to ISO 8601. Returns None if blank."""
    if not date_str or not time_str or not date_str.strip() or not time_str.strip():
        return None
    return f"{date_str}T{time_str.replace('.', ':')}Z"


def elapsed_seconds(iso_ts, now_epoch):
    """Seconds between ISO 8601 timestamp and now_epoch. None if no timestamp."""
    if not iso_ts:
        return None
    d, t = iso_ts.split("T")
    t = t.rstrip("Z")
    Y, M, D = (int(x) for x in d.split("-"))
    h, m, s = (int(x) for x in t.split(":"))
    return max(now_epoch - calendar.timegm((Y, M, D, h, m, s, 0, 0, 0)), 0)


def _depth_percent(curdepth, maxdepth):
    """Compute depth percentage matching ksh integer math."""
    if maxdepth <= 0:
        return None
    dp = (curdepth * 10000) // maxdepth
    frac = dp % 100
    return float(f"{dp // 100}.{'0' + str(frac) if frac < 10 else frac}")


def _build_queue(name, qlocal, qstatus, advanced, now_epoch):
    """Build the mq.queue object for one queue."""
    curdepth = int(qlocal["CURDEPTH"])
    maxdepth = int(qlocal["MAXDEPTH"])
    q = {"name": name, "type": "local", "depth": curdepth, "max_depth": maxdepth}

    if not advanced:
        return q

    dp = _depth_percent(curdepth, maxdepth)
    if dp is not None:
        q["depth_percent"] = dp

    if not qstatus:
        return q

    for mq_key, json_key in (("IPPROCS", "input_handles"), ("OPPROCS", "output_handles")):
        v = qstatus.get(mq_key, "")
        if v:
            q[json_key] = int(v)

    uncom = qstatus.get("UNCOM", "")
    if uncom:
        q["uncommitted"] = uncom == "YES"

    msgage = qstatus.get("MSGAGE", "").strip()
    if msgage:
        q["oldest_message_age"] = int(msgage)

    qtime = qstatus.get("QTIME", "")
    if qtime:
        parts = [p.strip() for p in qtime.split(",", 1)]
        if parts[0]:
            q["queue_time_short"] = int(parts[0])
        if len(parts) > 1 and parts[1]:
            q["queue_time_long"] = int(parts[1])

    for date_k, time_k, ts_key, elapsed_key in (
        ("LPUTDATE", "LPUTTIME", "last_put_timestamp", "last_put_elapsed_seconds"),
        ("LGETDATE", "LGETTIME", "last_get_timestamp", "last_get_elapsed_seconds"),
    ):
        ts = mq_to_iso(qstatus.get(date_k, ""), qstatus.get(time_k, ""))
        if ts:
            q[ts_key] = ts
            elapsed = elapsed_seconds(ts, now_epoch)
            if elapsed is not None:
                q[elapsed_key] = elapsed

    return q


def _build_doc(timestamp, hostname, qmgr, queue_fields):
    """Build a full ECS 8.11.0 metric document."""
    return {
        "@timestamp": timestamp,
        "ecs": {"version": "8.11.0"},
        "event": {"kind": "metric", "category": ["host"], "type": ["info"],
                  "module": "mq", "dataset": "mq.queue"},
        "data_stream": {"type": "metrics", "dataset": "mq.queue", "namespace": "default"},
        "host": {"name": hostname},
        "agent": {"name": "mq-metrics", "version": "2.0.0", "type": "mq-metrics"},
        "service": {"name": "ibm-mq", "type": "messaging"},
        "mq": {"queue_manager": {"name": qmgr}, "queue": queue_fields},
    }


def collect_qmgr(qmgr, config):
    """Collect metrics from one queue manager. Returns (docs, errors)."""
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    errors = 0
    exclude_re = config["exclude_re"]

    mqsc = "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH"
    if config["filter_websphere"]:
        mqsc += " WHERE(DESCR NL 'WebSphere MQ')"
    rc, raw = _runmqsc(qmgr, mqsc)
    if rc != 0 and not raw.strip():
        log.error("runmqsc DISPLAY QLOCAL failed for %s (rc=%d)", qmgr, rc)
        return [], 1
    qlocal_data = _parse_mqsc(raw, exclude_re, ("CURDEPTH", "MAXDEPTH"))

    qstatus_data = {}
    now_epoch = 0
    if config["advanced"]:
        now_epoch = int(time.time())
        rc, raw = _runmqsc(qmgr, "DISPLAY QSTATUS(*) TYPE(QUEUE) ALL")
        if rc != 0 and not raw.strip():
            log.error("runmqsc DISPLAY QSTATUS failed for %s (rc=%d)", qmgr, rc)
            errors += 1
        else:
            qstatus_data = _parse_mqsc(raw, exclude_re,
                ("LPUTDATE", "LPUTTIME", "LGETDATE", "LGETTIME",
                 "MSGAGE", "QTIME", "IPPROCS", "OPPROCS", "UNCOM"))

    docs = []
    for name, ql in qlocal_data.items():
        qf = _build_queue(name, ql, qstatus_data.get(name), config["advanced"], now_epoch)
        docs.append(_build_doc(timestamp, config["hostname"], qmgr, qf))
    return docs, errors


def send_bulk(docs, config):
    """Send docs to Elasticsearch Bulk API, or print to stdout in dry-run mode."""
    if not docs:
        log.info("No documents to send")
        return 0

    if not config["elastic_url"]:
        for doc in docs:
            print(json.dumps(doc))
        return 0

    lines = []
    for doc in docs:
        lines.append('{ "create": { } }')
        lines.append(json.dumps(doc))
    body = "\n".join(lines) + "\n"

    url = f"{config['elastic_url']}/{config['elastic_index']}/_bulk"
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST",
        headers={"Content-Type": "application/x-ndjson",
                 "Authorization": f"ApiKey {config['elastic_api_key']}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            if '"errors":true' in resp.read().decode("utf-8"):
                log.error("Bulk request returned with item-level errors (HTTP 200)")
                return 1
    except urllib.error.HTTPError as e:
        log.error("Bulk request failed - HTTP %d", e.code)
        return 1
    except urllib.error.URLError as e:
        log.error("Bulk request failed - %s", e.reason)
        return 1
    return 0


def main(argv=None):
    if argv is None:
        argv = sys.argv

    logging.basicConfig(format="%(asctime)s %(levelname)-5s %(message)s",
                        datefmt="%Y-%m-%dT%H:%M:%SZ", level=logging.INFO,
                        stream=sys.stderr)
    logging.Formatter.converter = time.gmtime

    env = os.environ.get
    qmgr_raw = argv[1] if len(argv) > 1 else env("MQ_METRICS_QMGR_LIST", "")
    config = {
        "elastic_url": env("MQ_METRICS_ELASTIC_URL", ""),
        "elastic_api_key": env("MQ_METRICS_ELASTIC_API_KEY", ""),
        "elastic_index": env("MQ_METRICS_ELASTIC_INDEX", "metrics-mq.queue-default"),
        "exclude_re": re.compile(env("MQ_METRICS_EXCLUDE_QUEUES", r"^SYSTEM\.|^AMQ\.")),
        "advanced": env("MQ_METRICS_ADVANCED", "") in ("1", "yes"),
        "filter_websphere": env("MQ_METRICS_FILTER_WEBSPHERE", "1") != "0",
        "hostname": socket.gethostname(),
    }

    log.info("mq-metrics starting")
    qmgrs = [q.strip() for q in qmgr_raw.split(",") if q.strip()] if qmgr_raw else discover_qmgrs()
    if not qmgrs:
        log.error("No running queue managers found")
        return 1

    log.info("Queue managers: %s", " ".join(qmgrs))

    total_queues = 0
    total_errors = 0
    all_docs = []
    for qm in qmgrs:
        log.info("Collecting metrics from %s", qm)
        docs, errs = collect_qmgr(qm, config)
        all_docs.extend(docs)
        total_queues += len(docs)
        total_errors += errs

    total_errors += send_bulk(all_docs, config)
    log.info("Done - %d queues collected, %d errors", total_queues, total_errors)
    return 1 if total_errors > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
