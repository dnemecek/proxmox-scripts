#!/bin/bash
#
# Soubor: disk-util.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: Vytizeni disku na node s prirazenim OSD a modelu
#
# Pouziti:  ./disk-util.sh [SECONDS] [MIN_UTIL]
#           ./disk-util.sh              (10 s, disky s vytizenim >= 5 %)
#           ./disk-util.sh 30 0         (30 s, vsechny disky)
#
# Co dela: zmeri z /proc/diskstats za SECONDS vytizeni (%util), IOPS, MB/s
#          a prumernou dobu obsluhy (await) kazdeho disku a priradi k nemu
#          Ceph OSD a model. Disk s vysokym %util pri malem poctu IOPS a
#          dlouhym await je podezrely. Nevyzaduje sysstat. Jen cte.
#

set -euo pipefail

SECONDS_SAMPLE="${1:-10}"
MIN_UTIL="${2:-5}"
[[ "$SECONDS_SAMPLE" =~ ^[0-9]+$ && "$SECONDS_SAMPLE" -gt 0 && "$MIN_UTIL" =~ ^[0-9]+$ ]] \
    || { echo "Usage: $0 [SECONDS] [MIN_UTIL]" >&2; exit 1; }

for cmd in awk join sort readlink tr; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

# Disk -> OSD: symlink block (data) a block.db (RocksDB) OSD vede na LV (dm-N),
# disk pod nim je v slaves/. DB svazek se oznaci priponou ":db".
declare -A osd_of
for blk in /var/lib/ceph/osd/ceph-*/block /var/lib/ceph/osd/ceph-*/block.db; do
    [[ -e "$blk" ]] || continue
    id=${blk%/block*}; id=${id##*-}
    tag="osd.${id}"; [[ "$blk" == *block.db ]] && tag="osd.${id}:db"
    dm=$(basename "$(readlink -f "$blk")")
    for slave in /sys/block/"$dm"/slaves/*; do
        [[ -e "$slave" ]] || continue
        # slave muze byt oddil (sdb1) -- nadrazeny disk je o uroven vys v /sys/class/block
        parent=$(basename "$(dirname "$(readlink -f "/sys/class/block/$(basename "$slave")")")")
        [[ -d "/sys/block/$(basename "$slave")" ]] && parent=$(basename "$slave")
        osd_of[$parent]="${osd_of[$parent]:+${osd_of[$parent]},}${tag}"
    done
done

# Cil: Vypise vybrane citace z /proc/diskstats pro disky sd*, nvme* a vd*.
# Pole /proc/diskstats: 4 reads, 6 sectors read, 7 ms reading,
# 8 writes, 10 sectors written, 11 ms writing, 13 ms doing I/O
snap() { awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$/ {print $3,$4,$6,$7,$8,$10,$11,$13}' /proc/diskstats; }

before=$(snap)
sleep "$SECONDS_SAMPLE"
after=$(snap)

printf "%-9s %5s %7s %7s %7s %7s %8s  %-12s %s\n" dev util r/s rMB/s w/s wMB/s await_ms osd model
join <(echo "$before" | sort) <(echo "$after" | sort) |
    while read -r dev r1 rs1 rt1 w1 ws1 wt1 io1 r2 rs2 rt2 w2 ws2 wt2 io2; do
    util=$(( (io2 - io1) / (SECONDS_SAMPLE * 10) ))
    (( util >= MIN_UTIL )) || continue
    ios=$(( (r2 - r1) + (w2 - w1) ))
    await=0; (( ios > 0 )) && await=$(( ((rt2 - rt1) + (wt2 - wt1)) / ios ))
    model=$(tr -s ' ' < "/sys/block/${dev}/device/model" 2>/dev/null || echo "-")
    printf "%-9s %4d%% %7d %7d %7d %7d %8d  %-12s %s\n" "$dev" "$util" \
        $(( (r2 - r1) / SECONDS_SAMPLE )) $(( (rs2 - rs1) * 512 / 1000000 / SECONDS_SAMPLE )) \
        $(( (w2 - w1) / SECONDS_SAMPLE )) $(( (ws2 - ws1) * 512 / 1000000 / SECONDS_SAMPLE )) \
        "$await" "${osd_of[$dev]:--}" "$model"
done
