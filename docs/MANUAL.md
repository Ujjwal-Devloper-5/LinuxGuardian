---
title: SystemBackup — Advanced AI-Powered Disaster Recovery
author: Ujjwal
---

# SystemBackup: The Ultimate Administrator's Manual

Welcome to **SystemBackup**, a highly sophisticated, AI-driven disaster recovery and system monitoring ecosystem. Designed for modern Linux environments, it goes far beyond traditional backup scripts by incorporating predictive AI, idle-aware scheduling, and zero-trust encryption.

---

## 1. Architectural Overview

SystemBackup utilizes a rigorous, production-grade **8-Phase Pipeline** for every backup execution to ensure absolute data integrity.

### The 8-Phase Pipeline
1. **Pre-flight**: Validates configurations, checks required dependencies (`restic`, `rclone`, `python3`), ensures repository initialization, and acquires system-wide locks to prevent data corruption.
2. **Idle Detection**: Checks CPU and IO load. If the system is busy, it safely defers the backup (up to 6 hours) to prevent desktop lag.
3. **Execution**: Leverages the **Restic** engine for heavily deduplicated, encrypted backups. Operates a dual-tier strategy: `home` (daily) and `system` (weekly). Real-time IO throttling (`ionice`) keeps performance snappy.
4. **AI Analysis**: Runs anomaly detection, integrity verification, log trend analysis, and storage prediction.
5. **Cloud Sync**: Uses **Rclone** with exponential backoff to sync local encrypted snapshots securely to the cloud.
6. **Retention (GFS)**: Implements Grandfather-Father-Son pruning, ensuring you keep just the right amount of daily, weekly, monthly, and yearly backups.
7. **Notification**: Generates a unified "Health Score" (0-100) and dispatches a detailed report.
8. **Cleanup**: Rotates logs intelligently (by age and >10MB size limits) and releases locks.

---

## 2. The AI Suite: Predictive & Proactive Maintenance

SystemBackup actively works to prevent silent data failure using machine learning and statistical modeling located in the `src/ai/` suite.

* **Anomaly Detection (`anomaly_detect.sh`)**  
  Uses Z-scores to identify "statistically unusual" backup sizes. For instance, if your backup is typically 1GB and suddenly spikes to 50GB, it flags a CRITICAL anomaly—warning you of potential data bloat or ransomware encryption.
* **Storage Prediction (`predict_storage.sh`)**  
  Analyzes historical usage trends via regression logic to calculate the exact number of days remaining before your backup drive reaches capacity.
* **Health Scoring (`health_score.sh`)**  
  Aggregates Z-scores, integrity verifications, and storage availability into a definitive letter grade (A-F), so you know your backup state at a glance.

---

## 3. Security & Cloud Synchronization

**Zero-Knowledge Encryption**  
SystemBackup is encrypted-by-design. Because it uses Restic as its core engine, all data is encrypted locally *before* it is ever written to disk or sent to the cloud.
* **No Plaintext Risk:** Even if a cloud provider (e.g., Google Drive, AWS S3) is compromised, attackers only see encrypted data blobs.
* **Least Privilege:** Home backups can be configured in systemd to run under standard user permissions instead of root.

**Cloud Features**
* Multi-cloud support via Rclone (S3, B2, GDrive, OneDrive, Dropbox).
* Syncs are verified with strict checksums, never just file timestamps.
* Network resilience: Exponential backoff automatically handles dropped internet connections.

---

## 4. Installation & Initial Setup

SystemBackup comes with an interactive wizard for a smooth installation experience.

### Step 1: Install Dependencies
SystemBackup will verify dependencies automatically, but ensure you have the basics:
```bash
sudo apt update
sudo apt install restic rclone python3 jq bc
```

### Step 2: Run the Initialization Wizard
Run the initialization script from the source directory. This will guide you through setting up your repositories, encryption passwords, and cloud remotes.
```bash
./src/init-wizard.sh
```

### Step 3: Configure `sysbackup.conf`
The configuration file is generated at `/etc/sysbackup/sysbackup.conf`. 
Key variables to customize:
```ini
# Backup Sources
HOME_SOURCES="/home"
SYSTEM_SOURCES="/"

# AI Features
SMART_SCHEDULE_ENABLED=true
ANOMALY_DETECTION=true
STORAGE_PREDICTION=true

# Retention Policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
```

---

## 5. Usage & Commands

SystemBackup provides a clean CLI interface via `sysbackup-cli.sh`.

### Manual Backup Execution
To force a backup immediately (bypassing idle-detection if desired):
```bash
# Run Home Backup
sudo sysbackup run --home

# Run Full System Backup
sudo sysbackup run --system

# Run Both
sudo sysbackup run --all
```

### Automated Systemd Timers
SystemBackup installs systemd timers to handle everything in the background.
```bash
# Enable and start the daily home backup timer
sudo systemctl enable --now sysbackup-home.timer

# Enable and start the weekly system backup timer
sudo systemctl enable --now sysbackup-system.timer

# Check the status of your timers
systemctl list-timers | grep sysbackup
```

---

## 6. One-Click Restore Utility

Restoring data is frictionless thanks to the included **One-Click Restore** script (`src/sysbackup-restore.sh`).

1. Execute the restore script:
   ```bash
   ./src/sysbackup-restore.sh
   ```
2. **Select Repository:** Choose whether to restore from the Home (1) or System (2) repository.
3. **View Snapshots:** The utility automatically queries Restic and displays a clean table of all available snapshots.
4. **Select Target:** Enter the Snapshot ID and your desired target directory (e.g., `/tmp/restore-test`).
5. **Done!** The script securely retrieves your data and places it in the target directory.

---

## 7. Logs and Troubleshooting

If a backup fails, SystemBackup provides granular logs.
* **Log Location:** `/var/lib/sysbackup/logs/`
* **Log Rotation:** Logs are automatically rotated after 30 days. If any log exceeds 10MB due to continuous errors, it is safely truncated to the last 1MB to prevent disk bloat.
* **Testing AI Scripts:** You can independently test AI capabilities by running the test suite:
  ```bash
  ./tests/test_anomaly.sh
  ./tests/test_backup.sh
  ```

---
*Generated by Gemini CLI — 2026*
