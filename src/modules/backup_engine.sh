#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Backup Engine Module
#  Core restic backup operations: home/system backups, snapshot
#  management, repo initialization, integrity checks.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly BACKUP_SIZES_LOG="${SYSBACKUP_DATA_DIR:-/var/lib/linuxguardian}/data/backup_sizes.log"
readonly BACKUP_ENGINE_VERSION="1.0.0"

# ═══════════════════════════════════════════════════════════════
#  REPOSITORY MANAGEMENT
# ═══════════════════════════════════════════════════════════════

# Initialize a new restic repository
# Usage: init_repo /path/to/repo
init_repo() {
    local repo_path="${1:?Usage: init_repo <repo_path>}"

    log_section "Initializing Restic Repository"
    log_info "Repository path: $repo_path"

    setup_restic_env "$repo_path"

    # Check if already initialized
    if is_repo_initialized "$repo_path" 2>/dev/null; then
        log_warn "Repository already initialized: $repo_path"
        return 0
    fi

    # Ensure parent directory exists
    ensure_dir "$(dirname "$repo_path")" "700"

    # Dry-run guard
    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize restic repo at: $repo_path"
        return 0
    fi

    log_info "Creating new restic repository..."
    if restic init 2>&1 | while IFS= read -r line; do log_debug "restic: $line"; done; then
        log_success "Repository initialized: $repo_path"
    else
        log_error "Failed to initialize repository: $repo_path"
        return 1
    fi
}

# Check repository integrity
# Usage: check_repo /path/to/repo
check_repo() {
    local repo_path="${1:?Usage: check_repo <repo_path>}"

    log_section "Checking Repository Integrity"
    log_info "Repository: $repo_path"

    setup_restic_env "$repo_path"

    # Handle stale locks before checking
    _handle_stale_locks "$repo_path"

    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Would run restic check on: $repo_path"
        return 0
    fi

    local start_time
    start_time=$(date +%s)

    if restic check --read-data-subset=5% 2>&1 | while IFS= read -r line; do log_debug "restic: $line"; done; then
        local end_time duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_success "Repository integrity check passed ($(human_duration "$duration"))"
        return 0
    else
        log_error "Repository integrity check FAILED: $repo_path"
        log_error "Consider running 'restic repair' to fix issues."
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  STALE LOCK HANDLING
# ═══════════════════════════════════════════════════════════════

# Detect and remove stale restic locks
# Restic leaves locks if a previous backup was interrupted.
_handle_stale_locks() {
    local repo_path="$1"

    setup_restic_env "$repo_path"

    # List locks; if any exist and no other restic is running, unlock
    local lock_output
    lock_output=$(restic list locks 2>/dev/null || true)

    if [[ -n "$lock_output" ]]; then
        log_warn "Stale lock(s) detected in repository: $repo_path"

        # Check if another restic process is actually running
        if pgrep -x restic >/dev/null 2>&1; then
            log_warn "Another restic process is running — skipping unlock"
            return 1
        fi

        log_info "Removing stale locks..."
        if restic unlock 2>&1 | while IFS= read -r line; do log_debug "restic: $line"; done; then
            log_success "Stale locks removed"
        else
            log_error "Failed to remove stale locks"
            return 1
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
#  HOME BACKUP
# ═══════════════════════════════════════════════════════════════

# Run a home directory backup with restic
# Tags snapshots with type=home,schedule=daily
# Captures JSON output for stats and records metrics
backup_home() {
    log_section "Home Directory Backup"

    # Resolve config values
    local repo_path
    repo_path=$(config_get "HOME_REPO" "")
    local sources
    sources=$(config_get "HOME_SOURCES" "/home")
    local exclude_file
    exclude_file=$(config_get "HOME_EXCLUDE_FILE" "")
    local hostname
    hostname=$(get_hostname)

    # Validate
    if [[ -z "$repo_path" ]]; then
        die "HOME_REPO is not configured. Set it in linuxguardian.conf."
    fi

    setup_restic_env "$repo_path"

    # Handle stale locks
    _handle_stale_locks "$repo_path" || true

    log_info "Repository : $repo_path"
    log_info "Sources    : $sources"
    log_info "Exclude    : ${exclude_file:-<none>}"
    log_info "Host       : $hostname"

    # Build restic command
    local -a restic_cmd=(restic backup)
    restic_cmd+=(--json)
    restic_cmd+=(--tag "type=home" --tag "schedule=daily")
    restic_cmd+=(--host "$hostname")
    restic_cmd+=(--verbose)

    # Add exclude file if it exists
    if [[ -n "$exclude_file" && -f "$exclude_file" ]]; then
        restic_cmd+=(--exclude-file "$exclude_file")
        log_debug "Using exclude file: $exclude_file"
    elif [[ -n "$exclude_file" ]]; then
        log_warn "Exclude file not found: $exclude_file (continuing without it)"
    fi

    # Append source paths (split on spaces for multiple paths)
    # shellcheck disable=SC2206
    local -a source_paths=($sources)
    restic_cmd+=("${source_paths[@]}")

    # Dry-run mode
    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        restic_cmd+=(--dry-run)
        log_info "[DRY-RUN] Simulating home backup..."
    fi

    # Execute backup
    _run_backup "home" "${restic_cmd[@]}"
}

# ═══════════════════════════════════════════════════════════════
#  SYSTEM BACKUP
# ═══════════════════════════════════════════════════════════════

# Run a full system backup with restic
# Tags snapshots with type=system,schedule=weekly
# Must be run as root
backup_system() {
    log_section "System Backup"

    # System backup requires root
    require_root

    # Resolve config values
    local repo_path
    repo_path=$(config_get "SYSTEM_REPO" "")
    local sources
    sources=$(config_get "SYSTEM_SOURCES" "/")
    local exclude_file
    exclude_file=$(config_get "SYSTEM_EXCLUDE_FILE" "")
    local hostname
    hostname=$(get_hostname)

    # Validate
    if [[ -z "$repo_path" ]]; then
        die "SYSTEM_REPO is not configured. Set it in linuxguardian.conf."
    fi

    setup_restic_env "$repo_path"

    # Handle stale locks
    _handle_stale_locks "$repo_path" || true

    log_info "Repository : $repo_path"
    log_info "Sources    : $sources"
    log_info "Exclude    : ${exclude_file:-<none>}"
    log_info "Host       : $hostname"

    # Build restic command
    local -a restic_cmd=(restic backup)
    restic_cmd+=(--json)
    restic_cmd+=(--tag "type=system" --tag "schedule=weekly")
    restic_cmd+=(--host "$hostname")
    restic_cmd+=(--verbose)
    restic_cmd+=(--one-file-system)  # Don't cross filesystem boundaries

    # Add exclude file if it exists
    if [[ -n "$exclude_file" && -f "$exclude_file" ]]; then
        restic_cmd+=(--exclude-file "$exclude_file")
        log_debug "Using exclude file: $exclude_file"
    elif [[ -n "$exclude_file" ]]; then
        log_warn "Exclude file not found: $exclude_file (continuing without it)"
    fi

    # Append source paths
    # shellcheck disable=SC2206
    local -a source_paths=($sources)
    restic_cmd+=("${source_paths[@]}")

    # Dry-run mode
    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        restic_cmd+=(--dry-run)
        log_info "[DRY-RUN] Simulating system backup..."
    fi

    # Execute backup
    _run_backup "system" "${restic_cmd[@]}"
}

# ═══════════════════════════════════════════════════════════════
#  BACKUP EXECUTION ENGINE (Internal)
# ═══════════════════════════════════════════════════════════════

# Run the actual restic backup, capture JSON stats, record metrics
# Usage: _run_backup <type> <restic_cmd...>
_run_backup() {
    local backup_type="$1"
    shift
    local -a cmd=("$@")

    local start_time start_epoch
    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    start_epoch=$(date +%s)

    log_info "Starting $backup_type backup at $start_time"

    # Capture JSON output into a temp file
    local json_output
    json_output=$(mktemp /tmp/linuxguardian-json-XXXXXX.json)
    # Ensure cleanup
    trap "rm -f '$json_output'" RETURN

    local exit_code=0
    # Execute with lowest IO priority to avoid system lag (Real-time IO Throttling)
    if ionice -c 3 "${cmd[@]}" > "$json_output" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_epoch duration
    end_epoch=$(date +%s)
    duration=$((end_epoch - start_epoch))

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Backup ($backup_type) FAILED after $(human_duration "$duration") (exit code: $exit_code)"
        # Dump output for debugging
        if [[ -s "$json_output" ]]; then
            log_debug "Restic output:"
            while IFS= read -r line; do log_debug "  $line"; done < "$json_output"
        fi
        return "$exit_code"
    fi

    # Parse the JSON summary message from restic output
    # Restic emits one JSON object per line; the summary has message_type=summary
    local files_new=0 files_changed=0 files_unmodified=0
    local data_added=0 total_size=0 total_files=0
    local snapshot_id="unknown"

    if [[ -s "$json_output" ]]; then
        local summary_line
        summary_line=$(grep '"message_type":"summary"' "$json_output" 2>/dev/null || true)

        if [[ -n "$summary_line" ]]; then
            files_new=$(echo "$summary_line" | jq -r '.files_new // 0' 2>/dev/null || echo 0)
            files_changed=$(echo "$summary_line" | jq -r '.files_changed // 0' 2>/dev/null || echo 0)
            files_unmodified=$(echo "$summary_line" | jq -r '.files_unmodified // 0' 2>/dev/null || echo 0)
            data_added=$(echo "$summary_line" | jq -r '.data_added // 0' 2>/dev/null || echo 0)
            total_files=$((files_new + files_changed + files_unmodified))
            total_size=$(echo "$summary_line" | jq -r '.total_bytes_processed // 0' 2>/dev/null || echo 0)
            snapshot_id=$(echo "$summary_line" | jq -r '.snapshot_id // "unknown"' 2>/dev/null || echo "unknown")
        fi
    fi

    # Log results
    log_success "$backup_type backup completed in $(human_duration "$duration")"
    log_info "  Snapshot   : ${snapshot_id:0:12}"
    log_info "  Files      : $files_new new, $files_changed changed, $files_unmodified unmodified"
    log_info "  Data added : $(human_size "$data_added")"
    log_info "  Total size : $(human_size "$total_size")"
    log_info "  Duration   : $(human_duration "$duration")"

    # Record metrics to backup_sizes.log
    # Format: timestamp,type,snapshot_id,files_new,files_changed,files_unmodified,data_added,total_size,duration_sec
    mkdir -p "$(dirname "$BACKUP_SIZES_LOG")"
    record_metric "$BACKUP_SIZES_LOG" \
        "$backup_type,$snapshot_id,$files_new,$files_changed,$files_unmodified,$data_added,$total_size,$duration"

    log_debug "Metrics recorded to: $BACKUP_SIZES_LOG"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  SNAPSHOT MANAGEMENT
# ═══════════════════════════════════════════════════════════════

# Get detailed information about a specific snapshot
# Usage: get_snapshot_info <snapshot_id>
# Output: JSON with files_new, files_changed, files_unmodified, data_added, total_size
get_snapshot_info() {
    local snapshot_id="${1:?Usage: get_snapshot_info <snapshot_id>}"

    # Determine which repo contains this snapshot — try home first, then system
    local repo_path=""
    local home_repo
    home_repo=$(config_get "HOME_REPO" "")
    local system_repo
    system_repo=$(config_get "SYSTEM_REPO" "")

    for candidate_repo in "$home_repo" "$system_repo"; do
        if [[ -z "$candidate_repo" ]]; then
            continue
        fi
        setup_restic_env "$candidate_repo"
        if restic snapshots --json "$snapshot_id" &>/dev/null; then
            repo_path="$candidate_repo"
            break
        fi
    done

    if [[ -z "$repo_path" ]]; then
        log_error "Snapshot not found: $snapshot_id"
        return 1
    fi

    setup_restic_env "$repo_path"
    log_debug "Found snapshot $snapshot_id in repo: $repo_path"

    # Get stats for this snapshot
    local stats_json
    stats_json=$(restic stats "$snapshot_id" --json 2>/dev/null || echo "{}")

    local total_size total_files
    total_size=$(echo "$stats_json" | jq -r '.total_size // 0' 2>/dev/null || echo 0)
    total_files=$(echo "$stats_json" | jq -r '.total_file_count // 0' 2>/dev/null || echo 0)

    # Get snapshot metadata
    local snap_json
    snap_json=$(restic snapshots --json "$snapshot_id" 2>/dev/null || echo "[]")

    local snap_time snap_host snap_tags snap_paths
    snap_time=$(echo "$snap_json" | jq -r '.[0].time // "unknown"' 2>/dev/null || echo "unknown")
    snap_host=$(echo "$snap_json" | jq -r '.[0].hostname // "unknown"' 2>/dev/null || echo "unknown")
    snap_tags=$(echo "$snap_json" | jq -r '.[0].tags // [] | join(",")' 2>/dev/null || echo "")
    snap_paths=$(echo "$snap_json" | jq -r '.[0].paths // [] | join(",")' 2>/dev/null || echo "")

    # Look up backup stats from our metrics log if available
    local files_new=0 files_changed=0 files_unmodified=0 data_added=0
    if [[ -f "$BACKUP_SIZES_LOG" ]]; then
        local log_line
        log_line=$(grep "$snapshot_id" "$BACKUP_SIZES_LOG" 2>/dev/null | tail -1 || true)
        if [[ -n "$log_line" ]]; then
            files_new=$(echo "$log_line" | cut -d',' -f4)
            files_changed=$(echo "$log_line" | cut -d',' -f5)
            files_unmodified=$(echo "$log_line" | cut -d',' -f6)
            data_added=$(echo "$log_line" | cut -d',' -f7)
        fi
    fi

    # Output structured JSON
    jq -n \
        --arg id "$snapshot_id" \
        --arg time "$snap_time" \
        --arg host "$snap_host" \
        --arg tags "$snap_tags" \
        --arg paths "$snap_paths" \
        --argjson files_new "$files_new" \
        --argjson files_changed "$files_changed" \
        --argjson files_unmodified "$files_unmodified" \
        --argjson data_added "$data_added" \
        --argjson total_size "$total_size" \
        --argjson total_files "$total_files" \
        '{
            snapshot_id: $id,
            time: $time,
            hostname: $host,
            tags: $tags,
            paths: $paths,
            files_new: $files_new,
            files_changed: $files_changed,
            files_unmodified: $files_unmodified,
            data_added: $data_added,
            total_size: $total_size,
            total_files: $total_files
        }'
}

# List snapshots filtered by tag type, limited to count
# Usage: list_snapshots [type] [count]
# Example: list_snapshots home 10
list_snapshots() {
    local type="${1:-}"
    local count="${2:-0}"

    # Determine repo from type
    local repo_path=""
    case "$type" in
        home)
            repo_path=$(config_get "HOME_REPO" "")
            ;;
        system)
            repo_path=$(config_get "SYSTEM_REPO" "")
            ;;
        "")
            # If no type, default to home repo
            repo_path=$(config_get "HOME_REPO" "")
            ;;
        *)
            log_error "Unknown snapshot type: $type (expected: home, system)"
            return 1
            ;;
    esac

    if [[ -z "$repo_path" ]]; then
        die "Repository path not configured for type: ${type:-default}"
    fi

    setup_restic_env "$repo_path"

    # Build command
    local -a cmd=(restic snapshots --json)

    # Filter by tag if type specified
    if [[ -n "$type" ]]; then
        cmd+=(--tag "type=$type")
    fi

    # Get snapshots
    local json_output
    json_output=$("${cmd[@]}" 2>/dev/null || echo "[]")

    # Apply count limit (restic doesn't have --limit, so we truncate with jq)
    if [[ "$count" -gt 0 ]]; then
        echo "$json_output" | jq ".[-${count}:]"
    else
        echo "$json_output"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  MODULE SELF-TEST
# ═══════════════════════════════════════════════════════════════

# Quick self-test to verify the module loaded correctly
_backup_engine_loaded() {
    log_debug "Backup engine module v${BACKUP_ENGINE_VERSION} loaded"
}

_backup_engine_loaded
