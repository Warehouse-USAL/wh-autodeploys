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

**Guided (recommended)** — prompts for everything, sets it all up, prints your URLs:

```bash
curl -fsSL https://raw.githubusercontent.com/Warehouse-USAL/wh-autodeploys/main/scripts/init.sh | bash
```

You can pre-set any prompt as an env var to run it unattended (e.g. over SSH):

```bash
GHCR_USER=... GHCR_PAT=... RUNNER_TOKEN_BACKEND=... \
JWT_SECRET=... SPRING_DATA_MONGODB_URI=... MONGO_ROOT_USER=... MONGO_ROOT_PASSWORD=... \
  ./scripts/init.sh
```

Leave `RUNNER_TOKEN_DASHBOARD` unset to set up the backend only (e.g. before the
Dashboard image exists in GHCR).

**Low-level** — `scripts/bootstrap.sh` does the box plumbing (Docker, runners,
proxy, boot unit) without prompts or `.env`/bring-up; `init.sh` wraps it.

See `.env.example` for the variables. Full design + implementation plan in `docs/`.
