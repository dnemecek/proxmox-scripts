#!/bin/bash
#
# Soubor: auto_deep_scrub.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: Spusti deep-scrub na PG, ktere Ceph hlasi jako not deep-scrubbed in time
#

# Nastaveni logovani
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Konfigurovatelne parametry
LOG_FILE="/var/log/ceph/deep_scrub.log"
SLEEP_BETWEEN=2          # Pauza mezi operacemi v sekundach

# Cil: Zapise zpravu s casovou znackou na stdout a do LOG_FILE.
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

# Kontrola existence log souboru a adresare
if [ ! -d "/var/log/ceph" ]; then
    mkdir -p /var/log/ceph
fi
touch $LOG_FILE

# Start skriptu
log "=== Deep-scrub check started ==="

# Ziskat seznam PG se zpozdenym deep-scrub
delayed_pgs=$(ceph health detail | grep 'pg ' | grep 'not deep-scrubbed' | awk '{print $2}' | sort -u)

if [ -z "$delayed_pgs" ]; then
    log "No PGs with overdue deep-scrub."
    log "=== Check finished ==="
    exit 0
fi

log "Found PGs with overdue deep-scrub:"
for pg in $delayed_pgs; do
    log "- $pg"
done

# Zpracovat kazdou PG
for pg in $delayed_pgs; do
    # Kontrola stavu PG pred spustenim deep-scrub
    pg_state=$(ceph pg $pg query | grep '"state"' | head -1)
    
    if echo "$pg_state" | grep -q "scrubbing\|repair\|recovering"; then
        log "PG $pg is in state $(echo $pg_state | grep -o 'active[^"]*') - skipping"
        continue
    fi
    
    log "Starting deep-scrub on PG: $pg"
    ceph pg deep-scrub $pg
    if [ $? -eq 0 ]; then
        log "Deep-scrub on PG $pg started successfully"
    else
        log "ERROR: Failed to start deep-scrub on PG $pg"
    fi
    
    log "Waiting $SLEEP_BETWEEN seconds..."
    sleep $SLEEP_BETWEEN
done

# Vypis finalniho stavu
log "Current cluster status:"
ceph -s >> $LOG_FILE 2>&1

log "=== Check finished ==="

# Uklid starych logu (starsich nez 30 dni)
find /var/log/ceph -name "deep_scrub.log*" -mtime +30 -delete

exit 0