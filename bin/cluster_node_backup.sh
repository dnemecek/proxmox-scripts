#!/bin/bash

# Nacteni konfiguracniho souboru
CONFIG_FILE="./cluster_node_backup.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file $CONFIG_FILE not found!"
    exit 1
fi

# Export autentizacnich promennych pro PBS
export PBS_PASSWORD
export PBS_FINGERPRINT

# Funkce pro kontrolu, zda je uzel v seznamu ignorovanych
is_ignored_node() {
    local NODE=$1
    for IGNORE_NODE in "${IGNORE_NODES[@]}"; do
        if [ "$NODE" == "$IGNORE_NODE" ]; then
            return 0  # Zaloha uzlu se preskoci
        fi
    done
    return 1  # Zaloha uzlu se provede
}

# Funkce pro spusteni zalohy na uzlu
backup_node() {
    local NODE=$1
    echo "Running backup for node: $NODE"

    # Spusteni zalohy na uzlu; heslo jde pres stdin, ne v prikazove radce (viditelne v ps)
    printf '%s\n%s\n' "$PBS_PASSWORD" "$PBS_FINGERPRINT" | ssh -o BatchMode=yes root@$NODE "
        read -r PBS_PASSWORD; read -r PBS_FINGERPRINT
        export PBS_PASSWORD PBS_FINGERPRINT
        proxmox-backup-client backup etc.pxar:/etc varlibpve.pxar:/var/lib/pve-cluster root.pxar:/root cron.pxar:/var/spool/cron \
        --repository root@pam@$PBS_SERVER:$PBS_STORAGE  > /dev/null 2>&1
    " &

    # Ulozeni PID procesu zalohy na pozadi
    JOBS+=($!)
}

# Pole pro uchovani zaloh spustenych na pozadi
JOBS=()

# Ziskani seznamu vsech uzlu z Proxmox clusteru
ALL_NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node')

# Spusteni zalohy pro kazdy uzel, ktery neni v seznamu ignorovanych
for NODE in $ALL_NODES; do
    if is_ignored_node "$NODE"; then
        echo "Skipping backup for node: $NODE"
        continue
    fi
    backup_node "$NODE"
done

# Cekani na dokonceni vsech zaloh
for job in "${JOBS[@]}"; do
    wait "$job"
done

echo "Backup of all nodes completed."