#!/bin/bash
#
# Soubor: ceph_osd_restart.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: Postupny restart Ceph OSD (vsech, nebo jen hlasicich BlueStore slow operations)
#
# Ansible-ready skript pro restart Ceph OSD
# - Bez parametru: restart vsech OSD sekvencne
# - --slow: restart pouze OSD hlasicich BlueStore slow operations
# - --dry-run: zobrazi plan bez provedeni
#
# Umisteni: ~/bin/ceph_osd_restart.sh (na vsech PVE nodech)
# Konfigurace: ~/bin/ceph_osd_restart.conf
# Log: /var/log/ceph_osd_restart.log
#

set -o pipefail

# -----------------------------------------------------------------------------
# Konfigurace
# -----------------------------------------------------------------------------
SCRIPT_NAME="ceph_osd_restart"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.conf"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"

# Vychozi hodnoty (lze prepsat v .conf)
RESTART_DELAY=90
CURRENT_NODE=$(hostname)

# Nacti konfiguraci pokud existuje
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Runtime promenne
MODE="all"
DRY_RUN=false
CHANGED=false
RESTARTED=0
SKIPPED=0
FAILED=0

# Cil: Zapise zpravu s urovni a casovou znackou do LOG_FILE.
log_msg() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${msg}" >> "$LOG_FILE"
}

# Cil: Zkratky pro log_msg podle urovne.
log_info()  { log_msg "INFO"  "$1"; }
log_warn()  { log_msg "WARN"  "$1"; }
log_error() { log_msg "ERROR" "$1"; }

# Cil: Vypise na stdout jednoradkovy JSON vysledek pro Ansible (changed, msg).
json_output() {
    local changed="$1"
    local msg="$2"
    echo "{\"changed\": ${changed}, \"reboot_required\": false, \"msg\": \"${msg}\"}"
}

# Cil: Vypise napovedu k pouziti skriptu.
show_help() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Ceph OSD Restart Script

Usage: ${SCRIPT_NAME}.sh [OPTIONS]

Options:
  --slow      Restart only OSDs reporting BlueStore slow operations
  --dry-run   Show what would be done without making changes
  --help      Show this help message

Examples:
  ${SCRIPT_NAME}.sh              # Restart all OSDs sequentially
  ${SCRIPT_NAME}.sh --slow       # Restart only slow OSDs
  ${SCRIPT_NAME}.sh --slow --dry-run  # Show slow OSDs without restart

Exit codes:
  0  Success
  1  Error
EOF
}

# Cil: Vypise ID OSD, ktera v ceph health detail hlasi BlueStore slow operations (serazena, bez duplicit).
# Mantinely: Jen cte; vyzaduje funkcni ceph CLI; pri chybe ceph je vystup prazdny.
# Kontrola: Prazdny vystup = zadna slow OSD; hlavni beh to vrati v JSON vystupu.
get_slow_osds() {
    # Hleda radky: "osd.XX observed slow operation indications in BlueStore"
    ceph health detail 2>/dev/null | \
        grep "observed slow operation" | \
        grep -oE "osd\.[0-9]+" | \
        sed 's/osd\.//' | \
        sort -n | \
        uniq
}

# Cil: Vypise ID vsech OSD z ceph osd tree (serazena).
# Mantinely: Jen cte; vyzaduje funkcni ceph CLI; pri chybe ceph je vystup prazdny.
# Kontrola: Prazdny vystup = zadna OSD; hlavni beh to vrati v JSON vystupu.
get_all_osds() {
    ceph osd tree 2>/dev/null | \
        grep -E "^\s*[0-9]+" | \
        awk '{print $1}' | \
        sort -n
}

# Cil: Vypise nazev nodu, na kterem lezi zadane OSD, podle ceph osd tree.
# Mantinely: Vstup je ciselne ID OSD; jen cte; predpoklada nazev hostu ve 4. sloupci radku host.
# Kontrola: Prazdny vystup = node nenalezen; restart_osd to zaloguje jako chybu.
get_osd_node() {
    local osd_id="$1"
    local node=""
    local current_host=""
    
    while read -r line; do
        if echo "$line" | grep -q "host"; then
            current_host=$(echo "$line" | awk '{print $4}')
        elif echo "$line" | grep -qE "^\s*${osd_id}\s+"; then
            node="$current_host"
            break
        fi
    done < <(ceph osd tree 2>/dev/null)
    
    echo "$node"
}

# Cil: Restartuje jedno OSD lokalne nebo pres SSH na jeho nodu a aktualizuje citace RESTARTED/SKIPPED/FAILED.
# Mantinely: Restartuje jen po uspesnem ceph osd ok-to-stop; v dry-run nic nemeni; SSH jen v BatchMode.
# Kontrola: Navratovy kod systemctl restart, zapis do logu a citacu; navratovy kod 1 = chyba.
restart_osd() {
    local osd_id="$1"
    local node
    node=$(get_osd_node "$osd_id")
    
    if [[ -z "$node" ]]; then
        log_error "Cannot find node for osd.${osd_id}"
        ((FAILED++))
        return 1
    fi
    
    # Kontrola ok-to-stop
    if ! ceph osd ok-to-stop "osd.${osd_id}" &>/dev/null; then
        log_warn "osd.${osd_id} - ok-to-stop check failed, skipping"
        ((SKIPPED++))
        return 0
    fi
    
    log_info "Restarting osd.${osd_id} on ${node}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would restart osd.${osd_id} on ${node}"
        return 0
    fi
    
    # Restart - lokalne nebo pres SSH
    local restart_result=0
    if [[ "$node" == "$CURRENT_NODE" ]]; then
        systemctl restart "ceph-osd@${osd_id}" || restart_result=$?
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$node" \
            "systemctl restart ceph-osd@${osd_id}" || restart_result=$?
    fi
    
    if [[ $restart_result -eq 0 ]]; then
        log_info "osd.${osd_id} restarted successfully"
        ((RESTARTED++))
        CHANGED=true
    else
        log_error "osd.${osd_id} restart failed (exit code: ${restart_result})"
        ((FAILED++))
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Zpracovani argumentu
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --slow)
            MODE="slow"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Hlavni beh
# -----------------------------------------------------------------------------
log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
log_info "Mode: ${MODE}, Dry-run: ${DRY_RUN}"

# Ziskej seznam OSD k restartu
declare -a osd_list
if [[ "$MODE" == "slow" ]]; then
    mapfile -t osd_list < <(get_slow_osds)
else
    mapfile -t osd_list < <(get_all_osds)
fi

osd_count=${#osd_list[@]}
log_info "Found ${osd_count} OSD(s) to process"

# Kontrola - zadna OSD
if [[ $osd_count -eq 0 ]]; then
    log_info "No OSDs to restart"
    if [[ "$MODE" == "slow" ]]; then
        json_output "false" "Mode: slow, No slow OSDs detected"
    else
        json_output "false" "Mode: all, No OSDs found in cluster"
    fi
    exit 0
fi

# Dry-run - jen vypis
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would restart: ${osd_list[*]}"
    json_output "false" "Mode: ${MODE}, Dry-run: ${osd_count} OSD(s) would be restarted"
    exit 0
fi

# Restart OSD sekvencne
for osd_id in "${osd_list[@]}"; do
    restart_osd "$osd_id"
    
    # Pauza mezi restarty (krome posledniho)
    if [[ "$osd_id" != "${osd_list[-1]}" ]]; then
        log_info "Waiting ${RESTART_DELAY}s before next restart..."
        sleep "$RESTART_DELAY"
    fi
done

# Archivuj ceph crash logy
log_info "Archiving ceph crash logs"
ceph crash archive-all &>/dev/null || true

# Vysledek
log_info "Completed: Restarted=${RESTARTED}, Skipped=${SKIPPED}, Failed=${FAILED}"
log_info "=== ${SCRIPT_NAME} finished ==="

# JSON vystup
if [[ $FAILED -gt 0 ]]; then
    json_output "true" "Mode: ${MODE}, Restarted: ${RESTARTED}, Skipped: ${SKIPPED}, Failed: ${FAILED}"
    exit 1
else
    changed_str="false"
    [[ "$CHANGED" == "true" ]] && changed_str="true"
    json_output "${changed_str}" "Mode: ${MODE}, Restarted: ${RESTARTED}, Skipped: ${SKIPPED}, Failed: ${FAILED}"
    exit 0
fi