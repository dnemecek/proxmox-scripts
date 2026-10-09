#!/bin/bash
# vm_baseline_policy.sh
# Verze: 1.1.0
# Popis: Ansible-ready skript pro vynuceni VM baseline policy
#        (cpu, machine, balloon, numa, agent, network queues)
# Umisteni: /root/bin/vm_baseline_policy.sh
# Pouziti: ./vm_baseline_policy.sh [VMID...]
#          ./vm_baseline_policy.sh           - zpracuje vsechny VM
#          ./vm_baseline_policy.sh 100       - zpracuje jen VM 100
#          ./vm_baseline_policy.sh 100 101   - zpracuje VM 100 a 101
#
# Changelog:
#   1.1.0 - detekce agent driftu porovnava cely retezec po normalizaci
#           (serazeni sub-options) misto jen enabled+fstrim. Nyni spravne
#           detekuje zmeny ve freeze-fs, type atd.
#   1.0.0 - prvni verze

set -o pipefail

# ===========================================
# KONSTANTY
# ===========================================
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_VERSION="1.1.0"
CONFIG_FILE="${SCRIPT_DIR}/vm_baseline_policy.conf"
DEFAULT_LOG_FILE="/var/log/pve/vm_baseline_policy.log"
DEFAULT_BACKUP_DIR="/var/backups/vm_baseline_policy"
CURRENT_NODE=$(hostname)

# Promenne pro Ansible vystup
CHANGED=false
CHANGES_MADE=0
ERRORS=0
SKIPPED=0
declare -a MESSAGES=()
declare -a POWEROFF_VMIDS=()

# CLI parametry
TARGET_VMIDS=""

# ===========================================
# KONTROLA ZAVISLOSTI
# ===========================================
check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if ! command -v qm &> /dev/null; then
        missing+=("qm (proxmox-ve)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "{\"changed\": false, \"reboot_required\": false, \"poweroff_vms\": [], \"changes\": 0, \"errors\": 1, \"skipped\": 0, \"msg\": \"Missing dependencies: ${missing[*]}\"}"
        exit 1
    fi
}

check_dependencies

# ===========================================
# FUNKCE: HELP
# ===========================================
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [VMID...]

Ansible-ready script for VM baseline policy enforcement.
Standardizes: cpu, machine, balloon, numa, agent, network queues.

OS detection by ostype prefix:
  l* (l24, l26)     -> Linux baseline
  w* (win*, w2k*)   -> Windows baseline
  other, solaris    -> Excluded (requires manual configuration)

Arguments:
  VMID...       Optional: One or more VM IDs to process.
                If not specified, all VMs are processed.

Options:
  -h, --help    Show this help message and exit
  -V, --version Show version and exit

Examples:
  $SCRIPT_NAME              Process all VMs
  $SCRIPT_NAME 100          Process only VM 100
  $SCRIPT_NAME 100 101 102  Process VMs 100, 101, and 102

Configuration: $CONFIG_FILE
Log file: \$LOG_FILE (default: $DEFAULT_LOG_FILE)

Note: Changes to 'machine' parameter require VM poweroff/poweron.
      A simple reboot is NOT sufficient.
EOF
    exit 0
}

show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    exit 0
}

# ===========================================
# FUNKCE: LOGOVANI A VYSTUP
# ===========================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

add_message() {
    MESSAGES+=("$1")
}

add_poweroff_vm() {
    local vmid="$1"
    # Pridat pouze pokud jeste neni v seznamu
    if [[ ! " ${POWEROFF_VMIDS[*]} " =~ " ${vmid} " ]]; then
        POWEROFF_VMIDS+=("$vmid")
    fi
}

output_json() {
    local msg=$(printf '%s; ' "${MESSAGES[@]}" | sed 's/; $//')
    [ -z "$msg" ] && msg="No changes required"

    # Vytvoreni JSON pole pro poweroff_vms
    local poweroff_json="[]"
    if [ ${#POWEROFF_VMIDS[@]} -gt 0 ]; then
        poweroff_json=$(printf '%s\n' "${POWEROFF_VMIDS[@]}" | jq -R . | jq -s 'map(tonumber)')
    fi

    cat <<EOF
{"changed": $CHANGED, "reboot_required": false, "poweroff_vms": $poweroff_json, "changes": $CHANGES_MADE, "errors": $ERRORS, "skipped": $SKIPPED, "msg": "$msg"}
EOF
}

# ===========================================
# FUNKCE: CLUSTER OPERACE
# ===========================================

get_vm_node() {
    local vmid="$1"
    jq -r ".ids.\"$vmid\".node // empty" /etc/pve/.vmlist
}

get_vm_name() {
    local vmid="$1"
    local vm_node="$2"

    if [ "$vm_node" == "$CURRENT_NODE" ]; then
        qm config "$vmid" 2>/dev/null | grep "^name:" | cut -d' ' -f2
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$vm_node" "qm config $vmid" 2>/dev/null | grep "^name:" | cut -d' ' -f2
    fi
}

get_vm_config() {
    local vmid="$1"
    local vm_node="$2"

    if [ "$vm_node" == "$CURRENT_NODE" ]; then
        qm config "$vmid" 2>/dev/null
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$vm_node" "qm config $vmid" 2>/dev/null
    fi
}

run_qm_set() {
    local vmid="$1"
    local param="$2"
    local value="$3"
    local vm_node=$(get_vm_node "$vmid")

    if [ -z "$vm_node" ]; then
        log "ERROR" "VM $vmid: Cannot determine node"
        return 1
    fi

    if [ "$vm_node" == "$CURRENT_NODE" ]; then
        qm set "$vmid" --"$param" "$value" 2>> "$LOG_FILE"
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$vm_node" "qm set $vmid --$param '$value'" 2>> "$LOG_FILE"
    fi
}

# ===========================================
# FUNKCE: KONFIGURACE
# ===========================================

is_excluded() {
    local vmid="$1"
    echo ",$EXCLUDED_VMIDS," | grep -q ",$vmid,"
}

# Detekce OS kategorie podle prefixu ostype
# Vraci: linux, windows, nebo excluded
detect_os_category() {
    local ostype="$1"
    case "$ostype" in
        w*)     echo "windows" ;;
        l*)     echo "linux" ;;
        *)      echo "excluded" ;;  # other, solaris, neznamy
    esac
}

get_baseline_value() {
    local os_category="$1"
    local param="$2"

    local prefix=""
    case "$os_category" in
        linux)   prefix="LINUX" ;;
        windows) prefix="WINDOWS" ;;
        *)       return 1 ;;
    esac

    local var_name="${prefix}_${param}"
    echo "${!var_name:-}"
}

# ===========================================
# FUNKCE: BACKUP
# ===========================================

backup_vm_config() {
    local vmid="$1"
    local vm_node="$2"
    local config_file="/etc/pve/nodes/${vm_node}/qemu-server/${vmid}.conf"

    if [ ! -f "$config_file" ]; then
        log "WARN" "VM $vmid: Config file not found for backup"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${BACKUP_DIR}/${vmid}_${timestamp}.conf"

    cp "$config_file" "$backup_file"
    log "INFO" "VM $vmid: Config backed up to $backup_file"
    return 0
}

# ===========================================
# FUNKCE: EXTRAKCE PARAMETRU
# ===========================================

get_config_value() {
    local vm_config="$1"
    local param="$2"
    echo "$vm_config" | grep "^${param}:" | cut -d' ' -f2-
}

get_vcpu_count() {
    local vm_config="$1"
    local cores=$(get_config_value "$vm_config" "cores")
    local sockets=$(get_config_value "$vm_config" "sockets")

    cores=${cores:-1}
    sockets=${sockets:-1}

    echo $((cores * sockets))
}

# Vypocet cilovych front pro sitova rozhrani
calculate_net_queues() {
    local vcpus="$1"
    local os_category="$2"

    local queues_setting=$(get_baseline_value "$os_category" "NET_QUEUES")

    if [ "$queues_setting" == "auto" ]; then
        # Linux: pouzit pocet vCPU primo
        echo "$vcpus"
    elif [ "$queues_setting" == "max" ]; then
        # Windows: min(vcpus, limit)
        local limit=$(get_baseline_value "$os_category" "NET_QUEUES_LIMIT")
        limit=${limit:-8}
        if [ "$vcpus" -lt "$limit" ]; then
            echo "$vcpus"
        else
            echo "$limit"
        fi
    else
        # Pevna hodnota
        echo "$queues_setting"
    fi
}

# ===========================================
# FUNKCE: POROVNANI PARAMETRU
# ===========================================

# Kontrola zda machine type potrebuje update
# Striktni porovnani - machine musi byt PRESNE baseline hodnota
machine_needs_update() {
    local current="$1"
    local target="$2"

    # Striktni porovnani - musi byt presna shoda
    if [ "$current" == "$target" ]; then
        return 1  # Neni potreba update
    fi

    return 0  # Potreba update
}

# Kontrola zda CPU potrebuje update
# Striktni porovnani - CPU musi byt PRESNE baseline hodnota
# cpu: host zpristupni vsechny CPU features, dalsi flagy jsou zbytecne
cpu_needs_update() {
    local current="$1"
    local target="$2"
    local os_category="$3"

    # Striktni porovnani - musi byt presna shoda
    if [ "$current" == "$target" ]; then
        return 1  # Neni potreba update
    fi

    return 0  # Potreba update
}

# Kontrola zda sitove rozhrani potrebuje update front
net_needs_update() {
    local net_config="$1"
    local target_queues="$2"

    # Preskocit pokud neni virtio
    if [[ ! "$net_config" == *"virtio"* ]]; then
        return 1
    fi

    # Extrakce aktualniho poctu front
    local current_queues=$(echo "$net_config" | grep -oP 'queues=\K[0-9]+' || echo "1")

    if [ "$current_queues" != "$target_queues" ]; then
        return 0
    fi

    return 1
}

# Kontrola, zda agent retezec potrebuje update (porovnani celeho retezce)
# Proxmox muze pri ulozeni zmenit poradi sub-options, proto se oba
# retezce pred porovnanim seradi, aby bylo porovnani idempotentni.
# Detekuje zmeny ve VSECH sub-options: enabled, fstrim_cloned_disks,
# freeze-fs, type.
agent_needs_update() {
    local current="$1"
    local target="$2"

    # Normalizace: rozdelit po carce, seradit, spojit zpet
    local current_norm=$(echo "$current" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
    local target_norm=$(echo "$target" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')

    if [ "$current_norm" == "$target_norm" ]; then
        return 1  # Neni potreba update
    fi

    return 0  # Potreba update
}

# ===========================================
# FUNKCE: UPDATE PARAMETRU
# ===========================================

update_net_queues() {
    local net_config="$1"
    local target_queues="$2"

    # Odstraneni existujiciho parametru queues
    local new_config=$(echo "$net_config" | sed -E 's/,queues=[0-9]+//g')

    # Pridani noveho parametru queues
    new_config="${new_config},queues=${target_queues}"

    echo "$new_config"
}

# ===========================================
# FUNKCE: ZPRACOVANI VM
# ===========================================

process_vm() {
    local vmid="$1"

    # Kontrola zda je vyloucena podle VMID
    if is_excluded "$vmid"; then
        log "INFO" "VM $vmid: Excluded (in EXCLUDED_VMIDS), skipping"
        add_message "VM $vmid: SKIPPED (excluded)"
        ((SKIPPED++))
        return 0
    fi

    # Zjisteni nodu VM
    local vm_node=$(get_vm_node "$vmid")
    if [ -z "$vm_node" ]; then
        log "WARN" "VM $vmid: Cannot determine node (VM does not exist?)"
        ((ERRORS++))
        add_message "VM $vmid: not found"
        return 1
    fi

    # Zjisteni nazvu VM
    local vm_name=$(get_vm_name "$vmid" "$vm_node")
    [ -z "$vm_name" ] && vm_name="unknown"

    # Ziskani VM konfigurace
    local vm_config=$(get_vm_config "$vmid" "$vm_node")
    if [ -z "$vm_config" ]; then
        log "WARN" "VM $vmid ($vm_name): Cannot get config from $vm_node"
        ((ERRORS++))
        return 1
    fi

    # Ziskani ostype a detekce kategorie
    local ostype=$(get_config_value "$vm_config" "ostype")
    local os_category=$(detect_os_category "$ostype")

    if [ "$os_category" == "excluded" ]; then
        log "WARN" "VM $vmid ($vm_name): ostype '$ostype' requires manual configuration, skipping"
        add_message "VM $vmid ($vm_name): ostype '$ostype' excluded"
        ((SKIPPED++))
        return 0
    fi

    log "INFO" "VM $vmid ($vm_name): ostype=$ostype, category=$os_category"

    # Sledovani zmen pro tuto VM
    local vm_changed=false
    local vm_needs_poweroff=false
    local backup_done=false

    # Ziskani aktualnich hodnot
    local current_cpu=$(get_config_value "$vm_config" "cpu")
    local current_machine=$(get_config_value "$vm_config" "machine")
    local current_balloon=$(get_config_value "$vm_config" "balloon")
    local current_numa=$(get_config_value "$vm_config" "numa")
    local current_agent=$(get_config_value "$vm_config" "agent")

    # Ziskani cilovych hodnot
    local target_cpu=$(get_baseline_value "$os_category" "CPU")
    local target_machine=$(get_baseline_value "$os_category" "MACHINE")
    local target_balloon=$(get_baseline_value "$os_category" "BALLOON")
    local target_numa=$(get_baseline_value "$os_category" "NUMA")
    local target_agent=$(get_baseline_value "$os_category" "AGENT")

    # Ziskani poctu vCPU pro sitove fronty
    local vcpus=$(get_vcpu_count "$vm_config")
    local target_queues=$(calculate_net_queues "$vcpus" "$os_category")

    # === Kontrola CPU ===
    if cpu_needs_update "$current_cpu" "$target_cpu" "$os_category"; then
        log "INFO" "VM $vmid ($vm_name): cpu drift: '$current_cpu' -> '$target_cpu'"

        if [ "$DRY_RUN" == "true" ]; then
            add_message "VM $vmid: would update cpu"
        else
            if [ "$backup_done" == "false" ]; then
                backup_vm_config "$vmid" "$vm_node"
                backup_done=true
            fi

            if run_qm_set "$vmid" "cpu" "$target_cpu"; then
                add_message "VM $vmid: cpu updated"
                log "INFO" "VM $vmid ($vm_name): cpu updated successfully"
            else
                log "ERROR" "VM $vmid ($vm_name): cpu update failed"
                ((ERRORS++))
            fi
        fi
        vm_changed=true
        ((CHANGES_MADE++))
    fi

    # === Kontrola machine ===
    if machine_needs_update "$current_machine" "$target_machine"; then
        log "INFO" "VM $vmid ($vm_name): machine drift: '$current_machine' -> '$target_machine'"
        vm_needs_poweroff=true

        if [ "$DRY_RUN" == "true" ]; then
            add_message "VM $vmid: would update machine (requires poweroff)"
        else
            if [ "$backup_done" == "false" ]; then
                backup_vm_config "$vmid" "$vm_node"
                backup_done=true
            fi

            if run_qm_set "$vmid" "machine" "$target_machine"; then
                add_message "VM $vmid: machine updated (requires poweroff)"
                log "INFO" "VM $vmid ($vm_name): machine updated successfully"
            else
                log "ERROR" "VM $vmid ($vm_name): machine update failed"
                ((ERRORS++))
            fi
        fi
        vm_changed=true
        ((CHANGES_MADE++))
    fi

    # === Kontrola balloon ===
    if [ "$current_balloon" != "$target_balloon" ]; then
        log "INFO" "VM $vmid ($vm_name): balloon drift: '$current_balloon' -> '$target_balloon'"

        if [ "$DRY_RUN" == "true" ]; then
            add_message "VM $vmid: would update balloon"
        else
            if [ "$backup_done" == "false" ]; then
                backup_vm_config "$vmid" "$vm_node"
                backup_done=true
            fi

            if run_qm_set "$vmid" "balloon" "$target_balloon"; then
                add_message "VM $vmid: balloon updated"
                log "INFO" "VM $vmid ($vm_name): balloon updated successfully"
            else
                log "ERROR" "VM $vmid ($vm_name): balloon update failed"
                ((ERRORS++))
            fi
        fi
        vm_changed=true
        ((CHANGES_MADE++))
    fi

    # === Kontrola NUMA ===
    if [ "$current_numa" != "$target_numa" ]; then
        log "INFO" "VM $vmid ($vm_name): numa drift: '$current_numa' -> '$target_numa'"

        if [ "$DRY_RUN" == "true" ]; then
            add_message "VM $vmid: would update numa"
        else
            if [ "$backup_done" == "false" ]; then
                backup_vm_config "$vmid" "$vm_node"
                backup_done=true
            fi

            if run_qm_set "$vmid" "numa" "$target_numa"; then
                add_message "VM $vmid: numa updated"
                log "INFO" "VM $vmid ($vm_name): numa updated successfully"
            else
                log "ERROR" "VM $vmid ($vm_name): numa update failed"
                ((ERRORS++))
            fi
        fi
        vm_changed=true
        ((CHANGES_MADE++))
    fi

    # === Kontrola agent ===
    # Porovnani celeho retezce po normalizaci (serazeni sub-options)
    # Detekuje zmeny ve VSECH sub-options vcetne freeze-fs.
    if agent_needs_update "$current_agent" "$target_agent"; then
        log "INFO" "VM $vmid ($vm_name): agent drift: '$current_agent' -> '$target_agent'"

        if [ "$DRY_RUN" == "true" ]; then
            add_message "VM $vmid: would update agent"
        else
            if [ "$backup_done" == "false" ]; then
                backup_vm_config "$vmid" "$vm_node"
                backup_done=true
            fi

            if run_qm_set "$vmid" "agent" "$target_agent"; then
                add_message "VM $vmid: agent updated"
                log "INFO" "VM $vmid ($vm_name): agent updated successfully"
            else
                log "ERROR" "VM $vmid ($vm_name): agent update failed"
                ((ERRORS++))
            fi
        fi
        vm_changed=true
        ((CHANGES_MADE++))
    fi

    # === Kontrola sitovych rozhrani ===
    while read -r line; do
        local net_name=$(echo "$line" | cut -d: -f1)
        local net_config=$(echo "$line" | cut -d: -f2- | sed 's/^ //')

        # Preskocit rozhrani, ktera nejsou virtio
        if [[ ! "$net_config" == *"virtio"* ]]; then
            log "DEBUG" "VM $vmid ($vm_name) $net_name: not virtio, skipping queues"
            continue
        fi

        if net_needs_update "$net_config" "$target_queues"; then
            local current_queues=$(echo "$net_config" | grep -oP 'queues=\K[0-9]+' || echo "1")
            log "INFO" "VM $vmid ($vm_name) $net_name: queues drift: '$current_queues' -> '$target_queues'"

            local new_net_config=$(update_net_queues "$net_config" "$target_queues")

            if [ "$DRY_RUN" == "true" ]; then
                add_message "VM $vmid $net_name: would update queues"
            else
                if [ "$backup_done" == "false" ]; then
                    backup_vm_config "$vmid" "$vm_node"
                    backup_done=true
                fi

                if run_qm_set "$vmid" "$net_name" "$new_net_config"; then
                    add_message "VM $vmid $net_name: queues updated"
                    log "INFO" "VM $vmid ($vm_name) $net_name: queues updated successfully"
                else
                    log "ERROR" "VM $vmid ($vm_name) $net_name: queues update failed"
                    ((ERRORS++))
                fi
            fi
            vm_changed=true
            ((CHANGES_MADE++))
        fi
    done < <(echo "$vm_config" | grep -E "^net[0-9]+:")

    # Sledovani pozadavku na poweroff
    if [ "$vm_needs_poweroff" == "true" ]; then
        add_poweroff_vm "$vmid"
    fi

    if [ "$vm_changed" == "true" ]; then
        CHANGED=true
    fi
}

# ===========================================
# MAIN
# ===========================================

# Zpracovani CLI argumentu
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -V|--version)
            show_version
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            # Pozicni argument = VMID
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                TARGET_VMIDS="$TARGET_VMIDS $1"
            else
                echo "Invalid VMID: $1 (must be numeric)" >&2
                exit 1
            fi
            ;;
    esac
    shift
done

# Oriznuti uvodni mezery
TARGET_VMIDS=$(echo "$TARGET_VMIDS" | xargs)

# Kontrola konfiguracniho souboru
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"changed": false, "reboot_required": false, "poweroff_vms": [], "changes": 0, "errors": 1, "skipped": 0, "msg": "Config file not found: '"$CONFIG_FILE"'"}'
    exit 1
fi

# Nacteni konfigurace
source "$CONFIG_FILE"

# Nastaveni vychozich hodnot
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
DRY_RUN="${DRY_RUN:-true}"
EXCLUDED_VMIDS="${EXCLUDED_VMIDS:-}"

# Vytvoreni adresaru
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"

log "INFO" "=== Starting $SCRIPT_NAME v$SCRIPT_VERSION ==="
log "INFO" "DRY_RUN: $DRY_RUN, Node: $CURRENT_NODE"
log "INFO" "Excluded VMIDs: $EXCLUDED_VMIDS"

# Ziskani seznamu VM
if [ -n "$TARGET_VMIDS" ]; then
    vmids="$TARGET_VMIDS"
    log "INFO" "Target VMIDs from CLI: $vmids"
else
    vmids=$(jq -r '.ids | to_entries[] | select(.value.type == "qemu") | .key' /etc/pve/.vmlist | sort -n)
    log "INFO" "Processing all VMs"
fi

if [ -z "$vmids" ]; then
    log "INFO" "No VMs found"
    output_json
    exit 0
fi

log "INFO" "Found VMs: $(echo $vmids | tr '\n' ' ')"

# Zpracovani kazde VM
for vmid in $vmids; do
    process_vm "$vmid"
done

# Souhrnne varovani o poweroff do logu
if [ ${#POWEROFF_VMIDS[@]} -gt 0 ]; then
    log "WARN" "=== VMs requiring poweroff/poweron: ${POWEROFF_VMIDS[*]} ==="
fi

log "INFO" "=== Finished: $CHANGES_MADE changes, $ERRORS errors, $SKIPPED skipped ==="

# Ansible JSON vystup na stdout
output_json

exit 0