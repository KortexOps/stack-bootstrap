#!/usr/bin/env bash

set -euo pipefail

SERVER_HOST="${SERVER_HOST:-}"
SERVER_USER="${SERVER_USER:-deploy}"
HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN:-}"
FORGEJO_DOMAIN="${FORGEJO_DOMAIN:-}"
# Optional: explicit VPS tailnet IP override. Normally auto-detected from the server.
VPS_TAILSCALE_IP="${VPS_TAILSCALE_IP:-}"
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

remote() {
  [[ -n "$SERVER_HOST" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "${SERVER_USER}@${SERVER_HOST}" "sudo -n $1"
}

if [[ ! -r /etc/os-release ]] || ! grep -qE '^ID=(debian|ubuntu)' /etc/os-release; then
  warn "This script supports Debian and Ubuntu clients only."
  exit 1
fi

if grep -qE '^10\.42\.0\.1[[:space:]].*duckdns\.org' /etc/hosts; then
  log "Removing the stale Innernet entry from /etc/hosts..."
  sudo sed -i '/^10\.42\.0\.1[[:space:]].*duckdns\.org/d' /etc/hosts
fi

if ! command -v tailscale >/dev/null 2>&1; then
  command -v curl >/dev/null 2>&1 || {
    warn "curl is required to install Tailscale."
    exit 1
  }
  log "Installing the Tailscale client..."
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo systemctl enable --now tailscaled
fi

if [[ -z "$HEADSCALE_DOMAIN" || -z "$FORGEJO_DOMAIN" ]]; then
  if [[ -z "$SERVER_HOST" ]]; then
    warn "SERVER_HOST is required when HEADSCALE_DOMAIN or FORGEJO_DOMAIN is not provided."
    exit 1
  fi
  if [[ -z "$HEADSCALE_DOMAIN" ]]; then
    HEADSCALE_DOMAIN="$(remote "grep '^HEADSCALE_DOMAIN=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\\r'")"
  fi
  if [[ -z "$FORGEJO_DOMAIN" ]]; then
    FORGEJO_DOMAIN="$(remote "grep '^FORGEJO_DOMAIN=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\\r'")"
  fi
fi

if [[ -z "$HEADSCALE_DOMAIN" ]]; then
  warn "HEADSCALE_DOMAIN is missing."
  exit 1
fi
if [[ -z "$FORGEJO_DOMAIN" ]]; then
  warn "FORGEJO_DOMAIN is missing."
  exit 1
fi

CURRENT_TAILSCALE_IP=""
if tailscale ip -4 >/dev/null 2>&1; then
  CURRENT_TAILSCALE_IP="$(tailscale ip -4 | head -n1 | tr -d '\r')"
fi

if [[ -z "$CURRENT_TAILSCALE_IP" ]]; then
  [[ "$NODE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || {
    warn "NODE_NAME must contain only letters, numbers and hyphens and be at most 63 characters."
    exit 1
  }

  [[ -n "$HEADSCALE_AUTHKEY" ]] || {
    warn "HEADSCALE_AUTHKEY is required to join the tailnet."
    warn "Generate a single-use key from your machine with the Makefile helpers:"
    warn "  make id     # list Headscale users and their numeric IDs"
    warn "  make key    # generate a single-use key for the default user"
    warn "Then re-run with: HEADSCALE_AUTHKEY=<key> ./services/headscale/client-setup.sh"
    exit 1
  }

  log "Joining the tailnet ${HEADSCALE_DOMAIN} (node '${NODE_NAME}')..."
  sudo tailscale up \
    --login-server="https://${HEADSCALE_DOMAIN}" \
    --authkey="${HEADSCALE_AUTHKEY}" \
    --hostname="${NODE_NAME}" \
    --accept-dns=true
  unset HEADSCALE_AUTHKEY
fi

CLIENT_TAILSCALE_IP="$(tailscale ip -4 | head -n1 | tr -d '\r')"
[[ -n "$CLIENT_TAILSCALE_IP" ]] || {
  warn "Tailscale joined but did not return an IPv4 address."
  exit 1
}

# Forgejo runs on the VPS, so the hosts entry must point at the VPS tailnet IP
# (not this client's own IP). Fetch it from the server's .env when possible.
if [[ -z "$VPS_TAILSCALE_IP" && -n "$SERVER_HOST" ]]; then
  VPS_TAILSCALE_IP="$(remote "grep '^TAILSCALE_IP=' /opt/ia-stack/.env | cut -d= -f2- | tr -d '\\r'")" || VPS_TAILSCALE_IP=""
fi

if [[ -n "$VPS_TAILSCALE_IP" ]]; then
  log "Updating the Forgejo hosts entry ($FORGEJO_DOMAIN -> $VPS_TAILSCALE_IP)..."
  tmp_hosts="$(mktemp)"
  trap 'rm -f "$tmp_hosts"' EXIT
  awk -v ip="$VPS_TAILSCALE_IP" -v host="$FORGEJO_DOMAIN" '
    {
      has_host = 0
      for (i = 2; i <= NF; i++) {
        if ($i == host) {
          has_host = 1
        }
      }
      if (has_host) {
        if (!updated) {
          print ip "  " host
          updated = 1
        }
        next
      }
      print
    }
    END {
      if (!updated) {
        print ip "  " host
      }
    }
  ' /etc/hosts > "$tmp_hosts"
  sudo install -o root -g root -m 0644 "$tmp_hosts" /etc/hosts
else
  warn "Could not determine the VPS tailnet IP; relying on MagicDNS for $FORGEJO_DOMAIN."
fi

log "Verification..."
tailscale status
tailscale ip -4

if command -v curl >/dev/null 2>&1; then
  log "Checking https://${FORGEJO_DOMAIN} ..."
  if curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 10 "https://${FORGEJO_DOMAIN}"; then
    :
  else
    warn "Could not reach ${FORGEJO_DOMAIN} over HTTPS (routing or certificate issue)."
  fi
fi

printf '\n\033[1;32mDone.\033[0m Open https://%s in your browser.\n' "$FORGEJO_DOMAIN"
