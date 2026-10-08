#!/bin/bash

# Získej název aktuálního nodu
current_node=$(hostname)

# Inicializuj proměnnou pro uložení názvu nodu
node=""

# Zpracuj výstup z ceph osd tree
ceph osd tree | while read -r line; do
    # Zjisti, zda je řádek typu "host" (nese jméno nodu)
    if echo "$line" | grep -q "host"; then
        # Ulož jméno hostu (nodu)
        node=$(echo "$line" | awk '{print $4}')
    
    # Pokud řádek obsahuje OSD (např. "osd.6"), restartuj OSD na odpovídajícím nodu
    elif echo "$line" | grep -q "osd\."; then
        osd_id=$(echo "$line" | awk '{print $1}')
        echo "Restarting OSD $osd_id on node $node"
        
        # Pokud je node stejný jako aktuální node, restartuj lokálně
        if [ "$node" == "$current_node" ]; then
            echo "Restarting locally: OSD $osd_id on $node"
            sudo systemctl restart ceph-osd@${osd_id/osd./}
        else
            # Pokud se jedná o jiný node, použij SSH pro restart
            echo "Restarting remotely: OSD $osd_id on $node via SSH"
            ssh -n -o BatchMode=yes "$node" "sudo systemctl restart ceph-osd@${osd_id/osd./}"
        fi
        
        # Pauza mezi restarty, minimálně 30 sekund
        echo "Waiting for 90 seconds before restarting the next OSD..."
        sleep 90
    fi
done
ceph crash archive-all
