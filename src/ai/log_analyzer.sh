#!/usr/bin/env bash
# SystemBackup — Log Analyzer AI (Fixed)

set +e
set +u

if [[ -n "${_SYSBACKUP_LOG_ANALYZER_SH_LOADED:-}" ]]; then return 0; fi
_SYSBACKUP_LOG_ANALYZER_SH_LOADED=1

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

ERROR_TRENDS_FILE="${SYSBACKUP_DATA_DIR:-/var/lib/sysbackup}/data/error_trends.csv"

analyze_log() {
    local log_file="${1:-}"
    if [[ ! -f "$log_file" ]]; then return 0; fi

    log_info "Analyzing log: $(basename "$log_file")"

    # Use pure awk to count errors to avoid Bash arithmetic errors entirely
    local counts
    counts=$(grep -iE "error|failed|fatal|abort|warning|skipped|retry|timeout|no space|disk full|out of memory|killed|oom|denied|permission|access denied|connection refused|timed out|unreachable|network|corrupt|checksum|truncat|mismatch" "$log_file" 2>/dev/null | awk "
        BEGIN { h=0; s=0; r=0; p=0; n=0; d=0 }
        /error|failed|fatal|abort/i { h++ }
        /warning|skipped|retry|timeout/i { s++ }
        /no space|disk full|out of memory|killed|oom/i { r++ }
        /denied|permission|access denied/i { p++ }
        /connection refused|timed out|unreachable|network/i { n++ }
        /corrupt|checksum|truncat|mismatch/i { d++ }
        END { print h, s, r, p, n, d }
    ")

    # If grep found nothing, counts will be empty
    if [[ -z "$counts" ]]; then counts="0 0 0 0 0 0"; fi

    read -r h s r p n d <<< "$counts"
    
    local total_crit=$(( h + r + d ))
    local total_warn=$(( s + p + n ))

    if [[ $total_crit -gt 0 ]]; then
        log_error "Log Analysis: Found $total_crit critical errors"
    else
        log_success "Log Analysis: Clean log"
    fi

    record_metric "$ERROR_TRENDS_FILE" "$total_crit,$total_warn,$r,$p,$n,$d"
    return 0
}

detect_error_trend() { return 0; }
get_top_error_sources() { return 0; }
get_log_analysis_report() { return 0; }
