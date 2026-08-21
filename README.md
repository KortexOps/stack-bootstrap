# Stack Bootstrap

Automated deployment of a **Headscale** + **Traefik** + **Forgejo** server stack on a VPS using Ansible.

## Architecture

| Service    | Role                                        | Access                                     |
|------------|---------------------------------------------|--------------------------------------------|
| Headscale  | Self-hosted Tailscale control server (VPN)  | Public HTTPS (`HEADSCALE_DOMAIN`)          |
| Tailscale  | VPS node on the tailnet                     | Tailnet `100.x.y.z`, UDP 41641             |
| Traefik    | Public/private reverse proxy                | Public `80/443`, tailnet `100.x.y.z:443`   |
| Forgejo    | Private Git forge                           | HTTPS through the tailnet only             |

Flow:

- Control plane: `Clients → Headscale (https://HEADSCALE_DOMAIN)` for registration, keys and ACLs
- Data plane: direct WireGuard between nodes (UDP 41641), DERP relay as fallback
- Forgejo: `Tailnet → Traefik private (100.x.y.z:443) → Forgejo (3000)`

Clients use the official **Tailscale** apps (Linux, Windows, macOS, Android, iOS) pointed at the self-hosted Headscale server.

## Prerequisites

- A VPS (Debian/Ubuntu) with ports **22**, **80**, **443** (TCP) and **41641** (UDP) allowed
- Docker installed on **your machine** (to run Ansible in a container)
- A DuckDNS domain (e.g. `jortexops.duckdns.org`) pointing to the VPS public IP, plus a dedicated subdomain for Headscale (`headscale.jortexops.duckdns.org`) and one for Forgejo (`git.jortexops.duckdns.org`)
- An SSH key authorized on the VPS (`/root/.ssh/authorized_keys`)

## Project Structure

```
.
├── ansible.cfg              # Ansible configuration
├── Dockerfile               # Image for running Ansible
├── Makefile                 # Shortcut commands (make deploy, make check...)
├── README.md
├── inventory.yml            # Hosts (VPS IP)
├── playbook.yml             # Deployment steps (includes tasks/)
├── .env.example             # Variable template
├── .env                     # Actual variables (ignored by git)
├── docker-compose.yml       # Traefik + Headscale + Forgejo stack
├── tasks/                   # Playbook tasks, split by service
│   ├── base.yml                 # System packages, Docker, files
│   ├── stack.yml                # Start containers, Headscale user
│   ├── headscale.yml            # Headscale configuration
│   ├── tailscale.yml            # VPS node on the tailnet
│   ├── forgejo.yml              # Forgejo credentials
│   ├── forgejo-admin.yml        # Forgejo administrator
│   ├── cleanup.yml              # Legacy Innernet removal
│   └── hardening.yml            # ufw, reverse path, SSH
└── services/
    └── headscale/
        ├── config.yaml.j2       # Headscale server configuration
        ├── policy.hujson.j2     # Tailnet ACL policy (deny by default)
        └── client-setup.sh      # Client onboarding (Tailscale)
```

## Configuration

### 1. Environment variables (`.env`)

Copy the template and fill in the values:

```bash
cp .env.example .env
```

```env
ACME_EMAIL=your.email@example.com
FORGEJO_DOMAIN=git.jortexops.duckdns.org
HEADSCALE_DOMAIN=headscale.jortexops.duckdns.org
PUBLIC_IP=YOUR_VPS_PUBLIC_IP
ANSIBLE_IMAGE=my-ansible
```

| Variable            | Description                                                         |
|---------------------|---------------------------------------------------------------------|
| `ACME_EMAIL`        | Email address for Let's Encrypt certificates                        |
| `FORGEJO_DOMAIN`    | Forgejo domain, reachable only through the tailnet                  |
| `HEADSCALE_DOMAIN`  | Public HTTPS domain of the Headscale control server                 |
| `HEADSCALE_AUTHKEY` | Pre-auth key for the VPS node (see "Deployment", phase 2)           |
| `PUBLIC_IP`         | Public VPS address; overwritten from `inventory.yml`                |
| `TAILSCALE_IP`      | Tailscale IP of the VPS node; written automatically by Ansible      |
| `ANSIBLE_IMAGE`     | Docker image for running Ansible (default: `my-ansible`)            |

⚠️ `FORGEJO_DOMAIN` and `HEADSCALE_DOMAIN` **must be different** from each other and from the base DuckDNS domain used for the WireGuard endpoint — a hosts entry pointing Forgejo to the tailnet IP must never hijack the Headscale control domain.

### 2. Inventory (`inventory.yml`)

```yaml
all:
  hosts:
    vps-ia:
      ansible_host: VPS_IP_ADDRESS
      ansible_user: root
```

## Deployment

### Phase 1 — bring up Headscale

```bash
make deploy
```

This installs Docker, starts Traefik + Headscale + Forgejo, and creates the Headscale user. On the first run the VPS does not join the tailnet yet (no pre-auth key).

### Phase 2 — join the VPS to the tailnet

Create a pre-auth key and add it to `.env`:

```bash
# on the server
docker exec headscale headscale users list    # find the numeric ID of the 'default' user
docker exec headscale headscale preauthkeys create --user <ID> --reusable=false
```

```env
HEADSCALE_AUTHKEY=<paste the key>
```

Then re-run `make deploy`. Ansible installs the Tailscale client on the VPS, joins the tailnet, writes `TAILSCALE_IP` to `.env`, rebinds the private Traefik entrypoint to the tailnet address and **expires the pre-auth key** once the node is registered (single-use keys cannot be reused afterwards).

Once `TAILSCALE_IP` is set, the deploy also writes the **ACL policy** (`services/headscale/policy.hujson.j2`), validates it with `headscale policy check` and restarts Headscale so it applies.


### Manually with Docker

```bash
docker build -t my-ansible .

docker run --rm -it \
  -v "$PWD":/ansible \
  -v "$HOME/.ssh":/root/.ssh:ro \
  my-ansible -i inventory.yml playbook.yml
```

## Connecting a client

Clients use the official Tailscale app pointed at the Headscale server. `services/headscale/client-setup.sh` automates this on Debian/Ubuntu machines: it installs Tailscale, joins the tailnet with a pre-auth key, and adds the Forgejo hosts entry.

**1. The admin creates a pre-auth key on the server** (one per client):

```bash
docker exec headscale headscale users list    # find the numeric ID of the 'default' user
docker exec headscale headscale preauthkeys create --user <ID> --reusable=false
```

**2. On the client machine** (Debian/Ubuntu, with SSH access to the VPS or explicit env vars):

```bash
HEADSCALE_AUTHKEY=<key> ./services/headscale/client-setup.sh
```

The script is passive: it never creates keys or nodes — the admin does. Override the defaults with environment variables: `SERVER_HOST`, `SERVER_USER`, `HEADSCALE_DOMAIN`, `FORGEJO_DOMAIN`, `TAILSCALE_IP`, `HEADSCALE_AUTHKEY`, `NODE_NAME`.

### Phone (Android/iOS)

Install the official **Tailscale** app, add the Headscale server (`Add custom coordination server` → `https://HEADSCALE_DOMAIN`), sign in with the pre-auth key, and Forgejo is reachable at `https://FORGEJO_DOMAIN` once the hosts entry or MagicDNS resolves it.

## Tailnet ACL policy

The tailnet is **deny by default**. Once the VPS has a tailnet IP, Headscale enforces the policy from `services/headscale/policy.hujson.j2` (rendered to `/etc/headscale/policy.hujson` inside the container):

| Rule                        | Effect                                                    |
|-----------------------------|-----------------------------------------------------------|
| `* → <TAILSCALE_IP>:443`    | All nodes can reach Forgejo through the private Traefik   |
| `* → <TAILSCALE_IP>:22`     | All nodes can SSH to the VPS through the tailnet          |
| `* → *:*` (ICMP)            | All nodes can ping each other (debugging)                 |

Everything else is denied: nodes cannot reach each other directly (only the VPS services), so a compromised client cannot reach other clients or other ports of the VPS. The policy is only written after the VPS joins (when `TAILSCALE_IP` is known) — before that, Headscale stays permissive.

The policy is validated with `docker exec headscale headscale policy check --file /etc/headscale/policy.hujson` before Headscale is restarted, so an invalid policy aborts the deploy instead of locking the tailnet. To inspect or adjust it:

```bash
# on the server
docker exec headscale headscale policy check --file /etc/headscale/policy.hujson
cat /opt/ia-stack/headscale/policy.hujson
```

Note: Taildrop (file sharing) is governed by the same ACLs — add an explicit rule if you ever need it.

## Useful Commands

```bash
# Headscale administration (on the server)
docker exec headscale headscale users list
docker exec headscale headscale nodes list
docker exec headscale headscale preauthkeys list
docker exec headscale headscale nodes delete -i <node-id>

# Client
tailscale status
tailscale ip -4
```

```bash
make build   # Build the image
make check   # Check the playbook syntax (without running it)
make help    # List the commands
```

## Hardening

The playbook ends with a hardening section that:

- Enables **ufw** (allowing `22/tcp`, `80/tcp`, `443/tcp`, `41641/udp` and all traffic on the `tailscale0` interface, with a default-deny incoming policy and Docker-compatible forwarding)
- Enforces a **deny-by-default tailnet ACL policy** (Forgejo HTTPS, tailnet SSH and ICMP only — see "Tailnet ACL policy")
- **Expires the VPS pre-auth key automatically** after the node joins, so a leaked key is useless
- Enables **strict reverse path filtering** (RFC 3704)
- Locks down **SSH to key-only authentication** (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`) — skipped with a warning if no key is found, to avoid locking yourself out
- Creates a dedicated sudo user (`deploy` by default, `ssh_admin_user` variable), copies the root SSH key to it and grants passwordless sudo
- Removes the old Innernet service and firewall rules

### Disabling root SSH (optional, recommended)

The playbook keeps `PermitRootLogin prohibit-password` by default. To fully disable root SSH, do this **in order** to avoid locking yourself out:

1. Deploy once (as root) so the `deploy` user and its key are created: `make deploy`
2. Verify you can log in as the new user: `ssh deploy@45.147.97.211`
3. Set `ansible_user: deploy` in `inventory.yml`
4. Set `ssh_disable_root: true` in `playbook.yml` and deploy again — the playbook verifies the `deploy` user has a key before cutting root, and validates the SSH config (`sshd -t`) before restarting

## Troubleshooting

- **HTTPS certificate is not generated**: make sure `HEADSCALE_DOMAIN` and `FORGEJO_DOMAIN` resolve publicly to the VPS IP and that ports 80/443 are open.
- **Clients cannot register with Headscale**: make sure `HEADSCALE_DOMAIN` is reachable publicly over HTTPS and the pre-auth key is valid (non-reusable keys expire after one use).
- **Forgejo is unreachable from the tailnet**: make sure the client is connected (`tailscale status`), the VPS node is up, and the Forgejo domain resolves to `TAILSCALE_IP` (hosts entry or MagicDNS).
- **No direct connection between nodes**: open UDP 41641 inbound; otherwise clients fall back to DERP relays.
- **A service became unreachable after the ACL policy was applied**: the policy is deny-by-default — check `/opt/ia-stack/headscale/policy.hujson` and add the missing rule, then `docker exec headscale headscale policy check --file /etc/headscale/policy.hujson && docker restart headscale`.
- **SSH connection failed**: make sure your key is present in `/root/.ssh/authorized_keys` on the VPS.
- **Permission error**: the playbook automatically installs Docker and copies the files to `/opt/ia-stack`.
