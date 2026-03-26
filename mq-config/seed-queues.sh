#!/usr/bin/env bash
# Seed IBM MQ queues with random test messages.
# Usage: ./mq-config/seed-queues.sh
#
# Requires the ibmmq container to be running and healthy.
# Uses podman exec + amqsput (shipped in the MQ container).

set -euo pipefail

CONTAINER="ibmmq"
QMGR="QM1"

QUEUES=(
  "APP.ORDERS.IN"
  "APP.ORDERS.OUT"
  "APP.PAYMENTS.IN"
  "APP.PAYMENTS.OUT"
  "APP.NOTIFY.EVENTS"
  "APP.NOTIFY.ALERTS"
  "APP.AUDIT.LOG"
  "APP.BATCH.REQUESTS"
  "DEV.QUEUE.1"
  "DEV.QUEUE.2"
  "DEV.QUEUE.3"
)

# Number of messages per queue (random between MIN and MAX)
MIN_MSGS=5
MAX_MSGS=30

put_messages() {
  local queue="$1"
  local count="$2"

  echo "  Putting ${count} messages on ${queue} ..."

  for i in $(seq 1 "$count"); do
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    local payload="{ \"seq\": ${i}, \"queue\": \"${queue}\", \"ts\": \"${ts}\", \"data\": \"test-message-$(head -c 16 /dev/urandom | xxd -p)\" }"

    # amqsput reads from stdin; send payload then empty line to end
    printf '%s\n\n' "$payload" | \
      podman exec -i "$CONTAINER" /opt/mqm/samp/bin/amqsput "$queue" "$QMGR" 2>/dev/null
  done
}

echo "Waiting for MQ container to be healthy..."
until podman healthcheck run "$CONTAINER" &>/dev/null; do
  sleep 2
done
echo "MQ is healthy."

echo "Seeding queues with random messages..."
for queue in "${QUEUES[@]}"; do
  count=$(( RANDOM % (MAX_MSGS - MIN_MSGS + 1) + MIN_MSGS ))
  put_messages "$queue" "$count"
done

echo "Done. Seeded all queues."
