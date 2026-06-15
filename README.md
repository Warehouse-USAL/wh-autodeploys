# wh-autodeploys

Deployment infrastructure for the Warehouse-USAL system. This repo owns **how
the box reaches services and how it recovers** — not the app deploys themselves
(each app repo deploys itself via its own `make deploy` + `release`-triggered
workflow on a self-hosted runner).

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` + `Caddyfile` | Caddy reverse proxy — the **single exposed port** (:80) routing `/api/*` → backend, `/` → dashboard. |
| `scripts/bootstrap.sh` | One-command setup for a fresh box (Docker, GHCR login, runners, proxy, boot unit). |
| `scripts/reconcile.sh` | Converge each app repo to its latest release. The safety net for long outages. |
| `systemd/wh-reconcile.service` | Runs `reconcile.sh` once on boot. |

## How it works

1. CI in each app repo builds an image and pushes it to GHCR on a stable release.
2. `release: published` triggers that repo's `deploy.yml` on a **self-hosted
   runner** running on this box (the runner long-polls GitHub outbound — the box
   never accepts inbound connections).
3. The runner runs `make deploy` → `docker compose pull && up -d <service>`,
   recreating only that service.
4. If the box was powered off and missed releases, `wh-reconcile.service` brings
   it to the latest release on next boot.

## Bring up a fresh box

```bash
GHCR_USER=... GHCR_PAT=... RUNNER_TOKEN_BACKEND=... RUNNER_TOKEN_DASHBOARD=... \
  ./scripts/bootstrap.sh
# then create /opt/wh/{wh-backend,Dashboard}/.env and:
make reconcile
```

See `.env.example` for the required variables. Full design + implementation plan
in `docs/`.
