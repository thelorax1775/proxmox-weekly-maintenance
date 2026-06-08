#!/usr/bin/env bash
# Proxmox VE Weekly Maintenance Script
# Downloads and runs the official community-scripts maintenance tools
# unattended (no TTY / no interactive prompts).
# Source: https://github.com/community-scripts/ProxmoxVE

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="proxmox-weekly-maintenance"
readonly VERSION="1.1.1"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
readonly CONFIG_FILE="/etc/${SCRIPT_NAME}.conf"
readonly BASE_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve"
readonly -a MAINTENANCE_SCRIPTS=(
    "update-repo.sh"
    "update-lxcs.sh"
    "update-apps.sh"
)

# ─── Defaults (overridable in config file or environment) ─────────────────────
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
CURL_TIMEOUT="${CURL_TIMEOUT:-60}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

# update-apps.sh behaviour (passed through as var_* environment variables).
# See: update-apps.sh --help
APP_CONTAINER_SELECTION="${APP_CONTAINER_SELECTION:-all_running}"
APP_BACKUP="${APP_BACKUP:-no}"
APP_BACKUP_STORAGE="${APP_BACKUP_STORAGE:-}"
APP_AUTO_REBOOT="${APP_AUTO_REBOOT:-no}"
APP_CONTINUE_ON_ERROR="${APP_CONTINUE_ON_ERROR:-yes}"

# ─── Load optional config file ────────────────────────────────────────────────
# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# ─── Color support (terminal only) ───────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local entry="[${timestamp}] [${level}] ${message}"

    printf '%s\n' "${entry}" >> "${LOG_FILE}" 2>/dev/null || true

    case "${level}" in
        INFO)  printf "${CYAN}%s${RESET}\n"        "${entry}" ;;
        OK)    printf "${GREEN}%s${RESET}\n"       "${entry}" ;;
        WARN)  printf "${YELLOW}%s${RESET}\n"      "${entry}" ;;
        ERROR) printf "${RED}%s${RESET}\n"         "${entry}" >&2 ;;
        STEP)  printf "${BOLD}${BLUE}%s${RESET}\n" "${entry}" ;;
        *)     printf '%s\n'                       "${entry}" ;;
    esac
}

log_info()  { log "INFO"  "$@"; }
log_ok()    { log "OK"    "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_step()  { log "STEP"  "$@"; }

# ─── Notifications ────────────────────────────────────────────────────────────
send_discord() {
    local message="$1"
    local color="${2:-3066993}"   # 3066993=green  15158332=red
    [[ -z "${DISCORD_WEBHOOK_URL}" ]] && return 0

    # Escape the message so it is always a valid JSON string value.
    message="${message//\\/\\\\}"        # backslash (must be first)
    message="${message//\"/\\\"}"        # double quote
    message="${message//$'\n'/\\n}"      # newline

    curl -fsSL --max-time 15 \
        -X POST "${DISCORD_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"embeds\":[{\"title\":\"Proxmox Weekly Maintenance\",\"description\":\"${message}\",\"color\":${color},\"footer\":{\"text\":\"v${VERSION} | $(hostname)\"}}]}" \
        &>/dev/null || log_warn "Discord notification failed"
}

send_email() {
    local subject="$1"
    local body="$2"
    [[ -z "${NOTIFICATION_EMAIL}" ]] && return 0

    if ! command -v mail &>/dev/null; then
        log_warn "mail command not found; skipping email (install mailutils or sendmail)"
        return 0
    fi

    printf '%s' "${body}" \
        | mail -s "${subject}" "${NOTIFICATION_EMAIL}" 2>/dev/null \
        || log_warn "Email notification to ${NOTIFICATION_EMAIL} failed"
}

# ─── Preflight checks ─────────────────────────────────────────────────────────
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Must run as root (EUID=${EUID})"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in curl flock bash date mktemp hostname; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "Proxmox VE not detected (pveversion not found)"
        exit 1
    fi
    log_info "Host: $(pveversion)"
}

check_internet() {
    log_info "Checking internet connectivity..."
    if ! curl -fsSL --max-time 10 --head "https://raw.githubusercontent.com" &>/dev/null; then
        log_error "Cannot reach raw.githubusercontent.com — check network/DNS"
        return 1
    fi
    log_ok "Internet connectivity confirmed"
}

setup_log() {
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        printf 'ERROR: Cannot write to %s\n' "${LOG_FILE}" >&2
        exit 1
    fi
    chmod 640 "${LOG_FILE}" 2>/dev/null || true
}

# ─── Locking ──────────────────────────────────────────────────────────────────
acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        # Overlap with an already-running instance is an expected skip, not a
        # maintenance failure — disarm the EXIT handler so no FAILED alert is
        # sent, and exit cleanly so systemd does not mark the service failed.
        log_warn "Another instance is already running (lock: ${LOCK_FILE}); skipping this run"
        trap - EXIT
        exit 0
    fi
}

# ─── Non-interactive preamble ─────────────────────────────────────────────────
# The upstream scripts use whiptail dialogs, the `clear` command, and (for
# update-apps.sh) var_* environment variables. When run from systemd there is
# no TTY, so whiptail/clear would fail and abort the script. This preamble is
# prepended to each downloaded script before execution to force fully
# unattended behaviour. It does NOT modify the downloaded file on disk —
# scripts are still fetched verbatim from upstream on every run.
build_preamble() {
    cat <<PREAMBLE
# ── injected by ${SCRIPT_NAME} for unattended execution ──
clear() { :; }
whiptail() { return 0; }
export DEBIAN_FRONTEND=noninteractive
export TERM="xterm"
# update-apps.sh non-interactive configuration:
export var_skip_confirm="yes"
export var_unattended="yes"
export var_container="${APP_CONTAINER_SELECTION}"
export var_backup="${APP_BACKUP}"
export var_backup_storage="${APP_BACKUP_STORAGE}"
export var_auto_reboot="${APP_AUTO_REBOOT}"
export var_continue_on_error="${APP_CONTINUE_ON_ERROR}"
# ── end injected preamble ──
PREAMBLE
}

# ─── Download and execute ─────────────────────────────────────────────────────
download_and_run() {
    local script_name="$1"
    local url="${BASE_URL}/${script_name}"
    local attempt=0
    local script_content=""
    local stderr_tmp
    stderr_tmp="$(mktemp)"

    log_step "┌─ ${script_name}"

    while (( attempt < MAX_RETRIES )); do
        attempt=$(( attempt + 1 ))
        log_info "Downloading ${script_name} (attempt ${attempt}/${MAX_RETRIES})..."

        if script_content="$(curl -fsSL --max-time "${CURL_TIMEOUT}" \
                "${url}" 2>"${stderr_tmp}")"; then
            if [[ -n "${script_content}" ]]; then
                break
            fi
            log_warn "Download returned empty response"
            script_content=""
        else
            log_warn "curl failed: $(< "${stderr_tmp}")"
            script_content=""
        fi

        if (( attempt < MAX_RETRIES )); then
            log_info "Retrying in ${RETRY_DELAY}s..."
            sleep "${RETRY_DELAY}"
        fi
    done

    rm -f "${stderr_tmp}"

    if [[ -z "${script_content}" ]]; then
        log_error "└─ FAILED: could not download ${script_name} after ${MAX_RETRIES} attempts"
        return 1
    fi

    # Prepend the non-interactive preamble, then execute the verbatim script.
    local full_script
    full_script="$(build_preamble)"$'\n'"${script_content}"

    log_info "Executing ${script_name} (unattended)..."
    if bash -c "${full_script}"; then
        log_ok "└─ OK: ${script_name}"
        return 0
    fi

    log_error "└─ FAILED: ${script_name} exited non-zero"
    return 1
}

# ─── Exit handler ─────────────────────────────────────────────────────────────
START_EPOCH="$(date '+%s')"

on_exit() {
    local exit_code=$?
    local elapsed=$(( $(date '+%s') - START_EPOCH ))
    local time_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"

    if [[ ${exit_code} -eq 0 ]]; then
        log_ok "════ Maintenance complete — ${time_str} ════"
        send_discord "✅ Weekly maintenance completed successfully in ${time_str}" "3066993"
        send_email "[SUCCESS] Proxmox Weekly Maintenance" \
"All tasks completed successfully.
Host:     $(hostname)
Duration: ${time_str}
Log:      ${LOG_FILE}"
    else
        log_error "════ Maintenance FAILED (exit ${exit_code}) — ${time_str} ════"
        send_discord "❌ Weekly maintenance FAILED after ${time_str} — check ${LOG_FILE} on $(hostname)" "15158332"
        send_email "[FAILED] Proxmox Weekly Maintenance" \
"One or more maintenance tasks failed.
Host:     $(hostname)
Duration: ${time_str}
Log:      ${LOG_FILE}"
    fi
}

trap on_exit EXIT

# ─── Maintenance run ──────────────────────────────────────────────────────────
run_maintenance() {
    log_info "Running ${#MAINTENANCE_SCRIPTS[@]} maintenance scripts in order..."

    for script in "${MAINTENANCE_SCRIPTS[@]}"; do
        # Exit immediately on the first failing script (spec requirement).
        if ! download_and_run "${script}"; then
            log_error "Aborting: ${script} failed"
            return 1
        fi
    done

    log_ok "All maintenance scripts completed successfully"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_deps
    setup_log

    log_step "════ Proxmox Weekly Maintenance v${VERSION} ═ $(hostname) ═ $(date '+%Y-%m-%d %H:%M:%S') ════"

    check_proxmox
    acquire_lock
    check_internet
    run_maintenance
}

main "$@"
