#!/bin/bash

# Získá seznam poolů a spustí force-recovery a force-backfill pro každý kromě .mgr
for pool in $(ceph osd pool ls); do
    if [ "$pool" != ".mgr" ]; then
        echo "Forcing recovery and backfill for pool: $pool"
        ceph osd pool force-recovery $pool >/dev/null 2>&1
        ceph osd pool force-backfill $pool >/dev/null 2>&1
        echo "----------------------------------------"
    fi
done

# Zobrazí stav
echo "Current cluster status:"
ceph -s
