#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Advanced Recovery & Restore System
#  Enterprise-grade tool for partial and full disaster recovery.
# ═══════════════════════════════════════════════════════════════

set -o pipefail

# ── Resolve library path ──────────────────────────────────────
SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

# ── Initialization / Bootstrap Logic ─────────────────────────
bootstrap_new_system() {
    log_warn "Configuration file not found. Switching to NEW SYSTEM RECOVERY mode."
    echo "This mode allows you to restore data to a fresh installation."
    echo ""
    
    # 1. Rclone Setup
    if ! command -v rclone &>/dev/null; then
        die "rclone is not installed. Please run: sudo pacman -S rclone"
    fi
    
    read -r -p "Enter your Google Drive rclone remote name (e.g., fortress-cloudbackup): " CLOUD_REMOTE
    read -r -p "Enter your rclone config path (default: ~/.config/rclone/rclone.conf): " RCLONE_CONFIG
    RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
    
    if [[ ! -f "$RCLONE_CONFIG" ]]; then
        die "rclone config not found at $RCLONE_CONFIG. Please run "rclone config" first."
    fi

    # 2. Restic Password Setup
    read -r -s -p "Enter your Restic Master Password (the one you set during backup): " RESTIC_PASSWORD
    echo ""
    export RESTIC_PASSWORD="$RESTIC_PASSWORD"
}

# ── Main UI ───────────────────────────────────────────────────
print_banner

if [[ ! -f "/etc/sysbackup/sysbackup.conf" ]]; then
    bootstrap_new_system
    MODE="cloud"
else
    source /etc/sysbackup/sysbackup.conf
    MODE="local"
    log_info "Configuration detected. Mode: Standard Recovery"
fi

echo -e "${CLR_CYAN}▶ Advanced Restore System${CLR_RESET}"
echo "What would you like to restore?"
echo "  1) Home Data (/home)"
echo "  2) System Data (/)"
read -r -p "Choice (1/2): " type_choice

case "$type_choice" in
    1) 
       TYPE="home"
       REPO_LOCAL="${HOME_REPO:-/var/lib/sysbackup/repos/home}"
       REPO_CLOUD="rclone:${CLOUD_REMOTE:-fortress-cloudbackup}:sysbackup/home"
       ;;
    2) 
       TYPE="system"
       REPO_LOCAL="${SYSTEM_REPO:-/var/lib/sysbackup/repos/system}"
       REPO_CLOUD="rclone:${CLOUD_REMOTE:-fortress-cloudbackup}:sysbackup/system"
       require_root
       ;;
    *) die "Invalid choice." ;;
esac

# ── Location Choice ──────────────────────────────────────────
echo ""
echo "Select Source Location:"
echo "  1) Local Disk (Fastest - Recommended)"
echo "  2) Cloud (Google Drive - Direct Download)"
read -r -p "Choice (1/2): " loc_choice

if [[ "$loc_choice" == "1" ]]; then
    export RESTIC_REPOSITORY="$REPO_LOCAL"
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/var/lib/sysbackup/.restic-password}"
else
    export RESTIC_REPOSITORY="$REPO_CLOUD"
    export RCLONE_CONFIG="${RCLONE_CONFIG:-/home/ujjwal/.config/rclone/rclone.conf}"
    # Use password file if available, otherwise use the one from bootstrap
    if [[ -f "/var/lib/sysbackup/.restic-password" ]]; then
        export RESTIC_PASSWORD_FILE="/var/lib/sysbackup/.restic-password"
    fi
fi

# ── Snapshot Selection ────────────────────────────────────────
log_section "Available Snapshots ($TYPE)"
restic snapshots --option rclone.program="rclone --config $RCLONE_CONFIG" 2>/dev/null || restic snapshots

echo ""
read -r -p "Enter Snapshot ID to restore (or "latest"): " SNAP_ID
SNAP_ID="${SNAP_ID:-latest}"

# ── Scope Selection ──────────────────────────────────────────
echo ""
echo "Select Restore Scope:"
echo "  1) Full Restore (Everything in snapshot)"
echo "  2) Selective Restore (Specific files or folders)"
read -r -p "Choice (1/2): " scope_choice

case "$scope_choice" in
    1) SCOPE_ARGS="" ;;
    2) 
       read -r -p "Enter path to file/folder (e.g., /home/user/Documents): " SELECTIVE_PATH
       SCOPE_ARGS="--include $SELECTIVE_PATH"
       ;;
    *) die "Invalid choice." ;;
esac

# ── Target Selection ──────────────────────────────────────────
echo ""
read -r -p "Enter Target Path (e.g., /tmp/restore or /): " TARGET_PATH
TARGET_PATH="${TARGET_PATH:-/tmp/restore}"

if [[ "$TARGET_PATH" == "/" ]]; then
    log_warn "DANGER: You are restoring directly to the LIVE system (/)."
    read -r -p "Are you absolutely sure you want to overwrite existing files? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then die "Restore cancelled."; fi
fi

# ── Execute Restore ───────────────────────────────────────────
ensure_dir "$TARGET_PATH" "755"
log_info "Initiating restore from $RESTIC_REPOSITORY..."

if restic restore "$SNAP_ID" --target "$TARGET_PATH" $SCOPE_ARGS --option rclone.program="rclone --config $RCLONE_CONFIG"; then
    log_success "Restore completed successfully to: $TARGET_PATH"
else
    log_error "Restore encountered errors. Please check the logs."
    exit 1
fi
