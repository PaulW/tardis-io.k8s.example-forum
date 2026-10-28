# =====================================================================
# phpBB local development helpers
# =====================================================================
# Run `make help` for the list of targets.
#
# These targets wrap the docker compose commands so the day-to-day
# workflow does not need the long --profile invocations.
# =====================================================================

COMPOSE ?= docker compose
PHPBB_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
HTTP_PORT ?= 8080
BASE_URL ?= http://127.0.0.1:$(HTTP_PORT)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- Build ---------------------------------------------------------------

.PHONY: build
build: ## Build the production image
	$(COMPOSE) build phpbb

.PHONY: build-all
build-all: ## Build both the installer and production images
	$(COMPOSE) --profile install build phpbb-installer
	$(COMPOSE) build phpbb

# --- Database ------------------------------------------------------------

.PHONY: db-up
db-up: ## Start the MariaDB container only
	$(COMPOSE) up -d mariadb
	@echo "Waiting for MariaDB to become healthy..."
	@until [ "$$(docker inspect -f '{{.State.Health.Status}}' phpbb-mariadb 2>/dev/null)" = "healthy" ]; do \
		sleep 2; \
	done
	@echo "MariaDB is healthy."

# --- Install -------------------------------------------------------------

.PHONY: install
install: db-up ## Install the forum (schema + admin user). Run once.
	@echo "Running the phpBB installer..."
	$(COMPOSE) --profile install run --rm phpbb-installer
	@echo ""
	@echo "Install complete. Start the forum with: make up"

# --- Run -----------------------------------------------------------------

.PHONY: up
up: ## Start the forum
	$(COMPOSE) up -d phpbb
	@echo "Forum starting on $(BASE_URL)"

.PHONY: down
down: ## Stop the forum and the database
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop everything and delete the volumes (destroys the forum data)
	$(COMPOSE) --profile install --profile cron down -v

.PHONY: logs
logs: ## Follow the forum logs
	$(COMPOSE) logs -f phpbb

# --- Scheduled tasks -----------------------------------------------------

.PHONY: cron
cron: ## Run the scheduled tasks once
	$(COMPOSE) --profile cron run --rm phpbb-cron

.PHONY: cron-up
cron-up: ## Start the scheduled-task loop (runs the tasks every hour)
	$(COMPOSE) --profile cron up -d phpbb-cron

# --- Verification --------------------------------------------------------

# The connection limit is read from the deployment values, so the
# check against the pool size cannot be run with a stale number.
#
# The limit is set on the User CR by the chart, and the values file
# is where the deployment sets it. The file is parsed rather than
# duplicated, so the two cannot drift apart.
DB_MAX_CONNECTIONS ?= $(shell sed -n 's/^ *maxUserConnections: *\([0-9]*\).*/\1/p' $(PHPBB_DIR)../../deployment/environments/values.yaml 2>/dev/null | head -1)

.PHONY: verify
verify: ## Run the end-to-end verification script
	@echo "The database connection limit: $(DB_MAX_CONNECTIONS)"
	DB_MAX_CONNECTIONS=$(DB_MAX_CONNECTIONS) sh $(PHPBB_DIR)scripts/verify.sh

.PHONY: status
status: ## Show the container status
	$(COMPOSE) ps

.PHONY: shell
shell: ## Open a shell in the forum container
	$(COMPOSE) exec phpbb sh

.PHONY: php-shell
php-shell: ## Open a PHP shell with the forum's environment
	$(COMPOSE) exec phpbb php -a
