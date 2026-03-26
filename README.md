# MQ Metrics

## Project Overview

A lightweight tooling application that extracts metrics from IBM MQ Manager instances and regularly pushes them into an Elastic Stack (Elasticsearch + Kibana).

## Target Environment

- **IBM MQ 9.3 LTS** ; capability to run on **AIX servers** (script written in Korn shell).
- **No Prometheus metrics endpoint** — the built-in `/metrics` feature is not available on all setups (AIX, ...).
- Metrics collected via **`runmqsc`** (MQSC commands) — runs locally on each AIX host, zero extra dependencies.

## Architecture

- **Source**: IBM MQ LTS — queue discovery and depth via `DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH` through `runmqsc`.
- **Sink**: Elasticsearch — authenticated via API key (`Authorization: ApiKey <encoded>`).
- **App**: `mq-metrics.ksh` — a Korn shell script that polls queue metrics and posts ECS-compliant JSON. Designed to run via cron on each host.
- **Output format**: Elastic Common Schema (ECS) 8.11.0 — documents land in a data stream named `metrics-mq.queue-<namespace>`.

## ECS Document Schema

Each queue produces one JSON document per collection run:

```json
{
  "@timestamp": "2026-03-26T21:50:55Z",
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
  "host": { "name": "<hostname>" },
  "agent": { "name": "mq-metrics", "version": "1.0.0", "type": "mq-metrics" },
  "service": { "name": "ibm-mq", "type": "messaging" },
  "mq": {
    "queue_manager": { "name": "QM1" },
    "queue": {
      "name": "APP.ORDERS.IN",
      "type": "local",
      "depth": 3,
      "max_depth": 10000
    }
  }
}
```

Key fields:
- `mq.queue.depth` — current message count (CURDEPTH)
- `mq.queue.max_depth` — queue capacity (MAXDEPTH)
- `mq.queue_manager.name` — identifies which QM the metric came from
- `host.name` — identifies which AIX host collected the metric
- `data_stream.*` — enables Elasticsearch data stream routing (`metrics-mq.queue-default`)

## Configuration

`mq-metrics.ksh` is configured via environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MQ_METRICS_ELASTIC_URL` | Yes | — | Elasticsearch base URL |
| `MQ_METRICS_ELASTIC_API_KEY` | Yes | — | Elastic API key (base64-encoded) |
| `MQ_METRICS_ELASTIC_INDEX` | No | `metrics-mq.queue-default` | Target index / data stream |
| `MQ_METRICS_QMGR_LIST` | No | auto-discover via `dspmq` | Comma-separated QM names |
| `MQ_METRICS_EXCLUDE_QUEUES` | No | `^SYSTEM\.\|^AMQ\.` | Regex of queues to skip |

When `MQ_METRICS_ELASTIC_URL` is unset, documents are printed to stdout (dry-run mode).

## Project Structure

```
mq-metrics.ksh                # Main collector script (ksh) — the deployable artifact
compose.yaml                  # Podman Compose: IBM MQ 9.3 LTS dev container
mq-config/
  20-queues.mqsc              # MQSC script: custom queue definitions (auto-run on first start)
  seed-queues.sh              # Shell script: fills queues with random test messages
```

## Local Development Environment

A Podman Compose setup provides an IBM MQ 9.3 LTS container (`icr.io/ibm-messaging/mq:9.3.0.25-r1`) that mirrors the production environment (without Prometheus metrics).

### Quick Start

```bash
# Start MQ container
podman compose up -d

# Wait for healthy, then seed queues with test data
./mq-config/seed-queues.sh

# Dry-run: print ECS JSON to stdout (runmqsc must be available, or use podman exec)
MQ_METRICS_QMGR_LIST=QM1 ./mq-metrics.ksh

# Push to Elasticsearch
MQ_METRICS_ELASTIC_URL=https://my-elastic:9200 \
MQ_METRICS_ELASTIC_API_KEY=<base64-encoded-key> \
MQ_METRICS_QMGR_LIST=QM1 \
  ./mq-metrics.ksh
```

### Dev Endpoints

| Service     | URL                                      | Credentials        |
|-------------|------------------------------------------|---------------------|
| MQ Listener | `localhost:1414`                         | app / passw0rd      |
| MQ Console  | `https://localhost:9443/ibmmq/console/`  | admin / passw0rd    |

### Dev Queues

Default dev queues (`DEV.QUEUE.1`-`3`, `DEV.DEAD.LETTER.QUEUE`) plus custom ones:
`APP.ORDERS.IN/OUT/DLQ`, `APP.PAYMENTS.IN/OUT/DLQ`, `APP.NOTIFY.EVENTS/ALERTS`, `APP.AUDIT.LOG`, `APP.BATCH.REQUESTS`.

## Metric Extraction Approach

The `runmqsc` + shell approach was chosen over alternatives:

| Approach | Verdict | Reason |
|----------|---------|--------|
| **`runmqsc` + ksh** | **Chosen** | Zero dependencies, runs locally on AIX, trivial to deploy |
| PCF (Java/Python) | Rejected | Requires JVM or Python runtime |
| MQ REST API | Rejected | Requires optional `mqm.web.rte` component + `mqweb` server |
| `amqsrua` | N/A | Does not expose queue depth (resource stats only) |
| Prometheus exporter | N/A | Not available on all setups |
