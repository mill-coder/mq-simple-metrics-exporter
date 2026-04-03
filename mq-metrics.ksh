#!/bin/ksh
#
# mq-metrics.ksh - Collect IBM MQ queue metrics and push to Elasticsearch (ECS format)
#
# Collects queue depth (DISPLAY QLOCAL) and optionally runtime status (DISPLAY QSTATUS)
# then merges both into a single ECS document per queue.
#
# Configuration:
#  MQ_METRICS_ELASTIC_URL        - Elasticsearch base URL (e.g. http://elastic-lab.lan:9200)
#  MQ_METRICS_ELASTIC_API_KEY    - Elastic API key for authentication
#  MQ_METRICS_ELASTIC_INDEX      - Target index/data-stream (default: metrics-mq.queue-default)
#  MQ_METRICS_QMGR_LIST          - Comma-separated QM names (optional; auto-discovers via dspmq if unset)
#  MQ_METRICS_EXCLUDE_QUEUES     - Extended regex of queues to skip (default: ^SYSTEM\.|^AMQ\.)
#  MQ_METRICS_ADVANCED           - Set to 1 to enable QSTATUS collection and derived fields
#  MQ_METRICS_FILTER_WEBSPHERE   - Set to 0 to disable WHERE(DESCR NL 'WebSphere MQ') filter (default: 1)

set -u

# ============================================================================
# Defaults
# ============================================================================
MQ_METRICS_QMGR_LIST=${1:-}

ELASTIC_URL="${MQ_METRICS_ELASTIC_URL:-}"
ELASTIC_API_KEY="${MQ_METRICS_ELASTIC_API_KEY:-}"
ELASTIC_INDEX="${MQ_METRICS_ELASTIC_INDEX:-metrics-mq.queue-default}"
QMGR_LIST="${MQ_METRICS_QMGR_LIST:-}"
EXCLUDE_QUEUES="${MQ_METRICS_EXCLUDE_QUEUES:-^SYSTEM\.|^AMQ\.}"
ADVANCED="${MQ_METRICS_ADVANCED:-}"
FILTER_WEBSPHERE="${MQ_METRICS_FILTER_WEBSPHERE:-1}"

AGENT_NAME="mq-metrics"
AGENT_VERSION="2.0.0"
HOSTNAME=$(hostname)

# Counters
total_queues=0
total_errors=0

# ============================================================================
# Logging helpers
# ============================================================================
log_info()  { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') INFO  $@"; }
log_error() { print -u2 "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR $@"; }

# ============================================================================
# Extract KEY(VALUE) from a runmqsc output line.
# Usage: val=$(extract_val CURDEPTH "$line")
# Uses a function to isolate parenthesis parsing from case blocks.
# ============================================================================
extract_val() {
    _ev_key="$1" ; _ev_src="$2"
    case "$_ev_src" in
        *${_ev_key}\(*)
            _ev_tmp="${_ev_src#*${_ev_key}\(}"
            print "${_ev_tmp%%\)*}"
            ;;
    esac
}

# ============================================================================
# Discover running queue managers via dspmq
# ============================================================================
discover_qmgrs() {
    _dq_tmp="/tmp/mq-metrics-dspmq.$$"
    dspmq >"$_dq_tmp" 2>/dev/null
    _dq_list=
    while read -r line; do
        _dq_status=$(extract_val STATUS "$line")
        if [[ "$_dq_status" = "Running" ]]; then
            _dq_qm=$(extract_val QMNAME "$line")
            _dq_list="${_dq_list}${_dq_qm} "
        fi
    done < "$_dq_tmp"
    rm -f "$_dq_tmp"
    print "$_dq_list"
}

# ============================================================================
# Parse DISPLAY QLOCAL output into per-queue temp files
#   Produces: <dir>/<QUEUENAME>.qlocal  with lines KEY=VALUE
# ============================================================================
parse_qlocal() {
    _pl_qmgr="$1" ; _pl_tmpdir="$2"
    _pl_tmpfile="/tmp/mq-metrics-qlocal.$$.${_pl_qmgr}"

    _pl_cmd="DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH"
    if [[ "$FILTER_WEBSPHERE" = "1" ]]; then
        _pl_cmd="DISPLAY QLOCAL(*) CURDEPTH MAXDEPTH WHERE(DESCR NL 'WebSphere MQ')"
    fi

    print "$_pl_cmd" | runmqsc "$_pl_qmgr" >"$_pl_tmpfile" 2>/dev/null
    _pl_rc=$?
    if [[ $_pl_rc -ne 0 && ! -s "$_pl_tmpfile" ]]; then
        log_error "runmqsc DISPLAY QLOCAL failed for ${_pl_qmgr} (rc=${_pl_rc})"
        rm -f "$_pl_tmpfile"
        total_errors=$((total_errors + 1))
        return 1
    fi

    _pl_queue="" ; _pl_curdepth="" ; _pl_maxdepth=""

    while read -r line; do
        _pl_val=$(extract_val QUEUE "$line")
        if [[ -n "$_pl_val" ]]; then
            # Emit previous record
            if [[ -n "$_pl_queue" && -n "$_pl_curdepth" && -n "$_pl_maxdepth" ]]; then
                if ! print "$_pl_queue" | grep -qE "$EXCLUDE_QUEUES"; then
                    print "CURDEPTH=${_pl_curdepth}" > "${_pl_tmpdir}/${_pl_queue}.qlocal"
                    print "MAXDEPTH=${_pl_maxdepth}" >> "${_pl_tmpdir}/${_pl_queue}.qlocal"
                fi
            fi
            _pl_queue="$_pl_val"
            _pl_curdepth="" ; _pl_maxdepth=""
        fi

        _pl_val=$(extract_val CURDEPTH "$line")
        [[ -n "$_pl_val" ]] && _pl_curdepth="$_pl_val"

        _pl_val=$(extract_val MAXDEPTH "$line")
        [[ -n "$_pl_val" ]] && _pl_maxdepth="$_pl_val"
    done < "$_pl_tmpfile"

    # Last record
    if [[ -n "$_pl_queue" && -n "$_pl_curdepth" && -n "$_pl_maxdepth" ]]; then
        if ! print "$_pl_queue" | grep -qE "$EXCLUDE_QUEUES"; then
            print "CURDEPTH=${_pl_curdepth}" > "${_pl_tmpdir}/${_pl_queue}.qlocal"
            print "MAXDEPTH=${_pl_maxdepth}" >> "${_pl_tmpdir}/${_pl_queue}.qlocal"
        fi
    fi

    rm -f "$_pl_tmpfile"
    return 0
}

# ============================================================================
# Parse DISPLAY QSTATUS output into per-queue temp files
#   Produces: <dir>/<QUEUENAME>.qstatus  with lines KEY=VALUE
# ============================================================================
parse_qstatus() {
    _ps_qmgr="$1" ; _ps_tmpdir="$2"
    _ps_tmpfile="/tmp/mq-metrics-qstatus.$$.${_ps_qmgr}"

    print "DISPLAY QSTATUS(*) TYPE(QUEUE) ALL" | runmqsc "$_ps_qmgr" >"$_ps_tmpfile" 2>/dev/null
    _ps_rc=$?
    if [[ $_ps_rc -ne 0 && ! -s "$_ps_tmpfile" ]]; then
        log_error "runmqsc DISPLAY QSTATUS failed for ${_ps_qmgr} (rc=${_ps_rc})"
        rm -f "$_ps_tmpfile"
        total_errors=$((total_errors + 1))
        return 1
    fi

    _ps_queue=""
    _ps_lputdate="" ; _ps_lputtime="" ; _ps_lgetdate="" ; _ps_lgettime=""
    _ps_msgage="" ; _ps_qtime="" ; _ps_ipprocs="" ; _ps_opprocs="" ; _ps_uncom=""

    while read -r line; do
        _ps_val=$(extract_val QUEUE "$line")
        if [[ -n "$_ps_val" ]]; then
            # Emit previous record
            if [[ -n "$_ps_queue" ]]; then
                if ! print "$_ps_queue" | grep -qE "$EXCLUDE_QUEUES"; then
                    write_qstatus "$_ps_tmpdir" "$_ps_queue" \
                        "$_ps_lputdate" "$_ps_lputtime" \
                        "$_ps_lgetdate" "$_ps_lgettime" \
                        "$_ps_msgage" "$_ps_qtime" \
                        "$_ps_ipprocs" "$_ps_opprocs" "$_ps_uncom"
                fi
            fi
            _ps_queue="$_ps_val"
            _ps_lputdate="" ; _ps_lputtime="" ; _ps_lgetdate="" ; _ps_lgettime=""
            _ps_msgage="" ; _ps_qtime="" ; _ps_ipprocs="" ; _ps_opprocs="" ; _ps_uncom=""
        fi

        _ps_val=$(extract_val LPUTDATE "$line") ; [[ -n "$_ps_val" ]] && _ps_lputdate="$_ps_val"
        _ps_val=$(extract_val LPUTTIME "$line") ; [[ -n "$_ps_val" ]] && _ps_lputtime="$_ps_val"
        _ps_val=$(extract_val LGETDATE "$line") ; [[ -n "$_ps_val" ]] && _ps_lgetdate="$_ps_val"
        _ps_val=$(extract_val LGETTIME "$line") ; [[ -n "$_ps_val" ]] && _ps_lgettime="$_ps_val"
        _ps_val=$(extract_val MSGAGE "$line")   ; [[ -n "$_ps_val" ]] && _ps_msgage="$_ps_val"
        _ps_val=$(extract_val IPPROCS "$line")  ; [[ -n "$_ps_val" ]] && _ps_ipprocs="$_ps_val"
        _ps_val=$(extract_val OPPROCS "$line")  ; [[ -n "$_ps_val" ]] && _ps_opprocs="$_ps_val"
        _ps_val=$(extract_val UNCOM "$line")    ; [[ -n "$_ps_val" ]] && _ps_uncom="$_ps_val"
        _ps_val=$(extract_val QTIME "$line")    ; [[ -n "$_ps_val" ]] && _ps_qtime="$_ps_val"
    done < "$_ps_tmpfile"

    # Last record
    if [[ -n "$_ps_queue" ]]; then
        if ! print "$_ps_queue" | grep -qE "$EXCLUDE_QUEUES"; then
            write_qstatus "$_ps_tmpdir" "$_ps_queue" \
                "$_ps_lputdate" "$_ps_lputtime" \
                "$_ps_lgetdate" "$_ps_lgettime" \
                "$_ps_msgage" "$_ps_qtime" \
                "$_ps_ipprocs" "$_ps_opprocs" "$_ps_uncom"
        fi
    fi

    rm -f "$_ps_tmpfile"
    return 0
}

write_qstatus() {
    _ws_dir="$1" ; _ws_q="$2"
    _ws_lputdate="$3" ; _ws_lputtime="$4"
    _ws_lgetdate="$5" ; _ws_lgettime="$6"
    _ws_msgage="$7" ; _ws_qtime="$8"
    _ws_ipprocs="$9" ; _ws_opprocs="${10}" ; _ws_uncom="${11}"

    {
        print "LPUTDATE=${_ws_lputdate}"
        print "LPUTTIME=${_ws_lputtime}"
        print "LGETDATE=${_ws_lgetdate}"
        print "LGETTIME=${_ws_lgettime}"
        print "MSGAGE=${_ws_msgage}"
        print "QTIME=${_ws_qtime}"
        print "IPPROCS=${_ws_ipprocs}"
        print "OPPROCS=${_ws_opprocs}"
        print "UNCOM=${_ws_uncom}"
    } > "${_ws_dir}/${_ws_q}.qstatus"
}

# ============================================================================
# Convert MQ date (YYYY-MM-DD) + time (HH.MM.SS) to ISO 8601 timestamp
# ============================================================================
mq_to_iso() {
    _mi_d="$1" ; _mi_t="$2"
    if [[ -z "$_mi_d" || -z "$_mi_t" || "$_mi_d" = " " || "$_mi_t" = " " ]]; then
        print ""
        return
    fi
    # MQ time uses dots: HH.MM.SS -> HH:MM:SS
    _mi_hh="${_mi_t%%.*}"
    _mi_rest="${_mi_t#*.}"
    _mi_mm="${_mi_rest%%.*}"
    _mi_ss="${_mi_rest#*.}"
    print "${_mi_d}T${_mi_hh}:${_mi_mm}:${_mi_ss}Z"
}

# ============================================================================
# Compute elapsed seconds between an ISO timestamp and now (epoch-based)
# ============================================================================
elapsed_seconds() {
    _es_iso="$1" ; _es_now_epoch="$2"
    if [[ -z "$_es_iso" ]]; then
        print ""
        return
    fi
    # Parse ISO: YYYY-MM-DDThh:mm:ssZ
    _es_dpart="${_es_iso%%T*}"
    _es_tpart="${_es_iso#*T}"
    _es_tpart="${_es_tpart%Z}"

    _es_year="${_es_dpart%%-*}"
    _es_rest="${_es_dpart#*-}"
    _es_month="${_es_rest%%-*}"
    _es_day="${_es_rest#*-}"

    _es_hour="${_es_tpart%%:*}"
    _es_rest="${_es_tpart#*:}"
    _es_min="${_es_rest%%:*}"
    _es_sec="${_es_rest#*:}"

    # Approximate epoch (accurate enough for elapsed computation)
    _es_y=$((_es_year - 1970))
    _es_leap_days=$(( (_es_year - 1969) / 4 - (_es_year - 1901) / 100 + (_es_year - 1601) / 400 ))
    _es_year_days=$((_es_y * 365 + _es_leap_days))

    # Cumulative days per month (non-leap); use positional params instead of array
    set -- 0 31 59 90 120 151 181 212 243 273 304 334
    _es_m=$((10#$_es_month))
    eval _es_month_days=\${$_es_m}
    if [[ $_es_m -gt 2 ]]; then
        if [[ $((_es_year % 4)) -eq 0 && ( $((_es_year % 100)) -ne 0 || $((_es_year % 400)) -eq 0 ) ]]; then
            _es_month_days=$((_es_month_days + 1))
        fi
    fi

    _es_d=$((10#$_es_day))
    _es_h=$((10#$_es_hour))
    _es_mi=$((10#$_es_min))
    _es_s=$((10#$_es_sec))

    _es_ts_epoch=$(( (_es_year_days + _es_month_days + _es_d - 1) * 86400 + _es_h * 3600 + _es_mi * 60 + _es_s ))
    _es_diff=$((_es_now_epoch - _es_ts_epoch))
    if [[ $_es_diff -lt 0 ]]; then
        _es_diff=0
    fi
    print "$_es_diff"
}

# ============================================================================
# Get current epoch (POSIX-portable)
# ============================================================================
get_epoch() {
    # Try date +%s first (works on most systems including AIX 7.2+)
    _ge_epoch=$(date +%s 2>/dev/null)
    if [[ -n "$_ge_epoch" && "$_ge_epoch" != "%s" ]]; then
        print "$_ge_epoch"
        return
    fi
    # Fallback: compute from date -u output
    _ge_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    _ge_dpart="${_ge_now%%T*}"
    _ge_tpart="${_ge_now#*T}"
    _ge_tpart="${_ge_tpart%Z}"
    _ge_year="${_ge_dpart%%-*}"
    _ge_rest="${_ge_dpart#*-}"
    _ge_month="${_ge_rest%%-*}"
    _ge_day="${_ge_rest#*-}"
    _ge_hour="${_ge_tpart%%:*}"
    _ge_rest="${_ge_tpart#*:}"
    _ge_min="${_ge_rest%%:*}"
    _ge_sec="${_ge_rest#*:}"

    _ge_y=$((_ge_year - 1970))
    _ge_leap_days=$(( (_ge_year - 1969) / 4 - (_ge_year - 1901) / 100 + (_ge_year - 1601) / 400 ))
    _ge_year_days=$((_ge_y * 365 + _ge_leap_days))

    set -- 0 31 59 90 120 151 181 212 243 273 304 334
    _ge_m=$((10#$_ge_month))
    eval _ge_month_days=\${$_ge_m}
    if [[ $_ge_m -gt 2 ]]; then
        if [[ $((_ge_year % 4)) -eq 0 && ( $((_ge_year % 100)) -ne 0 || $((_ge_year % 400)) -eq 0 ) ]]; then
            _ge_month_days=$((_ge_month_days + 1))
        fi
    fi

    _ge_d=$((10#$_ge_day))
    _ge_h=$((10#$_ge_hour))
    _ge_mi=$((10#$_ge_min))
    _ge_s=$((10#$_ge_sec))

    print $(( (_ge_year_days + _ge_month_days + _ge_d - 1) * 86400 + _ge_h * 3600 + _ge_mi * 60 + _ge_s ))
}

# ============================================================================
# Merge qlocal + qstatus data and build bulk payload for one QM
# Appends NDJSON lines (action + doc) to the bulk file
# ============================================================================
collect_qmgr() {
    _cq_qmgr="$1" ; _cq_bulkfile="$2"
    _cq_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    _cq_tmpdir="/tmp/mq-metrics-merge.$$.$_cq_qmgr"
    mkdir -p "$_cq_tmpdir"

    # Run DISPLAY commands
    parse_qlocal "$_cq_qmgr" "$_cq_tmpdir"

    if [[ -n "$ADVANCED" && ( "$ADVANCED" = "1" || "$ADVANCED" = "yes" ) ]]; then
        _cq_now_epoch=$(get_epoch)
        parse_qstatus "$_cq_qmgr" "$_cq_tmpdir"
    fi

    # Iterate over all queues that have a .qlocal file (authoritative list)
    for _cq_qlocal_file in "${_cq_tmpdir}"/*.qlocal; do
        [[ -f "$_cq_qlocal_file" ]] || continue

        _cq_base="${_cq_qlocal_file##*/}"
        _cq_queue="${_cq_base%.qlocal}"

        # Read qlocal values
        _cq_curdepth="" ; _cq_maxdepth=""
        while read -r _cq_kvline; do
            _cq_key="${_cq_kvline%%=*}"
            _cq_val="${_cq_kvline#*=}"
            case "$_cq_key" in
                CURDEPTH) _cq_curdepth="$_cq_val" ;;
                MAXDEPTH) _cq_maxdepth="$_cq_val" ;;
            esac
        done < "$_cq_qlocal_file"

        # Build base queue JSON fragment
        _cq_queue_json="\"name\": \"${_cq_queue}\", \"type\": \"local\", \"depth\": ${_cq_curdepth}, \"max_depth\": ${_cq_maxdepth}"

        # Advanced fields (only when QSTATUS was collected)
        if [[ -n "$ADVANCED" && ( "$ADVANCED" = "1" || "$ADVANCED" = "yes" ) ]]; then

            # depth_percent (derived from CURDEPTH/MAXDEPTH)
            if [[ -n "$_cq_maxdepth" && "$_cq_maxdepth" -gt 0 ]]; then
                _cq_dp=$(( (_cq_curdepth * 10000) / _cq_maxdepth ))
                _cq_dp_int=$((_cq_dp / 100))
                _cq_dp_frac=$((_cq_dp % 100))
                if [[ $_cq_dp_frac -lt 10 ]]; then
                    _cq_queue_json="${_cq_queue_json}, \"depth_percent\": ${_cq_dp_int}.0${_cq_dp_frac}"
                else
                    _cq_queue_json="${_cq_queue_json}, \"depth_percent\": ${_cq_dp_int}.${_cq_dp_frac}"
                fi
            fi

            # Read qstatus values (may not exist if QSTATUS failed)
            _cq_lputdate="" ; _cq_lputtime="" ; _cq_lgetdate="" ; _cq_lgettime=""
            _cq_msgage="" ; _cq_qtime="" ; _cq_ipprocs="" ; _cq_opprocs="" ; _cq_uncom=""
            _cq_qstatus_file="${_cq_tmpdir}/${_cq_queue}.qstatus"
            if [[ -f "$_cq_qstatus_file" ]]; then
                while read -r _cq_kvline; do
                    _cq_key="${_cq_kvline%%=*}"
                    _cq_val="${_cq_kvline#*=}"
                    case "$_cq_key" in
                        LPUTDATE) _cq_lputdate="$_cq_val" ;;
                        LPUTTIME) _cq_lputtime="$_cq_val" ;;
                        LGETDATE) _cq_lgetdate="$_cq_val" ;;
                        LGETTIME) _cq_lgettime="$_cq_val" ;;
                        MSGAGE)   _cq_msgage="$_cq_val" ;;
                        QTIME)    _cq_qtime="$_cq_val" ;;
                        IPPROCS)  _cq_ipprocs="$_cq_val" ;;
                        OPPROCS)  _cq_opprocs="$_cq_val" ;;
                        UNCOM)    _cq_uncom="$_cq_val" ;;
                    esac
                done < "$_cq_qstatus_file"
            fi

            # Append optional queue fields
            [[ -n "$_cq_ipprocs" ]] && _cq_queue_json="${_cq_queue_json}, \"input_handles\": ${_cq_ipprocs}"
            [[ -n "$_cq_opprocs" ]] && _cq_queue_json="${_cq_queue_json}, \"output_handles\": ${_cq_opprocs}"
            if [[ -n "$_cq_uncom" ]]; then
                if [[ "$_cq_uncom" = "YES" ]]; then
                    _cq_queue_json="${_cq_queue_json}, \"uncommitted\": true"
                else
                    _cq_queue_json="${_cq_queue_json}, \"uncommitted\": false"
                fi
            fi
            [[ -n "$_cq_msgage" && "$_cq_msgage" != " " ]] && _cq_queue_json="${_cq_queue_json}, \"oldest_message_age\": ${_cq_msgage}"

            # Parse QTIME into short/long components: "12345, 67890" or " , "
            if [[ -n "$_cq_qtime" ]]; then
                _cq_qt_left="${_cq_qtime%%,*}"
                _cq_qt_right="${_cq_qtime#*,}"
                # Trim spaces
                while [[ "$_cq_qt_left" = " "* ]]; do _cq_qt_left="${_cq_qt_left# }"; done
                while [[ "$_cq_qt_left" = *" " ]]; do _cq_qt_left="${_cq_qt_left% }"; done
                while [[ "$_cq_qt_right" = " "* ]]; do _cq_qt_right="${_cq_qt_right# }"; done
                while [[ "$_cq_qt_right" = *" " ]]; do _cq_qt_right="${_cq_qt_right% }"; done
                [[ -n "$_cq_qt_left" ]] && _cq_queue_json="${_cq_queue_json}, \"queue_time_short\": ${_cq_qt_left}"
                [[ -n "$_cq_qt_right" ]] && _cq_queue_json="${_cq_queue_json}, \"queue_time_long\": ${_cq_qt_right}"
            fi

            # Compute timestamps and elapsed seconds
            _cq_last_put_ts=$(mq_to_iso "$_cq_lputdate" "$_cq_lputtime")
            _cq_last_get_ts=$(mq_to_iso "$_cq_lgetdate" "$_cq_lgettime")
            [[ -n "$_cq_last_put_ts" ]] && _cq_queue_json="${_cq_queue_json}, \"last_put_timestamp\": \"${_cq_last_put_ts}\""
            [[ -n "$_cq_last_get_ts" ]] && _cq_queue_json="${_cq_queue_json}, \"last_get_timestamp\": \"${_cq_last_get_ts}\""

            _cq_last_put_elapsed=$(elapsed_seconds "$_cq_last_put_ts" "$_cq_now_epoch")
            _cq_last_get_elapsed=$(elapsed_seconds "$_cq_last_get_ts" "$_cq_now_epoch")
            [[ -n "$_cq_last_put_elapsed" ]] && _cq_queue_json="${_cq_queue_json}, \"last_put_elapsed_seconds\": ${_cq_last_put_elapsed}"
            [[ -n "$_cq_last_get_elapsed" ]] && _cq_queue_json="${_cq_queue_json}, \"last_get_elapsed_seconds\": ${_cq_last_get_elapsed}"
        fi

        # Build the full ECS document
        _cq_doc="{ \"@timestamp\": \"${_cq_timestamp}\", \"ecs\": { \"version\": \"8.11.0\" }, \"event\": { \"kind\": \"metric\", \"category\": [\"host\"], \"type\": [\"info\"], \"module\": \"mq\", \"dataset\": \"mq.queue\" }, \"data_stream\": { \"type\": \"metrics\", \"dataset\": \"mq.queue\", \"namespace\": \"default\" }, \"host\": { \"name\": \"${HOSTNAME}\" }, \"agent\": { \"name\": \"${AGENT_NAME}\", \"version\": \"${AGENT_VERSION}\", \"type\": \"${AGENT_NAME}\" }, \"service\": { \"name\": \"ibm-mq\", \"type\": \"messaging\" }, \"mq\": { \"queue_manager\": { \"name\": \"${_cq_qmgr}\" }, \"queue\": { ${_cq_queue_json} } } }"

        # Append bulk action + document lines
        print "{ \"create\": { } }" >> "$_cq_bulkfile"
        print "$_cq_doc" >> "$_cq_bulkfile"

        total_queues=$((total_queues + 1))
    done

    # Cleanup temp dir
    rm -rf "$_cq_tmpdir"
}

# ============================================================================
# Send bulk payload to Elasticsearch
# ============================================================================
send_bulk() {
    _sb_bulkfile="$1"

    if [[ ! -s "$_sb_bulkfile" ]]; then
        log_info "No documents to send"
        return
    fi

    if [[ -z "$ELASTIC_URL" ]]; then
        # Dry-run: print each document (skip action lines)
        while read -r line; do
            case "$line" in
                '{ "create":'*) ;;
                *) print "$line" ;;
            esac
        done < "$_sb_bulkfile"
        return
    fi

    _sb_response_file="/tmp/mq-metrics-bulk-response.$$"
    _sb_http_code=$(curl -s -o "$_sb_response_file" -w '%{http_code}' \
        --connect-timeout 10 --max-time 60 \
        -X POST "${ELASTIC_URL}/${ELASTIC_INDEX}/_bulk" \
        -H "Content-Type: application/x-ndjson" \
        -H "Authorization: ApiKey ${ELASTIC_API_KEY}" \
        --data-binary @"$_sb_bulkfile" 2>/dev/null)

    if [[ "$_sb_http_code" != "200" ]]; then
        log_error "Bulk request failed - HTTP ${_sb_http_code}"
        total_errors=$((total_errors + 1))
    else
        # Check for per-item errors in the response
        if grep -q '"errors":true' "$_sb_response_file" 2>/dev/null; then
            log_error "Bulk request returned with item-level errors (HTTP 200)"
            total_errors=$((total_errors + 1))
        fi
    fi

    rm -f "$_sb_response_file"
}

# ============================================================================
# Main
# ============================================================================
main() {
    log_info "mq-metrics starting"

    # Build queue manager list
    if [[ -n "${QMGR_LIST}" ]]; then
        qmgrs=$(echo "${QMGR_LIST}" | tr ',' ' ')
    else
        qmgrs=$(discover_qmgrs)
    fi

    if [[ -z "${qmgrs}" ]]; then
        log_error "No running queue managers found"
        exit 1
    fi

    log_info "Queue managers: ${qmgrs}"

    _m_bulkfile="/tmp/mq-metrics-bulk.$$"
    > "$_m_bulkfile"

    for qm in ${qmgrs}; do
        log_info "Collecting metrics from ${qm}"
        collect_qmgr "$qm" "$_m_bulkfile"
    done

    send_bulk "$_m_bulkfile"
    rm -f "$_m_bulkfile"

    log_info "Done - ${total_queues} queues collected, ${total_errors} errors"
}

main "$@"
