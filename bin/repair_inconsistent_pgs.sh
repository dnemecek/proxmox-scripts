#!/bin/bash

# Nastavení loggingu
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Konfigurovatelné parametry
MAX_FORCE_RECOVERIES=20  # Maximální počet současných force-recovery operací
FORCE_AGE_DAYS=5        # Spustit force po X dnech běžící opravy
LOG_FILE="/var/log/ceph/pg_repair.log"

# Funkce pro logging
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

# Kontrola existence log souboru a adresáře
if [ ! -d "/var/log/ceph" ]; then
    mkdir -p /var/log/ceph
fi
touch $LOG_FILE

# Funkce pro získání stáří problému
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
log "=== Začátek kontroly problematických PG ==="

# Získat seznam všech problematických PG
problematic_pgs=$(ceph health detail | grep -E "pg [0-9]+\.[0-9a-f]+" | grep -E 'inconsistent|unfound|degraded|down|incomplete|stale|peering|recovering|undersized|backfilling|backfill_toofull|backfill_wait|remapped' | awk '{print $2}' | sort -u)

if [ -z "$problematic_pgs" ]; then
    log "Žádné problematické PG nebyly nalezeny."
    log "=== Konec kontroly ==="
    exit 0
fi

log "Nalezeny problematické PG:"
for pg in $problematic_pgs; do
    log "- $pg"
done

# Procházet každou problematickou PG
for pg in $problematic_pgs; do
    # Kontrola stavu PG
    pg_state=$(ceph pg $pg query | grep '"state"' | head -1)
    log "PG $pg - ve stavu $(echo $pg_state | grep -o 'active[^"]*')"
    
    # Rozdělení podle typu problému
    if echo "$pg_state" | grep -q "inconsistent"; then
        # Pro inconsistent spustíme repair
        if ! echo "$pg_state" | grep -q "repair\|scrubbing"; then
            log "PG $pg je inconsistent - spouštím repair"
            ceph pg repair $pg
        else
            log "PG $pg - již běží repair nebo scrub"
        fi
        
    elif echo "$pg_state" | grep -q "unfound"; then
        # Pro unfound objekty zvážíme force-recovery
        age=$(get_problem_age $pg)
        if [ $age -ge $FORCE_AGE_DAYS ] && ! echo "$pg_state" | grep -q "forced_recovery"; then
            active_force=$(ceph pg dump | grep -c "forced_recovery")
            if [ $active_force -ge $MAX_FORCE_RECOVERIES ]; then
                log "Dosažen limit force-recovery - přeskakuji"
                continue
            fi
            log "PG $pg má unfound objekty déle než $FORCE_AGE_DAYS dní - zapínám force-recovery"
            ceph pg force-recovery $pg
        else
            log "PG $pg - čekám na dokončení recovery nebo není ještě čas na force"
        fi
        
    elif echo "$pg_state" | grep -q "degraded"; then
        # Pro degraded sledujeme stav
        if ! echo "$pg_state" | grep -q "recovery\|backfilling"; then
            log "PG $pg je degraded ale neběží recovery - kontrola stavu OSDs"
        else
            log "PG $pg - probíhá recovery degradovaného stavu"
        fi
        
    elif echo "$pg_state" | grep -q "stale"; then
        log "PG $pg je stale - může vyžadovat kontrolu OSDs"
    
    elif echo "$pg_state" | grep -q "down"; then
        log "PG $pg je down - vyžaduje kontrolu dostupnosti OSDs"
    
    else
        log "PG $pg - monitoring stavu, není potřeba přímý zásah"
    fi
done

# Výpis finálního stavu
active_force=$(ceph pg dump | grep -c "forced_recovery")
log "Aktuální počet force-recovery: $active_force"
log "Aktuální stav clusteru:"
ceph -s >> $LOG_FILE 2>&1

log "=== Konec kontroly ==="

# Vyčistit staré logy (starší než 30 dní)
find /var/log/ceph -name "pg_repair.log*" -mtime +30 -delete

exit 0