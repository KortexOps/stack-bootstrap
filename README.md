# Stack Bootstrap

Automated deployment of a **Traefik** + **Forgejo** server stack on a VPS using Ansible.

## Architecture

| Service  | Role                              | Access                      |
|----------|-----------------------------------|----------------------------|
| Traefik  | Reverse proxy + automatic HTTPS   | Ports 80 / 443             |
| Forgejo  | Git forge (repository hosting)    | `https://<FORGEJO_DOMAIN>` |

Flow: `Internet → Traefik (443) → Forgejo (3000)`

## Prerequisites

- A VPS (Debian/Ubuntu) with ports **22**, **80**, and **443** open
- Docker installed on **your machine** (to run Ansible in a container)
- A hostname pointing to the VPS IP address (free DuckDNS, or a real domain)
- An SSH key authorized on the VPS (`/root/.ssh/authorized_keys`)

## Project Structure

```
.
├── ansible.cfg              # Ansible configuration
├── Dockerfile               # Image for running Ansible
├── Makefile                 # Shortcut commands (make deploy, make check...)
├── README.md
├── inventory.yml            # Hosts (VPS IP)
├── playbook.yml             # Deployment steps
├── .env.example             # Variable template
├── .env                     # Actual variables (ignored by git)
└── files/
    └── docker-compose.yml   # Traefik + Forgejo stack
```

## Configuration

### 1. Environment variables (`.env`)

Copy the template and fill in the values:

```bash
cp .env.example .env
```

```env
ACME_EMAIL=your.email@example.com
FORGEJO_DOMAIN=git.example.com
ANSIBLE_IMAGE=my-ansible
```

| Variable         | Description                                           |
|------------------|-------------------------------------------------------|
| `ACME_EMAIL`     | Email address for Let's Encrypt certificates          |
| `FORGEJO_DOMAIN` | Domain used to access Forgejo (DNS → VPS IP)          |
| `ANSIBLE_IMAGE`  | Docker image for running Ansible (default: `my-ansible`) |

### 2. Inventory (`inventory.yml`)

```yaml
all:
  hosts:
    vps-ia:
      ansible_host: VPS_IP_ADDRESS
      ansible_user: root
```

## Deployment

### Using Make (recommended)

```bash
make deploy
```

### Manually with Docker

```bash
docker build -t my-ansible .

docker run --rm -it \
  -v "$PWD":/ansible \
  -v "$HOME/.ssh":/root/.ssh:ro \
  my-ansible -i inventory.yml playbook.yml
```

## After Deployment

1. Open `https://<FORGEJO_DOMAIN>`
2. Complete the Forgejo installation (admin account, database...)

## Useful Commands

```bash
make build   # Build the image
make check   # Check the playbook syntax (without running it)
make help    # List the commands
```

## Troubleshooting

- **HTTPS certificate is not generated**: make sure the DNS points to the VPS IP address and that ports 80/443 are open.
- **SSH connection failed**: make sure your key is present in `/root/.ssh/authorized_keys` on the VPS.
- **Permission error**: the playbook automatically installs Docker and copies the files to `/opt/ia-stack`.
