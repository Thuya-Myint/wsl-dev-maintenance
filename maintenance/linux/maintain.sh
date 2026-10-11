#!/usr/bin/env bash
# maintain.sh — version 1, foundation
set -Eeuo pipefail
umask 077

MODE="dry-run"

usage() {
    cat <<'EOF'
Usage: maintain.sh [--dry-run | --apply]

Modes:
  --dry-run  Preview maintenance actions without changing anything. Default.
  --apply    Run selected actions after you type yes for each one.
  --help      Show this help.

Modules:
  apt      Remove unused dependency packages; clear package downloads.
  node     Clear npm cache; prune unused pnpm store entries.
  python   Clear pip download and wheel caches.
  go       Clear Go build/test caches and downloaded modules.
  docker   Remove unused Docker build cache only.
  journal  Rotate logs; remove archived logs older than 7 days; limit
           archived journal logs to 200 MB.

Protected:
  Project directories, node_modules, Python virtual environments,
  Docker images, containers, and volumes are not removed.

Logs:
  A detailed timestamped log is saved under:
  ~/.local/state/maintenance/

Examples:
  maintain.sh
  maintain.sh --dry-run
  maintain.sh --apply
EOF
}

while (($#)); do
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --apply)   MODE="apply" ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# Run as your normal user; individual system actions will use sudo.
if ((EUID == 0)); then
    printf 'Run this script as your normal user, without sudo.\n' >&2
    exit 1
fi

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/maintenance"
mkdir -p -- "$LOG_DIR"
LOG_FILE="$(mktemp "$LOG_DIR/maintain-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"

log() {
    printf '%s\n' "$*"
    printf '[%s] %s\n' "$(date '+%F %T%z')" "$*" >> "$LOG_FILE"
}

section() {
    log ""
    log "============================================================"
    log "$*"
    log "============================================================"
}

on_error() {
    local status="$1" line="$2"
    trap - ERR
    printf 'ERROR: line %s failed (exit %s).\n' "$line" "$status" >&2
    printf 'ERROR: line %s failed (exit %s).\n' "$line" "$status" \
        >> "$LOG_FILE"
    exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR
trap 'log "Interrupted."; exit 130' INT
trap 'log "Terminated."; exit 143' TERM

detect_environment() {
    local kernel
    kernel="$(uname -r)"

    if [[ "${kernel,,}" == *microsoft-standard* ]]; then
        log "Environment: WSL2 (kernel: $kernel)"
    elif [[ "${kernel,,}" == *microsoft* ]]; then
        log "Environment: WSL detected; version uncertain (kernel: $kernel)"
    else
        log "Environment: Linux; WSL not detected (kernel: $kernel)"
    fi
}

confirm() {
    local answer
    if [[ ! -t 0 ]]; then
        log "Skipped: confirmation requires an interactive terminal."
        return 1
    fi

    printf '%s Type yes to continue: ' "$1"
    if ! IFS= read -r answer; then
        return 1
    fi
    [[ "$answer" == "yes" ]]
}

PREVIEW_COUNT=0
DONE_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

run_action() {
    local description="$1"
    shift

    local command_text status
    printf -v command_text '%q ' "$@"

    log ""
    log "Action: $description"
    log "Command: $command_text"

    if [[ "$MODE" == "dry-run" ]]; then
        PREVIEW_COUNT=$((PREVIEW_COUNT + 1))
        log "[PREVIEW] No changes made."
        return 0
    fi

    if ! confirm "Run this action?"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        log "[SKIPPED] Action was not executed."
        return 0
    fi

    log "[RUNNING]"

    if "$@" 2>&1 | tee -a -- "$LOG_FILE"; then
        DONE_COUNT=$((DONE_COUNT + 1))
        log "[DONE] Action completed successfully."
    else
        status=$?
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log "[FAILED] Exit status: $status"
        log "Details: $LOG_FILE"
        return "$status"
    fi
}
disk_report() {
    df -h -- / "$HOME" |
        awk '!seen[$0]++' |
        tee -a -- "$LOG_FILE"
}
apt_maintenance() {
 section "APT — unused packages and download cache"
    if ! command -v apt-get >/dev/null 2>&1; then
        log "Skipped apt: apt-get is unavailable."
        return 0
    fi
   
    log "APT: previewing packages eligible for autoremove."
    log "Review the list; unused means apt no longer sees a dependency."

    # Simulation is read-only and needs no sudo.
    # Failure stops execution before any cleanup is offered.
    apt-get --simulate autoremove 2>&1 | tee -a -- "$LOG_FILE"

    if [[ "$MODE" == "apply" ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            log "ERROR: sudo is unavailable."
            return 1
        fi
    fi

    run_action \
        "APT: remove unused dependency packages, preserving configuration files?" \
        sudo apt-get \
            -o APT::Get::Assume-Yes=false \
            -o APT::Get::Assume-No=false \
            autoremove

    run_action \
        "APT: delete all cached package downloads?" \
        sudo apt-get clean
}

node_maintenance() {
   
    section "NODE — npm and pnpm caches"

    if command -v npm >/dev/null 2>&1; then
        run_action \
            "npm: clear downloaded package cache? Future installs may need downloads." \
            npm cache clean --force
    else
        log "Skipped npm: command is unavailable."
    fi

    if command -v pnpm >/dev/null 2>&1; then
        run_action \
            "pnpm: prune unused store entries? Future installs may need downloads." \
            pnpm store prune
    else
        log "Skipped pnpm: command is unavailable."
    fi
}
python_maintenance() {
    section "PYTHON — pip cache"

    # Use Ubuntu's system Python, even if a virtual environment is active.
    local python_bin="/usr/bin/python3"

    if [[ ! -x "$python_bin" ]]; then
        log "Skipped pip: system Python is unavailable."
        return 0
    fi

    if [[ "$MODE" == "dry-run" ]]; then
        log "pip availability will be checked in apply mode."
        run_action \
            "pip: clear the current user's download and wheel caches?" \
            "$python_bin" -m pip cache purge
        return 0
    fi

    if ! "$python_bin" -m pip --version >> "$LOG_FILE" 2>&1; then
        log "Skipped pip: pip is unavailable for system Python."
        return 0
    fi

    run_action \
        "pip: clear the current user's download and wheel caches?" \
        "$python_bin" -m pip cache purge
}
go_maintenance() {
    section "GO — build, test and module caches"

    if ! command -v go >/dev/null 2>&1; then
        log "Skipped Go: command is unavailable."
        return 0
    fi

    run_action \
        "Go: clear build and test caches? Future builds will take longer." \
        env GOTOOLCHAIN=local go clean -cache -testcache

    run_action \
        "Go: clear downloaded module cache? Future builds may need downloads." \
        env GOTOOLCHAIN=local go clean -modcache
}
docker_maintenance() {
   section "DOCKER — unused build cache"

    if ! command -v docker >/dev/null 2>&1; then
        log "Skipped Docker: command is unavailable."
        return 0
    fi

    if [[ "$MODE" == "apply" ]]; then
        log "Checking Docker access and displaying its disk usage."

        if ! docker system df 2>&1 | tee -a -- "$LOG_FILE"; then
            log "Skipped Docker: daemon unavailable or access denied."
            return 0
        fi
    fi

    run_action \
        "Docker: remove all unused build cache from the configured Docker endpoint? Future builds may take longer." \
        docker builder prune --all --force
}
journal_maintenance() {
    section "JOURNAL — archived system logs"

    if ! command -v journalctl >/dev/null 2>&1; then
        log "Skipped journal: journalctl is unavailable."
        return 0
    fi

    if [[ ! -d /run/systemd/system ]]; then
        log "Skipped journal: systemd is not running."
        return 0
    fi

    log "Current journal disk usage:"
    journalctl --disk-usage 2>&1 | tee -a -- "$LOG_FILE"

    if [[ "$MODE" == "apply" ]] &&
       ! command -v sudo >/dev/null 2>&1; then
        log "ERROR: sudo is unavailable."
        return 1
    fi

    run_action \
        "Journal: rotate active logs into archives? This alone deletes no logs." \
        sudo journalctl --rotate

    run_action \
        "Journal: permanently delete archives older than 7 days and trim archives to 200 MB? Newer archives may also be deleted." \
        sudo journalctl --vacuum-time=7d --vacuum-size=200M

    log "Journal disk usage after maintenance:"
    journalctl --disk-usage 2>&1 | tee -a -- "$LOG_FILE"
}
print_summary() {
    section "ACTION SUMMARY"
    log "Previewed : $PREVIEW_COUNT"
    log "Completed : $DONE_COUNT"
    log "Declined  : $SKIPPED_COUNT"
    log "Failed    : $FAILED_COUNT"
    log ""
    log "Unavailable tools are reported in their module sections."
    log "Full log: $LOG_FILE"
}
disk_used_bytes() {
    LC_ALL=C df -B1 --output=used / |
        awk 'NR == 2 { print $1 }'
}
main() {
    section "LINUX MAINTENANCE v1"

    if [[ "$MODE" == "dry-run" ]]; then
        log "Mode: PREVIEW — no cleanup commands will run"
    else
        log "Mode: APPLY — each cleanup requires confirmation"
    fi

    log "Log file: $LOG_FILE"
    detect_environment

    local before_bytes after_bytes reclaimed_bytes
    before_bytes="$(disk_used_bytes)"

    section "DISK USAGE BEFORE"
    disk_report

    apt_maintenance
    node_maintenance
    python_maintenance
    go_maintenance
    docker_maintenance
    journal_maintenance

    section "DISK USAGE AFTER"
    disk_report

    after_bytes="$(disk_used_bytes)"
    reclaimed_bytes=$((before_bytes - after_bytes))

    if [[ "$MODE" == "dry-run" ]]; then
        log "Preview only: no cleanup commands executed."
    elif ((reclaimed_bytes >= 0)); then
        log "Net space reclaimed on /: $(numfmt --to=iec-i --suffix=B "$reclaimed_bytes")"
    else
        log "Net space usage increased on /: $(numfmt --to=iec-i --suffix=B "$((-reclaimed_bytes))")"
    fi

    print_summary

    section "FINISHED"
    log "Run completed successfully."
}

main