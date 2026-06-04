#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Retention & Pruning Module
#  GFS (Grandfather-Father-Son) snapshot retention management.
#  Handles restic forget/prune, snapshot listing, space savings
#  calculation, and retention policy display.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly RETENTION_VERSION="1.0.0"

# ═══════════════════════════════════════════════════════════════
#  RETENTION POLICY
# ═══════════════════════════════════════════════════════════════

# Return the current GFS retention policy as a formatted string
# Reads: KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY, KEEP_YEARLY from config
get_retention_policy() {
    local keep_daily keep_weekly keep_monthly keep_yearly
    keep_daily=$(config_get "KEEP_DAILY" "7")
    keep_weekly=$(config_get "KEEP_WEEKLY" "4")
    keep_monthly=$(config_get "KEEP_MONTHLY" "12")
    keep_yearly=$(config_get "KEEP_YEARLY" "3")

    cat <<EOF
GFS Retention Policy:
  ├── Daily   : Keep last ${keep_daily} daily snapshots
  ├── Weekly  : Keep last ${keep_weekly} weekly snapshots
  ├── Monthly : Keep last ${keep_monthly} monthly snapshots
  └── Yearly  : Keep last ${keep_yearly} yearly snapshots
EOF
}

# ═══════════════════════════════════════════════════════════════
#  SNAPSHOT PRUNING
# ═══════════════════════════════════════════════════════════════

# Prune snapshots using the GFS retention policy
# Usage: prune_snapshots <repo_path> [type]
# type: home, system (used to filter by tag)
prune_snapshots() {
    local repo_path="${1:?Usage: prune_snapshots <repo_path> [type]}"
    local type="${2:-}"

    log_section "Snapshot Pruning"

    setup_restic_env "$repo_path"

    # Read retention policy from config
    local keep_daily keep_weekly keep_monthly keep_yearly
    keep_daily=$(config_get "KEEP_DAILY" "7")
    keep_weekly=$(config_get "KEEP_WEEKLY" "4")
    keep_monthly=$(config_get "KEEP_MONTHLY" "12")
    keep_yearly=$(config_get "KEEP_YEARLY" "3")

    log_info "Repository : $repo_path"
    log_info "Type filter: ${type:-<all>}"
    log_info "Policy     : daily=$keep_daily, weekly=$keep_weekly, monthly=$keep_monthly, yearly=$keep_yearly"

    # Get snapshot count before pruning
    local count_before
    count_before=$(_count_snapshots "$repo_path" "$type")
    log_info "Snapshots before: $count_before"

    # Get repo size before pruning (for space savings)
    local size_before
    size_before=$(_get_repo_size "$repo_path")

    # Build the restic forget command
    local -a forget_cmd=(
        restic forget
        --keep-daily "$keep_daily"
        --keep-weekly "$keep_weekly"
        --keep-monthly "$keep_monthly"
        --keep-yearly "$keep_yearly"
        --prune              # Actually reclaim space after forgetting
        --json               # JSON output for parsing
    )

    # Filter by type tag if specified
    if [[ -n "$type" ]]; then
        forget_cmd+=(--tag "type=$type")
    fi

    # Dry-run support
    if [[ "${SYSBACKUP_DRY_RUN:-false}" == "true" ]]; then
        forget_cmd+=(--dry-run)
        log_info "[DRY-RUN] Simulating prune operation..."
    fi

    local start_epoch
    start_epoch=$(date +%s)

    # Execute pruning
    local prune_output exit_code=0
    prune_output=$(mktemp /tmp/linuxguardian-prune-XXXXXX.json)
    trap "rm -f '$prune_output'" RETURN

    if "${forget_cmd[@]}" > "$prune_output" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_epoch duration
    end_epoch=$(date +%s)
    duration=$((end_epoch - start_epoch))

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Pruning FAILED (exit code: $exit_code, duration: $(human_duration "$duration"))"
        if [[ -s "$prune_output" ]]; then
            while IFS= read -r line; do log_debug "restic: $line"; done < "$prune_output"
        fi
        return "$exit_code"
    fi

    # Get snapshot count after pruning
    local count_after
    count_after=$(_count_snapshots "$repo_path" "$type")

    # Get repo size after pruning
    local size_after
    size_after=$(_get_repo_size "$repo_path")

    local removed=$((count_before - count_after))
    local space_saved=0
    if [[ "$size_before" -gt 0 && "$size_after" -gt 0 ]]; then
        space_saved=$((size_before - size_after))
        [[ "$space_saved" -lt 0 ]] && space_saved=0
    fi

    log_success "Pruning completed in $(human_duration "$duration")"
    log_info "  Snapshots removed : $removed"
    log_info "  Snapshots kept    : $count_after"
    if [[ "$space_saved" -gt 0 ]]; then
        log_info "  Space reclaimed   : $(human_size "$space_saved")"
    fi

    # Record metrics
    local data_dir
    data_dir=$(config_get "DATA_DIR" "/var/lib/linuxguardian")
    record_metric "${data_dir}/data/retention.log" \
        "${type:-all},$count_before,$count_after,$removed,$size_before,$size_after,$space_saved,$duration"

    return 0
}

# ═══════════════════════════════════════════════════════════════
#  SNAPSHOT LISTING
# ═══════════════════════════════════════════════════════════════

# List all snapshots with full metadata
# Usage: list_all_snapshots <repo_path>
# Output: JSON array with id, time, paths, tags, hostname
list_all_snapshots() {
    local repo_path="${1:?Usage: list_all_snapshots <repo_path>}"

    log_debug "Listing all snapshots in: $repo_path"
    setup_restic_env "$repo_path"

    # Get snapshots as JSON
    local snapshots_json
    snapshots_json=$(restic snapshots --json 2>/dev/null || echo "[]")

    # Get stats for each snapshot (if --json is available)
    # For performance, get overall repo stats rather than per-snapshot
    local repo_stats
    repo_stats=$(restic stats --json 2>/dev/null || echo '{"total_size": 0}')
    local repo_total_size
    repo_total_size=$(echo "$repo_stats" | jq -r '.total_size // 0' 2>/dev/null || echo 0)

    # Enrich snapshot data with computed fields
    echo "$snapshots_json" | jq --argjson repo_size "$repo_total_size" '
        [.[] | {
            id: .short_id,
            full_id: .id,
            time: .time,
            hostname: .hostname,
            tags: (.tags // []),
            paths: (.paths // []),
            username: (.username // "unknown"),
            repo_total_size: $repo_size
        }]
    ' 2>/dev/null || echo "$snapshots_json"
}

# Get the total count of snapshots in a repository
# Usage: get_snapshot_count <repo_path>
get_snapshot_count() {
    local repo_path="${1:?Usage: get_snapshot_count <repo_path>}"

    setup_restic_env "$repo_path"

    local count
    count=$(restic snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    echo "$count"
}

# ═══════════════════════════════════════════════════════════════
#  SPACE SAVINGS CALCULATION
# ═══════════════════════════════════════════════════════════════

# Report potential space savings from a prune operation
# Usage: calculate_space_savings <repo_path>
# Runs a dry-run prune and reports what would be saved
calculate_space_savings() {
    local repo_path="${1:?Usage: calculate_space_savings <repo_path>}"

    log_section "Space Savings Estimate"

    setup_restic_env "$repo_path"

    # Read retention policy
    local keep_daily keep_weekly keep_monthly keep_yearly
    keep_daily=$(config_get "KEEP_DAILY" "7")
    keep_weekly=$(config_get "KEEP_WEEKLY" "4")
    keep_monthly=$(config_get "KEEP_MONTHLY" "12")
    keep_yearly=$(config_get "KEEP_YEARLY" "3")

    # Get current repo stats
    local current_size
    current_size=$(_get_repo_size "$repo_path")
    local snapshot_count
    snapshot_count=$(get_snapshot_count "$repo_path")

    log_info "Repository       : $repo_path"
    log_info "Current size     : $(human_size "$current_size")"
    log_info "Total snapshots  : $snapshot_count"

    # Run a dry-run forget to see what would be removed
    local dry_run_output
    dry_run_output=$(restic forget \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" \
        --keep-yearly "$keep_yearly" \
        --dry-run \
        --json 2>/dev/null || echo "[]")

    # Count snapshots that would be removed
    local would_remove=0
    local would_keep=0
    if [[ -n "$dry_run_output" && "$dry_run_output" != "[]" ]]; then
        would_remove=$(echo "$dry_run_output" | jq '[.[].remove // [] | length] | add // 0' 2>/dev/null || echo 0)
        would_keep=$(echo "$dry_run_output" | jq '[.[].keep // [] | length] | add // 0' 2>/dev/null || echo 0)
    fi

    log_info "Would remove     : $would_remove snapshots"
    log_info "Would keep       : $would_keep snapshots"

    # Estimate space savings (rough approximation)
    # Actual savings depend on deduplication — we can't know precisely without pruning
    if [[ "$snapshot_count" -gt 0 && "$would_remove" -gt 0 ]]; then
        # Very rough estimate: assume savings proportional to removed/total ratio
        # This is intentionally conservative since restic uses deduplication
        local estimated_pct
        estimated_pct=$(echo "scale=1; $would_remove * 100 / $snapshot_count" | bc 2>/dev/null || echo 0)
        log_info "Estimated savings: ~${estimated_pct}% of repo size"
        log_info "  (Actual savings depend on data deduplication)"
    else
        log_info "No snapshots eligible for removal under current policy"
    fi

    # Output structured JSON
    jq -n \
        --argjson current_size "$current_size" \
        --argjson snapshot_count "$snapshot_count" \
        --argjson would_remove "$would_remove" \
        --argjson would_keep "$would_keep" \
        '{
            current_size: $current_size,
            snapshot_count: $snapshot_count,
            would_remove: $would_remove,
            would_keep: $would_keep
        }'
}

# ═══════════════════════════════════════════════════════════════
#  INTERNAL HELPERS
# ═══════════════════════════════════════════════════════════════

# Count snapshots, optionally filtered by type tag
_count_snapshots() {
    local repo_path="$1"
    local type="${2:-}"

    setup_restic_env "$repo_path"

    local -a cmd=(restic snapshots --json)
    if [[ -n "$type" ]]; then
        cmd+=(--tag "type=$type")
    fi

    "${cmd[@]}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0
}

# Get total repository size in bytes
_get_repo_size() {
    local repo_path="$1"

    setup_restic_env "$repo_path"

    # Use restic stats for accurate repo size
    local stats_json
    stats_json=$(restic stats --mode raw-data --json 2>/dev/null || echo '{"total_size": 0}')

    echo "$stats_json" | jq -r '.total_size // 0' 2>/dev/null || echo 0
}

# ═══════════════════════════════════════════════════════════════
#  MODULE SELF-TEST
# ═══════════════════════════════════════════════════════════════

_retention_loaded() {
    log_debug "Retention module v${RETENTION_VERSION} loaded"
}

_retention_loaded
