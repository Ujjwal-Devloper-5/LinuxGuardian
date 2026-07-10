#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — One-Click Restore Utility
#  Provides an interactive UI to list snapshots and restore data.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Resolve library path
SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

load_config || die "Failed to load configuration"
print_banner

echo -e "${CLR_CYAN}▶ One-Click Restore Utility${CLR_RESET}"
echo "Select which backup repository to restore from:"
echo "  1) Home Backup"
echo "  2) System Backup"
read -r -p "Choice (1/2): " choice

case "$choice" in
    1) repo="$(config_get "HOME_REPO" "")" ;;
    2) 
       require_root
       repo="$(config_get "SYSTEM_REPO" "")" 
       ;;
    *) die "Invalid choice." ;;
esac

if [[ -z "$repo" ]]; then
    die "Repository path is not configured in sysbackup.conf."
fi

export RESTIC_REPOSITORY="$repo"
export RESTIC_PASSWORD_FILE="$(config_get "RESTIC_PASSWORD_FILE" "")"

log_section "Available Snapshots"
restic snapshots || die "Failed to retrieve snapshots. Check repository connection and password."

echo ""
read -r -p "Enter snapshot ID to restore (or latest): " snap_id
snap_id="${snap_id:-latest}"

# ── Subpath Filtering Option ──────────────────────────────────
echo ""
read -r -p "Restore the entire backup? [Y/n]: " whole_restore
whole_restore="${whole_restore:-y}"
include_args=()

if [[ "$whole_restore" =~ ^[Nn] ]]; then
    read -r -p "Enter specific folder/file subpath to restore (e.g. home/ujjwal/Documents): " subpath
    if [[ -n "$subpath" ]]; then
        include_args+=(--include "$subpath")
        log_info "Selective restore filter added: $subpath"
    else
        log_warn "Empty subpath. Restoring the entire backup."
    fi
fi

# ── Migration / Destination Selection ─────────────────────────
echo ""
echo "Select Restore Mode:"
echo "  1) Safe Restore (Restore to a temporary or custom folder)"
echo "  2) In-Place Migration (Restore directly to active OS paths)"
read -r -p "Choice (1/2): " restore_mode

target=""
if [[ "$restore_mode" -eq 2 ]]; then
    require_root
    if [[ "$choice" -eq 1 ]]; then
        echo -e "${CLR_YELLOW}${CLR_BOLD}⚠️  WARNING: You are about to restore personal data directly to your active root system. This will overwrite files in your home directories.${CLR_RESET}"
        read -r -p "Are you sure you want to perform in-place migration? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy] ]] || die "Migration aborted by user."
        target="/"
    else
        echo -e "${CLR_RED}${CLR_BOLD}🚨 DANGER: Restoring system configurations directly to / on a live OS can cause stability issues and break boot configurations.${CLR_RESET}"
        read -r -p "Do you want to proceed and force system restoration directly to /? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy] ]] || die "System migration aborted by user."
        target="/"
    fi
else
    read -r -p "Enter destination path to restore to (e.g., /tmp/restore): " target
    if [[ -z "$target" ]]; then
        die "Destination path is required."
    fi
fi

ensure_dir "$target" "755"

# ── Initialize Dedicated Restore Log ──────────────────────────
log_dir=$(config_get "LOG_DIR" "/var/lib/sysbackup/logs")
mkdir -p "$log_dir"
ts=$(date '+%Y-%m-%d_%H%M%S')
restore_log="${log_dir}/sysbackup-restore-${ts}.log"
touch "$restore_log"

log_info "Restoring snapshot $snap_id to $target..."
log_info "Detailed logs are being written to: $restore_log"
echo "This may take some time depending on your backup size. Please wait..."

# Run restic restore redirecting outputs to the log file
if restic restore "$snap_id" --target "$target" "${include_args[@]}" > "$restore_log" 2>&1; then
    log_success "Restore completed successfully to $target"
else
    # Parse log file to see if failures are only non-fatal skipped sockets/FIFOs
    local total_errors
    total_errors=$(grep -c -i "error" "$restore_log" || echo 0)
    local skipped_sockets
    skipped_sockets=$(grep -c -i "socket file skipped" "$restore_log" || echo 0)
    local skipped_fifos
    skipped_fifos=$(grep -c -i "fifo skipped" "$restore_log" || echo 0)
    local non_fatal_skips=$((skipped_sockets + skipped_fifos))

    if [[ "$total_errors" -eq "$non_fatal_skips" && "$non_fatal_skips" -gt 0 ]]; then
        log_warn "Restore completed with $non_fatal_skips non-fatal warnings (skipped sockets/pipes)."
        log_success "All data files and directories successfully restored to $target"
    else
        log_error "Restore encountered fatal errors."
        log_error "Please check the detailed logs at: $restore_log"
        exit 1
    fi
fi
