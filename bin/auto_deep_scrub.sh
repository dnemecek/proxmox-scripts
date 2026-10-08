#!/bin/bash

# Nastavení loggingu
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Konfigurovatelné parametry
LOG_FILE="/var/log/ceph/deep_scrub.log"
SLEEP_BETWEEN=2          # Pauza mezi operacemi v sekundách

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

# Start skriptu
log "=== Začátek kontroly deep-scrub operací ==="

# Získat seznam PG se zpožděným deep-scrub
delayed_pgs=$(ceph health detail | grep 'pg ' | grep 'not deep-scrubbed' | awk '{print $2}' | sort -u)

if [ -z "$delayed_pgs" ]; then
    log "Žádné PG nejsou ve zpoždění pro deep-scrub."
    log "=== Konec kontroly ==="
    exit 0
fi

log "Nalezeny PG se zpožděným deep-scrub:"
for pg in $delayed_pgs; do
    log "- $pg"
done

# Zpracovat každou PG
for pg in $delayed_pgs; do
    # Kontrola stavu PG před spuštěním deep-scrub
    pg_state=$(ceph pg $pg query | grep '"state"' | head -1)
    
    if echo "$pg_state" | grep -q "scrubbing\|repair\|recovering"; then
        log "PG $pg je ve stavu $(echo $pg_state | grep -o 'active[^"]*') - přeskakuji"
        continue
    fi
    
    log "Spouštím deep-scrub na PG: $pg"
    ceph pg deep-scrub $pg
    if [ $? -eq 0 ]; then
        log "Deep-scrub pro PG $pg úspěšně spuštěn"
    else
        log "CHYBA: Spuštění deep-scrub pro PG $pg selhalo"
    fi
    
    log "Čekám $SLEEP_BETWEEN sekund..."
    sleep $SLEEP_BETWEEN
done

# Výpis finálního stavu
log "Aktuální stav clusteru:"
ceph -s >> $LOG_FILE 2>&1

log "=== Konec kontroly ==="

# Vyčistit staré logy (starší než 30 dní)
find /var/log/ceph -name "deep_scrub.log*" -mtime +30 -delete

exit 0