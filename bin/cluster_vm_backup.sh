#!/bin/bash

# Načtení proměnných z externího konfiguračního souboru
CONFIG_FILE="./cluster_vm_backup.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Chyba: Konfigurační soubor $CONFIG_FILE nebyl nalezen!"
    exit 1
fi

# Export autentizačních proměnných
export PBS_PASSWORD
export PBS_FINGERPRINT

# Funkce pro získání stáří poslední zálohy z PBS
get_backup_age_pbs() {
    local VMID=$1
    LAST_BACKUP_TIMESTAMP=$(proxmox-backup-client list --output-format json --repository "root@pam@$PBS_SERVER:$PBS_STORAGE" --ns "$NAMESPACE" | jq -r ".[] | select(.\"backup-id\" == \"$VMID\") | .\"last-backup\" // empty" | sort -nr | head -n1)
    
    if [ -z "$LAST_BACKUP_TIMESTAMP" ]; then
        echo "NO_BACKUP"  # Pokud neexistuje záloha, vrátí "NO_BACKUP"
    else
        CURRENT_TIMESTAMP=$(date +%s)
        echo $(( (CURRENT_TIMESTAMP - LAST_BACKUP_TIMESTAMP) / 86400 ))
    fi
}

# Funkce pro kontrolu, zda je VM nebo LXC v seznamu ignorovaných na základě kombinace ID a jména
is_ignored_vm() {
    local VMID=$1
    local NAME=$2
    if [ ${#IGNORE_VMS[@]} -eq 0 ]; then
        return 1  # Pokud je prázdná, žádné VM/LXC se neignorují
    fi
    for IGNORE_ENTRY in "${IGNORE_VMS[@]}"; do
        IFS=':' read -r IGNORE_ID IGNORE_NAME <<< "$IGNORE_ENTRY"
        
        if [ "$VMID" == "$IGNORE_ID" ] && [ "$NAME" == "$IGNORE_NAME" ]; then
            return 0  # Ignoruje, pokud se ID i jméno shodují
        fi
    done
    return 1
}

# Funkce pro kontrolu, zda je uzel v seznamu ignorovaných
is_ignored_node() {
    local NODE=$1
    if [ ${#IGNORE_NODES[@]} -eq 0 ]; then
        return 1  # Pokud je prázdná, žádné uzly se neignorují
    fi
    for IGNORE_NODE in "${IGNORE_NODES[@]}"; do
        if [ "$NODE" == "$IGNORE_NODE" ]; then
            return 0
        fi
    done
    return 1
}

# Získá seznam všech VM a LXC kontejnerů na všech uzlech včetně jména a prochází přímo ve smyčce
ALL_RESOURCES=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[] | "\(.node) \(.type) \(.vmid) \(.name)"')

# Pole pro uchování seznamu ignorovaných VM/LXC a spuštěných procesů
IGNORED_LIST=()
JOBS=()

# Používáme zde <<EOF pro čtení ze seznamu ALL_RESOURCES přímo ve smyčce
echo "Seznam VM a LXC kontejnerů k zálohování:"
echo "--------------------------------------"
while read -r NODE TYPE VMID NAME; do
    if is_ignored_vm "$VMID" "$NAME"; then
        IGNORED_LIST+=("Uzel: $NODE | Typ: $TYPE | ID: $VMID | Jméno: $NAME | Důvod: IGNOROVÁNO (podle ID a jména)")
        continue
    fi

    if is_ignored_node "$NODE"; then
        IGNORED_LIST+=("Uzel: $NODE | Typ: $TYPE | ID: $VMID | Jméno: $NAME | Důvod: IGNOROVÁNO (podle uzlu)")
        continue
    fi

    # Kontrola stáří zálohy
    BACKUP_AGE=$(get_backup_age_pbs $VMID)
    if [ "$BACKUP_AGE" == "NO_BACKUP" ] || [ "$BACKUP_AGE" -gt "$DATE_LIMIT" ]; then
        echo "Uzel: $NODE | Typ: $TYPE | ID: $VMID | Jméno: $NAME | Stav: NO_BACKUP / Záloha starší než $DATE_LIMIT dní"
        
        # Spuštění zálohy na pozadí
        echo "Spouštím zálohu pro VM/LXC ID: $VMID na uzlu $NODE"
        ssh -n -o BatchMode=yes root@$NODE "vzdump $VMID --mode snapshot --storage $PVE_STORAGE --compress zstd --quiet 1" &
        
        # Uložení PID pozadí procesu
        JOBS+=($!)
    fi
done <<< "$ALL_RESOURCES"

# Čekání na dokončení všech spuštěných záloh
for job in "${JOBS[@]}"; do
    wait "$job"
done

# Výpis ignorovaných VM/LXC na konci
echo
echo "Ignorovaná VM a LXC kontejnery:"
echo "-------------------------------"
for IGNORED_ITEM in "${IGNORED_LIST[@]}"; do
    echo "$IGNORED_ITEM"
done
