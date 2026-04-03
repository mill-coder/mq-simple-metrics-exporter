#!/bin/bash
#
# run-python-tests.sh - Build Python container and run mq-metrics.py integration tests
#
# Usage: ./tests/run-python-tests.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="mq-metrics-python-test"
CONTAINER_NAME="mq-metrics-python-test-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
failed=0

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    passed=$((passed + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    echo -e "       $2"
    failed=$((failed + 1))
}

# --------------------------------------------------------------------------
# Build container image
# --------------------------------------------------------------------------
echo "Building Python test container..."
podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile.python" "$PROJECT_DIR" >/dev/null 2>&1
echo "Build complete."
echo ""

# --------------------------------------------------------------------------
# Helper: run script inside container
# --------------------------------------------------------------------------
run_in_container() {
    podman run --rm --name "$CONTAINER_NAME" \
        --hostname test-host \
        -e "MQ_METRICS_QMGR_LIST=${MQ_METRICS_QMGR_LIST:-QM1}" \
        -e "MQ_METRICS_ELASTIC_URL=${MQ_METRICS_ELASTIC_URL:-}" \
        -e "MQ_METRICS_ELASTIC_API_KEY=${MQ_METRICS_ELASTIC_API_KEY:-}" \
        -e "MQ_METRICS_ELASTIC_INDEX=${MQ_METRICS_ELASTIC_INDEX:-metrics-mq.queue-default}" \
        -e "MQ_METRICS_EXCLUDE_QUEUES=${MQ_METRICS_EXCLUDE_QUEUES:-^SYSTEM\.|^AMQ\.}" \
        -e "MQ_METRICS_ADVANCED=${MQ_METRICS_ADVANCED:-}" \
        -e "MQ_METRICS_FILTER_WEBSPHERE=${MQ_METRICS_FILTER_WEBSPHERE:-1}" \
        "$IMAGE_NAME" /opt/mq-metrics.py "$@" 2>/tmp/mq-metrics-python-test-stderr.$$
}

# --------------------------------------------------------------------------
# Test 1: Basic mode (ADVANCED off) - dry-run
# --------------------------------------------------------------------------
echo "=== Test 1: Basic mode (no ADVANCED) ==="

MQ_METRICS_ADVANCED="" \
output=$(run_in_container)

# Should have 3 queues (SYSTEM.* excluded)
count=$(echo "$output" | grep -c '"depth"' || true)
if [[ "$count" -eq 3 ]]; then
    pass "3 queue documents produced (SYSTEM queue excluded)"
else
    fail "Expected 3 queue documents, got $count" "$output"
fi

# Should NOT have advanced fields
if echo "$output" | grep -q '"input_handles"'; then
    fail "Advanced fields present in basic mode" "Found input_handles"
else
    pass "No advanced fields in basic mode"
fi

if echo "$output" | grep -q '"depth_percent"'; then
    fail "depth_percent present in basic mode" "Should only appear with ADVANCED=1"
else
    pass "No depth_percent in basic mode"
fi

# Check basic JSON structure
if echo "$output" | grep -q '"queue_manager"'; then
    pass "mq.queue_manager present"
else
    fail "mq.queue_manager missing" "$output"
fi

if echo "$output" | grep -q '"service"'; then
    pass "service block present"
else
    fail "service block missing" "$output"
fi

# Check host.name uses container hostname
if echo "$output" | grep -q '"test-host"'; then
    pass "hostname set correctly"
else
    fail "hostname not set correctly" "$output"
fi

echo ""

# --------------------------------------------------------------------------
# Test 2: Advanced mode (ADVANCED=1) - dry-run
# --------------------------------------------------------------------------
echo "=== Test 2: Advanced mode (ADVANCED=1) ==="

MQ_METRICS_ADVANCED="1" \
output=$(run_in_container)

count=$(echo "$output" | grep -c '"depth"' || true)
if [[ "$count" -eq 3 ]]; then
    pass "3 queue documents produced"
else
    fail "Expected 3 queue documents, got $count" "$output"
fi

# Check advanced fields on APP.ORDERS.IN (has full QSTATUS data)
orders_in=$(echo "$output" | grep "APP.ORDERS.IN")
if echo "$orders_in" | grep -q '"input_handles": 1'; then
    pass "input_handles present for APP.ORDERS.IN"
else
    fail "input_handles missing for APP.ORDERS.IN" "$orders_in"
fi

if echo "$orders_in" | grep -q '"output_handles": 2'; then
    pass "output_handles present for APP.ORDERS.IN"
else
    fail "output_handles missing for APP.ORDERS.IN" "$orders_in"
fi

if echo "$orders_in" | grep -q '"uncommitted": false'; then
    pass "UNCOM(NO) mapped to uncommitted: false"
else
    fail "UNCOM mapping incorrect" "$orders_in"
fi

if echo "$orders_in" | grep -q '"oldest_message_age": 462'; then
    pass "MSGAGE(462) present"
else
    fail "MSGAGE missing" "$orders_in"
fi

if echo "$orders_in" | grep -q '"queue_time_short": 12345'; then
    pass "QTIME short component parsed"
else
    fail "QTIME short missing" "$orders_in"
fi

if echo "$orders_in" | grep -q '"queue_time_long": 67890'; then
    pass "QTIME long component parsed"
else
    fail "QTIME long missing" "$orders_in"
fi

if echo "$orders_in" | grep -q '"last_put_timestamp": "2026-04-03T15:24:19Z"'; then
    pass "LPUTDATE+LPUTTIME converted to ISO 8601"
else
    fail "last_put_timestamp incorrect" "$orders_in"
fi

if echo "$orders_in" | grep -q '"last_get_timestamp": "2026-04-03T14:30:05Z"'; then
    pass "LGETDATE+LGETTIME converted to ISO 8601"
else
    fail "last_get_timestamp incorrect" "$orders_in"
fi

# Check depth_percent for APP.ORDERS.IN: 17/10000 = 0.17
if echo "$orders_in" | grep -q '"depth_percent": 0.17'; then
    pass "depth_percent calculated correctly (17/10000 = 0.17)"
else
    fail "depth_percent incorrect for APP.ORDERS.IN" "$orders_in"
fi

# Check UNCOM(YES) mapping on APP.PAYMENTS.IN
payments_in=$(echo "$output" | grep "APP.PAYMENTS.IN")
if echo "$payments_in" | grep -q '"uncommitted": true'; then
    pass "UNCOM(YES) mapped to uncommitted: true"
else
    fail "UNCOM(YES) mapping incorrect" "$payments_in"
fi

# Check depth_percent for APP.PAYMENTS.IN: 250/50000 = 0.50
if echo "$payments_in" | grep -q '"depth_percent": 0.5'; then
    pass "depth_percent calculated correctly (250/50000 = 0.50)"
else
    fail "depth_percent incorrect for APP.PAYMENTS.IN" "$payments_in"
fi

echo ""

# --------------------------------------------------------------------------
# Test 3: Empty MONQ fields (APP.ORDERS.OUT has no timestamp data)
# --------------------------------------------------------------------------
echo "=== Test 3: Empty MONQ fields ==="

MQ_METRICS_ADVANCED="1" \
output=$(run_in_container)

orders_out=$(echo "$output" | grep "APP.ORDERS.OUT")

# LPUTDATE/LPUTTIME are blank - should NOT have last_put_timestamp
if echo "$orders_out" | grep -q '"last_put_timestamp"'; then
    fail "last_put_timestamp present for empty MONQ data" "$orders_out"
else
    pass "last_put_timestamp omitted for empty MONQ data"
fi

if echo "$orders_out" | grep -q '"last_get_timestamp"'; then
    fail "last_get_timestamp present for empty MONQ data" "$orders_out"
else
    pass "last_get_timestamp omitted for empty MONQ data"
fi

# QTIME( , ) should not produce queue_time fields
if echo "$orders_out" | grep -q '"queue_time_short"'; then
    fail "queue_time_short present for empty QTIME" "$orders_out"
else
    pass "queue_time_short omitted for empty QTIME"
fi

# depth_percent for 0/5000 = 0.0
if echo "$orders_out" | grep -q '"depth_percent": 0.0'; then
    pass "depth_percent 0.0 for empty queue"
else
    fail "depth_percent incorrect for empty queue" "$orders_out"
fi

echo ""

# --------------------------------------------------------------------------
# Test 4: Auto-discover queue managers
# --------------------------------------------------------------------------
echo "=== Test 4: Auto-discover queue managers ==="

MQ_METRICS_QMGR_LIST="" MQ_METRICS_ADVANCED="" \
output=$(run_in_container 2>/tmp/mq-metrics-python-test-stderr.$$ || true)
stderr=$(cat /tmp/mq-metrics-python-test-stderr.$$ 2>/dev/null || true)

# dspmq mock returns QM1 (Running) and QM2 (Ended normally) - only QM1 should be used
if echo "$stderr" | grep -q "Queue managers:.*QM1"; then
    pass "Auto-discovered QM1 from dspmq"
else
    fail "QM1 not discovered" "$stderr"
fi

if echo "$stderr" | grep -q "QM2"; then
    fail "QM2 (Ended normally) should not be discovered" "$stderr"
else
    pass "QM2 (Ended normally) correctly excluded"
fi

echo ""

# --------------------------------------------------------------------------
# Test 5: Valid JSON output (each line parses)
# --------------------------------------------------------------------------
echo "=== Test 5: Valid JSON output ==="

MQ_METRICS_ADVANCED="1" \
output=$(run_in_container)

json_ok=true
while IFS= read -r line; do
    if ! python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$line" 2>/dev/null; then
        json_ok=false
        break
    fi
done <<< "$output"

if $json_ok; then
    pass "All output lines are valid JSON"
else
    fail "Invalid JSON in output" "$line"
fi

echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "========================================"
total=$((passed + failed))
echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC} out of ${total} tests"
echo "========================================"

# Cleanup
rm -f /tmp/mq-metrics-python-test-stderr.$$

if [[ $failed -gt 0 ]]; then
    exit 1
fi
exit 0
