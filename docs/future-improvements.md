# Future Improvements

Ideas for improving `mq-metrics.ksh` (v2.0.0) when scaling to production environments with hundreds of queues.

---

## 1. ~~Use Elasticsearch Bulk API~~ (Done)

**Implemented in v2.0.0** (`feature/get_put_dates` branch).

The script now collects all documents into an NDJSON payload and sends them in a single `POST /_bulk` request. Response is checked for both HTTP-level and per-item errors.

---

## 2. ~~ksh88 Compatibility~~ (Done)

**Implemented in v2.0.0.** The script now follows strict ksh88 compatibility guidelines: no arrays, no `typeset` in `name()` functions, escaped parentheses in parameter expansions, temp-file redirect instead of piped while-read, per-function variable prefixes. See `docs/ksh88-compat-guidelines.md`.

A container-based test harness (`tests/run-ksh88-tests.sh`) validates the script against mksh (ksh88 proxy) on Alpine.

---

## 3. Use ksh Built-in Pattern Matching for Queue Exclusion

**Priority: Medium**

The current exclusion check forks two processes per queue (`print | grep -qE`). On AIX, process creation is more expensive than on Linux — with 500 queues this means ~1000 short-lived processes per run.

Replace with ksh native glob matching:

```ksh
# Current (forks 2 processes)
if print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then

# Improved (zero forks)
if [[ $queue == SYSTEM.* || $queue == AMQ.* ]]; then
```

For custom exclusion patterns set via `MQ_METRICS_EXCLUDE_QUEUES`, fall back to a single `grep` call only when a non-default pattern is configured.

---

## 4. Retry on Transient Elasticsearch Failures

**Priority: Low**

Add a single retry with a short backoff (e.g., 5s) for the bulk POST when Elasticsearch returns a transient error (HTTP 429, 503). This avoids losing an entire collection run due to a momentary ES hiccup.

---

## Notes on Queue Manager Impact

Both `DISPLAY QLOCAL` and `DISPLAY QSTATUS` commands used by the script are read-only inquiries against in-memory QM structures. They do not access message data, acquire exclusive locks, or touch journal/log files. IBM's own monitoring tools use the same mechanism. Overhead is negligible even at 1000+ queues — no improvements needed on this side.

When `MQ_METRICS_ADVANCED=1`, the script runs two `runmqsc` commands per queue manager instead of one. The additional `DISPLAY QSTATUS(*)` command has similar overhead to `DISPLAY QLOCAL(*)`.
