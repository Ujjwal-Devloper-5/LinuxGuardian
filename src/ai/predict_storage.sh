#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — AI Storage Prediction Module
#  Linear regression to predict storage exhaustion.
#  Uses least-squares in awk + optional Python weighted regression.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly PREDICT_MODULE_VERSION="1.0.0"
readonly STORAGE_TREND_LOG="${DATA_DIR:-/var/lib/linuxguardian}/data/storage_trend.log"
readonly CLOUD_TREND_LOG="${DATA_DIR:-/var/lib/linuxguardian}/data/cloud_storage_trend.log"
readonly HELPERS_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}/helpers"
readonly STORAGE_PREDICTOR_PY="${HELPERS_DIR}/storage_predictor.py"

# ── Configurable Thresholds (days until full) ─────────────────
STORAGE_WARN_DAYS="${STORAGE_WARN_DAYS:-60}"
STORAGE_ALERT_DAYS="${STORAGE_ALERT_DAYS:-30}"
STORAGE_CRITICAL_DAYS="${STORAGE_CRITICAL_DAYS:-7}"

# ═══════════════════════════════════════════════════════════════
#  INTERNAL: Pure-awk Least-Squares Linear Regression
# ═══════════════════════════════════════════════════════════════

# _awk_linear_regression <data_file> <total_capacity_bytes>
#   Reads CSV: timestamp,used_bytes,total_bytes
#   Returns: slope_bytes_per_day days_until_full current_usage_pct
_awk_linear_regression() {
    local data_file="$1"
    local total_capacity="${2:-0}"

    if [[ ! -f "$data_file" ]] || [[ ! -s "$data_file" ]]; then
        log_debug "predict_storage: No data file or empty: $data_file"
        echo "0 -1 0"
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$data_file")

    if [[ "$line_count" -lt 2 ]]; then
        log_debug "predict_storage: Insufficient data points (${line_count}, need ≥2)"
        echo "0 -1 0"
        return 0
    fi

    awk -F',' -v total_cap="$total_capacity" '
    BEGIN {
        n = 0
        sum_x = 0; sum_y = 0; sum_xy = 0; sum_xx = 0
        first_ts = 0; last_used = 0; last_total = 0
    }
    {
        ts = $1 + 0
        used = $2 + 0
        cap = $3 + 0

        if (ts <= 0 || used < 0) next

        if (n == 0) first_ts = ts
        last_used = used
        if (cap > 0) last_total = cap

        # Normalize timestamp to days from first observation
        x = (ts - first_ts) / 86400.0
        y = used

        sum_x += x
        sum_y += y
        sum_xy += x * y
        sum_xx += x * x
        n++
    }
    END {
        if (n < 2) {
            print "0 -1 0"
            exit
        }

        # Effective capacity: prefer passed-in, else from data
        capacity = (total_cap > 0) ? total_cap : last_total
        if (capacity <= 0) {
            # Cannot compute days_until_full without capacity
            print "0 -1 0"
            exit
        }

        # Least-squares slope (bytes per day)
        denom = (n * sum_xx) - (sum_x * sum_x)
        if (denom == 0) {
            slope = 0
        } else {
            slope = ((n * sum_xy) - (sum_x * sum_y)) / denom
        }

        # Current usage percentage
        usage_pct = (last_used / capacity) * 100.0

        # Days until full
        remaining = capacity - last_used
        if (slope > 0 && remaining > 0) {
            days_until_full = remaining / slope
        } else if (slope <= 0) {
            days_until_full = -1  # Not growing or shrinking
        } else {
            days_until_full = 0   # Already full
        }

        printf "%.4f %.1f %.2f\n", slope, days_until_full, usage_pct
    }' "$data_file"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Predict Storage Usage
# ═══════════════════════════════════════════════════════════════

# predict_storage_usage [total_capacity_bytes]
#   Run linear regression on storage trend data.
#   Outputs: growth_rate_per_day days_until_full current_usage_pct
#   If a Python helper is available, uses weighted regression instead.
predict_storage_usage() {
    local total_capacity="${1:-0}"

    log_debug "predict_storage: Running storage prediction"

    # Try the Python weighted-regression helper first (more accurate)
    if [[ -f "$STORAGE_PREDICTOR_PY" ]] && command -v python3 &>/dev/null; then
        log_debug "predict_storage: Using Python weighted regression"
        local py_result
        if py_result=$(python3 "$STORAGE_PREDICTOR_PY" "$STORAGE_TREND_LOG" "$total_capacity" 2>/dev/null); then
            # Python outputs JSON; extract the key values
            local slope days_full usage_pct
            slope=$(echo "$py_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['slope_bytes_per_day'])" 2>/dev/null || echo "")
            days_full=$(echo "$py_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['days_until_full'])" 2>/dev/null || echo "")
            usage_pct=$(echo "$py_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current_usage_pct'])" 2>/dev/null || echo "")

            if [[ -n "$slope" && -n "$days_full" && -n "$usage_pct" ]]; then
                echo "${slope} ${days_full} ${usage_pct}"
                return 0
            fi
        fi
        log_warn "predict_storage: Python helper failed, falling back to awk"
    fi

    # Fallback: pure awk least-squares
    _awk_linear_regression "$STORAGE_TREND_LOG" "$total_capacity"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Record Storage Usage
# ═══════════════════════════════════════════════════════════════

# record_storage_usage <repo_path>
#   Record current storage usage of a repo path to the trend log.
#   Format: timestamp,used_bytes,total_bytes
record_storage_usage() {
    local repo_path="${1:?Usage: record_storage_usage <repo_path>}"

    if [[ ! -d "$repo_path" ]]; then
        log_warn "predict_storage: Repository path not a directory: $repo_path"
        return 1
    fi

    local mount_point
    mount_point=$(df --output=target "$repo_path" 2>/dev/null | tail -1)

    if [[ -z "$mount_point" ]]; then
        log_error "predict_storage: Cannot determine mount point for: $repo_path"
        return 1
    fi

    # Get filesystem stats
    local fs_info
    fs_info=$(df -B1 --output=used,size "$repo_path" 2>/dev/null | tail -1)

    local used_bytes total_bytes
    read -r used_bytes total_bytes <<< "$fs_info"

    if [[ -z "$used_bytes" || -z "$total_bytes" ]]; then
        log_error "predict_storage: Cannot read filesystem stats for: $repo_path"
        return 1
    fi

    mkdir -p "$(dirname "$STORAGE_TREND_LOG")"
    local ts
    ts=$(date +%s)
    echo "${ts},${used_bytes},${total_bytes}" >> "$STORAGE_TREND_LOG"

    log_debug "predict_storage: Recorded usage — used=$(human_size "$used_bytes"), total=$(human_size "$total_bytes")"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Cloud Storage Prediction
# ═══════════════════════════════════════════════════════════════

# predict_cloud_storage [rclone_remote]
#   Use rclone about to get cloud storage stats and predict exhaustion.
#   Outputs: growth_rate_per_day days_until_full current_usage_pct
predict_cloud_storage() {
    local remote="${1:-}"

    if [[ -z "$remote" ]]; then
        remote=$(config_get "RCLONE_REMOTE" "")
        if [[ -z "$remote" ]]; then
            log_warn "predict_storage: No rclone remote configured"
            echo "0 -1 0"
            return 0
        fi
    fi

    if ! command -v rclone &>/dev/null; then
        log_error "predict_storage: rclone not installed"
        return 1
    fi

    # Get cloud storage info via rclone
    local rclone_json
    if ! rclone_json=$(rclone about "$remote" --json 2>/dev/null); then
        log_error "predict_storage: rclone about failed for remote: $remote"
        return 1
    fi

    local used_bytes total_bytes
    used_bytes=$(echo "$rclone_json" | jq -r '.used // 0' 2>/dev/null || echo "0")
    total_bytes=$(echo "$rclone_json" | jq -r '.total // 0' 2>/dev/null || echo "0")

    if [[ "$total_bytes" -le 0 ]]; then
        log_warn "predict_storage: Cloud remote reports no total capacity (unlimited plan?)"
        echo "0 -1 0"
        return 0
    fi

    # Record to cloud trend log
    local ts
    ts=$(date +%s)
    mkdir -p "$(dirname "$CLOUD_TREND_LOG")"
    echo "${ts},${used_bytes},${total_bytes}" >> "$CLOUD_TREND_LOG"

    # Run regression on cloud data
    _awk_linear_regression "$CLOUD_TREND_LOG" "$total_bytes"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Prediction Report
# ═══════════════════════════════════════════════════════════════

# get_prediction_report [total_capacity_bytes]
#   Generate a human-readable storage prediction report.
get_prediction_report() {
    local total_capacity="${1:-0}"

    log_section "Storage Prediction Report"

    if [[ ! -f "$STORAGE_TREND_LOG" ]] || [[ ! -s "$STORAGE_TREND_LOG" ]]; then
        echo ""
        echo "  📊 No storage trend data available yet."
        echo "     Data will be collected after your first backup run."
        echo ""
        return 0
    fi

    local result
    result=$(predict_storage_usage "$total_capacity")

    local growth_rate days_until_full usage_pct
    read -r growth_rate days_until_full usage_pct <<< "$result"

    # Convert growth rate to human-readable
    local growth_abs
    growth_abs=$(echo "$growth_rate" | awk '{v=$1; if(v<0) v=-v; print v}')
    local growth_human
    growth_human=$(human_size "$(printf '%.0f' "$growth_abs")")

    local growth_direction="📈"
    if (( $(echo "$growth_rate < 0" | bc -l) )); then
        growth_direction="📉"
    fi

    echo ""
    echo "  💾 Local Storage Prediction"
    echo "  ├─ Current Usage : $(printf '%.1f' "$usage_pct")%"
    echo "  ├─ Growth Rate   : ${growth_direction} ${growth_human}/day"

    if (( $(echo "$days_until_full > 0" | bc -l) )); then
        local days_int
        days_int=$(printf '%.0f' "$days_until_full")

        echo "  ├─ Days Until Full: ${days_int} days"

        # Alert level based on days remaining
        if [[ "$days_int" -le "$STORAGE_CRITICAL_DAYS" ]]; then
            echo "  └─ Status        : 🔴 CRITICAL — Storage full within ${days_int} days!"
        elif [[ "$days_int" -le "$STORAGE_ALERT_DAYS" ]]; then
            echo "  └─ Status        : 🟠 ALERT — Storage full within ${days_int} days"
        elif [[ "$days_int" -le "$STORAGE_WARN_DAYS" ]]; then
            echo "  └─ Status        : 🟡 WARNING — Monitor storage growth"
        else
            echo "  └─ Status        : 🟢 OK — Sufficient storage for ${days_int} days"
        fi

        # Timeline projection
        echo ""
        echo "  📅 Projected Timeline"
        if [[ "$days_int" -ge 7 ]]; then
            echo "  ├─  7 days: $(printf '%.1f' "$(echo "$usage_pct + ($growth_rate * 7 / ${total_capacity:-1}) * 100" | bc -l 2>/dev/null || echo "$usage_pct")")% used"
        fi
        if [[ "$days_int" -ge 30 ]]; then
            echo "  ├─ 30 days: $(printf '%.1f' "$(echo "$usage_pct + ($growth_rate * 30 / ${total_capacity:-1}) * 100" | bc -l 2>/dev/null || echo "$usage_pct")")% used"
        fi
        if [[ "$days_int" -ge 60 ]]; then
            echo "  └─ 60 days: $(printf '%.1f' "$(echo "$usage_pct + ($growth_rate * 60 / ${total_capacity:-1}) * 100" | bc -l 2>/dev/null || echo "$usage_pct")")% used"
        fi
    elif (( $(echo "$days_until_full == 0" | bc -l) )); then
        echo "  ├─ Days Until Full: 0"
        echo "  └─ Status        : 🔴 CRITICAL — Storage is FULL!"
    else
        echo "  ├─ Days Until Full: ∞ (not growing)"
        echo "  └─ Status        : 🟢 OK — Storage usage is stable or decreasing"
    fi

    # Cloud storage section (if data exists)
    if [[ -f "$CLOUD_TREND_LOG" ]] && [[ -s "$CLOUD_TREND_LOG" ]]; then
        local cloud_total
        cloud_total=$(tail -1 "$CLOUD_TREND_LOG" | awk -F',' '{print $3}')
        local cloud_result
        cloud_result=$(_awk_linear_regression "$CLOUD_TREND_LOG" "$cloud_total")
        local cgrowth cdays cusage
        read -r cgrowth cdays cusage <<< "$cloud_result"

        echo ""
        echo "  ☁️  Cloud Storage Prediction"
        echo "  ├─ Current Usage : $(printf '%.1f' "$cusage")%"
        local cgrowth_human
        cgrowth_human=$(human_size "$(printf '%.0f' "$(echo "$cgrowth" | awk '{v=$1; if(v<0) v=-v; print v}')")")
        echo "  ├─ Growth Rate   : ${cgrowth_human}/day"
        if (( $(echo "$cdays > 0" | bc -l) )); then
            echo "  └─ Days Until Full: $(printf '%.0f' "$cdays") days"
        else
            echo "  └─ Days Until Full: ∞ (stable)"
        fi
    fi

    echo ""
    echo "  ⚙️  Alert Thresholds: CRITICAL≤${STORAGE_CRITICAL_DAYS}d  ALERT≤${STORAGE_ALERT_DAYS}d  WARN≤${STORAGE_WARN_DAYS}d"
    echo ""

    return 0
}
