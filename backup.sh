#!/usr/bin/env bash
# Backup Forgejo + Headscale + stack configuration and sync to Google Drive.
#
# Runs on the VPS as root (deployed to /opt/ia-stack/backup.sh by Ansible).
# It is safe to run while services are live: each component is backed up
# independently and failures in one do not block the others.
#
# What it backs up (5 archives per run, inside a timestamped folder):
#   $BACKUP_DIR/20260824-133209/
#     forgejo-dump.tar.gz   — Forgejo DB + LFS + attachments + avatars
#     forgejo-repos.tar.gz  — raw Git repositories from the Docker volume
#     forgejo-pg.sql.gz     — PostgreSQL pg_dump (most reliable DB restore)
#     headscale.tar.gz      — Headscale database + config + ACL
#     stack-config.tar.gz   — docker-compose.yml, .env, passwords
#
# Repositories are backed up directly from Docker volumes rather than via
# "forgejo dump" because Forgejo 10.x refuses to dump repos inside the
# container when they live on a named volume.
#
# Requires an rclone remote named "gdrive" pointing at your Google Drive (see
# README "Backups" section). If rclone is not configured, the dumps are simply
# left in BACKUP_DIR.

set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ia-stack}"

# Derive the Compose project + container names from the server .env (set by
# Ansible), so prod and dev target their own containers and their own bucket.
COMPOSE_PROJECT_NAME="$(grep '^COMPOSE_PROJECT_NAME=' "${STACK_DIR}/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ia-stack}"
FORGEJO_CONTAINER="${FORGEJO_CONTAINER:-${COMPOSE_PROJECT_NAME}-forgejo}"
FORGEJO_DB_CONTAINER="${FORGEJO_DB_CONTAINER:-${COMPOSE_PROJECT_NAME}-forgejo-db}"

BACKUP_DIR="${BACKUP_DIR:-${STACK_DIR}/backups}"
# Separate Google Drive bucket per environment: prod -> forgejo-backups,
# dev -> forgejo-backups-dev.  Override via RCLONE_REMOTE (env or .env).
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:forgejo-backups${COMPOSE_PROJECT_NAME#ia-stack}}"
RCLONE_OPTS="${RCLONE_OPTS:-}"
# Local dumps older than this are pruned after every run. Google Drive keeps
# a full history (rclone copy never deletes), so this only limits local disk.
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

# Pick up optional overrides from the server-side .env (RCLONE_REMOTE,
# BACKUP_RETENTION_DAYS) without sourcing arbitrary shell content.
if [ -f "${STACK_DIR}/.env" ]; then
  _env_rclone="$(grep '^RCLONE_REMOTE=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  _env_retention="$(grep '^BACKUP_RETENTION_DAYS=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  [ -n "$_env_rclone" ] && RCLONE_REMOTE="$_env_rclone"
  [ -n "$_env_retention" ] && RETENTION_DAYS="$_env_retention"
fi
# Sanity: retention must be a positive integer, otherwise fall back to 14.
printf '%s' "$RETENTION_DAYS" | grep -qE '^[0-9]+$' || RETENTION_DAYS=14

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${BACKUP_DIR}/${STAMP}"
mkdir -p "$RUN_DIR"

echo "==> Forgejo dump (database + LFS + attachments + avatars)..."
FORGEJO_TMP="/tmp/forgejo-dump-${STAMP}.tar.gz"
FORGEJO_LOG="/tmp/forgejo-dump-${STAMP}.log"
if docker inspect --format='{{.State.Running}}' "$FORGEJO_CONTAINER" 2>/dev/null | grep -q 'true'; then
  if docker exec -u 1000 -w /tmp "$FORGEJO_CONTAINER" \
       forgejo dump --skip-repository --type tar.gz -f "$FORGEJO_TMP" >"$FORGEJO_LOG" 2>&1; then
    docker cp "$FORGEJO_CONTAINER:$FORGEJO_TMP" "$RUN_DIR/forgejo-dump.tar.gz"
    docker exec -u 1000 "$FORGEJO_CONTAINER" rm -f "$FORGEJO_TMP" "$FORGEJO_LOG" 2>/dev/null || true
    echo "    Forgejo dump complete."
  else
    echo "    WARNING: forgejo dump failed:"
    tail -n 20 "$FORGEJO_LOG" 2>/dev/null | sed 's/^/      /' || true
    docker exec -u 1000 "$FORGEJO_CONTAINER" rm -f "$FORGEJO_TMP" "$FORGEJO_LOG" 2>/dev/null || true
  fi
else
  echo "    Forgejo is not running — skipping its dump."
fi

echo "==> Git repositories (direct from Docker volume)..."
# Scope the volume to THIS Compose project so prod and dev never read each
# other's data (ia-stack_forgejo-data vs ia-stack-dev_forgejo-data).
FORGEJO_VOLUME="$(docker volume ls --format '{{.Name}}' | grep "${COMPOSE_PROJECT_NAME}_forgejo-data$" | head -n1)"
if [ -n "$FORGEJO_VOLUME" ]; then
  VOLUME_PATH="$(docker volume inspect --format '{{.Mountpoint}}' "$FORGEJO_VOLUME")"
  REPO_VOLUME="${VOLUME_PATH}/git/repositories"
  if [ -d "$REPO_VOLUME" ] && [ -n "$(ls -A "$REPO_VOLUME" 2>/dev/null)" ]; then
    REPOS_ERR="$(mktemp)"
    if tar -czf "$RUN_DIR/forgejo-repos.tar.gz" \
         -C "${VOLUME_PATH}/git" repositories 2>"$REPOS_ERR"; then
      # Validate the archive; never leave an unreadable file behind.
      if gzip -t "$RUN_DIR/forgejo-repos.tar.gz" 2>/dev/null; then
        echo "    Repositories backed up ($(du -sh "$REPO_VOLUME" 2>/dev/null | cut -f1))."
      else
        echo "    WARNING: repository archive failed validation — removing it."
        rm -f "$RUN_DIR/forgejo-repos.tar.gz"
      fi
    else
      echo "    WARNING: repository tar failed:"
      tail -n 20 "$REPOS_ERR" 2>/dev/null | sed 's/^/      /' || true
      rm -f "$RUN_DIR/forgejo-repos.tar.gz"
    fi
    rm -f "$REPOS_ERR"
  else
    echo "    No repositories found — skipping (normal for a fresh instance)."
    rm -f "$RUN_DIR/forgejo-repos.tar.gz"
  fi
else
  echo "    No forgejo-data volume found — skipping."
fi

echo "==> PostgreSQL dump (most reliable DB restore path)..."
if docker inspect --format='{{.State.Running}}' "$FORGEJO_DB_CONTAINER" 2>/dev/null | grep -q 'true'; then
  DB_NAME="$(grep '^POSTGRES_DB=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  DB_USER="$(grep '^POSTGRES_USER=' "${STACK_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  [ -n "$DB_NAME" ] || DB_NAME=forgejo
  [ -n "$DB_USER" ] || DB_USER=forgejo
  docker exec "$FORGEJO_DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
    | gzip -c > "$RUN_DIR/forgejo-pg.sql.gz"
  echo "    PostgreSQL dump complete ($DB_NAME)."
else
  echo "    forgejo-db is not running — skipping PostgreSQL dump."
fi

echo "==> Headscale state (database + config + ACL)..."
if [ -d "${STACK_DIR}/headscale" ]; then
  tar -czf "$RUN_DIR/headscale.tar.gz" \
    -C "${STACK_DIR}/headscale" . 2>/dev/null || true
fi

echo "==> Stack configuration and secrets (needed for a full restore)..."
tar -czf "$RUN_DIR/stack-config.tar.gz" \
  -C "${STACK_DIR}" \
  docker-compose.yml .env .postgres_password .forgejo_admin_password \
  2>/dev/null || true

echo "==> Pruning local dumps older than $RETENTION_DAYS days..."
# Delete entire timestamped folders that are too old.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
  -mtime "+${RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true

echo "==> Syncing to Google Drive ($RCLONE_REMOTE)..."
if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE%%:*}:$"; then
  # `copy` (not `sync`) so Google Drive keeps the full history and is never
  # pruned by a local retention cleanup.
  # shellcheck disable=SC2086
  rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE" ${RCLONE_OPTS:-}
  echo "    Done. Backups synced to $RCLONE_REMOTE."
else
  echo "    rclone remote '${RCLONE_REMOTE%%:*}' is not configured —"
  echo "    dumps were left in $BACKUP_DIR and NOT uploaded."
fi

echo "==> Backup finished → $RUN_DIR"
ls -lh "$RUN_DIR"