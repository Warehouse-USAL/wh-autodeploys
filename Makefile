.PHONY: help up down logs reconcile

.DEFAULT_GOAL := help

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Start the reverse proxy (creates the shared network if missing)
	docker network create wh-proxy 2>/dev/null || true
	docker compose up -d

down: ## Stop the reverse proxy
	docker compose down

logs: ## Tail the proxy logs
	docker compose logs -f caddy

reconcile: ## Converge all app repos to their latest release now
	./scripts/reconcile.sh
