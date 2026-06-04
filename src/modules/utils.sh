#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Shared Utilities & Logging
#  All modules source this file for common functionality.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Version ───────────────────────────────────────────────────
readonly SYSBACKUP_VERSION="1.0.0"
readonly SYSBACKUP_NAME="SystemBackup"

# ── Color Codes (only if terminal supports it) ────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    readonly CLR_RESET="\033[0m"
    readonly CLR_RED="\033[1;31m"
    readonly CLR_GREEN="\033[1;32m"
    readonly CLR_YELLOW="\033[1;33m"
    readonly CLR_BLUE="\033[1;34m"
    readonly CLR_MAGENTA="\033[1;35m"
    readonly CLR_CYAN="\033[1;36m"
    readonly CLR_GRAY="\033[0;37m"
    readonly CLR_BOLD="\033[1m"
    readonly CLR_DIM="\033[2m"
else
    readonly CLR_RESET="" CLR_RED="" CLR_GREEN="" CLR_YELLOW=""
    readonly CLR_BLUE="" CLR_MAGENTA="" CLR_CYAN="" CLR_GRAY=""
    readonly CLR_BOLD="" CLR_DIM=""
fi

# ── Default Paths ─────────────────────────────────────────────
readonly DEFAULT_CONFIG_FILE="/etc/sysbackup/sysbackup.conf"
readonly DEFAULT_DATA_DIR="/var/lib/sysbackup"
readonly DEFAULT_LOG_DIR="/var/lib/sysbackup/logs"
readonly DEFAULT_LIB_DIR="/usr/local/lib/sysbackup"
readonly DEFAULT_LOCK_FILE="/var/run/sysbackup.lock"

# ── Globals (set after config load) ───────────────────────────
SYSBACKUP_CONFIG_FILE="${SYSBACKUP_CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
SYSBACKUP_DATA_DIR="${SYSBACKUP_DATA_DIR:-$DEFAULT_DATA_DIR}"
SYSBACKUP_LOG_DIR="${SYSBACKUP_LOG_DIR:-$DEFAULT_LOG_DIR}"
SYSBACKUP_VERBOSE="${SYSBACKUP_VERBOSE:-false}"
SYSBACKUP_LOG_FILE=""
SYSBACKUP_LOCK_FD=""

# ═══════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════

# Internal timestamp generator
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Internal log writer — writes to both stdout and log file
_log() {
    local level="$1" color="$2" icon="$3"
    shift 3
    local msg="$*"
    local ts
    ts=$(_timestamp)

    # Console output
    printf "${color}${icon} [%s] [%-7s] %s${CLR_RESET}\n" "$ts" "$level" "$msg" >&2

    # File output (if log file is set)
    if [[ -n "${SYSBACKUP_LOG_FILE:-}" && -w "$(dirname "${SYSBACKUP_LOG_FILE}")" ]]; then
        printf "[%s] [%-7s] %s\n" "$ts" "$level" "$msg" >> "$SYSBACKUP_LOG_FILE"
    fi
}

log_info() {
    _log "INFO" "$CLR_BLUE" "ℹ" "$@"
}

log_success() {
    _log "SUCCESS" "$CLR_GREEN" "✅" "$@"
}

log_warn() {
    _log "WARN" "$CLR_YELLOW" "⚠️" "$@"
}

log_error() {
    _log "ERROR" "$CLR_RED" "❌" "$@"
}

log_debug() {
    if [[ "$SYSBACKUP_VERBOSE" == "true" ]]; then
        _log "DEBUG" "$CLR_GRAY" "🔍" "$@"
    fi
}

log_section() {
    local title="$1"
    _log "INFO" "$CLR_CYAN" "━━" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _log "INFO" "$CLR_CYAN" "▶" " $title"
    _log "INFO" "$CLR_CYAN" "━━" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Initialize log file for this run
init_log_file() {
    local backup_type="${1:-general}"
    local ts
    ts=$(date '+%Y-%m-%d_%H%M%S')
    SYSBACKUP_LOG_FILE="${SYSBACKUP_LOG_DIR}/sysbackup-${backup_type}-${ts}.log"
    mkdir -p "$SYSBACKUP_LOG_DIR"
    touch "$SYSBACKUP_LOG_FILE"
    log_info "Log file initialized: $SYSBACKUP_LOG_FILE"
}

# Rotate old log files (by time and size limit)
rotate_logs() {
    local retention_days="${LOG_RETENTION_DAYS:-30}"
    local count
    
    # 1. Rotate by age
    count=$(find "$SYSBACKUP_LOG_DIR" -name "sysbackup-*.log" -mtime "+${retention_days}" 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        find "$SYSBACKUP_LOG_DIR" -name "sysbackup-*.log" -mtime "+${retention_days}" -delete
        log_info "Rotated $count old log files (older than ${retention_days} days)"
    fi

    # 2. Rotate by size (if log exceeds 10MB, truncate to prevent disk bloat)
    find "$SYSBACKUP_LOG_DIR" -name "sysbackup-*.log" -type f -size +10M 2>/dev/null | while read -r large_log; do
        if [[ -f "$large_log" ]]; then
            log_warn "Log file $large_log exceeded 10MB. Truncating to last 1MB."
            # Keep the last 1MB of logs for context, discard the rest
            tail -c 1M "$large_log" > "${large_log}.tmp" && mv "${large_log}.tmp" "$large_log"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═══════════════════════════════════════════════════════════════

# Load configuration file
load_config() {
    local config_file="${1:-$SYSBACKUP_CONFIG_FILE}"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        log_error "Run 'sysbackup init' to create one."
        return 1
    fi

    # Validate config file permissions (should not be world-readable if it contains secrets)
    local perms
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" && "$perms" != "640" && "$perms" != "644" ]]; then
        log_warn "Config file permissions ($perms) are loose. Recommend: chmod 640 $config_file"
    fi

    # Source the config file (it's bash-compatible key=value)
    # shellcheck source=/dev/null
    source "$config_file"

    # Update runtime paths from config
    SYSBACKUP_DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"
    SYSBACKUP_LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

    log_debug "Configuration loaded from: $config_file"
    return 0
}

# Get a config value with default
config_get() {
    local key="$1"
    local default="${2:-}"
    local val
    val="${!key:-$default}"
    echo "$val"
}

# Validate required config keys exist
validate_config() {
    local required_keys=(
        "BACKUP_NAME"
        "DATA_DIR"
        "HOME_REPO"
        "SYSTEM_REPO"
        "RESTIC_PASSWORD_FILE"
    )
    local missing=0

    for key in "${required_keys[@]}"; do
        if [[ -z "${!key:-}" ]]; then
            log_error "Required config key missing: $key"
            ((missing++))
        fi
    done

    if [[ "$missing" -gt 0 ]]; then
        log_error "$missing required configuration keys are missing."
        return 1
    fi

    # Validate password file exists
    if [[ ! -f "${RESTIC_PASSWORD_FILE:-}" ]]; then
        log_error "Restic password file not found: ${RESTIC_PASSWORD_FILE}"
        log_error "Run 'sysbackup init' to set up."
        return 1
    fi

    log_debug "Configuration validation passed"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  DEPENDENCY CHECKING
# ═══════════════════════════════════════════════════════════════

# Check if a command exists
check_command() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then
        return 0
    fi
    return 1
}

# Check a dependency and suggest install command
check_dependency() {
    local cmd="$1"
    local package="${2:-$cmd}"
    local required="${3:-true}"

    if check_command "$cmd"; then
        log_debug "Dependency found: $cmd ($(command -v "$cmd"))"
        return 0
    fi

    local install_hint=""
    if check_command apt; then
        install_hint="sudo apt install $package"
    elif check_command pacman; then
        install_hint="sudo pacman -S $package"
    elif check_command dnf; then
        install_hint="sudo dnf install $package"
    elif check_command zypper; then
        install_hint="sudo zypper install $package"
    fi

    if [[ "$required" == "true" ]]; then
        log_error "Required dependency not found: $cmd"
        [[ -n "$install_hint" ]] && log_error "Install with: $install_hint"
        return 1
    else
        log_warn "Optional dependency not found: $cmd"
        [[ -n "$install_hint" ]] && log_warn "Install with: $install_hint"
        return 1
    fi
}

# Check all required dependencies
check_all_dependencies() {
    local failed=0

    log_section "Checking Dependencies"

    # Required
    check_dependency "restic" "restic" "true" || ((failed++))
    check_dependency "rclone" "rclone" "true" || ((failed++))
    check_dependency "jq" "jq" "true" || ((failed++))
    check_dependency "bc" "bc" "true" || ((failed++))

    # Optional
    check_dependency "gum" "gum" "false" || true
    check_dependency "fzf" "fzf" "false" || true
    check_dependency "notify-send" "libnotify-bin" "false" || true
    check_dependency "paplay" "pulseaudio-utils" "false" || true
    check_dependency "xprintidle" "xprintidle" "false" || true

    if [[ "$failed" -gt 0 ]]; then
        log_error "$failed required dependencies are missing."
        return 1
    fi

    log_success "All required dependencies found"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  LOCKING (prevent concurrent runs)
# ═══════════════════════════════════════════════════════════════

# Acquire an exclusive lock
lock_acquire() {
    local lock_file="${1:-$DEFAULT_LOCK_FILE}"
    local lock_timeout="${2:-5}"

    # Open the lock file descriptor
    exec 9>"$lock_file"
    SYSBACKUP_LOCK_FD=9

    if ! flock -w "$lock_timeout" 9; then
        log_error "Another backup is already running (lock file: $lock_file)"
        log_error "If this is a stale lock, remove it: rm -f $lock_file"
        return 1
    fi

    # Write PID to lock file
    echo "$$" >&9
    log_debug "Lock acquired: $lock_file (PID: $$)"
    return 0
}

# Release the lock
lock_release() {
    if [[ -n "${SYSBACKUP_LOCK_FD:-}" ]]; then
        flock -u "$SYSBACKUP_LOCK_FD" 2>/dev/null || true
        eval "exec ${SYSBACKUP_LOCK_FD}>&-" 2>/dev/null || true
        SYSBACKUP_LOCK_FD=""
        log_debug "Lock released"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  HUMAN-READABLE FORMATTERS
# ═══════════════════════════════════════════════════════════════

# Convert bytes to human-readable size
human_size() {
    local bytes="${1:-0}"
    if [[ "$bytes" -lt 1024 ]]; then
        echo "${bytes} B"
    elif [[ "$bytes" -lt 1048576 ]]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc) KB"
    elif [[ "$bytes" -lt 1073741824 ]]; then
        echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    elif [[ "$bytes" -lt 1099511627776 ]]; then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    else
        echo "$(echo "scale=2; $bytes / 1099511627776" | bc) TB"
    fi
}

# Convert seconds to human-readable duration
human_duration() {
    local seconds="${1:-0}"
    local hours=$((seconds / 3600))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))

    if [[ "$hours" -gt 0 ]]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
    elif [[ "$minutes" -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# Format timestamp for display
format_timestamp() {
    local epoch="${1:-$(date +%s)}"
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown"
}

# Format percentage with color
format_percentage() {
    local pct="$1"
    local threshold_warn="${2:-70}"
    local threshold_crit="${3:-90}"

    if (( $(echo "$pct >= $threshold_crit" | bc -l) )); then
        printf "${CLR_RED}%.1f%%${CLR_RESET}" "$pct"
    elif (( $(echo "$pct >= $threshold_warn" | bc -l) )); then
        printf "${CLR_YELLOW}%.1f%%${CLR_RESET}" "$pct"
    else
        printf "${CLR_GREEN}%.1f%%${CLR_RESET}" "$pct"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  SYSTEM DETECTION
# ═══════════════════════════════════════════════════════════════

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "${ID:-unknown}"
    elif check_command lsb_release; then
        lsb_release -si | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}

# Detect package manager
detect_package_manager() {
    if check_command apt; then echo "apt"
    elif check_command pacman; then echo "pacman"
    elif check_command dnf; then echo "dnf"
    elif check_command zypper; then echo "zypper"
    elif check_command apk; then echo "apk"
    else echo "unknown"
    fi
}

# Detect display server (X11 or Wayland)
detect_display_server() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo "wayland"
    elif [[ -n "${DISPLAY:-}" ]]; then
        echo "x11"
    else
        echo "none"
    fi
}

# Detect sound system
detect_sound_system() {
    if check_command pw-play; then echo "pipewire"
    elif check_command paplay; then echo "pulseaudio"
    elif check_command aplay; then echo "alsa"
    else echo "none"
    fi
}

# Get active user UID (first graphical session)
get_active_user_uid() {
    loginctl list-sessions --no-legend 2>/dev/null | \
        awk '{print $3}' | head -1 | \
        xargs -I{} id -u {} 2>/dev/null || echo ""
}

# Get active user name
get_active_user_name() {
    loginctl list-sessions --no-legend 2>/dev/null | \
        awk '{print $3}' | head -1 || echo ""
}

# ═══════════════════════════════════════════════════════════════
#  DATA RECORDING
# ═══════════════════════════════════════════════════════════════

# Record a metric to a CSV file
record_metric() {
    local file="$1"
    shift
    local values="$*"
    local ts
    ts=$(date +%s)
    mkdir -p "$(dirname "$file")"
    echo "${ts},${values}" >> "$file"
}

# Get the last N lines from a data file
get_recent_data() {
    local file="$1"
    local count="${2:-30}"
    if [[ -f "$file" ]]; then
        tail -n "$count" "$file"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  DIRECTORY & FILE HELPERS
# ═══════════════════════════════════════════════════════════════

# Ensure a directory exists with proper permissions
ensure_dir() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-root:root}"

    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        chown "$owner" "$dir" 2>/dev/null || true
        log_debug "Created directory: $dir (mode: $mode)"
    fi
}

# Ensure all data directories exist
ensure_data_dirs() {
    local data_dir="${DATA_DIR:-$DEFAULT_DATA_DIR}"
    ensure_dir "$data_dir" "750"
    ensure_dir "$data_dir/data" "750"
    ensure_dir "$data_dir/logs" "750"
    ensure_dir "$data_dir/repos" "700"
    ensure_dir "$data_dir/cache" "750"
    ensure_dir "$data_dir/config" "750"
}

# ═══════════════════════════════════════════════════════════════
#  ERROR HANDLING & CLEANUP
# ═══════════════════════════════════════════════════════════════

# Trap handler for clean exit
_cleanup() {
    local exit_code=$?
    lock_release
    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Script exited with code: $exit_code"
    fi
    return "$exit_code"
}

# Set up cleanup trap
setup_traps() {
    trap _cleanup EXIT
    trap 'log_error "Interrupted (SIGINT)"; exit 130' INT
    trap 'log_error "Terminated (SIGTERM)"; exit 143' TERM
}

# Die with error message
die() {
    log_error "$@"
    exit 1
}

# ═══════════════════════════════════════════════════════════════
#  RESTIC HELPERS
# ═══════════════════════════════════════════════════════════════

# Get restic environment for a given repo
setup_restic_env() {
    local repo="$1"
    export RESTIC_REPOSITORY="$repo"
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-}"
    export RESTIC_CACHE_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}/cache/restic"
}

# Check if a restic repo is initialized
is_repo_initialized() {
    local repo="$1"
    setup_restic_env "$repo"
    restic snapshots --json --latest 1 &>/dev/null
    return $?
}

# ═══════════════════════════════════════════════════════════════
#  MISC
# ═══════════════════════════════════════════════════════════════

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This operation requires root privileges. Run with sudo."
    fi
}

# Check if running as root (soft check - warn only)
suggest_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Running without root privileges. Some operations may fail."
        return 1
    fi
    return 0
}

# Get hostname for backup naming
get_hostname() {
    hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"
}

# Generate a secure random password
generate_password() {
    local length="${1:-32}"
    head -c 128 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length"
}

# Print a styled banner
print_banner() {
    printf "${CLR_CYAN}"
    cat << 'BANNER'
   ███████╗██╗   ██╗███████╗██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗
   ██╔════╝╚██╗ ██╔╝██╔════╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗
   ███████╗ ╚████╔╝ ███████╗██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝
   ╚════██║  ╚██╔╝  ╚════██║██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝
   ███████║   ██║   ███████║██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║
   ╚══════╝   ╚═╝   ╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝
BANNER
    printf "${CLR_RESET}\n"
    printf "${CLR_DIM}   v%s — Advanced AI-Powered System Backup${CLR_RESET}\n\n" "$SYSBACKUP_VERSION"
}
