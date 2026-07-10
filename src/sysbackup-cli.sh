#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — CLI / TUI Control Plane
#  Main entry point for user interaction.
# ═══════════════════════════════════════════════════════════════

set -o pipefail

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

# Load config if it exists (don't fail if it doesn't, init might be needed)
source /etc/sysbackup/sysbackup.conf 2>/dev/null || true

# ── Help / Usage ──────────────────────────────────────────────
show_help() {
    print_banner
    cat << EOF
USAGE:
    sysbackup <command> [options]

COMMANDS:
    init              Run the initialization wizard
    run               Run a backup now (use --home or --system)
    status            Show backup status dashboard
    snapshots         List all backup snapshots
    restore           Restore files from a snapshot
    config            Manage configuration
    relocate          Relocate local backup repositories
    cloud             Cloud storage management
    schedule          Manage backup schedule
    health            Show backup health report
    logs              View backup logs
    verify            Run integrity verification
    version           Show version information
    help              Show this help message

OPTIONS FOR RUN:
    --home            Backup home directory only
    --system          Backup system only
    --all             Backup both home and system
    --force           Skip idle check
    --dry-run         Simulate without making changes

EXAMPLES:
    sysbackup run --home
    sysbackup status --watch
    sysbackup snapshots --home
    sysbackup restore --interactive
    sysbackup logs --last 5
EOF
}

# ── Status Dashboard ──────────────────────────────────────────



cmd_status() {
    local watch=false
    if [[ "${1:-}" == "--watch" ]]; then
        watch=true
    fi
    
    draw_dashboard() {
        clear
        
        local hs="UNKNOWN"
        local grade="UNKNOWN"
        local emoji="⚪"
        local color="240"
        
        if check_command bc; then
            hs=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && calculate_health_score 2>/dev/null || echo "50")
            grade=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && get_health_grade "$hs" 2>/dev/null || echo "WARNING")
            emoji=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && get_grade_emoji "$grade" 2>/dev/null || echo "⚪")
            
            case "$grade" in
                EXCELLENT) color="46" ;;
                GOOD)      color="39" ;;
                WARNING)   color="214" ;;
                CRITICAL)  color="196" ;;
            esac
        fi

        # 1. Header Bar
        local header_text=" 🛡️ LINUX GUARDIAN v$SYSBACKUP_VERSION  |  HOST: $(hostname)  |  UPTIME: $(uptime -p | sed 's/up //') "
        gum style --width 82 --background 212 --foreground 0 --bold --align center "$header_text"
        echo ""

        # 2. Unified Status Area
        local health_text=" SYSTEM HEALTH: $hs/100 [$grade $emoji] "
        gum style --width 82 --border rounded --border-foreground "$color" --align center --bold "$health_text"

        # 3. Repository Stats
        local home_snap="None" home_date="Never" sys_snap="None" sys_date="Never"
        
        if is_repo_online "${HOME_REPO:-}" 2>/dev/null; then
            if is_repo_initialized "${HOME_REPO:-}" 2>/dev/null; then
                source "${SYSBACKUP_LIB_DIR}/modules/backup_engine.sh" 2>/dev/null || true
                home_snap=$(setup_restic_env "${HOME_REPO:-}"; restic snapshots --json --tag "type=home" --latest 1 2>/dev/null | jq -r ".[0].short_id // \"None\"")
                home_date=$(setup_restic_env "${HOME_REPO:-}"; restic snapshots --json --tag "type=home" --latest 1 2>/dev/null | jq -r ".[0].time // \"Never\"" | sed 's/T/ /' | cut -d. -f1)
            fi
        else
            home_snap="OFFLINE 🔌"
            home_date="Drive Unplugged"
        fi

        if is_repo_online "${SYSTEM_REPO:-}" 2>/dev/null; then
            if is_repo_initialized "${SYSTEM_REPO:-}" 2>/dev/null; then
                sys_snap=$(setup_restic_env "${SYSTEM_REPO:-}"; restic snapshots --json --tag "type=system" --latest 1 2>/dev/null | jq -r ".[0].short_id // \"None\"")
                sys_date=$(setup_restic_env "${SYSTEM_REPO:-}"; restic snapshots --json --tag "type=system" --latest 1 2>/dev/null | jq -r ".[0].time // \"Never\"" | sed 's/T/ /' | cut -d. -f1)
            fi
        else
            sys_snap="OFFLINE 🔌"
            sys_date="Drive Unplugged"
        fi

        local home_card sys_card
        home_card=$(gum style --width 40 --border rounded --border-foreground 39 --padding "0 1" \
            "📦 PERSONAL DATA" "" "ID  : $home_snap" "RUN : $home_date" "SCH : ${HOME_SCHEDULE:-Daily}")
        
        sys_card=$(gum style --width 40 --border rounded --border-foreground 212 --padding "0 1" \
            "🖥️  SYSTEM STATE" "" "ID  : $sys_snap" "RUN : $sys_date" "SCH : ${SYSTEM_SCHEDULE:-Weekly}")

        gum join --horizontal "$home_card" "$sys_card"

        # 4. Cloud Status
        echo ""
        local cloud_text=" 🛰️  CLOUD: ${CLOUD_REMOTE:-Not set} (${CLOUD_PROVIDER:-manual}) "
        gum style --width 82 --border rounded --border-foreground 117 --align center "$cloud_text"

        # 5. Footer Metrics
        local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
        local mem=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
        
        echo ""
        gum join --horizontal \
            "$(gum style --foreground 245 --width 27 --align center "CPU: $cpu%")" \
            "$(gum style --foreground 245 --width 28 --align center "MEM: $mem%")" \
            "$(gum style --foreground 245 --width 27 --align center "SHIELD: ACTIVE")"
    }
    
    if [[ "$watch" == "true" ]]; then
        while true; do
            draw_dashboard
            sleep 5
        done
    else
        draw_dashboard
    fi
}

# ── Snapshots ─────────────────────────────────────────────────
cmd_snapshots() {
    local filter_type=""
    if [[ "${1:-}" == "--home" ]]; then filter_type="home"; shift; fi
    if [[ "${1:-}" == "--system" ]]; then filter_type="system"; shift; fi
    
    local repo_path=""
    if [[ "$filter_type" == "home" ]]; then repo_path="${HOME_REPO:-}"
    elif [[ "$filter_type" == "system" ]]; then repo_path="${SYSTEM_REPO:-}"
    else
        echo "Please specify --home or --system"
        return 1
    fi
    
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
        log_error "Repository not found or not configured: $repo_path"
        return 1
    fi
    
    source "${SYSBACKUP_LIB_DIR}/modules/backup_engine.sh"
    setup_restic_env "$repo_path"
    
    log_info "Snapshots for $filter_type backup:"
    restic snapshots
}

# ── Logs ──────────────────────────────────────────────────────
cmd_logs() {
    local last_n=5
    if [[ "${1:-}" == "--last" ]]; then
        last_n="$2"
        shift 2
    fi
    
    local log_dir="${LOG_DIR:-/var/lib/sysbackup/logs}"
    if [[ ! -d "$log_dir" ]]; then
        log_error "Log directory not found: $log_dir"
        return 1
    fi
    
    ls -lt "$log_dir" | grep "sysbackup-.*\.log" | head -n "$last_n" | while read -r line; do
        local file
        file=$(echo "$line" | awk '{print $9}')
        echo "=== $file ==="
        tail -n 20 "$log_dir/$file"
        echo ""
    done
}


# ── Restore ───────────────────────────────────────────────────
cmd_restore() {
    exec "/usr/local/bin/sysbackup-restore.sh" "$@"
}

# ── Cloud ─────────────────────────────────────────────────────
cmd_cloud() {
    log_section "Cloud Storage Status"
    source /etc/sysbackup/sysbackup.conf
    echo "Remote Name : ${CLOUD_REMOTE:-Not set}"
    echo "Config Path : ${RCLONE_CONFIG:-Default}"
    echo ""
    echo "Cloud Directory Contents:"
    rclone lsd "${CLOUD_REMOTE:-}:${CLOUD_PATH:-sysbackup}" --config "${RCLONE_CONFIG:-}"
}

# ── Schedule ──────────────────────────────────────────────────
cmd_schedule() {
    log_section "Backup Schedule Status"
    systemctl list-timers sysbackup-* --no-pager
}

# ── Verify ────────────────────────────────────────────────────
cmd_verify() {
    log_section "Integrity Verification"
    source "${SYSBACKUP_LIB_DIR}/modules/backup_engine.sh"
    echo "Verifying Home Repository..."
    check_repo "${HOME_REPO}"
    echo "Verifying System Repository..."
    check_repo "${SYSTEM_REPO}"
}

# ── Health ────────────────────────────────────────────────────
cmd_health() {
    log_section "AI Health Report"
    source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh"
    local hs=$(calculate_health_score 2>/dev/null || echo "50")
    local grade=$(get_health_grade "$hs" 2>/dev/null || echo "WARNING")
    echo "Current Health Score: $hs/100"
    echo "System Grade        : $grade"
    source "${SYSBACKUP_LIB_DIR}/ai/anomaly_detect.sh"
    get_anomaly_report
}

# ── Config ────────────────────────────────────────────────────
cmd_config() {
    if [[ "${1:-}" == "--edit" ]]; then
        sudo nano /etc/sysbackup/sysbackup.conf
    else
        cat /etc/sysbackup/sysbackup.conf
    fi
}

# ── Relocation ────────────────────────────────────────────────
cmd_relocate() {
    require_root
    
    tui_header "Relocate Backup Repositories" "Move local repositories to a new drive"
    
    local src_home_repo="$HOME_REPO"
    local src_system_repo="$SYSTEM_REPO"
    local config_active=true

    # Auto-detect if current config paths actually exist locally
    if [[ ! -d "$src_home_repo" && ! -d "$src_system_repo" ]]; then
        config_active=false
    fi

    # If config paths don't exist, check default location
    if [[ "$config_active" == "false" && -d "/var/lib/sysbackup/repos" ]]; then
        tui_info "The currently configured repository paths do not exist."
        tui_info "However, existing backup repositories were found at the default location:"
        tui_info "  /var/lib/sysbackup/repos"
        echo ""
        if tui_confirm "Would you like to relocate from the default internal folder?" "yes"; then
            src_home_repo="/var/lib/sysbackup/repos/home"
            src_system_repo="/var/lib/sysbackup/repos/system"
        fi
    fi

    # Show confirmation of source directories
    echo ""
    echo -e "Source Repository Locations (Migrating FROM):"
    echo -e "  Home Repo   : $src_home_repo"
    echo -e "  System Repo : $src_system_repo"
    echo ""
    
    if ! tui_confirm "Are these the correct source paths of your existing backups?" "yes"; then
        local src_parent
        src_parent=$(tui_input "Enter parent directory of your existing backups" "/var/lib/sysbackup")
        src_home_repo="${src_parent}/repos/home"
        src_system_repo="${src_parent}/repos/system"
        echo ""
        echo -e "Updated Source Paths:"
        echo -e "  Home Repo   : $src_home_repo"
        echo -e "  System Repo : $src_system_repo"
        echo ""
    fi

    # Check if they are local paths
    if [[ ! "$src_home_repo" =~ ^/ ]] || [[ ! "$src_system_repo" =~ ^/ ]]; then
        log_error "Relocation is only supported for local repository paths starting with /"
        return 1
    fi
    
    # 2. Ask for new parent directory
    local new_parent
    new_parent=$(tui_input "Enter new parent directory (e.g. /mnt/portable)" "")
    if [[ -z "$new_parent" ]]; then
        log_error "Parent directory cannot be empty."
        return 1
    fi
    
    # Check if the parent directory exists
    if [[ ! -d "$new_parent" ]]; then
        log_warn "Directory '$new_parent' does not exist."
        if tui_confirm "Would you like to create it now?" "yes"; then
            mkdir -p "$new_parent" || { log_error "Failed to create directory."; return 1; }
        else
            log_error "Target directory must exist."
            return 1
        fi
    fi
    
    local new_home_repo="${new_parent}/repos/home"
    local new_system_repo="${new_parent}/repos/system"
    
    echo ""
    echo -e "New Repository Paths will be:"
    echo -e "  Home Repo   : $new_home_repo"
    echo -e "  System Repo : $new_system_repo"
    echo ""
    
    if [[ "$src_home_repo" == "$new_home_repo" || "$src_system_repo" == "$new_system_repo" ]]; then
        log_error "New paths are identical to the source paths. Relocation aborted."
        return 1
    fi

    # 3. Ask if they want to move existing files
    if tui_confirm "Move existing repository files to the new location?" "yes"; then
        # Move Home Repo
        if [[ -d "$src_home_repo" ]]; then
            log_info "Moving Home Repository with progress bar..."
            mkdir -p "$(dirname "$new_home_repo")"
            if rsync -ah --info=progress2 "$src_home_repo" "$(dirname "$new_home_repo")/"; then
                # Remove old repo after successful copy
                rm -rf "$src_home_repo"
                tui_success "Home repository files moved."
            else
                log_error "Failed to copy Home repository files."
                return 1
            fi
        else
            log_warn "Source Home repository directory ($src_home_repo) does not exist. Skipping file copy."
        fi
        
        # Move System Repo
        if [[ -d "$src_system_repo" ]]; then
            log_info "Moving System Repository with progress bar..."
            mkdir -p "$(dirname "$new_system_repo")"
            if rsync -ah --info=progress2 "$src_system_repo" "$(dirname "$new_system_repo")/"; then
                # Remove old repo after successful copy
                rm -rf "$src_system_repo"
                tui_success "System repository files moved."
            else
                log_error "Failed to copy System repository files."
                return 1
            fi
        else
            log_warn "Source System repository directory ($src_system_repo) does not exist. Skipping file copy."
        fi
    fi
    
    # 4. Update configuration file
    log_info "Updating configuration file /etc/sysbackup/sysbackup.conf..."
    sed -i "s|^HOME_REPO=.*|HOME_REPO=\"$new_home_repo\"|g" /etc/sysbackup/sysbackup.conf
    sed -i "s|^SYSTEM_REPO=.*|SYSTEM_REPO=\"$new_system_repo\"|g" /etc/sysbackup/sysbackup.conf
    
    # 5. Reload configuration in memory
    HOME_REPO="$new_home_repo"
    SYSTEM_REPO="$new_system_repo"
    
    # 6. Verify link
    tui_success "Configuration updated successfully!"
    echo ""
    log_info "Verifying new repository connections..."
    if is_repo_online "$HOME_REPO" && is_repo_initialized "$HOME_REPO" 2>/dev/null; then
        tui_success "Home repository verified at new location."
    else
        log_warn "Could not verify Home repository. You may need to run: sysbackup init"
    fi
    
    if is_repo_online "$SYSTEM_REPO" && is_repo_initialized "$SYSTEM_REPO" 2>/dev/null; then
        tui_success "System repository verified at new location."
    else
        log_warn "Could not verify System repository. You may need to run: sysbackup init"
    fi
}

# ── Main Dispatcher ───────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    local cmd="$1"
    shift
    
    case "$cmd" in
        init)
            require_root
            exec "${SYSBACKUP_LIB_DIR}/init-wizard.sh" "$@"
            ;;
        relocate)
            require_root
            cmd_relocate "$@"
            ;;
        run)
            exec "/usr/local/bin/sysbackup.sh" "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        snapshots)
            cmd_snapshots "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        restore)
            cmd_restore "$@"
            ;;
        cloud)
            cmd_cloud "$@"
            ;;
        schedule)
            cmd_schedule "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        health)
            cmd_health "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        metrics-collect)
            /usr/local/bin/sysbackup.sh --metrics
            ;;
        help)
            show_help
            ;;
        version)
            echo "SystemBackup v${SYSBACKUP_VERSION:-1.0.0}"
            ;;
        *)
            log_error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
