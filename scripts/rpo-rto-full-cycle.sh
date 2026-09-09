#!/bin/bash
# Full cycle RTO/RPO test: write load -> kill Region A -> measure automated
# failover -> failback Region A -> restore forward replication -> ready for
# next run. Designed to be run multiple times to demonstrate consistency.
set -u

RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_FILE=~/multi-region-dr/logs/full-cycle-${RUN_ID}.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"; }

log "========== FULL CYCLE TEST RUN $RUN_ID =========="

# --- Pre-check: both regions must match before starting ---
A_MAX=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT coalesce(max(id),0) FROM dr_test;" 2>/dev/null | tr -d '[:space:]')
B_MAX=$(docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -t -c "SELECT coalesce(max(id),0) FROM dr_test;" 2>/dev/null | tr -d '[:space:]')
log "Pre-check: Region A max(id)=$A_MAX, Region B max(id)=$B_MAX"
if [ "$A_MAX" != "$B_MAX" ]; then
  log "ABORT: regions not in sync before test start."
  exit 1
fi

# --- Write load ---
log "Starting write load (1 insert/0.1s)..."
(
  while true; do
    docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c \
      "INSERT INTO dr_test (message) VALUES ('cycle-${RUN_ID}');" > /dev/null 2>&1
    sleep 0.1
  done
) &
WRITER_PID=$!
sleep 8

LAST_A_ID=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT max(id) FROM dr_test;" | tr -d '[:space:]')
T_KILL=$(date +%s.%N)
log "Region A max(id) just before kill: $LAST_A_ID"
log ">>> Killing Region A (patroni-a1, patroni-a2, consul-a) <<<"
docker stop patroni-a1 patroni-a2 consul-a > /dev/null 2>&1
kill "$WRITER_PID" 2>/dev/null; wait "$WRITER_PID" 2>/dev/null
log "Region A killed at $(date '+%Y-%m-%d %H:%M:%S.%3N')"

# --- Wait for automated failover (monitor-and-failover.sh handles detection+promotion) ---
DEADLINE=$(echo "$T_KILL + 60" | bc)
while true; do
  NOW=$(date +%s.%N)
  if (( $(echo "$NOW > $DEADLINE" | bc -l) )); then
    log "TIMEOUT waiting for HAProxy to route to Region B."
    break
  fi
  ROUTED=$(curl -s http://localhost:7000/\;csv 2>/dev/null | awk -F, '$2 ~ /patroni-b/ && $18=="UP" {print $2}' | head -1)
  if [ -n "$ROUTED" ]; then
    T_ROUTED=$(date +%s.%N)
    RTO=$(echo "$T_ROUTED - $T_KILL" | bc)
    log "HAProxy routing confirmed to $ROUTED. RTO = ${RTO}s"
    break
  fi
  sleep 0.5
done

FINAL_B_ID=$(docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -t -c "SELECT max(id) FROM dr_test;" | tr -d '[:space:]')
RPO_ROWS=$((LAST_A_ID - FINAL_B_ID))
log "Region B max(id) after failover: $FINAL_B_ID"
log "=== RESULT: RTO=${RTO}s, RPO=${RPO_ROWS} row(s) (negative/zero = no loss) ==="

# --- Failback: bring Region A up, reverse-sync from B, restore forward direction ---
log "--- Beginning failback ---"
cd ~/multi-region-dr/region-a
docker compose up -d > /dev/null 2>&1
log "Region A containers restarted. Waiting for Patroni to stabilize..."
sleep 15

docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "DROP SUBSCRIPTION IF EXISTS dr_sub_failback;" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "DROP PUBLICATION IF EXISTS dr_pub_failback;" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "CREATE PUBLICATION dr_pub_failback FOR TABLE dr_test;" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "TRUNCATE dr_test RESTART IDENTITY;" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "
CREATE SUBSCRIPTION dr_sub_failback
CONNECTION 'host=patroni-b1 port=5432 dbname=postgres user=replicator password=replpass'
PUBLICATION dr_pub_failback;
" > /dev/null 2>&1

log "Waiting for Region A to catch up from Region B..."
for i in $(seq 1 30); do
  A_ID=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT coalesce(max(id),0) FROM dr_test;" 2>/dev/null | tr -d '[:space:]')
  if [ "$A_ID" = "$FINAL_B_ID" ]; then
    log "Region A caught up (max(id)=$A_ID) after failback sync."
    break
  fi
  sleep 2
done
if [ "$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT coalesce(max(id),0) FROM dr_test;" 2>/dev/null | tr -d "[:space:]")" != "$FINAL_B_ID" ]; then
  log "Region A did not catch up via subscription in time; forcing pg_dump/restore fallback."
  docker exec patroni-b1 pg_dump -h 127.0.0.1 -U postgres -t dr_test --data-only postgres > /tmp/dr_test_data.sql 2>/dev/null
  docker exec -i patroni-a1 psql -h 127.0.0.1 -U postgres postgres < /tmp/dr_test_data.sql > /dev/null 2>&1
  log "Fallback data copy applied."
fi

# --- Restore forward direction (A -> B) for next run ---
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "ALTER SUBSCRIPTION dr_sub_failback DISABLE;" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "ALTER SUBSCRIPTION dr_sub_failback SET (slot_name = NONE);" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "DROP SUBSCRIPTION dr_sub_failback;" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "DROP PUBLICATION IF EXISTS dr_pub_failback;" > /dev/null 2>&1

docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "ALTER SUBSCRIPTION dr_sub DISABLE;" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "ALTER SUBSCRIPTION dr_sub SET (slot_name = NONE);" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "DROP SUBSCRIPTION dr_sub;" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "DROP PUBLICATION IF EXISTS dr_pub;" > /dev/null 2>&1
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "CREATE PUBLICATION dr_pub FOR TABLE dr_test;" > /dev/null 2>&1
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -c "
CREATE SUBSCRIPTION dr_sub
CONNECTION 'host=patroni-a1 port=5432 dbname=postgres user=replicator password=replpass'
PUBLICATION dr_pub;
" > /dev/null 2>&1

sleep 5
A_FINAL=$(docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT max(id) FROM dr_test;" | tr -d '[:space:]')
B_FINAL=$(docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -t -c "SELECT max(id) FROM dr_test;" | tr -d '[:space:]')
log "Post-failback state: Region A max(id)=$A_FINAL, Region B max(id)=$B_FINAL"
log "========== RUN $RUN_ID COMPLETE (RTO=${RTO}s, RPO=${RPO_ROWS} rows) =========="
echo ""
