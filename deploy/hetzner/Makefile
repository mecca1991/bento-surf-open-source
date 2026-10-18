# Operate the Bento stack on the VM. Run from anywhere:  make -C /opt/bento/src/deploy/hetzner <target>
#
#   make check        verify secrets exist and contain no placeholders
#   make up-db        start only Postgres (first boot / before a restore)
#   make restore dump=/opt/bento/x.dump
#   make build        build the bento-app image (uses bento.env as a BuildKit secret)
#   make up           start everything
#   make logs s=bento_app
#   make psql         psql into bento_db as supabase_admin

BENTO_HOME ?= /opt/bento
DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENV_FILE := $(BENTO_HOME)/secrets/compose.env
COMPOSE := docker compose --env-file $(ENV_FILE) -f $(DIR)/docker-compose.yml

.DEFAULT_GOAL := help
.PHONY: help check up-db up down restart ps logs build pull restore backup psql config

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

check: ## Secrets present, mode 600, no placeholders left
	@test -f $(ENV_FILE) || { echo "missing $(ENV_FILE) — run init-secrets.sh"; exit 1; }
	@test -f $(BENTO_HOME)/secrets/bento.env || { echo "missing bento.env — run init-secrets.sh"; exit 1; }
	@for f in $(ENV_FILE) $(BENTO_HOME)/secrets/bento.env; do \
	  [ "$$(stat -c %a $$f)" = "600" ] || { echo "$$f must be mode 600"; exit 1; }; \
	  grep -nE '__(CARRY_OVER|RANDOM|ANON_KEY|SERVICE_ROLE_KEY|PG_PASSWORD|PUBLIC_HOST|CRON_TOKEN)__' $$f && { echo "placeholders remain in $$f"; exit 1; }; \
	done; echo "secrets ok"

config: check ## Render the merged compose config (secrets stay in the env files)
	$(COMPOSE) config --quiet && echo "compose config ok"

up-db: check ## Start Postgres only
	$(COMPOSE) up -d bento_db

restore: ## Restore the laptop dump into a fresh bento_db:  make restore dump=/opt/bento/x.dump
	@test -n "$(dump)" || { echo "usage: make restore dump=<file.dump>"; exit 1; }
	BENTO_DB_CONTAINER=bento_db $(DIR)/restore-from-dump.sh $(dump)

build: check ## Build the app image
	$(COMPOSE) build bento_app

up: check ## Start the whole stack
	$(COMPOSE) up -d

down: ## Stop and remove containers (volumes are kept)
	$(COMPOSE) down

restart: ## Restart one service or all:  make restart s=bento_app
	$(COMPOSE) restart $(s)

ps: ## Container status
	$(COMPOSE) ps

logs: ## Follow logs:  make logs s=bento_app
	$(COMPOSE) logs -f --tail=100 $(s)

pull: ## Pull the Supabase / nginx / alpine images
	$(COMPOSE) pull --ignore-buildable

backup: ## Local backup (db dump + state tarball) into $(BENTO_HOME)/backups
	BENTO_HOME=$(BENTO_HOME) $(DIR)/backup.sh

psql: ## psql into bento_db
	docker exec -it bento_db psql -U supabase_admin -d postgres
