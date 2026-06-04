#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Interactive Initialization Wizard
#  Guides the user through first-time setup with a beautiful
#  TUI experience using gum (with whiptail/read fallback).
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SYSBACKUP_LIB_DIR="${SYSBACKUP_LIB_DIR:-/usr/local/lib/linuxguardian}"
source "${SYSBACKUP_LIB_DIR}/modules/utils.sh"

# ═══════════════════════════════════════════════════════════════
#  TUI ABSTRACTION LAYER
#  Auto-detect: gum > whiptail > plain read
# ═══════════════════════════════════════════════════════════════

TUI_ENGINE="read"  # default fallback

detect_tui_engine() {
    if check_command gum; then
        TUI_ENGINE="gum"
    elif check_command whiptail; then
        TUI_ENGINE="whiptail"
    else
        TUI_ENGINE="read"
    fi
    log_debug "TUI engine: $TUI_ENGINE"
}

# ── Styled Header ────────────────────────────────────────────
tui_header() {
    local title="$1"
    local subtitle="${2:-}"

    case "$TUI_ENGINE" in
        gum)
            echo ""
            gum style \
                --border double \
                --border-foreground 212 \
                --padding "1 3" \
                --margin "0 2" \
                --bold \
                "$title" "$subtitle"
            echo ""
            ;;
        *)
            echo ""
            printf "${CLR_CYAN}╔══════════════════════════════════════════╗${CLR_RESET}\n"
            printf "${CLR_CYAN}║  ${CLR_BOLD}%-40s${CLR_CYAN}║${CLR_RESET}\n" "$title"
            if [[ -n "$subtitle" ]]; then
                printf "${CLR_CYAN}║  ${CLR_DIM}%-40s${CLR_CYAN}║${CLR_RESET}\n" "$subtitle"
            fi
            printf "${CLR_CYAN}╚══════════════════════════════════════════╝${CLR_RESET}\n"
            echo ""
            ;;
    esac
}

# ── Text Input ────────────────────────────────────────────────
tui_input() {
    local prompt="$1"
    local default="${2:-}"
    local result=""

    case "$TUI_ENGINE" in
        gum)
            result=$(gum input \
                --placeholder "$default" \
                --prompt "  $prompt: " \
                --value "$default" \
                --width 50 \
                --char-limit 200)
            ;;
        whiptail)
            result=$(whiptail --inputbox "$prompt" 10 50 "$default" 3>&1 1>&2 2>&3 || echo "$default")
            ;;
        *)
            printf "  ${CLR_CYAN}$prompt${CLR_RESET} [${CLR_DIM}$default${CLR_RESET}]: "
            read -r result
            result="${result:-$default}"
            ;;
    esac

    echo "$result"
}

# ── Single Choice Menu ────────────────────────────────────────
tui_choose() {
    local prompt="$1"
    shift
    local options=("$@")
    local result=""

    case "$TUI_ENGINE" in
        gum)
            printf "  ${CLR_CYAN}$prompt${CLR_RESET}\n"
            result=$(printf '%s\n' "${options[@]}" | gum choose --cursor.foreground 212)
            ;;
        whiptail)
            local items=()
            local i=1
            for opt in "${options[@]}"; do
                items+=("$opt" "" "$i")
                ((i++))
            done
            result=$(whiptail --menu "$prompt" 20 60 10 "${items[@]}" 3>&1 1>&2 2>&3 || echo "${options[0]}")
            ;;
        *)
            printf "  ${CLR_CYAN}$prompt${CLR_RESET}\n"
            local i=1
            for opt in "${options[@]}"; do
                printf "  ${CLR_YELLOW}%d)${CLR_RESET} %s\n" "$i" "$opt"
                ((i++))
            done
            printf "  ${CLR_CYAN}Choose [1-${#options[@]}]:${CLR_RESET} "
            local num
            read -r num
            num="${num:-1}"
            if [[ "$num" -ge 1 && "$num" -le "${#options[@]}" ]]; then
                result="${options[$((num - 1))]}"
            else
                result="${options[0]}"
            fi
            ;;
    esac

    echo "$result"
}

# ── Yes/No Confirmation ──────────────────────────────────────
tui_confirm() {
    local prompt="$1"
    local default="${2:-yes}"

    case "$TUI_ENGINE" in
        gum)
            if [[ "$default" == "yes" ]]; then
                gum confirm "$prompt" --default=true && return 0 || return 1
            else
                gum confirm "$prompt" --default=false && return 0 || return 1
            fi
            ;;
        whiptail)
            if whiptail --yesno "$prompt" 10 50; then
                return 0
            else
                return 1
            fi
            ;;
        *)
            local yn_hint="[Y/n]"
            [[ "$default" == "no" ]] && yn_hint="[y/N]"
            printf "  ${CLR_CYAN}$prompt${CLR_RESET} $yn_hint: "
            local ans
            read -r ans
            ans="${ans:-$default}"
            case "$ans" in
                [Yy]*) return 0 ;;
                *)     return 1 ;;
            esac
            ;;
    esac
}

# ── Spinner (gum only) ───────────────────────────────────────
tui_spin() {
    local title="$1"
    shift

    case "$TUI_ENGINE" in
        gum)
            gum spin --spinner dot --title "  $title" -- "$@"
            ;;
        *)
            printf "  ${CLR_DIM}$title...${CLR_RESET} "
            "$@" 2>/dev/null
            printf "${CLR_GREEN}done${CLR_RESET}\n"
            ;;
    esac
}

# ── Password Input ────────────────────────────────────────────
tui_password() {
    local prompt="$1"
    local result=""

    case "$TUI_ENGINE" in
        gum)
            result=$(gum input --password --prompt "  $prompt: " --width 50)
            ;;
        whiptail)
            result=$(whiptail --passwordbox "$prompt" 10 50 3>&1 1>&2 2>&3 || echo "")
            ;;
        *)
            printf "  ${CLR_CYAN}$prompt${CLR_RESET}: "
            read -rs result
            echo ""
            ;;
    esac

    echo "$result"
}

# ── Info Message ──────────────────────────────────────────────
tui_info() {
    local msg="$1"
    case "$TUI_ENGINE" in
        gum)
            gum style --foreground 39 --italic "  ℹ $msg"
            ;;
        *)
            printf "  ${CLR_BLUE}ℹ %s${CLR_RESET}\n" "$msg"
            ;;
    esac
}

# ── Success Message ───────────────────────────────────────────
tui_success() {
    local msg="$1"
    case "$TUI_ENGINE" in
        gum)
            gum style --foreground 46 --bold "  ✅ $msg"
            ;;
        *)
            printf "  ${CLR_GREEN}✅ %s${CLR_RESET}\n" "$msg"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  WIZARD STEPS
# ═══════════════════════════════════════════════════════════════

# Collected settings
declare -A WIZARD_SETTINGS

wizard_welcome() {
    clear 2>/dev/null || true
    print_banner

    case "$TUI_ENGINE" in
        gum)
            gum style \
                --border rounded \
                --border-foreground 39 \
                --padding "1 3" \
                --margin "0 2" \
                "Welcome to LinuxGuardian Setup Wizard!" \
                "" \
                "This wizard will guide you through:" \
                "  • Configuring backup locations" \
                "  • Setting up cloud storage" \
                "  • Configuring schedules" \
                "  • Enabling AI features" \
                "  • Initializing backup repositories" \
                "" \
                "Let's make your system backup-proof! 🛡️"
            ;;
        *)
            printf "${CLR_CYAN}  Welcome to LinuxGuardian Setup Wizard!${CLR_RESET}\n\n"
            printf "  This wizard will guide you through:\n"
            printf "    • Configuring backup locations\n"
            printf "    • Setting up cloud storage\n"
            printf "    • Configuring schedules\n"
            printf "    • Enabling AI features\n"
            printf "    • Initializing backup repositories\n"
            printf "\n  Let's make your system backup-proof! 🛡️\n"
            ;;
    esac

    echo ""
    tui_confirm "Ready to begin?" "yes" || { echo "Setup cancelled."; exit 0; }
}

wizard_step_general() {
    tui_header "Step 1/9: General Settings" "Basic backup configuration"

    WIZARD_SETTINGS[BACKUP_NAME]=$(tui_input "Backup name (hostname)" "$(get_hostname)")
    WIZARD_SETTINGS[DATA_DIR]=$(tui_input "Data directory" "/var/lib/linuxguardian")
    WIZARD_SETTINGS[LOG_DIR]=$(tui_input "Log directory" "${WIZARD_SETTINGS[DATA_DIR]}/logs")

    tui_success "General settings configured"
}

wizard_step_storage() {
    tui_header "Step 2/9: Storage Locations" "Where to store backup repositories"

    local default_base="${WIZARD_SETTINGS[DATA_DIR]}/repos"
    WIZARD_SETTINGS[HOME_REPO]=$(tui_input "Home backup repo path" "${default_base}/home")
    WIZARD_SETTINGS[SYSTEM_REPO]=$(tui_input "System backup repo path" "${default_base}/system")

    tui_info "Repos will be initialized after setup"
    tui_success "Storage locations configured"
}

wizard_step_password() {
    tui_header "Step 3/9: Encryption" "Backup encryption password"

    tui_info "restic encrypts all backups with AES-256."
    tui_info "This password is required for ALL backup/restore operations."
    echo ""

    local pw_method
    pw_method=$(tui_choose "How would you like to set the encryption password?" \
        "Generate a secure random password (recommended)" \
        "Enter my own password")

    local password=""
    local password_file="${WIZARD_SETTINGS[DATA_DIR]}/.restic-password"

    if [[ "$pw_method" == *"Generate"* ]]; then
        password=$(generate_password 32)
        tui_info "Generated password (SAVE THIS SOMEWHERE SAFE!):"
        echo ""
        printf "  ${CLR_YELLOW}${CLR_BOLD}  %s  ${CLR_RESET}\n" "$password"
        echo ""
        tui_info "This password will be stored in: $password_file"
        tui_confirm "I have saved the password somewhere safe" "yes" || {
            log_warn "Please save the password before continuing!"
            tui_confirm "Continue anyway?" "no" || exit 1
        }
    else
        password=$(tui_password "Enter encryption password")
        local confirm
        confirm=$(tui_password "Confirm encryption password")
        if [[ "$password" != "$confirm" ]]; then
            log_error "Passwords don't match!"
            exit 1
        fi
    fi

    WIZARD_SETTINGS[RESTIC_PASSWORD]="$password"
    WIZARD_SETTINGS[RESTIC_PASSWORD_FILE]="$password_file"

    tui_success "Encryption configured"
}

wizard_step_cloud() {
    tui_header "Step 4/9: Cloud Storage" "Configure cloud backup destination"

    if ! tui_confirm "Enable cloud backup?" "yes"; then
        WIZARD_SETTINGS[CLOUD_ENABLED]="false"
        tui_info "Cloud backup disabled. Backups will be local only."
        return
    fi

    WIZARD_SETTINGS[CLOUD_ENABLED]="true"

    local provider
    provider=$(tui_choose "Select your cloud provider:" \
        "Google Drive" \
        "Backblaze B2" \
        "Amazon S3" \
        "Cloudflare R2" \
        "Microsoft OneDrive" \
        "Dropbox" \
        "SFTP Server" \
        "Wasabi" \
        "DigitalOcean Spaces" \
        "Other (configure manually)")

    # Map display name to rclone type
    case "$provider" in
        "Google Drive")        WIZARD_SETTINGS[CLOUD_PROVIDER]="drive" ;;
        "Backblaze B2")        WIZARD_SETTINGS[CLOUD_PROVIDER]="b2" ;;
        "Amazon S3")           WIZARD_SETTINGS[CLOUD_PROVIDER]="s3" ;;
        "Cloudflare R2")       WIZARD_SETTINGS[CLOUD_PROVIDER]="s3" ;;
        "Microsoft OneDrive")  WIZARD_SETTINGS[CLOUD_PROVIDER]="onedrive" ;;
        "Dropbox")             WIZARD_SETTINGS[CLOUD_PROVIDER]="dropbox" ;;
        "SFTP Server")         WIZARD_SETTINGS[CLOUD_PROVIDER]="sftp" ;;
        "Wasabi")              WIZARD_SETTINGS[CLOUD_PROVIDER]="s3" ;;
        "DigitalOcean Spaces") WIZARD_SETTINGS[CLOUD_PROVIDER]="s3" ;;
        *)                     WIZARD_SETTINGS[CLOUD_PROVIDER]="manual" ;;
    esac

    WIZARD_SETTINGS[CLOUD_REMOTE]=$(tui_input "Remote name" "linuxguardian-cloud")
    WIZARD_SETTINGS[CLOUD_PATH]=$(tui_input "Remote path/bucket" "linuxguardian")

    tui_info "You'll need to configure rclone for ${provider}."
    echo ""

    if tui_confirm "Configure rclone now? (requires interactive setup)" "yes"; then
        echo ""
        tui_info "Starting rclone configuration..."
        tui_info "Follow the prompts to authenticate with ${provider}."
        echo ""

        if [[ "${WIZARD_SETTINGS[CLOUD_PROVIDER]}" != "manual" ]]; then
            rclone config create "${WIZARD_SETTINGS[CLOUD_REMOTE]}" \
                "${WIZARD_SETTINGS[CLOUD_PROVIDER]}" 2>&1 || {
                log_warn "rclone config failed. You can configure later with: rclone config"
            }
        else
            rclone config 2>&1 || {
                log_warn "rclone config failed. You can configure later with: rclone config"
            }
        fi
    else
        tui_info "Configure later with: rclone config"
        tui_info "Create a remote named '${WIZARD_SETTINGS[CLOUD_REMOTE]}'"
    fi

    local bw_limit
    bw_limit=$(tui_input "Bandwidth limit (0 = unlimited, or e.g. '10M')" "0")
    WIZARD_SETTINGS[RCLONE_BW_LIMIT]="$bw_limit"

    tui_success "Cloud storage configured"
}

wizard_step_schedule() {
    tui_header "Step 5/9: Backup Schedule" "When to run backups"

    # Home backup schedule
    local home_freq
    home_freq=$(tui_choose "Home directory backup frequency:" \
        "Daily (recommended)" \
        "Twice daily" \
        "Every 6 hours" \
        "Weekly")

    case "$home_freq" in
        "Daily"*)        WIZARD_SETTINGS[HOME_SCHEDULE]="daily" ;;
        "Twice daily")   WIZARD_SETTINGS[HOME_SCHEDULE]="twice-daily" ;;
        "Every 6"*)      WIZARD_SETTINGS[HOME_SCHEDULE]="6hours" ;;
        "Weekly")        WIZARD_SETTINGS[HOME_SCHEDULE]="weekly" ;;
    esac

    WIZARD_SETTINGS[HOME_TIME]=$(tui_input "Home backup time (HH:MM, 24h format)" "02:00")

    # System backup schedule
    local sys_freq
    sys_freq=$(tui_choose "Full system backup frequency:" \
        "Weekly (recommended)" \
        "Daily" \
        "Bi-weekly" \
        "Monthly")

    case "$sys_freq" in
        "Weekly"*)   WIZARD_SETTINGS[SYSTEM_SCHEDULE]="weekly" ;;
        "Daily")     WIZARD_SETTINGS[SYSTEM_SCHEDULE]="daily" ;;
        "Bi-weekly") WIZARD_SETTINGS[SYSTEM_SCHEDULE]="biweekly" ;;
        "Monthly")   WIZARD_SETTINGS[SYSTEM_SCHEDULE]="monthly" ;;
    esac

    WIZARD_SETTINGS[SYSTEM_TIME]=$(tui_input "System backup time (HH:MM)" "03:00")

    local sys_day
    sys_day=$(tui_choose "System backup day (for weekly/bi-weekly):" \
        "Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")
    WIZARD_SETTINGS[SYSTEM_DAY]="$sys_day"

    tui_success "Schedule configured"
}

wizard_step_resources() {
    tui_header "Step 6/9: Resource Limits" "CPU, I/O, and memory throttling"

    tui_info "These settings prevent backup from slowing down your system."
    echo ""

    local profile
    profile=$(tui_choose "Select a resource profile:" \
        "Conservative (recommended — minimal system impact)" \
        "Balanced (moderate speed, moderate impact)" \
        "Aggressive (fastest backup, higher system impact)" \
        "Custom")

    case "$profile" in
        "Conservative"*)
            WIZARD_SETTINGS[CPU_QUOTA]="30%"
            WIZARD_SETTINGS[IO_WEIGHT]="10"
            WIZARD_SETTINGS[MEMORY_MAX]="512M"
            WIZARD_SETTINGS[NICE_LEVEL]="19"
            WIZARD_SETTINGS[IO_CLASS]="idle"
            ;;
        "Balanced"*)
            WIZARD_SETTINGS[CPU_QUOTA]="50%"
            WIZARD_SETTINGS[IO_WEIGHT]="20"
            WIZARD_SETTINGS[MEMORY_MAX]="1G"
            WIZARD_SETTINGS[NICE_LEVEL]="15"
            WIZARD_SETTINGS[IO_CLASS]="best-effort"
            ;;
        "Aggressive"*)
            WIZARD_SETTINGS[CPU_QUOTA]="80%"
            WIZARD_SETTINGS[IO_WEIGHT]="50"
            WIZARD_SETTINGS[MEMORY_MAX]="2G"
            WIZARD_SETTINGS[NICE_LEVEL]="10"
            WIZARD_SETTINGS[IO_CLASS]="best-effort"
            ;;
        "Custom"*)
            WIZARD_SETTINGS[CPU_QUOTA]=$(tui_input "CPU quota (e.g., 50%)" "50%")
            WIZARD_SETTINGS[IO_WEIGHT]=$(tui_input "I/O weight (1-100, lower = less priority)" "20")
            WIZARD_SETTINGS[MEMORY_MAX]=$(tui_input "Memory limit (e.g., 1G)" "1G")
            WIZARD_SETTINGS[NICE_LEVEL]=$(tui_input "Nice level (0-19, higher = lower priority)" "19")
            WIZARD_SETTINGS[IO_CLASS]=$(tui_choose "I/O scheduling class:" "idle" "best-effort")
            ;;
    esac

    tui_success "Resource limits configured"
}

wizard_step_notifications() {
    tui_header "Step 7/9: Notifications" "Desktop alerts & sounds"

    if tui_confirm "Enable desktop notifications?" "yes"; then
        WIZARD_SETTINGS[NOTIFY_ENABLED]="true"

        if tui_confirm "Play sound on completion?" "yes"; then
            WIZARD_SETTINGS[NOTIFY_SOUND_ENABLED]="true"
        else
            WIZARD_SETTINGS[NOTIFY_SOUND_ENABLED]="false"
        fi

        WIZARD_SETTINGS[NOTIFY_ON_SUCCESS]="true"
        WIZARD_SETTINGS[NOTIFY_ON_FAILURE]="true"
    else
        WIZARD_SETTINGS[NOTIFY_ENABLED]="false"
        WIZARD_SETTINGS[NOTIFY_SOUND_ENABLED]="false"
    fi

    tui_success "Notifications configured"
}

wizard_step_ai() {
    tui_header "Step 8/9: AI Features" "Smart backup intelligence"

    tui_info "AI features make your backups smarter and safer."
    echo ""

    if tui_confirm "Enable smart scheduling (detect idle system)?" "yes"; then
        WIZARD_SETTINGS[SMART_SCHEDULE_ENABLED]="true"
        WIZARD_SETTINGS[MAX_DEFER_HOURS]=$(tui_input "Max defer hours (force backup after)" "6")
    else
        WIZARD_SETTINGS[SMART_SCHEDULE_ENABLED]="false"
    fi

    WIZARD_SETTINGS[ANOMALY_DETECTION]="true"
    WIZARD_SETTINGS[STORAGE_PREDICTION]="true"
    WIZARD_SETTINGS[INTEGRITY_VERIFY]="true"
    WIZARD_SETTINGS[LOG_ANALYSIS]="true"
    WIZARD_SETTINGS[HEALTH_SCORE]="true"

    if tui_confirm "Enable all AI features? (anomaly detection, storage prediction, integrity, log analysis, health score)" "yes"; then
        tui_success "All AI features enabled"
    else
        tui_info "Configuring individual AI features..."
        tui_confirm "Anomaly detection (detect unusual backup sizes)?" "yes" && WIZARD_SETTINGS[ANOMALY_DETECTION]="true" || WIZARD_SETTINGS[ANOMALY_DETECTION]="false"
        tui_confirm "Storage prediction (predict when storage runs out)?" "yes" && WIZARD_SETTINGS[STORAGE_PREDICTION]="true" || WIZARD_SETTINGS[STORAGE_PREDICTION]="false"
        tui_confirm "Integrity verification (rotating checksum checks)?" "yes" && WIZARD_SETTINGS[INTEGRITY_VERIFY]="true" || WIZARD_SETTINGS[INTEGRITY_VERIFY]="false"
        tui_confirm "Log analysis (detect error patterns)?" "yes" && WIZARD_SETTINGS[LOG_ANALYSIS]="true" || WIZARD_SETTINGS[LOG_ANALYSIS]="false"
        WIZARD_SETTINGS[HEALTH_SCORE]="true"  # Always enabled — it's the summary
    fi

    tui_success "AI features configured"
}

wizard_step_retention() {
    tui_header "Step 9/9: Retention Policy" "How long to keep backup snapshots"

    tui_info "Using Grandfather-Father-Son (GFS) rotation policy."
    echo ""

    local policy
    policy=$(tui_choose "Select retention policy:" \
        "Standard (7 daily, 4 weekly, 12 monthly, 3 yearly)" \
        "Minimal (3 daily, 2 weekly, 6 monthly, 1 yearly)" \
        "Extended (14 daily, 8 weekly, 24 monthly, 5 yearly)" \
        "Custom")

    case "$policy" in
        "Standard"*)
            WIZARD_SETTINGS[KEEP_DAILY]=7
            WIZARD_SETTINGS[KEEP_WEEKLY]=4
            WIZARD_SETTINGS[KEEP_MONTHLY]=12
            WIZARD_SETTINGS[KEEP_YEARLY]=3
            ;;
        "Minimal"*)
            WIZARD_SETTINGS[KEEP_DAILY]=3
            WIZARD_SETTINGS[KEEP_WEEKLY]=2
            WIZARD_SETTINGS[KEEP_MONTHLY]=6
            WIZARD_SETTINGS[KEEP_YEARLY]=1
            ;;
        "Extended"*)
            WIZARD_SETTINGS[KEEP_DAILY]=14
            WIZARD_SETTINGS[KEEP_WEEKLY]=8
            WIZARD_SETTINGS[KEEP_MONTHLY]=24
            WIZARD_SETTINGS[KEEP_YEARLY]=5
            ;;
        "Custom"*)
            WIZARD_SETTINGS[KEEP_DAILY]=$(tui_input "Keep daily snapshots" "7")
            WIZARD_SETTINGS[KEEP_WEEKLY]=$(tui_input "Keep weekly snapshots" "4")
            WIZARD_SETTINGS[KEEP_MONTHLY]=$(tui_input "Keep monthly snapshots" "12")
            WIZARD_SETTINGS[KEEP_YEARLY]=$(tui_input "Keep yearly snapshots" "3")
            ;;
    esac

    tui_success "Retention policy configured"
}

# ═══════════════════════════════════════════════════════════════
#  SUMMARY & WRITE CONFIG
# ═══════════════════════════════════════════════════════════════

wizard_summary() {
    tui_header "Configuration Summary" "Review your settings"

    local summary=""
    summary+="  Backup Name:        ${WIZARD_SETTINGS[BACKUP_NAME]}\n"
    summary+="  Data Directory:     ${WIZARD_SETTINGS[DATA_DIR]}\n"
    summary+="  Home Repo:          ${WIZARD_SETTINGS[HOME_REPO]}\n"
    summary+="  System Repo:        ${WIZARD_SETTINGS[SYSTEM_REPO]}\n"
    summary+="  \n"
    summary+="  Home Schedule:      ${WIZARD_SETTINGS[HOME_SCHEDULE]} at ${WIZARD_SETTINGS[HOME_TIME]}\n"
    summary+="  System Schedule:    ${WIZARD_SETTINGS[SYSTEM_SCHEDULE]} on ${WIZARD_SETTINGS[SYSTEM_DAY]} at ${WIZARD_SETTINGS[SYSTEM_TIME]}\n"
    summary+="  \n"
    summary+="  Cloud Enabled:      ${WIZARD_SETTINGS[CLOUD_ENABLED]}\n"
    if [[ "${WIZARD_SETTINGS[CLOUD_ENABLED]}" == "true" ]]; then
        summary+="  Cloud Provider:     ${WIZARD_SETTINGS[CLOUD_PROVIDER]}\n"
        summary+="  Cloud Remote:       ${WIZARD_SETTINGS[CLOUD_REMOTE]}:${WIZARD_SETTINGS[CLOUD_PATH]}\n"
    fi
    summary+="  \n"
    summary+="  CPU Quota:          ${WIZARD_SETTINGS[CPU_QUOTA]}\n"
    summary+="  I/O Weight:         ${WIZARD_SETTINGS[IO_WEIGHT]}\n"
    summary+="  Memory Limit:       ${WIZARD_SETTINGS[MEMORY_MAX]}\n"
    summary+="  \n"
    summary+="  Notifications:      ${WIZARD_SETTINGS[NOTIFY_ENABLED]}\n"
    summary+="  Sound:              ${WIZARD_SETTINGS[NOTIFY_SOUND_ENABLED]}\n"
    summary+="  \n"
    summary+="  Smart Scheduling:   ${WIZARD_SETTINGS[SMART_SCHEDULE_ENABLED]}\n"
    summary+="  Anomaly Detection:  ${WIZARD_SETTINGS[ANOMALY_DETECTION]}\n"
    summary+="  Storage Prediction: ${WIZARD_SETTINGS[STORAGE_PREDICTION]}\n"
    summary+="  \n"
    summary+="  Retention:          ${WIZARD_SETTINGS[KEEP_DAILY]}d / ${WIZARD_SETTINGS[KEEP_WEEKLY]}w / ${WIZARD_SETTINGS[KEEP_MONTHLY]}m / ${WIZARD_SETTINGS[KEEP_YEARLY]}y\n"

    case "$TUI_ENGINE" in
        gum)
            echo -e "$summary" | gum style \
                --border rounded \
                --border-foreground 39 \
                --padding "1 2"
            ;;
        *)
            echo -e "$summary"
            ;;
    esac

    echo ""
    tui_confirm "Proceed with this configuration?" "yes" || {
        log_info "Setup cancelled by user."
        exit 0
    }
}

write_config() {
    local config_dir="/etc/linuxguardian"
    local config_file="${config_dir}/linuxguardian.conf"

    log_info "Writing configuration..."

    # Create config directory
    mkdir -p "$config_dir"

    # Map schedule to OnCalendar format for systemd timers
    local home_oncalendar system_oncalendar
    case "${WIZARD_SETTINGS[HOME_SCHEDULE]}" in
        daily)       home_oncalendar="*-*-* ${WIZARD_SETTINGS[HOME_TIME]}:00" ;;
        twice-daily) home_oncalendar="*-*-* 02,14:00:00" ;;
        6hours)      home_oncalendar="*-*-* 00/6:00:00" ;;
        weekly)      home_oncalendar="Sun *-*-* ${WIZARD_SETTINGS[HOME_TIME]}:00" ;;
    esac

    local sys_day_short="${WIZARD_SETTINGS[SYSTEM_DAY]:0:3}"
    case "${WIZARD_SETTINGS[SYSTEM_SCHEDULE]}" in
        daily)    system_oncalendar="*-*-* ${WIZARD_SETTINGS[SYSTEM_TIME]}:00" ;;
        weekly)   system_oncalendar="${sys_day_short} *-*-* ${WIZARD_SETTINGS[SYSTEM_TIME]}:00" ;;
        biweekly) system_oncalendar="${sys_day_short} *-*-1/14 ${WIZARD_SETTINGS[SYSTEM_TIME]}:00" ;;
        monthly)  system_oncalendar="*-*-01 ${WIZARD_SETTINGS[SYSTEM_TIME]}:00" ;;
    esac

    cat > "$config_file" << CONF
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Configuration File
#  Generated: $(date '+%Y-%m-%d %H:%M:%S')
#  Hostname: $(hostname)
# ═══════════════════════════════════════════════════════════════

# ── General ───────────────────────────────────────────────────
BACKUP_NAME="${WIZARD_SETTINGS[BACKUP_NAME]}"
DATA_DIR="${WIZARD_SETTINGS[DATA_DIR]}"
LOG_DIR="${WIZARD_SETTINGS[LOG_DIR]}"
LOG_RETENTION_DAYS=30

# ── Backup Repositories ──────────────────────────────────────
HOME_REPO="${WIZARD_SETTINGS[HOME_REPO]}"
SYSTEM_REPO="${WIZARD_SETTINGS[SYSTEM_REPO]}"
RESTIC_PASSWORD_FILE="${WIZARD_SETTINGS[RESTIC_PASSWORD_FILE]}"

# ── Backup Sources ────────────────────────────────────────────
HOME_SOURCES="/home"
SYSTEM_SOURCES="/"
HOME_EXCLUDE_FILE="/etc/linuxguardian/exclude-home.txt"
SYSTEM_EXCLUDE_FILE="/etc/linuxguardian/exclude-system.txt"

# ── Schedule ──────────────────────────────────────────────────
HOME_SCHEDULE="${WIZARD_SETTINGS[HOME_SCHEDULE]}"
HOME_TIME="${WIZARD_SETTINGS[HOME_TIME]}"
HOME_ONCALENDAR="${home_oncalendar}"
SYSTEM_SCHEDULE="${WIZARD_SETTINGS[SYSTEM_SCHEDULE]}"
SYSTEM_DAY="${WIZARD_SETTINGS[SYSTEM_DAY]}"
SYSTEM_TIME="${WIZARD_SETTINGS[SYSTEM_TIME]}"
SYSTEM_ONCALENDAR="${system_oncalendar}"

# ── Smart Scheduling (AI) ────────────────────────────────────
SMART_SCHEDULE_ENABLED=${WIZARD_SETTINGS[SMART_SCHEDULE_ENABLED]}
IDLE_THRESHOLD_MS=600000
CPU_IDLE_THRESHOLD=80
MAX_DEFER_HOURS=${WIZARD_SETTINGS[MAX_DEFER_HOURS]:-6}
METRICS_INTERVAL_SEC=300

# ── Cloud Sync ────────────────────────────────────────────────
CLOUD_ENABLED=${WIZARD_SETTINGS[CLOUD_ENABLED]}
CLOUD_REMOTE="${WIZARD_SETTINGS[CLOUD_REMOTE]:-mycloud}"
CLOUD_PATH="${WIZARD_SETTINGS[CLOUD_PATH]:-linuxguardian}"
CLOUD_PROVIDER="${WIZARD_SETTINGS[CLOUD_PROVIDER]:-}"
RCLONE_CONFIG="/etc/linuxguardian/rclone.conf"
RCLONE_BW_LIMIT="${WIZARD_SETTINGS[RCLONE_BW_LIMIT]:-0}"
RCLONE_TRANSFERS=4

# ── Retention (GFS) ──────────────────────────────────────────
KEEP_DAILY=${WIZARD_SETTINGS[KEEP_DAILY]}
KEEP_WEEKLY=${WIZARD_SETTINGS[KEEP_WEEKLY]}
KEEP_MONTHLY=${WIZARD_SETTINGS[KEEP_MONTHLY]}
KEEP_YEARLY=${WIZARD_SETTINGS[KEEP_YEARLY]}

# ── Resource Limits ───────────────────────────────────────────
NICE_LEVEL=${WIZARD_SETTINGS[NICE_LEVEL]}
IO_CLASS="${WIZARD_SETTINGS[IO_CLASS]}"
CPU_QUOTA="${WIZARD_SETTINGS[CPU_QUOTA]}"
IO_WEIGHT=${WIZARD_SETTINGS[IO_WEIGHT]}
MEMORY_MAX="${WIZARD_SETTINGS[MEMORY_MAX]}"

# ── Notifications ─────────────────────────────────────────────
NOTIFY_ENABLED=${WIZARD_SETTINGS[NOTIFY_ENABLED]}
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true
NOTIFY_SOUND_ENABLED=${WIZARD_SETTINGS[NOTIFY_SOUND_ENABLED]}
NOTIFY_SOUND_SUCCESS="/usr/share/linuxguardian/sounds/backup-success.oga"
NOTIFY_SOUND_ERROR="/usr/share/linuxguardian/sounds/backup-error.oga"

# ── AI Features ───────────────────────────────────────────────
ANOMALY_DETECTION=${WIZARD_SETTINGS[ANOMALY_DETECTION]}
ANOMALY_ZSCORE_WARN=2.0
ANOMALY_ZSCORE_CRITICAL=3.0
STORAGE_PREDICTION=${WIZARD_SETTINGS[STORAGE_PREDICTION]}
INTEGRITY_VERIFY=${WIZARD_SETTINGS[INTEGRITY_VERIFY]}
LOG_ANALYSIS=${WIZARD_SETTINGS[LOG_ANALYSIS]}
HEALTH_SCORE=${WIZARD_SETTINGS[HEALTH_SCORE]}
CONF

    chmod 640 "$config_file"
    tui_success "Configuration written to: $config_file"
}

initialize_system() {
    tui_header "Initializing System" "Setting up directories and repositories"

    # 1. Create data directories
    tui_info "Creating data directories..."
    local data_dir="${WIZARD_SETTINGS[DATA_DIR]}"
    mkdir -p "$data_dir"/{data,logs,repos,cache,config}
    chmod 750 "$data_dir"
    chmod 700 "$data_dir/repos"
    tui_success "Data directories created"

    # 2. Write password file
    tui_info "Securing encryption password..."
    echo "${WIZARD_SETTINGS[RESTIC_PASSWORD]}" > "${WIZARD_SETTINGS[RESTIC_PASSWORD_FILE]}"
    chmod 600 "${WIZARD_SETTINGS[RESTIC_PASSWORD_FILE]}"
    tui_success "Password file secured"

    # 3. Initialize restic repos
    export RESTIC_PASSWORD_FILE="${WIZARD_SETTINGS[RESTIC_PASSWORD_FILE]}"

    tui_info "Initializing home backup repository..."
    if restic init --repo "${WIZARD_SETTINGS[HOME_REPO]}" 2>/dev/null; then
        tui_success "Home repo initialized: ${WIZARD_SETTINGS[HOME_REPO]}"
    else
        log_warn "Home repo may already be initialized"
    fi

    tui_info "Initializing system backup repository..."
    if restic init --repo "${WIZARD_SETTINGS[SYSTEM_REPO]}" 2>/dev/null; then
        tui_success "System repo initialized: ${WIZARD_SETTINGS[SYSTEM_REPO]}"
    else
        log_warn "System repo may already be initialized"
    fi

    # 4. Copy exclude files if not present
    local etc_dir="/etc/linuxguardian"
    if [[ ! -f "$etc_dir/exclude-home.txt" ]]; then
        cp "${SYSBACKUP_LIB_DIR}/../config/exclude-home.txt" "$etc_dir/" 2>/dev/null || \
        cp "/etc/linuxguardian/exclude-home.txt.example" "$etc_dir/exclude-home.txt" 2>/dev/null || true
    fi
    if [[ ! -f "$etc_dir/exclude-system.txt" ]]; then
        cp "${SYSBACKUP_LIB_DIR}/../config/exclude-system.txt" "$etc_dir/" 2>/dev/null || \
        cp "/etc/linuxguardian/exclude-system.txt.example" "$etc_dir/exclude-system.txt" 2>/dev/null || true
    fi

    # 5. Enable systemd timers
    tui_info "Enabling systemd timers..."
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable linuxguardian-home.timer 2>/dev/null && tui_success "Home backup timer enabled" || log_warn "Could not enable home timer"
        systemctl enable linuxguardian-system.timer 2>/dev/null && tui_success "System backup timer enabled" || log_warn "Could not enable system timer"
        systemctl enable linuxguardian-monitor.timer 2>/dev/null && tui_success "Monitor timer enabled" || log_warn "Could not enable monitor timer"
        systemctl start linuxguardian-home.timer 2>/dev/null || true
        systemctl start linuxguardian-system.timer 2>/dev/null || true
        systemctl start linuxguardian-monitor.timer 2>/dev/null || true
    else
        log_warn "systemd not available — timers not configured"
    fi

    tui_success "System initialization complete!"
}

wizard_complete() {
    echo ""
    case "$TUI_ENGINE" in
        gum)
            gum style \
                --border double \
                --border-foreground 46 \
                --padding "1 3" \
                --margin "0 2" \
                --bold \
                "🎉 Setup Complete!" \
                "" \
                "Your system is now backup-proof!" \
                "" \
                "Quick commands:" \
                "  linuxguardian status      — View backup dashboard" \
                "  linuxguardian backup      — Run a backup now" \
                "  linuxguardian snapshots   — List backup snapshots" \
                "  linuxguardian restore     — Restore from backup" \
                "  linuxguardian health      — View health report" \
                "" \
                "Backups are scheduled automatically via systemd timers."
            ;;
        *)
            printf "\n${CLR_GREEN}${CLR_BOLD}  🎉 Setup Complete!${CLR_RESET}\n\n"
            printf "  Your system is now backup-proof!\n\n"
            printf "  Quick commands:\n"
            printf "    ${CLR_CYAN}linuxguardian status${CLR_RESET}      — View backup dashboard\n"
            printf "    ${CLR_CYAN}linuxguardian backup${CLR_RESET}      — Run a backup now\n"
            printf "    ${CLR_CYAN}linuxguardian snapshots${CLR_RESET}   — List backup snapshots\n"
            printf "    ${CLR_CYAN}linuxguardian restore${CLR_RESET}     — Restore from backup\n"
            printf "    ${CLR_CYAN}linuxguardian health${CLR_RESET}      — View health report\n\n"
            printf "  Backups are scheduled automatically via systemd timers.\n"
            ;;
    esac

    echo ""
    if tui_confirm "Run first home backup now?" "yes"; then
        echo ""
        log_info "Starting first home backup..."
        /usr/local/bin/linuxguardian run --home --force 2>&1 || \
            log_warn "First backup had issues. Check: linuxguardian logs --last 1"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

run_init_wizard() {
    require_root

    detect_tui_engine

    wizard_welcome
    wizard_step_general
    wizard_step_storage
    wizard_step_password
    wizard_step_cloud
    wizard_step_schedule
    wizard_step_resources
    wizard_step_notifications
    wizard_step_ai
    wizard_step_retention
    wizard_summary
    write_config
    initialize_system
    wizard_complete
}

# Entry point when called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_init_wizard
fi
