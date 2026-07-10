#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Cloud Sync Module
#  rclone-based cloud synchronization: sync, verify, usage,
#  provider config, retry logic with exponential backoff.
# ═══════════════════════════════════════════════════════════════

set -o pipefail

if [[ -n "${_SYSBACKUP_CLOUD_SYNC_SH_LOADED:-}" ]]; then return 0; fi
_SYSBACKUP_CLOUD_SYNC_SH_LOADED=1


# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
CLOUD_SYNC_VERSION="1.0.0"
CLOUD_SYNC_MAX_RETRIES=3
CLOUD_SYNC_INITIAL_BACKOFF_SEC=30

# ═══════════════════════════════════════════════════════════════
#  RETRY LOGIC (Exponential Backoff)
# ═══════════════════════════════════════════════════════════════

# Execute a command with exponential backoff retries
# Usage: _retry_with_backoff <max_retries> <initial_backoff_sec> <command...>
# Returns: exit code of the last attempt
_retry_with_backoff() {
    local max_retries="$1"
    local backoff="$2"
    shift 2
    local -a cmd=("$@")

    local attempt=1
    local exit_code=0

    while [[ "$attempt" -le "$max_retries" ]]; do
        log_debug "Attempt $attempt/$max_retries: ${cmd[*]}"

        exit_code=0
        if "${cmd[@]}"; then
            return 0
        else
            exit_code=$?
        fi

        if [[ "$attempt" -lt "$max_retries" ]]; then
            log_warn "Attempt $attempt failed (exit code: $exit_code). Retrying in ${backoff}s..."
            sleep "$backoff"
            # Exponential backoff: double the wait each time
            backoff=$((backoff * 2))
        else
            log_error "All $max_retries attempts failed (last exit code: $exit_code)"
        fi

        ((attempt++))
    done

    return "$exit_code"
}

# ═══════════════════════════════════════════════════════════════
#  RCLONE HELPERS
# ═══════════════════════════════════════════════════════════════

# Build common rclone flags from config
# Returns an array of flags via stdout (one per line)
_build_rclone_flags() {
    local -a flags=()

    # Config file
    local rclone_config
    rclone_config=$(config_get "RCLONE_CONFIG" "")
    if [[ -n "$rclone_config" && -f "$rclone_config" ]]; then
        flags+=(--config "$rclone_config")
    fi

    # Bandwidth limit
    local bw_limit
    bw_limit=$(config_get "RCLONE_BW_LIMIT" "0")
    if [[ "$bw_limit" != "0" && -n "$bw_limit" ]]; then
        flags+=(--bwlimit "$bw_limit")
    fi

    # Number of parallel transfers
    local transfers
    transfers=$(config_get "RCLONE_TRANSFERS" "4")
    flags+=(--transfers "$transfers")

    # Logging / verbosity
    if [[ "${SYSBACKUP_VERBOSE:-false}" == "true" ]]; then
        flags+=(-v)
    fi

    printf '%s\n' "${flags[@]}"
}

# Get the fully-qualified rclone remote destination
# Returns: CLOUD_REMOTE:CLOUD_PATH
_get_cloud_destination() {
    local cloud_remote
    cloud_remote=$(config_get "CLOUD_REMOTE" "")
    local cloud_path
    cloud_path=$(config_get "CLOUD_PATH" "sysbackup")

    if [[ -z "$cloud_remote" ]]; then
        die "CLOUD_REMOTE is not configured. Set it in sysbackup.conf."
    fi

    echo "${cloud_remote}:${cloud_path}"
}

# Check if cloud sync is enabled in config
_cloud_enabled_check() {
    local enabled
    enabled=$(config_get "CLOUD_ENABLED" "false")
    if [[ "$enabled" != "true" ]]; then
        log_warn "Cloud sync is disabled in configuration (CLOUD_ENABLED=$enabled)"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  SYNC TO CLOUD
# ═══════════════════════════════════════════════════════════════

# Sync a local restic repository to cloud storage via rclone
# Usage: sync_to_cloud <repo_path>
# Uses --checksum for data integrity during transfer
sync_to_cloud() {
    local repo_path="${1:?Usage: sync_to_cloud <repo_path>}"
    local subpath="${2:-}"

    log_section "Cloud Sync: Upload"

    _cloud_enabled_check || return 0
    check_dependency "rclone" "rclone" "true" || return 1

    if [[ ! -d "$repo_path" ]]; then
        die "Repository path does not exist: $repo_path"
    fi

    local destination
    destination=$(_get_cloud_destination)
    if [[ -n "$subpath" ]]; then
        destination="${destination}/${subpath}"
    fi

    log_info "Source      : $repo_path"
    log_info "Destination : $destination"

    # Build rclone flags
    local -a rclone_flags=()
    while IFS= read -r flag; do
        rclone_flags+=("$flag")
    done < <(_build_rclone_flags)

    # Build the sync command
    local -a sync_cmd=(
        rclone sync --progress
        "$repo_path"
        "$destination"
        --checksum              # Use checksums instead of timestamps
        --stats 30s             # Print stats every 30 seconds
        --stats-one-line --stats 1s        # Compact stats output
        --log-level INFO
    )
    sync_cmd+=("${rclone_flags[@]}")

    # Add progress logging to file if log file is set
    if [[ -n "${SYSBACKUP_LOG_FILE:-}" ]]; then
        sync_cmd+=(--log-file "${SYSBACKUP_LOG_FILE}")
    fi

    # Dry-run mode
    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        sync_cmd+=(--dry-run)
        log_info "[DRY-RUN] Simulating cloud sync..."
    fi

    local start_epoch
    start_epoch=$(date +%s)

    # Execute with retry logic
    log_info "Starting cloud sync with ${CLOUD_SYNC_MAX_RETRIES} max retries..."
    if _retry_with_backoff "$CLOUD_SYNC_MAX_RETRIES" "$CLOUD_SYNC_INITIAL_BACKOFF_SEC" "${sync_cmd[@]}"; then
        local end_epoch duration
        end_epoch=$(date +%s)
        duration=$((end_epoch - start_epoch))
        log_success "Cloud sync completed in $(human_duration "$duration")"

        # Record sync metric
        local data_dir
        data_dir=$(config_get "DATA_DIR" "/var/lib/sysbackup")
        record_metric "${data_dir}/data/cloud_sync.log" \
            "sync,$repo_path,$destination,$duration,success"
        return 0
    else
        local end_epoch duration
        end_epoch=$(date +%s)
        duration=$((end_epoch - start_epoch))
        log_error "Cloud sync FAILED after $(human_duration "$duration")"

        local data_dir
        data_dir=$(config_get "DATA_DIR" "/var/lib/sysbackup")
        record_metric "${data_dir}/data/cloud_sync.log" \
            "sync,$repo_path,$destination,$duration,failed"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  VERIFY CLOUD SYNC
# ═══════════════════════════════════════════════════════════════

# Verify the integrity of a cloud sync by comparing local/remote checksums
# Usage: verify_cloud_sync <repo_path>
verify_cloud_sync() {
    local repo_path="${1:?Usage: verify_cloud_sync <repo_path>}"

    log_section "Cloud Sync: Verification"

    _cloud_enabled_check || return 0
    check_dependency "rclone" "rclone" "true" || return 1

    if [[ ! -d "$repo_path" ]]; then
        die "Repository path does not exist: $repo_path"
    fi

    local destination
    destination=$(_get_cloud_destination)

    log_info "Verifying: $repo_path ↔ $destination"

    # Build rclone flags
    local -a rclone_flags=()
    while IFS= read -r flag; do
        rclone_flags+=("$flag")
    done < <(_build_rclone_flags)

    # Run rclone check — compares files in source and destination
    local -a check_cmd=(
        rclone check
        "$repo_path"
        "$destination"
        --checksum
        --one-way             # Only check files that exist locally
    )
    check_cmd+=("${rclone_flags[@]}")

    local start_epoch
    start_epoch=$(date +%s)

    local check_output exit_code=0
    check_output=$(mktemp /tmp/sysbackup-rclone-check-XXXXXX.txt)
    trap "rm -f '$check_output'" RETURN

    if "${check_cmd[@]}" > "$check_output" 2>&1; then
        local end_epoch duration
        end_epoch=$(date +%s)
        duration=$((end_epoch - start_epoch))
        log_success "Cloud sync verification PASSED ($(human_duration "$duration"))"

        local data_dir
        data_dir=$(config_get "DATA_DIR" "/var/lib/sysbackup")
        record_metric "${data_dir}/data/cloud_sync.log" \
            "verify,$repo_path,$destination,$duration,pass"
        return 0
    else
        exit_code=$?
        local end_epoch duration
        end_epoch=$(date +%s)
        duration=$((end_epoch - start_epoch))
        log_error "Cloud sync verification FAILED ($(human_duration "$duration"))"

        # Log the differences
        if [[ -s "$check_output" ]]; then
            log_error "Verification differences:"
            while IFS= read -r line; do log_error "  $line"; done < "$check_output"
        fi

        local data_dir
        data_dir=$(config_get "DATA_DIR" "/var/lib/sysbackup")
        record_metric "${data_dir}/data/cloud_sync.log" \
            "verify,$repo_path,$destination,$duration,fail"
        return "$exit_code"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  CLOUD USAGE
# ═══════════════════════════════════════════════════════════════

# Get cloud storage usage information
# Output: JSON with used, total, free bytes
get_cloud_usage() {
    log_section "Cloud Storage Usage"

    _cloud_enabled_check || return 0
    check_dependency "rclone" "rclone" "true" || return 1

    local cloud_remote
    cloud_remote=$(config_get "CLOUD_REMOTE" "")

    if [[ -z "$cloud_remote" ]]; then
        die "CLOUD_REMOTE is not configured."
    fi

    # Build rclone flags
    local -a rclone_flags=()
    while IFS= read -r flag; do
        rclone_flags+=("$flag")
    done < <(_build_rclone_flags)

    log_info "Querying storage usage for remote: $cloud_remote"

    # rclone about returns JSON with --json flag
    local about_json
    about_json=$(rclone about "${cloud_remote}:" --json "${rclone_flags[@]}" 2>/dev/null || echo "{}")

    if [[ -z "$about_json" || "$about_json" == "{}" ]]; then
        log_warn "Could not retrieve cloud storage usage (remote may not support 'about')"
        # Return a default structure
        echo '{"used": 0, "total": 0, "free": 0, "trashed": 0, "available": false}'
        return 0
    fi

    # Extract values
    local used total free trashed
    used=$(echo "$about_json" | jq -r '.used // 0' 2>/dev/null || echo 0)
    total=$(echo "$about_json" | jq -r '.total // 0' 2>/dev/null || echo 0)
    free=$(echo "$about_json" | jq -r '.free // 0' 2>/dev/null || echo 0)
    trashed=$(echo "$about_json" | jq -r '.trashed // 0' 2>/dev/null || echo 0)

    log_info "  Used    : $(human_size "$used")"
    log_info "  Total   : $(human_size "$total")"
    log_info "  Free    : $(human_size "$free")"
    if [[ "$trashed" -gt 0 ]]; then
        log_info "  Trashed : $(human_size "$trashed")"
    fi

    # Calculate usage percentage
    if [[ "$total" -gt 0 ]]; then
        local pct
        pct=$(echo "scale=1; $used * 100 / $total" | bc)
        log_info "  Usage   : ${pct}%"
    fi

    # Output structured JSON
    jq -n \
        --argjson used "$used" \
        --argjson total "$total" \
        --argjson free "$free" \
        --argjson trashed "$trashed" \
        '{
            used: $used,
            total: $total,
            free: $free,
            trashed: $trashed,
            available: true
        }'
}

# ═══════════════════════════════════════════════════════════════
#  CLOUD PROVIDER CONFIGURATION
# ═══════════════════════════════════════════════════════════════

# Helper to interactively configure an rclone remote for a given provider
# Usage: configure_cloud <provider>
# provider: gdrive, onedrive, s3, b2, dropbox, etc.
configure_cloud() {
    local provider="${1:?Usage: configure_cloud <provider>}"

    log_section "Cloud Provider Configuration"
    check_dependency "rclone" "rclone" "true" || return 1

    local cloud_remote
    cloud_remote=$(config_get "CLOUD_REMOTE" "sysbackup-cloud")
    local rclone_config
    rclone_config=$(config_get "RCLONE_CONFIG" "")

    log_info "Provider   : $provider"
    log_info "Remote name: $cloud_remote"

    # Build rclone flags for config
    local -a config_flags=()
    if [[ -n "$rclone_config" ]]; then
        config_flags+=(--config "$rclone_config")
    fi

    # Map common provider names to rclone backend types
    local rclone_type
    case "$provider" in
        gdrive|google-drive|googledrive)
            rclone_type="drive"
            log_info "Backend: Google Drive"
            ;;
        onedrive|microsoft)
            rclone_type="onedrive"
            log_info "Backend: Microsoft OneDrive"
            ;;
        s3|aws|amazon)
            rclone_type="s3"
            log_info "Backend: Amazon S3"
            ;;
        b2|backblaze)
            rclone_type="b2"
            log_info "Backend: Backblaze B2"
            ;;
        dropbox)
            rclone_type="dropbox"
            log_info "Backend: Dropbox"
            ;;
        sftp)
            rclone_type="sftp"
            log_info "Backend: SFTP"
            ;;
        *)
            rclone_type="$provider"
            log_info "Backend: $provider (custom)"
            ;;
    esac

    log_info "Launching interactive rclone configuration..."
    log_info "Follow the prompts to authenticate with $provider."
    echo ""

    # Run rclone config create interactively
    # This will open a browser for OAuth providers
    if rclone config create "$cloud_remote" "$rclone_type" "${config_flags[@]}" 2>&1; then
        log_success "Cloud remote '$cloud_remote' configured for $provider"
        log_info "Test with: rclone lsd ${cloud_remote}:"
        return 0
    else
        log_error "Failed to configure cloud remote"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  MODULE SELF-TEST
# ═══════════════════════════════════════════════════════════════

_cloud_sync_loaded() {
    log_debug "Cloud sync module v${CLOUD_SYNC_VERSION} loaded"
}

_cloud_sync_loaded