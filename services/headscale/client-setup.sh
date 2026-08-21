#!/usr/bin/env bash

set -euo pipefail

SERVER_HOST="${SERVER_HOST:-45.147.97.211}"
SERVER_USER="${SERVER_USER:-root}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:-}"
FORGEJO_DOMAIN="${FORGEJO_DOMAIN:-}"
TAILSCALE_IP="${TAILSCALE_IP:-}"
HEADSCALE_AUTHKEY="${HEADSCALE_AUTHKEY:-}"
NODE_NAME="${NODE_NAME:-}"

DEFAULT_NODE_NAME="$(hostname -s 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cd 'a-z0-9-' \
  | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' \
  | cut -c1-63)"
NODE_NAME="${NODE_NAME:-${DEFAULT_NODE_NAME:-client}}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

remote() { ssh "${SERVER_USER}@${SERVER_HOST}" "sudo -n $1"; }

if grep -qE '^10\.42\.0\.1[[:space:]].*duckdns\.org' /etc/hosts; then
  log "Removing the stale Innernet entry from /etc/hosts..."
  sudo sed -i '/^10\.42\.0\.1[[:space:]].*duckdns\.org/d' /etc/hosts
fi

if ! command -v tailscale >/dev/null 2>&1; then
  log "Installing the Tailscale client..."
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled 2>/dev/null || true
fi

if [[ -z "$HEADSCALE_DOMAIN" ]]; then
  HEADSCALE_DOMAIN="$(remote "grep '^HEADSCALE_DOMAIN=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\r'" 2>/dev/null || true)"
fi
if [[ -z "$FORGEJO_DOMAIN" ]]; then
  FORGEJO_DOMAIN="$(remote "grep '^FORGEJO_DOMAIN=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\r'" 2>/dev/null || true)"
fi
if [[ -z "$TAILSCALE_IP" ]]; then
  TAILSCALE_IP="$(remote "grep '^TAILSCALE_IP=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\r'" 2>/dev/null || true)"
fi

if [[ -z "$HEADSCALE_DOMAIN" ]]; then
  warn "HEADSCALE_DOMAIN is unknown - set it as an environment variable or check the server .env file."
  exit 1
fi

if tailscale status >/dev/null 2>&1; then
  log "This machine is already connected to the tailnet."
else
  if [[ -z "$HEADSCALE_AUTHKEY" ]]; then
    warn "HEADSCALE_AUTHKEY is missing - the admin must create a key on the server:"
    printf '\n  docker exec headscale headscale users list\n  docker exec headscale headscale preauthkeys create --user <ID> --reusable=false\n\n'
    warn "then re-run:  HEADSCALE_AUTHKEY=<key> ./services/headscale/client-setup.sh"
    exit 1
  fi
  log "Joining the tailnet ${HEADSCALE_DOMAIN} (node '${NODE_NAME}')..."
  sudo tailscale up \
    --login-server="https://${HEADSCALE_DOMAIN}" \
    --authkey="${HEADSCALE_AUTHKEY}" \
    --hostname="${NODE_NAME}" \
    --accept-dns=true
fi

if [[ -n "$FORGEJO_DOMAIN" && -n "$TAILSCALE_IP" ]]; then
  if grep -qE "[[:space:]]${FORGEJO_DOMAIN}([[:space:]]|$)" /etc/hosts; then
    log "The /etc/hosts entry for ${FORGEJO_DOMAIN} already exists."
  else
    log "Adding '${TAILSCALE_IP}  ${FORGEJO_DOMAIN}' to /etc/hosts..."
    echo "${TAILSCALE_IP}  ${FORGEJO_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
  fi
else
  warn "FORGEJO_DOMAIN or TAILSCALE_IP is unknown - add the entry manually to /etc/hosts:"
  warn "  ${TAILSCALE_IP}  <forgejo-domain>"
fi

log "Verification..."
tailscale status || true
tailscale ip -4 || true

printf '\n\033[1;32mDone.\033[0m Open https://%s in your browser.\n' "${FORGEJO_DOMAIN:-<forgejo-domain>}"
