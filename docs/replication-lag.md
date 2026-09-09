# Replication Lag — Measurement Results

## Method
`scripts/measure-replication-lag.sh` inserts one row into `dr_test` on Region A's
Patroni leader every ~200ms for 30 seconds (100 rows total), then immediately
queries `pg_replication_slots` on Region A for `confirmed_flush_lsn` vs
`pg_current_wal_lsn()`, and compares row counts on both regions.

## Result (run on 2026-09-09)
- Rows inserted: 100
- Replication slot: `dr_sub`, active = true
- WAL lag at end of load: **0 bytes** (confirmed_flush_lsn == pg_current_wal_lsn)
- Row count Region A: 102 (100 load rows + 2 earlier manual test rows)
- Row count Region B (measured 2s after load stopped): 102 — **exact match**

## Interpretation
On this local Docker setup (same host, negligible network latency between
containers), logical replication keeps up with a sustained ~5 writes/sec load
with effectively zero measurable lag. In a real multi-region deployment over an
actual WAN link, expect lag to correlate with inter-region network RTT (typically
tens to low hundreds of ms for same-continent regions), not with write throughput
at this scale. This number establishes the baseline for the RPO test in Phase 5 —
any data loss measured there will be attributable to the failover detection/
promotion window, not to replication throughput being unable to keep up.
