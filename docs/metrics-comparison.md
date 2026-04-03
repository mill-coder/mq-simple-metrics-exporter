# Metrics Comparison: Prometheus Exporter vs runmqsc

Comparison of metrics available from IBM MQ's built-in Prometheus exporter (CD containerized versions) versus what can be collected via `runmqsc` MQSC commands on any MQ 9.3 installation (including LTS on AIX).

---

## Summary

| Approach | Availability | Collection method | Output format |
|----------|-------------|-------------------|---------------|
| **Prometheus exporter** | CD container images only (`MQ_ENABLE_METRICS=true`, port 9157) | Pull-based HTTP scrape | Prometheus text format |
| **runmqsc** | All MQ installations (LTS, CD, AIX, Linux, Windows) | On-demand command execution | Text, requires parsing |
| **mq-metrics.ksh** (v2.0.0) | Anywhere `runmqsc` is available | Cron-scheduled ksh88 script | ECS JSON to Elasticsearch (Bulk API) |

---

## Queue Metrics

| Metric | Prometheus (`ibmmq_queue_*`) | runmqsc command | mq-metrics.ksh |
|--------|------------------------------|-----------------|----------------|
| Current depth | `ibmmq_queue_depth` | `DISPLAY QLOCAL(*) CURDEPTH` | Yes |
| Max depth | `ibmmq_queue_max_depth` | `DISPLAY QLOCAL(*) MAXDEPTH` | Yes |
| MQGET count | `ibmmq_queue_mqget_count` | `DISPLAY QSTATUS(*) TYPE(QUEUE)` (\*) | No |
| MQPUT count | `ibmmq_queue_mqput_count` | `DISPLAY QSTATUS(*) TYPE(QUEUE)` (\*) | No |
| MQPUT1 count | `ibmmq_queue_mqput1_count` | `DISPLAY QSTATUS(*) TYPE(QUEUE)` (\*) | No |
| Bytes retrieved (GET) | `ibmmq_queue_mqget_bytes` | Not directly available | No |
| Bytes put (PUT) | `ibmmq_queue_mqput_bytes` | Not directly available | No |
| Browse count | `ibmmq_queue_browse_count` | Not directly available | No |
| Expired messages | `ibmmq_queue_expired_message_count` | Not directly available | No |
| Purged messages | `ibmmq_queue_purged_message_count` | Not directly available | No |
| Persistent msg count | `ibmmq_queue_persistent_message_count` | Not directly available | No |
| Non-persistent msg count | `ibmmq_queue_non_persistent_message_count` | Not directly available | No |
| Open input processes | Not exposed | `DISPLAY QSTATUS(*) IPPROCS` | Yes (A) |
| Open output processes | Not exposed | `DISPLAY QSTATUS(*) OPPROCS` | Yes (A) |
| Oldest message age | `ibmmq_queue_oldest_message_age` (\*\*) | `DISPLAY QSTATUS(*) MSGAGE` | Yes (A) |
| Avg queue time (short) | `ibmmq_queue_qtime_short` (\*\*) | `DISPLAY QSTATUS(*) QTIME` | Yes (A) |
| Avg queue time (long) | `ibmmq_queue_qtime_long` (\*\*) | `DISPLAY QSTATUS(*) QTIME` | Yes (A) |
| Last GET date/time | Not exposed | `DISPLAY QSTATUS(*) LGETDATE LGETTIME` | Yes (A) |
| Last PUT date/time | Not exposed | `DISPLAY QSTATUS(*) LPUTDATE LPUTTIME` | Yes (A) |
| Uncommitted messages | Not exposed | `DISPLAY QSTATUS(*) UNCOM` | Yes (A) |

(\*) PUT/GET counts from `DISPLAY QSTATUS` are available as monitoring data only if `MONQ` is enabled on the queue or queue manager. They reflect activity since the QM started, not per-interval deltas.

(\*\*) Requires queue monitoring to be enabled (`ALTER QLOCAL(...) MONQ(MEDIUM)` or `MONQ(HIGH)`).

(A) Requires `MQ_METRICS_ADVANCED=1`. These fields come from `DISPLAY QSTATUS` which is only collected when advanced mode is enabled. Timestamp fields additionally require MONQ to be enabled on the queue manager.

---

## Queue Manager Metrics

| Metric | Prometheus (`ibmmq_qmgr_*`) | runmqsc command |
|--------|------------------------------|-----------------|
| QM status | `ibmmq_qmgr_status` | `DISPLAY QMSTATUS` |
| Connection count | `ibmmq_qmgr_connection_count` | `DISPLAY CONN(*) COUNT` (parse) |
| MQOPEN count | `ibmmq_qmgr_mqopen_count` | Not directly available |
| MQCLOSE count | `ibmmq_qmgr_mqclose_count` | Not directly available |
| MQGET count (global) | `ibmmq_qmgr_mqget_count` | Not directly available |
| MQPUT count (global) | `ibmmq_qmgr_mqput_count` | Not directly available |
| MQPUT1 count (global) | `ibmmq_qmgr_mqput1_count` | Not directly available |
| MQCONN count | `ibmmq_qmgr_mqconnect_count` | Not directly available |
| MQDISC count | `ibmmq_qmgr_mqdisconnect_count` | Not directly available |
| MQCOMMIT count | `ibmmq_qmgr_mqcommit_count` | Not directly available |
| MQROLLBACK count | `ibmmq_qmgr_mqrollback_count` | Not directly available |
| MQSUB count | `ibmmq_qmgr_mqsub_count` | Not directly available |
| Log utilization | `ibmmq_qmgr_log_*` | `DISPLAY QMSTATUS` (partial) |

The global MQI call counters (MQOPEN, MQGET, MQPUT, etc.) are published via system topics and consumed by the Prometheus exporter. They are **not** available through any `runmqsc` command.

---

## Channel Metrics

| Metric | Prometheus (`ibmmq_channel_*`) | runmqsc command |
|--------|--------------------------------|-----------------|
| Channel status | `ibmmq_channel_status` | `DISPLAY CHSTATUS(*) STATUS` |
| Bytes sent | `ibmmq_channel_bytes_sent` | `DISPLAY CHSTATUS(*) BYTSSENT` |
| Bytes received | `ibmmq_channel_bytes_received` | `DISPLAY CHSTATUS(*) BYTSRCVD` |
| Buffers sent | `ibmmq_channel_buffers_sent` | `DISPLAY CHSTATUS(*) BUFSSENT` |
| Buffers received | `ibmmq_channel_buffers_received` | `DISPLAY CHSTATUS(*) BUFSRCVD` |
| Batches completed | `ibmmq_channel_batches` | `DISPLAY CHSTATUS(*) BATCHES` |
| Messages / MQI calls | `ibmmq_channel_messages` | `DISPLAY CHSTATUS(*) MSGS` |
| Connection name | (label) | `DISPLAY CHSTATUS(*) CONNAME` |
| Channel type | (label) | `DISPLAY CHSTATUS(*) CHLTYPE` |
| Xmit queue time (short) | `ibmmq_channel_xmitq_time_short` | `DISPLAY CHSTATUS(*) XQTIME` |
| Xmit queue time (long) | `ibmmq_channel_xmitq_time_long` | `DISPLAY CHSTATUS(*) XQTIME` |
| Substate | Not exposed | `DISPLAY CHSTATUS(*) SUBSTATE` |
| SSL cipher | Not exposed | `DISPLAY CHSTATUS(*) SSLCIPH` |

Channel metrics have very good parity between the two approaches.

---

## Topic and Subscription Metrics

| Metric | Prometheus (`ibmmq_topic_*` / `ibmmq_sub_*`) | runmqsc command |
|--------|----------------------------------------------|-----------------|
| Publisher count | `ibmmq_topic_publisher_count` | `DISPLAY TPSTATUS(*) PUBCOUNT` |
| Subscriber count | `ibmmq_topic_subscriber_count` | `DISPLAY TPSTATUS(*) SUBCOUNT` |
| Publication count | `ibmmq_topic_publication_count` | Not directly available |
| Subscription msg count | `ibmmq_sub_message_count` | `DISPLAY SBSTATUS(*) NUMMSGS` |

---

## Connection Metrics

| Metric | Prometheus | runmqsc command |
|--------|-----------|-----------------|
| Connection list | Not exposed individually | `DISPLAY CONN(*) APPLTAG USERID CHANNEL` |
| Application name | Not exposed | `DISPLAY CONN(*) APPLTAG` |
| User ID | Not exposed | `DISPLAY CONN(*) USERID` |
| Connection type | Not exposed | `DISPLAY CONN(*) CONTYPE` |

Connection-level detail is a strength of `runmqsc` — the Prometheus exporter only surfaces an aggregate connection count at the QM level.

---

## Key Differences

### Prometheus exporter strengths
- **Global MQI counters**: MQOPEN/CLOSE/GET/PUT/COMMIT/ROLLBACK counts at QM level — not available via any MQSC command.
- **Byte-level queue metrics**: Bytes put/retrieved per queue.
- **Expiration and purge tracking**: Expired and purged message counts.
- **Automatic collection**: Pull-based, no cron scheduling needed.
- **Pre-formatted**: No text parsing required.

### runmqsc strengths
- **Universal availability**: Works on all platforms (AIX, Linux, Windows) and all MQ versions (LTS and CD).
- **Connection detail**: Per-connection application name, user ID, channel — not available in Prometheus.
- **Queue status detail**: IPPROCS, OPPROCS, LGETDATE/LPUTDATE, UNCOM — not exposed by Prometheus.
- **No extra components**: No exporter process, no HTTP port, no container requirement.
- **On-demand**: Can be triggered at any time, not tied to a scrape interval.

### Metrics only available via Prometheus
- Global MQI call counters (MQOPEN, MQCLOSE, MQGET, MQPUT, MQCONN, MQDISC, MQCOMMIT, MQROLLBACK at QM level)
- Per-queue byte counts (bytes put/retrieved)
- Expired / purged message counts
- Browse operation counts
- Persistent / non-persistent message breakdown

### Metrics only available via runmqsc (all now collected by mq-metrics.ksh with `ADVANCED=1`)
- Open input/output process counts (IPPROCS, OPPROCS) -- `mq.queue.input_handles`, `mq.queue.output_handles`
- Last GET/PUT timestamps (LGETDATE, LGETTIME, LPUTDATE, LPUTTIME) -- `mq.queue.last_get_timestamp`, `mq.queue.last_put_timestamp`
- Uncommitted message flag (UNCOM) -- `mq.queue.uncommitted`
- Per-connection detail (APPLTAG, USERID, CONTYPE) -- not yet collected
- Channel substate and SSL cipher details -- not yet collected

---

## Metrics Achievable in mq-metrics.ksh via runmqsc

The following metrics could be added to `mq-metrics.ksh` using additional MQSC commands, without any extra dependencies:

| Category | MQSC command | Key fields | Status |
|----------|-------------|------------|--------|
| Queue depth (current) | `DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH` | depth, max_depth | Implemented (always) |
| Queue activity | `DISPLAY QSTATUS(*) IPPROCS OPPROCS MSGAGE QTIME` | open handles, oldest msg, avg latency | Implemented (ADVANCED=1) |
| Queue timestamps | `DISPLAY QSTATUS(*) LGETDATE LGETTIME LPUTDATE LPUTTIME` | last activity times | Implemented (ADVANCED=1) |
| Queue uncommitted | `DISPLAY QSTATUS(*) UNCOM` | uncommitted flag | Implemented (ADVANCED=1) |
| Derived: depth_percent | computed from CURDEPTH/MAXDEPTH | queue fullness % | Implemented (ADVANCED=1) |
| Derived: elapsed seconds | computed from timestamps + epoch | time since last put/get | Implemented (ADVANCED=1) |
| Channel status | `DISPLAY CHSTATUS(*) STATUS BYTSSENT BYTSRCVD MSGS` | status, throughput | Not yet implemented |
| QM status | `DISPLAY QMSTATUS` | status, connection count | Not yet implemented |
| Connections | `DISPLAY CONN(*) APPLTAG USERID CHANNEL` | who is connected | Not yet implemented |
