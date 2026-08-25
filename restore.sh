#!/usr/bin/env bash
# Restore Forgejo + Headscale + stack configuration from Google Drive backups.
#
# Runs on the VPS as root (deployed to /opt/ia-stack/restore.sh by Ansible).
#
# Usage:
#   restore.sh                 # restore the most recent set of backups
#   restore.sh 20260824-103000 # restore the set with that timestamp
#
# What it restores (in order):
#   1. PostgreSQL database        (from pg_dump, the most reliable DB path)
#   2. Forgejo dump               (attachments, LFS, avatars)
#   3. Git repositories           (raw from Docker volume backup)
#   4. Headscale state            (database + config + ACL)
#   5. Stack config + secrets     (docker-compose.yml, .env, passwords)
#
# Backups are stored in timestamped folders under BACKUP_DIR:
#   20260824-133209/
#     forgejo-dump.tar.gz
#     forgejo-repos.tar.gz
#     forgejo-pg.sql.gz
#     headscale.tar.gz
#     stack-config.tar.gz
#
# By default it downloads missing dumps from the rclone remote first. Set
# RESTORE_OFFLINE=1 to use only the local backups directory.

set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ia-stack}"

# Derive the Compose project + container names from the server .env (set by
# Ansible), so prod and dev restore their own containers and bucket.
COMPOSE_PROJECT_NAME="$(grep '^COMPOSE_PROJECT_NAME=' "${STACK_DIR}/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ia-stack}"
FORGEJO_CONTAINER="${FORGEJO_CONTAINER:-${COMPOSE_PROJECT_NAME}-forgejo}"
FORGEJO_DB_CONTAINER="${FORGEJO_DB_CONTAINER:-${COMPOSE_PROJECT_NAME}-forgejo-db}"

# Resolve the forgejo-data volume mount point so files can be restored directly
# on the host, without needing the (possibly stopped) Forgejo container, and
# with correct UID 1000 (git) ownership.
FORGEJO_VOLUME="$(docker volume ls --format '{{.Name}}' | grep "${COMPOSE_PROJECT_NAME}_forgejo-data$" | head -n1 || true)"
FORGEJO_DATA_MOUNTPOINT=""
if [ -n "$FORGEJO_VOLUME" ]; then
  FORGEJO_DATA_MOUNTPOINT="$(docker volume inspect --format '{{.Mountpoint}}' "$FORGEJO_VOLUME" 2>/dev/null || true)"
fi

BACKUP_DIR="${BACKUP_DIR:-${STACK_DIR}/backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:forgejo-backups${COMPOSE_PROJECT_NAME#ia-stack}}"
STAMP="${1:-}"

# Pick up RCLONE_REMOTE override from the server-side .env (same as backup.sh).
if [ -f "${STACK_DIR}/.env" ]; then
  _env_rclone="$(grep '^RCLONE_REMOTE=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  [ -n "$_env_rclone" ] && RCLONE_REMOTE="$_env_rclone"
fi

# Download the latest backups from Google Drive unless told otherwise.
if [ -z "${RESTORE_OFFLINE:-}" ]; then
  if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE%%:*}:$"; then
    echo "==> Downloading backups from $RCLONE_REMOTE ..."
    rclone copy "$RCLONE_REMOTE" "$BACKUP_DIR"
  else
    echo "    rclone remote '${RCLONE_REMOTE%%:*}' not configured — using local $BACKUP_DIR only."
  fi
fi

# Resolve the newest dump of each kind (optionally filtered by STAMP).
# Backups are stored inside timestamped folders: backups/20260824-133209/forgejo-pg.sql.gz
pick() {
  local pattern="$1"
  if [ -n "$STAMP" ]; then
    find "$BACKUP_DIR" -name "$pattern" -path "*/$STAMP/*" 2>/dev/null | sort -r | head -n1 || true
  else
    find "$BACKUP_DIR" -name "$pattern" 2>/dev/null | sort -r | head -n1 || true
  fi
}

PG_DUMP="$(pick 'forgejo-pg.sql.gz')"
FORGEJO_DUMP="$(pick 'forgejo-dump.tar.gz')"
FORGEJO_REPOS="$(pick 'forgejo-repos.tar.gz')"
HEADSCALE_DUMP="$(pick 'headscale.tar.gz')"
CONFIG_DUMP="$(pick 'stack-config.tar.gz')"

echo "Using:"
echo "  PostgreSQL  : ${PG_DUMP:-<none>}"
echo "  Forgejo dump : ${FORGEJO_DUMP:-<none>}"
echo "  Repositories : ${FORGEJO_REPOS:-<none>}"
echo "  Headscale    : ${HEADSCALE_DUMP:-<none>}"
echo "  Stack secrets: ${CONFIG_DUMP:-<none>}"

if [ -z "$PG_DUMP" ] && [ -z "$FORGEJO_DUMP" ] && [ -z "$FORGEJO_REPOS" ] && [ -z "$HEADSCALE_DUMP" ]; then
  echo "ERROR: no backups found in $BACKUP_DIR." >&2
  exit 1
fi

# Pre-flight: verify every archive is a readable gzip BEFORE touching data.
echo "==> Verifying archives..."
CORRUPT=0
for _var in PG_DUMP FORGEJO_DUMP FORGEJO_REPOS HEADSCALE_DUMP CONFIG_DUMP; do
  _file="${!_var}"
  if [ -n "$_file" ]; then
    if [ -s "$_file" ] && gzip -t "$_file" 2>/dev/null; then
      echo "    OK   ${_var}: $(basename "$_file")"
    else
      echo "    BAD  ${_var}: $(basename "$_file") (missing, empty or not gzip)"
      CORRUPT=1
    fi
  fi
done
if [ "$CORRUPT" -eq 1 ]; then
  echo "    NOTE: BAD archives will be skipped by this restore."
  echo "    If the database depends on the repositories and this is the latest"
  echo "    backup, consider restoring an older set:"
  echo "      make restore STAMP=<older-timestamp>"
fi

# Destructive operation — require explicit confirmation when connected to a TTY.
if [ -t 0 ] && [ -z "${RESTORE_YES:-}" ]; then
  echo ""
  echo "⚠  This will DESTROY the current data and replace it with the backup above."
  echo "   Set RESTORE_YES=1 to skip this prompt."
  echo ""
  read -r -p "Type 'yes' to continue: " REPLY
  if [ "$REPLY" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ---- 1. PostgreSQL ---------------------------------------------------------
if [ -n "$PG_DUMP" ]; then
  echo "==> Restoring PostgreSQL from $PG_DUMP ..."
  if ! docker inspect --format='{{.State.Running}}' "$FORGEJO_DB_CONTAINER" 2>/dev/null | grep -q 'true'; then
    echo "    $FORGEJO_DB_CONTAINER is not running — start the stack first (docker compose up -d db)." >&2
    exit 1
  fi
  DB_NAME="$(grep '^POSTGRES_DB=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  DB_USER="$(grep '^POSTGRES_USER=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  [ -n "$DB_NAME" ] || DB_NAME=forgejo
  [ -n "$DB_USER" ] || DB_USER=forgejo
  # Stop Forgejo so it does not write to the DB during restore.
  docker stop "$FORGEJO_CONTAINER" >/dev/null 2>&1 || true
  gzip -dc "$PG_DUMP" | docker exec -i "$FORGEJO_DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME"
  echo "    PostgreSQL restored."
fi

# ---- 2. Forgejo dump (attachments, LFS, avatars) ---------------------------
if [ -n "$FORGEJO_DUMP" ]; then
  echo "==> Extracting Forgejo dump from $FORGEJO_DUMP ..."
  WORK="$(mktemp -d)"
  tar -xzf "$FORGEJO_DUMP" -C "$WORK"

  # Attachments / avatars / LFS live under data/ in the dump, which maps to
  # /data/gitea inside the container (= $FORGEJO_DATA_MOUNTPOINT/gitea on host).
  if [ -d "$WORK/data" ] && [ -n "$(ls -A "$WORK/data" 2>/dev/null)" ]; then
    echo "    Restoring data (attachments, avatars, LFS...) -> /data/gitea ..."
    if [ -n "$FORGEJO_DATA_MOUNTPOINT" ]; then
      mkdir -p "$FORGEJO_DATA_MOUNTPOINT/gitea"
      cp -a "$WORK/data/." "$FORGEJO_DATA_MOUNTPOINT/gitea/"
    else
      docker cp "$WORK/data/." "$FORGEJO_CONTAINER:/data/gitea/"
    fi
  else
    echo "    No data/ in dump — nothing to restore."
  fi

  rm -rf "$WORK"
  echo "    Forgejo dump restored."
fi

# ---- 2b. Git repositories (raw from Docker volume) -------------------------
if [ -n "$FORGEJO_REPOS" ]; then
  echo "==> Restoring Git repositories from $FORGEJO_REPOS ..."
  # The archive's top-level entry is `repositories/` (backup.sh tars it with
  # `-C .../git repositories`), so it must be extracted into .../git (not
  # .../git/repositories) or it would nest into repositories/repositories/.
  if [ -s "$FORGEJO_REPOS" ] && gzip -t "$FORGEJO_REPOS" 2>/dev/null; then
    # IMPORTANT: do NOT pipe through `gzip -dc | tar -xzf -`.  tar -z would then
    # receive an already-decompressed stream and fail with
    # "gzip: stdin: not in gzip format".  Let tar read the gzip file directly
    # (or receive the raw gzip on stdin for the docker fallback).
    if [ -n "$FORGEJO_DATA_MOUNTPOINT" ]; then
      mkdir -p "$FORGEJO_DATA_MOUNTPOINT/git"
      tar -xzf "$FORGEJO_REPOS" -C "$FORGEJO_DATA_MOUNTPOINT/git" --numeric-owner
    else
      docker exec "$FORGEJO_CONTAINER" mkdir -p /data/git
      docker exec -i -u 1000 "$FORGEJO_CONTAINER" tar -xzf - -C /data/git < "$FORGEJO_REPOS"
    fi
    echo "    Repositories restored."
  else
    echo "    WARNING: $FORGEJO_REPOS is empty or not a valid gzip archive — skipping."
    echo "    (Repositories may have been missing when this backup ran.)"
  fi
fi

# ---- 3. Headscale ----------------------------------------------------------
if [ -n "$HEADSCALE_DUMP" ] && [ -s "$HEADSCALE_DUMP" ] && gzip -t "$HEADSCALE_DUMP" 2>/dev/null; then
  echo "==> Restoring Headscale from $HEADSCALE_DUMP ..."
  mkdir -p "${STACK_DIR}/headscale"
  tar -xzf "$HEADSCALE_DUMP" -C "${STACK_DIR}/headscale"
  echo "    Headscale restored."
else
  echo "    WARNING: headscale archive missing or corrupt — skipping."
fi

# ---- 4. Stack config + secrets ---------------------------------------------
if [ -n "$CONFIG_DUMP" ] && [ -s "$CONFIG_DUMP" ] && gzip -t "$CONFIG_DUMP" 2>/dev/null; then
  echo "==> Restoring stack config + secrets from $CONFIG_DUMP ..."
  tar -xzf "$CONFIG_DUMP" -C "${STACK_DIR}"
  echo "    Config restored."
else
  echo "    WARNING: stack-config archive missing or corrupt — skipping."
fi

echo "==> Restarting the stack..."
cd "${STACK_DIR}"
docker compose up -d
echo "    Done."

echo "==> Restore finished. Verify with:"
echo "    docker compose ps"
echo "    docker logs --tail 50 $FORGEJO_CONTAINER"
