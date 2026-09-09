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

## Failback Procedure (validated)

After Region A recovers from a failure, failback is a **deliberate, planned
operation** — not automatic. This is intentional: an automatic failback could
re-promote a region whose underlying failure cause hasn't actually been fixed
(e.g. flapping network), causing a second outage. The steps below were tested
and validated:

1. Confirm Region A's Patroni cluster is healthy again (`patronictl list`).
2. Drop any leftover forward-direction publication/subscription objects.
3. Create a **reverse** publication on Region B (now the authoritative primary)
   and a subscription on Region A, so Region A catches up on all writes it
   missed while it was down.
4. Once Region A's row count/max(id) matches Region B exactly, Region A is
   caught up.
5. To fully failback (Region A becomes primary again): disable the reverse
   subscription on Region A, then recreate the original forward publication
   (Region A -> Region B) and subscription, restoring the normal
   Active-Passive direction. Update HAProxy back to treating Region A as
   primary, Region B as backup.
6. Alternative (often preferred operationally): **skip step 5** and simply
   leave Region B as the new permanent primary, treating Region A as the new
   standby going forward — avoids a second cutover and its risk window.

This exercise validated steps 1-4 end-to-end: Region A was killed, Region B
was promoted (see RTO/RPO test), Region A was brought back, reverse-replicated
from Region B, and confirmed to match exactly (`max(id)=156, count=156` on
both sides) before the forward direction was restored for repeat testing.
