# ─── Operator Makefile (CI doesn't use this — it calls docker run directly) ──
-include .env

ANSIBLE_IMAGE ?= my-ansible
INVENTORY      ?= inventory-prod.yml
PLAYBOOK       ?= playbook.yml
ANSIBLE_ARGS   ?=
# Safer default; .env overrides it (set ANSIBLE_USER=root for the very first
# bootstrap on a fresh VPS before the deploy user exists).
ANSIBLE_USER   ?= deploy
SSH_PRIVATE_KEY ?= $(HOME)/.ssh/id_ed25519
SSH_KNOWN_HOSTS ?= $(HOME)/.ssh/known_hosts

# Remote shell for Headscale helpers and backup/restore targets.
SERVER_USER    ?= deploy
SERVER_HOST    ?=
HEADSCALE_USER ?= default
HEADSCALE_CONTAINER ?= ia-stack-headscale
STACK_DIR_PROD ?= /opt/ia-stack
STACK_DIR_DEV  ?= /opt/ia-stack-dev
SSH_OPTS       := -o BatchMode=yes -o ConnectTimeout=10 -i $(SSH_PRIVATE_KEY)
SSH_TARGET     := $(SERVER_USER)@$(SERVER_HOST)
ifeq ($(SERVER_USER),root)
  DOCKER_SUDO :=
else
  DOCKER_SUDO := sudo -n
endif

.DEFAULT_GOAL := help

.PHONY: build bootstrap check help id key key_id keys key_del key_expire backup backup-dev restore restore-dev ci-enable ci-disable ci-status

# ─── Recovery (NOT for updates — updates go through git/CI) ─────────────────

build: ## Build the Ansible Docker image
	docker build --pull -t $(ANSIBLE_IMAGE) .

# Full rebuild after a total deletion of the VPS (or the stack). Deploys the
# whole prod stack from scratch (--tags all), then restores data from the
# Google Drive backups. Forgejo runs ON this VPS, so after a wipe you MUST use
# this target to bring it back before git-driven updates can work again.
#
# For a fresh VPS: set ANSIBLE_USER=root in .env for the first run, and set a
# fresh HEADSCALE_AUTHKEY (make key) so the VPS rejoins the tailnet.
bootstrap: build ## Rebuild the whole stack from scratch and restore data from Drive
	@test -f "$(SSH_PRIVATE_KEY)" || (echo "SSH private key not found: $(SSH_PRIVATE_KEY)" >&2; exit 1)
	@test -f "$(SSH_KNOWN_HOSTS)" || (echo "SSH known_hosts not found: $(SSH_KNOWN_HOSTS)" >&2; exit 1)
	@test -f .env || (echo ".env not found; copy .env.example to .env" >&2; exit 1)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	@read -r -p "⚠ This REBUILDS the whole stack and REPLACES data from Drive backups. Type 'bootstrap' to confirm: " REPLY; \
	[ "$$REPLY" = "bootstrap" ] || { echo "Aborted."; exit 1; }
	docker run --rm \
		--env-file .env \
		-e PUBLIC_IP="$(PUBLIC_IP)" \
		-e ANSIBLE_USER="$(ANSIBLE_USER)" \
		-v "$(CURDIR):/ansible" \
		-v "$(SSH_PRIVATE_KEY):/root/.ssh/id_ed25519:ro" \
		-v "$(SSH_KNOWN_HOSTS):/root/.ssh/known_hosts:ro" \
		$(ANSIBLE_IMAGE) -i inventory-prod.yml $(PLAYBOOK) --tags all $(ANSIBLE_ARGS)
	@echo "==> Restoring data from Drive backups (if any)..."
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) STACK_DIR=$(STACK_DIR_PROD) $(STACK_DIR_PROD)/restore.sh $(STAMP)" \
	  || echo "!! restore step failed. On a brand-new VPS there may be no Drive backups yet — that is expected."
	@echo ""
	@echo "==> Bootstrap done. To re-enable CI/CD, restart the runner on the VPS:"
	@echo "      echo 'TOKEN' | sudo tee /opt/ia-stack/.runner_token && sudo chmod 600 /opt/ia-stack/.runner_token"
	@echo "      sudo docker compose -f /opt/ia-stack/docker-compose.runner.yml up -d"

check: build ## Syntax-check the playbook against all inventories
	docker run --rm -v "$(CURDIR):/ansible" $(ANSIBLE_IMAGE) -i inventory-prod.yml $(PLAYBOOK) --syntax-check
	docker run --rm -v "$(CURDIR):/ansible" $(ANSIBLE_IMAGE) -i inventory-dev.yml $(PLAYBOOK) --syntax-check

# ─── Headscale helpers ──────────────────────────────────────────────────────

id: ## List Headscale users and their numeric IDs
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale users list"

key: ## Generate a single-use pre-auth key (name or numeric ID via HEADSCALE_USER)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	@user='$(HEADSCALE_USER)'; \
	id="$$user"; \
	if ! printf '%s' "$$user" | grep -qE '^[0-9]+$$'; then \
		id=$$(ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale users list -n $$user -o json" \
			| grep -oE '"id"[[:space:]]*:[[:space:]]*"?[0-9]+"?' \
			| grep -oE '[0-9]+' \
			| head -n1); \
		test -n "$$id" || { echo "User '$$user' not found. Run 'make id' to list users." >&2; exit 1; }; \
	fi; \
	printf 'Using user ID %s\n' "$$id"; \
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale preauthkeys create --user $$id --reusable=false"

key_id: ## Generate a single-use pre-auth key for a numeric user ID (make key_id ID=<id>)
	@test -n "$(ID)" || (echo "Usage: make key_id ID=<user-id>" >&2; exit 1)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale preauthkeys create --user $(ID) --reusable=false"

keys: ## List all pre-auth keys
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale preauthkeys list"

key_del: ## Delete a pre-auth key by ID (make key_del ID=<id>)
	@test -n "$(ID)" || (echo "Usage: make key_del ID=<key-id>" >&2; exit 1)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale preauthkeys delete --id $(ID)"

key_expire: ## Expire a pre-auth key by ID (make key_expire ID=<id>)
	@test -n "$(ID)" || (echo "Usage: make key_expire ID=<key-id>" >&2; exit 1)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker exec $(HEADSCALE_CONTAINER) headscale preauthkeys expire --id $(ID)"

# ─── Backup / Restore ───────────────────────────────────────────────────────

backup: ## Back up prod Forgejo + Headscale to Google Drive
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) STACK_DIR=$(STACK_DIR_PROD) $(STACK_DIR_PROD)/backup.sh"

backup-dev: ## Back up the dev stack (local dumps on the VPS)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) STACK_DIR=$(STACK_DIR_DEV) $(STACK_DIR_DEV)/backup.sh"

restore: ## Restore prod from latest Google Drive backup (make restore [STAMP=<ts>])
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) STACK_DIR=$(STACK_DIR_PROD) $(STACK_DIR_PROD)/restore.sh $(STAMP)"

restore-dev: ## Restore dev from its local backups
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) STACK_DIR=$(STACK_DIR_DEV) $(STACK_DIR_DEV)/restore.sh $(STAMP)"

# ─── CI/CD (Forgejo Actions runner) ────────────────────────────────────────
# Enabling/disabling CI/CD starts/stops the self-hosted runner container on
# the VPS (docker-compose.runner.yml). Jobs are only picked up while the runner
# is up. The compose file interpolates ${FORGEJO_DOMAIN} from the stack's .env,
# so the commands cd into STACK_DIR_PROD first (SSH starts in the deploy user's
# home, where no .env exists).

ci-enable: ## Enable CI/CD — start the Forgejo Actions runner on the VPS
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	@ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) test -s $(STACK_DIR_PROD)/.runner_token" \
	  || { echo "!! No runner registration token on the VPS ($(STACK_DIR_PROD)/.runner_token missing or empty)." >&2; \
	       echo "   Create one: Forgejo → Site Administration → Actions → Runners → Create new runner" >&2; \
	       echo "   then: echo 'TOKEN' | sudo tee $(STACK_DIR_PROD)/.runner_token && sudo chmod 600 $(STACK_DIR_PROD)/.runner_token" >&2; \
	       exit 1; }
	@echo "==> Starting the CI runner..."
	ssh $(SSH_OPTS) $(SSH_TARGET) "cd $(STACK_DIR_PROD) && $(DOCKER_SUDO) docker compose -f docker-compose.runner.yml up -d"
	@echo "==> CI/CD enabled. Verify: https://$(FORGEJO_DOMAIN)/admin/actions/runners"

ci-disable: ## Disable CI/CD — stop the Forgejo Actions runner (jobs stop being picked up)
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "cd $(STACK_DIR_PROD) && $(DOCKER_SUDO) docker compose -f docker-compose.runner.yml stop"
	@echo "==> CI/CD disabled. Re-enable with 'make ci-enable'."

ci-status: ## Show whether the CI/CD runner is running
	@test -n "$(SERVER_HOST)" || (echo "SERVER_HOST is required in .env" >&2; exit 1)
	ssh $(SSH_OPTS) $(SSH_TARGET) "$(DOCKER_SUDO) docker ps -a --filter name=forgejo-runner --format '{{.Names}}\t{{.Status}}'"

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'