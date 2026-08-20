-include .env

ANSIBLE_IMAGE ?= my-ansible
INVENTORY     := inventory.yml
PLAYBOOK      := playbook.yml

.DEFAULT_GOAL := help

.PHONY: build deploy check help

build:
	docker build -t $(ANSIBLE_IMAGE) .

deploy: build
	docker run --rm -it \
		-v "$$(pwd)":/ansible \
		-v ~/.ssh:/root/.ssh:ro \
		$(ANSIBLE_IMAGE) -i $(INVENTORY) $(PLAYBOOK)

check: build
	docker run --rm \
		-v "$$(pwd)":/ansible \
		$(ANSIBLE_IMAGE) -i $(INVENTORY) $(PLAYBOOK) --syntax-check

help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
