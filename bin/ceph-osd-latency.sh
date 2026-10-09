#!/bin/bash
#
# Soubor: ceph-osd-latency.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: BlueStore latence lokalnich OSD podle modelu disku
#
# Pouziti:  ./ceph-osd-latency.sh [--class hdd|ssd|nvme]
#
# Co dela: pro kazde OSD na tomto node precte z admin socketu BlueStore
#          citace a vypise prumerne latence (ms) s modelem disku, serazene
#          od nejpomalejsiho. Degradovany disk se pozna nasobne vyssi
#          aio_wait a kv_queued nez ostatni disky stejne tridy.
#          Hodnoty jsou prumery od startu OSD. Jen cte, nic nemeni.
#
# Sloupce:  flush    kv_flush_lat        flush zapisu na disk
#           sync     kv_sync_lat         commit RocksDB
#           aio_wait state_aio_wait_lat  cekani na zapis dat na disk
#           queued   state_kv_queued_lat cekani ve fronte na commit
#

set -euo pipefail

# Cil: Vypise pouziti na stderr a ukonci skript s kodem 1.
usage() { echo "Usage: $0 [--class hdd|ssd|nvme]" >&2; exit 1; }

FILTER_CLASS=""
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" == "--class" ]] || usage
    FILTER_CLASS="$2"
fi

for cmd in ceph python3 sort awk; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

shopt -s nullglob
sockets=(/var/run/ceph/ceph-osd.*.asok)
[[ ${#sockets[@]} -gt 0 ]] || { echo "No local OSD admin sockets found" >&2; exit 1; }

# Cil: Z perf dump OSD (stdin) a metadat OSD vypise jeden radek tabulky: osd, trida, latence v ms a model.
# Mantinely: Argumenty: nazev OSD, device class, JSON metadat; jen cte; JSON z ceph se zpracuje
#            v python3 (soucast Proxmox VE, jq tam byt nemusi).
# Kontrola: Pri chybe parsovani python skonci nenulove a volajici radek preskoci (|| true).
row() {
    python3 -c '
import json, re, sys
osd, cls, meta, perf = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.load(sys.stdin)
b = perf["bluestore"]
ms = lambda k: b.get(k, {}).get("avgtime", 0) * 1000
# device_ids: "nvme0n1=<id>,sdf=ATA_WDC_WD181PURP-85_<serial>" (s DB na jinem disku vic polozek);
# model se bere z disku, na kterem lezi data OSD (bluestore_bdev_devices), bez serioveho cisla
ids = dict(x.split("=", 1) for x in meta.get("device_ids", "").split(",") if "=" in x)
dev = meta.get("bluestore_bdev_devices", "").split(",")[0]
raw = ids.get(dev) or next(iter(ids.values()), "-")
model = re.sub(r"_[A-Z0-9]+$", "", re.sub(r"^ATA_", "", raw))
print("\t".join([osd, cls] + ["%.1f" % ms(k) for k in
    ("kv_flush_lat", "kv_sync_lat", "state_aio_wait_lat", "state_kv_queued_lat")] + [model]))
' "$@"
}

{
    for sock in "${sockets[@]}"; do
        id=$(basename "$sock" .asok); id=${id#ceph-osd.}
        class=$(ceph osd crush get-device-class "osd.${id}" 2>/dev/null || echo "-")
        [[ -z "$FILTER_CLASS" || "$class" == "$FILTER_CLASS" ]] || continue
        meta=$(ceph osd metadata "$id" 2>/dev/null || echo "{}")
        ceph daemon "osd.${id}" perf dump 2>/dev/null | row "osd.${id}" "$class" "$meta" || true
    done
} | sort -t$'\t' -k6,6 -g -r \
  | awk -F'\t' 'BEGIN{printf "%-8s %-5s %8s %8s %9s %9s  %s\n","osd","class","flush","sync","aio_wait","queued","model"}
                {printf "%-8s %-5s %8s %8s %9s %9s  %s\n",$1,$2,$3,$4,$5,$6,$7}'
