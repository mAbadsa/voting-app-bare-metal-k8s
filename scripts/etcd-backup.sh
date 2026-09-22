#!/usr/bin/env bash
#
# etcd-backup.sh
# Takes an etcd snapshot, uploads it to S3, and prunes local backups
# older than RETENTION_DAYS. Intended to run on a control-plane node,
# via cron or a systemd timer.
#
# Usage: sudo ./etcd-backup.sh

set -euo pipefail

# ---- Configuration -----------------------------------------------------
BACKUP_DIR="/var/backups/etcd"
RETENTION_DAYS=7
S3_BUCKET="s3://my-etcd-backups-1790072037/$(hostname)"

ETCD_ENDPOINT="https://127.0.0.1:2379"
ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_FILE="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"
LOG_TAG="etcd-backup"
# -------------------------------------------------------------------------

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

fail() {
  log "ERROR: $*"
  exit 1
}

# Must run as root — needed to read etcd's certs and take the snapshot
if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root (use sudo)."
fi

# ---- 1. Ensure the backup directory exists -----------------------------
if [[ ! -d "$BACKUP_DIR" ]]; then
  log "Backup directory $BACKUP_DIR does not exist — creating it."
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
fi

# ---- 2. Take the etcd snapshot ------------------------------------------
log "Taking etcd snapshot -> $SNAPSHOT_FILE"

ETCDCTL_API=3 etcdctl snapshot save "$SNAPSHOT_FILE" \
  --endpoints="$ETCD_ENDPOINT" \
  --cacert="$ETCD_CACERT" \
  --cert="$ETCD_CERT" \
  --key="$ETCD_KEY" \
  || fail "etcdctl snapshot save failed."

# Sanity-check the snapshot is valid before trusting it
ETCDCTL_API=3 etcdctl snapshot status "$SNAPSHOT_FILE" --write-out=table \
  || fail "Snapshot status check failed — snapshot may be corrupt."

log "Snapshot created and verified successfully."

# ---- 3. Upload to S3 -----------------------------------------------------
if command -v aws >/dev/null 2>&1; then
  log "Uploading snapshot to $S3_BUCKET"
  aws s3 cp "$SNAPSHOT_FILE" "${S3_BUCKET}/" \
    || fail "Upload to S3 failed. Local snapshot retained at $SNAPSHOT_FILE."
  log "Upload complete."
else
  log "WARNING: aws CLI not found — skipping S3 upload. Install/configure the AWS CLI to enable off-node backups."
fi

# ---- 4. Prune local backups older than RETENTION_DAYS -------------------
log "Removing local backups older than ${RETENTION_DAYS} days."
find "$BACKUP_DIR" -name "*.db" -mtime "+${RETENTION_DAYS}" -print -delete

log "Backup cycle complete."
