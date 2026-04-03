#!/bin/ksh
#
# mq-metrics.ksh — Collect IBM MQ queue metrics and push to Elasticsearch (ECS format)
#
# Collects queue depth (DISPLAY QLOCAL) and runtime status (DISPLAY QSTATUS)
# then merges both into a single ECS document per queue.
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
AGENT_VERSION="2.0.0"
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
# Extract KEY(VALUE) from a runmqsc output line.
# Usage: extract_val "CURDEPTH" "$line"   -> prints the value or empty string
# Note: uses a separate function to avoid ksh case/parenthesis parsing issues.
# ---------------------------------------------------------------------------
extract_val() {
    typeset key="$1" src="$2"
    typeset tmp
    case "$src" in
        *"${key}("*)
            tmp="${src#*"${key}("}"
            # Remove everything from the first ) onwards
            print "${tmp%%\)*}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Discover running queue managers via dspmq
# ---------------------------------------------------------------------------
discover_qmgrs() {
    dspmq 2>/dev/null | while IFS= read -r line; do
        typeset status
        status=$(extract_val STATUS "$line")
        if [[ "$status" = "Running" ]]; then
            extract_val QMNAME "$line"
        fi
    done
}

# ---------------------------------------------------------------------------
# Parse DISPLAY QLOCAL output into associative-like temp files
#   Produces: <dir>/<QUEUENAME>.qlocal  with lines KEY=VALUE
# ---------------------------------------------------------------------------
parse_qlocal() {
    typeset qmgr="$1" tmpdir="$2"
    typeset tmpfile="/tmp/mq-metrics-qlocal.$$.${qmgr}"

    print "DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH" | runmqsc "$qmgr" >"$tmpfile" 2>/dev/null
    typeset rc=$?
    if [[ $rc -ne 0 && ! -s "$tmpfile" ]]; then
        log_error "runmqsc DISPLAY QLOCAL failed for ${qmgr} (rc=${rc})"
        rm -f "$tmpfile"
        total_errors=$((total_errors + 1))
        return 1
    fi

    typeset queue="" curdepth="" maxdepth="" val=""

    while IFS= read -r line; do
        val=$(extract_val QUEUE "$line")
        if [[ -n "$val" ]]; then
            # Emit previous record
            if [[ -n "$queue" && -n "$curdepth" && -n "$maxdepth" ]]; then
                if ! print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then
                    print "CURDEPTH=${curdepth}" > "${tmpdir}/${queue}.qlocal"
                    print "MAXDEPTH=${maxdepth}" >> "${tmpdir}/${queue}.qlocal"
                fi
            fi
            queue="$val"
            curdepth=""
            maxdepth=""
        fi

        val=$(extract_val CURDEPTH "$line")
        [[ -n "$val" ]] && curdepth="$val"

        val=$(extract_val MAXDEPTH "$line")
        [[ -n "$val" ]] && maxdepth="$val"
    done < "$tmpfile"

    # Last record
    if [[ -n "$queue" && -n "$curdepth" && -n "$maxdepth" ]]; then
        if ! print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then
            print "CURDEPTH=${curdepth}" > "${tmpdir}/${queue}.qlocal"
            print "MAXDEPTH=${maxdepth}" >> "${tmpdir}/${queue}.qlocal"
        fi
    fi

    rm -f "$tmpfile"
    return 0
}

# ---------------------------------------------------------------------------
# Parse DISPLAY QSTATUS output into temp files
#   Produces: <dir>/<QUEUENAME>.qstatus  with lines KEY=VALUE
# ---------------------------------------------------------------------------
parse_qstatus() {
    typeset qmgr="$1" tmpdir="$2"
    typeset tmpfile="/tmp/mq-metrics-qstatus.$$.${qmgr}"

    print "DISPLAY QSTATUS(*) TYPE(QUEUE) ALL" | runmqsc "$qmgr" >"$tmpfile" 2>/dev/null
    typeset rc=$?
    if [[ $rc -ne 0 && ! -s "$tmpfile" ]]; then
        log_error "runmqsc DISPLAY QSTATUS failed for ${qmgr} (rc=${rc})"
        rm -f "$tmpfile"
        total_errors=$((total_errors + 1))
        return 1
    fi

    typeset queue="" lputdate="" lputtime="" lgetdate="" lgettime=""
    typeset msgage="" qtime="" ipprocs="" opprocs="" uncom="" val=""

    while IFS= read -r line; do
        val=$(extract_val QUEUE "$line")
        if [[ -n "$val" ]]; then
            # Emit previous record
            if [[ -n "$queue" ]]; then
                if ! print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then
                    write_qstatus "$tmpdir" "$queue" "$lputdate" "$lputtime" \
                        "$lgetdate" "$lgettime" "$msgage" "$qtime" \
                        "$ipprocs" "$opprocs" "$uncom"
                fi
            fi
            queue="$val"
            lputdate="" ; lputtime="" ; lgetdate="" ; lgettime=""
            msgage="" ; qtime="" ; ipprocs="" ; opprocs="" ; uncom=""
        fi

        val=$(extract_val LPUTDATE "$line") ; [[ -n "$val" ]] && lputdate="$val"
        val=$(extract_val LPUTTIME "$line") ; [[ -n "$val" ]] && lputtime="$val"
        val=$(extract_val LGETDATE "$line") ; [[ -n "$val" ]] && lgetdate="$val"
        val=$(extract_val LGETTIME "$line") ; [[ -n "$val" ]] && lgettime="$val"
        val=$(extract_val MSGAGE "$line")   ; [[ -n "$val" ]] && msgage="$val"
        val=$(extract_val IPPROCS "$line")  ; [[ -n "$val" ]] && ipprocs="$val"
        val=$(extract_val OPPROCS "$line")  ; [[ -n "$val" ]] && opprocs="$val"
        val=$(extract_val UNCOM "$line")    ; [[ -n "$val" ]] && uncom="$val"
        val=$(extract_val QTIME "$line")    ; [[ -n "$val" ]] && qtime="$val"
    done < "$tmpfile"

    # Last record
    if [[ -n "$queue" ]]; then
        if ! print "$queue" | grep -qE "$EXCLUDE_QUEUES"; then
            write_qstatus "$tmpdir" "$queue" "$lputdate" "$lputtime" \
                "$lgetdate" "$lgettime" "$msgage" "$qtime" \
                "$ipprocs" "$opprocs" "$uncom"
        fi
    fi

    rm -f "$tmpfile"
    return 0
}

write_qstatus() {
    typeset dir="$1" q="$2"
    typeset _lputdate="$3" _lputtime="$4" _lgetdate="$5" _lgettime="$6"
    typeset _msgage="$7" _qtime="$8" _ipprocs="$9" _opprocs="${10}" _uncom="${11}"

    {
        print "LPUTDATE=${_lputdate}"
        print "LPUTTIME=${_lputtime}"
        print "LGETDATE=${_lgetdate}"
        print "LGETTIME=${_lgettime}"
        print "MSGAGE=${_msgage}"
        print "QTIME=${_qtime}"
        print "IPPROCS=${_ipprocs}"
        print "OPPROCS=${_opprocs}"
        print "UNCOM=${_uncom}"
    } > "${dir}/${q}.qstatus"
}

# ---------------------------------------------------------------------------
# Convert MQ date (YYYY-MM-DD) + time (HH.MM.SS) to ISO 8601 timestamp
# ---------------------------------------------------------------------------
mq_to_iso() {
    typeset d="$1" t="$2"
    if [[ -z "$d" || -z "$t" || "$d" = " " || "$t" = " " ]]; then
        print ""
        return
    fi
    # MQ time uses dots: HH.MM.SS -> HH:MM:SS
    typeset ts="${d}T${t%%.*}:${t#*.}"
    # ts is now YYYY-MM-DDThh:MM.SS — need to fix second dot
    typeset hh="${t%%.*}"
    typeset rest="${t#*.}"
    typeset mm="${rest%%.*}"
    typeset ss="${rest#*.}"
    print "${d}T${hh}:${mm}:${ss}Z"
}

# ---------------------------------------------------------------------------
# Compute elapsed seconds between an ISO timestamp and now (epoch-based)
# Falls back to 0-precision arithmetic available in ksh on AIX.
# ---------------------------------------------------------------------------
elapsed_seconds() {
    typeset iso="$1" now_epoch="$2"
    if [[ -z "$iso" ]]; then
        print ""
        return
    fi
    # Parse ISO: YYYY-MM-DDThh:mm:ssZ
    typeset dpart="${iso%%T*}"
    typeset tpart="${iso#*T}"
    tpart="${tpart%Z}"

    typeset year="${dpart%%-*}"
    typeset rest="${dpart#*-}"
    typeset month="${rest%%-*}"
    typeset day="${rest#*-}"

    typeset hour="${tpart%%:*}"
    rest="${tpart#*:}"
    typeset min="${rest%%:*}"
    typeset sec="${rest#*:}"

    # Approximate epoch using POSIX-friendly arithmetic (no bc/date -d on AIX ksh)
    # Days from year: simplified — accurate enough for elapsed computation
    typeset y=$((year - 1970))
    typeset leap_days=$(( (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400 ))
    typeset year_days=$((y * 365 + leap_days))

    # Days from month (cumulative, non-leap; adjust for leap year)
    set -A mdays 0 31 59 90 120 151 181 212 243 273 304 334
    typeset m=$((10#$month))
    typeset month_days=${mdays[$((m - 1))]}
    if [[ $m -gt 2 ]]; then
        if [[ $((year % 4)) -eq 0 && ( $((year % 100)) -ne 0 || $((year % 400)) -eq 0 ) ]]; then
            month_days=$((month_days + 1))
        fi
    fi

    typeset d=$((10#$day))
    typeset h=$((10#$hour))
    typeset mi=$((10#$min))
    typeset s=$((10#$sec))

    typeset ts_epoch=$(( (year_days + month_days + d - 1) * 86400 + h * 3600 + mi * 60 + s ))
    typeset diff=$((now_epoch - ts_epoch))
    if [[ $diff -lt 0 ]]; then
        diff=0
    fi
    print "$diff"
}

# ---------------------------------------------------------------------------
# Get current epoch (POSIX-portable)
# ---------------------------------------------------------------------------
get_epoch() {
    # Try date +%s first (works on most systems including AIX 7.2+)
    typeset epoch
    epoch=$(date +%s 2>/dev/null)
    if [[ -n "$epoch" && "$epoch" != "%s" ]]; then
        print "$epoch"
        return
    fi
    # Fallback: compute from date -u output
    typeset now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    typeset dpart="${now%%T*}"
    typeset tpart="${now#*T}"
    tpart="${tpart%Z}"
    typeset year="${dpart%%-*}"
    typeset rest="${dpart#*-}"
    typeset month="${rest%%-*}"
    typeset day="${rest#*-}"
    typeset hour="${tpart%%:*}"
    rest="${tpart#*:}"
    typeset min="${rest%%:*}"
    typeset sec="${rest#*:}"
    typeset y=$((year - 1970))
    typeset leap_days=$(( (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400 ))
    typeset year_days=$((y * 365 + leap_days))
    set -A mdays 0 31 59 90 120 151 181 212 243 273 304 334
    typeset m=$((10#$month))
    typeset month_days=${mdays[$((m - 1))]}
    if [[ $m -gt 2 ]]; then
        if [[ $((year % 4)) -eq 0 && ( $((year % 100)) -ne 0 || $((year % 400)) -eq 0 ) ]]; then
            month_days=$((month_days + 1))
        fi
    fi
    typeset d=$((10#$day))
    typeset h=$((10#$hour))
    typeset mi=$((10#$min))
    typeset s=$((10#$sec))
    print $(( (year_days + month_days + d - 1) * 86400 + h * 3600 + mi * 60 + s ))
}

# ---------------------------------------------------------------------------
# Merge qlocal + qstatus data and build bulk payload for one QM
# Appends NDJSON lines (action + doc) to the bulk file
# ---------------------------------------------------------------------------
collect_qmgr() {
    typeset qmgr="$1" bulkfile="$2"
    typeset timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    typeset now_epoch
    now_epoch=$(get_epoch)

    typeset tmpdir="/tmp/mq-metrics-merge.$$.$qmgr"
    mkdir -p "$tmpdir"

    # Run both DISPLAY commands
    parse_qlocal "$qmgr" "$tmpdir"
    parse_qstatus "$qmgr" "$tmpdir"

    # Iterate over all queues that have a .qlocal file (authoritative list)
    for qlocal_file in "${tmpdir}"/*.qlocal; do
        [[ -f "$qlocal_file" ]] || continue

        typeset base="${qlocal_file##*/}"
        typeset queue="${base%.qlocal}"

        # Read qlocal values
        typeset curdepth="" maxdepth=""
        while IFS='=' read -r key val; do
            case "$key" in
                CURDEPTH) curdepth="$val" ;;
                MAXDEPTH) maxdepth="$val" ;;
            esac
        done < "$qlocal_file"

        # Read qstatus values (may not exist if QSTATUS failed)
        typeset lputdate="" lputtime="" lgetdate="" lgettime=""
        typeset msgage="" qtime="" ipprocs="" opprocs="" uncom=""
        typeset qstatus_file="${tmpdir}/${queue}.qstatus"
        if [[ -f "$qstatus_file" ]]; then
            while IFS='=' read -r key val; do
                case "$key" in
                    LPUTDATE) lputdate="$val" ;;
                    LPUTTIME) lputtime="$val" ;;
                    LGETDATE) lgetdate="$val" ;;
                    LGETTIME) lgettime="$val" ;;
                    MSGAGE)   msgage="$val" ;;
                    QTIME)    qtime="$val" ;;
                    IPPROCS)  ipprocs="$val" ;;
                    OPPROCS)  opprocs="$val" ;;
                    UNCOM)    uncom="$val" ;;
                esac
            done < "$qstatus_file"
        fi

        # Compute derived fields
        typeset last_put_ts last_get_ts
        last_put_ts=$(mq_to_iso "$lputdate" "$lputtime")
        last_get_ts=$(mq_to_iso "$lgetdate" "$lgettime")

        typeset last_put_elapsed last_get_elapsed
        last_put_elapsed=$(elapsed_seconds "$last_put_ts" "$now_epoch")
        last_get_elapsed=$(elapsed_seconds "$last_get_ts" "$now_epoch")

        typeset depth_percent=""
        if [[ -n "$maxdepth" && "$maxdepth" -gt 0 ]]; then
            depth_percent=$(( (curdepth * 10000) / maxdepth ))
            # Insert decimal: 10000 -> 100.00
            typeset int_part=$((depth_percent / 100))
            typeset frac_part=$((depth_percent % 100))
            if [[ $frac_part -lt 10 ]]; then
                depth_percent="${int_part}.0${frac_part}"
            else
                depth_percent="${int_part}.${frac_part}"
            fi
        fi

        # Parse QTIME into short/long components: "12345, 67890" or " , "
        typeset qtime_short="" qtime_long=""
        if [[ -n "$qtime" ]]; then
            typeset qt_left="${qtime%%,*}"
            typeset qt_right="${qtime#*,}"
            # Trim all leading/trailing spaces
            while [[ "$qt_left" = " "* ]]; do qt_left="${qt_left# }"; done
            while [[ "$qt_left" = *" " ]]; do qt_left="${qt_left% }"; done
            while [[ "$qt_right" = " "* ]]; do qt_right="${qt_right# }"; done
            while [[ "$qt_right" = *" " ]]; do qt_right="${qt_right% }"; done
            [[ -n "$qt_left" ]] && qtime_short="$qt_left"
            [[ -n "$qt_right" ]] && qtime_long="$qt_right"
        fi

        # Build the mq.queue JSON fragment with optional fields
        typeset queue_json="\"name\": \"${queue}\", \"type\": \"local\", \"depth\": ${curdepth}, \"max_depth\": ${maxdepth}"

        [[ -n "$depth_percent" ]] && queue_json="${queue_json}, \"depth_percent\": ${depth_percent}"
        [[ -n "$ipprocs" ]] && queue_json="${queue_json}, \"input_handles\": ${ipprocs}"
        [[ -n "$opprocs" ]] && queue_json="${queue_json}, \"output_handles\": ${opprocs}"
        if [[ -n "$uncom" ]]; then
            if [[ "$uncom" = "YES" ]]; then
                queue_json="${queue_json}, \"uncommitted\": true"
            else
                queue_json="${queue_json}, \"uncommitted\": false"
            fi
        fi
        [[ -n "$msgage" && "$msgage" != " " ]] && queue_json="${queue_json}, \"oldest_message_age\": ${msgage}"
        [[ -n "$qtime_short" ]] && queue_json="${queue_json}, \"queue_time_short\": ${qtime_short}"
        [[ -n "$qtime_long" ]] && queue_json="${queue_json}, \"queue_time_long\": ${qtime_long}"
        [[ -n "$last_put_ts" ]] && queue_json="${queue_json}, \"last_put_timestamp\": \"${last_put_ts}\""
        [[ -n "$last_get_ts" ]] && queue_json="${queue_json}, \"last_get_timestamp\": \"${last_get_ts}\""
        [[ -n "$last_put_elapsed" ]] && queue_json="${queue_json}, \"last_put_elapsed_seconds\": ${last_put_elapsed}"
        [[ -n "$last_get_elapsed" ]] && queue_json="${queue_json}, \"last_get_elapsed_seconds\": ${last_get_elapsed}"

        typeset doc="{ \"@timestamp\": \"${timestamp}\", \"ecs\": { \"version\": \"8.11.0\" }, \"event\": { \"kind\": \"metric\", \"category\": [\"host\"], \"type\": [\"info\"], \"module\": \"mq\", \"dataset\": \"mq.queue\" }, \"data_stream\": { \"type\": \"metrics\", \"dataset\": \"mq.queue\", \"namespace\": \"default\" }, \"host\": { \"name\": \"${HOSTNAME}\" }, \"agent\": { \"name\": \"${AGENT_NAME}\", \"version\": \"${AGENT_VERSION}\", \"type\": \"${AGENT_NAME}\" }, \"service\": { \"name\": \"ibm-mq\", \"type\": \"messaging\" }, \"mq\": { \"queue_manager\": { \"name\": \"${qmgr}\" }, \"queue\": { ${queue_json} } } }"

        # Append bulk action + document lines
        print "{ \"create\": { } }" >> "$bulkfile"
        print "$doc" >> "$bulkfile"

        total_queues=$((total_queues + 1))
    done

    # Cleanup temp dir
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Send bulk payload to Elasticsearch
# ---------------------------------------------------------------------------
send_bulk() {
    typeset bulkfile="$1"

    if [[ ! -s "$bulkfile" ]]; then
        log_info "No documents to send"
        return
    fi

    if [[ -z "$ELASTIC_URL" ]]; then
        # Dry-run: pretty-print each document (skip action lines)
        while IFS= read -r line; do
            case "$line" in
                '{ "create":'*) ;;
                *) print "$line" ;;
            esac
        done < "$bulkfile"
        return
    fi

    typeset response_file="/tmp/mq-metrics-bulk-response.$$"
    typeset http_code
    http_code=$(curl -s -o "$response_file" -w '%{http_code}' \
        --connect-timeout 10 --max-time 60 \
        -X POST "${ELASTIC_URL}/${ELASTIC_INDEX}/_bulk" \
        -H "Content-Type: application/x-ndjson" \
        -H "Authorization: ApiKey ${ELASTIC_API_KEY}" \
        --data-binary @"$bulkfile" 2>/dev/null)

    if [[ "$http_code" != "200" ]]; then
        log_error "Bulk request failed — HTTP ${http_code}"
        total_errors=$((total_errors + 1))
    else
        # Check for per-item errors in the response
        if grep -q '"errors":true' "$response_file" 2>/dev/null; then
            log_error "Bulk request returned with item-level errors (HTTP 200)"
            total_errors=$((total_errors + 1))
        fi
    fi

    rm -f "$response_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "mq-metrics starting"

    # Build queue manager list
    typeset -a qmgrs
    if [[ -n "$QMGR_LIST" ]]; then
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

    typeset bulkfile="/tmp/mq-metrics-bulk.$$"
    > "$bulkfile"

    typeset qm
    for qm in "${qmgrs[@]}"; do
        log_info "Collecting metrics from ${qm}"
        collect_qmgr "$qm" "$bulkfile"
    done

    send_bulk "$bulkfile"
    rm -f "$bulkfile"

    log_info "Done — ${total_queues} queues collected, ${total_errors} errors"
}

main "$@"
