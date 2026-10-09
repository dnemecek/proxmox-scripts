#!/bin/bash

# Ziska seznam poolu a spusti force-recovery a force-backfill pro kazdy krome .mgr
for pool in $(ceph osd pool ls); do
    if [ "$pool" != ".mgr" ]; then
        echo "Forcing recovery and backfill for pool: $pool"
        ceph osd pool force-recovery $pool >/dev/null 2>&1
        ceph osd pool force-backfill $pool >/dev/null 2>&1
        echo "----------------------------------------"
    fi
done

# Zobrazi stav
echo "Current cluster status:"
ceph -s
