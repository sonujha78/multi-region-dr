#!/bin/bash
# Continuously monitors Region A. On confirmed total failure, promotes
# Region B (stops the subscription so it becomes standalone-authoritative)
# and logs every step with a timestamp for RTO measurement.
set -u

LOG_FILE=~/multi-region-dr/logs/failover-$(date +%Y%m%d-%H%M%S).log
CHECK_INTERVAL=3        # seconds between health checks
FAIL_THRESHOLD=3        # consecutive failed checks before declaring Region A down
FAIL_COUNT=0
REGION_A_DOWN=false

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" | tee -a "$LOG_FILE"
}

check_region_a_healthy() {
  # Region A is healthy if EITHER patroni-a1 or patroni-a2 responds 200 on /health
  A1=$(docker exec patroni-a1 curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8008/health 2>/dev/null)
  A2=$(docker exec patroni-a2 curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:8008/health 2>/dev/null)
  if [ "$A1" = "200" ] || [ "$A2" = "200" ]; then
    return 0
  else
    return 1
  fi
}

promote_region_b() {
  log "=== FAILOVER TRIGGERED: Region A confirmed down after $FAIL_THRESHOLD consecutive failed checks ==="
  T_DETECT=$(date +%s.%N)
  log "Detection complete. Beginning promotion of Region B."

  # Find current Region B Patroni leader
  B_LEADER=$(docker exec patroni-b1 curl -s http://localhost:8008/leader -o /dev/null -w "%{http_code}")
  if [ "$B_LEADER" = "200" ]; then
    LEADER_NODE="patroni-b1"
  else
    LEADER_NODE="patroni-b2"
  fi
  log "Region B current leader: $LEADER_NODE"

  # Stop the subscription so Region B no longer waits on / depends on dead Region A
  log "Disabling subscription dr_sub on $LEADER_NODE (stop pulling from Region A)..."
  docker exec "$LEADER_NODE" psql -h 127.0.0.1 -U postgres -c "ALTER SUBSCRIPTION dr_sub DISABLE;" 2>&1 | tee -a "$LOG_FILE"

  T_PROMOTE=$(date +%s.%N)
  log "Region B ($LEADER_NODE) is now standalone-authoritative primary."

  # HAProxy already auto-routes to backup (Region B) once all Region A checks fail;
  # confirm it here.
  sleep 2
  ROUTED_TO=$(curl -s http://localhost:7000/\;csv 2>/dev/null | awk -F, '$2 ~ /patroni-b/ && $18=="UP" {print $2}' | head -1)
  T_ROUTED=$(date +%s.%N)
  if [ -n "$ROUTED_TO" ]; then
    log "HAProxy confirmed routing writes to: $ROUTED_TO"
  else
    log "WARNING: HAProxy did not show a Region B server as UP yet."
  fi

  RTO=$(echo "$T_ROUTED - $T_DETECT" | bc)
  log "=== FAILOVER COMPLETE. RTO (detection-confirmed to traffic-routed): ${RTO}s ==="
  log "Log file: $LOG_FILE"
}

log "Starting Region A health monitor (interval=${CHECK_INTERVAL}s, threshold=${FAIL_THRESHOLD})"

while true; do
  if check_region_a_healthy; then
    if [ "$FAIL_COUNT" -gt 0 ]; then
      log "Region A recovered (was failing). Resetting failure count."
    fi
    FAIL_COUNT=0
    REGION_A_DOWN=false
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "Region A health check FAILED ($FAIL_COUNT/$FAIL_THRESHOLD)"
    if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ] && [ "$REGION_A_DOWN" = false ]; then
      REGION_A_DOWN=true
      promote_region_b
      log "Monitor will keep running to detect Region A recovery (for failback)."
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
