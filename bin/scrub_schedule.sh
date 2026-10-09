#!/bin/bash
#
# Soubor: scrub_schedule.sh
# Projekt: proxmox-scripts
# Autor: David Nemecek
# Datum: 2026-10-08
# Popis: Casova politika pro Ceph scrub a recovery
#
# Verze: 2.1.0 (2026-10-09)
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

# === Zpracovani CLI argumentu ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE_MODE="${2:-}"
            if [[ "${FORCE_MODE}" != "prod" && "${FORCE_MODE}" != "off" ]]; then
                echo "ERROR: --force requires argument 'prod' or 'off'" >&2
                exit 1
            fi
            shift 2
            ;;
        --version|-v)
            echo "scrub_schedule.sh v${VERSION}"
            exit 0
            ;;
        --help|-h)
            sed -n '2,29p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
done

# === Lock - zabran soubeznemu behu z cronu a rucniho spusteni ===
# POZN: 'exec 200>file' pri selhani vypise chybu na stderr, ale neukonci skript
#       (ani pod 'set -e'), proto explicitni check s podshellem.
if ! ( : >>"${LOCK_FILE}" ) 2>/dev/null; then
    echo "ERROR: Cannot open lock file ${LOCK_FILE} (permissions/missing dir?)" >&2
    exit 1
fi
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "ERROR: Another scrub_schedule.sh is already running (${LOCK_FILE}), exiting." >&2
    exit 1
fi

# === Nastaveni logovani ===
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

# Cil: Zapise zpravu s urovni a casovou znackou na stdout a do LOG_FILE.
log() {
    local ts level msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    level="$1"; shift
    msg="$*"
    printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" | tee -a "${LOG_FILE}"
}
# Cil: Zkratky pro log podle urovne (log_error vypisuje na stderr).
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@" >&2; }

# === Validace configu ===
if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Config file ${CONFIG_FILE} not found"
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
    log_error "Missing variables in ${CONFIG_FILE}: $(IFS=','; echo "${missing[*]}" | sed 's/,/, /g')"
    exit 3
fi

# Volitelne (od 2.1.0): bez promenne zustava puvodni chovani
mclock_override_recovery_settings="${mclock_override_recovery_settings:-false}"
if [[ "${mclock_override_recovery_settings}" != "true" && "${mclock_override_recovery_settings}" != "false" ]]; then
    log_error "mclock_override_recovery_settings must be true or false, got '${mclock_override_recovery_settings}'"
    exit 3
fi

# === Ceph wrapper s osetrenim chyb ===
# Cil: Nastavi parametr OSD pres ceph config set a zpetnym ctenim overi, ze plati.
# Mantinely: V dry-run jen loguje; meni jen sekci osd; odlisnou platnou hodnotu neopravuje, jen hlasi.
# Kontrola: Navratovy kod ceph config set (1 = chyba) a porovnani s ceph config get (rozdil = WARN v logu).
ceph_set() {
    local key="$1" value="$2"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] ceph config set osd ${key} ${value}"
        return 0
    fi
    if ! ceph config set osd "${key}" "${value}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed: ceph config set osd ${key} ${value}"
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
        log_warn "ceph config set osd ${key} ${value}: effective value is '${actual}'"
    fi
}

# Cil: Nastavi osd_max_backfills a osd_recovery_max_active_hdd/ssd, pod mClockem vcetne override.
# Mantinely: Pod mClockem bez mclock_override_recovery_settings=true limity nenastavuje a override vypne
#            (viz hlavicka); jinak by se nastaveni tvarilo jako provedene a nemelo by ucinek.
# Kontrola: ceph_set overi kazdou hodnotu zpetnym ctenim.
apply_recovery_limits() {
    local using_mclock="$1" backfills="$2" max_hdd="$3" max_ssd="$4"
    if [[ "${using_mclock}" -eq 1 ]]; then
        if [[ "${mclock_override_recovery_settings}" != "true" ]]; then
            local note="   mClock without override: max_backfills and recovery_max_active are controlled by mClock"
            log_warn "${note} (mclock_override_recovery_settings=false)"
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
# Cil: Vrati 0, pokud OSD pouzivaji mClock scheduler (osd_op_queue = mclock_scheduler).
# Mantinely: Jen cte; nedostupny ceph = navratovy kod 1 (vetev WPQ).
# Kontrola: Navratovy kod; volajici zaloguje detekovany scheduler.
ceph_uses_mclock() {
    local sched
    sched=$(ceph config get osd osd_op_queue 2>/dev/null || echo "")
    [[ "${sched}" == "mclock_scheduler" ]]
}

# === Detekce casu ===
# 10# vynuti desitkovou interpretaci - "08"/"09" by jinak bash bral jako osmickove cislo a skript by spadl
day_of_week=$((10#$(date +%u)))      # 1=Po..7=Ne
current_hour=$((10#$(date +%H)))     # 0..23

# Cil: Vrati 0, pokud je pracovni den a aktualni hodina je v produkcnim okne z configu.
is_production_window() {
    [[ "${day_of_week}" -le 5 ]] || return 1
    [[ "${current_hour}" -ge "${production_start_time}" ]] || return 1
    [[ "${current_hour}" -lt "${production_end_time}" ]] || return 1
    return 0
}

# === Aplikace politiky ===
# Cil: Aplikuje produkcni politiku: omezi scrub a recovery ve prospech VM workloadu.
# Mantinely: Hodnoty bere jen z configu; parametry priority nastavuje jen pod WPQ (mClock je ignoruje).
# Kontrola: ceph_set overi kazdou hodnotu; vysledne hodnoty se zapisi do logu.
apply_production_policy() {
    log_info "=> Applying PRODUCTION policy (priority: VM workload)"

    local using_mclock=0
    if ceph_uses_mclock; then
        using_mclock=1
        log_info "   Detected mClock scheduler -> profile ${production_mclock_profile}"
        ceph_set osd_mclock_profile "${production_mclock_profile}"
    else
        log_info "   Detected WPQ scheduler (osd_op_queue != mclock_scheduler)"
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

    # Parametry priority - jen WPQ (mClock je ignoruje)
    if [[ "${using_mclock}" -eq 0 ]]; then
        ceph_set osd_scrub_priority          "${production_scrub_priority}"
        ceph_set osd_recovery_op_priority    "${production_recovery_op_priority}"
        ceph_set osd_recovery_sleep_hdd      "${production_recovery_sleep_hdd}"
        ceph_set osd_recovery_sleep_ssd      "${production_recovery_sleep_ssd}"
    fi

    log_info "   Values:  max_scrubs=${scrubs_in_production}, max_backfills=${production_max_backfills}"
    local line
    line="            recovery_max_hdd=${production_recovery_max_active_hdd}"
    log_info "${line}, recovery_max_ssd=${production_recovery_max_active_ssd}"
    line="            scrub_sleep=${scrub_sleep_production}s"
    log_info "${line}, scrub_load_threshold=${production_scrub_load_threshold}"
    log_info "            scrub_during_recovery=${production_scrub_during_recovery}"
    log_info "            deep_scrub_interval=$(( deep_scrub_interval_production / 86400 )) days"
}

# Cil: Aplikuje off-hours politiku: povoli vic scrub a recovery pro dohnani zpozdeni (catch-up).
# Mantinely: Hodnoty bere jen z configu; parametry priority nastavuje jen pod WPQ (mClock je ignoruje).
# Kontrola: ceph_set overi kazdou hodnotu; vysledne hodnoty se zapisi do logu.
apply_off_hours_policy() {
    log_info "=> Applying OFF-HOURS policy (catch-up scrub and recovery)"

    local using_mclock=0
    if ceph_uses_mclock; then
        using_mclock=1
        log_info "   Detected mClock scheduler -> profile ${off_hours_mclock_profile}"
        ceph_set osd_mclock_profile "${off_hours_mclock_profile}"
    else
        log_info "   Detected WPQ scheduler (osd_op_queue != mclock_scheduler)"
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

    log_info "   Values:  max_scrubs=${scrubs_off_hours}, max_backfills=${off_hours_max_backfills}"
    local line
    line="            recovery_max_hdd=${off_hours_recovery_max_active_hdd}"
    log_info "${line}, recovery_max_ssd=${off_hours_recovery_max_active_ssd}"
    log_info "            scrub_sleep=${scrub_sleep_off_hours}s, scrub_load_threshold=${off_hours_scrub_load_threshold}"
    log_info "            scrub_during_recovery=${off_hours_scrub_during_recovery}"
    log_info "            deep_scrub_interval=$(( deep_scrub_interval_off_hours / 86400 )) days"
}

# === Hlavni beh ===
log_info "=== scrub_schedule.sh v${VERSION} - start (DRY_RUN=${DRY_RUN}) ==="
log_info "Config: ${CONFIG_FILE}"
log_info "Time: $(date '+%Y-%m-%d %H:%M:%S'), day of week: ${day_of_week} (1=Mon..7=Sun)"

# Overeni dostupnosti Ceph clusteru
if ! osd_count=$(ceph osd ls 2>/dev/null | wc -l); then
    log_error "Ceph cluster unreachable (ceph osd ls failed)"
    exit 4
fi
if [[ "${osd_count}" -le 0 ]]; then
    log_error "Ceph reports 0 OSDs - cluster in unexpected state"
    exit 4
fi
log_info "OSD count: ${osd_count}"

# Spolecne nastaveni - vzdy
log_info "Setting common parameters (auto-repair, scrub window, chunks)"
ceph_set osd_scrub_auto_repair      "${scrub_auto_repair}"
ceph_set osd_scrub_begin_hour       "${scrub_begin_hour}"
ceph_set osd_scrub_end_hour         "${scrub_end_hour}"
ceph_set osd_scrub_chunk_min        "${scrub_chunk_min}"
ceph_set osd_scrub_chunk_max        "${scrub_chunk_max}"
ceph_set osd_debug_deep_scrub_sleep "${debug_deep_scrub_sleep}"

# Volba politiky
if [[ -n "${FORCE_MODE}" ]]; then
    log_warn "FORCE mode: ${FORCE_MODE}"
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
log_info "Current cluster status:"
if ! ceph -s >>"${LOG_FILE}" 2>&1; then
    log_warn "ceph -s failed (cluster may be unreachable)"
fi

log_info "=== scrub_schedule.sh - end ==="

# Uklid starych rotovanych logu (POZN: tecka v globu - aktivni log se nesmaze)
find "${LOG_DIR}" -name "scrub_schedule.log.*" -mtime +30 -delete 2>/dev/null || true

exit 0
