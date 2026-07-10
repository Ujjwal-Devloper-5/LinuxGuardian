#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — AI Anomaly Detection Module
#  Z-score based backup size & file count anomaly detection.
#  Detects: ransomware (sudden size spike), data loss (sudden drop)
# ═══════════════════════════════════════════════════════════════

set -o pipefail

if [[ -n "${_SYSBACKUP_ANOMALY_DETECT_SH_LOADED:-}" ]]; then return 0; fi
_SYSBACKUP_ANOMALY_DETECT_SH_LOADED=1


# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
ANOMALY_MODULE_VERSION="1.0.0"
BACKUP_SIZES_LOG="${DATA_DIR:-/var/lib/sysbackup}/data/backup_sizes.log"
FILE_COUNTS_LOG="${DATA_DIR:-/var/lib/sysbackup}/data/file_counts.log"
ANOMALY_HISTORY_SAMPLES=30

# ── Configurable Thresholds ──────────────────────────────────
# Can be set in sysbackup.conf or environment
ANOMALY_ZSCORE_WARN="${ANOMALY_ZSCORE_WARN:-2.0}"
ANOMALY_ZSCORE_CRITICAL="${ANOMALY_ZSCORE_CRITICAL:-3.0}"

# ═══════════════════════════════════════════════════════════════
#  INTERNAL: AWK-based statistics engine
# ═══════════════════════════════════════════════════════════════

# _compute_zscore <current_value> <data_file> <sample_count>
#   Reads the last N values from data_file (2nd CSV field = value),
#   computes mean, stddev, z-score, and percentage change.
#   Outputs: mean stddev zscore pct_change
_compute_zscore() {
    local current_value="$1"
    local data_file="$2"
    local sample_count="${3:-$ANOMALY_HISTORY_SAMPLES}"

    # Validate inputs
    if [[ -z "$current_value" ]]; then
        log_error "anomaly_detect: current_value is required"
        return 1
    fi

    if [[ ! -f "$data_file" ]]; then
        log_debug "anomaly_detect: Data file not found: $data_file (first run?)"
        echo "0 0 0 0"
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$data_file" 2>/dev/null || echo "0")

    if [[ "$line_count" -lt 3 ]]; then
        log_debug "anomaly_detect: Insufficient data (${line_count} samples, need ≥3)"
        echo "0 0 0 0"
        return 0
    fi

    # Pure awk: read last N values, compute mean, stddev, z-score, pct_change
    tail -n "$sample_count" "$data_file" | awk -F',' -v current="$current_value" '
    BEGIN {
        n = 0
        sum = 0
        sum_sq = 0
        last_val = 0
    }
    {
        # Column 1 = timestamp, Column 2 = value
        val = $8 + 0
        if (val >= 0) {
            values[n] = val
            sum += val
            sum_sq += val * val
            last_val = val
            n++
        }
    }
    END {
        if (n < 2) {
            print "0 0 0 0"
            exit
        }

        mean = sum / n

        # Population standard deviation
        variance = (sum_sq / n) - (mean * mean)
        if (variance < 0) variance = 0
        stddev = sqrt(variance)

        # Z-score (guard against zero stddev)
        if (stddev > 0) {
            zscore = (current - mean) / stddev
        } else {
            zscore = 0
        }

        # Percentage change from the last recorded value
        if (last_val > 0) {
            pct_change = ((current - last_val) / last_val) * 100
        } else if (current > 0) {
            pct_change = 100
        } else {
            pct_change = 0
        }

        printf "%.4f %.4f %.4f %.2f\n", mean, stddev, zscore, pct_change
    }'
}

# _classify_zscore <zscore>
#   Returns: OK, WARNING, or CRITICAL based on absolute z-score
_classify_zscore() {
    local zscore="$1"
    local warn_thresh="$ANOMALY_ZSCORE_WARN"
    local crit_thresh="$ANOMALY_ZSCORE_CRITICAL"

    awk -v z="$zscore" -v warn="$warn_thresh" -v crit="$crit_thresh" '
    BEGIN {
        abs_z = (z < 0) ? -z : z
        if (abs_z >= crit) {
            print "CRITICAL"
        } else if (abs_z >= warn) {
            print "WARNING"
        } else {
            print "OK"
        }
    }'
}

# _direction_analysis <zscore>
#   Returns a human-readable direction hint
_direction_analysis() {
    local zscore="$1"

    awk -v z="$zscore" '
    BEGIN {
        if (z > 0) {
            print "INCREASE"
        } else if (z < 0) {
            print "DECREASE"
        } else {
            print "STABLE"
        }
    }'
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Backup Size Anomaly Detection
# ═══════════════════════════════════════════════════════════════

# check_anomaly <current_size_bytes>
#   Analyze whether the current backup size is anomalous.
#   Outputs a single line:  level zscore mean pct_change
#     level      = OK | WARNING | CRITICAL
#     zscore     = the computed z-score (signed)
#     mean       = historical mean size in bytes
#     pct_change = percentage change from the last backup
check_anomaly() {
    local current_size="${1:?Usage: check_anomaly <current_size_bytes>}"

    log_debug "anomaly_detect: Checking size anomaly (current=${current_size})"

    local stats
    stats=$(_compute_zscore "$current_size" "$BACKUP_SIZES_LOG" "$ANOMALY_HISTORY_SAMPLES")

    local mean stddev zscore pct_change
    read -r mean stddev zscore pct_change <<< "$stats"

    local level
    level=$(_classify_zscore "$zscore")

    local direction
    direction=$(_direction_analysis "$zscore")

    # Log warnings or criticals
    if [[ "$level" == "CRITICAL" ]]; then
        if [[ "$direction" == "INCREASE" ]]; then
            log_error "anomaly_detect: CRITICAL size increase detected (Z=${zscore}) — possible ransomware / corruption!"
        else
            log_error "anomaly_detect: CRITICAL size decrease detected (Z=${zscore}) — possible data loss / misconfiguration!"
        fi
    elif [[ "$level" == "WARNING" ]]; then
        if [[ "$direction" == "INCREASE" ]]; then
            log_warn "anomaly_detect: Unusual size increase detected (Z=${zscore})"
        else
            log_warn "anomaly_detect: Unusual size decrease detected (Z=${zscore})"
        fi
    else
        log_debug "anomaly_detect: Size within normal range (Z=${zscore})"
    fi

    echo "${level}|${zscore}|${mean}|${pct_change}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: File Count Anomaly Detection
# ═══════════════════════════════════════════════════════════════

# check_file_count_anomaly <current_count>
#   Same Z-score analysis applied to file counts.
#   Outputs: level zscore mean pct_change
check_file_count_anomaly() {
    local current_count="${1:?Usage: check_file_count_anomaly <current_count>}"

    log_debug "anomaly_detect: Checking file count anomaly (current=${current_count})"

    local stats
    stats=$(_compute_zscore "$current_count" "$FILE_COUNTS_LOG" "$ANOMALY_HISTORY_SAMPLES")

    local mean stddev zscore pct_change
    read -r mean stddev zscore pct_change <<< "$stats"

    local level
    level=$(_classify_zscore "$zscore")

    local direction
    direction=$(_direction_analysis "$zscore")

    # Log warnings or criticals
    if [[ "$level" == "CRITICAL" ]]; then
        if [[ "$direction" == "INCREASE" ]]; then
            log_error "anomaly_detect: CRITICAL file count increase (Z=${zscore}) — check for file proliferation"
        else
            log_error "anomaly_detect: CRITICAL file count decrease (Z=${zscore}) — possible accidental deletion"
        fi
    elif [[ "$level" == "WARNING" ]]; then
        log_warn "anomaly_detect: Unusual file count change detected (Z=${zscore}, direction=${direction})"
    else
        log_debug "anomaly_detect: File count within normal range (Z=${zscore})"
    fi

    echo "${level}|${zscore}|${mean}|${pct_change}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Record Data Points
# ═══════════════════════════════════════════════════════════════

# record_backup_size <size_bytes>
#   Append a timestamped size entry to the sizes log.
record_backup_size() {
    local size="${1:?Usage: record_backup_size <size_bytes>}"
    record_metric "$BACKUP_SIZES_LOG" "$size"
    log_debug "anomaly_detect: Recorded backup size: ${size} bytes"
}

# record_file_count <count>
#   Append a timestamped file count entry to the counts log.
record_file_count() {
    local count="${1:?Usage: record_file_count <count>}"
    record_metric "$FILE_COUNTS_LOG" "$count"
    log_debug "anomaly_detect: Recorded file count: ${count}"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Human-Readable Anomaly Report
# ═══════════════════════════════════════════════════════════════

# get_anomaly_report
#   Produce a multi-line human-readable summary of the current
#   anomaly state, reading the most recent entry from logs.
get_anomaly_report() {
    log_section "Anomaly Detection Report"

    local has_data=false

    # ── Size Analysis ──
    if [[ -f "$BACKUP_SIZES_LOG" ]] && [[ -s "$BACKUP_SIZES_LOG" ]]; then
        has_data=true
        local latest_size
        latest_size=$(tail -1 "$BACKUP_SIZES_LOG" | awk -F',' '{print $2}')

        if [[ -n "$latest_size" ]] && [[ "$latest_size" -gt 0 ]] 2>/dev/null; then
            local size_result
            size_result=$(check_anomaly "$latest_size")

            local slevel szscore smean spct
            read -r slevel szscore smean spct <<< "$size_result"

            local direction
            direction=$(_direction_analysis "$szscore")

            local size_human mean_human
            size_human=$(human_size "$latest_size")
            mean_human=$(human_size "$(printf '%.0f' "$smean")")

            echo ""
            echo "  📦 Backup Size Analysis"
            echo "  ├─ Current Size  : ${size_human}"
            echo "  ├─ Historical Avg: ${mean_human}"
            echo "  ├─ Z-Score       : ${szscore}"
            echo "  ├─ Change        : ${spct}%"
            echo "  ├─ Direction     : ${direction}"

            case "$slevel" in
                OK)       echo "  └─ Status        : ✅ OK — within normal range" ;;
                WARNING)  echo "  └─ Status        : ⚠️  WARNING — unusual deviation" ;;
                CRITICAL) echo "  └─ Status        : ❌ CRITICAL — investigate immediately" ;;
            esac
        fi
    fi

    # ── File Count Analysis ──
    if [[ -f "$FILE_COUNTS_LOG" ]] && [[ -s "$FILE_COUNTS_LOG" ]]; then
        has_data=true
        local latest_count
        latest_count=$(tail -1 "$FILE_COUNTS_LOG" | awk -F',' '{print $2}')

        if [[ -n "$latest_count" ]] && [[ "$latest_count" -ge 0 ]] 2>/dev/null; then
            local count_result
            count_result=$(check_file_count_anomaly "$latest_count")

            local clevel czscore cmean cpct
            read -r clevel czscore cmean cpct <<< "$count_result"

            local direction
            direction=$(_direction_analysis "$czscore")

            echo ""
            echo "  📂 File Count Analysis"
            echo "  ├─ Current Count : ${latest_count}"
            echo "  ├─ Historical Avg: $(printf '%.0f' "$cmean")"
            echo "  ├─ Z-Score       : ${czscore}"
            echo "  ├─ Change        : ${cpct}%"
            echo "  ├─ Direction     : ${direction}"

            case "$clevel" in
                OK)       echo "  └─ Status        : ✅ OK — within normal range" ;;
                WARNING)  echo "  └─ Status        : ⚠️  WARNING — unusual deviation" ;;
                CRITICAL) echo "  └─ Status        : ❌ CRITICAL — investigate immediately" ;;
            esac
        fi
    fi

    if [[ "$has_data" == false ]]; then
        echo ""
        echo "  📊 No anomaly data available yet."
        echo "     Data will be collected after your first backup run."
    fi

    # ── Thresholds Info ──
    echo ""
    echo "  ⚙️  Thresholds: WARN=±${ANOMALY_ZSCORE_WARN}σ  CRITICAL=±${ANOMALY_ZSCORE_CRITICAL}σ"
    echo "  📈 Sample window: last ${ANOMALY_HISTORY_SAMPLES} backups"
    echo ""

    return 0
}