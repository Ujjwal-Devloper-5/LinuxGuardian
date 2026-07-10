#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  SystemBackup — Installer
#  One-command install for any major Linux distribution.
#  Usage:  sudo bash install.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Resolve script location ──────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source utils for logging, banner, and helpers ─────────────
# During install, utils.sh lives in the source tree
export SYSBACKUP_LIB_DIR="${SCRIPT_DIR}/src"
source "${SCRIPT_DIR}/src/modules/utils.sh"

# ═══════════════════════════════════════════════════════════════
#  STEP 1 — Banner
# ═══════════════════════════════════════════════════════════════

print_banner
printf "${CLR_BOLD}   ── Installer ──${CLR_RESET}\n\n"

# ═══════════════════════════════════════════════════════════════
#  STEP 2 — Root Check
# ═══════════════════════════════════════════════════════════════

if [[ $EUID -ne 0 ]]; then
    log_error "This installer must be run as root."
    log_error "Usage: sudo bash install.sh"
    exit 1
fi

log_info "Running as root — OK"

# ═══════════════════════════════════════════════════════════════
#  STEP 3 — Detect Distro & Package Manager
# ═══════════════════════════════════════════════════════════════

log_section "Detecting System"

DISTRO=$(detect_distro)
PKG_MGR=$(detect_package_manager)
ARCH=$(uname -m)

log_info "Distribution : ${DISTRO}"
log_info "Package Mgr  : ${PKG_MGR}"
log_info "Architecture : ${ARCH}"

if [[ "$PKG_MGR" == "unknown" ]]; then
    log_error "Unsupported package manager. Install dependencies manually and re-run."
    exit 1
fi

# ── Helper: package install wrapper ──────────────────────────
pkg_install() {
    local packages=("$@")
    case "$PKG_MGR" in
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm --needed "${packages[@]}"
            ;;
        dnf)
            dnf install -y -q "${packages[@]}"
            ;;
        zypper)
            zypper install -y -n "${packages[@]}"
            ;;
    esac
}

# ── Helper: map package names across distros ─────────────────
map_package_name() {
    local generic="$1"
    case "$generic" in
        libnotify)
            case "$PKG_MGR" in
                apt)    echo "libnotify-bin" ;;
                pacman) echo "libnotify" ;;
                dnf)    echo "libnotify" ;;
                zypper) echo "libnotify-tools" ;;
            esac
            ;;
        xprintidle)
            case "$PKG_MGR" in
                apt)    echo "xprintidle" ;;
                pacman) echo "xprintidle" ;;
                dnf)    echo "xprintidle" ;;
                zypper) echo "xprintidle" ;;
            esac
            ;;
        *)
            echo "$generic"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  STEP 4 — Install Dependencies
# ═══════════════════════════════════════════════════════════════

log_section "Installing Dependencies"

# ── 4a. Required packages ─────────────────────────────────────
REQUIRED_PKGS=(restic rclone jq bc)
log_info "Installing required packages: ${REQUIRED_PKGS[*]}"
pkg_install "${REQUIRED_PKGS[@]}" || {
    log_error "Failed to install required packages."
    exit 1
}
log_success "Required packages installed"

# ── 4b. Optional packages (best-effort) ──────────────────────
log_info "Installing optional packages (failures are non-fatal)..."

OPTIONAL_GENERIC=(fzf xprintidle libnotify)
for pkg_generic in "${OPTIONAL_GENERIC[@]}"; do
    pkg_name=$(map_package_name "$pkg_generic")
    log_info "  → ${pkg_name}..."
    pkg_install "$pkg_name" 2>/dev/null || log_warn "  Could not install ${pkg_name} — skipping"
done

# ── 4c. Gum — download binary from GitHub ────────────────────
if ! command -v gum &>/dev/null; then
    log_info "Installing gum (terminal UI tool)..."

    GUM_VERSION="0.14.5"

    # Map architecture to gum naming convention
    case "$ARCH" in
        x86_64|amd64)  GUM_ARCH="x86_64"  ;;
        aarch64|arm64) GUM_ARCH="arm64"    ;;
        armv7l|armhf)  GUM_ARCH="armv7"    ;;
        i686|i386)     GUM_ARCH="i386"     ;;
        *)
            log_warn "Unsupported architecture ($ARCH) for gum binary — skipping"
            GUM_ARCH=""
            ;;
    esac

    if [[ -n "$GUM_ARCH" ]]; then
        GUM_URL="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"
        GUM_TMP=$(mktemp -d)

        if curl -fsSL "$GUM_URL" -o "${GUM_TMP}/gum.tar.gz" 2>/dev/null; then
            tar -xzf "${GUM_TMP}/gum.tar.gz" -C "$GUM_TMP" 2>/dev/null
            # The tarball extracts into a directory; find the binary
            GUM_BIN=$(find "$GUM_TMP" -name "gum" -type f -executable 2>/dev/null | head -1)
            if [[ -z "$GUM_BIN" ]]; then
                # Some tarballs have it at the top level without +x
                GUM_BIN=$(find "$GUM_TMP" -name "gum" -type f 2>/dev/null | head -1)
            fi
            if [[ -n "$GUM_BIN" ]]; then
                install -m 755 "$GUM_BIN" /usr/local/bin/gum
                log_success "gum ${GUM_VERSION} installed to /usr/local/bin/gum"
            else
                log_warn "Could not locate gum binary in archive — skipping"
            fi
        else
            log_warn "Could not download gum from GitHub — skipping"
        fi

        rm -rf "$GUM_TMP"
    fi
else
    log_info "gum already installed: $(command -v gum)"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 5 — Create Directory Structure
# ═══════════════════════════════════════════════════════════════

log_section "Creating Directory Structure"

# Library directories
install -d -m 755 /usr/local/lib/sysbackup/modules
install -d -m 755 /usr/local/lib/sysbackup/ai
install -d -m 755 /usr/local/lib/sysbackup/helpers
log_info "Created /usr/local/lib/sysbackup/{modules,ai,helpers}"

# Config directory
install -d -m 755 /etc/sysbackup
log_info "Created /etc/sysbackup"

# Data directories
install -d -m 750 /var/lib/sysbackup
install -d -m 750 /var/lib/sysbackup/data
install -d -m 750 /var/lib/sysbackup/logs
install -d -m 700 /var/lib/sysbackup/repos
install -d -m 750 /var/lib/sysbackup/cache
install -d -m 750 /var/lib/sysbackup/config
log_info "Created /var/lib/sysbackup/{data,logs,repos,cache,config}"

# Sound directory
install -d -m 755 /usr/share/sysbackup/sounds
log_info "Created /usr/share/sysbackup/sounds"

log_success "Directory structure ready"

# ═══════════════════════════════════════════════════════════════
#  STEP 6 — Copy Source Files
# ═══════════════════════════════════════════════════════════════

log_section "Installing Source Files"

# ── 6a. Module scripts ────────────────────────────────────────
if compgen -G "${SCRIPT_DIR}/src/modules/"*.sh >/dev/null 2>&1; then
    install -m 644 "${SCRIPT_DIR}"/src/modules/*.sh /usr/local/lib/sysbackup/modules/
    log_info "Installed modules → /usr/local/lib/sysbackup/modules/"
else
    log_warn "No module scripts found in src/modules/"
fi

# ── 6b. AI scripts ───────────────────────────────────────────
if compgen -G "${SCRIPT_DIR}/src/ai/"*.sh >/dev/null 2>&1; then
    install -m 644 "${SCRIPT_DIR}"/src/ai/*.sh /usr/local/lib/sysbackup/ai/
    log_info "Installed AI modules → /usr/local/lib/sysbackup/ai/"
else
    log_warn "No AI scripts found in src/ai/ — skipping"
fi

# ── 6c. Helper scripts ───────────────────────────────────────
if compgen -G "${SCRIPT_DIR}/src/helpers/"*.py >/dev/null 2>&1; then
    install -m 644 "${SCRIPT_DIR}"/src/helpers/*.py /usr/local/lib/sysbackup/helpers/
    log_info "Installed helpers → /usr/local/lib/sysbackup/helpers/"
else
    log_warn "No helper scripts found in src/helpers/ — skipping"
fi

# ── 6d. Main entry point (CLI) ───────────────────────────────
# The CLI script is the main entry point (/usr/local/bin/sysbackup)
if [[ -f "${SCRIPT_DIR}/src/sysbackup-cli.sh" ]]; then
    install -m 755 "${SCRIPT_DIR}/src/sysbackup-cli.sh" /usr/local/bin/sysbackup
    log_info "Installed CLI → /usr/local/bin/sysbackup"
elif [[ -f "${SCRIPT_DIR}/src/sysbackup.sh" ]]; then
    # Fallback: use sysbackup.sh if CLI doesn't exist yet
    install -m 755 "${SCRIPT_DIR}/src/sysbackup.sh" /usr/local/bin/sysbackup
    log_info "Installed entry point → /usr/local/bin/sysbackup"
else
    log_warn "No entry point found (src/sysbackup-cli.sh or src/sysbackup.sh) — skipping"
    log_warn "You will need to install the sysbackup binary manually."
fi

log_success "Source files installed"

# ═══════════════════════════════════════════════════════════════
#  STEP 7 — Copy Config Files
# ═══════════════════════════════════════════════════════════════

log_section "Installing Configuration"

# Example config (never overwrite user's existing config)
if [[ -f "${SCRIPT_DIR}/config/sysbackup.conf.example" ]]; then
    install -m 640 "${SCRIPT_DIR}/config/sysbackup.conf.example" /etc/sysbackup/sysbackup.conf.example
    log_info "Installed example config → /etc/sysbackup/sysbackup.conf.example"

    # If no live config exists, copy the example as default
    if [[ ! -f /etc/sysbackup/sysbackup.conf ]]; then
        install -m 640 "${SCRIPT_DIR}/config/sysbackup.conf.example" /etc/sysbackup/sysbackup.conf
        log_info "Created default config → /etc/sysbackup/sysbackup.conf"
    else
        log_info "Existing config preserved: /etc/sysbackup/sysbackup.conf"
    fi
fi

# Exclude lists
if compgen -G "${SCRIPT_DIR}/config/exclude-"*.txt >/dev/null 2>&1; then
    install -m 640 "${SCRIPT_DIR}"/config/exclude-*.txt /etc/sysbackup/
    log_info "Installed exclude lists → /etc/sysbackup/"
fi

# Importance config
if [[ -f "${SCRIPT_DIR}/config/importance.conf" ]]; then
    install -m 640 "${SCRIPT_DIR}/config/importance.conf" /etc/sysbackup/importance.conf
    log_info "Installed importance config → /etc/sysbackup/importance.conf"
fi

log_success "Configuration files installed"

# ═══════════════════════════════════════════════════════════════
#  STEP 8 — Copy systemd Units
# ═══════════════════════════════════════════════════════════════

log_section "Installing systemd Units"

if compgen -G "${SCRIPT_DIR}/systemd/sysbackup-"*.service >/dev/null 2>&1 || \
   compgen -G "${SCRIPT_DIR}/systemd/sysbackup-"*.timer >/dev/null 2>&1; then

    for unit_file in "${SCRIPT_DIR}"/systemd/sysbackup-*.{service,timer}; do
        [[ -f "$unit_file" ]] || continue
        install -m 644 "$unit_file" /etc/systemd/system/
        log_info "Installed $(basename "$unit_file") → /etc/systemd/system/"
    done

    log_success "systemd units installed"
else
    log_warn "No systemd unit files found in systemd/ — skipping"
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 9 — Copy Sound Files
# ═══════════════════════════════════════════════════════════════

log_section "Installing Sound Files"

SOUNDS_INSTALLED=0

if [[ -d "${SCRIPT_DIR}/assets/sounds" ]] && compgen -G "${SCRIPT_DIR}/assets/sounds/"* >/dev/null 2>&1; then
    for sound_file in "${SCRIPT_DIR}"/assets/sounds/*; do
        [[ -f "$sound_file" ]] || continue
        install -m 644 "$sound_file" /usr/share/sysbackup/sounds/
        ((SOUNDS_INSTALLED++))
    done
    log_info "Installed ${SOUNDS_INSTALLED} sound file(s) → /usr/share/sysbackup/sounds/"
fi

# Set up system sound fallbacks
SYSTEM_SOUND_DIR="/usr/share/sounds/freedesktop/stereo"
if [[ -d "$SYSTEM_SOUND_DIR" ]]; then
    # Symlink system sounds as fallbacks if custom sounds are missing
    if [[ ! -f /usr/share/sysbackup/sounds/complete.oga ]] && [[ -f "${SYSTEM_SOUND_DIR}/complete.oga" ]]; then
        ln -sf "${SYSTEM_SOUND_DIR}/complete.oga" /usr/share/sysbackup/sounds/complete.oga
        log_info "Linked fallback sound: complete.oga"
    fi
    if [[ ! -f /usr/share/sysbackup/sounds/dialog-warning.oga ]] && [[ -f "${SYSTEM_SOUND_DIR}/dialog-warning.oga" ]]; then
        ln -sf "${SYSTEM_SOUND_DIR}/dialog-warning.oga" /usr/share/sysbackup/sounds/dialog-warning.oga
        log_info "Linked fallback sound: dialog-warning.oga"
    fi
    if [[ ! -f /usr/share/sysbackup/sounds/dialog-error.oga ]] && [[ -f "${SYSTEM_SOUND_DIR}/dialog-error.oga" ]]; then
        ln -sf "${SYSTEM_SOUND_DIR}/dialog-error.oga" /usr/share/sysbackup/sounds/dialog-error.oga
        log_info "Linked fallback sound: dialog-error.oga"
    fi
else
    log_warn "FreeDesktop sound directory not found — no fallback sounds linked"
fi

log_success "Sound files installed"

# ═══════════════════════════════════════════════════════════════
#  STEP 10 — Set Permissions
# ═══════════════════════════════════════════════════════════════

log_section "Setting Permissions"

# Repo directory must be tightly locked (contains restic repos)
chmod 700 /var/lib/sysbackup/repos
log_info "Set /var/lib/sysbackup/repos → 700"

# Data directories — root group readable
chmod 750 /var/lib/sysbackup/data /var/lib/sysbackup/logs \
          /var/lib/sysbackup/cache /var/lib/sysbackup/config
log_info "Set data directories → 750"

# Config files — owner+group readable
find /etc/sysbackup -type f -exec chmod 640 {} \;
log_info "Set /etc/sysbackup/* → 640"

log_success "Permissions configured"

# ═══════════════════════════════════════════════════════════════
#  STEP 11 — Reload systemd
# ═══════════════════════════════════════════════════════════════

log_section "Reloading systemd"

systemctl daemon-reload
log_success "systemd daemon reloaded"

# ═══════════════════════════════════════════════════════════════
#  STEP 12 — Print Success
# ═══════════════════════════════════════════════════════════════

printf "\n"
log_section "Installation Complete!"
printf "\n"
printf "${CLR_GREEN}  ✅  SystemBackup v%s has been installed successfully!${CLR_RESET}\n\n" "$SYSBACKUP_VERSION"

printf "${CLR_BOLD}  Installed locations:${CLR_RESET}\n"
printf "    Binary     : /usr/local/bin/sysbackup\n"
printf "    Libraries  : /usr/local/lib/sysbackup/\n"
printf "    Config     : /etc/sysbackup/\n"
printf "    Data       : /var/lib/sysbackup/\n"
printf "    Sounds     : /usr/share/sysbackup/sounds/\n"
printf "    Units      : /etc/systemd/system/sysbackup-*\n\n"

printf "${CLR_BOLD}  Next steps:${CLR_RESET}\n"
printf "    1. Edit your config:  ${CLR_CYAN}sudo nano /etc/sysbackup/sysbackup.conf${CLR_RESET}\n"
printf "    2. Initialize repos:  ${CLR_CYAN}sudo sysbackup init${CLR_RESET}\n"
printf "    3. Enable timers:\n"
printf "       ${CLR_CYAN}sudo systemctl enable --now sysbackup-home.timer${CLR_RESET}\n"
printf "       ${CLR_CYAN}sudo systemctl enable --now sysbackup-system.timer${CLR_RESET}\n"
printf "       ${CLR_CYAN}sudo systemctl enable --now sysbackup-monitor.timer${CLR_RESET}\n"
printf "    4. Run your first backup:  ${CLR_CYAN}sudo sysbackup run --home${CLR_RESET}\n\n"

printf "${CLR_DIM}  For help: sysbackup --help${CLR_RESET}\n\n"
