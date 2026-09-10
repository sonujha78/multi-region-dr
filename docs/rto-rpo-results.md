# RTO/RPO Test Results

## Method
`scripts/rpo-rto-full-cycle.sh` runs an automated end-to-end cycle:
1. Verify both regions match before starting.
2. Write continuously to Region A for 8 seconds (~1 insert/0.1s).
3. Kill Region A completely (all Patroni + Consul containers).
4. Wait for `monitor-and-failover.sh` to detect the failure (3 consecutive
   failed health checks, 3s interval) and promote Region B.
5. Confirm HAProxy has switched routing to Region B.
6. Measure RTO (kill timestamp -> HAProxy routes to Region B) and RPO
   (Region A's last known max(id) vs Region B's max(id) after failover).
7. Bring Region A back, reverse-replicate from Region B, confirm exact
   match, then restore forward replication (A->B) for the next run.

## Results (3 consecutive runs, 2026-09-09)

| Run | RTO (s) | RPO (rows lost) | Notes |
|-----|---------|------------------|-------|
| 1   | 10.24   | 0                | Clean run |
| 2   | 10.25   | 0                | Clean run |
| 3   | 10.41   | 0                | Failback subscription took >60s to catch up; automatic pg_dump/restore fallback in the script completed the sync instead |

**RTO consistently ~10.2-10.4 seconds.** This breaks down as:
- ~3s: automated detection (3 checks x 3s interval — tunable via
  `CHECK_INTERVAL`/`FAIL_THRESHOLD` in monitor-and-failover.sh)
- ~2-7s: subscription disable + HAProxy health-check re-evaluation before
  it marks Region B's backup server UP (HAProxy's own check interval/fall
  count also contributes here)

**RPO: 0 rows lost in all 3 runs.** Because replication lag under load
was already measured at 0 bytes (see docs/replication-lag.md), and the
detection window only adds a few seconds, no committed transaction was
ever ahead of what Region B had received.

## A real bug this testing exposed
During run 2, an intra-region Patroni leader election (patroni-a1 ->
patroni-a2) silently broke the logical replication subscription, because
it was pointed at a hardcoded hostname. See
docs/troubleshooting.md (Issue 4) for the full root cause and the
production-correct fix (subscribe through a stable/HAProxy-fronted
endpoint, not a raw node hostname). This is exactly the kind of failure
mode that repeated DR testing is meant to surface before it happens in
an actual incident.
