-include .env

ANSIBLE_IMAGE ?= my-ansible
INVENTORY     := inventory.yml
PLAYBOOK      := playbook.yml
ANSIBLE_ARGS  ?=
SSH_PRIVATE_KEY ?= ~/.ssh/id_ed25519

.DEFAULT_GOAL := help

.PHONY: build deploy check help

build:
	docker build -t $(ANSIBLE_IMAGE) .

deploy: build
	docker run --rm -it \
		-e PUBLIC_IP=$(PUBLIC_IP) \
		-v "$(CURDIR)":/ansible \
		-v $(SSH_PRIVATE_KEY):/root/.ssh/id_ed25519:ro \
		$(ANSIBLE_IMAGE) -i $(INVENTORY) $(PLAYBOOK) $(ANSIBLE_ARGS)

check: build
	docker run --rm \
		-v "$(CURDIR)":/ansible \
		$(ANSIBLE_IMAGE) -i $(INVENTORY) $(PLAYBOOK) --syntax-check

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
