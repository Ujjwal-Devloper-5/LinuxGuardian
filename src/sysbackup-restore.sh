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
restic snapshots

echo ""
read -r -p "Enter snapshot ID to restore (or latest): " snap_id
if [[ -z "$snap_id" ]]; then
    die "Snapshot ID is required."
fi

read -r -p "Enter destination path to restore to (e.g., /tmp/restore): " target
if [[ -z "$target" ]]; then
    die "Destination path is required."
fi

ensure_dir "$target" "755"
log_info "Restoring snapshot $snap_id to $target..."

if restic restore "$snap_id" --target "$target"; then
    log_success "Restore completed successfully to $target"
else
    log_error "Restore encountered issues or failed."
    exit 1
fi
