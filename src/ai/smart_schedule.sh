#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — AI Smart Scheduling Module
#  Finds optimal backup windows by analyzing system idle patterns.
#  Uses EWMA smoothing + Python helper for time-series analysis.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly SCHEDULE_MODULE_VERSION="1.0.0"
readonly CPU_STATS_FILE="${DATA_DIR:-/var/lib/sysbackup}/data/cpu_stats.csv"
readonly IO_STATS_FILE="${DATA_DIR:-/var/lib/sysbackup}/data/io_stats.csv"
readonly SCHEDULE_DATA_FILE="${DATA_DIR:-/var/lib/sysbackup}/data/schedule_history.csv"
readonly HELPERS_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/helpers"
readonly SCHEDULE_ANALYZER_PY="${HELPERS_DIR}/schedule_analyzer.py"

# ── Configurable Parameters ──────────────────────────────────
SCHEDULE_EWMA_ALPHA="${SCHEDULE_EWMA_ALPHA:-0.2}"
SCHEDULE_IDLE_THRESHOLD="${SCHEDULE_IDLE_THRESHOLD:-80}"
SCHEDULE_MIN_SAMPLES="${SCHEDULE_MIN_SAMPLES:-24}"
SCHEDULE_LOAD_MAX="${SCHEDULE_LOAD_MAX:-2.0}"
SCHEDULE_IO_MAX="${SCHEDULE_IO_MAX:-80}"

# ═══════════════════════════════════════════════════════════════
#  INTERNAL: System Metrics Collection
# ═══════════════════════════════════════════════════════════════

# _get_cpu_idle
#   Returns the current CPU idle percentage (0-100).
_get_cpu_idle() {
    # Method 1: /proc/stat based (instantaneous, 1-second sample)
    if [[ -r /proc/stat ]]; then
        awk '/^cpu / {
            idle = $5
            total = $2 + $3 + $4 + $5 + $6 + $7 + $8
            if (total > 0) printf "%.1f", (idle / total) * 100
            else print "0"
        }' /proc/stat
        return 0
    fi

    # Method 2: top (fallback)
    if command -v top &>/dev/null; then
        top -bn1 2>/dev/null | awk '/Cpu\(s\)/ || /%Cpu/ {
            for(i=1; i<=NF; i++) {
                if ($(i+1) ~ /id/) { gsub(/,/, "", $i); printf "%.1f", $i; exit }
            }
        }'
        return 0
    fi

    echo "0"
}

# _get_load_average
#   Returns the 1-minute load average.
_get_load_average() {
    if [[ -r /proc/loadavg ]]; then
        awk '{print $1}' /proc/loadavg
    else
        uptime | awk -F'load average:' '{print $2}' | awk -F',' '{gsub(/ /, "", $1); print $1}'
    fi
}

# _get_io_utilization
#   Returns a rough I/O utilization percentage.
_get_io_utilization() {
    if command -v iostat &>/dev/null; then
        iostat -d -x 1 2 2>/dev/null | awk '
            /^[a-z]/ && NR > 3 {
                if ($NF + 0 > max) max = $NF + 0
            }
            END { printf "%.1f", max + 0 }
        '
        return 0
    fi

    # Fallback: estimate from /proc/diskstats
    if [[ -r /proc/diskstats ]]; then
        awk '{
            if ($3 ~ /^sd[a-z]$|^nvme[0-9]+n[0-9]+$|^vd[a-z]$/) {
                io_ms += $13
                count++
            }
        }
        END {
            if (count > 0) printf "%.1f", (io_ms / count / 10)
            else print "0"
        }' /proc/diskstats
        return 0
    fi

    echo "0"
}

# _get_memory_available_pct
#   Returns available memory as a percentage of total.
_get_memory_available_pct() {
    if [[ -r /proc/meminfo ]]; then
        awk '
            /^MemTotal:/ { total = $2 }
            /^MemAvailable:/ { available = $2 }
            END {
                if (total > 0) printf "%.1f", (available / total) * 100
                else print "0"
            }
        ' /proc/meminfo
        return 0
    fi
    echo "0"
}

# ═══════════════════════════════════════════════════════════════
#  INTERNAL: EWMA Smoothing
# ═══════════════════════════════════════════════════════════════

# _ewma_smooth <data_file> <column_index> <alpha>
#   Apply Exponentially Weighted Moving Average on a CSV column.
#   Returns the latest smoothed value.
_ewma_smooth() {
    local data_file="$1"
    local col="${2:-2}"
    local alpha="${3:-$SCHEDULE_EWMA_ALPHA}"

    if [[ ! -f "$data_file" ]] || [[ ! -s "$data_file" ]]; then
        echo "0"
        return 0
    fi

    tail -n 100 "$data_file" | awk -F',' -v col="$col" -v alpha="$alpha" '
    BEGIN { ewma = -1 }
    {
        val = $col + 0
        if (ewma < 0) {
            ewma = val
        } else {
            ewma = alpha * val + (1 - alpha) * ewma
        }
    }
    END {
        if (ewma < 0) print "0"
        else printf "%.2f", ewma
    }'
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Update Schedule Data
# ═══════════════════════════════════════════════════════════════

# update_schedule_data
#   Called periodically (e.g., by a monitor service) to record
#   current system metrics for later analysis.
update_schedule_data() {
    local ts hour cpu_idle load_avg io_util mem_avail

    ts=$(date +%s)
    hour=$(date +%H)
    cpu_idle=$(_get_cpu_idle)
    load_avg=$(_get_load_average)
    io_util=$(_get_io_utilization)
    mem_avail=$(_get_memory_available_pct)

    mkdir -p "$(dirname "$CPU_STATS_FILE")"

    # Write header if file doesn't exist
    if [[ ! -f "$CPU_STATS_FILE" ]]; then
        echo "timestamp,hour,cpu_idle,load_avg,io_util,mem_avail" > "$CPU_STATS_FILE"
    fi

    echo "${ts},${hour},${cpu_idle},${load_avg},${io_util},${mem_avail}" >> "$CPU_STATS_FILE"

    log_debug "smart_schedule: Recorded metrics — idle=${cpu_idle}%, load=${load_avg}, io=${io_util}%, mem=${mem_avail}%"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Find Optimal Backup Window
# ═══════════════════════════════════════════════════════════════

# find_optimal_window
#   Analyze historical CPU data to find the top 3 most idle hours.
#   Output: JSON with optimal_hours, confidence, recommendation
find_optimal_window() {
    log_debug "smart_schedule: Finding optimal backup window"

    if [[ ! -f "$CPU_STATS_FILE" ]] || [[ ! -s "$CPU_STATS_FILE" ]]; then
        log_warn "smart_schedule: No CPU stats data available"
        echo '{"optimal_hours": [2, 3, 4], "confidence": 0.0, "recommendation": "No data yet — using default late-night window"}'
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$CPU_STATS_FILE")

    if [[ "$line_count" -lt "$SCHEDULE_MIN_SAMPLES" ]]; then
        log_warn "smart_schedule: Insufficient data (${line_count}/${SCHEDULE_MIN_SAMPLES} samples)"
        echo '{"optimal_hours": [2, 3, 4], "confidence": 0.0, "recommendation": "Insufficient data — using default late-night window"}'
        return 0
    fi

    # Try Python helper first (more sophisticated analysis)
    if [[ -f "$SCHEDULE_ANALYZER_PY" ]] && command -v python3 &>/dev/null; then
        log_debug "smart_schedule: Using Python analyzer"
        local py_result
        if py_result=$(python3 "$SCHEDULE_ANALYZER_PY" --find-window "$CPU_STATS_FILE" 2>/dev/null); then
            if echo "$py_result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
                echo "$py_result"
                return 0
            fi
        fi
        log_warn "smart_schedule: Python helper failed, falling back to awk"
    fi

    # Fallback: pure awk analysis — group by hour, find top 3 idle hours
    awk -F',' '
    NR == 1 { next }  # Skip header
    {
        hour = $2 + 0
        idle = $3 + 0
        load = $4 + 0

        sum_idle[hour] += idle
        sum_load[hour] += load
        count[hour]++
    }
    END {
        # Calculate average idle for each hour
        best_count = 0
        for (h = 0; h < 24; h++) {
            if (count[h] > 0) {
                avg_idle[h] = sum_idle[h] / count[h]
                avg_load[h] = sum_load[h] / count[h]
                best_count++
            } else {
                avg_idle[h] = -1
            }
        }

        # Find top 3 hours by idle percentage
        top1 = -1; top2 = -1; top3 = -1
        max1 = -1; max2 = -1; max3 = -1

        for (h = 0; h < 24; h++) {
            if (avg_idle[h] < 0) continue
            if (avg_idle[h] > max1) {
                max3 = max2; top3 = top2
                max2 = max1; top2 = top1
                max1 = avg_idle[h]; top1 = h
            } else if (avg_idle[h] > max2) {
                max3 = max2; top3 = top2
                max2 = avg_idle[h]; top2 = h
            } else if (avg_idle[h] > max3) {
                max3 = avg_idle[h]; top3 = h
            }
        }

        # Confidence based on data coverage (how many hours have data)
        confidence = best_count / 24.0
        if (confidence > 1) confidence = 1

        # Build recommendation string
        if (top1 >= 0) {
            rec = sprintf("Best time: %02d:00 (%.0f%% idle)", top1, max1)
        } else {
            rec = "No data available"
        }

        # Output JSON
        printf "{\"optimal_hours\": ["
        if (top1 >= 0) printf "%d", top1
        if (top2 >= 0) printf ", %d", top2
        if (top3 >= 0) printf ", %d", top3
        printf "], \"confidence\": %.2f, \"recommendation\": \"%s\"}\n", confidence, rec
    }' "$CPU_STATS_FILE"
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Should Backup Now?
# ═══════════════════════════════════════════════════════════════

# should_backup_now
#   Quick check: is the system currently favorable for a backup?
#   Returns 0 (yes) or 1 (no), with JSON reasoning on stdout.
should_backup_now() {
    local cpu_idle load_avg io_util mem_avail
    cpu_idle=$(_get_cpu_idle)
    load_avg=$(_get_load_average)
    io_util=$(_get_io_utilization)
    mem_avail=$(_get_memory_available_pct)

    # Apply EWMA smoothing to CPU idle if we have history
    local smoothed_idle="$cpu_idle"
    if [[ -f "$CPU_STATS_FILE" ]] && [[ -s "$CPU_STATS_FILE" ]]; then
        smoothed_idle=$(_ewma_smooth "$CPU_STATS_FILE" 3 "$SCHEDULE_EWMA_ALPHA")
    fi

    local idle_threshold="$SCHEDULE_IDLE_THRESHOLD"
    local load_max="$SCHEDULE_LOAD_MAX"
    local io_max="$SCHEDULE_IO_MAX"

    # Decision logic
    local favorable=true
    local reasons=""

    # Check CPU idle (using real-time, not smoothed, for immediate decision)
    if (( $(echo "$cpu_idle < $idle_threshold" | bc -l 2>/dev/null || echo "0") )); then
        favorable=false
        reasons="${reasons}CPU busy (${cpu_idle}% idle, threshold ${idle_threshold}%); "
    fi

    # Check load average
    if (( $(echo "$load_avg > $load_max" | bc -l 2>/dev/null || echo "0") )); then
        favorable=false
        reasons="${reasons}High load (${load_avg}, max ${load_max}); "
    fi

    # Check I/O
    if (( $(echo "$io_util > $io_max" | bc -l 2>/dev/null || echo "0") )); then
        favorable=false
        reasons="${reasons}High I/O (${io_util}%, max ${io_max}%); "
    fi

    # Check memory
    if (( $(echo "$mem_avail < 10" | bc -l 2>/dev/null || echo "0") )); then
        favorable=false
        reasons="${reasons}Low memory (${mem_avail}% available); "
    fi

    # Also try Python helper for sustained-idle check
    if [[ "$favorable" == true ]] && [[ -f "$SCHEDULE_ANALYZER_PY" ]] && command -v python3 &>/dev/null; then
        local py_check
        if py_check=$(python3 "$SCHEDULE_ANALYZER_PY" --should-backup "$CPU_STATS_FILE" 2>/dev/null); then
            local py_favorable
            py_favorable=$(echo "$py_check" | python3 -c "import sys,json; print(json.load(sys.stdin).get('favorable', True))" 2>/dev/null || echo "True")
            if [[ "$py_favorable" == "False" ]]; then
                favorable=false
                reasons="${reasons}Python analyzer recommends waiting; "
            fi
        fi
    fi

    # Output decision as JSON
    local decision="true"
    [[ "$favorable" == false ]] && decision="false"

    # Clean trailing separator from reasons
    reasons="${reasons%; }"
    [[ -z "$reasons" ]] && reasons="All metrics within acceptable range"

    printf '{"favorable": %s, "cpu_idle": %.1f, "smoothed_idle": %.1f, "load_avg": %.2f, "io_util": %.1f, "mem_avail": %.1f, "reason": "%s"}\n' \
        "$decision" "$cpu_idle" "$smoothed_idle" "$load_avg" "$io_util" "$mem_avail" "$reasons"

    if [[ "$favorable" == true ]]; then
        log_debug "smart_schedule: System is favorable for backup"
        return 0
    else
        log_debug "smart_schedule: System NOT favorable — ${reasons}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  PUBLIC API: Schedule Recommendation
# ═══════════════════════════════════════════════════════════════

# get_schedule_recommendation
#   Generate a human-readable scheduling recommendation
#   including a systemd OnCalendar= value.
get_schedule_recommendation() {
    log_section "Smart Schedule Recommendation"

    local window_json
    window_json=$(find_optimal_window)

    # Parse the JSON
    local optimal_hours confidence recommendation
    if command -v python3 &>/dev/null; then
        optimal_hours=$(echo "$window_json" | python3 -c "import sys,json; print(' '.join(map(str, json.load(sys.stdin)['optimal_hours'])))" 2>/dev/null || echo "2 3 4")
        confidence=$(echo "$window_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['confidence'])" 2>/dev/null || echo "0")
        recommendation=$(echo "$window_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['recommendation'])" 2>/dev/null || echo "")
    elif command -v jq &>/dev/null; then
        optimal_hours=$(echo "$window_json" | jq -r '.optimal_hours | join(" ")' 2>/dev/null || echo "2 3 4")
        confidence=$(echo "$window_json" | jq -r '.confidence' 2>/dev/null || echo "0")
        recommendation=$(echo "$window_json" | jq -r '.recommendation' 2>/dev/null || echo "")
    else
        optimal_hours="2 3 4"
        confidence="0"
        recommendation="Cannot parse results (install jq or python3)"
    fi

    local primary_hour
    primary_hour=$(echo "$optimal_hours" | awk '{print $1}')

    echo ""
    echo "  🕐 Optimal Backup Windows"
    echo "  ├─ Analysis     : ${recommendation}"
    echo "  ├─ Confidence   : $(printf '%.0f' "$(echo "$confidence * 100" | bc -l 2>/dev/null || echo "0")")%"
    echo "  │"

    local rank=1
    for hour in $optimal_hours; do
        local padded
        padded=$(printf '%02d' "$hour")
        local icon="│"
        [[ "$rank" -eq 3 ]] && icon="└"
        echo "  ${icon}─ #${rank} Window    : ${padded}:00 - ${padded}:59"
        ((rank++))
    done

    echo ""
    echo "  ⚙️  Recommended systemd timer OnCalendar:"
    echo "     OnCalendar=*-*-* ${primary_hour}:00:00"
    echo ""

    # Current system state
    echo "  📊 Current System State"
    local cpu_idle load_avg mem_avail
    cpu_idle=$(_get_cpu_idle)
    load_avg=$(_get_load_average)
    mem_avail=$(_get_memory_available_pct)

    echo "  ├─ CPU Idle      : ${cpu_idle}%"
    echo "  ├─ Load Average  : ${load_avg}"
    echo "  └─ Memory Avail  : ${mem_avail}%"
    echo ""

    return 0
}
