#!/bin/bash
# ============================================================================
# proxmox-scripts - Deploy na Proxmox VE node
# ============================================================================
# Pouziti:  ./deploy.sh [user@]<node> [--config-dir DIR]
#           ./deploy.sh pve1                       (user = root)
#           ./deploy.sh pve1 --config-dir ../muj-cluster/conf
#
# Co dela: nakopiruje skripty z bin/ do /root/bin na node. S --config-dir
#          navic soubory primo v DIR, ktere jsou commitnute v gitu; gitignored
#          soubory (napr. konfigurace s heslem) se nekopiruji. Na node nic
#          nemaze, soubory mimo seznam nechava.
#
# David Nemecek | 2026
# ============================================================================

set -euo pipefail

DEST_DIR="/root/bin"

usage() { echo "Usage: $0 [user@]<node> [--config-dir DIR]" >&2; exit 1; }

TARGET="${1:-}"
[[ -z "$TARGET" || "$TARGET" == -* ]] && usage
shift
CONFIG_DIR=""
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" == "--config-dir" ]] || usage
    CONFIG_DIR="$2"
fi
[[ "$TARGET" == *@* ]] || TARGET="root@${TARGET}"

# Konfigurace: jen commitnute soubory primo v DIR (cesta relativne k volajicimu)
CONF_FILES=()
if [[ -n "$CONFIG_DIR" ]]; then
    [[ -d "$CONFIG_DIR" ]] || { echo "[ERROR] Config dir not found: $CONFIG_DIR" >&2; exit 1; }
    CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"
    git -C "$CONFIG_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { echo "[ERROR] Config dir is not in a git repository: $CONFIG_DIR" >&2; exit 1; }
    git -C "$CONFIG_DIR" diff --quiet HEAD -- . \
        || { echo "[ERROR] Uncommitted changes in $CONFIG_DIR" >&2; exit 1; }
    while IFS= read -r f; do
        [[ "$f" == */* ]] || CONF_FILES+=("$CONFIG_DIR/$f")
    done < <(git -C "$CONFIG_DIR" ls-files .)
fi

cd "$(dirname "$0")"
SCRIPTS=(bin/*)
for f in "${SCRIPTS[@]}"; do
    bash -n "$f"
done

echo "[DEPLOY] Copying ${#SCRIPTS[@]} scripts and ${#CONF_FILES[@]} config files to ${TARGET}:${DEST_DIR}/"
ssh "$TARGET" "mkdir -p ${DEST_DIR}"
# ${arr[@]+...}: prazdne pole pod set -u v bash 3.2 (macOS)
scp -q -p "${SCRIPTS[@]}" ${CONF_FILES[@]+"${CONF_FILES[@]}"} "${TARGET}:${DEST_DIR}/"

echo "[OK] Deploy complete"
