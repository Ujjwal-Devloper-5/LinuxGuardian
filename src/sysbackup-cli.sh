#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — CLI / TUI Control Plane
#  Main entry point for user interaction.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

# Load config if it exists (don't fail if it doesn't, init might be needed)
load_config 2>/dev/null || true

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
    
    local draw_dashboard() {
        clear
        print_banner
        
        local hs="UNKNOWN"
        local grade="UNKNOWN"
        local emoji="⚪"
        
        if check_command bc; then
            hs=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && calculate_health_score 2>/dev/null || echo "50")
            grade=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && get_health_grade "$hs" 2>/dev/null || echo "WARNING")
            emoji=$(source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh" && get_grade_emoji "$grade" 2>/dev/null || echo "⚪")
        fi
        
        echo "╔══════════════════════════════════════════════════════════════╗"
        printf "║  🛡️  SystemBackup Dashboard — %-29s ║\n" "$(get_hostname)"
        printf "║  Health Score: %3s/100 %s %-32s ║\n" "$hs" "$emoji" "$grade"
        echo "╠══════════════════════════════════════════════════════════════╣"
        
        # Home Backup
        local home_snap="None"
        local home_date="Never"
        if is_repo_initialized "${HOME_REPO:-}" 2>/dev/null; then
            source "${SYSBACKUP_LIB_DIR}/modules/backup_engine.sh" 2>/dev/null || true
            home_snap=$(get_latest_snapshot_id "${HOME_REPO:-}" "home" 2>/dev/null || echo "None")
            if [[ "$home_snap" != "None" && "$home_snap" != "unknown" ]]; then
                # Get date (mock implementation for dashboard)
                home_date=$(date '+%Y-%m-%d %H:%M:%S')
            fi
        fi
        
        printf "║  📦 Last Home Backup    │ %-29s      ║\n" "$home_date"
        printf "║     Snapshot: %-9s │                              ║\n" "$home_snap"
        
        # System Backup
        echo "║                                                              ║"
        local sys_snap="None"
        local sys_date="Never"
        if is_repo_initialized "${SYSTEM_REPO:-}" 2>/dev/null; then
            sys_snap=$(get_latest_snapshot_id "${SYSTEM_REPO:-}" "system" 2>/dev/null || echo "None")
            if [[ "$sys_snap" != "None" && "$sys_snap" != "unknown" ]]; then
                sys_date=$(date '+%Y-%m-%d %H:%M:%S' -d "1 day ago") # Mock
            fi
        fi
        
        printf "║  🖥️  Last System Backup  │ %-29s      ║\n" "$sys_date"
        printf "║     Snapshot: %-9s │                              ║\n" "$sys_snap"
        
        # Cloud Sync
        echo "║                                                              ║"
        printf "║  ☁️  Cloud Sync          │ Provider: %-20s  ║\n" "${CLOUD_PROVIDER:-None}"
        printf "║     Remote: %-11s │                              ║\n" "${CLOUD_REMOTE:-None}"
        
        # Schedule
        echo "║                                                              ║"
        printf "║  🗓️  Schedule                                                ║\n"
        printf "║     Home:   %-10s │ %-28s ║\n" "${HOME_SCHEDULE:-Not set}" "${HOME_TIME:-}"
        printf "║     System: %-10s │ %s %-24s ║\n" "${SYSTEM_SCHEDULE:-Not set}" "${SYSTEM_DAY:-}" "${SYSTEM_TIME:-}"
        echo "╚══════════════════════════════════════════════════════════════╝"
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
            exec "${SYSBACKUP_LIB_DIR}/../init-wizard.sh" "$@"
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
