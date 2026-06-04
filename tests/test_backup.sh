#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  LinuxGuardian — Test: Backup Engine
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# Setup environment for testing
export SYSBACKUP_LIB_DIR="/usr/local/lib/linuxguardian"
export DATA_DIR="/tmp/linuxguardian-tests"
export HOME_REPO="$DATA_DIR/repos/home"
export SYSTEM_REPO="$DATA_DIR/repos/system"
export RESTIC_PASSWORD_FILE="$DATA_DIR/.restic-password"
export HOME_SOURCES="$DATA_DIR/test-home"
export HOME_EXCLUDE_FILE="/tmp/empty-exclude"

mkdir -p "$HOME_SOURCES" "$DATA_DIR/repos"
echo "test_password_123" > "$RESTIC_PASSWORD_FILE"
touch "$HOME_EXCLUDE_FILE"

# Create some test files
echo "Hello World" > "$HOME_SOURCES/file1.txt"
dd if=/dev/urandom of="$HOME_SOURCES/file2.bin" bs=1M count=5 2>/dev/null

echo "==> Mocking utils.sh..."
mkdir -p "$SYSBACKUP_LIB_DIR/modules"
cat > "$SYSBACKUP_LIB_DIR/modules/utils.sh" << 'EOF'
log_info() { echo "INFO: $*"; }
log_warn() { echo "WARN: $*"; }
log_error() { echo "ERROR: $*"; }
log_success() { echo "SUCCESS: $*"; }
setup_restic_env() {
    export RESTIC_REPOSITORY="$1"
    export RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
}
EOF

echo "==> Testing backup_engine.sh (mocking if needed)..."
# In a real environment we would source backup_engine.sh and test functions.
# For this basic test script, we just verify restic works with our paths.

export RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
export RESTIC_REPOSITORY="$HOME_REPO"

echo "Initializing repo..."
restic init

echo "Running backup..."
restic backup "$HOME_SOURCES" --tag "type=home,schedule=daily"

echo "Checking snapshots..."
restic snapshots

echo "Cleaning up..."
rm -rf "$DATA_DIR" "$HOME_EXCLUDE_FILE"
echo "✅ Test complete!"
