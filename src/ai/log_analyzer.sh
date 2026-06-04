#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Log Analyzer AI
#  Multi-pattern scanner and trend detection for backup logs.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

readonly ERROR_TRENDS_FILE="${SYSBACKUP_DATA_DIR:-/var/lib/sysbackup}/data/error_trends.csv"

# ── Multi-pattern log scanner ──────────────────────────────────
analyze_log() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        log_warn "Log file not found: $log_file"
        return 1
    fi
    
    log_info "Analyzing log: $(basename "$log_file")"
    
    # Count errors by category
    local hard_errors
    hard_errors=$(grep -ciE "error|failed|fatal|abort" "$log_file" 2>/dev/null || echo 0)
    
    local soft_errors
    soft_errors=$(grep -ciE "warning|skipped|retry|timeout" "$log_file" 2>/dev/null || echo 0)
    
    local resource_errors
    resource_errors=$(grep -ciE "no space|disk full|out of memory|killed|oom" "$log_file" 2>/dev/null || echo 0)
    
    local perm_errors
    perm_errors=$(grep -ciE "denied|permission|access denied" "$log_file" 2>/dev/null || echo 0)
    
    local net_errors
    net_errors=$(grep -ciE "connection refused|timed out|unreachable|network" "$log_file" 2>/dev/null || echo 0)
    
    local data_errors
    data_errors=$(grep -ciE "corrupt|checksum|truncat|mismatch" "$log_file" 2>/dev/null || echo 0)
    
    local total_critical=$((hard_errors + resource_errors + data_errors))
    local total_warnings=$((soft_errors + perm_errors + net_errors))
    
    if [[ "$total_critical" -gt 0 ]]; then
        log_error "Log Analysis: Found $total_critical critical errors and $total_warnings warnings"
    elif [[ "$total_warnings" -gt 0 ]]; then
        log_warn "Log Analysis: Found $total_warnings warnings (0 critical)"
    else
        log_success "Log Analysis: Clean log, no issues detected"
    fi
    
    # Record to trends file
    record_metric "$ERROR_TRENDS_FILE" "$total_critical,$total_warnings,$resource_errors,$perm_errors,$net_errors,$data_errors"
    
    return "$total_critical"
}

# ── Trend detection ───────────────────────────────────────────
detect_error_trend() {
    if [[ ! -f "$ERROR_TRENDS_FILE" ]]; then
        return 0
    fi
    
    local line_count
    line_count=$(wc -l < "$ERROR_TRENDS_FILE")
    
    if [[ "$line_count" -lt 10 ]]; then
        log_debug "Insufficient data for error trend analysis (need 10, have $line_count)"
        return 0
    fi
    
    # Compare error rate in first vs second half of last 10 runs
    local trend_result
    trend_result=$(tail -n 10 "$ERROR_TRENDS_FILE" | awk -F',' '
    {
        # $2 is total_critical
        errors[NR] = $2
        n = NR
    }
    END {
        if (n < 4) { print "INSUFFICIENT"; exit }
        
        half = int(n/2)
        sum1 = 0; sum2 = 0
        for (i = 1; i <= half; i++) sum1 += errors[i]
        for (i = half+1; i <= n; i++) sum2 += errors[i]
        
        avg1 = sum1 / half
        avg2 = sum2 / (n - half)
        
        if (avg2 > avg1 * 1.5 && avg2 > 1) {
            printf "INCREASING|%.1f|%.1f\n", avg1, avg2
        } else if (avg1 > avg2 * 1.5 && avg1 > 1) {
            printf "DECREASING|%.1f|%.1f\n", avg1, avg2
        } else {
            printf "STABLE|%.1f|%.1f\n", avg1, avg2
        }
    }')
    
    local trend_status
    trend_status=$(echo "$trend_result" | cut -d'|' -f1)
    local avg_old
    avg_old=$(echo "$trend_result" | cut -d'|' -f2)
    local avg_new
    avg_new=$(echo "$trend_result" | cut -d'|' -f3)
    
    if [[ "$trend_status" == "INCREASING" ]]; then
        log_warn "Error Trend: INCREASING (Old avg: $avg_old, New avg: $avg_new per run)"
    fi
    
    echo "$trend_result"
}

# ── Top error sources ─────────────────────────────────────────
get_top_error_sources() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        return 1
    fi
    
    # Extract paths from lines containing error-like keywords
    grep -iE "error|failed|denied|permission" "$log_file" | \
        awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | \
        sort | uniq -c | sort -rn | head -10
}

# ── Comprehensive report ──────────────────────────────────────
get_log_analysis_report() {
    local log_file="${1:-}"
    
    if [[ -z "$log_file" ]]; then
        # Find latest log
        log_file=$(find "${SYSBACKUP_LOG_DIR:-/var/lib/sysbackup/logs}" -name "sysbackup-*.log" -type f -printf "%T@ %p\n" | sort -rn | head -1 | cut -d' ' -f2)
    fi
    
    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        echo "No logs found for analysis."
        return 1
    fi
    
    local report="Log Analysis Report for $(basename "$log_file")\n"
    report+="---------------------------------------------------\n\n"
    
    local hard_errors=$(grep -ciE "error|failed|fatal|abort" "$log_file" 2>/dev/null || echo 0)
    local soft_errors=$(grep -ciE "warning|skipped|retry|timeout" "$log_file" 2>/dev/null || echo 0)
    local resource_errors=$(grep -ciE "no space|disk full|out of memory|killed|oom" "$log_file" 2>/dev/null || echo 0)
    local perm_errors=$(grep -ciE "denied|permission|access denied" "$log_file" 2>/dev/null || echo 0)
    
    report+="Error Summary:\n"
    report+="  Critical Errors:   $hard_errors\n"
    report+="  Soft Warnings:     $soft_errors\n"
    report+="  Resource Issues:   $resource_errors\n"
    report+="  Permission Denied: $perm_errors\n\n"
    
    local top_sources
    top_sources=$(get_top_error_sources "$log_file")
    if [[ -n "$top_sources" ]]; then
        report+="Top Problematic Paths:\n"
        report+="$top_sources\n\n"
    fi
    
    local trend
    trend=$(detect_error_trend 2>/dev/null | cut -d'|' -f1 || echo "UNKNOWN")
    report+="Historical Trend: $trend"
    
    echo -e "$report"
}
