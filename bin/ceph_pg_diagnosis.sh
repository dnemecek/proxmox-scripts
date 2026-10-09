#!/bin/bash
# ceph_pg_diagnosis.sh
# verze 2.0.0
# Minimalisticky diagnosticky skript pro Ceph PG

set -euo pipefail

# Konfigurace
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
LOG_FILE="${SCRIPT_NAME}.log"
PG_ID="${1:-}"
OUTPUT_FORMAT="${2:-human}"  # human|json

# Jednoduche logovani
log() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"  # Jen do logu
    fi
}

# Kontrola pripojeni k Ceph
if ! ceph status &>/dev/null; then
    log "ERROR: Cannot connect to Ceph cluster"
    exit 1
fi

log "=== Ceph PG Diagnostics ==="

# Autodetekce, nebo konkretni PG?
if [[ -z "$PG_ID" ]]; then
    log "Mode: auto-detect problematic PGs"
    
    # Najdi problematicka PG z health detail
    PROBLEMATIC_PGS=$(ceph health detail 2>/dev/null | grep -oE 'pg [0-9]+\.[0-9a-f]+' | awk '{print $2}' | sort -u)
    
    if [[ -z "$PROBLEMATIC_PGS" ]]; then
        log "No problematic PGs found - cluster is healthy"
        exit 0
    fi
    
    log "Problematic PGs found:"
    for pg in $PROBLEMATIC_PGS; do
        log "  - $pg"
    done
    
    # Analyzuj prvni problematicke PG
    PG_ID=$(echo "$PROBLEMATIC_PGS" | head -1)
    log "Analyzing PG: $PG_ID"
else
    log "Mode: analyze specific PG $PG_ID"
fi

# Zakladni informace o PG
log "--- Basic information ---"
PG_HEALTH=$(ceph health detail 2>/dev/null | grep "pg $PG_ID" || echo "PG not found in health detail")
log "$PG_HEALTH"

# Detailni stav PG
log "--- Detailed state ---"
ceph pg $PG_ID query 2>/dev/null | grep -E "(state_name|acting|up)" | head -5 | while read -r line; do
    log "$line"
done

# OSD logy pro acting OSD
log "--- OSD logs (last errors) ---"
ACTING_OSDS=$(echo "$PG_HEALTH" | grep -oE 'acting \[[0-9,]+\]' | grep -oE '[0-9,]+' | tr ',' ' ')

for osd in $ACTING_OSDS; do
    if [[ -n "$osd" ]]; then
        log "OSD.$osd errors:"
        
        # Zjisti, na kterem serveru je OSD
        osd_host=$(ceph osd find $osd 2>/dev/null | grep -o '"host":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
        
        if [[ -n "$osd_host" ]] && [[ "$osd_host" != "$(hostname)" ]]; then
            # OSD je na jinem serveru - pouzij SSH
            log "  (OSD.$osd is on host $osd_host)"
            ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$osd_host" \
                "grep -i '$PG_ID' /var/log/ceph/ceph-osd.$osd.log 2>/dev/null | grep -iE '(error|inconsistent|corrupt)' | tail -3" 2>/dev/null | \
            while read -r error; do
                if [[ -n "$error" ]]; then
                    log "  $error"
                fi
            done || log "  (Cannot connect to $osd_host or no errors)"
        else
            # OSD je na lokalnim serveru
            journalctl -u ceph-osd@"$osd" --since "24 hours ago" --no-pager 2>/dev/null | \
            grep -i "$PG_ID" | grep -iE "(error|inconsistent|corrupt)" | tail -3 | \
            while read -r error; do
                if [[ -n "$error" ]]; then
                    log "  $error"
                fi
            done || log "  (No errors in the last 24 hours)"
        fi
    fi
done

# Doporuceni
log "--- Recommendations ---"
if echo "$PG_HEALTH" | grep -q "snaptrim_wait"; then
    log "PG is waiting for snapshot cleanup (snaptrim) to finish"
    log "Recommended steps:"
    log "   1. Wait for the snaptrim process to finish"
    log "   2. Monitor: watch 'ceph pg ls | grep snaptrim'"
    log "   3. The issue should resolve automatically"
elif echo "$PG_HEALTH" | grep -q "failed_repair"; then
    log "WARNING: PG has failed_repair - automatic repair failed"
    log "Recommended steps:"
    log "   1. ceph pg deep-scrub $PG_ID"
    log "   2. If it fails: ceph pg repair $PG_ID"
    log "   3. Last resort: ceph pg mark-unfound-lost $PG_ID --yes-i-really-mean-it"
elif echo "$PG_HEALTH" | grep -q "inconsistent"; then
    log "WARNING: PG has inconsistent data"
    log "Recommended steps:"
    log "   1. ceph pg repair $PG_ID"
    log "   2. If it fails: ceph pg deep-scrub $PG_ID"
else
    log "INFO: Generic issue"
    log "Try: ceph pg repair $PG_ID"
fi

log "=== Diagnostics complete ==="
log "Log saved to: $(pwd)/$LOG_FILE"

# JSON vystup pro Ansible
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Extrakce acting OSD
    ACTING_OSDS_JSON=$(echo "$PG_HEALTH" | grep -oE 'acting \[[0-9,]+\]' | grep -oE '[0-9,]+' | sed 's/,/","/g; s/^/"/; s/$/"/')
    
    # Urceni stavu a doporuceni
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
    log "For Ansible use: $0 [PG_ID] json"
fi

# Navratovy kod podle stavu
if echo "$PG_HEALTH" | grep -qE "(inconsistent|incomplete|down|degraded)"; then
    exit 2  # PG ma problemy
else
    exit 0  # PG je v poradku
fi
