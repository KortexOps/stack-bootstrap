# Stack Bootstrap

Self-hosted **Headscale** (Tailscale control server) + **Traefik** + **Forgejo** on a single VPS, deployed with Ansible. Client devices join the private tailnet through **single-use pre-auth keys**.

## What you get

| Service   | Role                                        | Access                                    |
|-----------|---------------------------------------------|-------------------------------------------|
| Headscale | Self-hosted Tailscale control server (VPN)  | Public HTTPS (`HEADSCALE_DOMAIN`)         |
| Tailscale | VPS node on the tailnet                     | Tailnet `100.x.y.z`, UDP 41641            |
| Traefik   | Public/private reverse proxy                | Public `80/443`, tailnet `100.x.y.z:443`  |
| Forgejo   | Private Git forge                           | HTTPS through the tailnet only            |

- **Forgejo is private** — it is only reachable from inside the tailnet, never on the public internet.
- **Headscale is public** — it must be reachable over HTTPS so clients can register and fetch their config.
- **Traefik** terminates TLS for both, with Let's Encrypt certificates.

```
clients ──(HTTPS)──> Headscale   # control plane: register, keys, ACLs
nodes   ──(UDP 41641)──> nodes   # data plane: WireGuard / DERP fallback
nodes   ──(HTTPS 100.x.y.z:443)──> Traefik ──> Forgejo
```

## Prerequisites

- A Debian/Ubuntu VPS with inbound **22/tcp**, **80/tcp**, **443/tcp** and **41641/udp** open.
- Docker on **your local machine** (to run Ansible in a container).
- DNS records pointing at the VPS:
  - `HEADSCALE_DOMAIN` → VPS public IP (required, public HTTPS)
  - `FORGEJO_DOMAIN` → VPS public IP (only for the Let's Encrypt HTTP-01 challenge; traffic is then tailnet-only)
  - `HEADSCALE_DNS_DOMAIN` → MagicDNS suffix, no public record needed
- An SSH key on your machine (`~/.ssh/id_ed25519`) authorized on the VPS, with the VPS host key in `~/.ssh/known_hosts`.

## Quick start (bootstrap only)

Normal updates go through **git**: push to `main` deploys prod, opening a pull
request deploys dev (Forgejo Actions). `make` is **not** used for updates — it
is only for rebuilding everything after a total deletion (see
[Recovery](#recovery-make-bootstrap)).

```bash
# 1. Configure
cp .env.example .env
# edit .env: set ACME_EMAIL, the three domains, and your VPS IP
# set ANSIBLE_USER=root for the very first bootstrap (the deploy user does not exist yet)

# 2. Rebuild the stack from scratch (installs everything, then restores Drive backups)
make bootstrap
```

## Configuration

### Environment variables (`.env`)

| Variable              | Required | Description                                                         |
|-----------------------|----------|---------------------------------------------------------------------|
| `ACME_EMAIL`          | yes      | Email for Let's Encrypt certificates                                |
| `HEADSCALE_DOMAIN`    | yes      | Public HTTPS domain of the Headscale control server                 |
| `HEADSCALE_DNS_DOMAIN`| yes      | MagicDNS suffix (must differ from the other two domains)            |
| `FORGEJO_DOMAIN`      | yes      | Forgejo domain (reachable only through the tailnet)                 |
| `PUBLIC_IP`           | no       | VPS public IP — overwritten from `inventory.yml` by Ansible         |
| `TAILSCALE_IP`        | no       | VPS tailnet IP — written automatically, leave empty                 |
| `HEADSCALE_AUTHKEY`   | phase 2  | Single-use pre-auth key for the VPS node (see below)                |
| `ANSIBLE_USER`        | yes      | SSH user for Ansible (`root` first, then `deploy`)                  |
| `ANSIBLE_IMAGE`       | no       | Local Ansible image name (default `my-ansible`)                     |
| `SERVER_HOST`         | key cmds | VPS IP used by `make id` / `make key`                               |
| `SERVER_USER`         | key cmds | SSH user used by `make id` / `make key` (default `deploy`)          |
| `TRAEFIK_IMAGE`       | no       | Traefik image tag                                                    |
| `HEADSCALE_IMAGE`     | no       | Headscale image tag                                                  |
| `POSTGRES_IMAGE`      | no       | PostgreSQL image tag                                                 |
| `FORGEJO_IMAGE`       | no       | Forgejo image tag                                                    |
| `POSTGRES_DB`         | yes      | Forgejo database name                                                |
| `POSTGRES_USER`       | yes      | Forgejo database user                                                |
| `FORGEJO_ADMIN_USERNAME` | no    | Forgejo admin account name                                           |
| `FORGEJO_ADMIN_EMAIL` | yes      | Forgejo admin email                                                  |

> ⚠️ `HEADSCALE_DOMAIN`, `HEADSCALE_DNS_DOMAIN` and `FORGEJO_DOMAIN` **must all be different**.
> `HEADSCALE_DOMAIN` and `FORGEJO_DOMAIN` must resolve publicly to the VPS for the certificate challenge.
> `TAILSCALE_IP` is managed by the playbook — leave it empty and never edit it by hand.

### Inventory (`inventory.yml`)

```yaml
all:
  hosts:
    vps-ia:
      ansible_host: VPS_IP_ADDRESS
      ansible_user: root
```

## Make commands

```bash
make build           # build the Ansible image
make check           # syntax-check the playbook (no connection)
make bootstrap       # REBUILD the whole stack from scratch and restore Drive backups (recovery only)
make id              # list Headscale users and their numeric IDs
make key             # generate a single-use pre-auth key (default user)
make key_id ID=5     # generate a single-use pre-auth key for numeric user ID 5
make keys            # list all pre-auth keys and their IDs
make key_del ID=7    # delete a pre-auth key by its ID
make key_expire ID=7 # expire (revoke) a pre-auth key by its ID
make backup          # back up the prod stack to Google Drive
make backup-dev      # back up the dev stack (local dumps on the VPS)
make restore         # restore the prod stack from Google Drive
make restore-dev     # restore the dev stack from its local backups
make ci-enable       # start the CI/CD runner (Forgejo Actions)
make ci-disable      # stop the CI/CD runner
make ci-status       # show the CI/CD runner status
make help            # list all commands
```

> Updates never go through `make` — they go through git (see CI/CD). `make` is
> only for recovery (`make bootstrap`), key management and backups.

`make id` / `make key` / `make key_id` / `make backup` / `make restore` SSH into the VPS (using `SERVER_USER`/`SERVER_HOST`) and run commands inside the container or on the host. They use `sudo` automatically unless you connect as `root`.

```bash
make key HEADSCALE_USER=someuser   # generate a key for a different user
## Recovery (make bootstrap)

`make bootstrap` rebuilds the whole stack from scratch and restores the data
from the Google Drive backups. It is the only `make` target that deploys —
reserved for when the VPS (or the stack) was **totally deleted**. Normal
updates go through git: since Forgejo runs **on this VPS**, a wiped VPS has no
git host to trigger a deploy, so `make bootstrap` is the recovery path that
brings Forgejo back first.

`make bootstrap`:

1. Installs Docker and prerequisites, starts Traefik + Headscale + Forgejo, creates the `default` Headscale user, and provisions the `deploy` account.
2. Restores the stack configuration + data from the Drive backups (`restore.sh`).
3. Prints the steps to restart the CI runner afterwards.

### First bootstrap (fresh VPS)

```bash
# set ANSIBLE_USER=root in .env for the first run (the deploy user doesn't exist yet)
make bootstrap
# then verify the deploy user works and set ANSIBLE_USER=deploy in .env
```

### Join the VPS to the tailnet (after a wipe)

The VPS itself is a machine without a browser, so it joins with a pre-auth key.

1. Generate a key:
   ```bash
   make id          # find the numeric ID of the `default` user
   make key         # single-use key for the default user
   ```
2. Paste it into `.env`:
   ```env
   HEADSCALE_AUTHKEY=<the-key>
   ```
3. Re-run the rebuild:
   ```bash
   make bootstrap
   ```

Ansible installs the Tailscale client on the VPS, joins the tailnet, writes `TAILSCALE_IP`, rebinds the private Traefik entrypoint to the tailnet IP, then **expires and removes the key** automatically.

> Container names are namespaced by environment (`ia-stack-headscale`,
> `ia-stack-forgejo`… for prod; `ia-stack-dev-forgejo`… for dev — dev has no
> Headscale of its own). Prefer `make id` / `make key` / `make keys`; they target
the right container automatically.

## Connecting a device

Every device joins with its own **single-use pre-auth key**. Never reuse a key between machines.

### Desktop / laptop (Linux)

```bash
# 1. On your machine: generate a key
make key          # or: make key_id ID=<id>

# 2. On the client: run the onboarding script
SERVER_HOST=YOUR_VPS_IP \
HEADSCALE_AUTHKEY=<the-key> \
./services/headscale/client-setup.sh
```

The script installs Tailscale, joins the tailnet, and adds a `/etc/hosts` entry so Forgejo resolves to the VPS's tailnet IP.

### Phone (Android / iOS)

1. Install the official **Tailscale** app.
2. Tap the menu → **Use custom coordination server** (or equivalent) → `https://HEADSCALE_DOMAIN`.
3. Log in with a pre-auth key you generated with `make key`.

Once connected, Forgejo is available at `https://FORGEJO_DOMAIN` (via MagicDNS or the hosts entry).

## Dev environment

Dev is a second Forgejo instance that previews your pull requests before they
reach production. It keeps the VPS simple by reusing the prod infrastructure:

| Component        | Dev uses                                                           |
|------------------|--------------------------------------------------------------------|
| Forgejo + DB     | its own containers/volumes (`ia-stack-dev-forgejo`, `ia-stack-dev-*`) |
| Traefik          | the **prod** Traefik (certs + routing, shared `ia-stack-proxy` network) |
| Tailnet          | the **prod** tailnet (the VPS is already a node)                   |
| Backups          | local dumps in `/opt/ia-stack-dev/backups` (no Drive token)        |

How it works:
- Dev's compose renders **no Traefik and no Headscale**: dev containers join
the prod `ia-stack-proxy` network and register routers
(`ia-stack-dev-forgejo`…) on the prod Traefik (unique router names avoid
colliding with prod routers).
- The prod Traefik issues the certificate for `dev.git.<BASE_DOMAIN>` via
HTTP-01 (the domain must resolve publicly to the VPS) but serves dev **only on
the tailnet entrypoint** — dev is never exposed on the public internet, same
privacy model as prod.

Git flow (automated by Forgejo Actions, see below):

```
feature branch ──(open PR)─────> dev stack auto-deploy
      │
      └──(merge to main)──────> prod stack auto-deploy
```

To reach the dev instance, point `dev.git.<BASE_DOMAIN>` at the VPS tailnet IP
(same pattern as prod's hosts entry):

```bash
# find the VPS tailnet IP
ssh deploy@YOUR_VPS_IP 'sudo grep ^TAILSCALE_IP= /opt/ia-stack/.env | cut -d= -f2-'
# add the dev host entry (replace the IP)
echo "<TAILSCALE_IP>  dev.git.YOUR_DOMAIN.com" | sudo tee -a /etc/hosts
# open in your browser
https://dev.git.YOUR_DOMAIN.com
```

The dev admin is `dev-admin` (password generated on the server at
`/opt/ia-stack-dev/.forgejo_admin_password`).

> The `dev.git.`, `dev-headscale.` and `dev-tailnet.` names are still required
> in the dev `.env` (the playbook validates them), but only `dev.git.` must
> resolve publicly (for the certificate). Dev joins the prod tailnet, so its
> own Headscale/Tailscale variables are unused.

## CI/CD (Forgejo Actions)

The repo ships two workflows (`.forgejo/workflows/`):

- `deploy-dev.yml` — on every pull request → deploys the dev stack.
- `deploy-prod.yml` — on push to `main` → deploys the prod stack.

> Updates go through these workflows **only**. `make bootstrap` is the sole local
deploy path, reserved for full recovery after a total deletion — never for
regular updates.

### 1. Start the self-hosted runner (on the VPS)

Jobs run directly on the VPS through the host Docker socket.

```bash
# a) In Forgejo: Site Administration → Actions → Runners → Create new runner,
#    copy the registration token.

# b) On the VPS, save the token and start the runner (the instance URL is
#    derived from FORGEJO_DOMAIN in /opt/ia-stack/.env):
echo "TOKEN" | sudo tee /opt/ia-stack/.runner_token && sudo chmod 600 /opt/ia-stack/.runner_token
sudo docker compose -f /opt/ia-stack/docker-compose.runner.yml up -d

# c) Verify the runner shows "online" in the Forgejo admin.
```

### Enabling / disabling CI/CD

CI/CD is active only while the runner container is running. Toggle it from
your machine (no SSH needed):

```bash
make ci-enable    # start the runner (requires a registration token, see step 1)
make ci-disable   # stop the runner — jobs are queued but not picked up
make ci-status    # show whether the runner is up
```

`ci-disable` keeps the runner's registration (volume `runner-data`), so
`make ci-enable` brings CI/CD back instantly. A manually stopped runner does
not restart on reboot (`restart: unless-stopped`).

> `docker compose` prints an **"Found orphan containers"** warning when
> starting the runner. This is expected: both compose files share the same
> project (`ia-stack`) and the same `.env`, and `docker-compose.runner.yml`
> only declares the runner. It is harmless — nothing is touched. Never add
> `--remove-orphans` to the runner command, as it would stop the whole stack.

### 2. Give the CI an SSH key for the `deploy` user

The workflows connect as `deploy` (never `root` — hardening disables root
SSH). The runner mounts the VPS's `/root/.ssh`, so generate a CI key there
once and authorize it for `deploy`:

```bash
# one-time, on the VPS:
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519   # pick another name if the file exists
sudo sh -c 'cat /root/.ssh/id_ed25519.pub >> /home/deploy/.ssh/authorized_keys'
sudo ssh-keyscan -H YOUR_VPS_PUBLIC_IP >> /root/.ssh/known_hosts
```

### 3. Create the repo secrets

Forgejo repo → Settings → Actions → Secrets:

| Secret | Value |
|---|---|
| `BASE_DOMAIN` | `example.com` (no `git.` prefix) |
| `PUBLIC_IP` | the VPS public IP |
| `ACME_EMAIL` | your email |
| `FORGEJO_ADMIN_EMAIL` | the prod admin email |
| `RCLONE_CONFIG_TOKEN` | the `rclone authorize "drive"` JSON (prod backups) |

### 4. Push the repo

Push this repository to your Forgejo instance and create the `main` branch.
The workflows then trigger on PRs (dev) and pushes to `main` (prod).

## Managing nodes and keys

```bash
# Users and keys
make id              # list users + numeric IDs
make key             # new single-use key (default user)
make keys            # list all pre-auth keys + their IDs
make key_del ID=7    # delete a key by ID
make key_expire ID=7 # expire a key by ID

# Nodes
ssh deploy@YOUR_VPS_IP 'sudo docker exec ia-stack-headscale headscale nodes list'
ssh deploy@YOUR_VPS_IP 'sudo docker exec ia-stack-headscale headscale nodes delete -i <node-id>'

# On a client
tailscale status
tailscale ip -4
```

## Tailnet ACL policy

The tailnet is **deny by default**. Once the VPS has a tailnet IP, Headscale enforces `services/headscale/policy.hujson.j2`:

| Rule                     | Effect                                                  |
|--------------------------|---------------------------------------------------------|
| `* → <TAILSCALE_IP>:443` | All nodes reach Forgejo through the private Traefik     |
| `* → <TAILSCALE_IP>:22`  | All nodes can SSH to the VPS through the tailnet        |
| `* → *:*` (ICMP)         | Nodes can ping each other (debugging)                   |

Everything else is denied: a compromised client cannot reach other clients or other VPS
ports. The policy is only applied after the VPS joins, and it is validated with
`headscale policy check` before Headscale restarts — an invalid policy aborts the
deploy rather than locking you out.

To inspect or adjust it:

```bash
cat services/headscale/policy.hujson.j2
# on the server:
ssh deploy@YOUR_VPS_IP 'sudo cat /opt/ia-stack/headscale/policy.hujson'
```

## Backups

Backups are pushed to **Google Drive** via `rclone`, so your data survives even if the VPS dies. The playbook installs `rclone` and deploys `/opt/ia-stack/backup.sh`, which dumps:

- **Forgejo** — repositories, database, LFS objects, attachments and config (a single `forgejo dump` archive, consistent and restorable).
- **Headscale** — SQLite database, `config.yaml`, ACL policy.
- **Stack config** — `docker-compose.yml`, `.env` and the generated secrets, so a full restore is possible.

### One-time rclone setup

Ansible generates the rclone configuration automatically — no manual `rclone config`
on the server. Just:

1. Install rclone on your **laptop** (needed once to authorize):
   ```bash
   # macOS: brew install rclone   /   Linux: sudo apt install rclone
   ```
2. Authorize Google Drive:
   ```bash
   rclone authorize "drive"
   ```
   A browser opens; sign in to your Google account and approve access.
3. Paste the **entire** JSON block printed by rclone into your `.env` as a
   single `RCLONE_CONFIG_TOKEN=` line:
   ```env
   RCLONE_CONFIG_TOKEN={"access_token":"...","token_type":"Bearer","refresh_token":"...","expiry":"..."}
   ```
4. Add the token as the Forgejo secret `RCLONE_CONFIG_TOKEN`, then trigger a
   deploy (push to `main`, or Actions → Deploy Prod → Run workflow). Ansible
   picks it up from the server `.env` and writes
   `/root/.config/rclone/rclone.conf`.
5. Verify:
   ```bash
   ssh deploy@YOUR_VPS_IP 'sudo rclone about gdrive:'
   ```

> We use scope `drive.file`, the most restrictive usable scope: rclone can only see
> and manage files it created itself, so it is sandboxed to the backup folder and
> cannot read your other Drive files. The default target folder is `forgejo-backups`.

### Running a backup

```bash
make backup
```

This SSHes to the VPS and runs the backup script, which then uploads everything with `rclone copy`. Google Drive keeps the **full history** (nothing is ever deleted there); local dumps are pruned after 14 days by default.

Optional overrides in `.env`:

```env
RCLONE_REMOTE=gdrive:my-folder   # default gdrive:forgejo-backups
BACKUP_RETENTION_DAYS=30         # default 14
```

To schedule automatic daily backups, add a cron entry on the VPS:

```bash
ssh deploy@YOUR_VPS_IP 'echo "30 3 * * * root /opt/ia-stack/backup.sh" | sudo tee /etc/cron.d/forgejo-backup'
```

### Restoring

> ⚠️ The SQL bundled inside `forgejo dump` has known re-import bugs (per Forgejo's
own docs). That's why the backup script **also** produces a direct `pg_dump`
(`forgejo-pg-*.sql.gz`), which is the reliable path to restore the database.

The playbook deploys `/opt/ia-stack/restore.sh`. To restore the most recent set
of backups from Google Drive:

```bash
make restore
```

Or restore a specific timestamp:

```bash
make restore STAMP=20260824-103000
```

This downloads the dumps from Drive and restores, in order:

1. **PostgreSQL** — from `forgejo-pg.sql.gz` (via `pg_dump`).
2. **Forgejo files** — attachments/LFS (`data/`) from `forgejo-dump.tar.gz`.
3. **Git repositories** — raw from `forgejo-repos.tar.gz` (extracted directly
   on the `forgejo-data` volume mount point, preserving UID 1000 ownership).
4. **Headscale** — SQLite database, `config.yaml`, ACL from `headscale.tar.gz`.
5. **Stack config** — `docker-compose.yml`, `.env` and secrets from
   `stack-config.tar.gz`.

For a manual restore (or if the script reports a missing piece), the equivalent
steps are:

```bash
# 1. List what is in Drive
sudo rclone ls gdrive:forgejo-backups

# 2. Download locally
sudo rclone copy gdrive:forgejo-backups /opt/ia-stack/backups

# 3. Restore PostgreSQL
sudo gzip -dc /opt/ia-stack/backups/forgejo-pg.sql.gz \
  | sudo docker exec -i ia-stack-forgejo-db psql -U forgejo -d forgejo

# 4. Restore Forgejo attachments/LFS (data/ -> /data/gitea)
#    and repositories (repositories/ -> /data/git/repositories)
#    The volume mount point is /var/lib/docker/volumes/ia-stack_forgejo-data/_data
#    (prefer restore.sh — it handles this automatically and safely)
sudo tar -xzf /opt/ia-stack/backups/forgejo-dump.tar.gz -C /tmp/forgejo-extract
sudo cp -a /tmp/forgejo-extract/data/. /var/lib/docker/volumes/ia-stack_forgejo-data/_data/gitea/

# 5. Restore Headscale
sudo tar -xzf /opt/ia-stack/backups/headscale.tar.gz -C /opt/ia-stack/headscale

# 6. Restore config + secrets
sudo tar -xzf /opt/ia-stack/backups/stack-config.tar.gz -C /opt/ia-stack

# 7. Restart
cd /opt/ia-stack && sudo docker compose up -d
```

> **Important** — if `forgejo-repos.tar.gz` is missing, empty or not a valid
gzip archive, it means the repositories were already missing when the backup
ran (the `open /data/git/repositories` error). In that case the git
repositories cannot be restored from this backup; only the database and
attachments are recoverable.


## Hardening

The playbook ends with a hardening section that:

- Enables **ufw** (public `22/tcp`, `80/tcp`, `443/tcp`, `41641/udp`; only `22/tcp` and `443/tcp` on `tailscale0`; default-deny inbound).
- Enforces the **deny-by-default ACL policy** above.
- **Expires the VPS pre-auth key** automatically after the node joins.
- Enables **strict reverse-path filtering** (RFC 3704).
- Locks down **SSH to key-only** authentication and creates a dedicated `deploy` sudo user.

### Disable root SSH (recommended)

1. Deploy once with `ANSIBLE_USER=root` so `deploy` and its key are created.
2. Verify `ssh deploy@YOUR_VPS_IP`.
3. Set `ANSIBLE_USER=deploy` in `.env`.
4. Set `ssh_disable_root: true` in `group_vars/all.yml` and re-deploy (push to
   `main` through the CI, or `make bootstrap` for a full rebuild).

## Troubleshooting

- **Certificate not issued** — `HEADSCALE_DOMAIN` and `FORGEJO_DOMAIN` must resolve publicly to the VPS and ports 80/443 must be open.
- **Client can't register** — `HEADSCALE_DOMAIN` must be reachable over public HTTPS, and the pre-auth key must be valid (single-use keys expire after one use).
- **Forgejo unreachable from the tailnet** — run `tailscale status` on the client, confirm the VPS node is up, and that `FORGEJO_DOMAIN` resolves to the VPS tailnet IP (hosts entry or MagicDNS).
- **No direct connection between nodes** — open UDP 41641 inbound, otherwise traffic falls back to DERP relays.
- **A service became unreachable after the ACL applied** — the policy is deny-by-default; add the missing rule and redeploy.
- **SSH connection failed** — ensure the deploy key is in `/root/.ssh/authorized_keys` (bootstrap) or `/home/deploy/.ssh/authorized_keys` (later), and `known_hosts` contains the VPS key.
