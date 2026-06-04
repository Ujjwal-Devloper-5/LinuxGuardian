#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Integrity Verification Module
#  3-tier rotating checksum verification system.
#  Tier 1: Every backup  — repo structure check
#  Tier 2: Weekly rotation — read-data subset (1/7 per day)
#  Tier 3: Monthly        — full read-data + test restore
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly INTEGRITY_MODULE_VERSION="1.0.0"
readonly VERIFICATION_HISTORY="${DATA_DIR:-/var/lib/linuxguardian}/data/verification_history.log"
readonly VERIFICATION_RESTORE_DIR="${DATA_DIR:-/var/lib/linuxguardian}/cache/verify_restore"

# ── Configurable Parameters ──────────────────────────────────
VERIFY_TIER2_DAY_OF_WEEK="${VERIFY_TIER2_DAY_OF_WEEK:-}"  # Empty = auto (use current day)
VERIFY_TIER3_DAY_OF_MONTH="${VERIFY_TIER3_DAY_OF_MONTH:-1}"
VERIFY_RESTORE_MAX_SIZE="${VERIFY_RESTORE_MAX_SIZE:-104857600}"  # 100 MB max for test restore
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-3600}"  # 1 hour timeout per tier

# ═══════════════════════════════════════════════════════════════
#  INTERNAL: Result Recording
# ═══════════════════════════════════════════════════════════════

# _record_verification <tier> <repo_path> <status> <duration_secs> <details>
#   Append a verification result to history log.
#   Format: timestamp,tier,repo,status,duration,details
_record_verification() {
    local tier="$1"
    local repo_path="$2"
    local status="$3"
    local duration="$4"
    local details="${5:-}"

    mkdir -p "$(dirname "$VERIFICATION_HISTORY")"

    # Sanitize details (remove commas and newlines)
    details=$(echo "$details" | tr ',\n' '; ' | head -c 200)

    record_metric "$VERIFICATION_HISTORY" "${tier},${repo_path},${status},${duration},${details}"
    log_debug "integrity: Recorded tier ${tier} result: ${status} (${duration}s)"
}

# _determine_tier
#   Auto-determine which verification tier to run based on date.
_determine_tier() {
    local day_of_month day_of_week

    day_of_month=$(date +%-d)
    day_of_week=$(date +%u)  # 1=Monday, 7=Sunday

    # Tier 3: monthly (specific day of month)
    if [[ "$day_of_month" -eq "$VERIFY_TIER3_DAY_OF_MONTH" ]]; then
        echo "3"
        return
    fi

    # Tier 2: weekly (any day except tier 3 day)
    # We always run tier 2 with the appropriate subset
    if [[ "$day_of_week" -le 7 ]]; then
        echo "2"
        return
    fi

    # Tier 1: default
    echo "1"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Tier 1 — Basic Repository Structure Check
# ═══════════════════════════════════════════════════════════════

# verify_tier1 <repo_path>
#   Fast check: validates repository structure and index consistency.
#   This should run with every backup (< 1 minute typically).
verify_tier1() {
    local repo_path="${1:?Usage: verify_tier1 <repo_path>}"

    log_info "integrity: Tier 1 verification — repository structure check"
    log_info "integrity: Repository: ${repo_path}"

    local start_time
    start_time=$(date +%s)

    # Set up restic environment
    setup_restic_env "$repo_path"

    local status="PASS"
    local details=""
    local check_output

    if check_output=$(timeout "$VERIFY_TIMEOUT" restic check 2>&1); then
        log_success "integrity: Tier 1 PASSED — repository structure is consistent"
        details="Structure OK; $(echo "$check_output" | tail -1)"
    else
        local exit_code=$?
        status="FAIL"
        details="restic check failed (exit=${exit_code}); $(echo "$check_output" | tail -3 | tr '\n' '; ')"

        if [[ "$exit_code" -eq 124 ]]; then
            log_error "integrity: Tier 1 TIMEOUT after ${VERIFY_TIMEOUT}s"
            details="Timed out after ${VERIFY_TIMEOUT}s"
        else
            log_error "integrity: Tier 1 FAILED — repository may be corrupted"
            log_error "integrity: Output: $(echo "$check_output" | tail -3)"
        fi
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    _record_verification "1" "$repo_path" "$status" "$duration" "$details"

    log_info "integrity: Tier 1 completed in $(human_duration "$duration")"

    [[ "$status" == "PASS" ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Tier 2 — Weekly Rotating Data Subset Check
# ═══════════════════════════════════════════════════════════════

# verify_tier2 <repo_path>
#   Medium check: reads 1/7 of the data (rotating daily).
#   Over a full week, all data is verified.
verify_tier2() {
    local repo_path="${1:?Usage: verify_tier2 <repo_path>}"

    # Determine which subset to check (1-7 based on day of week)
    local subset_n
    if [[ -n "$VERIFY_TIER2_DAY_OF_WEEK" ]]; then
        subset_n="$VERIFY_TIER2_DAY_OF_WEEK"
    else
        subset_n=$(date +%u)  # 1=Monday through 7=Sunday
    fi

    log_info "integrity: Tier 2 verification — data subset ${subset_n}/7"
    log_info "integrity: Repository: ${repo_path}"

    local start_time
    start_time=$(date +%s)

    setup_restic_env "$repo_path"

    local status="PASS"
    local details=""
    local check_output

    if check_output=$(timeout "$VERIFY_TIMEOUT" restic check --read-data-subset="${subset_n}/7" 2>&1); then
        log_success "integrity: Tier 2 PASSED — data subset ${subset_n}/7 verified"
        details="Subset ${subset_n}/7 OK; $(echo "$check_output" | tail -1)"
    else
        local exit_code=$?
        status="FAIL"
        details="Subset ${subset_n}/7 failed (exit=${exit_code}); $(echo "$check_output" | tail -3 | tr '\n' '; ')"

        if [[ "$exit_code" -eq 124 ]]; then
            log_error "integrity: Tier 2 TIMEOUT after ${VERIFY_TIMEOUT}s"
            details="Subset ${subset_n}/7 timed out after ${VERIFY_TIMEOUT}s"
        else
            log_error "integrity: Tier 2 FAILED — data corruption detected in subset ${subset_n}/7"
            log_error "integrity: Output: $(echo "$check_output" | tail -3)"
        fi
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    _record_verification "2" "$repo_path" "$status" "$duration" "$details"

    log_info "integrity: Tier 2 completed in $(human_duration "$duration")"

    [[ "$status" == "PASS" ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Tier 3 — Monthly Full Verification + Test Restore
# ═══════════════════════════════════════════════════════════════

# verify_tier3 <repo_path>
#   Full check: reads ALL data + test-restores a random snapshot.
#   This is the most thorough but slowest check.
verify_tier3() {
    local repo_path="${1:?Usage: verify_tier3 <repo_path>}"

    log_info "integrity: Tier 3 verification — full data read + test restore"
    log_info "integrity: Repository: ${repo_path}"

    local start_time
    start_time=$(date +%s)

    setup_restic_env "$repo_path"

    local status="PASS"
    local details=""

    # ── Phase 1: Full data read ──
    log_info "integrity: Phase 1/2 — Full data integrity check"
    local check_output

    if check_output=$(timeout "$VERIFY_TIMEOUT" restic check --read-data 2>&1); then
        log_success "integrity: Phase 1 PASSED — all data verified"
        details="Full read OK"
    else
        local exit_code=$?
        status="FAIL"
        details="Full read failed (exit=${exit_code}); $(echo "$check_output" | tail -3 | tr '\n' '; ')"

        if [[ "$exit_code" -eq 124 ]]; then
            log_error "integrity: Phase 1 TIMEOUT after ${VERIFY_TIMEOUT}s"
        else
            log_error "integrity: Phase 1 FAILED — data corruption detected"
        fi
    fi

    # ── Phase 2: Test restore of random snapshot (only if phase 1 passed) ──
    if [[ "$status" == "PASS" ]]; then
        log_info "integrity: Phase 2/2 — Test restore of random snapshot"

        local snapshots_json
        if snapshots_json=$(restic snapshots --json 2>/dev/null); then
            local snapshot_count
            snapshot_count=$(echo "$snapshots_json" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$snapshot_count" -gt 0 ]]; then
                # Pick a random snapshot
                local random_index
                random_index=$(( RANDOM % snapshot_count ))
                local snapshot_id
                snapshot_id=$(echo "$snapshots_json" | jq -r ".[$random_index].short_id // .[$random_index].id" 2>/dev/null)

                if [[ -n "$snapshot_id" && "$snapshot_id" != "null" ]]; then
                    log_info "integrity: Test-restoring snapshot ${snapshot_id}"

                    # Create temporary restore directory
                    local restore_dir="${VERIFICATION_RESTORE_DIR}/${snapshot_id}_$(date +%s)"
                    mkdir -p "$restore_dir"

                    local restore_output
                    if restore_output=$(timeout "$VERIFY_TIMEOUT" restic restore "$snapshot_id" \
                        --target "$restore_dir" \
                        --exclude-larger-than "$(( VERIFY_RESTORE_MAX_SIZE ))b" \
                        2>&1); then
                        log_success "integrity: Test restore PASSED"
                        details="${details}; restore of ${snapshot_id} OK"

                        # Verify restored files aren't empty / have content
                        local restored_files
                        restored_files=$(find "$restore_dir" -type f 2>/dev/null | wc -l)
                        log_info "integrity: Restored ${restored_files} files for verification"

                        if [[ "$restored_files" -eq 0 ]]; then
                            log_warn "integrity: Test restore produced no files (may be expected for size-limited restore)"
                        fi
                    else
                        local exit_code=$?
                        status="FAIL"
                        details="${details}; restore of ${snapshot_id} failed (exit=${exit_code})"
                        log_error "integrity: Test restore FAILED for snapshot ${snapshot_id}"
                    fi

                    # Clean up test restore
                    rm -rf "$restore_dir" 2>/dev/null || true
                else
                    log_warn "integrity: Could not extract snapshot ID for test restore"
                    details="${details}; snapshot selection failed"
                fi
            else
                log_warn "integrity: No snapshots found for test restore"
                details="${details}; no snapshots available"
            fi
        else
            log_warn "integrity: Cannot list snapshots for test restore"
            details="${details}; snapshot listing failed"
        fi
    fi

    # Clean up parent restore dir if empty
    rmdir "$VERIFICATION_RESTORE_DIR" 2>/dev/null || true

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    _record_verification "3" "$repo_path" "$status" "$duration" "$details"

    log_info "integrity: Tier 3 completed in $(human_duration "$duration")"

    [[ "$status" == "PASS" ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Auto-Select Verification Tier
# ═══════════════════════════════════════════════════════════════

# run_verification <repo_path>
#   Automatically select and run the appropriate verification tier
#   based on the current date.
run_verification() {
    local repo_path="${1:?Usage: run_verification <repo_path>}"

    local tier
    tier=$(_determine_tier)

    log_info "integrity: Auto-selected tier ${tier} for today ($(date +%A, %B\ %d))"

    case "$tier" in
        1) verify_tier1 "$repo_path" ;;
        2) verify_tier2 "$repo_path" ;;
        3) verify_tier3 "$repo_path" ;;
        *)
            log_error "integrity: Unknown tier: $tier"
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Verification Report
# ═══════════════════════════════════════════════════════════════

# get_verification_report
#   Summarize recent verification results.
get_verification_report() {
    log_section "Integrity Verification Report"

    if [[ ! -f "$VERIFICATION_HISTORY" ]] || [[ ! -s "$VERIFICATION_HISTORY" ]]; then
        echo ""
        echo "  🔍 No verification history available yet."
        echo "     Run 'linuxguardian verify' to perform a check."
        echo ""
        return 0
    fi

    echo ""

    # Overall statistics
    local total_checks pass_count fail_count
    total_checks=$(wc -l < "$VERIFICATION_HISTORY")
    pass_count=$(grep -c ',PASS,' "$VERIFICATION_HISTORY" 2>/dev/null || echo "0")
    fail_count=$(grep -c ',FAIL,' "$VERIFICATION_HISTORY" 2>/dev/null || echo "0")

    local pass_rate="0"
    if [[ "$total_checks" -gt 0 ]]; then
        pass_rate=$(echo "scale=1; ($pass_count * 100) / $total_checks" | bc -l)
    fi

    echo "  📊 Overall Statistics"
    echo "  ├─ Total Checks  : ${total_checks}"
    echo "  ├─ Passed        : ${pass_count}"
    echo "  ├─ Failed        : ${fail_count}"
    echo "  └─ Pass Rate     : ${pass_rate}%"

    # Per-tier breakdown
    echo ""
    echo "  🏗️  Per-Tier Summary"

    for tier in 1 2 3; do
        local tier_label
        case "$tier" in
            1) tier_label="Structure Check" ;;
            2) tier_label="Data Subset Read" ;;
            3) tier_label="Full Read + Restore" ;;
        esac

        local tier_total tier_pass
        tier_total=$(grep -c ",${tier}," "$VERIFICATION_HISTORY" 2>/dev/null || echo "0")
        tier_pass=$(grep ",${tier}," "$VERIFICATION_HISTORY" | grep -c ',PASS,' 2>/dev/null || echo "0")

        local last_result="N/A"
        local last_line
        last_line=$(grep ",${tier}," "$VERIFICATION_HISTORY" | tail -1 2>/dev/null || echo "")

        if [[ -n "$last_line" ]]; then
            local last_ts last_status last_duration
            last_ts=$(echo "$last_line" | awk -F',' '{print $1}')
            last_status=$(echo "$last_line" | awk -F',' '{print $4}')
            last_duration=$(echo "$last_line" | awk -F',' '{print $5}')

            local last_date
            last_date=$(format_timestamp "$last_ts")

            if [[ "$last_status" == "PASS" ]]; then
                last_result="✅ PASS ($(human_duration "$last_duration"), ${last_date})"
            else
                last_result="❌ FAIL ($(human_duration "$last_duration"), ${last_date})"
            fi
        fi

        local tree_char="├"
        [[ "$tier" -eq 3 ]] && tree_char="└"

        echo "  ${tree_char}─ Tier ${tier} (${tier_label})"
        echo "  │   Runs: ${tier_total} | Passed: ${tier_pass} | Last: ${last_result}"
    done

    # Recent failures (last 5)
    local recent_fails
    recent_fails=$(grep ',FAIL,' "$VERIFICATION_HISTORY" 2>/dev/null | tail -5 || echo "")

    if [[ -n "$recent_fails" ]]; then
        echo ""
        echo "  ⚠️  Recent Failures"
        echo "$recent_fails" | while IFS=',' read -r ts tier repo status duration details _rest; do
            local fail_date
            fail_date=$(format_timestamp "$ts")
            echo "  ├─ [${fail_date}] Tier ${tier}: ${details:-unknown error}"
        done
    fi

    echo ""

    # Next scheduled checks
    local today_tier
    today_tier=$(_determine_tier)
    echo "  📅 Today's Tier: ${today_tier}"
    echo "  ⚙️  Tier 3 scheduled for day ${VERIFY_TIER3_DAY_OF_MONTH} of each month"
    echo ""

    return 0
}
