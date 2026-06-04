#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Idle Detection Module
#  Smart system idle detection combining CPU usage, user input
#  idle time, and load average. Supports exponential backup
#  deferral when the system is busy.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly IDLE_DETECT_VERSION="1.0.0"
readonly CPU_SAMPLE_INTERVAL_SEC=2   # Sampling window for CPU idle measurement

# ── Defer tracking file ──────────────────────────────────────
# Stores the number of times backup has been deferred in the current cycle
readonly DEFER_STATE_FILE="${SYSBACKUP_DATA_DIR:-/var/lib/sysbackup}/data/.defer_state"

# ═══════════════════════════════════════════════════════════════
#  CPU IDLE PERCENTAGE
# ═══════════════════════════════════════════════════════════════

# Get CPU idle percentage by sampling /proc/stat over a 2-second window
# Returns: integer 0-100 representing idle %
get_cpu_idle_pct() {
    if [[ ! -f /proc/stat ]]; then
        log_warn "Cannot read /proc/stat — returning 0% idle"
        echo 0
        return 0
    fi

    # First sample: parse the "cpu " line from /proc/stat
    # Fields: user nice system idle iowait irq softirq steal guest guest_nice
    local line1 line2
    line1=$(grep '^cpu ' /proc/stat)

    local user1 nice1 system1 idle1 iowait1
    read -r _ user1 nice1 system1 idle1 iowait1 _ <<< "$line1"

    # Wait for the sampling interval
    sleep "$CPU_SAMPLE_INTERVAL_SEC"

    # Second sample
    line2=$(grep '^cpu ' /proc/stat)

    local user2 nice2 system2 idle2 iowait2
    read -r _ user2 nice2 system2 idle2 iowait2 _ <<< "$line2"

    # Calculate deltas
    local total_delta idle_delta
    local total1=$((user1 + nice1 + system1 + idle1 + iowait1))
    local total2=$((user2 + nice2 + system2 + idle2 + iowait2))
    total_delta=$((total2 - total1))
    idle_delta=$((idle2 - idle1))

    # Avoid division by zero
    if [[ "$total_delta" -eq 0 ]]; then
        echo 100
        return 0
    fi

    # Calculate idle percentage (integer math)
    local idle_pct
    idle_pct=$((idle_delta * 100 / total_delta))
    echo "$idle_pct"
}

# ═══════════════════════════════════════════════════════════════
#  USER IDLE TIME
# ═══════════════════════════════════════════════════════════════

# Get user idle time in milliseconds
# Primary: xprintidle (measures time since last keyboard/mouse input)
# Fallback: returns -1 if xprintidle is unavailable (caller should treat as idle)
get_user_idle_ms() {
    # Try xprintidle first (works on X11)
    if check_command xprintidle; then
        local idle_ms
        idle_ms=$(xprintidle 2>/dev/null || echo "-1")
        echo "$idle_ms"
        return 0
    fi

    # On Wayland, xprintidle may not work; try via D-Bus (GNOME/KDE)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        # GNOME: org.gnome.Mutter.IdleMonitor
        if check_command gdbus; then
            local idle_ms
            idle_ms=$(gdbus call --session \
                --dest org.gnome.Mutter.IdleMonitor \
                --object-path /org/gnome/Mutter/IdleMonitor/Core \
                --method org.gnome.Mutter.IdleMonitor.GetIdletime \
                2>/dev/null | tr -dc '0-9' || echo "-1")
            if [[ "$idle_ms" != "-1" && -n "$idle_ms" ]]; then
                echo "$idle_ms"
                return 0
            fi
        fi
    fi

    # No idle detection available — return -1 to indicate unavailable
    log_debug "User idle detection unavailable (no xprintidle or Wayland method)"
    echo "-1"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  LOAD AVERAGE
# ═══════════════════════════════════════════════════════════════

# Get 1-minute load average from /proc/loadavg
# Returns: float (e.g., "1.23")
get_load_average() {
    if [[ -f /proc/loadavg ]]; then
        awk '{print $1}' /proc/loadavg
    else
        # Fallback to uptime parsing
        uptime | awk -F'load average:' '{print $2}' | awk -F',' '{gsub(/ /, "", $1); print $1}'
    fi
}

# ═══════════════════════════════════════════════════════════════
#  COMBINED IDLE CHECK
# ═══════════════════════════════════════════════════════════════

# Check if the system is idle based on multiple signals
# Returns: 0 if system is idle, 1 if busy
#
# Logic:
#   idle when ALL of:
#     1. CPU_IDLE > CPU_IDLE_THRESHOLD (default 80%)
#     2. xprintidle > IDLE_THRESHOLD_MS (default 600000ms = 10min) OR xprintidle unavailable
#     3. Load average < 1.5
is_system_idle() {
    local cpu_threshold
    cpu_threshold=$(config_get "CPU_IDLE_THRESHOLD" "80")
    local idle_threshold_ms
    idle_threshold_ms=$(config_get "IDLE_THRESHOLD_MS" "600000")
    local load_threshold="1.5"

    log_debug "Idle check: CPU threshold=${cpu_threshold}%, idle threshold=${idle_threshold_ms}ms, load threshold=${load_threshold}"

    # ── Check 1: CPU idle ──────────────────────────────────
    local cpu_idle
    cpu_idle=$(get_cpu_idle_pct)
    log_debug "CPU idle: ${cpu_idle}% (threshold: ${cpu_threshold}%)"

    if [[ "$cpu_idle" -lt "$cpu_threshold" ]]; then
        log_debug "System BUSY: CPU idle ${cpu_idle}% < ${cpu_threshold}%"
        return 1
    fi

    # ── Check 2: User idle (keyboard/mouse) ────────────────
    local user_idle_ms
    user_idle_ms=$(get_user_idle_ms)
    log_debug "User idle: ${user_idle_ms}ms (threshold: ${idle_threshold_ms}ms)"

    # -1 means xprintidle unavailable — treat as idle (headless server, etc.)
    if [[ "$user_idle_ms" -ne -1 && "$user_idle_ms" -lt "$idle_threshold_ms" ]]; then
        log_debug "System BUSY: User idle ${user_idle_ms}ms < ${idle_threshold_ms}ms"
        return 1
    fi

    # ── Check 3: Load average ──────────────────────────────
    local load_avg
    load_avg=$(get_load_average)
    log_debug "Load average: ${load_avg} (threshold: ${load_threshold})"

    # Use bc for float comparison
    if (( $(echo "$load_avg >= $load_threshold" | bc -l 2>/dev/null || echo 0) )); then
        log_debug "System BUSY: Load ${load_avg} >= ${load_threshold}"
        return 1
    fi

    log_debug "System is IDLE (CPU: ${cpu_idle}%, user: ${user_idle_ms}ms, load: ${load_avg})"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  BACKUP DEFERRAL LOGIC
# ═══════════════════════════════════════════════════════════════

# Check if backup should be deferred because the system is busy
# Uses exponential backoff: check at 15min, 30min, 1h, 2h intervals
# After MAX_DEFER_HOURS, force backup regardless of system state
#
# Returns: 0 if backup should proceed, 1 if should be deferred
should_defer_backup() {
    local max_defer_hours
    max_defer_hours=$(config_get "MAX_DEFER_HOURS" "6")

    # Read defer state (count of previous deferrals this cycle)
    local defer_count=0
    local first_defer_epoch=0

    if [[ -f "$DEFER_STATE_FILE" ]]; then
        defer_count=$(head -1 "$DEFER_STATE_FILE" 2>/dev/null || echo 0)
        first_defer_epoch=$(tail -1 "$DEFER_STATE_FILE" 2>/dev/null || echo 0)
    fi

    # Check if we've exceeded MAX_DEFER_HOURS
    if [[ "$first_defer_epoch" -gt 0 ]]; then
        local now elapsed_hours
        now=$(date +%s)
        elapsed_hours=$(( (now - first_defer_epoch) / 3600 ))

        if [[ "$elapsed_hours" -ge "$max_defer_hours" ]]; then
            log_warn "Backup deferred for ${elapsed_hours}h (max: ${max_defer_hours}h) — forcing backup now"
            _clear_defer_state
            return 0  # Proceed with backup
        fi
    fi

    # Check if system is idle
    if is_system_idle; then
        log_info "System is idle — backup can proceed"
        _clear_defer_state
        return 0  # Proceed with backup
    fi

    # System is busy — defer with exponential backoff
    # Schedule: 15min, 30min, 1h, 2h, 2h, 2h, ...
    local -a defer_intervals=(900 1800 3600 7200)  # seconds
    local interval_idx=$defer_count
    if [[ "$interval_idx" -ge "${#defer_intervals[@]}" ]]; then
        interval_idx=$(( ${#defer_intervals[@]} - 1 ))  # Cap at max interval
    fi
    local next_check_sec="${defer_intervals[$interval_idx]}"
    local next_check_min=$((next_check_sec / 60))

    # Update defer state
    ((defer_count++))
    local now
    now=$(date +%s)
    if [[ "$first_defer_epoch" -eq 0 ]]; then
        first_defer_epoch="$now"
    fi

    mkdir -p "$(dirname "$DEFER_STATE_FILE")"
    printf '%d\n%d\n' "$defer_count" "$first_defer_epoch" > "$DEFER_STATE_FILE"

    log_info "System busy — deferring backup (attempt ${defer_count}, next check in ${next_check_min}min)"
    return 1  # Defer
}

# Clear the deferral state (called when backup proceeds or completes)
_clear_defer_state() {
    rm -f "$DEFER_STATE_FILE" 2>/dev/null || true
    log_debug "Defer state cleared"
}

# Get the next defer check interval in seconds (for use by scheduler)
get_next_defer_interval() {
    local defer_count=0
    if [[ -f "$DEFER_STATE_FILE" ]]; then
        defer_count=$(head -1 "$DEFER_STATE_FILE" 2>/dev/null || echo 0)
    fi

    local -a defer_intervals=(900 1800 3600 7200)
    local interval_idx=$defer_count
    if [[ "$interval_idx" -ge "${#defer_intervals[@]}" ]]; then
        interval_idx=$(( ${#defer_intervals[@]} - 1 ))
    fi

    echo "${defer_intervals[$interval_idx]}"
}

# ═══════════════════════════════════════════════════════════════
#  SYSTEM METRICS RECORDING
# ═══════════════════════════════════════════════════════════════

# Record current system metrics to CSV for trend analysis
# Logs: timestamp, cpu_idle%, ram_available%, load_average
# File: $DATA_DIR/data/cpu_stats.csv
record_system_metrics() {
    local data_dir
    data_dir=$(config_get "DATA_DIR" "/var/lib/sysbackup")
    local metrics_file="${data_dir}/data/cpu_stats.csv"

    # Ensure header exists
    if [[ ! -f "$metrics_file" ]]; then
        mkdir -p "$(dirname "$metrics_file")"
        echo "timestamp,cpu_idle_pct,ram_available_pct,load_avg_1m" > "$metrics_file"
    fi

    # ── CPU idle % (quick sample — use a shorter interval for metrics) ──
    local cpu_idle
    # Use a 1-second sample for metrics recording to be faster
    local line1 line2
    line1=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "cpu 0 0 0 100 0 0 0")
    sleep 1
    line2=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "cpu 0 0 0 100 0 0 0")

    local user1 nice1 system1 idle1 iowait1
    read -r _ user1 nice1 system1 idle1 iowait1 _ <<< "$line1"
    local user2 nice2 system2 idle2 iowait2
    read -r _ user2 nice2 system2 idle2 iowait2 _ <<< "$line2"

    local total1=$((user1 + nice1 + system1 + idle1 + iowait1))
    local total2=$((user2 + nice2 + system2 + idle2 + iowait2))
    local total_delta=$((total2 - total1))
    local idle_delta=$((idle2 - idle1))

    if [[ "$total_delta" -gt 0 ]]; then
        cpu_idle=$((idle_delta * 100 / total_delta))
    else
        cpu_idle=100
    fi

    # ── RAM available % ──
    local ram_available_pct=0
    if [[ -f /proc/meminfo ]]; then
        local mem_total mem_available
        mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

        if [[ "$mem_total" -gt 0 ]]; then
            ram_available_pct=$((mem_available * 100 / mem_total))
        fi
    fi

    # ── Load average ──
    local load_avg
    load_avg=$(get_load_average)

    # Record to CSV
    record_metric "$metrics_file" "$cpu_idle,$ram_available_pct,$load_avg"
    log_debug "Metrics recorded: CPU idle=${cpu_idle}%, RAM avail=${ram_available_pct}%, load=${load_avg}"
}

# ═══════════════════════════════════════════════════════════════
#  MODULE SELF-TEST
# ═══════════════════════════════════════════════════════════════

_idle_detect_loaded() {
    log_debug "Idle detection module v${IDLE_DETECT_VERSION} loaded"
}

_idle_detect_loaded
