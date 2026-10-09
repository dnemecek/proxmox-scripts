#!/bin/bash
#
# scrub_schedule.sh - Casova politika pro Ceph scrub a recovery
# Verze: 2.1.0
# Datum: 2026-10-09
#
# Cil: V produkcnich hodinach minimalizovat dopad scrub/recovery na VM workload.
#      Off-hours a vikend = catch-up.
#
# Pouziti:
#   scrub_schedule.sh                # aplikuj politiku podle aktualniho casu
#   scrub_schedule.sh --dry-run      # vypis co by se nastavilo, nic nemen
#   scrub_schedule.sh --force prod   # vynut produkcni politiku
#   scrub_schedule.sh --force off    # vynut off-hours politiku
#   scrub_schedule.sh --version
#   scrub_schedule.sh --help
#
# mClock (Ceph Quincy+): osd_max_backfills a osd_recovery_max_active_* plati jen
# s osd_mclock_override_recovery_settings=true, jinak je mClock vraci na vychozi
# hodnoty. Override zapne promenna mclock_override_recovery_settings=true v configu
# (vychozi false = puvodni chovani, limity se pod mClockem nenastavuji).
#
# Cron priklad (kazdou hodinu):
#   0 * * * * /root/bin/scrub_schedule.sh >/dev/null 2>&1

set -euo pipefail
IFS=$'\n\t'

# === Konstanty ===
readonly VERSION="2.1.0"
readonly CONFIG_FILE="${SCRUB_CONFIG_FILE:-/root/bin/scrub_schedule.conf}"
readonly LOG_DIR="${SCRUB_LOG_DIR:-/var/log/ceph}"
readonly LOG_FILE="${LOG_DIR}/scrub_schedule.log"
readonly LOCK_FILE="${SCRUB_LOCK_FILE:-/var/run/scrub_schedule.lock}"

DRY_RUN=0
FORCE_MODE=""

# === CLI parsing ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE_MODE="${2:-}"
            if [[ "${FORCE_MODE}" != "prod" && "${FORCE_MODE}" != "off" ]]; then
                echo "ERROR: --force vyzaduje argument 'prod' nebo 'off'" >&2
                exit 1
            fi
            shift 2
            ;;
        --version|-v)
            echo "scrub_schedule.sh v${VERSION}"
            exit 0
            ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: Neznamy argument: $1 (pouzij --help)" >&2
            exit 1
            ;;
    esac
done

# === Lock - zabran paralelnimu beznu z cronu + manualu ===
# POZN: 'exec 200>file' pri selhani vypise chybu na stderr, ale neukonci skript
#       (ani pod 'set -e'), proto explicitni check s podshellem.
if ! ( : >>"${LOCK_FILE}" ) 2>/dev/null; then
    echo "ERROR: Nelze otevrit lock file ${LOCK_FILE} (permissions/missing dir?)" >&2
    exit 1
fi
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "ERROR: Jiny scrub_schedule.sh jiz bezi (${LOCK_FILE}), koncim." >&2
    exit 1
fi

# === Logging setup ===
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

log() {
    local ts level msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    level="$1"; shift
    msg="$*"
    printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" | tee -a "${LOG_FILE}"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@" >&2; }

# === Validace configu ===
if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Konfiguracni soubor ${CONFIG_FILE} neexistuje"
    exit 2
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

readonly REQUIRED_VARS=(
    production_start_time production_end_time
    scrub_begin_hour scrub_end_hour
    production_scrub_priority off_hours_scrub_priority
    production_recovery_op_priority off_hours_recovery_op_priority
    scrubs_in_production scrubs_off_hours
    production_recovery_max_active_hdd off_hours_recovery_max_active_hdd
    production_recovery_max_active_ssd off_hours_recovery_max_active_ssd
    production_max_backfills off_hours_max_backfills
    production_recovery_sleep_hdd production_recovery_sleep_ssd
    off_hours_recovery_sleep_hdd off_hours_recovery_sleep_ssd
    scrub_sleep_production scrub_sleep_off_hours
    deep_scrub_interval_production deep_scrub_interval_off_hours
    deep_scrub_stride_production deep_scrub_stride_off_hours
    scrub_chunk_min scrub_chunk_max
    production_scrub_load_threshold off_hours_scrub_load_threshold
    production_scrub_during_recovery off_hours_scrub_during_recovery
    scrub_auto_repair
    production_mclock_profile off_hours_mclock_profile
    debug_deep_scrub_sleep
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing+=("${var}")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "V ${CONFIG_FILE} chybi promenne: $(IFS=','; echo "${missing[*]}" | sed 's/,/, /g')"
    exit 3
fi

# Volitelne (od 2.1.0): bez promenne zustava puvodni chovani
mclock_override_recovery_settings="${mclock_override_recovery_settings:-false}"
if [[ "${mclock_override_recovery_settings}" != "true" && "${mclock_override_recovery_settings}" != "false" ]]; then
    log_error "mclock_override_recovery_settings musi byt true nebo false, je '${mclock_override_recovery_settings}'"
    exit 3
fi

# === Ceph wrapper s error handlingem ===
ceph_set() {
    local key="$1" value="$2"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] ceph config set osd ${key} ${value}"
        return 0
    fi
    if ! ceph config set osd "${key}" "${value}" >>"${LOG_FILE}" 2>&1; then
        log_error "Selhalo: ceph config set osd ${key} ${value}"
        return 1
    fi
    # Ceph muze zmenu prijmout bez chyby a presto ji neulozit (napr. limity
    # recovery pod mClockem bez override) -> overit zpetnym ctenim
    local actual
    actual=$(ceph config get osd "${key}" 2>/dev/null || echo "?")
    # Cisla porovnat numericky (Ceph vraci 5.0 jako 5.000000)
    if [[ "${actual}" != "${value}" ]] && \
       ! awk -v a="${actual}" -v b="${value}" \
           'BEGIN { n = "^-?[0-9]+([.][0-9]+)?$"; exit !(a ~ n && b ~ n && a + 0 == b + 0) }'; then
        log_warn "ceph config set osd ${key} ${value}: plati '${actual}'"
    fi
}

# Limity recovery/backfill. Pod mClockem jen s override (viz hlavicka), jinak
# by se nastaveni tvarilo jako provedene a nemelo by ucinek.
apply_recovery_limits() {
    local using_mclock="$1" backfills="$2" max_hdd="$3" max_ssd="$4"
    if [[ "${using_mclock}" -eq 1 ]]; then
        if [[ "${mclock_override_recovery_settings}" != "true" ]]; then
            log_warn "   mClock bez override: max_backfills a recovery_max_active ridi mClock (mclock_override_recovery_settings=false)"
            ceph_set osd_mclock_override_recovery_settings false
            return 0
        fi
        ceph_set osd_mclock_override_recovery_settings true
    fi
    ceph_set osd_max_backfills               "${backfills}"
    ceph_set osd_recovery_max_active_hdd     "${max_hdd}"
    ceph_set osd_recovery_max_active_ssd     "${max_ssd}"
}

# === Detekce mClock scheduleru ===
ceph_uses_mclock() {
    local sched
    sched=$(ceph config get osd osd_op_queue 2>/dev/null || echo "")
    [[ "${sched}" == "mclock_scheduler" ]]
}

# === Detekce casu ===
# 10# vynuti decimalni interpretaci - "08"/"09" by jinak bash brala jako oktal a spadlo by
day_of_week=$((10#$(date +%u)))      # 1=Po..7=Ne
current_hour=$((10#$(date +%H)))     # 0..23

is_production_window() {
    [[ "${day_of_week}" -le 5 ]] || return 1
    [[ "${current_hour}" -ge "${production_start_time}" ]] || return 1
    [[ "${current_hour}" -lt "${production_end_time}" ]] || return 1
    return 0
}

# === Aplikace politiky ===
apply_production_policy() {
    log_info "=> Aplikuji PRODUKCNI politiku (priorita: VM workload)"

    local using_mclock=0
    if ceph_uses_mclock; then
        using_mclock=1
        log_info "   Detekovan mClock scheduler -> profil ${production_mclock_profile}"
        ceph_set osd_mclock_profile "${production_mclock_profile}"
    else
        log_info "   Detekovan WPQ scheduler (osd_op_queue != mclock_scheduler)"
    fi

    # Tvrde limity - funguji v obou schedulerech
    ceph_set osd_max_scrubs                  "${scrubs_in_production}"
    apply_recovery_limits "${using_mclock}" "${production_max_backfills}" \
        "${production_recovery_max_active_hdd}" "${production_recovery_max_active_ssd}"
    ceph_set osd_deep_scrub_interval         "${deep_scrub_interval_production}"
    ceph_set osd_deep_scrub_stride           "${deep_scrub_stride_production}"
    ceph_set osd_scrub_sleep                 "${scrub_sleep_production}"
    ceph_set osd_scrub_load_threshold        "${production_scrub_load_threshold}"
    ceph_set osd_scrub_during_recovery       "${production_scrub_during_recovery}"

    # Prioritni knoby - WPQ only (mClock je ignoruje)
    if [[ "${using_mclock}" -eq 0 ]]; then
        ceph_set osd_scrub_priority          "${production_scrub_priority}"
        ceph_set osd_recovery_op_priority    "${production_recovery_op_priority}"
        ceph_set osd_recovery_sleep_hdd      "${production_recovery_sleep_hdd}"
        ceph_set osd_recovery_sleep_ssd      "${production_recovery_sleep_ssd}"
    fi

    log_info "   Hodnoty: max_scrubs=${scrubs_in_production}, max_backfills=${production_max_backfills}"
    log_info "            recovery_max_hdd=${production_recovery_max_active_hdd}, recovery_max_ssd=${production_recovery_max_active_ssd}"
    log_info "            scrub_sleep=${scrub_sleep_production}s, scrub_load_threshold=${production_scrub_load_threshold}"
    log_info "            scrub_during_recovery=${production_scrub_during_recovery}"
    log_info "            deep_scrub_interval=$(( deep_scrub_interval_production / 86400 )) dni"
}

apply_off_hours_policy() {
    log_info "=> Aplikuji OFF-HOURS politiku (catch-up scrub a recovery)"

    local using_mclock=0
    if ceph_uses_mclock; then
        using_mclock=1
        log_info "   Detekovan mClock scheduler -> profil ${off_hours_mclock_profile}"
        ceph_set osd_mclock_profile "${off_hours_mclock_profile}"
    else
        log_info "   Detekovan WPQ scheduler (osd_op_queue != mclock_scheduler)"
    fi

    ceph_set osd_max_scrubs                  "${scrubs_off_hours}"
    apply_recovery_limits "${using_mclock}" "${off_hours_max_backfills}" \
        "${off_hours_recovery_max_active_hdd}" "${off_hours_recovery_max_active_ssd}"
    ceph_set osd_deep_scrub_interval         "${deep_scrub_interval_off_hours}"
    ceph_set osd_deep_scrub_stride           "${deep_scrub_stride_off_hours}"
    ceph_set osd_scrub_sleep                 "${scrub_sleep_off_hours}"
    ceph_set osd_scrub_load_threshold        "${off_hours_scrub_load_threshold}"
    ceph_set osd_scrub_during_recovery       "${off_hours_scrub_during_recovery}"

    if [[ "${using_mclock}" -eq 0 ]]; then
        ceph_set osd_scrub_priority          "${off_hours_scrub_priority}"
        ceph_set osd_recovery_op_priority    "${off_hours_recovery_op_priority}"
        ceph_set osd_recovery_sleep_hdd      "${off_hours_recovery_sleep_hdd}"
        ceph_set osd_recovery_sleep_ssd      "${off_hours_recovery_sleep_ssd}"
    fi

    log_info "   Hodnoty: max_scrubs=${scrubs_off_hours}, max_backfills=${off_hours_max_backfills}"
    log_info "            recovery_max_hdd=${off_hours_recovery_max_active_hdd}, recovery_max_ssd=${off_hours_recovery_max_active_ssd}"
    log_info "            scrub_sleep=${scrub_sleep_off_hours}s, scrub_load_threshold=${off_hours_scrub_load_threshold}"
    log_info "            scrub_during_recovery=${off_hours_scrub_during_recovery}"
    log_info "            deep_scrub_interval=$(( deep_scrub_interval_off_hours / 86400 )) dni"
}

# === Hlavni beh ===
log_info "=== scrub_schedule.sh v${VERSION} - start (DRY_RUN=${DRY_RUN}) ==="
log_info "Config: ${CONFIG_FILE}"
log_info "Cas: $(date '+%Y-%m-%d %H:%M:%S'), den v tydnu: ${day_of_week} (1=Po..7=Ne)"

# Overeni dostupnosti Ceph clusteru
if ! osd_count=$(ceph osd ls 2>/dev/null | wc -l); then
    log_error "Ceph cluster nedostupny (ceph osd ls selhalo)"
    exit 4
fi
if [[ "${osd_count}" -le 0 ]]; then
    log_error "Ceph hlasi 0 OSD - cluster v podivnem stavu"
    exit 4
fi
log_info "Pocet OSD: ${osd_count}"

# Spolecne nastaveni - vzdy
log_info "Nastavuji zakladni parametry (auto-repair, scrub okno, chunks)"
ceph_set osd_scrub_auto_repair      "${scrub_auto_repair}"
ceph_set osd_scrub_begin_hour       "${scrub_begin_hour}"
ceph_set osd_scrub_end_hour         "${scrub_end_hour}"
ceph_set osd_scrub_chunk_min        "${scrub_chunk_min}"
ceph_set osd_scrub_chunk_max        "${scrub_chunk_max}"
ceph_set osd_debug_deep_scrub_sleep "${debug_deep_scrub_sleep}"

# Volba politiky
if [[ -n "${FORCE_MODE}" ]]; then
    log_warn "FORCE rezim: ${FORCE_MODE}"
    case "${FORCE_MODE}" in
        prod) apply_production_policy ;;
        off)  apply_off_hours_policy ;;
    esac
elif is_production_window; then
    apply_production_policy
else
    apply_off_hours_policy
fi

# Stav clusteru do logu
log_info "Aktualni stav clusteru:"
if ! ceph -s >>"${LOG_FILE}" 2>&1; then
    log_warn "ceph -s selhalo (cluster mozna nedostupny)"
fi

log_info "=== scrub_schedule.sh - konec ==="

# Cleanup starych ROTOVANYCH logu (POZN: tecka v glob - aktivni log se nesmaze)
find "${LOG_DIR}" -name "scrub_schedule.log.*" -mtime +30 -delete 2>/dev/null || true

exit 0
