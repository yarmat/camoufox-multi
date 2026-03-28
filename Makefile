.DEFAULT_GOAL := help
SHELL := /bin/bash

ACCOUNTS_DIR := accounts

# Resolve PORT from account .env for display purposes
_port = $(shell grep '^PORT=' $(ACCOUNTS_DIR)/$(ACCOUNT)/.env 2>/dev/null | cut -d= -f2)

# ─── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "Camoufox Multi-Account Browser Manager"
	@echo ""
	@echo "Usage:"
	@echo "  make new                      Interactive account creation"
	@echo "  make up     ACCOUNT=<name>    Start account container"
	@echo "  make down   ACCOUNT=<name>    Stop account container"
	@echo "  make restart ACCOUNT=<name>   Restart account container"
	@echo "  make logs   ACCOUNT=<name>    Follow container logs"
	@echo "  make status                   Show running containers"
	@echo "  make list                     List all accounts with status"
	@echo "  make set-proxy ACCOUNT=<name> Update proxy for account"
	@echo "  make clean  ACCOUNT=<name>    Wipe browser profile"
	@echo "  make fresh  ACCOUNT=<name>    Wipe profile + generate new fingerprint seed"
	@echo "  make remove ACCOUNT=<name>    Remove container + account folder"
	@echo "  make check-leaks ACCOUNT=<name> Run leak detection inside container"
	@echo "  make build                    Build Docker image"

# ─── Core ────────────────────────────────────────────────────────────────────

.PHONY: build
build:
	docker build -t camoufox .

.PHONY: new
new:
	@bash scripts/new-account.sh

.PHONY: up
up: _require-account
	@docker compose --env-file $(ACCOUNTS_DIR)/$(ACCOUNT)/.env up -d
	@echo "✓ $(ACCOUNT) → http://localhost:$(_port)/vnc.html"

.PHONY: down
down: _require-account
	@docker compose --env-file $(ACCOUNTS_DIR)/$(ACCOUNT)/.env down

.PHONY: restart
restart: _require-account down up

.PHONY: logs
logs: _require-account
	@docker compose --env-file $(ACCOUNTS_DIR)/$(ACCOUNT)/.env logs -f

# ─── Status & Listing ────────────────────────────────────────────────────────

.PHONY: status
status:
	@printf "%-20s %-20s %s\n" "ACCOUNT" "STATUS" "URL"
	@printf "%-20s %-20s %s\n" "-------" "------" "---"
	@for env_file in $(ACCOUNTS_DIR)/*/.env; do \
		[ -f "$$env_file" ] || continue; \
		name=$$(grep '^ACCOUNT=' "$$env_file" | cut -d= -f2); \
		port=$$(grep '^PORT=' "$$env_file" | cut -d= -f2); \
		status=$$(docker ps --filter "name=camoufox-$$name" --format "{{.Status}}" 2>/dev/null); \
		if [ -n "$$status" ]; then \
			printf "%-20s %-20s %s\n" "$$name" "$$status" "http://localhost:$$port/vnc.html"; \
		fi; \
	done

.PHONY: list
list:
	@printf "%-20s %-10s %s\n" "ACCOUNT" "STATUS" "URL"
	@printf "%-20s %-10s %s\n" "-------" "------" "---"
	@for env_file in $(ACCOUNTS_DIR)/*/.env; do \
		[ -f "$$env_file" ] || continue; \
		name=$$(grep '^ACCOUNT=' "$$env_file" | cut -d= -f2); \
		port=$$(grep '^PORT=' "$$env_file" | cut -d= -f2); \
		running=$$(docker ps --filter "name=camoufox-$$name" --format "{{.Names}}" 2>/dev/null); \
		if [ -n "$$running" ]; then \
			status="running"; \
		else \
			status="stopped"; \
		fi; \
		printf "%-20s %-10s %s\n" "$$name" "$$status" "http://localhost:$$port/vnc.html"; \
	done

# ─── Proxy Management ────────────────────────────────────────────────────────

.PHONY: set-proxy
set-proxy: _require-account
	@echo "=== Update proxy for $(ACCOUNT) ==="
	@read -rp "Proxy type (http/socks5) [http]: " ptype; \
	ptype=$${ptype:-http}; \
	read -rp "Proxy address (host:port): " paddr; \
	if [ -z "$$paddr" ]; then echo "Error: address required"; exit 1; fi; \
	read -rp "Proxy login (Enter to skip): " plogin; \
	if [ -n "$$plogin" ]; then \
		read -rsp "Proxy password: " ppass; echo ""; \
		purl="$${ptype}://$${plogin}:$${ppass}@$${paddr}"; \
	else \
		purl="$${ptype}://$${paddr}"; \
	fi; \
	sed -i.bak \
		-e "s|^PROXY=.*|PROXY=$$purl|" \
		-e "s|^PROXY_TYPE=.*|PROXY_TYPE=$$ptype|" \
		$(ACCOUNTS_DIR)/$(ACCOUNT)/.env && \
	rm -f $(ACCOUNTS_DIR)/$(ACCOUNT)/.env.bak; \
	echo "✓ Proxy updated for $(ACCOUNT)"; \
	echo "  Restart with: make restart ACCOUNT=$(ACCOUNT)"

# ─── Leak Detection ──────────────────────────────────────────────────────────

.PHONY: check-leaks
check-leaks: _require-account
	@container="camoufox-$(ACCOUNT)"; \
	if ! docker ps --format '{{.Names}}' | grep -q "^$$container$$"; then \
		echo "Error: container '$$container' is not running. Start it first: make up ACCOUNT=$(ACCOUNT)"; \
		exit 1; \
	fi; \
	echo "Running leak checks inside $$container ..."; \
	docker exec -i -u root "$$container" bash < scripts/check-leaks.sh

# ─── Cleanup ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean: _require-account
	@echo "This will delete the browser profile for '$(ACCOUNT)' (cookies, cache, history)."
	@read -rp "Are you sure? (y/N): " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf $(ACCOUNTS_DIR)/$(ACCOUNT)/profile/*; \
		echo "✓ Profile wiped for $(ACCOUNT)"; \
	else \
		echo "Aborted."; \
	fi

.PHONY: fresh
fresh: _require-account
	@echo "This will wipe the browser profile and generate a new fingerprint seed for '$(ACCOUNT)'."
	@read -rp "Are you sure? (y/N): " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		running=$$(docker ps --filter "name=camoufox-$(ACCOUNT)" --format "{{.Names}}" 2>/dev/null); \
		if [ -n "$$running" ]; then \
			docker compose --env-file $(ACCOUNTS_DIR)/$(ACCOUNT)/.env down; \
		fi; \
		rm -rf $(ACCOUNTS_DIR)/$(ACCOUNT)/profile/*; \
		new_seed=$$(python3 -c 'import random; print(random.randint(0, 4294967295))'); \
		sed -i.bak "s|^CAM_SEED=.*|CAM_SEED=$$new_seed|" $(ACCOUNTS_DIR)/$(ACCOUNT)/.env && \
		rm -f $(ACCOUNTS_DIR)/$(ACCOUNT)/.env.bak; \
		echo "✓ Profile wiped, new fingerprint seed: $$new_seed"; \
		echo "  Start with: make up ACCOUNT=$(ACCOUNT)"; \
	else \
		echo "Aborted."; \
	fi

.PHONY: remove
remove: _require-account
	@echo "This will PERMANENTLY delete container and all data for '$(ACCOUNT)'."
	@read -rp "Are you sure? (y/N): " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		docker compose --env-file $(ACCOUNTS_DIR)/$(ACCOUNT)/.env down --volumes 2>/dev/null || true; \
		rm -rf $(ACCOUNTS_DIR)/$(ACCOUNT); \
		echo "✓ Account '$(ACCOUNT)' removed"; \
	else \
		echo "Aborted."; \
	fi

# ─── Internal ────────────────────────────────────────────────────────────────

.PHONY: _require-account
_require-account:
	@if [ -z "$(ACCOUNT)" ]; then \
		echo "Error: ACCOUNT is required. Usage: make $(MAKECMDGOALS) ACCOUNT=<name>"; \
		exit 1; \
	fi
	@if [ ! -f "$(ACCOUNTS_DIR)/$(ACCOUNT)/.env" ]; then \
		echo "Error: account '$(ACCOUNT)' not found (missing $(ACCOUNTS_DIR)/$(ACCOUNT)/.env)"; \
		exit 1; \
	fi