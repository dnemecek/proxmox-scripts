#!/bin/bash

# Načtení konfiguračního souboru
CONFIG_FILE="./cluster_node_backup.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Chyba: Konfigurační soubor $CONFIG_FILE nebyl nalezen!"
    exit 1
fi

# Export autentizačních proměnných pro PBS
export PBS_PASSWORD
export PBS_FINGERPRINT

# Funkce pro kontrolu, zda je uzel v seznamu ignorovaných
is_ignored_node() {
    local NODE=$1
    for IGNORE_NODE in "${IGNORE_NODES[@]}"; do
        if [ "$NODE" == "$IGNORE_NODE" ]; then
            return 0  # Uzlu se zálohování přeskočí
        fi
    done
    return 1  # Uzlu se zálohování provede
}

# Funkce pro spuštění zálohy na uzlu
backup_node() {
    local NODE=$1
    echo "Provádím zálohu pro uzel: $NODE"

    # Spuštění zálohy na uzlu; heslo jde přes stdin, ne v příkazové řádce (viditelné v ps)
    printf '%s\n%s\n' "$PBS_PASSWORD" "$PBS_FINGERPRINT" | ssh -o BatchMode=yes root@$NODE "
        read -r PBS_PASSWORD; read -r PBS_FINGERPRINT
        export PBS_PASSWORD PBS_FINGERPRINT
        proxmox-backup-client backup etc.pxar:/etc varlibpve.pxar:/var/lib/pve-cluster root.pxar:/root cron.pxar:/var/spool/cron \
        --repository root@pam@$PBS_SERVER:$PBS_STORAGE  > /dev/null 2>&1
    " &

    # Uložení PID procesu zálohy na pozadí
    JOBS+=($!)
}

# Pole pro uchování spuštěných záloh na pozadí
JOBS=()

# Získání seznamu všech uzlů z Proxmox clusteru
ALL_NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node')

# Spuštění zálohy pro každý uzel, který není v seznamu ignorovaných
for NODE in $ALL_NODES; do
    if is_ignored_node "$NODE"; then
        echo "Přeskakuji zálohu pro uzel: $NODE"
        continue
    fi
    backup_node "$NODE"
done

# Čekání na dokončení všech záloh
for job in "${JOBS[@]}"; do
    wait "$job"
done

echo "Zálohování všech uzlů dokončeno."