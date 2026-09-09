# Troubleshooting Log — Multi-Region DR Setup

## Issue 1: Patroni cluster stuck "uninitialized" / "waiting for leader to bootstrap"

**Symptom:** Both Patroni nodes loop forever printing "waiting for leader to bootstrap",
`patronictl list` shows cluster as `(uninitialized)`.

**Root cause:** Patroni was configured entirely via `PATRONI_*` environment variables with
an empty `/patroni.yml` (`{}`). This particular Patroni/Postgres image combination requires
an explicit `bootstrap:` section (initdb params, pg_hba, DCS settings) in the YAML config —
env vars alone are not sufficient to trigger bootstrap.

**Fix:** Replaced env-var-only config with a full `patroni-<node>.yml` file (bootstrap,
postgresql, consul, restapi sections) mounted read-only into each container.

---

## Issue 2: Replica fails with "data directory has invalid permissions"

**Symptom:** One Patroni replica repeatedly fails to start:
FATAL: data directory "/data/patroni" has invalid permissions
DETAIL: Permissions should be u=rwx (0700) or u=rwx,g=rx (0750).

**Root cause:** After Patroni performs a basebackup from the leader to bootstrap a new
replica, the copied data directory sometimes ends up with permission bits that don't
satisfy PostgreSQL's strict directory permission check (must be exactly 0700 or 0750).

**Fix (immediate):**
```bash
docker exec -u root -it <container> chmod 0700 /data/patroni
docker exec -u root -it <container> chown -R postgres:postgres /data/patroni
docker restart <container>
```

**Fix (permanent):** Added an `entrypoint.sh` wrapper in the Patroni image that runs
`chmod 0700 /data/patroni` (if the directory exists) before exec-ing `patroni`, so every
container start self-heals this condition automatically.

---

## Issue 3 (major): Second custom Docker bridge network is unreachable from its own containers

**Symptom:** Containers on `region-a-net` (the first custom bridge network created) could
reach each other fine. Containers on `region-b-net` (created afterwards) could **not** reach
each other, even though they were on the same network — `curl` to a sibling container's
IP/hostname always timed out after connect, despite:
- DNS resolving correctly
- ARP resolving correctly (MAC address known)
- The container's TX packet counter incrementing (packet did leave the container)
- The veth pair showing `state UP`, `state forwarding`, attached to the correct bridge
- `iptables -L DOCKER-FORWARD` showing an ACCEPT rule for the bridge
- `br_netfilter` module loaded, `bridge-nf-call-iptables=1`

Packet captures at every layer (bridge interface, veth interface, `iptables -j LOG` in
`FORWARD`) showed the SYN packet reaching the container's own veth, but never appearing on
the destination container's veth, and never hitting the `FORWARD` chain at all — meaning
the drop happened purely inside L2 bridging, before Netfilter ever saw the packet.

**What did NOT fix it (tried and ruled out, in order):**
- Recreating the network / containers
- Restarting the Docker daemon (worked once, transiently, then failed again on next rebuild)
- Removing `libvirt` (a suspected source of conflicting `FORWARD`/NAT rules)
- Leaving Docker Swarm mode (removed `ingress` overlay network — unrelated but good cleanup)
- Manually inserting `iptables -I DOCKER-FORWARD -i <bridge> -j ACCEPT`
- Disabling NIC offload features (`tx`, `rx`, `tso`, `gso`, `gro`) on the veth via `ethtool`
- Rebooting the host machine
- Creating the two bridge networks in reverse order, or with a delay between them

**Isolating the pattern:** Whichever bridge network was created **second** consistently
failed — this was true whether Region A or Region B was created first. This points to a
Docker Engine 29.1.3 (this host) bug/race condition in how iptables rules are generated
for the *n*-th custom bridge network created in a session, not anything specific to Region
A or B's configuration.

**Working fix:** Instead of one bridge network per region, both regions share a single
Docker bridge network (`dr-net`, created once via `docker network create dr-net`, referenced
as `external: true` in both `region-a/docker-compose.yml` and `region-b/docker-compose.yml`).
Since only one custom bridge network is ever created, the bug never triggers. Region
isolation is still achieved logically — separate container names, separate Consul
datacenters (`dc-a`/`dc-b`), separate Postgres/Patroni ports — which is representative of
how two regions connected over a routed network (e.g. VPN/peering) would behave in a real
multi-region deployment.

**Follow-up for anyone hitting this on a different Docker/kernel version:** try upgrading/
downgrading Docker Engine, or check `journalctl -u docker` around the time of network
creation for iptables errors that might not surface in normal output.
