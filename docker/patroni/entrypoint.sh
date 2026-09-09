#!/bin/bash
set -e
if [ -d /data/patroni ]; then
  chmod 0700 /data/patroni 2>/dev/null || true
fi
exec patroni /patroni.yml
