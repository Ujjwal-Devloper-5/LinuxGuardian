#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Health Score AI
#  Composite health scoring for backup status reporting.
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

# ── Calculate composite health score (0-100) ───────────────────
calculate_health_score() {
    local completion="${1:-100}"    # 0 or 100
    local zscore_abs="${2:-0}"      # absolute Z-score (0.0 to N)
    local integrity_pass="${3:-100}" # 0 or 100
    local days_remaining="${4:-999}" # integer
    local duration_ratio="${5:-1.0}" # float

    # Weightings
    # Completion: 30%
    # Anomaly: 25%
    # Integrity: 20%
    # Storage: 15%
    # Duration: 10%

    # 1. Completion Score (max 30)
    local score_completion=$(echo "$completion * 0.30" | bc -l)

    # 2. Anomaly Score (max 25)
    local anomaly_factor=100
    if (( $(echo "$zscore_abs >= 3" | bc -l) )); then anomaly_factor=0
    elif (( $(echo "$zscore_abs >= 2" | bc -l) )); then anomaly_factor=50
    elif (( $(echo "$zscore_abs >= 1" | bc -l) )); then anomaly_factor=75
    fi
    local score_anomaly=$(echo "$anomaly_factor * 0.25" | bc -l)

    # 3. Integrity Score (max 20)
    local score_integrity=$(echo "$integrity_pass * 0.20" | bc -l)

    # 4. Storage Score (max 15)
    local storage_factor=100
    if [[ "$days_remaining" -lt 7 ]]; then storage_factor=0
    elif [[ "$days_remaining" -lt 30 ]]; then storage_factor=50
    elif [[ "$days_remaining" -lt 60 ]]; then storage_factor=75
    fi
    local score_storage=$(echo "$storage_factor * 0.15" | bc -l)

    # 5. Duration Score (max 10)
    local duration_factor=100
    if (( $(echo "$duration_ratio > 2.0" | bc -l) )); then duration_factor=25
    elif (( $(echo "$duration_ratio > 1.5" | bc -l) )); then duration_factor=50
    elif (( $(echo "$duration_ratio > 1.2" | bc -l) )); then duration_factor=75
    fi
    local score_duration=$(echo "$duration_factor * 0.10" | bc -l)

    # Total
    echo "$score_completion + $score_anomaly + $score_integrity + $score_storage + $score_duration" | bc | cut -d'.' -f1
}

# ── Get grade mapping ─────────────────────────────────────────
get_health_grade() {
    local score="${1:-0}"
    
    if [[ "$score" -ge 90 ]]; then
        echo "EXCELLENT"
    elif [[ "$score" -ge 70 ]]; then
        echo "GOOD"
    elif [[ "$score" -ge 50 ]]; then
        echo "WARNING"
    else
        echo "CRITICAL"
    fi
}

get_grade_emoji() {
    local grade="$1"
    case "$grade" in
        EXCELLENT) echo "🟢" ;;
        GOOD)      echo "🟡" ;;
        WARNING)   echo "🟠" ;;
        CRITICAL)  echo "🔴" ;;
        *)         echo "⚪" ;;
    esac
}

# ── Generate comprehensive formatted report ────────────────────
generate_backup_report() {
    local score="${1:-0}"
    local backup_type="${2:-unknown}"
    local duration="${3:-0}"
    local zscore="${4:-0}"
    local days_remaining="${5:-999}"
    local cloud_synced="${6:-false}"
    
    local grade
    grade=$(get_health_grade "$score")
    local emoji
    emoji=$(get_grade_emoji "$grade")
    
    local duration_str
    duration_str=$(human_duration "$duration")
    
    local sync_status="Skipped/Failed"
    [[ "$cloud_synced" == "true" ]] && sync_status="Success"
    
    local storage_str="Plenty"
    if [[ "$days_remaining" -ne 999 ]]; then
        storage_str="~${days_remaining} days left"
    fi
    
    local report=""
    report+="Health Score: ${score}/100 ($grade) ${emoji}\n\n"
    report+="📊 Backup Summary ($backup_type):\n"
    report+="  Duration:       ${duration_str}\n"
    report+="  Cloud Sync:     ${sync_status}\n"
    report+="  Anomaly Z-Score: ${zscore}\n"
    report+="  Storage Runwy:  ${storage_str}\n"
    
    echo -e "$report"
}
