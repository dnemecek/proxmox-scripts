#!/bin/bash

# Nacteni promennych z externiho konfiguracniho souboru
CONFIG_FILE="./cluster_vm_backup.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file $CONFIG_FILE not found!"
    exit 1
fi

# Export autentizacnich promennych
export PBS_PASSWORD
export PBS_FINGERPRINT

# Funkce pro zjisteni stari posledni zalohy z PBS
get_backup_age_pbs() {
    local VMID=$1
    LAST_BACKUP_TIMESTAMP=$(proxmox-backup-client list --output-format json --repository "root@pam@$PBS_SERVER:$PBS_STORAGE" --ns "$NAMESPACE" | jq -r ".[] | select(.\"backup-id\" == \"$VMID\") | .\"last-backup\" // empty" | sort -nr | head -n1)
    
    if [ -z "$LAST_BACKUP_TIMESTAMP" ]; then
        echo "NO_BACKUP"  # Pokud zaloha neexistuje, vrati "NO_BACKUP"
    else
        CURRENT_TIMESTAMP=$(date +%s)
        echo $(( (CURRENT_TIMESTAMP - LAST_BACKUP_TIMESTAMP) / 86400 ))
    fi
}

# Funkce pro kontrolu, zda je VM nebo LXC v seznamu ignorovanych podle kombinace ID a jmena
is_ignored_vm() {
    local VMID=$1
    local NAME=$2
    if [ ${#IGNORE_VMS[@]} -eq 0 ]; then
        return 1  # Prazdny seznam = zadne VM/LXC se neignoruji
    fi
    for IGNORE_ENTRY in "${IGNORE_VMS[@]}"; do
        IFS=':' read -r IGNORE_ID IGNORE_NAME <<< "$IGNORE_ENTRY"
        
        if [ "$VMID" == "$IGNORE_ID" ] && [ "$NAME" == "$IGNORE_NAME" ]; then
            return 0  # Ignoruje, pokud se shoduje ID i jmeno
        fi
    done
    return 1
}

# Funkce pro kontrolu, zda je uzel v seznamu ignorovanych
is_ignored_node() {
    local NODE=$1
    if [ ${#IGNORE_NODES[@]} -eq 0 ]; then
        return 1  # Prazdny seznam = zadne uzly se neignoruji
    fi
    for IGNORE_NODE in "${IGNORE_NODES[@]}"; do
        if [ "$NODE" == "$IGNORE_NODE" ]; then
            return 0
        fi
    done
    return 1
}

# Ziska seznam vsech VM a LXC kontejneru na vsech uzlech vcetne jmena
ALL_RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[] | "\(.node) \(.type) \(.vmid) \(.name)"')

# Pole pro seznam ignorovanych VM/LXC a spustenych procesu
IGNORED_LIST=()
JOBS=()

# Cteni seznamu ALL_RESOURCES primo ve smycce (here-string <<<)
echo "VMs and LXC containers to back up:"
echo "----------------------------------"
while read -r NODE TYPE VMID NAME; do
    if is_ignored_vm "$VMID" "$NAME"; then
        IGNORED_LIST+=("Node: $NODE | Type: $TYPE | ID: $VMID | Name: $NAME | Reason: IGNORED (by ID and name)")
        continue
    fi

    if is_ignored_node "$NODE"; then
        IGNORED_LIST+=("Node: $NODE | Type: $TYPE | ID: $VMID | Name: $NAME | Reason: IGNORED (by node)")
        continue
    fi

    # Kontrola stari zalohy
    BACKUP_AGE=$(get_backup_age_pbs $VMID)
    if [ "$BACKUP_AGE" == "NO_BACKUP" ] || [ "$BACKUP_AGE" -gt "$DATE_LIMIT" ]; then
        echo "Node: $NODE | Type: $TYPE | ID: $VMID | Name: $NAME | Status: NO_BACKUP / backup older than $DATE_LIMIT days"
        
        # Spusteni zalohy na pozadi
        echo "Starting backup of VM/LXC ID: $VMID on node $NODE"
        ssh -n -o BatchMode=yes root@$NODE "vzdump $VMID --mode snapshot --storage $PVE_STORAGE --compress zstd --quiet 1" &
        
        # Ulozeni PID procesu na pozadi
        JOBS+=($!)
    fi
done <<< "$ALL_RESOURCES"

# Cekani na dokonceni vsech spustenych zaloh
for job in "${JOBS[@]}"; do
    wait "$job"
done

# Vypis ignorovanych VM/LXC na konci
echo
echo "Ignored VMs and LXC containers:"
echo "-------------------------------"
for IGNORED_ITEM in "${IGNORED_LIST[@]}"; do
    echo "$IGNORED_ITEM"
done
