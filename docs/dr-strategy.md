# DR Strategy: Active-Passive

## Decision
This setup uses **Active-Passive** replication: Region A serves all production traffic
by default. Region B runs a fully warm PostgreSQL replica (via cross-region logical
replication) and is promoted to primary only on failure of Region A.

## Why Active-Passive over Active-Active

**Active-Active was considered and rejected** for this exercise because:
- It requires either a conflict-resolution strategy (e.g. last-write-wins with
  timestamps) or partitioning writes by region/row so both regions never write the
  same row concurrently. Both add real application-level complexity and risk of
  silent data loss (LWW) or added latency (partitioning coordination).
- For a single logical database serving one application (not multi-tenant, not
  geo-partitioned by design), Active-Active adds operational complexity without a
  clear latency win, since most read/write traffic patterns here don't demand
  sub-region write locality.

**Active-Passive trade-off accepted:**
- Region B's compute capacity sits mostly idle until a failover — this is the cost
  we accept.
- In exchange we get a much simpler, more auditable system: one source of truth for
  writes at any given time, no conflict resolution logic, and RPO/RTO numbers that
  are straightforward to reason about and prove (the actual point of this exercise).

## Architecture Summary
- Region A: Patroni-managed 2-node PostgreSQL cluster (patroni-a1, patroni-a2),
  Consul (dc-a) for local leader election.
- Region B: Patroni-managed 2-node PostgreSQL cluster (patroni-b1, patroni-b2),
  Consul (dc-b) for local leader election.
- Cross-region: PostgreSQL logical replication from Region A's current Patroni
  leader to Region B's current Patroni leader (publication/subscription).
- Consul WAN federation links dc-a and dc-b so failover automation can observe
  both regions' health from either side.
- HAProxy / DNS-based routing directs application traffic to whichever region is
  currently "active" (starts as Region A).

## Failover trigger
Region A is considered down when all of: Patroni REST API health check fails on
both patroni-a1 and patroni-a2, AND consul-a's WAN gossip marks dc-a nodes as
`failed`, for a sustained period (see automated failover doc for exact timing).
This dual-signal approach avoids false-positive failover from a single flaky check.
