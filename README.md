# wh-autodeploys

Deployment infrastructure for the Warehouse-USAL system, **as containers**. The
only thing installed on the host is the Docker engine — runners, reverse proxy,
and the reconcile safety net all run as containers from this one compose file.

This repo owns *how the box reaches services and how it recovers*. Each app repo
deploys itself (its own `make deploy` + `release`-triggered workflow that runs on
a self-hosted runner here).

## Components (all containers)

| Service | Purpose |
|---|---|
| `caddy` | Reverse proxy — the **single exposed port** (:80). `/app/*` → webapp, `/dashboard/*` → dashboard (both prefix-stripped), everything else (`/auth`, `/products`, `/ws`, `/`) → backend at root. |
| `runner-backend` / `runner-dashboard` / `runner-webapp` | Self-hosted GitHub Actions runners. Self-register from a PAT, long-poll GitHub **outbound**, and deploy via the host Docker daemon (docker.sock mounted). |
| `reconcile` | Clones missing app repos and, on a loop, converges each to its latest release. Safety net for first boot, long power-offs, and drift. |

The runners use **Docker-out-of-Docker**: they mount `/var/run/docker.sock` and
`/opt/wh` (same path host↔container) so the containers they deploy are siblings
on the host, not nested.

## Bring up a fresh box

```bash
curl -fsSL https://raw.githubusercontent.com/Warehouse-USAL/wh-autodeploys/master/scripts/init.sh | bash
# fills in /opt/wh/wh-autodeploys/.env on first run — set GH_OWNER + GH_PAT, re-run
```

Then it's just `docker compose up -d --build` (which `init.sh` runs for you).
See `.env.example` for the infra secrets (just `GH_OWNER` + a `GH_PAT` with
`repo` + `read:packages`).

**App config is separate.** Each app's runtime config lives in its own `.env`,
copied from the repo's shipped `.env.example`:

```bash
cp /opt/wh/wh-backend/.env.example        /opt/wh/wh-backend/.env         # Mongo URI, JWT, ...
cp /opt/wh/Dashboard/.env.example         /opt/wh/Dashboard/.env          # no BACKEND_URL needed
cp /opt/wh/smarthouse_webapp/.env.example /opt/wh/smarthouse_webapp/.env  # no BACKEND_URL needed
```

The two frontends call the backend with bare paths (`/auth`, `/products`, ...)
which the Caddy proxy routes to the backend at root — so neither needs a
`BACKEND_URL`.

## How a deploy flows

1. App CI builds an image, pushes it to GHCR on a stable release.
2. The release triggers that repo's `deploy.yml` on its runner container here.
3. The job logs into GHCR and runs `make deploy` → `docker compose pull && up -d <svc>`
   against the host daemon, recreating only that service.
4. If the box was off and missed releases, `reconcile` converges it on next boot.

## Security note

The runners mount the Docker socket — that's root-equivalent access to the host.
Acceptable for a private, single-team box; tighten later with a socket proxy if
this goes multi-tenant.
