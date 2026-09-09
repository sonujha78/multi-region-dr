#!/bin/bash
# Measures logical replication lag from Region A to Region B under continuous write load.
set -e

echo "Starting continuous insert load on Region A for 30 seconds..."
END_TIME=$((SECONDS + 30))
COUNT=0

while [ $SECONDS -lt $END_TIME ]; do
  docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c \
    "INSERT INTO dr_test (message) VALUES ('load-test-msg-$COUNT');" > /dev/null
  COUNT=$((COUNT + 1))
  sleep 0.2
done

echo "Inserted $COUNT rows. Measuring lag..."
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -c "
SELECT slot_name, active,
       pg_current_wal_lsn() AS current_lsn,
       confirmed_flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
FROM pg_replication_slots WHERE slot_name = 'dr_sub';
"

echo "Row count on Region A:"
docker exec patroni-a1 psql -h 127.0.0.1 -U postgres -t -c "SELECT count(*) FROM dr_test;"

echo "Row count on Region B (should match after replication catches up):"
sleep 2
docker exec patroni-b1 psql -h 127.0.0.1 -U postgres -t -c "SELECT count(*) FROM dr_test;"
