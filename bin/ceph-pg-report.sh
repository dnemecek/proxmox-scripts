#!/bin/bash
# ceph-pg-report.sh - Identify VMs affected by Ceph PG problems
# Author: David Nemecek | December 2025

echo "=== CEPH PG Health Report ==="
echo "Cluster: $(pvesh get /cluster/status --output-format json | jq -r '.[] | select(.type=="cluster") | .name')"
echo "Generated: $(date '+%Y-%m-%d %H:%M')"
echo ""

# Get problematic PGs
PROBLEM_PGS=$(ceph health detail 2>/dev/null | grep "^    pg " | awk '{print $2}')

if [ -z "$PROBLEM_PGS" ]; then
    echo "No problematic PGs found. Cluster healthy."
    exit 0
fi

# Get pool ID to name mapping
declare -A POOL_NAMES
while read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    POOL_NAMES[$id]=$name
done < <(ceph osd pool ls detail 2>/dev/null | grep "^pool" | awk '{print $2, $3}' | tr -d "'")

# Get RBD image ID to name mapping per pool
declare -A IMAGE_MAP
for pool in "${POOL_NAMES[@]}"; do
    while read -r img; do
        [ -z "$img" ] && continue
        id=$(rbd info "$pool/$img" --format json 2>/dev/null | jq -r '.id')
        [ -n "$id" ] && [ "$id" != "null" ] && IMAGE_MAP["$pool:$id"]="$img"
    done < <(rbd ls "$pool" 2>/dev/null)
done

# Build VM status cache from cluster resources
declare -A VM_STATUS_CACHE
while IFS='|' read -r vmid status; do
    [ -n "$vmid" ] && VM_STATUS_CACHE[$vmid]=$status
done < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[] | "\(.vmid)|\(.status)"')

# Function to get VM name and status from cluster config
get_vm_info() {
    local vmid=$1
    local vm_name=""
    local vm_node=""
    
    # Search config in all nodes
    for conf in /etc/pve/nodes/*/qemu-server/${vmid}.conf; do
        if [ -f "$conf" ]; then
            vm_name=$(grep "^name:" "$conf" 2>/dev/null | cut -d' ' -f2)
            vm_node=$(echo "$conf" | cut -d'/' -f5)
            break
        fi
    done
    
    # Get status from cache
    vm_status=${VM_STATUS_CACHE[$vmid]:-stopped}
    
    echo "${vm_name:-unknown}|${vm_status}|${vm_node:-unknown}"
}

echo "PROBLEMATIC PGs:"
echo "================"

for pg in $PROBLEM_PGS; do
    # Get PG state from health detail
    state=$(ceph health detail 2>/dev/null | grep "pg $pg " | sed 's/.*is //' | sed 's/, acting.*//')
    
    # Extract pool ID from PG (format: poolid.pgnum)
    pool_id=$(echo "$pg" | cut -d'.' -f1)
    pool_name=${POOL_NAMES[$pool_id]}
    
    # Get acting OSDs from pg query
    acting=$(ceph pg "$pg" query 2>/dev/null | jq -r '.acting | join(",")')
    
    echo ""
    echo "PG $pg ($pool_name)"
    echo "  State: $state"
    echo "  Acting OSDs: $acting"
    
    # Get unique image IDs in this PG
    echo "  Analyzing objects..."
    
    declare -A PG_IMAGES
    
    while read -r obj; do
        # Extract image ID from object name (rbd_data.IMAGEID.OFFSET)
        if [[ "$obj" =~ rbd_data\.([a-f0-9]+)\. ]]; then
            img_id="${BASH_REMATCH[1]}"
            ((PG_IMAGES[$img_id]++))
        fi
    done < <(rados --pgid "$pg" ls 2>/dev/null)
    
    # Check which images exist and which are orphaned
    affected_vms=""
    orphaned_list=""
    
    for img_id in "${!PG_IMAGES[@]}"; do
        obj_count=${PG_IMAGES[$img_id]}
        img_name=${IMAGE_MAP["$pool_name:$img_id"]}
        
        if [ -n "$img_name" ]; then
            # Image exists - find which VM uses it
            vmid=$(echo "$img_name" | grep -oP '(vm|base)-\K[0-9]+')
            if [ -n "$vmid" ]; then
                vm_info=$(get_vm_info "$vmid")
                vm_name=$(echo "$vm_info" | cut -d'|' -f1)
                vm_status=$(echo "$vm_info" | cut -d'|' -f2)
                vm_node=$(echo "$vm_info" | cut -d'|' -f3)
                affected_vms+="    VM-$vmid ($vm_name) - $vm_status @ $vm_node\n"
                affected_vms+="      Disk: $img_name ($obj_count objects)\n"
            fi
        else
            # Orphaned - no RBD image
            orphaned_list+="    Image ID: $img_id ($obj_count objects) - NO RBD IMAGE\n"
        fi
    done
    
    if [ -n "$affected_vms" ]; then
        echo ""
        echo "  AFFECTED VMs:"
        echo -e "$affected_vms"
    fi
    
    if [ -n "$orphaned_list" ]; then
        echo ""
        echo "  ORPHANED (safe to delete):"
        echo -e "$orphaned_list"
    fi
    
    unset PG_IMAGES
    declare -A PG_IMAGES
done

echo ""
echo "=== END REPORT ==="