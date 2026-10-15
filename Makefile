# hacklab — provisioning a reverse-engineering / dev VM on Hetzner Cloud.
#
#   make init     download the hcloud provider (run once)
#   make plan     show what would change
#   make up       create/update the server, then wait until it is ready
#   make ssh      open a shell on the server
#   make status   show outputs + whether the box is provisioned yet
#   make destroy  delete everything (stops Hetzner billing)
#
# HCLOUD_TOKEN must be exported in your environment. Nothing here is hardcoded.

SHELL := /bin/bash
.DEFAULT_GOAL := help

TOFU ?= tofu
SCRIPTS := scripts

# Public key used by 'make adopt-ssh-key' (defaults to ~/.ssh/id_ed25519.pub when empty).
SSH_PUBKEY ?=

# Pull the connection details from OpenTofu so targets don't repeat themselves.
SSH_HOST := $(shell $(TOFU) output -raw server_ipv4 2>/dev/null)
SSH_USER := $(shell $(TOFU) output -raw username 2>/dev/null)

.PHONY: help init fmt validate plan up ssh status password logs wait-ready verify destroy adopt-ssh-key

help: ## Show this help
	@echo "hacklab targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Remember to: export HCLOUD_TOKEN=<your-token>"

init: ## Initialise the working directory (downloads the hcloud provider)
	$(TOFU) init

fmt: ## Format all .tf files
	$(TOFU) fmt -recursive

validate: ## Validate the configuration
	$(TOFU) validate

plan: ## Show the execution plan
	$(TOFU) plan

up: ## Apply the plan, then wait until cloud-init reports the box is ready
	$(TOFU) apply
	@echo
	@echo ">>> Server created. Waiting for provisioning to finish..."
	@$(MAKE) --no-print-directory wait-ready

ssh: ## Open an SSH session on the server
	@test -n "$(SSH_HOST)" || { echo "No server yet — run 'make up' first." >&2; exit 1; }
	ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$(SSH_HOST)

status: ## Show server outputs and provisioning state
	@echo "== hacklab status =="
	@$(TOFU) output
	@echo
	@if [ -z "$(SSH_HOST)" ]; then \
	  echo "Server: not created yet (or outputs not applied)."; \
	elif ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
	     $(SSH_USER)@$(SSH_HOST) 'test -f /var/lib/hacklab/ready' 2>/dev/null; then \
	  echo "Provisioning: READY (/var/lib/hacklab/ready present)."; \
	else \
	  echo "Provisioning: in progress or unreachable."; \
	  echo "  Follow the log:  make logs"; \
	fi

password: ## Print the generated console password (sensitive)
	@$(TOFU) output -raw password
	@echo

logs: ## Tail the cloud-init setup log on the server
	@test -n "$(SSH_HOST)" || { echo "No server yet — run 'make up' first." >&2; exit 1; }
	ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$(SSH_HOST) 'tail -f /var/log/hacklab-setup.log'

wait-ready: ## Wait for cloud-init to finish (writes /var/lib/hacklab/ready)
	@$(SCRIPTS)/wait-ready.sh

adopt-ssh-key: ## Fix "SSH key not unique" by importing your existing project key
	@$(SCRIPTS)/adopt-ssh-key.sh "$(SSH_PUBKEY)"

verify: ## Run the on-server verification table + Ghidra smoke test
	@test -n "$(SSH_HOST)" || { echo "No server yet — run 'make up' first." >&2; exit 1; }
	scp -o StrictHostKeyChecking=accept-new $(SCRIPTS)/verify.sh $(SSH_USER)@$(SSH_HOST):/tmp/verify.sh
	ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$(SSH_HOST) 'bash /tmp/verify.sh'

destroy: ## Destroy all managed resources
	$(TOFU) destroy
