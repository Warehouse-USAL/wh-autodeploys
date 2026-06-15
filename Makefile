.PHONY: help up down logs reconcile redeploy redeploy-backend redeploy-dashboard

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

# --- redeploy: dispatch a service's Deploy workflow (uses GH_PAT from .env) ---
define _dispatch
	@set -a; . ./.env; set +a; \
	curl -fsS -o /dev/null -w "$(1) redeploy dispatched (HTTP %{http_code})\n" -X POST \
	  -H "Authorization: Bearer $$GH_PAT" -H "Accept: application/vnd.github+json" \
	  "https://api.github.com/repos/$$GH_OWNER/$(1)/actions/workflows/deploy.yml/dispatches" \
	  -d '{"ref":"master"}'
endef

redeploy-backend: ## Trigger a production redeploy of the backend
	$(call _dispatch,wh-backend)

redeploy-dashboard: ## Trigger a production redeploy of the dashboard
	$(call _dispatch,Dashboard)

redeploy: redeploy-backend redeploy-dashboard ## Trigger a redeploy of both services
