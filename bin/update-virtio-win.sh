#!/bin/bash
#
# Soubor: update-virtio-win.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: Stazeni aktualniho virtio-win ISO do ISO storage
#
# Pouziti:  ./update-virtio-win.sh [TARGET_DIR]
#           ./update-virtio-win.sh                              (storage local)
#           ./update-virtio-win.sh /mnt/pve/<storage>/template/iso
#
# Co dela: zjisti nazev posledni verze virtio-win ISO, stahne ji, pokud v
#          TARGET_DIR jeste neni, a nastavi symlink virtio-win-latest.iso.
#          Opakovany beh bez nove verze nic nemeni.
#

set -euo pipefail

base_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
target_dir="${1:-/var/lib/vz/template/iso}"

[[ -d "$target_dir" ]] || { echo "Target dir not found: $target_dir" >&2; exit 1; }

# Finalni URL po presmerovani (bez downloadu) nese nazev s verzi
final_url=$(curl -sfIL -o /dev/null -w '%{url_effective}' "$base_url")
filename=$(basename "$final_url")
file="$target_dir/$filename"

echo "Version file: $filename"

if [[ -f "$file" ]]; then
    echo "Already exists: $file"
    exit 0
fi

# Stazeni do docasneho souboru, aby preruseny download nezanechal neuplne ISO
wget -q -O "$file.part" "$final_url"
mv "$file.part" "$file"
echo "Downloaded: $file"

ln -sf "$filename" "$target_dir/virtio-win-latest.iso"
