#!/bin/bash
# vm_disk_policy.sh
# Verze: 1.2.6
# Popis: Ansible-ready skript pro nastaveni disk policy (cache, iothread, aio, bandwidth, iops, discard, ssd, scsihw) na VM discich
#        Automaticky nastavi virtio-scsi-single controller pro VM s SCSI disky
#        Identicky skript pro Ceph i ZFS clustery, per-cluster jen vm_disk_policy.conf
# Spousteni: rucne nebo cron, opravuje drift od pozadovane konfigurace
# Umisteni: /root/bin/vm_disk_policy.sh
# Pouziti: ./vm_disk_policy.sh [VMID...]
#          ./vm_disk_policy.sh           - zpracuje vsechny VM
#          ./vm_disk_policy.sh 100       - zpracuje jen VM 100
#          ./vm_disk_policy.sh 100 101   - zpracuje VM 100 a 101

set -o pipefail

# ===========================================
# KONSTANTY
# ===========================================
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_VERSION="1.2.6"
CONFIG_FILE="${SCRIPT_DIR}/vm_disk_policy.conf"
DEFAULT_LOG_FILE="/var/log/pve/vm_disk_policy.log"
DEFAULT_BACKUP_DIR="/var/backups/vm_disk_policy"
CURRENT_NODE=$(hostname)

# Ansible output promenne
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

Ansible-ready script for setting disk policy (cache, iothread, aio, bandwidth, iops, discard, ssd, scsihw) on VM disks.

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

Note: Changes to 'cache' parameter require VM poweroff/poweron to take effect.
      A simple reboot is NOT sufficient.
      
Config value "default" = use Proxmox default, do not set explicitly.
EOF
    exit 0
}

show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
    exit 0
}

# ===========================================
# FUNKCE: LOGOVANI A OUTPUT
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
    local disk="$2"
    local value="$3"
    local vm_node=$(get_vm_node "$vmid")
    
    if [ -z "$vm_node" ]; then
        log "ERROR" "VM $vmid: Cannot determine node"
        return 1
    fi
    
    if [ "$vm_node" == "$CURRENT_NODE" ]; then
        qm set "$vmid" --"$disk" "$value"
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$vm_node" "qm set $vmid --$disk '$value'"
    fi
}

# ===========================================
# FUNKCE: KONFIGURACE
# ===========================================

is_excluded() {
    local vmid="$1"
    echo ",$EXCLUDED_VMIDS," | grep -q ",$vmid,"
}

get_storage_type() {
    local storage="$1"
    # Nahradit pomlcky podtrzitky pro bash promennou
    local safe_storage="${storage//-/_}"
    local var_name="STORAGE_MAP_${safe_storage}"
    echo "${!var_name:-UNKNOWN}"
}

get_policy_value() {
    local storage_type="$1"
    local param="$2"
    local var_name="${storage_type}_${param}"
    echo "${!var_name:-}"
}

# Kontrola zda disk typ podporuje iothread (pouze virtio a scsi)
supports_iothread() {
    local disk="$1"
    if [[ "$disk" =~ ^(virtio|scsi)[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

# Kontrola zda disk typ podporuje ssd emulation (pouze scsi)
supports_ssd_emulation() {
    local disk="$1"
    if [[ "$disk" =~ ^scsi[0-9]+$ ]]; then
        return 0
    fi
    return 1
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
# FUNKCE: PARSOVANI DISKU
# ===========================================

get_disk_param() {
    local disk_config="$1"
    local param="$2"
    # Extrahuje hodnotu parametru z disk config stringu
    echo "$disk_config" | grep -oP "${param}=\K[^,]+" || echo ""
}

get_current_disk_value() {
    local disk_config="$1"
    local param="$2"
    echo "$disk_config" | grep -oP "${param}=\K[0-9.]+" || echo ""
}

build_new_disk_config() {
    local disk_config="$1"
    local storage_type="$2"
    local disk="$3"

    # Ziskani cilove politiky
    local target_cache=$(get_policy_value "$storage_type" "CACHE")
    local target_iothread=$(get_policy_value "$storage_type" "IOTHREAD")
    local target_aio=$(get_policy_value "$storage_type" "AIO")
    local target_discard=$(get_policy_value "$storage_type" "DISCARD")
    local target_ssd=$(get_policy_value "$storage_type" "SSD")
    local target_rd=$(get_policy_value "$storage_type" "MBPS_RD")
    local target_wr=$(get_policy_value "$storage_type" "MBPS_WR")
    local target_rd_max=$(get_policy_value "$storage_type" "MBPS_RD_MAX")
    local target_wr_max=$(get_policy_value "$storage_type" "MBPS_WR_MAX")
    local target_iops_rd=$(get_policy_value "$storage_type" "IOPS_RD")
    local target_iops_wr=$(get_policy_value "$storage_type" "IOPS_WR")
    local target_iops_rd_max=$(get_policy_value "$storage_type" "IOPS_RD_MAX")
    local target_iops_wr_max=$(get_policy_value "$storage_type" "IOPS_WR_MAX")

    # Odstraneni starych parametru ktere budeme nastavovat
    # Vzdy odstranime, pokud je target=default, nepridame zpet (= Proxmox default)
    # POZN: regex `mbps_rd=[0-9.]+` neziabkne `mbps_rd_max=` (za = musi byt digit, ne `_`)
    local new_config=$(echo "$disk_config" | sed -E \
        -e 's/,cache=[^,]+//g' \
        -e 's/,iothread=[^,]+//g' \
        -e 's/,aio=[^,]+//g' \
        -e 's/,discard=[^,]+//g' \
        -e 's/,ssd=[^,]+//g' \
        -e 's/,mbps_rd=[0-9.]+//g' \
        -e 's/,mbps_wr=[0-9.]+//g' \
        -e 's/,mbps_rd_max=[0-9.]+//g' \
        -e 's/,mbps_wr_max=[0-9.]+//g' \
        -e 's/,iops_rd=[0-9.]+//g' \
        -e 's/,iops_wr=[0-9.]+//g' \
        -e 's/,iops_rd_max=[0-9.]+//g' \
        -e 's/,iops_wr_max=[0-9.]+//g')

    # Pridani novych parametru (pouze pokud neni "default")
    [ -n "$target_cache" ] && [ "$target_cache" != "default" ] && new_config="${new_config},cache=${target_cache}"

    # iothread pouze pro virtio a scsi
    if supports_iothread "$disk"; then
        [ -n "$target_iothread" ] && [ "$target_iothread" != "default" ] && new_config="${new_config},iothread=${target_iothread}"
    fi

    [ -n "$target_aio" ] && [ "$target_aio" != "default" ] && new_config="${new_config},aio=${target_aio}"

    # discard pro vsechny typy disku
    [ -n "$target_discard" ] && [ "$target_discard" != "default" ] && new_config="${new_config},discard=${target_discard}"

    # ssd emulation pouze pro scsi
    if supports_ssd_emulation "$disk"; then
        [ -n "$target_ssd" ] && [ "$target_ssd" != "default" ] && [ "$target_ssd" != "0" ] && new_config="${new_config},ssd=${target_ssd}"
    fi

    [ -n "$target_rd" ] && [ "$target_rd" != "default" ] && new_config="${new_config},mbps_rd=${target_rd}"
    [ -n "$target_wr" ] && [ "$target_wr" != "default" ] && new_config="${new_config},mbps_wr=${target_wr}"
    [ -n "$target_rd_max" ] && [ "$target_rd_max" != "default" ] && new_config="${new_config},mbps_rd_max=${target_rd_max}"
    [ -n "$target_wr_max" ] && [ "$target_wr_max" != "default" ] && new_config="${new_config},mbps_wr_max=${target_wr_max}"
    [ -n "$target_iops_rd" ] && [ "$target_iops_rd" != "default" ] && new_config="${new_config},iops_rd=${target_iops_rd}"
    [ -n "$target_iops_wr" ] && [ "$target_iops_wr" != "default" ] && new_config="${new_config},iops_wr=${target_iops_wr}"
    [ -n "$target_iops_rd_max" ] && [ "$target_iops_rd_max" != "default" ] && new_config="${new_config},iops_rd_max=${target_iops_rd_max}"
    [ -n "$target_iops_wr_max" ] && [ "$target_iops_wr_max" != "default" ] && new_config="${new_config},iops_wr_max=${target_iops_wr_max}"

    echo "$new_config"
}

needs_update() {
    local disk_config="$1"
    local storage_type="$2"
    local disk="$3"

    # Aktualni hodnoty
    local current_cache=$(get_disk_param "$disk_config" "cache")
    local current_iothread=$(get_disk_param "$disk_config" "iothread")
    local current_aio=$(get_disk_param "$disk_config" "aio")
    local current_discard=$(get_disk_param "$disk_config" "discard")
    local current_ssd=$(get_disk_param "$disk_config" "ssd")
    local current_rd=$(get_current_disk_value "$disk_config" "mbps_rd")
    local current_wr=$(get_current_disk_value "$disk_config" "mbps_wr")
    local current_rd_max=$(get_current_disk_value "$disk_config" "mbps_rd_max")
    local current_wr_max=$(get_current_disk_value "$disk_config" "mbps_wr_max")
    local current_iops_rd=$(get_current_disk_value "$disk_config" "iops_rd")
    local current_iops_wr=$(get_current_disk_value "$disk_config" "iops_wr")
    local current_iops_rd_max=$(get_current_disk_value "$disk_config" "iops_rd_max")
    local current_iops_wr_max=$(get_current_disk_value "$disk_config" "iops_wr_max")

    # Cilove hodnoty
    local target_cache=$(get_policy_value "$storage_type" "CACHE")
    local target_iothread=$(get_policy_value "$storage_type" "IOTHREAD")
    local target_aio=$(get_policy_value "$storage_type" "AIO")
    local target_discard=$(get_policy_value "$storage_type" "DISCARD")
    local target_ssd=$(get_policy_value "$storage_type" "SSD")
    local target_rd=$(get_policy_value "$storage_type" "MBPS_RD")
    local target_wr=$(get_policy_value "$storage_type" "MBPS_WR")
    local target_rd_max=$(get_policy_value "$storage_type" "MBPS_RD_MAX")
    local target_wr_max=$(get_policy_value "$storage_type" "MBPS_WR_MAX")
    local target_iops_rd=$(get_policy_value "$storage_type" "IOPS_RD")
    local target_iops_wr=$(get_policy_value "$storage_type" "IOPS_WR")
    local target_iops_rd_max=$(get_policy_value "$storage_type" "IOPS_RD_MAX")
    local target_iops_wr_max=$(get_policy_value "$storage_type" "IOPS_WR_MAX")

    # Porovnani - zmena pokud se lisi (preskocit pokud target=default)
    # Pro "default": zmena potreba pouze pokud je aktualni hodnota nastavena (chceme ji odstranit)

    if [ "$target_cache" == "default" ]; then
        [ -n "$current_cache" ] && return 0
    else
        [ "$current_cache" != "$target_cache" ] && return 0
    fi

    # iothread pouze pro virtio a scsi
    if supports_iothread "$disk"; then
        if [ "$target_iothread" == "default" ]; then
            [ -n "$current_iothread" ] && return 0
        else
            [ "$current_iothread" != "$target_iothread" ] && return 0
        fi
    fi

    if [ "$target_aio" == "default" ]; then
        [ -n "$current_aio" ] && return 0
    else
        [ "$current_aio" != "$target_aio" ] && return 0
    fi

    # discard
    if [ "$target_discard" == "default" ]; then
        [ -n "$current_discard" ] && return 0
    else
        [ "$current_discard" != "$target_discard" ] && return 0
    fi

    # ssd emulation pouze pro scsi
    if supports_ssd_emulation "$disk"; then
        if [ "$target_ssd" == "default" ] || [ "$target_ssd" == "0" ]; then
            [ -n "$current_ssd" ] && [ "$current_ssd" != "0" ] && return 0
        else
            [ "$current_ssd" != "$target_ssd" ] && return 0
        fi
    fi

    if [ "$target_rd" == "default" ]; then
        [ -n "$current_rd" ] && return 0
    else
        [ "$current_rd" != "$target_rd" ] && return 0
    fi

    if [ "$target_wr" == "default" ]; then
        [ -n "$current_wr" ] && return 0
    else
        [ "$current_wr" != "$target_wr" ] && return 0
    fi

    if [ "$target_rd_max" == "default" ]; then
        [ -n "$current_rd_max" ] && return 0
    else
        [ "$current_rd_max" != "$target_rd_max" ] && return 0
    fi

    if [ "$target_wr_max" == "default" ]; then
        [ -n "$current_wr_max" ] && return 0
    else
        [ "$current_wr_max" != "$target_wr_max" ] && return 0
    fi

    if [ "$target_iops_rd" == "default" ]; then
        [ -n "$current_iops_rd" ] && return 0
    else
        [ "$current_iops_rd" != "$target_iops_rd" ] && return 0
    fi

    if [ "$target_iops_wr" == "default" ]; then
        [ -n "$current_iops_wr" ] && return 0
    else
        [ "$current_iops_wr" != "$target_iops_wr" ] && return 0
    fi

    if [ "$target_iops_rd_max" == "default" ]; then
        [ -n "$current_iops_rd_max" ] && return 0
    else
        [ "$current_iops_rd_max" != "$target_iops_rd_max" ] && return 0
    fi

    if [ "$target_iops_wr_max" == "default" ]; then
        [ -n "$current_iops_wr_max" ] && return 0
    else
        [ "$current_iops_wr_max" != "$target_iops_wr_max" ] && return 0
    fi

    return 1
}

get_drift_details() {
    local disk_config="$1"
    local storage_type="$2"
    local disk="$3"
    local drifts=()

    # Aktualni hodnoty
    local current_cache=$(get_disk_param "$disk_config" "cache")
    local current_iothread=$(get_disk_param "$disk_config" "iothread")
    local current_aio=$(get_disk_param "$disk_config" "aio")
    local current_discard=$(get_disk_param "$disk_config" "discard")
    local current_ssd=$(get_disk_param "$disk_config" "ssd")
    local current_rd=$(get_current_disk_value "$disk_config" "mbps_rd")
    local current_wr=$(get_current_disk_value "$disk_config" "mbps_wr")
    local current_rd_max=$(get_current_disk_value "$disk_config" "mbps_rd_max")
    local current_wr_max=$(get_current_disk_value "$disk_config" "mbps_wr_max")
    local current_iops_rd=$(get_current_disk_value "$disk_config" "iops_rd")
    local current_iops_wr=$(get_current_disk_value "$disk_config" "iops_wr")
    local current_iops_rd_max=$(get_current_disk_value "$disk_config" "iops_rd_max")
    local current_iops_wr_max=$(get_current_disk_value "$disk_config" "iops_wr_max")

    # Cilove hodnoty
    local target_cache=$(get_policy_value "$storage_type" "CACHE")
    local target_iothread=$(get_policy_value "$storage_type" "IOTHREAD")
    local target_aio=$(get_policy_value "$storage_type" "AIO")
    local target_discard=$(get_policy_value "$storage_type" "DISCARD")
    local target_ssd=$(get_policy_value "$storage_type" "SSD")
    local target_rd=$(get_policy_value "$storage_type" "MBPS_RD")
    local target_wr=$(get_policy_value "$storage_type" "MBPS_WR")
    local target_rd_max=$(get_policy_value "$storage_type" "MBPS_RD_MAX")
    local target_wr_max=$(get_policy_value "$storage_type" "MBPS_WR_MAX")
    local target_iops_rd=$(get_policy_value "$storage_type" "IOPS_RD")
    local target_iops_wr=$(get_policy_value "$storage_type" "IOPS_WR")
    local target_iops_rd_max=$(get_policy_value "$storage_type" "IOPS_RD_MAX")
    local target_iops_wr_max=$(get_policy_value "$storage_type" "IOPS_WR_MAX")

    # Pro default: drift pokud je hodnota nastavena
    if [ "$target_cache" == "default" ]; then
        [ -n "$current_cache" ] && drifts+=("cache:${current_cache}->default")
    else
        [ "$current_cache" != "$target_cache" ] && drifts+=("cache:${current_cache:-default}>${target_cache}")
    fi

    # iothread pouze pro virtio a scsi
    if supports_iothread "$disk"; then
        if [ "$target_iothread" == "default" ]; then
            [ -n "$current_iothread" ] && drifts+=("iothread:${current_iothread}->default")
        else
            [ "$current_iothread" != "$target_iothread" ] && drifts+=("iothread:${current_iothread:-0}>${target_iothread}")
        fi
    fi

    if [ "$target_aio" == "default" ]; then
        [ -n "$current_aio" ] && drifts+=("aio:${current_aio}->default")
    else
        [ "$current_aio" != "$target_aio" ] && drifts+=("aio:${current_aio:-default}>${target_aio}")
    fi

    # discard
    if [ "$target_discard" == "default" ]; then
        [ -n "$current_discard" ] && drifts+=("discard:${current_discard}->default")
    else
        [ "$current_discard" != "$target_discard" ] && drifts+=("discard:${current_discard:-off}>${target_discard}")
    fi

    # ssd emulation pouze pro scsi
    if supports_ssd_emulation "$disk"; then
        if [ "$target_ssd" == "default" ] || [ "$target_ssd" == "0" ]; then
            [ -n "$current_ssd" ] && [ "$current_ssd" != "0" ] && drifts+=("ssd:${current_ssd}->default")
        else
            [ "$current_ssd" != "$target_ssd" ] && drifts+=("ssd:${current_ssd:-0}>${target_ssd}")
        fi
    fi

    if [ "$target_rd" == "default" ]; then
        [ -n "$current_rd" ] && drifts+=("rd:${current_rd}->default")
    else
        [ "$current_rd" != "$target_rd" ] && drifts+=("rd:${current_rd:-0}>${target_rd}")
    fi

    if [ "$target_wr" == "default" ]; then
        [ -n "$current_wr" ] && drifts+=("wr:${current_wr}->default")
    else
        [ "$current_wr" != "$target_wr" ] && drifts+=("wr:${current_wr:-0}>${target_wr}")
    fi

    if [ "$target_rd_max" == "default" ]; then
        [ -n "$current_rd_max" ] && drifts+=("rd_max:${current_rd_max}->default")
    else
        [ "$current_rd_max" != "$target_rd_max" ] && drifts+=("rd_max:${current_rd_max:-0}>${target_rd_max}")
    fi

    if [ "$target_wr_max" == "default" ]; then
        [ -n "$current_wr_max" ] && drifts+=("wr_max:${current_wr_max}->default")
    else
        [ "$current_wr_max" != "$target_wr_max" ] && drifts+=("wr_max:${current_wr_max:-0}>${target_wr_max}")
    fi

    if [ "$target_iops_rd" == "default" ]; then
        [ -n "$current_iops_rd" ] && drifts+=("iops_rd:${current_iops_rd}->default")
    else
        [ "$current_iops_rd" != "$target_iops_rd" ] && drifts+=("iops_rd:${current_iops_rd:-0}>${target_iops_rd}")
    fi

    if [ "$target_iops_wr" == "default" ]; then
        [ -n "$current_iops_wr" ] && drifts+=("iops_wr:${current_iops_wr}->default")
    else
        [ "$current_iops_wr" != "$target_iops_wr" ] && drifts+=("iops_wr:${current_iops_wr:-0}>${target_iops_wr}")
    fi

    if [ "$target_iops_rd_max" == "default" ]; then
        [ -n "$current_iops_rd_max" ] && drifts+=("iops_rd_max:${current_iops_rd_max}->default")
    else
        [ "$current_iops_rd_max" != "$target_iops_rd_max" ] && drifts+=("iops_rd_max:${current_iops_rd_max:-0}>${target_iops_rd_max}")
    fi

    if [ "$target_iops_wr_max" == "default" ]; then
        [ -n "$current_iops_wr_max" ] && drifts+=("iops_wr_max:${current_iops_wr_max}->default")
    else
        [ "$current_iops_wr_max" != "$target_iops_wr_max" ] && drifts+=("iops_wr_max:${current_iops_wr_max:-0}>${target_iops_wr_max}")
    fi

    echo "${drifts[*]}"
}

cache_changed() {
    local disk_config="$1"
    local storage_type="$2"
    
    local current_cache=$(get_disk_param "$disk_config" "cache")
    local target_cache=$(get_policy_value "$storage_type" "CACHE")
    
    if [ "$target_cache" == "default" ]; then
        # Zmena pokud je aktualni hodnota nastavena (budeme ji odstranovat)
        [ -n "$current_cache" ] && return 0
    else
        [ "$current_cache" != "$target_cache" ] && return 0
    fi
    
    return 1
}

# ===========================================
# FUNKCE: SCSI CONTROLLER
# ===========================================

get_scsihw() {
    local vm_config="$1"
    echo "$vm_config" | grep "^scsihw:" | cut -d' ' -f2
}

has_scsi_disks() {
    local vm_config="$1"
    echo "$vm_config" | grep -qE "^scsi[0-9]+:"
}

ensure_virtio_scsi_single() {
    local vmid="$1"
    local vm_name="$2"
    local vm_node="$3"
    local vm_config="$4"
    
    # Pokud VM nema SCSI disky, neni potreba menit controller
    if ! has_scsi_disks "$vm_config"; then
        return 0
    fi
    
    local current_scsihw=$(get_scsihw "$vm_config")
    
    # Pokud je uz virtio-scsi-single, nic nedelat
    if [ "$current_scsihw" == "virtio-scsi-single" ]; then
        log "DEBUG" "VM $vmid ($vm_name): scsihw already virtio-scsi-single"
        return 0
    fi
    
    # Potrebujeme zmenit na virtio-scsi-single
    log "WARN" "VM $vmid ($vm_name): scsihw=${current_scsihw:-lsi} needs change to virtio-scsi-single (poweroff required)"
    
    if [ "$DRY_RUN" == "true" ]; then
        log "INFO" "VM $vmid ($vm_name): DRY_RUN - would set scsihw=virtio-scsi-single"
        add_message "VM $vmid ($vm_name): would set scsihw=virtio-scsi-single"
        add_poweroff_vm "$vmid"
        CHANGED=true
        ((CHANGES_MADE++))
    else
        # Backup pred zmenou
        if [ ! -f "${BACKUP_DIR}/${vmid}_backup_done" ]; then
            backup_vm_config "$vmid" "$vm_node"
            touch "${BACKUP_DIR}/${vmid}_backup_done"
        fi
        
        log "INFO" "VM $vmid ($vm_name): Setting scsihw=virtio-scsi-single"
        
        if run_qm_set_simple "$vmid" "scsihw" "virtio-scsi-single" 2>> "$LOG_FILE"; then
            log "INFO" "VM $vmid ($vm_name): scsihw set to virtio-scsi-single successfully"
            add_message "VM $vmid ($vm_name): scsihw=virtio-scsi-single"
            add_poweroff_vm "$vmid"
            CHANGED=true
            ((CHANGES_MADE++))
        else
            log "ERROR" "VM $vmid ($vm_name): Failed to set scsihw"
            add_message "VM $vmid ($vm_name): scsihw FAILED"
            ((ERRORS++))
        fi
    fi
}

run_qm_set_simple() {
    local vmid="$1"
    local param="$2"
    local value="$3"
    local vm_node=$(get_vm_node "$vmid")
    
    if [ -z "$vm_node" ]; then
        log "ERROR" "VM $vmid: Cannot determine node"
        return 1
    fi
    
    if [ "$vm_node" == "$CURRENT_NODE" ]; then
        qm set "$vmid" --"$param" "$value"
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$vm_node" "qm set $vmid --$param $value"
    fi
}

# ===========================================
# FUNKCE: ZPRACOVANI DISKU
# ===========================================

process_disk() {
    local vmid="$1"
    local vm_name="$2"
    local vm_node="$3"
    local disk="$4"
    local disk_config="$5"
    
    # Preskoceni CD-ROM, none, cloudinit
    if echo "$disk_config" | grep -qE "(none|cdrom|media=cdrom|cloudinit)"; then
        return 0
    fi
    
    # Ziskani storage z disk config (napr. local-lvm:vm-100-disk-0)
    local storage=$(echo "$disk_config" | cut -d: -f1)
    local storage_type=$(get_storage_type "$storage")
    
    if [ "$storage_type" == "UNKNOWN" ]; then
        log "WARN" "VM $vmid ($vm_name) $disk: Unknown storage type for '$storage', skipping"
        return 0
    fi
    
    # Kontrola zda je potreba update
    if ! needs_update "$disk_config" "$storage_type" "$disk"; then
        log "DEBUG" "VM $vmid ($vm_name) $disk: No change needed ($storage_type)"
        return 0
    fi
    
    # Zjisteni co je potreba zmenit
    local drift_details=$(get_drift_details "$disk_config" "$storage_type" "$disk")
    
    # Detekce zmeny cache - vyzaduje poweroff
    local cache_requires_poweroff=false
    if cache_changed "$disk_config" "$storage_type"; then
        cache_requires_poweroff=true
        local current_cache=$(get_disk_param "$disk_config" "cache")
        local target_cache=$(get_policy_value "$storage_type" "CACHE")
        log "WARN" "VM $vmid ($vm_name) $disk: cache changed (${current_cache:-default}->${target_cache}), poweroff/poweron required to apply"
    fi
    
    # Sestaveni nove konfigurace
    local new_config=$(build_new_disk_config "$disk_config" "$storage_type" "$disk")
    
    if [ "$DRY_RUN" == "true" ]; then
        log "INFO" "VM $vmid ($vm_name) $disk: DRY_RUN - would fix [$drift_details] on $vm_node"
        add_message "VM $vmid ($vm_name) $disk: would update ($storage_type)"
        [ "$cache_requires_poweroff" == "true" ] && add_poweroff_vm "$vmid"
        CHANGED=true
        ((CHANGES_MADE++))
    else
        # Backup pred zmenou (pouze jednou per VM)
        if [ ! -f "${BACKUP_DIR}/${vmid}_backup_done" ]; then
            backup_vm_config "$vmid" "$vm_node"
            touch "${BACKUP_DIR}/${vmid}_backup_done"
        fi
        
        log "INFO" "VM $vmid ($vm_name) $disk: Applying policy [$drift_details] on $vm_node"
        
        if run_qm_set "$vmid" "$disk" "$new_config" 2>> "$LOG_FILE"; then
            log "INFO" "VM $vmid ($vm_name) $disk: Policy applied successfully"
            add_message "VM $vmid ($vm_name) $disk: updated ($storage_type)"
            [ "$cache_requires_poweroff" == "true" ] && add_poweroff_vm "$vmid"
            CHANGED=true
            ((CHANGES_MADE++))
        else
            log "ERROR" "VM $vmid ($vm_name) $disk: Failed to apply policy"
            add_message "VM $vmid ($vm_name) $disk: FAILED"
            ((ERRORS++))
        fi
    fi
}

# ===========================================
# FUNKCE: ZPRACOVANI VM
# ===========================================

process_vm() {
    local vmid="$1"
    
    # Kontrola excluded
    if is_excluded "$vmid"; then
        log "INFO" "VM $vmid: Excluded (in EXCLUDED_VMIDS), skipping"
        add_message "VM $vmid: SKIPPED (excluded)"
        ((SKIPPED++))
        return 0
    fi
    
    # Zjisteni nodu pro VM
    local vm_node=$(get_vm_node "$vmid")
    if [ -z "$vm_node" ]; then
        log "WARN" "VM $vmid: Cannot determine node (VM does not exist?)"
        ((ERRORS++))
        add_message "VM $vmid: not found"
        return 1
    fi
    
    # Ziskani nazvu VM
    local vm_name=$(get_vm_name "$vmid" "$vm_node")
    [ -z "$vm_name" ] && vm_name="unknown"
    
    # Ziskani VM konfigurace pomoci qm config (bez snapshotu)
    local vm_config=$(get_vm_config "$vmid" "$vm_node")
    
    if [ -z "$vm_config" ]; then
        log "WARN" "VM $vmid ($vm_name): Cannot get config from $vm_node"
        return 1
    fi
    
    # Zajistit virtio-scsi-single pro VM s SCSI disky
    ensure_virtio_scsi_single "$vmid" "$vm_name" "$vm_node" "$vm_config"
    
    # Hledani vsech disku (virtio, scsi, ide, sata)
    while read -r line; do
        local disk=$(echo "$line" | cut -d: -f1)
        local disk_config=$(echo "$line" | cut -d: -f2- | sed 's/^ //')
        
        process_disk "$vmid" "$vm_name" "$vm_node" "$disk" "$disk_config"
    done < <(echo "$vm_config" | grep -E "^(virtio|scsi|ide|sata)[0-9]+:")
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

# Trim leading space
TARGET_VMIDS=$(echo "$TARGET_VMIDS" | xargs)

# Kontrola konfiguracniho souboru
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"changed": false, "reboot_required": false, "poweroff_vms": [], "changes": 0, "errors": 1, "skipped": 0, "msg": "Config file not found: '"$CONFIG_FILE"'"}'
    exit 1
fi

# Nacteni konfigurace
source "$CONFIG_FILE"

# Nastaveni defaultu
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
DRY_RUN="${DRY_RUN:-true}"
EXCLUDED_VMIDS="${EXCLUDED_VMIDS:-}"

# Vytvoreni adresaru
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"

# Cleanup backup_done flags z predchoziho behu
rm -f "${BACKUP_DIR}"/*_backup_done 2>/dev/null

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

# Cleanup backup_done flags
rm -f "${BACKUP_DIR}"/*_backup_done 2>/dev/null

# Log poweroff warning summary
if [ ${#POWEROFF_VMIDS[@]} -gt 0 ]; then
    log "WARN" "=== VMs requiring poweroff/poweron: ${POWEROFF_VMIDS[*]} ==="
fi

log "INFO" "=== Finished: $CHANGES_MADE changes, $ERRORS errors, $SKIPPED skipped ==="

# Ansible JSON output na stdout
output_json

exit 0
