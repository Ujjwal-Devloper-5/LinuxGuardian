#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Test: Anomaly Detection
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# Setup environment for testing
export SYSBACKUP_LIB_DIR="/tmp/linuxguardian-tests/lib"
export SYSBACKUP_DATA_DIR="/tmp/linuxguardian-tests/data"
mkdir -p "$SYSBACKUP_LIB_DIR/modules" "$SYSBACKUP_DATA_DIR/data"

cat > "$SYSBACKUP_LIB_DIR/modules/utils.sh" << 'EOF'
log_info() { echo "INFO: $*"; }
log_warn() { echo "WARN: $*"; }
log_error() { echo "ERROR: $*"; }
log_success() { echo "SUCCESS: $*"; }
record_metric() { echo "$2" >> "$1"; }
EOF

# Copy the actual script to test dir
cp "/home/ujjwal/Project LinuxGuardian/src/ai/anomaly_detect.sh" "$SYSBACKUP_LIB_DIR/anomaly_detect.sh"

echo "==> Mocking historical data..."
HISTORY_FILE="$SYSBACKUP_DATA_DIR/data/backup_sizes.log"

# Generate 30 normal backup sizes (around 1GB, varying slightly)
for i in {1..30}; do
    size=$((1000000000 + (RANDOM % 50000000) - 25000000))
    echo "16000000$i,home,$size,60,10" >> "$HISTORY_FILE"
done

echo "==> Sourcing anomaly module..."
source "$SYSBACKUP_LIB_DIR/anomaly_detect.sh"

echo "==> Testing Normal Size..."
NORMAL_SIZE=1010000000
check_anomaly "$NORMAL_SIZE"

echo "==> Testing CRITICAL Large Size (Ransomware/Duplication?)..."
LARGE_SIZE=1500000000
check_anomaly "$LARGE_SIZE"

echo "==> Testing CRITICAL Small Size (Data Loss?)..."
SMALL_SIZE=500000000
check_anomaly "$SMALL_SIZE"

echo "Cleaning up..."
rm -rf "/tmp/linuxguardian-tests"
echo "✅ Test complete!"
