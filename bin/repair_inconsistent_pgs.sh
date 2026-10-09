#!/bin/bash

# Nastaveni logovani
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Konfigurovatelne parametry
MAX_FORCE_RECOVERIES=20  # Maximalni pocet soubeznych force-recovery operaci
FORCE_AGE_DAYS=5        # Spustit force po X dnech bezici opravy
LOG_FILE="/var/log/ceph/pg_repair.log"

# Funkce pro logovani
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

# Kontrola existence log souboru a adresare
if [ ! -d "/var/log/ceph" ]; then
    mkdir -p /var/log/ceph
fi
touch $LOG_FILE

# Funkce pro zjisteni stari problemu
get_problem_age() {
    local pg=$1
    local last_change=$(ceph pg $pg query | grep last_change | head -1 | awk -F'"' '{print $4}')
    if [ -n "$last_change" ]; then
        local last_change_epoch=$(date -d "$last_change" +%s)
        local current_epoch=$(date +%s)
        local age_days=$(( (current_epoch - last_change_epoch) / 86400 ))
        echo $age_days
    else
        echo 0
    fi
}

# Start skriptu
log "=== Problematic PG check started ==="

# Ziskat seznam vsech problematickych PG
problematic_pgs=$(ceph health detail | grep -E "pg [0-9]+\.[0-9a-f]+" | grep -E 'inconsistent|unfound|degraded|down|incomplete|stale|peering|recovering|undersized|backfilling|backfill_toofull|backfill_wait|remapped' | awk '{print $2}' | sort -u)

if [ -z "$problematic_pgs" ]; then
    log "No problematic PGs found."
    log "=== Check finished ==="
    exit 0
fi

log "Found problematic PGs:"
for pg in $problematic_pgs; do
    log "- $pg"
done

# Projit kazdou problematickou PG
for pg in $problematic_pgs; do
    # Kontrola stavu PG
    pg_state=$(ceph pg $pg query | grep '"state"' | head -1)
    log "PG $pg - state $(echo $pg_state | grep -o 'active[^"]*')"
    
    # Rozdeleni podle typu problemu
    if echo "$pg_state" | grep -q "inconsistent"; then
        # Pro inconsistent spustime repair
        if ! echo "$pg_state" | grep -q "repair\|scrubbing"; then
            log "PG $pg is inconsistent - starting repair"
            ceph pg repair $pg
        else
            log "PG $pg - repair or scrub already running"
        fi
        
    elif echo "$pg_state" | grep -q "unfound"; then
        # Pro unfound objekty zvazime force-recovery
        age=$(get_problem_age $pg)
        if [ $age -ge $FORCE_AGE_DAYS ] && ! echo "$pg_state" | grep -q "forced_recovery"; then
            active_force=$(ceph pg dump | grep -c "forced_recovery")
            if [ $active_force -ge $MAX_FORCE_RECOVERIES ]; then
                log "force-recovery limit reached - skipping"
                continue
            fi
            log "PG $pg has had unfound objects for more than $FORCE_AGE_DAYS days - enabling force-recovery"
            ceph pg force-recovery $pg
        else
            log "PG $pg - waiting for recovery to finish or too early for force"
        fi
        
    elif echo "$pg_state" | grep -q "degraded"; then
        # Pro degraded sledujeme stav
        if ! echo "$pg_state" | grep -q "recovery\|backfilling"; then
            log "PG $pg is degraded but recovery is not running - check OSD status"
        else
            log "PG $pg - recovery of degraded state in progress"
        fi
        
    elif echo "$pg_state" | grep -q "stale"; then
        log "PG $pg is stale - OSDs may need checking"
    
    elif echo "$pg_state" | grep -q "down"; then
        log "PG $pg is down - check OSD availability"
    
    else
        log "PG $pg - monitoring only, no direct action needed"
    fi
done

# Vypis finalniho stavu
active_force=$(ceph pg dump | grep -c "forced_recovery")
log "Current force-recovery count: $active_force"
log "Current cluster status:"
ceph -s >> $LOG_FILE 2>&1

log "=== Check finished ==="

# Uklid starych logu (starsich nez 30 dni)
find /var/log/ceph -name "pg_repair.log*" -mtime +30 -delete

exit 0