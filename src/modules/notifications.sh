#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Notifications Module
#  Desktop notifications, sound playback, and backup reports.
#  Handles X11/Wayland, root→user session bridging, PipeWire/
#  PulseAudio detection, and headless fallback via wall(1).
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Source shared utilities ───────────────────────────────────
source "${SYSBACKUP_LIB_DIR:-/usr/local/lib/sysbackup}/modules/utils.sh"

# ── Module Constants ──────────────────────────────────────────
readonly NOTIFICATIONS_VERSION="1.0.0"
readonly DEFAULT_NOTIFY_TIMEOUT=10000  # 10 seconds in milliseconds
readonly APP_NAME="SystemBackup"

# ── Notification Icons ────────────────────────────────────────
readonly ICON_SUCCESS="dialog-information"
readonly ICON_ERROR="dialog-error"
readonly ICON_WARNING="dialog-warning"
readonly ICON_BACKUP="drive-harddisk"

# ═══════════════════════════════════════════════════════════════
#  SESSION DETECTION
# ═══════════════════════════════════════════════════════════════

# Detect the active desktop user and their session environment
# Sets: _NOTIFY_USER, _NOTIFY_UID, _NOTIFY_DISPLAY, _NOTIFY_DBUS
# This is critical when running from a root systemd service that
# needs to send notifications to the logged-in desktop user.
_detect_session() {
    # If we're already running as a regular user with a display, use it
    if [[ $EUID -ne 0 && (-n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}") ]]; then
        _NOTIFY_USER=$(whoami)
        _NOTIFY_UID=$(id -u)
        _NOTIFY_DISPLAY="${DISPLAY:-${WAYLAND_DISPLAY:-}}"
        _NOTIFY_DBUS="${DBUS_SESSION_BUS_ADDRESS:-}"
        log_debug "Session detected (current user): user=$_NOTIFY_USER display=$_NOTIFY_DISPLAY"
        return 0
    fi

    # Running as root — need to find the active desktop user
    _NOTIFY_USER=$(get_active_user_name)
    if [[ -z "$_NOTIFY_USER" ]]; then
        log_debug "No active desktop user found via loginctl"
        _NOTIFY_USER=""
        _NOTIFY_UID=""
        _NOTIFY_DISPLAY=""
        _NOTIFY_DBUS=""
        return 1
    fi

    _NOTIFY_UID=$(id -u "$_NOTIFY_USER" 2>/dev/null || echo "")
    if [[ -z "$_NOTIFY_UID" ]]; then
        log_debug "Could not resolve UID for user: $_NOTIFY_USER"
        return 1
    fi

    # Find the user's D-Bus session bus address
    # Method 1: Read from the user's runtime directory
    _NOTIFY_DBUS=""
    local runtime_dir="/run/user/${_NOTIFY_UID}"
    if [[ -S "${runtime_dir}/bus" ]]; then
        _NOTIFY_DBUS="unix:path=${runtime_dir}/bus"
    fi

    # Method 2: Check the user's environment in /proc
    if [[ -z "$_NOTIFY_DBUS" ]]; then
        local user_pid
        user_pid=$(pgrep -u "$_NOTIFY_UID" -x "dbus-daemon" 2>/dev/null | head -1 || true)
        if [[ -z "$user_pid" ]]; then
            # Try finding any process of the user
            user_pid=$(pgrep -u "$_NOTIFY_UID" 2>/dev/null | head -1 || true)
        fi
        if [[ -n "$user_pid" && -r "/proc/$user_pid/environ" ]]; then
            _NOTIFY_DBUS=$(tr '\0' '\n' < "/proc/$user_pid/environ" 2>/dev/null | \
                grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1 | cut -d= -f2- || true)
        fi
    fi

    # Find the user's DISPLAY or WAYLAND_DISPLAY
    _NOTIFY_DISPLAY=""
    # Try loginctl to find the display
    local session_id
    session_id=$(loginctl list-sessions --no-legend 2>/dev/null | \
        awk -v user="$_NOTIFY_USER" '$3 == user {print $1; exit}' || true)

    if [[ -n "$session_id" ]]; then
        # Check session type
        local session_type
        session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || echo "")

        if [[ "$session_type" == "wayland" ]]; then
            _NOTIFY_DISPLAY=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null || echo "")
            if [[ -z "$_NOTIFY_DISPLAY" ]]; then
                _NOTIFY_DISPLAY="wayland-0"
            fi
        elif [[ "$session_type" == "x11" ]]; then
            _NOTIFY_DISPLAY=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null || echo ":0")
        fi
    fi

    # Fallback display detection from /proc
    if [[ -z "$_NOTIFY_DISPLAY" ]]; then
        local user_pid
        user_pid=$(pgrep -u "$_NOTIFY_UID" 2>/dev/null | head -1 || true)
        if [[ -n "$user_pid" && -r "/proc/$user_pid/environ" ]]; then
            _NOTIFY_DISPLAY=$(tr '\0' '\n' < "/proc/$user_pid/environ" 2>/dev/null | \
                grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' | head -1 | cut -d= -f2- || true)
        fi
    fi

    if [[ -n "$_NOTIFY_USER" && -n "$_NOTIFY_DBUS" ]]; then
        log_debug "Session detected (from root): user=$_NOTIFY_USER uid=$_NOTIFY_UID display=$_NOTIFY_DISPLAY"
        return 0
    else
        log_debug "Incomplete session detection: user=$_NOTIFY_USER dbus=${_NOTIFY_DBUS:-<empty>}"
        return 1
    fi
}

# Run a command as the desktop user with proper environment
# Usage: _run_as_user <command> [args...]
_run_as_user() {
    local -a cmd=("$@")

    # If we're already the right user, just run it
    if [[ $EUID -ne 0 ]]; then
        env \
            DISPLAY="${_NOTIFY_DISPLAY:-${DISPLAY:-}}" \
            WAYLAND_DISPLAY="${_NOTIFY_DISPLAY:-${WAYLAND_DISPLAY:-}}" \
            DBUS_SESSION_BUS_ADDRESS="${_NOTIFY_DBUS:-${DBUS_SESSION_BUS_ADDRESS:-}}" \
            "${cmd[@]}"
        return $?
    fi

    # Running as root — use sudo -u or runuser to switch
    if [[ -z "${_NOTIFY_USER:-}" ]]; then
        log_debug "No user context available to run command"
        return 1
    fi

    local run_cmd
    if check_command runuser; then
        run_cmd="runuser"
    elif check_command sudo; then
        run_cmd="sudo"
    else
        log_warn "Neither runuser nor sudo available"
        return 1
    fi

    local -a env_vars=(
        "DISPLAY=${_NOTIFY_DISPLAY:-}"
        "WAYLAND_DISPLAY=${_NOTIFY_DISPLAY:-}"
        "DBUS_SESSION_BUS_ADDRESS=${_NOTIFY_DBUS:-}"
        "XDG_RUNTIME_DIR=/run/user/${_NOTIFY_UID:-}"
    )

    if [[ "$run_cmd" == "runuser" ]]; then
        env "${env_vars[@]}" runuser -u "$_NOTIFY_USER" -- "${cmd[@]}"
    else
        sudo -u "$_NOTIFY_USER" env "${env_vars[@]}" "${cmd[@]}"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  MAIN NOTIFICATION DISPATCHER
# ═══════════════════════════════════════════════════════════════

# Send a desktop notification
# Usage: send_notification <title> <body> [icon] [urgency]
# urgency: low, normal, critical
send_notification() {
    local title="${1:?Usage: send_notification <title> <body> [icon] [urgency]}"
    local body="${2:-}"
    local icon="${3:-$ICON_BACKUP}"
    local urgency="${4:-normal}"

    # Check if notifications are enabled
    local notify_enabled
    notify_enabled=$(config_get "NOTIFY_ENABLED" "true")
    if [[ "$notify_enabled" != "true" ]]; then
        log_debug "Notifications disabled in config"
        return 0
    fi

    log_debug "Sending notification: [$urgency] $title"

    # Detect session for proper user/display targeting
    local session_ok=false
    if _detect_session; then
        session_ok=true
    fi

    # Try notify-send first
    if [[ "$session_ok" == "true" ]] && check_command notify-send; then
        if _run_as_user notify-send \
            --app-name="$APP_NAME" \
            --urgency="$urgency" \
            --icon="$icon" \
            --expire-time="$DEFAULT_NOTIFY_TIMEOUT" \
            "$title" \
            "$body" 2>/dev/null; then
            log_debug "Notification sent via notify-send"
            return 0
        else
            log_debug "notify-send failed, trying fallbacks"
        fi
    fi

    # Fallback: Try kdialog (KDE)
    if [[ "$session_ok" == "true" ]] && check_command kdialog; then
        local kdialog_type="--passivepopup"
        if _run_as_user kdialog \
            --title "$title" \
            "$kdialog_type" "$body" 10 2>/dev/null; then
            log_debug "Notification sent via kdialog"
            return 0
        fi
    fi

    # Fallback: Try zenity (GNOME)
    if [[ "$session_ok" == "true" ]] && check_command zenity; then
        _run_as_user zenity \
            --notification \
            --text="$title: $body" 2>/dev/null &
        log_debug "Notification sent via zenity"
        return 0
    fi

    # Final fallback: wall message (broadcast to all terminals)
    if check_command wall; then
        echo "[${APP_NAME}] $title: $body" | wall 2>/dev/null || true
        log_debug "Notification sent via wall"
        return 0
    fi

    # Log as last resort
    log_info "[NOTIFICATION] [$urgency] $title: $body"
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  CONVENIENCE NOTIFICATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════

# Send a success notification
# Usage: send_success_notification <summary_text>
send_success_notification() {
    local summary="${1:?Usage: send_success_notification <summary_text>}"

    local notify_on_success
    notify_on_success=$(config_get "NOTIFY_ON_SUCCESS" "true")
    if [[ "$notify_on_success" != "true" ]]; then
        log_debug "Success notifications disabled"
        return 0
    fi

    send_notification \
        "✅ Backup Successful" \
        "$summary" \
        "$ICON_SUCCESS" \
        "normal"

    # Play success sound if enabled
    local sound_enabled
    sound_enabled=$(config_get "NOTIFY_SOUND_ENABLED" "false")
    if [[ "$sound_enabled" == "true" ]]; then
        local sound_file
        sound_file=$(config_get "NOTIFY_SOUND_SUCCESS" "")
        if [[ -n "$sound_file" ]]; then
            play_sound "$sound_file"
        fi
    fi
}

# Send a failure notification
# Usage: send_failure_notification <error_text>
send_failure_notification() {
    local error_text="${1:?Usage: send_failure_notification <error_text>}"

    local notify_on_failure
    notify_on_failure=$(config_get "NOTIFY_ON_FAILURE" "true")
    if [[ "$notify_on_failure" != "true" ]]; then
        log_debug "Failure notifications disabled"
        return 0
    fi

    send_notification \
        "❌ Backup Failed" \
        "$error_text" \
        "$ICON_ERROR" \
        "critical"

    # Play error sound if enabled
    local sound_enabled
    sound_enabled=$(config_get "NOTIFY_SOUND_ENABLED" "false")
    if [[ "$sound_enabled" == "true" ]]; then
        local sound_file
        sound_file=$(config_get "NOTIFY_SOUND_ERROR" "")
        if [[ -n "$sound_file" ]]; then
            play_sound "$sound_file"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
#  SOUND PLAYBACK
# ═══════════════════════════════════════════════════════════════

# Play a notification sound file
# Auto-detects PipeWire (pw-play) vs PulseAudio (paplay) vs ALSA (aplay)
# Runs as the desktop user to use their audio session
# Usage: play_sound <sound_file>
play_sound() {
    local sound_file="${1:?Usage: play_sound <sound_file>}"

    # Check if the sound file exists
    if [[ ! -f "$sound_file" ]]; then
        log_debug "Sound file not found: $sound_file"
        return 0
    fi

    # Detect session if not already done
    _detect_session 2>/dev/null || true

    # Detect sound system and play
    local sound_system
    sound_system=$(detect_sound_system)

    log_debug "Playing sound via $sound_system: $sound_file"

    case "$sound_system" in
        pipewire)
            _run_as_user pw-play "$sound_file" 2>/dev/null &
            ;;
        pulseaudio)
            _run_as_user paplay "$sound_file" 2>/dev/null &
            ;;
        alsa)
            _run_as_user aplay "$sound_file" 2>/dev/null &
            ;;
        *)
            log_debug "No sound system available — skipping sound"
            return 0
            ;;
    esac

    # Don't wait for sound to finish — fire and forget
    disown 2>/dev/null || true
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  BACKUP REPORT NOTIFICATION
# ═══════════════════════════════════════════════════════════════

# Send a beautifully formatted backup report notification
# Usage: send_backup_report <health_score> <report_text>
# health_score: 0-100 integer
send_backup_report() {
    local health_score="${1:?Usage: send_backup_report <health_score> <report_text>}"
    local report_text="${2:-}"

    # Determine icon and urgency based on health score
    local icon urgency health_label
    if [[ "$health_score" -ge 90 ]]; then
        icon="$ICON_SUCCESS"
        urgency="normal"
        health_label="Excellent"
    elif [[ "$health_score" -ge 70 ]]; then
        icon="$ICON_WARNING"
        urgency="normal"
        health_label="Good"
    elif [[ "$health_score" -ge 50 ]]; then
        icon="$ICON_WARNING"
        urgency="normal"
        health_label="Fair"
    else
        icon="$ICON_ERROR"
        urgency="critical"
        health_label="Poor"
    fi

    # Build a formatted notification body
    local body
    body=$(printf "Health: %s (%d/100)\n%s" "$health_label" "$health_score" "$report_text")

    # Build title with health score bar
    local title
    title=$(printf "📊 Backup Report — %s (%d%%)" "$health_label" "$health_score")

    send_notification "$title" "$body" "$icon" "$urgency"

    # Play appropriate sound
    local sound_enabled
    sound_enabled=$(config_get "NOTIFY_SOUND_ENABLED" "false")
    if [[ "$sound_enabled" == "true" ]]; then
        local sound_file
        if [[ "$health_score" -ge 70 ]]; then
            sound_file=$(config_get "NOTIFY_SOUND_SUCCESS" "")
        else
            sound_file=$(config_get "NOTIFY_SOUND_ERROR" "")
        fi
        if [[ -n "$sound_file" ]]; then
            play_sound "$sound_file"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
#  MODULE SELF-TEST
# ═══════════════════════════════════════════════════════════════

_notifications_loaded() {
    log_debug "Notifications module v${NOTIFICATIONS_VERSION} loaded"
}

_notifications_loaded
