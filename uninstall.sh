#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Uninstaller
#  Cleanly removes SystemBackup from the system.
#  Usage:  sudo bash uninstall.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Color Codes (inline, since utils.sh may already be removed) ──
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    CLR_RESET="\033[0m"
    CLR_RED="\033[1;31m"
    CLR_GREEN="\033[1;32m"
    CLR_YELLOW="\033[1;33m"
    CLR_BLUE="\033[1;34m"
    CLR_CYAN="\033[1;36m"
    CLR_BOLD="\033[1m"
    CLR_DIM="\033[2m"
else
    CLR_RESET="" CLR_RED="" CLR_GREEN="" CLR_YELLOW=""
    CLR_BLUE="" CLR_CYAN="" CLR_BOLD="" CLR_DIM=""
fi

# ── Logging (self-contained, no dependency on utils.sh) ──────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { printf "${CLR_BLUE}ℹ [%s] [INFO   ] %s${CLR_RESET}\n" "$(_ts)" "$*" >&2; }
log_success() { printf "${CLR_GREEN}✅ [%s] [SUCCESS] %s${CLR_RESET}\n" "$(_ts)" "$*" >&2; }
log_warn()    { printf "${CLR_YELLOW}⚠️ [%s] [WARN   ] %s${CLR_RESET}\n" "$(_ts)" "$*" >&2; }
log_error()   { printf "${CLR_RED}❌ [%s] [ERROR  ] %s${CLR_RESET}\n" "$(_ts)" "$*" >&2; }
log_section() {
    printf "${CLR_CYAN}━━ [%s] [INFO   ] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}\n" "$(_ts)" >&2
    printf "${CLR_CYAN}▶ [%s] [INFO   ]  %s${CLR_RESET}\n" "$(_ts)" "$1" >&2
    printf "${CLR_CYAN}━━ [%s] [INFO   ] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}\n" "$(_ts)" >&2
}

# ── Interactive prompt (works without gum/fzf) ────────────────
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local reply

    if [[ "$default" == "y" ]]; then
        printf "${CLR_BOLD}%s [Y/n]: ${CLR_RESET}" "$prompt"
    else
        printf "${CLR_BOLD}%s [y/N]: ${CLR_RESET}" "$prompt"
    fi

    read -r reply
    reply="${reply:-$default}"

    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  Banner
# ═══════════════════════════════════════════════════════════════

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
printf "${CLR_RED}${CLR_BOLD}   ── Uninstaller ──${CLR_RESET}\n\n"

# ═══════════════════════════════════════════════════════════════
#  STEP 1 — Root Check
# ═══════════════════════════════════════════════════════════════

if [[ $EUID -ne 0 ]]; then
    log_error "This uninstaller must be run as root."
    log_error "Usage: sudo bash uninstall.sh"
    exit 1
fi

log_info "Running as root — OK"

# ═══════════════════════════════════════════════════════════════
#  STEP 2 — Stop & Disable Services
# ═══════════════════════════════════════════════════════════════

log_section "Stopping SystemBackup Services"

SYSBACKUP_UNITS=(
    sysbackup-home.timer
    sysbackup-system.timer
    sysbackup-monitor.timer
    sysbackup-home.service
    sysbackup-system.service
    sysbackup-monitor.service
)

for unit in "${SYSBACKUP_UNITS[@]}"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        systemctl stop "$unit" 2>/dev/null || true
        log_info "Stopped $unit"
    fi
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        systemctl disable "$unit" 2>/dev/null || true
        log_info "Disabled $unit"
    fi
done

log_success "All SystemBackup services stopped and disabled"

# ═══════════════════════════════════════════════════════════════
#  STEP 3 — Remove Binary
# ═══════════════════════════════════════════════════════════════

log_section "Removing Installed Files"

if [[ -f /usr/local/bin/sysbackup ]]; then
    rm -f /usr/local/bin/sysbackup
    log_info "Removed /usr/local/bin/sysbackup"
else
    log_info "Binary not found at /usr/local/bin/sysbackup — already removed"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 4 — Remove Library Directory
# ═══════════════════════════════════════════════════════════════

if [[ -d /usr/local/lib/sysbackup ]]; then
    rm -rf /usr/local/lib/sysbackup
    log_info "Removed /usr/local/lib/sysbackup/"
else
    log_info "Library directory not found — already removed"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 5 — Remove systemd Units
# ═══════════════════════════════════════════════════════════════

UNITS_REMOVED=0
for unit_file in /etc/systemd/system/sysbackup-*.service /etc/systemd/system/sysbackup-*.timer; do
    if [[ -f "$unit_file" ]]; then
        rm -f "$unit_file"
        ((UNITS_REMOVED++))
    fi
done

if [[ "$UNITS_REMOVED" -gt 0 ]]; then
    log_info "Removed ${UNITS_REMOVED} systemd unit file(s)"
else
    log_info "No systemd unit files found — already removed"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 6 — Reload systemd
# ═══════════════════════════════════════════════════════════════

systemctl daemon-reload
log_success "systemd daemon reloaded"

# ═══════════════════════════════════════════════════════════════
#  STEP 7 — Ask: Remove Data?
# ═══════════════════════════════════════════════════════════════

log_section "Optional Cleanup"

if [[ -d /var/lib/sysbackup ]]; then
    printf "\n"
    log_warn "Data directory exists: /var/lib/sysbackup"
    log_warn "This contains backup data, logs, repos, and cache."
    printf "\n"

    if ask_yes_no "  Remove ALL backup data (/var/lib/sysbackup)?" "n"; then
        rm -rf /var/lib/sysbackup
        log_info "Removed /var/lib/sysbackup/"
    else
        log_info "Kept /var/lib/sysbackup/ (your data is preserved)"
    fi
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 8 — Ask: Remove Config?
# ═══════════════════════════════════════════════════════════════

if [[ -d /etc/sysbackup ]]; then
    printf "\n"
    log_warn "Configuration directory exists: /etc/sysbackup"
    log_warn "This contains your backup configuration and exclude lists."
    printf "\n"

    if ask_yes_no "  Remove ALL configuration (/etc/sysbackup)?" "n"; then
        rm -rf /etc/sysbackup
        log_info "Removed /etc/sysbackup/"
    else
        log_info "Kept /etc/sysbackup/ (your config is preserved)"
    fi
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 9 — Remove Sound Files
# ═══════════════════════════════════════════════════════════════

if [[ -d /usr/share/sysbackup ]]; then
    rm -rf /usr/share/sysbackup
    log_info "Removed /usr/share/sysbackup/"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 10 — Done
# ═══════════════════════════════════════════════════════════════

printf "\n"
log_section "Uninstall Complete"
printf "\n"
printf "${CLR_GREEN}  ✅  SystemBackup has been uninstalled.${CLR_RESET}\n\n"

if [[ -d /var/lib/sysbackup ]] || [[ -d /etc/sysbackup ]]; then
    printf "${CLR_DIM}  Note: Some directories were preserved at your request.${CLR_RESET}\n"
    [[ -d /var/lib/sysbackup ]] && printf "${CLR_DIM}    → /var/lib/sysbackup  (backup data)${CLR_RESET}\n"
    [[ -d /etc/sysbackup ]]     && printf "${CLR_DIM}    → /etc/sysbackup      (configuration)${CLR_RESET}\n"
    printf "\n"
fi

printf "${CLR_DIM}  To reinstall: sudo bash install.sh${CLR_RESET}\n\n"
