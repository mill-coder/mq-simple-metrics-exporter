# Metrics Available via runmqsc

Comprehensive reference of all metrics retrievable from IBM MQ using `runmqsc` MQSC commands. Tested against MQ 9.3.0.25 (Linux container, same command set as AIX).

---

## 1. `DISPLAY QSTATUS(*) TYPE(QUEUE)` -- Runtime Queue Metrics

The primary command for operational monitoring. Returns live runtime status per queue.

```
echo "DISPLAY QSTATUS(*) TYPE(QUEUE) ALL" | runmqsc QM1
```

| Attribute | Type | Description | Requires MONQ | Implemented |
|-----------|------|-------------|:---:|:---:|
| **CURDEPTH** | int | Current message count (committed + uncommitted) | No | Yes (A) |
| **IPPROCS** | int | Open input handles (consumers) | No | Yes (A) |
| **OPPROCS** | int | Open output handles (producers) | No | Yes (A) |
| **UNCOM** | string | Uncommitted changes pending: `YES` or `NO` | No | Yes (A) |
| **LPUTDATE** | string | Date of last MQPUT: `YYYY-MM-DD` or single space when no data | Yes | Yes (A) |
| **LPUTTIME** | string | Time of last MQPUT: `HH.MM.SS` (dots, not colons) or single space | Yes | Yes (A) |
| **LGETDATE** | string | Date of last MQGET: `YYYY-MM-DD` or single space | Yes | Yes (A) |
| **LGETTIME** | string | Time of last MQGET: `HH.MM.SS` or single space | Yes | Yes (A) |
| **MSGAGE** | int | Age in seconds of the oldest message on the queue. `0` for empty queues, single space when MONQ off | Yes | Yes (A) |
| **QTIME** | pair | Avg time (microseconds) messages spend on queue. Two values: short-term, long-term. Format: `QTIME(12345, 67890)` or `QTIME( , )` when empty | Yes | Yes (A) |

> **(A)** = Requires `MQ_METRICS_ADVANCED=1`. QSTATUS collection is opt-in.
| **MONQ** | string | Monitoring level: `OFF`, `LOW`, `MEDIUM`, `HIGH` | N/A | No |
| **MEDIALOG** | string | Oldest log extent needed for media recovery | No | No |
| **CURFSIZE** | int | Current queue file size (bytes) -- MQ 9.1.5+ | No | No |
| **CURMAXFS** | int | Current maximum file size for the queue -- MQ 9.1.5+ | No | No |

### MONQ Prerequisite

Attributes marked "Requires MONQ = Yes" return **blank values** (single space) unless queue monitoring is enabled.

Enable at queue manager level (applies to all queues with default `MONQ(QMGR)`):

```
ALTER QMGR MONQ(LOW)
```

Or per-queue:

```
ALTER QLOCAL(APP.ORDERS.IN) MONQ(LOW)
```

### MONQ Performance Impact

| Level | Recalculation frequency | Impact |
|-------|------------------------|--------|
| **LOW** | Every ~64 messages | Minimal -- recommended for cron-based polling |
| **MEDIUM** | Every ~8 messages | Limited |
| **HIGH** | Every message | Possible impact on high-throughput queues |

The overhead affects **QTIME** and **MSGAGE** computation only. **LPUTDATE/LPUTTIME/LGETDATE/LGETTIME** are always exact regardless of level.

`LOW` is sufficient for our use case (periodic cron collection, not real-time streaming).

---

## 2. `DISPLAY QLOCAL(*) ALL` -- Queue Configuration Attributes

Static configuration attributes. Useful for capacity planning and queue identification.

```
echo "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH" | runmqsc QM1
```

| Attribute | Type | Description | Implemented |
|-----------|------|-------------|:---:|
| **CURDEPTH** | int | Current queue depth | Yes |
| **MAXDEPTH** | int | Maximum queue depth (capacity) | Yes |
| **MAXMSGL** | int | Maximum message length allowed | No |
| **DEFPSIST** | string | Default persistence: `YES`/`NO` | No |
| **DESCR** | string | Queue description text | No |
| **GET** | string | GET enabled/disabled | No |
| **PUT** | string | PUT enabled/disabled | No |
| **RETINTVL** | int | Retention interval (hours) | No |
| **BOQNAME** | string | Backout requeue name (DLQ for poison messages) | No |
| **BOTHRESH** | int | Backout threshold (redelivery count) | No |
| **TRIGTYPE** | string | Trigger type: `FIRST`, `EVERY`, `DEPTH`, `NONE` | No |
| **ALTDATE** | string | Date the queue definition was last altered | No |
| **ALTTIME** | string | Time the queue definition was last altered | No |
| **CRDATE** | string | Date the queue was created | No |
| **CRTIME** | string | Time the queue was created | No |

**Note**: `MAXDEPTH` is only available from `DISPLAY QLOCAL`, not from `DISPLAY QSTATUS`. Both commands must be used and merged to get full data.

---

## 3. `DISPLAY QSTATUS(*) TYPE(HANDLE)` -- Per-Connection Handle Details

Shows each individual open handle on a queue. Useful for identifying connected applications.

```
echo "DISPLAY QSTATUS(*) TYPE(HANDLE) ALL" | runmqsc QM1
```

| Attribute | Type | Description | Implemented |
|-----------|------|-------------|:---:|
| **APPLTAG** | string | Application name (process name) | No |
| **CHANNEL** | string | Channel name (if remote client) | No |
| **CONNAME** | string | Connection name (hostname/IP) | No |
| **OPENOPTS** | int | How the queue was opened (bitmask) | No |
| **PID** | int | Process ID | No |
| **TID** | int | Thread ID | No |
| **USERID** | string | User ID | No |
| **AESSION** | string | Session ID | No |

---

## 4. `DISPLAY CHSTATUS(*) ALL` -- Channel Status Metrics

```
echo "DISPLAY CHSTATUS(*) ALL" | runmqsc QM1
```

| Attribute | Type | Description | Implemented |
|-----------|------|-------------|:---:|
| **STATUS** | string | Channel state: `RUNNING`, `STOPPED`, `RETRYING`, `BINDING`, etc. | No |
| **SUBSTATE** | string | Sub-state: `RECEIVE`, `SEND`, `MQGET`, etc. | No |
| **MSGS** | int | Messages sent/received this session | No |
| **BYTES** | int | Bytes sent/received this session | No |
| **BATCHES** | int | Completed batches this session | No |
| **BUFSRCVD** | int | Buffers received | No |
| **BUFSSENT** | int | Buffers sent | No |
| **LSTMSGDA** | string | Date of last message transferred | No |
| **LSTMSGTI** | string | Time of last message transferred | No |
| **CHSTADA** | string | Channel start date | No |
| **CHSTATI** | string | Channel start time | No |
| **CURMSGS** | int | Current messages in batch | No |
| **CONNAME** | string | Connection name (remote end) | No |
| **MONCHL** | string | Monitoring level | No |
| **SSLPEER** | string | SSL peer name | No |
| **SSLCIPH** | string | SSL cipher spec | No |
| **XQTIME** | pair | Transmission queue time (short, long) in microseconds | No |

---

## 5. `DISPLAY QMSTATUS ALL` -- Queue Manager Status

```
echo "DISPLAY QMSTATUS ALL" | runmqsc QM1
```

| Attribute | Type | Description | Implemented |
|-----------|------|-------------|:---:|
| **STATUS** | string | QM state: `RUNNING`, `QUIESCING`, etc. | No |
| **CONNS** | int | Current number of connections | No |
| **CHINIT** | string | Channel initiator status | No |
| **CMDSERV** | string | Command server status | No |
| **STARTDA** | string | QM start date | No |
| **STARTTI** | string | QM start time | No |
| **CURRLOG** | string | Current log extent name | No |
| **LOGPATH** | string | Path to the log files | No |
| **LOGUTIL** | int | Log utilization percentage (MQ 9.3.2+) | No |
| **INSTNAME** | string | Installation name | No |
| **INSTPATH** | string | Installation path | No |

---

## 6. `DISPLAY CONN(*) ALL` -- Active Connections

```
echo "DISPLAY CONN(*) ALL" | runmqsc QM1
```

| Attribute | Type | Description | Implemented |
|-----------|------|-------------|:---:|
| **APPLTAG** | string | Application name | No |
| **CHANNEL** | string | Channel name | No |
| **CONNAME** | string | Connection name (IP/hostname) | No |
| **CONNOPTS** | string | Connection options | No |
| **USERID** | string | User ID | No |
| **OBJNAME** | string | Object(s) in use | No |
| **CONTYPE** | string | Connection type | No |

---

## Derived Fields (computed in mq-metrics.ksh)

These fields are not from runmqsc but computed by the script from raw data. All require `MQ_METRICS_ADVANCED=1`.

| Field | Computation | Implemented |
|-------|-------------|:---:|
| `depth_percent` | `CURDEPTH / MAXDEPTH * 100` | Yes (A) |
| `last_put_timestamp` | `LPUTDATE` + `LPUTTIME` combined to ISO 8601 | Yes (A) |
| `last_get_timestamp` | `LGETDATE` + `LGETTIME` combined to ISO 8601 | Yes (A) |
| `last_put_elapsed_seconds` | `now - last_put_timestamp` | Yes (A) |
| `last_get_elapsed_seconds` | `now - last_get_timestamp` | Yes (A) |

---

## References

- [DISPLAY QSTATUS (IBM MQ 9.3)](https://www.ibm.com/docs/en/ibm-mq/9.3.x?topic=reference-display-qstatus-display-queue-status)
- [DISPLAY QUEUE (IBM MQ 9.2)](https://www.ibm.com/docs/en/ibm-mq/9.2.x?topic=reference-display-queue-display-queue-attributes)
- [DISPLAY CHSTATUS (IBM MQ 9.3)](https://www.ibm.com/docs/en/ibm-mq/9.3.x?topic=reference-display-chstatus-display-channel-status)
- [DISPLAY QMSTATUS (IBM MQ 9.3)](https://www.ibm.com/docs/en/ibm-mq/9.3.x?topic=reference-display-qmstatus-display-queue-manager-status-multiplatforms)
- [MONQ empty values (IBM Support)](https://www.ibm.com/support/pages/ibm-mq-runmqsc-command-display-qstatus-shows-empty-values-lgetdate-lgettime-lputdate-lputtime-msgage-qtime)
- [Monitoring your IBM MQ network](https://www.ibm.com/docs/SSFKSJ_9.2.0/com.ibm.mq.mon.doc/q036140_.htm)
