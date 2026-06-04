#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Main Backup Orchestrator
#  This is the core backup pipeline that runs all phases:
#    Pre-flight → Idle Check → Backup → AI Analysis →
#    Cloud Sync → Retention → Notification
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Resolve library path ──────────────────────────────────────
SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}"

# ── Source all modules ────────────────────────────────────────
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"
source "${SYSBACKUP_LIB_DIR}/modules/backup_engine.sh"
source "${SYSBACKUP_LIB_DIR}/modules/cloud_sync.sh"
source "${SYSBACKUP_LIB_DIR}/modules/idle_detect.sh"
source "${SYSBACKUP_LIB_DIR}/modules/notifications.sh"
source "${SYSBACKUP_LIB_DIR}/modules/retention.sh"

# ── Source AI modules ─────────────────────────────────────────
source "${SYSBACKUP_LIB_DIR}/ai/anomaly_detect.sh"
source "${SYSBACKUP_LIB_DIR}/ai/predict_storage.sh"
source "${SYSBACKUP_LIB_DIR}/ai/smart_schedule.sh"
source "${SYSBACKUP_LIB_DIR}/ai/integrity_verify.sh"
source "${SYSBACKUP_LIB_DIR}/ai/log_analyzer.sh"
source "${SYSBACKUP_LIB_DIR}/ai/health_score.sh"

# ═══════════════════════════════════════════════════════════════
#  PIPELINE PHASES
# ═══════════════════════════════════════════════════════════════

# ── Phase 1: Pre-flight Checks ────────────────────────────────
phase_preflight() {
    log_section "Phase 1: Pre-flight Checks"

    # Load and validate configuration
    load_config || die "Failed to load configuration"
    validate_config || die "Configuration validation failed"

    # Ensure data directories exist
    ensure_data_dirs

    # Check dependencies
    check_dependency "restic" "restic" "true" || die "restic is required"
    check_dependency "python3" "python3" "true" || die "python3 is required for AI modules"
    
    if [[ "${CLOUD_ENABLED:-true}" == "true" ]]; then
        check_dependency "rclone" "rclone" "true" || die "rclone is required for cloud sync"
    fi

    # Check repos are initialized
    local backup_type="$1"
    if [[ "$backup_type" == "home" || "$backup_type" == "all" ]]; then
        if ! is_repo_initialized "$HOME_REPO" 2>/dev/null; then
            log_warn "Home repo not initialized. Initializing now..."
            init_repo "$HOME_REPO" || die "Failed to initialize home repo"
        fi
    fi
    if [[ "$backup_type" == "system" || "$backup_type" == "all" ]]; then
        if ! is_repo_initialized "$SYSTEM_REPO" 2>/dev/null; then
            log_warn "System repo not initialized. Initializing now..."
            init_repo "$SYSTEM_REPO" || die "Failed to initialize system repo"
        fi
    fi

    # Check available disk space (warn if < 10GB free at repo location)
    local repo_dir
    if [[ "$backup_type" == "home" ]]; then
        repo_dir="$HOME_REPO"
    else
        repo_dir="$SYSTEM_REPO"
    fi
    local free_space
    free_space=$(df -B1 "$(dirname "$repo_dir")" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    if [[ "$free_space" -lt 10737418240 ]]; then  # 10 GB
        log_warn "Low disk space: $(human_size "$free_space") free at $(dirname "$repo_dir")"
    fi

    # Acquire lock
    lock_acquire || die "Failed to acquire lock — another backup may be running"

    log_success "Pre-flight checks passed"
}

# ── Phase 2: Idle Check ───────────────────────────────────────
phase_idle_check() {
    local force="${1:-false}"

    if [[ "$force" == "true" ]]; then
        log_info "Idle check skipped (--force flag)"
        return 0
    fi

    if [[ "${SMART_SCHEDULE_ENABLED:-true}" != "true" ]]; then
        log_info "Smart scheduling disabled, proceeding immediately"
        return 0
    fi

    log_section "Phase 2: Idle Detection"

    # Record current system metrics for AI analysis
    record_system_metrics

    if is_system_idle; then
        log_success "System is idle — proceeding with backup"
        return 0
    fi

    # System is not idle — attempt deferred start
    log_warn "System is not idle"

    if should_defer_backup; then
        log_warn "Deferring backup — system is active"
        log_info "Will retry when system is idle (max defer: ${MAX_DEFER_HOURS:-6}h)"
        return 1
    fi

    log_warn "Maximum defer time reached — forcing backup"
    return 0
}

# ── Phase 3: Execute Backup ───────────────────────────────────
phase_backup() {
    local backup_type="$1"
    local start_time
    start_time=$(date +%s)

    log_section "Phase 3: Executing Backup ($backup_type)"

    local backup_exit_code=0
    local snapshot_id=""
    local backup_size=0
    local files_changed=0

    case "$backup_type" in
        home)
            if backup_home; then
                snapshot_id=$(get_latest_snapshot_id "$HOME_REPO" "home")
                log_success "Home backup completed — Snapshot: $snapshot_id"
            else
                backup_exit_code=1
                log_error "Home backup FAILED"
            fi
            ;;
        system)
            require_root
            if backup_system; then
                snapshot_id=$(get_latest_snapshot_id "$SYSTEM_REPO" "system")
                log_success "System backup completed — Snapshot: $snapshot_id"
            else
                backup_exit_code=1
                log_error "System backup FAILED"
            fi
            ;;
        all)
            # Home first (faster, higher priority)
            if backup_home; then
                local home_snap
                home_snap=$(get_latest_snapshot_id "$HOME_REPO" "home")
                log_success "Home backup completed — Snapshot: $home_snap"
            else
                backup_exit_code=1
                log_error "Home backup FAILED"
            fi

            # Then system
            require_root
            if backup_system; then
                local sys_snap
                sys_snap=$(get_latest_snapshot_id "$SYSTEM_REPO" "system")
                log_success "System backup completed — Snapshot: $sys_snap"
            else
                backup_exit_code=1
                log_error "System backup FAILED"
            fi
            ;;
        *)
            die "Unknown backup type: $backup_type"
            ;;
    esac

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Store results in global vars for later phases
    BACKUP_EXIT_CODE=$backup_exit_code
    BACKUP_DURATION=$duration
    BACKUP_SNAPSHOT_ID="${snapshot_id:-none}"
    BACKUP_TYPE="$backup_type"
    BACKUP_START_TIME=$start_time

    log_info "Backup phase completed in $(human_duration "$duration")"
    return "$backup_exit_code"
}

# ── Phase 4: AI Analysis ─────────────────────────────────────
phase_ai_analysis() {
    local backup_type="$1"
    local repo_path

    if [[ "$backup_type" == "home" ]]; then
        repo_path="$HOME_REPO"
    else
        repo_path="$SYSTEM_REPO"
    fi

    log_section "Phase 4: AI Analysis"

    # Initialize AI result globals
    ANOMALY_LEVEL="OK"
    ANOMALY_ZSCORE="0"
    INTEGRITY_PASS=true
    STORAGE_DAYS_REMAINING=999
    DURATION_RATIO="1.0"

    # 4a. Anomaly Detection
    if [[ "${ANOMALY_DETECTION:-true}" == "true" ]]; then
        log_info "Running anomaly detection..."
        local last_size
        last_size=$(get_last_backup_size "$repo_path" 2>/dev/null || echo 0)
        if [[ "$last_size" -gt 0 ]]; then
            local anomaly_result
            anomaly_result=$(check_anomaly "$last_size" 2>/dev/null || echo "OK|0|0|0")
            ANOMALY_LEVEL=$(echo "$anomaly_result" | cut -d'|' -f1)
            ANOMALY_ZSCORE=$(echo "$anomaly_result" | cut -d'|' -f2)
            case "$ANOMALY_LEVEL" in
                CRITICAL) log_error "ANOMALY DETECTED: Z-score=$ANOMALY_ZSCORE — Backup size is highly unusual!" ;;
                WARNING)  log_warn "Anomaly warning: Z-score=$ANOMALY_ZSCORE — Backup size is unusual" ;;
                *)        log_info "Anomaly check: OK (Z-score=$ANOMALY_ZSCORE)" ;;
            esac
        else
            log_info "Anomaly detection: Insufficient data (first backup)"
        fi
    fi

    # 4b. Integrity Verification
    if [[ "${INTEGRITY_VERIFY:-true}" == "true" ]]; then
        log_info "Running integrity verification..."
        if run_verification "$repo_path"; then
            log_success "Integrity verification passed"
            INTEGRITY_PASS=true
        else
            log_error "Integrity verification FAILED"
            INTEGRITY_PASS=false
        fi
    fi

    # 4c. Storage Prediction
    if [[ "${STORAGE_PREDICTION:-true}" == "true" ]]; then
        log_info "Running storage prediction..."
        record_storage_usage "$repo_path"
        local prediction
        prediction=$(predict_storage_usage 2>/dev/null || echo "")
        if [[ -n "$prediction" ]]; then
            STORAGE_DAYS_REMAINING=$(echo "$prediction" | grep -oP 'days_until_full=\K[0-9]+' || echo 999)
            log_info "Storage prediction: ~${STORAGE_DAYS_REMAINING} days remaining"
        fi
    fi

    # 4d. Log Analysis
    if [[ "${LOG_ANALYSIS:-true}" == "true" && -n "${SYSBACKUP_LOG_FILE:-}" ]]; then
        log_info "Running log analysis..."
        analyze_log "$SYSBACKUP_LOG_FILE" 2>/dev/null || true
        detect_error_trend 2>/dev/null || true
    fi

    # 4e. Duration ratio (actual vs expected)
    local expected_duration
    expected_duration=$(get_mean_duration "$backup_type" 2>/dev/null || echo 0)
    if [[ "$expected_duration" -gt 0 ]]; then
        DURATION_RATIO=$(echo "scale=2; ${BACKUP_DURATION:-0} / $expected_duration" | bc -l 2>/dev/null || echo "1.0")
    fi

    log_success "AI analysis complete"
}

# ── Phase 5: Cloud Sync ──────────────────────────────────────
phase_cloud_sync() {
    local backup_type="$1"

    if [[ "${CLOUD_ENABLED:-true}" != "true" ]]; then
        log_info "Cloud sync disabled — skipping"
        return 0
    fi

    log_section "Phase 5: Cloud Sync"

    local sync_success=true
    local start_time
    start_time=$(date +%s)

    if [[ "$backup_type" == "home" || "$backup_type" == "all" ]]; then
        log_info "Syncing home repo to cloud..."
        if sync_to_cloud "$HOME_REPO" "home"; then
            log_success "Home repo synced to cloud"
        else
            log_error "Home repo cloud sync FAILED"
            sync_success=false
        fi
    fi

    if [[ "$backup_type" == "system" || "$backup_type" == "all" ]]; then
        log_info "Syncing system repo to cloud..."
        if sync_to_cloud "$SYSTEM_REPO" "system"; then
            log_success "System repo synced to cloud"
        else
            log_error "System repo cloud sync FAILED"
            sync_success=false
        fi
    fi

    local duration=$(( $(date +%s) - start_time ))
    log_info "Cloud sync phase completed in $(human_duration "$duration")"

    CLOUD_SYNC_SUCCESS=$sync_success
}

# ── Phase 6: Retention & Pruning ──────────────────────────────
phase_retention() {
    local backup_type="$1"

    log_section "Phase 6: Retention & Pruning"

    if [[ "$backup_type" == "home" || "$backup_type" == "all" ]]; then
        log_info "Pruning home snapshots..."
        prune_snapshots "$HOME_REPO" "home" || log_warn "Home pruning encountered issues"
    fi

    if [[ "$backup_type" == "system" || "$backup_type" == "all" ]]; then
        log_info "Pruning system snapshots..."
        prune_snapshots "$SYSTEM_REPO" "system" || log_warn "System pruning encountered issues"
    fi

    log_success "Retention phase complete"
}

# ── Phase 7: Notification ────────────────────────────────────
phase_notification() {
    log_section "Phase 7: Notification"

    if [[ "${NOTIFY_ENABLED:-true}" != "true" ]]; then
        log_info "Notifications disabled — skipping"
        return 0
    fi

    # Calculate health score
    local completion_score=0
    [[ "${BACKUP_EXIT_CODE:-1}" -eq 0 ]] && completion_score=100

    local integrity_score=0
    [[ "${INTEGRITY_PASS:-false}" == "true" ]] && integrity_score=100

    local zscore_abs
    zscore_abs=$(echo "${ANOMALY_ZSCORE:-0}" | awk '{print ($1<0) ? -$1 : $1}')

    local health_score
    health_score=$(calculate_health_score \
        "$completion_score" \
        "$zscore_abs" \
        "$integrity_score" \
        "${STORAGE_DAYS_REMAINING:-999}" \
        "${DURATION_RATIO:-1.0}" 2>/dev/null || echo 50)

    local grade
    grade=$(get_health_grade "$health_score" 2>/dev/null || echo "UNKNOWN")

    log_info "Health Score: ${health_score}/100 (${grade})"

    # Generate report
    local report
    report=$(generate_backup_report \
        "$health_score" \
        "${BACKUP_TYPE:-unknown}" \
        "${BACKUP_DURATION:-0}" \
        "${ANOMALY_ZSCORE:-0}" \
        "${STORAGE_DAYS_REMAINING:-999}" \
        "${CLOUD_SYNC_SUCCESS:-false}" 2>/dev/null || echo "Backup completed.")

    # Send notification
    if [[ "${BACKUP_EXIT_CODE:-1}" -eq 0 ]]; then
        if [[ "${NOTIFY_ON_SUCCESS:-true}" == "true" ]]; then
            send_backup_report "$health_score" "$report"
            log_success "Success notification sent"
        fi
    else
        if [[ "${NOTIFY_ON_FAILURE:-true}" == "true" ]]; then
            send_failure_notification "Backup failed. Check logs: ${SYSBACKUP_LOG_FILE:-/var/lib/linuxguardian/logs/}"
            log_info "Failure notification sent"
        fi
    fi
}

# ── Phase 8: Cleanup ─────────────────────────────────────────
phase_cleanup() {
    log_section "Phase 8: Cleanup"

    # Rotate old logs
    rotate_logs

    # Update last backup timestamp marker
    touch "${DATA_DIR:-/var/lib/linuxguardian}/data/last_backup_timestamp"

    # Release lock
    lock_release

    log_success "Cleanup complete"
}

# ═══════════════════════════════════════════════════════════════
#  MAIN PIPELINE RUNNER
# ═══════════════════════════════════════════════════════════════

run_backup_pipeline() {
    local backup_type="${1:-home}"
    local force="${2:-false}"
    local dry_run="${3:-false}"

    # Set dry-run mode globally
    export SYSBACKUP_DRY_RUN="$dry_run"

    # Initialize logging
    init_log_file "$backup_type"

    print_banner
    log_info "Starting backup pipeline"
    log_info "  Type: $backup_type"
    log_info "  Force: $force"
    log_info "  Dry-run: $dry_run"
    log_info "  Hostname: $(get_hostname)"
    log_info "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    local pipeline_start
    pipeline_start=$(date +%s)
    local pipeline_success=true

    # ── Phase 1: Pre-flight ───────────────────────────────────
    if ! phase_preflight "$backup_type"; then
        die "Pre-flight checks failed"
    fi

    # ── Phase 2: Idle Check ───────────────────────────────────
    if ! phase_idle_check "$force"; then
        log_warn "Backup deferred — system is not idle"
        lock_release
        exit 0
    fi

    # ── Phase 3: Backup ───────────────────────────────────────
    if ! phase_backup "$backup_type"; then
        log_error "Backup phase failed"
        pipeline_success=false
    fi

    # Continue with post-backup phases even if backup had issues
    # (to capture state and notify)

    # ── Phase 4: AI Analysis ──────────────────────────────────
    phase_ai_analysis "$backup_type" || log_warn "AI analysis had issues"

    # ── Phase 5: Cloud Sync ───────────────────────────────────
    if [[ "$pipeline_success" == "true" ]]; then
        phase_cloud_sync "$backup_type" || log_warn "Cloud sync had issues"
    else
        log_warn "Skipping cloud sync due to backup failure"
        CLOUD_SYNC_SUCCESS=false
    fi

    # ── Phase 6: Retention ────────────────────────────────────
    if [[ "$pipeline_success" == "true" ]]; then
        phase_retention "$backup_type" || log_warn "Retention phase had issues"
    fi

    # ── Phase 7: Notification ─────────────────────────────────
    phase_notification || log_warn "Notification phase had issues"

    # ── Phase 8: Cleanup ──────────────────────────────────────
    phase_cleanup

    # ── Final Summary ─────────────────────────────────────────
    local pipeline_duration=$(( $(date +%s) - pipeline_start ))
    log_section "Pipeline Complete"
    log_info "Total duration: $(human_duration "$pipeline_duration")"

    if [[ "$pipeline_success" == "true" ]]; then
        log_success "Backup pipeline completed successfully! 🎉"
        return 0
    else
        log_error "Backup pipeline completed with errors"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  METRICS COLLECTION (called by monitor timer)
# ═══════════════════════════════════════════════════════════════

run_metrics_collection() {
    # Lightweight — just record current system metrics
    source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"
    load_config 2>/dev/null || true
    source "${SYSBACKUP_LIB_DIR}/modules/idle_detect.sh"

    record_system_metrics
}

# ═══════════════════════════════════════════════════════════════
#  HELPER: Get mean backup duration from history
# ═══════════════════════════════════════════════════════════════

get_mean_duration() {
    local backup_type="$1"
    local history_file="${DATA_DIR:-/var/lib/linuxguardian}/data/backup_sizes.log"

    if [[ ! -f "$history_file" ]]; then
        echo 0
        return
    fi

    # backup_sizes.log format: timestamp,type,size_bytes,duration_seconds,files_changed
    awk -F',' -v type="$backup_type" '
    $2 == type && $4 > 0 {
        sum += $4
        n++
    }
    END {
        if (n > 0) printf "%.0f", sum/n
        else print 0
    }' "$history_file"
}

# ═══════════════════════════════════════════════════════════════
#  HELPER: Get last backup size
# ═══════════════════════════════════════════════════════════════

get_last_backup_size() {
    local repo_path="$1"
    local history_file="${DATA_DIR:-/var/lib/linuxguardian}/data/backup_sizes.log"

    if [[ ! -f "$history_file" ]]; then
        echo 0
        return
    fi

    tail -1 "$history_file" | cut -d',' -f3
}

# ═══════════════════════════════════════════════════════════════
#  HELPER: Get latest snapshot ID
# ═══════════════════════════════════════════════════════════════

get_latest_snapshot_id() {
    local repo_path="$1"
    local tag_type="${2:-}"

    setup_restic_env "$repo_path"

    local tag_filter=""
    if [[ -n "$tag_type" ]]; then
        tag_filter="--tag type=$tag_type"
    fi

    # shellcheck disable=SC2086
    restic snapshots --json --latest 1 $tag_filter 2>/dev/null | \
        jq -r '.[0].short_id // "unknown"' 2>/dev/null || echo "unknown"
}

# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT (when called directly)
# ═══════════════════════════════════════════════════════════════

# This file is primarily sourced by linuxguardian-cli.sh
# But can be run directly for testing:
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_traps

    # Simple argument parsing for direct execution
    BACKUP_TYPE="home"
    FORCE=false
    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --home)    BACKUP_TYPE="home"; shift ;;
            --system)  BACKUP_TYPE="system"; shift ;;
            --all)     BACKUP_TYPE="all"; shift ;;
            --force)   FORCE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --metrics) run_metrics_collection; exit $? ;;
            *)         echo "Unknown argument: $1"; exit 1 ;;
        esac
    done

    run_backup_pipeline "$BACKUP_TYPE" "$FORCE" "$DRY_RUN"
fi
