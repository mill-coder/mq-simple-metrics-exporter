# IBM MQ Monitoring Methods — Comprehensive Reference

> Covers all standard, IBM, and select vendor-supported ways to collect **logs, metrics, and traces** from an IBM MQ cluster.

---

## Table of Contents

1. [Built-in IBM MQ Features](#1-built-in-ibm-mq-features)
2. [IBM Official Tools](#2-ibm-official-tools)
3. [Select Vendor Integrations](#3-select-vendor-integrations)
4. [Platform Support Matrix](#4-platform-support-matrix)
5. [Metric Coverage Matrix](#5-metric-coverage-matrix)
6. [Key Takeaways for AIX Environments](#6-key-takeaways-for-aix-environments)

---

## 1. Built-in IBM MQ Features

### 1.1 runmqsc (MQSC Commands)

| Attribute | Value |
|-----------|-------|
| **Min version** | All (available since earliest MQ releases) |
| **Distributions** | MQ for Multiplatforms, MQ for z/OS, MQ Appliance |
| **Components needed** | None — ships with every MQ installation |
| **Host types** | Bare metal, VM, containers |
| **OS** | AIX, Linux, Windows, z/OS, IBM i, Solaris, HP-UX |
| **Collects** | Metrics (point-in-time snapshots) |
| **Push / Pull** | Pull — run commands and parse text output |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | `DISPLAY QLOCAL`: CURDEPTH, MAXDEPTH, PUT/GET inhibit. `DISPLAY QSTATUS`: CURDEPTH, IPPROCS, OPPROCS, MSGAGE, LPUTDATE/LGETDATE, QTIME, UNCOM. `RESET QSTATS`: cumulative put/get counts and high water mark. |
| Channel | Full | `DISPLAY CHSTATUS`: STATUS, SUBSTATE, BYTSSENT, BYTSRCVD, MSGS, BATCHES, CURSHCNV, CONNAME, SSLPEER. |
| Queue Manager | Full | `DISPLAY QMSTATUS`: STATUS, CONNS, CHINIT, CMDSERV, PUBSUB, log info. `DISPLAY QMGR`: configuration attributes. |
| Resource | None | No CPU, memory, disk, or log I/O metrics. |
| Topic / Subscription | Full | `DISPLAY TPSTATUS`: publisher/subscriber count. `DISPLAY SBSTATUS`: subscription status, message count, topic string. |
| Listener | Full | `DISPLAY LSSTATUS`: status, port, backlog, PID, start date/time. |
| Application | Partial | `DISPLAY CONN`: connection handles, channel name, app tag, connection type. No per-connection MQI call counts or duration. |

**Limitations:** Text output requires parsing. Point-in-time snapshots only — no historical data. No resource-level metrics.

---

### 1.2 PCF (Programmable Command Format)

| Attribute | Value |
|-----------|-------|
| **Min version** | All (available since MQ v5.x) |
| **Distributions** | MQ for Multiplatforms, MQ for z/OS (partial), MQ Appliance (via client) |
| **Components needed** | MQ Client SDK — `com.ibm.mq.pcf` (Java), `pymqi`/`ibmmq` (Python), MQ C client (Go/C) |
| **Host types** | Bare metal, VM, containers |
| **OS** | Any platform with Java/Python/Go/C clients; z/OS QMs queryable remotely |
| **Collects** | Metrics |
| **Push / Pull** | Pull — PCF inquiry messages to `SYSTEM.ADMIN.COMMAND.QUEUE` |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full+ | `MQCMD_INQUIRE_Q_STATUS`: depth, max depth, open handles, oldest message age, queue time. `MQCMD_RESET_Q_STATS`: **cumulative put/get counts + high water mark** (resets on read). |
| Channel | Full | `MQCMD_INQUIRE_CHANNEL_STATUS`: status, bytes sent/received, messages, batches, CURSHCNV, SSL info. MQTT and AMQP variants. |
| Queue Manager | Full | `MQCMD_INQUIRE_Q_MGR_STATUS`: status, connection count, command server, channel initiator, pub/sub status, log info. |
| Resource | None | No CPU, memory, or disk I/O via PCF. |
| Topic / Subscription | Full | `MQCMD_INQUIRE_TOPIC_STATUS`, `MQCMD_INQUIRE_SUB_STATUS`, `MQCMD_INQUIRE_PUBSUB_STATUS`. |
| Listener | Full | `MQCMD_INQUIRE_LISTENER_STATUS`: status, port, backlog, start date. |
| Application | Partial | `MQCMD_INQUIRE_CONNECTION`: connected apps, channels, open objects. No per-connection MQI call counts. |

**Key advantage over runmqsc:** `RESET_Q_STATS` provides cumulative put/get counts. All responses are programmatically accessible (binary protocol, no text parsing). On z/OS, some PCF commands are restricted (e.g., `RESET QSTATS` not available).

---

### 1.3 MQ REST API (Administrative REST API)

| Attribute | Value |
|-----------|-------|
| **Min version** | 9.0.1 CD (initial), 9.1 LTS (GA) |
| **Distributions** | MQ for Multiplatforms (Linux, Windows, IBM i), MQ for z/OS (from 9.1), MQ Appliance |
| **Components needed** | `mqweb` server configured and running (`mqm.web.rte` component) |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, Windows, z/OS, IBM i. **Not available on AIX.** |
| **Collects** | Metrics and configuration |
| **Push / Pull** | Pull — HTTP GET/POST to mqweb endpoints |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | `/ibmmq/rest/v2/admin/qmgr/{qmgr}/queue`: depth, max depth, open handles, inhibit status. |
| Channel | Full | Channel configuration and status, bytes sent/received, messages, batches. |
| Queue Manager | Full | QM status, connection count, channel initiator, command server status. |
| Resource | None | No CPU, memory, disk, or log I/O endpoints. |
| Topic / Subscription | Partial | Topic and subscription resources available; status endpoints more limited than PCF. Progressively enhanced across 9.1–9.3. |
| Listener | Full | Listener configuration and status. |
| Application | None | No per-connection MQI call tracking. |

**Limitations:** Requires `mqweb` Liberty server running (extra overhead). **Not available on AIX.** The `/mqsc` endpoint can execute arbitrary MQSC as a fallback.

---

### 1.4 amqsrua (System Resource Usage — `$SYS/MQ` Topics)

| Attribute | Value |
|-----------|-------|
| **Min version** | 8.0 (basic), 8.0.0.4 (object type parameter), 9.1 (`-p` component selection) |
| **Distributions** | MQ for Multiplatforms, MQ Appliance. **Not z/OS** (uses SMF instead). |
| **Components needed** | `amqsrua` sample ships with MQ. Resource monitoring publications enabled by default. |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, Windows, AIX, other UNIX |
| **Collects** | Metrics (published every ~10 seconds via system topics) |
| **Push / Pull** | Pull (subscription-based) — subscribes to `$SYS/MQ/INFO/QMGR/…` |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | **STATQ** class: depth, open handles (browse/input/output/publish), average queue time, expired messages, per-queue put/get counts and bytes (persistent/non-persistent), failed get counts, rolled back puts/gets, purge counts. |
| Channel | None | No channel-specific metrics published to system topics. |
| Queue Manager | Full | **STATMQI** class: aggregate MQCONN/MQDISC, MQOPEN/MQCLOSE, MQPUT/MQGET counts and bytes, MQSUB/MQSUBRQ, commit/rollback, concurrent connection high water mark, subscription create/delete/alter, topic MQPUT counts. |
| Resource | **Full** | **CPU** class: user/system CPU time %, load averages (1/5/15 min), RAM total/free. **DISK** class: log bytes in use/max/archived, log write latency, log file system free/used, QM file system free/used, system volume free/used, FDC file count, trace file space. **NHAREPLICA** class (9.2+): replication backlog, compressed bytes, network RTT, synchronous log metrics. |
| Topic / Subscription | Partial | Aggregate subscription create/delete counts via STATMQI. No per-topic status. |
| Listener | None | No listener metrics published. |
| Application | Full | **STATAPP** class: per-application MQI usage stats (using `-o appname`). Tracks MQOPEN/MQCLOSE, MQPUT/MQGET, commit/rollback per specific application. |

**Key advantage:** Only built-in method providing CPU, memory, disk, and log I/O metrics. Published automatically at 10-second intervals.

---

### 1.5 Built-in Prometheus Metrics Endpoint (Container)

| Attribute | Value |
|-----------|-------|
| **Min version** | 9.1.5 (container images), enhanced in 9.3 and 9.4 |
| **Distributions** | MQ certified container images, MQ Operator (Kubernetes/OpenShift) only |
| **Components needed** | `MQ_ENABLE_METRICS=true` env var. `runmqserver` exposes `/metrics` on port 9157. |
| **Host types** | **Containers only** (Docker, Podman, Kubernetes, OpenShift) |
| **OS** | Linux (container runtime) |
| **Collects** | Metrics (Prometheus format) |
| **Push / Pull** | Pull — Prometheus scrapes `/metrics` endpoint |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | `ibmmq_queue_depth`, `ibmmq_queue_oldest_message_age`, `ibmmq_queue_input_handles`, `ibmmq_queue_output_handles`, queue time, time since put/get, uncommitted messages, per-queue put/get counts and bytes. |
| Channel | Full | `ibmmq_channel_status`, `ibmmq_channel_bytes_sent/received`, `ibmmq_channel_messages`, `ibmmq_channel_batches`, current/max instances, network time, transmission queue time. |
| Queue Manager | Full | `ibmmq_qmgr_status`, `ibmmq_qmgr_connection_count`, command server status, channel initiator status, active listeners/services, max channels, uptime, log extents. Aggregate MQI counts. |
| Resource | **Full** | CPU time %, load averages, RAM total/free, log bytes in use/written/latency, file system free/used, FDC file count. NHAREPLICA metrics for Native HA. |
| Topic / Subscription | Full | `ibmmq_topic_publisher_count`, `ibmmq_topic_subscriber_count`, `ibmmq_topic_messages_published/received`, `ibmmq_subscription_messages_received`, subscription type, topic string. |
| Listener | None | Not collected ([GitHub issue #183](https://github.com/ibm-messaging/mq-metric-samples/issues/183)). |
| Application | Partial | AMQP/MQTT client metrics. Per-app stats only if STATAPP class enabled. |

**Note:** Internally uses the same `mq-metric-samples` engine as the standalone Prometheus exporter (see 3.1). 200+ metrics available.

---

### 1.6 Event Messages

| Attribute | Value |
|-----------|-------|
| **Min version** | All |
| **Distributions** | MQ for Multiplatforms, MQ for z/OS, MQ Appliance |
| **Components needed** | Events enabled per type (`PERFMEV`, `CHLEV`, `CONFIGEV`, `CMDEV`, `AUTHOREV`). |
| **Host types** | Bare metal, VM, containers |
| **OS** | All supported MQ platforms |
| **Collects** | Events (threshold-triggered, not continuous metrics) |
| **Push / Pull** | Push — QM writes PCF messages to `SYSTEM.ADMIN.*.EVENT` queues |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Partial | **Queue Depth Events**: depth high, depth low, queue full. **Queue Service Interval Events**: high/OK. **Inhibit Events**: put/get inhibited. Threshold-triggered only. |
| Channel | Partial | **Channel Events**: started, stopped, not activated, auto-def error, conversion error, SSL error. Status changes only, not continuous metrics. |
| Queue Manager | Partial | QM active/standby events. **Command Events**: records every MQSC/PCF command issued. **Configuration Events**: object create/change/delete. |
| Resource | None | No resource usage events. |
| Topic / Subscription | None | No topic or subscription events. |
| Listener | None | No listener-specific events. |
| Application | Partial | **Authority Events**: authorization failures per application. Inhibit events. No MQI call counts. |

**Key characteristic:** Event-driven, not periodic. Best for alerting on threshold breaches and audit trails, not continuous metric collection.

---

### 1.7 Accounting & Statistics Messages

| Attribute | Value |
|-----------|-------|
| **Min version** | 6.0 (distributed platforms) |
| **Distributions** | MQ for Multiplatforms only. **Not z/OS** (uses SMF), **not IBM i** (limited). |
| **Components needed** | Enable via QM attributes: `ACCTMQI(ON)`, `ACCTQ(ON)`, `STATMQI(ON)`, `STATQ(ON)`, `STATCHL(ON)`. |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, AIX, Windows, Solaris, HP-UX |
| **Collects** | Metrics (detailed, periodic). Written at configurable intervals (`STATINT`/`ACCTINT`, default 1800s). |
| **Push / Pull** | Push — QM writes PCF messages to `SYSTEM.ADMIN.ACCOUNTING.QUEUE` and `SYSTEM.ADMIN.STATISTICS.QUEUE` |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | **Queue Statistics** (`STATQ`): per-queue put/get counts and bytes (persistent/non-persistent), MQOPEN/MQCLOSE counts, browse counts, failed operations, high water mark depth. **Queue Accounting** (`ACCTQ`): same metrics broken down per application connection. |
| Channel | Full | **Channel Statistics** (`STATCHL`): per-channel bytes sent/received, messages, batches, network time, average batch size. |
| Queue Manager | Full | **MQI Statistics** (`STATMQI`): aggregate MQCONN/MQDISC, MQOPEN/MQCLOSE, MQPUT/MQGET counts, commit/rollback, subscription operations. |
| Resource | None | No CPU, memory, or disk metrics. |
| Topic / Subscription | Partial | Aggregate subscription and topic put counts in MQI statistics. No per-topic breakdown. |
| Listener | None | No listener metrics. |
| Application | **Full** | **MQI Accounting** (`ACCTMQI`): per-connection MQI call counts (MQOPEN, MQCLOSE, MQPUT, MQGET, MQINQ, MQSET, MQSUB, commit, rollback). **Queue Accounting** (`ACCTQ`): per-connection per-queue put/get counts, bytes, message sizes. Written at MQDISC or at ACCTINT interval. |

**Key advantage:** Primary method for **per-application, per-connection** MQI call counts and per-queue breakdowns. Statistics = aggregate counters; accounting = per-connection detail.

---

### 1.8 Activity Trace

| Attribute | Value |
|-----------|-------|
| **Min version** | 7.0 (distributed platforms) |
| **Distributions** | MQ for Multiplatforms only. **Not z/OS** (uses GTF/SMF). |
| **Components needed** | Configure `mqat.ini` or enable `ACTVTRC(ON)` on QM. |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, AIX, Windows |
| **Collects** | Traces (per-MQI-call level) |
| **Push / Pull** | Push — trace messages to `SYSTEM.ADMIN.TRACE.ACTIVITY.QUEUE` |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Indirect | Traces show which queues are accessed, with parameters and return codes. Not aggregated. |
| Channel | Indirect | Channel-related operations visible. Not aggregated channel metrics. |
| Queue Manager | None | No QM status metrics — only connection/disconnection events. |
| Resource | None | No resource usage metrics. |
| Topic / Subscription | Indirect | MQSUB, MQSUBRQ calls and topic opens visible. |
| Listener | None | No listener metrics. |
| Application | **Full** | Every MQI call recorded: MQCONN/X, MQDISC, MQOPEN, MQCLOSE, MQPUT, MQPUT1, MQGET, MQINQ, MQSET, MQSUB, MQSUBRQ, MQCB, MQCTL — with full parameters, return codes, object names, timestamps. |

**Limitations:** Extremely verbose — meant for debugging, not continuous monitoring. Must be targeted via `mqat.ini` rules to avoid performance impact.

---

### 1.9 Error Logs (File-based)

| Attribute | Value |
|-----------|-------|
| **Min version** | All |
| **Distributions** | All (Multiplatforms, z/OS, Appliance) |
| **Components needed** | None — always written |
| **Host types** | Bare metal, VM, containers |
| **OS** | All |
| **Collects** | Logs |
| **Push / Pull** | Pull — tail/ship `AMQERR01-03.LOG` files from `<QM_data_dir>/errors/` |

Can be ingested by any log shipper (Filebeat, Fluentd, Splunk forwarder, etc.). Provides error codes, descriptions, explanations, and recommended actions. Not metrics.

---

### 1.10 SMF Records (z/OS Only — Type 115 / 116)

| Attribute | Value |
|-----------|-------|
| **Min version** | All MQ for z/OS versions |
| **Distributions** | **MQ for z/OS only** |
| **Components needed** | SMF recording enabled. `STATSTC`/`STATCHL`/`STATIME` system parameters. |
| **Host types** | z/OS mainframe |
| **OS** | z/OS |
| **Collects** | Metrics (richest dataset on any MQ platform) |
| **Push / Pull** | Push — MQ writes SMF records to SMF datasets/logstreams |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | SMF 116 subtypes 0/1/2: per-queue put/get counts, bytes, message sizes, CPU cost per MQI call per queue, messages by persistence, messages read from disk, expired messages, messages skipped. |
| Channel | Full | SMF 116 subtype 10: per-channel bytes sent/received, batch counts, messages. SMF 115 subtype 231: channel initiator statistics. |
| Queue Manager | Full | SMF 115 subtypes 1/2: Storage Manager, Log Manager, Buffer Manager, Message Manager, Data Manager, Coupling Facility Manager, DB2 Manager, Topic Manager, Lock Manager statistics. |
| Resource | **Full** | Log write rates, log buffer usage, checkpoint frequency, buffer pool stats (hits/misses, page I/O), virtual storage usage, Coupling Facility statistics. CPU usage per task in SMF 116. |
| Topic / Subscription | Full | Topic Manager statistics. Subscription/publish counts in MQI accounting. |
| Listener | None | No dedicated listener SMF records. |
| Application | **Full** | SMF 116 subtypes 0/1/2: per-task per-queue MQI call counts, **CPU time per call**, elapsed time, thread-level detail. The most detailed per-application accounting on any MQ platform. |

**Key advantage:** Includes CPU cost per MQI call, buffer pool hit ratios, Coupling Facility performance, and log manager internals — not available on distributed platforms.

---

### 1.11 OpenTelemetry Native (9.4+)

| Attribute | Value |
|-----------|-------|
| **Min version** | 9.4.0 (trace context propagation), 9.4.3 (native OTel Tracing Service on Appliance/z/OS) |
| **Distributions** | MQ for Multiplatforms (9.4+), MQ for z/OS (9.4.3+), MQ Appliance (9.4.3+) |
| **Components needed** | OTel trace context via message properties. Client libraries: Python `ibmmq` v2.0.2+ (MQ 9.4.5), Node.js, Go, C/C++, Java. |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, Windows, z/OS, Appliance. **Not AIX (no confirmed support).** |
| **Collects** | Traces (distributed tracing of message flows). Metrics via `mq_opentelem` exporter (see 3.1). |
| **Push / Pull** | Push — traces exported to OTel Collector or backend |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full (via mq_otel) | Same as mq-metric-samples exporter. |
| Channel | Full (via mq_otel) | Same as mq-metric-samples exporter. |
| Queue Manager | Full (via mq_otel) | Same as mq-metric-samples exporter. |
| Resource | Full (via mq_otel) | CPU, memory, disk, log metrics from system topics. |
| Topic / Subscription | Full (via mq_otel) | Topic and subscription metrics. |
| Listener | None | Same gap as mq-metric-samples. |
| Application | Partial | Native OTel Tracing Service provides per-message latency and path tracing. Not aggregated MQI call counts. |

**Key distinction:** The native 9.4 tracing produces **distributed trace spans**, not metrics. Metric collection relies on the `mq-metric-samples` / `mq_opentelem` exporter.

---

### 1.12 SNMP (MQ Appliance Only)

| Attribute | Value |
|-----------|-------|
| **Min version** | MQ Appliance 9.0.1 CD |
| **Distributions** | **MQ Appliance hardware only** (M2001, M2002, M2003) |
| **Components needed** | SNMP configured on appliance. Supports SNMPv1, v2c, v3. Traps from firmware 9.1.3+. |
| **Host types** | MQ Appliance hardware |
| **OS** | Appliance firmware |
| **Collects** | Infrastructure metrics + event traps |
| **Push / Pull** | Both — SNMP polling (pull) and SNMP traps (push) |

Covers CPU, memory, disk, network at the appliance level. **Does not expose MQ object metrics** (queues, channels) — those still require PCF/runmqsc. Not available on MQ software installations.

---

### 1.13 MQ Explorer

| Attribute | Value |
|-----------|-------|
| **Min version** | 6.0+ (Eclipse-based) |
| **Distributions** | Connects to any QM on any platform |
| **Components needed** | MQ Explorer on Windows or Linux workstation |
| **Host types** | Runs on admin workstation, connects remotely |
| **OS** | Explorer runs on Windows/Linux. Manages QMs on any platform. |
| **Collects** | Interactive real-time display (queue depths, channel status, QM status) |
| **Push / Pull** | Pull — interactive GUI |

**Not a monitoring tool** — no alerting, no historical data, no dashboards. Manual inspection only. Not suitable for automated monitoring.

---

## 2. IBM Official Tools

### 2.1 IBM Instana

| Attribute | Value |
|-----------|-------|
| **Min version** | MQ 7.5+ (sensor auto-discovers) |
| **Distributions** | MQ for Multiplatforms, MQ in containers/Kubernetes, Cloud Pak for Integration. z/OS via remote monitoring. |
| **Components needed** | Instana agent on MQ host. MQ sensor auto-configures. Native trace support from MQ 9.3.5+; OTel trace from 9.4+. |
| **Host types** | Bare metal, VM, containers, Kubernetes |
| **OS** | Linux, Windows. AIX = remote monitoring only. z/OS = remote collection. |
| **Collects** | Metrics (1-second granularity) + Traces |
| **Push / Pull** | Push — agent collects and pushes to Instana backend |
| **License** | Commercial IBM product |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | Depth, max depth, open handles, oldest message age, put/get counts. |
| Channel | Full | Status, bytes sent/received, messages, batches, current connections. |
| Queue Manager | Full | Status, connection count, command server, channel initiator. |
| Resource | Partial | Some resource metrics via system topics (agent config dependent). |
| Topic / Subscription | Full | Topic status, subscriber count, publication metrics. |
| Listener | Full | Listener status with health events. |
| Application | Full | Distributed tracing correlating MQ operations with app traces — per-app call patterns, latency, error rates. |

**Key advantage:** Auto-discovery, 1-second granularity, distributed tracing, built-in alerting.

---

### 2.2 IBM Cloud Pak for Integration Monitoring

| Attribute | Value |
|-----------|-------|
| **Min version** | Cloud Pak for Integration 2020.x+ (MQ 9.1+ operators) |
| **Distributions** | MQ deployed via MQ Operator on OpenShift/Kubernetes only |
| **Components needed** | OpenShift 4.6+. Built-in Prometheus + Grafana. Optional Instana integration. |
| **Host types** | **Containers on OpenShift/Kubernetes only** |
| **OS** | Linux (OpenShift) |
| **Collects** | Metrics (Prometheus-format), logs (container stdout/stderr), alerts |
| **Push / Pull** | Pull (Prometheus scrapes metrics endpoint) |

Not applicable to traditional MQ on AIX, Windows bare metal, or z/OS.

---

## 3. Select Vendor Integrations

### 3.1 IBM mq-metric-samples (Prometheus / OTel / JSON / CloudWatch / InfluxDB Exporters)

| Attribute | Value |
|-----------|-------|
| **Min version** | MQ 8.0+ (9.1 recommended) |
| **Distributions** | MQ for Multiplatforms, MQ for z/OS (remote only) |
| **Components needed** | Go binary from [ibm-messaging/mq-metric-samples](https://github.com/ibm-messaging/mq-metric-samples). IBM MQ Client SDK (C libraries). Exporters: `mq_prometheus`, `mq_opentelem`, `mq_json`, `mq_aws`, `mq_influx`. |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux (x64, ARM64), Windows (x64). **Not AIX** (no Go compiler — must use client mode from Linux/Win). Can monitor z/OS QMs remotely. |
| **Collects** | Metrics (200+) |
| **Push / Pull** | Prometheus = pull (scrape on port 9157). OTel/CloudWatch/InfluxDB = push. |
| **License** | Open source, provided as-is (no IBM PMR support) |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | Depth, max depth, oldest message age, open handles, queue time (long/short), time since put/get, uncommitted messages, per-queue put/get counts and bytes (persistent/non-persistent), browse counts, failed ops, expired messages, lock contention, purge count. |
| Channel | Full | Status, substatus, bytes sent/received, buffers sent/received, batches, batch size, network time, transmission queue time, current/max instances, messages, connection name, time since message. |
| Queue Manager | Full | Status, uptime, connection count, channel initiator, command server, active listeners/services, max channels, log extents (archive/current/media/restart/reusable), aggregate MQI counts, published-to-subscribers counts. |
| Resource | **Full** | CPU (user/system %, load averages), RAM (total/free), Disk (log bytes in use/max/archived, log write latency/size, QM/system/log file system free/used, FDC file count, trace file space). NHAREPLICA (replication backlog, compressed bytes, network RTT). |
| Topic / Subscription | Full | Per-topic: publisher/subscriber count, messages published/received, time since last message. Per-subscription: messages received, time since message, topic string, type. |
| Listener | None | Not collected ([GitHub issue #183](https://github.com/ibm-messaging/mq-metric-samples/issues/183)). |
| Application | Partial | AMQP/MQTT client metrics. STATAPP per-app stats if enabled. |

**Same engine** as the built-in container Prometheus endpoint (1.5).

---

### 3.2 Elastic Beats (Filebeat + Metricbeat)

| Attribute | Value |
|-----------|-------|
| **Min version** | 9.1+ (Metricbeat) / All (Filebeat) |
| **Distributions** | MQ for Multiplatforms (containerized for Metricbeat) |
| **Components needed** | **Metricbeat** `ibmmq` module (beta): scrapes Prometheus endpoint (port 9157, requires `MQ_ENABLE_METRICS=true`). **Filebeat** `ibmmq` module: parses QM error log files. |
| **Host types** | Filebeat: any host with MQ error logs. Metricbeat: containers. |
| **OS** | Linux, Windows (Filebeat for logs). Linux containers (Metricbeat for metrics). |
| **Collects** | Logs (Filebeat) + Metrics (Metricbeat) |
| **Push / Pull** | Pull (Metricbeat scrapes Prometheus; Filebeat tails logs) then push to Elasticsearch |

**Metric coverage (Metricbeat `qmgr` metricset):**

| Category | Support | Details |
|----------|---------|---------|
| Queue | None | `qmgr` metricset only. Per-queue metrics require custom PCF metricset or Elastic IBM MQ Integration. |
| Channel | None | Not in standard `qmgr` metricset. |
| Queue Manager | Full | MQOPEN/MQCLOSE/MQCONN/MQDISC/MQPUT/MQGET/MQINQ/MQSET/MQCTL/MQCB/MQSTAT/MQSUBRQ counts, persistent/non-persistent put/get bytes, browse counts, topic put ops, subscription create/delete, commit/rollback, log bytes written, failed ops. |
| Resource | None | Not in `qmgr` metricset. |
| Topic / Subscription | Partial | Aggregate topic put counts and subscription create/delete counts. No per-topic breakdown. |
| Listener | None | Not collected. |
| Application | None | Not collected. |

**Key limitation:** Requires containerized MQ with Prometheus endpoint. Only collects aggregate QM-level metrics, not per-queue or per-channel. Filebeat provides logs (error code, description, explanation, action) but no metrics.

---

### 3.3 MQGem MO71

| Attribute | Value |
|-----------|-------|
| **Min version** | All MQ versions |
| **Distributions** | Connects to any MQ QM (Multiplatforms, z/OS, Appliance) |
| **Components needed** | MO71 Windows GUI. Client connection to each QM. |
| **Host types** | Runs on admin workstation, connects remotely to any host type |
| **OS** | MO71 runs on Windows. Manages QMs on AIX, Linux, Windows, z/OS, Appliance. |
| **Collects** | Metrics (real-time) + interactive administration |
| **Push / Pull** | Pull — PCF/MQSC queries on demand |
| **License** | Commercial (MQGem Software) |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | Depth, max depth, open handles, oldest message age, put/get counts (via RESET QSTATS), inhibit status, queue time. Visual depth monitoring with threshold alerts. |
| Channel | Full | Status/substatus, bytes sent/received, messages, batches, connections. Network view. Trace-route visualization. |
| Queue Manager | Full | Status, connection count, command server, channel initiator, pub/sub status. Multi-QM health checks. |
| Resource | None | Admin GUI — no CPU, memory, or disk metrics. |
| Topic / Subscription | Full | Topic status, subscription browsing. Topic string validation. |
| Listener | Full | Listener status, port, backlog. |
| Application | Partial | Connection display (app names, channels, open handles). Activity trace viewer. No continuous per-app metric collection. |

**Key advantage:** Full graphical management + monitoring. Health check engine validates cross-QM object resolution.

---

### 3.4 MQGem MQEV

| Attribute | Value |
|-----------|-------|
| **Min version** | All MQ versions |
| **Distributions** | MQ for Multiplatforms |
| **Components needed** | MQEV background service. Consumes event/accounting/statistics queues. Can emit data to HTTP endpoints (e.g., Elasticsearch via GetPost). |
| **Host types** | Bare metal, VM, containers |
| **OS** | Linux, Windows, AIX |
| **Collects** | Events + Metrics (from event/accounting/statistics messages) |
| **Push / Pull** | Pull (from MQ event queues) + Push (to HTTP endpoints) |
| **License** | Commercial (MQGem Software) |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | From Queue Statistics: per-queue put/get counts, bytes, depth high water mark. From Queue Accounting: per-application per-queue breakdown. From Events: depth high/low/full. |
| Channel | Full | From Channel Statistics: bytes sent/received, messages, batches, network time. From Channel Events: started/stopped/error. |
| Queue Manager | Full | From MQI Statistics: aggregate MQI call counts. From QM Events: active/standby, command events, configuration events. Authority events. |
| Resource | None | Does not consume system topic resource metrics. |
| Topic / Subscription | Partial | Aggregate subscription/topic counts from MQI statistics. Topic data from accounting messages. |
| Listener | None | No listener-specific event processing. |
| Application | **Full** | From MQI Accounting: per-connection MQI call counts. From Queue Accounting: per-connection per-queue detail. Aggregation for trend analysis and capacity planning. |

**Key advantage:** Persistent storage and searchable history of event/accounting/statistics data. Aggregation for capacity planning.

---

### 3.5 BMC MainView Middleware Monitor (MVMM)

| Attribute | Value |
|-----------|-------|
| **Min version** | All MQ versions |
| **Distributions** | MQ for Multiplatforms, MQ for z/OS |
| **Components needed** | BMC agents with MQ extensions. Uses PCF + SMF data (z/OS). |
| **Host types** | Bare metal, VM, containers, z/OS mainframe |
| **OS** | Linux, Windows, z/OS |
| **Collects** | Metrics + Events |
| **Push / Pull** | Pull (agent queries MQ) + Push (to BMC backend) |
| **License** | Commercial (BMC) |

**Metric coverage:**

| Category | Support | Details |
|----------|---------|---------|
| Queue | Full | Depth, max depth, open handles, message throughput, put/get ops, aging metrics. |
| Channel | Full | All channel types. Batch sizes, compression rates, message counts, connections, short/long-term averages. |
| Queue Manager | Full | Status, CPU usage, message counts, connections. z/OS: buffer pool, Coupling Facility, DB2 integration. |
| Resource | Full (z/OS) | z/OS: buffer pool, Coupling Facility, log usage, storage manager (from SMF 115). Distributed: more limited. |
| Topic / Subscription | Full | Publication scope, subscriber counts, persistence settings, selector types, multicast reliability. |
| Listener | Full | Listener status via agent discovery. |
| Application | Full | From SMF 116 (z/OS) or accounting messages (distributed): per-connection per-queue MQI calls, CPU per call, message sizes. Cross-middleware transaction tracing. |

**Key advantage:** Enterprise-grade with SLA validation, automated problem detection, historical trending. Strongest on z/OS with SMF data.

---

## 4. Platform Support Matrix

| Method | AIX | z/OS | Linux | Windows | Containers | Min Version |
|--------|:---:|:----:|:-----:|:-------:|:----------:|:-----------:|
| runmqsc | Yes | Yes | Yes | Yes | Yes | All |
| PCF | Yes | Yes\* | Yes | Yes | Yes | All |
| REST API | **No** | Yes | Yes | Yes | Yes | 9.0.1 |
| amqsrua | Yes | **No** | Yes | Yes | Yes | 8.0 |
| Prometheus endpoint | **No** | **No** | **No** | **No** | **Yes** | 9.1.5 |
| Event Messages | Yes | Yes | Yes | Yes | Yes | All |
| Acct & Stats Messages | Yes | **No** | Yes | Yes | Yes | 6.0 |
| Activity Trace | Yes | **No** | Yes | Yes | Yes | 7.0 |
| Error Logs | Yes | Yes | Yes | Yes | Yes | All |
| SMF Records | **No** | **Yes** | **No** | **No** | **No** | All |
| OpenTelemetry native | **No** | Yes | Yes | Yes | Yes | 9.4.0 |
| SNMP | **No** | **No** | **No** | **No** | **No** | Appliance 9.0.1 |
| MQ Explorer | N/A | N/A | Yes | Yes | N/A | 6.0 |
| Instana | Remote | Remote | Yes | Yes | Yes | 7.5 |
| Cloud Pak | **No** | **No** | **Yes** | **No** | **Yes** | MQ Operator |
| mq-metric-samples | **No**\*\* | Remote | Yes | Yes | Yes | 8.0+ |
| Elastic Beats | Filebeat | **No** | Yes | Yes | Yes | 9.1 |
| MQGem MO71 | Remote | Remote | Remote | Yes | Remote | All |
| MQGem MQEV | Yes | **No** | Yes | Yes | Yes | All |
| BMC MVMM | **No** | Yes | Yes | Yes | Yes | All |

\* z/OS: some PCF commands restricted.
\*\* No Go compiler on AIX — must run exporter on Linux/Windows connecting remotely via client channel.
"Remote" = monitors MQ on that platform via remote client connection.

---

## 5. Metric Coverage Matrix

| Method | Queue | Channel | QM | Resource | Topic/Sub | Listener | Application |
|--------|:-----:|:-------:|:--:|:--------:|:---------:|:--------:|:-----------:|
| runmqsc | Full | Full | Full | -- | Full | Full | Partial |
| PCF | Full+ | Full | Full | -- | Full | Full | Partial |
| REST API | Full | Full | Full | -- | Partial | Full | -- |
| amqsrua | Full | -- | Full | **Full** | Partial | -- | Full |
| Prometheus endpoint | Full | Full | Full | **Full** | Full | -- | Partial |
| Event Messages | Partial | Partial | Partial | -- | -- | -- | Partial |
| Acct & Stats Messages | Full | Full | Full | -- | Partial | -- | **Full** |
| Activity Trace | Indirect | Indirect | -- | -- | Indirect | -- | **Full** |
| Error Logs | -- | -- | -- | -- | -- | -- | -- |
| SMF Records (z/OS) | Full | Full | Full | **Full** | Full | -- | **Full** |
| OTel Native (9.4+) | Full\* | Full\* | Full\* | **Full**\* | Full\* | -- | Partial |
| SNMP (Appliance) | -- | -- | -- | Partial | -- | -- | -- |
| Instana | Full | Full | Full | Partial | Full | Full | Full |
| Cloud Pak | Full | Full | Full | **Full** | Full | -- | Partial |
| mq-metric-samples | Full | Full | Full | **Full** | Full | -- | Partial |
| Elastic Metricbeat | -- | -- | Full | -- | Partial | -- | -- |
| MQGem MO71 | Full | Full | Full | -- | Full | Full | Partial |
| MQGem MQEV | Full | Full | Full | -- | Partial | -- | **Full** |
| BMC MVMM | Full | Full | Full | Full(z/OS) | Full | Full | Full |

**Legend:**
- **Full** — covers all or nearly all metrics in that category
- **Full+** — includes `RESET QSTATS` for cumulative put/get (PCF advantage)
- **Full\*** — metrics via `mq_opentelem` exporter; native part is traces only
- **Partial** — covers some metrics with significant gaps
- **Indirect** — raw data available but requires post-processing
- **--** — not supported

---

## 6. Key Takeaways for AIX Environments

For IBM MQ 9.3 LTS on AIX with no Prometheus endpoint, the viable options are:

| Method | Runs natively on AIX | Best for |
|--------|:-------------------:|----------|
| **runmqsc + ksh** | Yes | Zero-dependency queue depth collection |
| **PCF** (Java/Python/C) | Yes (if runtime available) | Structured queries, cumulative put/get counts |
| **amqsrua** | Yes | **CPU, memory, disk, log I/O metrics** (only source on AIX) |
| **Acct & Stats Messages** | Yes | **Per-application MQI call counts** (gold standard) |
| **Event Messages** | Yes | Threshold alerting (depth high/low/full) |
| **Activity Trace** | Yes | Per-application debugging (short-term) |
| **Error Logs** | Yes | Ship via Filebeat/Fluentd |
| **MQGem MQEV** | Yes | Persistent event/stats storage + capacity planning |
| **MQGem MO71** | Remote (Windows GUI) | Interactive admin + monitoring |
| **mq-metric-samples** | Remote only | Prometheus/OTel metrics (run on Linux, connect via client channel) |

**Gaps in the `runmqsc` approach:**
1. **No resource metrics** — CPU, memory, disk, log I/O only available via `amqsrua` / system topics.
2. **No cumulative put/get counts** — requires `RESET QSTATS` (via runmqsc or PCF).
3. **No per-application breakdown** — requires Accounting & Statistics Messages.
