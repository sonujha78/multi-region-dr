# Architecture

## Components per region
- **2x Patroni-managed PostgreSQL nodes** (one leader, one intra-region replica)
- **1x Consul agent** — service discovery, leader election (intra-region), WAN
  federation (cross-region)
- **1x HAProxy** (shared, sits in front of both regions) — routes writes to
  whichever region's Patroni leader currently passes its `/leader` health check

## Replication direction
Region A's Patroni leader is the PostgreSQL logical replication **publisher**
(`dr_pub`). Region B's Patroni leader is the **subscriber** (`dr_sub`). This is
one-way, Active-Passive: Region B never accepts application writes while
Region A is healthy.

## Failover path
1. `monitor-and-failover.sh` polls both Region A Patroni nodes' `/health`
   endpoint every 3 seconds.
2. After 3 consecutive failures (~9s), Region A is declared down.
3. The subscription on Region B is disabled, making Region B's data
   authoritative (no longer waiting on a dead publisher).
4. HAProxy's own health checks (already polling `/leader` on all 4 nodes)
   detect all Region A servers are down and promote a Region B backup server
   to receiving traffic — no manual intervention.

## Failback path (planned, not automatic)
See `docs/dr-strategy.md` for the full procedure: Region A is reverse-synced
from Region B, confirmed to match, then forward replication is restored.

See the inline diagram shown during this session for the full component
layout (HAProxy, both regions' Patroni + Consul, replication and WAN links).
