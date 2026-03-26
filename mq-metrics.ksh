#!/bin/ksh
#
# mq-metrics.ksh — Collect IBM MQ queue depth metrics and push to Elasticsearch (ECS format)
#
# Configuration (environment variables):
#   MQ_METRICS_ELASTIC_URL       — Elasticsearch base URL (e.g. https://elastic.corp:9200)
#   MQ_METRICS_ELASTIC_API_KEY   — Elastic API key for authentication
#   MQ_METRICS_ELASTIC_INDEX     — Target index/data-stream (default: metrics-mq.queue-default)
#   MQ_METRICS_QMGR_LIST        — Comma-separated QM names (optional; auto-discovers via dspmq if unset)
#   MQ_METRICS_EXCLUDE_QUEUES    — Extended regex of queues to skip (default: ^SYSTEM\.|^AMQ\.)
#

set -u

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ELASTIC_URL="${MQ_METRICS_ELASTIC_URL:-}"
ELASTIC_API_KEY="${MQ_METRICS_ELASTIC_API_KEY:-}"
ELASTIC_INDEX="${MQ_METRICS_ELASTIC_INDEX:-metrics-mq.queue-default}"
QMGR_LIST="${MQ_METRICS_QMGR_LIST:-}"
EXCLUDE_QUEUES="${MQ_METRICS_EXCLUDE_QUEUES:-^SYSTEM\.|^AMQ\.}"

AGENT_NAME="mq-metrics"
AGENT_VERSION="1.0.0"
HOSTNAME=$(hostname)

# Counters
total_queues=0
total_errors=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO  $*"; }
log_error() { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR $*"; }

# ---------------------------------------------------------------------------
# Discover running queue managers via dspmq
# ---------------------------------------------------------------------------
discover_qmgrs() {
    dspmq 2>/dev/null | while IFS= read -r line; do
        # dspmq output: QMNAME(QM1)   STATUS(Running)
        case "$line" in
            *STATUS\(Running\)*)
                qm="${line#*QMNAME(}"
                qm="${qm%%)*}"
                print "$qm"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Query queue depths for a single queue manager and emit JSON docs to stdout
# ---------------------------------------------------------------------------
collect_qmgr() {
    typeset qmgr="$1"
    typeset timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Capture runmqsc output to a temp file to avoid subshell from pipeline
    typeset tmpfile="/tmp/mq-metrics.$$.${qmgr}"
    print "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH" | runmqsc "$qmgr" >"$tmpfile" 2>/dev/null
    typeset rc=$?
    if [[ $rc -ne 0 && ! -s "$tmpfile" ]]; then
        log_error "runmqsc failed for ${qmgr} (rc=${rc})"
        rm -f "$tmpfile"
        total_errors=$((total_errors + 1))
        return
    fi

    typeset queue="" curdepth="" maxdepth=""

    while IFS= read -r line; do

        # Extract QUEUE(name)
        case "$line" in
            *QUEUE\(*)
                # If we already have a complete previous record, emit it
                if [[ -n "$queue" && -n "$curdepth" && -n "$maxdepth" ]]; then
                    emit_doc "$qmgr" "$queue" "$curdepth" "$maxdepth" "$timestamp"
                fi
                queue="${line#*QUEUE(}"
                queue="${queue%%)*}"
                curdepth=""
                maxdepth=""
                ;;
        esac

        # Extract CURDEPTH(n)
        case "$line" in
            *CURDEPTH\(*)
                curdepth="${line#*CURDEPTH(}"
                curdepth="${curdepth%%)*}"
                ;;
        esac

        # Extract MAXDEPTH(n)
        case "$line" in
            *MAXDEPTH\(*)
                maxdepth="${line#*MAXDEPTH(}"
                maxdepth="${maxdepth%%)*}"
                ;;
        esac
    done < "$tmpfile"

    # Emit last record
    if [[ -n "$queue" && -n "$curdepth" && -n "$maxdepth" ]]; then
        emit_doc "$qmgr" "$queue" "$curdepth" "$maxdepth" "$timestamp"
    fi

    rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# Build and send a single ECS JSON document
# ---------------------------------------------------------------------------
emit_doc() {
    typeset qmgr="$1" queue="$2" curdepth="$3" maxdepth="$4" timestamp="$5"

    # Filter excluded queues
    if print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then
        return
    fi

    total_queues=$((total_queues + 1))

    typeset doc="{
  \"@timestamp\": \"${timestamp}\",
  \"ecs\": { \"version\": \"8.11.0\" },
  \"event\": {
    \"kind\": \"metric\",
    \"category\": [\"host\"],
    \"type\": [\"info\"],
    \"module\": \"mq\",
    \"dataset\": \"mq.queue\"
  },
  \"data_stream\": {
    \"type\": \"metrics\",
    \"dataset\": \"mq.queue\",
    \"namespace\": \"default\"
  },
  \"host\": { \"name\": \"${HOSTNAME}\" },
  \"agent\": {
    \"name\": \"${AGENT_NAME}\",
    \"version\": \"${AGENT_VERSION}\",
    \"type\": \"${AGENT_NAME}\"
  },
  \"service\": {
    \"name\": \"ibm-mq\",
    \"type\": \"messaging\"
  },
  \"mq\": {
    \"queue_manager\": { \"name\": \"${qmgr}\" },
    \"queue\": {
      \"name\": \"${queue}\",
      \"type\": \"local\",
      \"depth\": ${curdepth},
      \"max_depth\": ${maxdepth}
    }
  }
}"

    # If no Elastic URL configured, just print the document to stdout
    if [[ -z "$ELASTIC_URL" ]]; then
        print "$doc"
        return
    fi

    # POST to Elasticsearch
    typeset http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X POST "${ELASTIC_URL}/${ELASTIC_INDEX}/_doc" \
        -H "Content-Type: application/json" \
        -H "Authorization: ApiKey ${ELASTIC_API_KEY}" \
        -d "$doc" 2>/dev/null)

    if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
        log_error "Failed to index ${qmgr}/${queue} — HTTP ${http_code}"
        total_errors=$((total_errors + 1))
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "mq-metrics starting"

    # Build queue manager list
    typeset -a qmgrs
    if [[ -n "$QMGR_LIST" ]]; then
        # Split comma-separated list
        typeset IFS=','
        set -A qmgrs $QMGR_LIST
    else
        set -A qmgrs $(discover_qmgrs)
    fi

    if [[ ${#qmgrs[@]} -eq 0 ]]; then
        log_error "No running queue managers found"
        exit 1
    fi

    log_info "Queue managers: ${qmgrs[*]}"

    typeset qm
    for qm in "${qmgrs[@]}"; do
        log_info "Collecting metrics from ${qm}"
        collect_qmgr "$qm"
    done

    log_info "Done — ${total_queues} queues collected, ${total_errors} errors"
}

main "$@"
