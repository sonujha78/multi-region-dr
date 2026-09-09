#!/bin/bash
# RPO/RTO test: writes continuously to Region A, kills Region A at a known
# point, then measures exactly how much data (if any) was lost and how long
# the application was unavailable.
set -u

RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_FILE=~/multi-region-dr/logs/rpo-rto-${RUN_ID}.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"; }

log "=== RPO/RTO TEST RUN $RUN_ID ==="

# Get starting id so we know exactly which rows this run writes
START_COUNT=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT count(*) FROM dr_test;" | tr -d '[:space:]')
log "Starting row count on Region A: $START_COUNT"

log "Beginning continuous write loop (1 insert per 0.1s) until Region A is killed..."
COUNT=0
(
  while true; do
    docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c \
      "INSERT INTO dr_test (message) VALUES ('rpo-test-${RUN_ID}-row-${COUNT}');" > /dev/null 2>&1
    COUNT=$((COUNT + 1))
    sleep 0.1
  done
) &
WRITER_PID=$!

log "Writer loop started (PID $WRITER_PID). Letting it run for 10 seconds before kill..."
sleep 10

# Capture last row A had written and confirmed, right before kill
LAST_WRITTEN=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT count(*) FROM dr_test;" | tr -d '[:space:]')
T_KILL=$(date +%s.%N)
log "Row count on Region A immediately before kill: $LAST_WRITTEN"
log ">>> KILLING REGION A NOW (docker stop patroni-a1 patroni-a2 consul-a) <<<"

docker stop patroni-a1 patroni-a2 consul-a > /dev/null 2>&1

kill "$WRITER_PID" 2>/dev/null
wait "$WRITER_PID" 2>/dev/null

log "Region A killed at $(date '+%Y-%m-%d %H:%M:%S.%3N')"
log "Waiting for automated failover (monitor script) to detect and promote Region B..."
log "(Watch the monitor-and-failover.sh terminal for live detection/promotion logs)"

# Poll Region B until it's confirmed serving as the new primary via HAProxy
DEADLINE=$(echo "$T_KILL + 60" | bc)
while true; do
  NOW=$(date +%s.%N)
  if (( $(echo "$NOW > $DEADLINE" | bc -l) )); then
    log "TIMEOUT: Region B not confirmed as primary within 60s."
    break
  fi
  ROUTED=$(curl -s http://localhost:7000/\;csv 2>/dev/null | awk -F, '$2 ~ /patroni-b/ && $18=="UP" {print $2}' | head -1)
  if [ -n "$ROUTED" ]; then
    T_RECOVERED=$(date +%s.%N)
    RTO=$(echo "$T_RECOVERED - $T_KILL" | bc)
    log "Region B ($ROUTED) confirmed UP and routed via HAProxy."
    log "=== RTO (kill to traffic restored): ${RTO}s ==="
    break
  fi
  sleep 1
done

# Now measure RPO: what Region B actually has vs what Region A had written
FINAL_B_COUNT=$(docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -t -c "SELECT count(*) FROM dr_test;" | tr -d '[:space:]')
log "Final row count on Region B: $FINAL_B_COUNT"
log "Row count Region A had at kill time: $LAST_WRITTEN"

RPO_ROWS=$((LAST_WRITTEN - FINAL_B_COUNT))
log "=== RPO: ${RPO_ROWS} row(s) lost (Region A had $LAST_WRITTEN, Region B has $FINAL_B_COUNT) ==="

log "Rows written by this test's writer loop before kill: $COUNT (approx, loop was killed)"
log "=== TEST RUN $RUN_ID COMPLETE. Full log: $LOG_FILE ==="
