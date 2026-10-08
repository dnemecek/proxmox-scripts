#!/bin/bash
# ceph_pg_diagnosis.sh
# verze 2.0.0
# Minimalistický diagnostický skript pro Ceph PG
# Pouze základní funkce - žádná složitost

set -euo pipefail

# Konfigurace
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
LOG_FILE="${SCRIPT_NAME}.log"
PG_ID="${1:-}"
OUTPUT_FORMAT="${2:-human}"  # human|json

# Jednoduché logování
log() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"  # Pouze do logu
    fi
}

# Kontrola Ceph připojení
if ! ceph status &>/dev/null; then
    log "CHYBA: Nelze se připojit k Ceph clusteru"
    exit 1
fi

log "=== Ceph PG Diagnostika ==="

# Autodetekce nebo konkrétní PG?
if [[ -z "$PG_ID" ]]; then
    log "Režim: Autodetekce problematických PG"
    
    # Najdi problematická PG z health detail
    PROBLEMATIC_PGS=$(ceph health detail 2>/dev/null | grep -oE 'pg [0-9]+\.[0-9a-f]+' | awk '{print $2}' | sort -u)
    
    if [[ -z "$PROBLEMATIC_PGS" ]]; then
        log "✅ Žádná problematická PG nenalezena - cluster je v pořádku"
        exit 0
    fi
    
    log "🔍 Nalezena problematická PG:"
    for pg in $PROBLEMATIC_PGS; do
        log "  - $pg"
    done
    
    # Analyzuj první problematické PG
    PG_ID=$(echo "$PROBLEMATIC_PGS" | head -1)
    log "📊 Analyzuji PG: $PG_ID"
else
    log "Režim: Analýza konkrétního PG $PG_ID"
fi

# Základní info o PG
log "--- Základní informace ---"
PG_HEALTH=$(ceph health detail 2>/dev/null | grep "pg $PG_ID" || echo "PG nenalezeno v health detail")
log "$PG_HEALTH"

# Detailní stav PG
log "--- Detailní stav ---"
ceph pg $PG_ID query 2>/dev/null | grep -E "(state_name|acting|up)" | head -5 | while read -r line; do
    log "$line"
done

# OSD logy pro acting OSD
log "--- OSD logy (posledních 10 chyb) ---"
ACTING_OSDS=$(echo "$PG_HEALTH" | grep -oE 'acting \[[0-9,]+\]' | grep -oE '[0-9,]+' | tr ',' ' ')

for osd in $ACTING_OSDS; do
    if [[ -n "$osd" ]]; then
        log "OSD.$osd chyby:"
        
        # Zjisti na kterém serveru je OSD
        osd_host=$(ceph osd find $osd 2>/dev/null | grep -o '"host":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
        
        if [[ -n "$osd_host" ]] && [[ "$osd_host" != "$(hostname)" ]]; then
            # OSD je na jiném serveru - použij SSH
            log "  (OSD.$osd je na serveru $osd_host)"
            ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$osd_host" \
                "grep -i '$PG_ID' /var/log/ceph/ceph-osd.$osd.log 2>/dev/null | grep -iE '(error|inconsistent|corrupt)' | tail -3" 2>/dev/null | \
            while read -r error; do
                if [[ -n "$error" ]]; then
                    log "  $error"
                fi
            done || log "  (Nelze se připojit na $osd_host nebo žádné chyby)"
        else
            # OSD je na lokálním serveru
            journalctl -u ceph-osd@"$osd" --since "24 hours ago" --no-pager 2>/dev/null | \
            grep -i "$PG_ID" | grep -iE "(error|inconsistent|corrupt)" | tail -3 | \
            while read -r error; do
                if [[ -n "$error" ]]; then
                    log "  $error"
                fi
            done || log "  (Žádné chyby za posledních 24 hodin)"
        fi
    fi
done

# Doporučení
log "--- Doporučení ---"
if echo "$PG_HEALTH" | grep -q "snaptrim_wait"; then
    log "⏳ PG čeká na dokončení snapshot cleanup"
    log "💡 Doporučené kroky:"
    log "   1. Počkejte na dokončení snaptrim procesu"
    log "   2. Sledujte: watch 'ceph pg ls | grep snaptrim'"
    log "   3. Problém by se měl vyřešit automaticky"
elif echo "$PG_HEALTH" | grep -q "failed_repair"; then
    log "⚠️  PG má failed_repair - selhala automatická oprava"
    log "💡 Doporučené kroky:"
    log "   1. ceph pg deep-scrub $PG_ID"
    log "   2. Pokud selže: ceph pg repair $PG_ID"
    log "   3. Krajní řešení: ceph pg mark-unfound-lost $PG_ID --yes-i-really-mean-it"
elif echo "$PG_HEALTH" | grep -q "inconsistent"; then
    log "⚠️  PG má nekonzistentní data"
    log "💡 Doporučené kroky:"
    log "   1. ceph pg repair $PG_ID"
    log "   2. Pokud selže: ceph pg deep-scrub $PG_ID"
else
    log "ℹ️  Standardní problém"
    log "💡 Zkuste: ceph pg repair $PG_ID"
fi

log "=== Diagnostika dokončena ==="
log "📋 Log uložen do: $(pwd)/$LOG_FILE"

# JSON výstup pro Ansible
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Extrakce acting OSD
    ACTING_OSDS_JSON=$(echo "$PG_HEALTH" | grep -oE 'acting \[[0-9,]+\]' | grep -oE '[0-9,]+' | sed 's/,/","/g; s/^/"/; s/$/"/')
    
    # Určení stavu a doporučení
    REQUIRES_REPAIR="false"
    SAFE_TO_REPAIR="true"
    if echo "$PG_HEALTH" | grep -qE "(inconsistent|incomplete|down|degraded)"; then
        REQUIRES_REPAIR="true"
    fi
    if echo "$PG_HEALTH" | grep -q "failed_repair"; then
        SAFE_TO_REPAIR="false"
    fi
    
    cat <<EOF
{
  "pg_id": "$PG_ID",
  "state": "$(echo "$PG_HEALTH" | grep -oE 'is [^,]+' | cut -d' ' -f2-)",
  "acting_osds": [$ACTING_OSDS_JSON],
  "requires_repair": $REQUIRES_REPAIR,
  "safe_to_repair": $SAFE_TO_REPAIR,
  "analysis_timestamp": "$(date -Iseconds)"
}
EOF
else
    log "💡 Pro Ansible použijte: $0 [PG_ID] json"
fi

# Exit code podle stavu
if echo "$PG_HEALTH" | grep -qE "(inconsistent|incomplete|down|degraded)"; then
    exit 2  # PG má problémy
else
    exit 0  # PG je v pořádku
fi
