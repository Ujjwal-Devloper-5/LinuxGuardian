# SystemBackup: Advanced AI-Powered Disaster Recovery

**SystemBackup** is an enterprise-grade, AI-monitored, and high-speed backup solution designed specifically for Linux power users. It leverages the power of **Restic** for encryption and deduplication, and **Rclone** for multi-cloud synchronization, all orchestrated by a smart, self-healing AI engine.

---

## Key Features

- **Zero-Knowledge Encryption** - Data is encrypted locally before it ever leaves your machine.
- **High-Speed Cloud Sync** - Leverages custom Google API Client IDs for maximum MiB/s throughput.
- **AI-Powered Monitoring** - 
  - **Anomaly Detection**: Statistical Z-score analysis to detect ransomware or data loss.
  - **Predictive Storage**: Regression-based analysis to predict disk-full dates.
  - **Smart Scheduling**: Defer backups automatically when the system is under heavy load.
- **Dual-Tier Vaults** - Clean separation of Personal Data (/home) and System OS State (/).
- **Elite Recovery Suite** - Interactive restore utility with support for full system recovery and selective file retrieval.
- **Systemd Native** - Fully automated background daemons and timers.

---

## Project Structure

```text
Project SystemBackup/
|-- assets/             # Icons and notification sounds
|-- config/             # Configuration templates and exclude lists
|-- docs/               # In-depth Manual and Restore Guide
|-- src/                # Core Logic
|   |-- ai/             # AI & Statistical modules
|   |-- helpers/        # Python-based predictive scripts
|   |-- modules/        # Bash-based engine modules
|   `-- sysbackup-cli.sh # The main user interface
|-- systemd/            # Systemd service and timer units
|-- tests/              # Integrity and anomaly test suites
`-- install.sh          # One-command automated installer
```

---

## Installation & Setup

### 1. Prerequisites
Ensure you have the following installed (Arch Linux example):
```bash
sudo pacman -S restic rclone jq bc python
```

### 2. Fast Install
```bash
git clone https://github.com/your-repo/Project-SystemBackup.git
cd Project-SystemBackup
sudo ./install.sh
```

### 3. Initialize
```bash
sudo sysbackup init
```
*Follow the wizard to set up your encryption password and Google Drive integration.*

---

## Usage

| Command | Description |
| :--- | :--- |
| `sysbackup run --home` | Trigger an immediate personal data backup |
| `sysbackup run --system` | Trigger a full system configuration backup |
| `sysbackup status` | View the real-time AI health dashboard |
| `sysbackup restore` | Launch the interactive recovery orchestrator |
| `sysbackup health` | View a detailed AI diagnostic report |

---

## Licensing

This project is licensed under the **Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)** license.

- **Personal Use**: Allowed and encouraged.
- **Commercial Use**: Forbidden.
- **Sale/Distribution for Profit**: Forbidden.
- **Work/Corporate Use**: Not licensed for professional work environments without permission.

---

## AUR Support (Future)
This project is designed to be compatible with `yay` and the Arch User Repository. A PKGBUILD is coming soon.

---
*Built with heart for the Linux Community.*
