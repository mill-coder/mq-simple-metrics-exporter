# MQ Metrics

A lightweight Korn shell script that extracts metrics from IBM MQ queue managers and pushes them to Elasticsearch via the Bulk API.

## Target Environment

- **IBM MQ 9.3 LTS** on **AIX servers** (ksh88-compatible)
- Metrics collected via `runmqsc` (MQSC commands) -- zero dependencies beyond the MQ installation
- Each AIX host runs the script locally via cron, avoiding cross-zone firewall openings

## What It Collects

| Mode | MQSC Command | Metrics |
|------|-------------|---------|
| **Basic** (default) | `DISPLAY QLOCAL(*)` | Queue depth, max depth |
| **Advanced** (`MQ_METRICS_ADVANCED=1`) | + `DISPLAY QSTATUS(*)` | Depth %, input/output handles, uncommitted flag, oldest message age, queue time (short/long), last put/get timestamps, elapsed seconds since last put/get |

Output: one ECS 8.11.0 JSON document per queue, sent as a single `_bulk` request to Elasticsearch.

### Example Document (advanced mode)

```json
{
    "@timestamp": "2026-04-03T17:39:48Z",
    "ecs": { "version": "8.11.0" },
    "event": {
        "kind": "metric",
        "category": ["host"],
        "type": ["info"],
        "module": "mq",
        "dataset": "mq.queue"
    },
    "data_stream": {
        "type": "metrics",
        "dataset": "mq.queue",
        "namespace": "default"
    },
    "host": { "name": "aix-host-01" },
    "agent": { "name": "mq-metrics", "version": "2.0.0", "type": "mq-metrics" },
    "service": { "name": "ibm-mq", "type": "messaging" },
    "mq": {
        "queue_manager": { "name": "QM1" },
        "queue": {
            "name": "APP.ORDERS.IN",
            "type": "local",
            "depth": 17,
            "max_depth": 10000,
            "depth_percent": 0.17,
            "input_handles": 1,
            "output_handles": 2,
            "uncommitted": false,
            "oldest_message_age": 462,
            "queue_time_short": 12345,
            "queue_time_long": 67890,
            "last_put_timestamp": "2026-04-03T15:24:19Z",
            "last_get_timestamp": "2026-04-03T14:30:05Z",
            "last_put_elapsed_seconds": 8129,
            "last_get_elapsed_seconds": 11383
        }
    }
}
```

In basic mode (no `MQ_METRICS_ADVANCED`), `mq.queue` only contains `name`, `type`, `depth`, and `max_depth`.

## Quick Start

```bash
# Start the dev MQ container
podman compose up -d
./mq-config/seed-queues.sh

# Dry-run (prints JSON to stdout)
MQ_METRICS_QMGR_LIST=QM1 ./mq-metrics.ksh

# Dry-run with advanced metrics
MQ_METRICS_QMGR_LIST=QM1 MQ_METRICS_ADVANCED=1 ./mq-metrics.ksh

# Push to Elasticsearch
MQ_METRICS_ELASTIC_URL=https://elastic.corp:9200 \
MQ_METRICS_ELASTIC_API_KEY=<key> \
MQ_METRICS_QMGR_LIST=QM1 \
MQ_METRICS_ADVANCED=1 \
  ./mq-metrics.ksh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MQ_METRICS_ELASTIC_URL` | -- | Elasticsearch base URL (unset = dry-run to stdout) |
| `MQ_METRICS_ELASTIC_API_KEY` | -- | Elastic API key for authentication |
| `MQ_METRICS_ELASTIC_INDEX` | `metrics-mq.queue-default` | Target index / data stream |
| `MQ_METRICS_QMGR_LIST` | auto-discover via `dspmq` | Comma-separated QM names (also accepts `$1` positional arg) |
| `MQ_METRICS_EXCLUDE_QUEUES` | `^SYSTEM\.\|^AMQ\.` | Extended regex of queues to skip |
| `MQ_METRICS_ADVANCED` | off | Set to `1` to enable QSTATUS collection and derived fields |
| `MQ_METRICS_FILTER_WEBSPHERE` | `1` (on) | Set to `0` to disable `WHERE(DESCR NL 'WebSphere MQ')` filter |

## Project Structure

```
mq-metrics.ksh                # Main collector script (ksh88-compatible)
compose.yaml                  # Podman Compose: IBM MQ 9.3 LTS dev container
mq-config/
  20-queues.mqsc              # Custom queue definitions (auto-run on first start)
  seed-queues.sh              # Fills queues with random test messages
tests/
  Containerfile.ksh88         # Alpine + mksh container for ksh88 compatibility testing
  run-ksh88-tests.sh          # Orchestrator: builds container, runs tests, reports pass/fail
  mock-bin/                   # Mock executables (runmqsc, dspmq, curl, hostname)
  fixtures/                   # Canned runmqsc output for testing
docs/
  ksh88-compat-guidelines.md  # ksh88 compatibility rules and portable alternatives
  runmqsc-available-metrics.md
  runmqsc-output-parsing.md
  metrics-comparison.md
  ibm-mq-monitoring-methods.md
  future-improvements.md
```

## ksh88 Compatibility

The script targets AIX ksh88. Key constraints:

- No ksh arrays -- space-delimited strings instead
- No `typeset` in `name()` functions -- per-function variable prefixes (`_cq_`, `_pl_`, etc.)
- Escaped parentheses in parameter expansion patterns
- Temp file + redirect instead of piped `while read` loops

See `docs/ksh88-compat-guidelines.md` for the full guide.

## Testing

```bash
# ksh88 compatibility tests (runs in mksh container, no MQ needed)
./tests/run-ksh88-tests.sh

# Integration test against live MQ container
podman compose up -d
./mq-config/seed-queues.sh
MQ_METRICS_QMGR_LIST=QM1 MQ_METRICS_ADVANCED=1 ./mq-metrics.ksh
```

## Dev Endpoints

| Service | URL | Credentials |
|---------|-----|-------------|
| MQ Listener | `localhost:1414` | app / passw0rd |
| MQ Console | `https://localhost:9443/ibmmq/console/` | admin / passw0rd |
