# Warehouse-USAL — Automated Release-to-Server CD

**Date:** 2026-06-15
**Author:** Mateo (backend lead)
**Status:** Design — pending implementation plan

## Problem

The three Warehouse-USAL repos already have a mature GitFlow + CI + release
pipeline that publishes Docker images to GHCR. What is **missing** is the
**CD layer**: nothing on the university-provided server ever pulls those images
and (re)starts the services. The server has **outbound** internet but **cannot
accept inbound** connections and cannot be exposed publicly yet, so the usual
"GitHub webhook pushes a deploy inward" model is impossible.

We need automatic, **trackable**, **per-service-independent** deploys to the
server, triggered by stable releases, without any inbound connection to the box.

## Constraints

- **Outbound-only server.** GitHub can never initiate a connection to the box.
  Any deploy must be **server-initiated** (the box reaches out).
- **No public exposure (yet).** Demo access is **university LAN only**. Design
  must leave a clean path to public exposure (reverse proxy / TLS) later.
- **Independent deployability.** A release of one service (e.g. backend) must
  deploy *only that service* and must not disturb the others or the stateful
  data services. Backend can be at v1.4 while Dashboard sits at v1.1.
- **Reuse existing pipeline.** GitFlow, branch validation, CI, and the
  `prerelease.yml` / `stable-release.yml` image-publishing workflows already
  exist and must not be rebuilt — the CD layer hangs off their release events.

## What already exists (do not rebuild)

- **GitFlow** across all 3 repos: `develop` default; enforced branch naming
  (`feature/`, `fix/`, `enhancement/`, `refactor/`, `hotfix/`, `beta/`,
  `backport/`, `dependabot/`); release flow `beta/<version>` → `master`.
- **CI** per repo: quality gates, tests + coverage, build.
- **Release pipeline:**
  - `prerelease.yml`: push to `beta/**` or `hotfix/**` → build + push image to
    GHCR with a derived pre-release tag + GitHub pre-release.
  - `stable-release.yml`: merge `beta/*`|`hotfix/*` → `master` → push
    `:version` + `:latest` to GHCR, create git tag, publish GitHub release,
    auto-backport to `develop`.
- **Images in GHCR:**
  - `ghcr.io/warehouse-usal/wh-backend` — published (on `develop`).
  - `ghcr.io/warehouse-usal/dashboard` — published, but the pipeline currently
    lives on `feature/gitflow-dockerization` (**precondition: merge to develop**).
- **Mobile (SmartWarehouse, Flutter):** `flutter build apk --release` → APK
  artifact. **Out of scope** for server CD.

## Decisions

| Decision | Choice |
|---|---|
| CD mechanism | **Self-hosted GitHub Actions runner on the server** (outbound long-poll) triggering a self-hosted PaaS |
| Deploy engine | **Dokploy** (self-hosted PaaS: UI, env/secret management, per-service logs, rollback) |
| Service model | **Backend + its data services in one Dokploy compose app** (`mongodb` + `redpanda` + `minio` co-located with the backend, but **never recreated on a backend deploy** — deploys are scoped to `docker compose up -d backend`); **Dashboard** as a separate Dokploy app. Each app deploys on its own release. |
| Deploy trigger | Each app repo's own `release: published` event deploys **only that service** |
| Stack home | New **`Warehouse-USAL/infra`** repo (single source of truth for deploy config + reusable workflow) |
| Reproducibility | **Config-as-code + bootstrap.** The `infra` repo is the source of truth; Dokploy is a thin runtime that points at the committed compose. University setup = `clone + one command`. |
| Staging | Build + prove the chain on the personal **Proxmox** lab first, then re-target the university server |

> **"data-services" defined:** the stateful backing services the backend
> depends on — **MongoDB** (database), **Redpanda** (Kafka-compatible broker),
> and **MinIO** (S3-compatible object storage). Grouped because they hold state
> (volumes), are shared, and rarely change version — unlike the stateless app
> containers that redeploy constantly.

## Architecture

### Components

1. **`Warehouse-USAL/infra` repo** — **the single source of truth for
   deployment** (config-as-code). Every decision is captured as a committed
   file, never only in the Dokploy UI:
   - **Backend compose** — the backend service **plus** its co-located data
     services (`mongodb`, `redpanda`, `minio`). The data services own the
     volumes, are brought up **once** by the bootstrap, and are **never
     recreated** by a routine backend deploy (see Service packaging below).
   - **Dashboard compose** — the dashboard service, a separate Dokploy app.
   - `.env.example` documenting every required secret/config. The real `.env`
     lives **only on the server** (in Dokploy's env management).
   - **`bootstrap.sh`** — a one-command setup script run on a fresh box that
     installs/points Dokploy at the committed compose and brings the stack up.
   - **Reusable deploy workflow** (`deploy.yml`, `workflow_call`) taking a
     `service` input — encodes "tell Dokploy to redeploy app X" once.
   - Runbook (`README`).

2. **Dokploy on the server** — self-hosted PaaS managing two compose apps:
   - `backend` app → GHCR `wh-backend` image **+ co-located data services**
     (`mongodb`, `redpanda`, `minio`).
   - `dashboard` app → GHCR `dashboard` image.
   Each app has its own version, logs, health, and rollback. All image/config
   fetches are **outbound**.

### Service packaging — why this is safe

The backend and its data services live in **one compose**, but the two have very
different lifecycles, so the deploy is **service-scoped**:

- **Bootstrap** brings up the full backend compose once (`up -d`), including the
  stateful Mongo/Redpanda/MinIO with their volumes.
- **A backend release deploy runs `docker compose up -d backend`** — Compose
  only recreates the `backend` container; the data services keep running,
  untouched, volumes intact. The deploy **must never** run `down`, `down -v`, or
  an unscoped `up` that could recreate the stateful services.

This keeps the backend's logical ownership of its data services (one compose,
one mental model) while guaranteeing a routine backend push can never disturb or
wipe the data. The data-service image tags are pinned, so even an unscoped `up`
would not pull new versions — but the deploy is scoped regardless, as defense in
depth.

3. **Self-hosted GitHub Actions runner on the server** — holds an outbound
   long-poll to GitHub; runs deploy jobs locally. **This is the inbound-constraint
   solver.** It calls Dokploy's deploy API/webhook over `localhost`.

4. **Thin `deploy.yml` in each app repo** (`wh-backend`, `Dashboard`) — fires on
   that repo's `release: published`, runs on the self-hosted runner, and calls
   the reusable workflow in `infra` with `service: backend` / `service: dashboard`.

### Trigger / data flow (per service, independent)

```
merge beta/* → master  (in wh-backend)
  → stable-release.yml: push :version + :latest to GHCR, publish GitHub release
    → release: published event (wh-backend only)
      → wh-backend/deploy.yml on the self-hosted runner
        → calls infra reusable workflow (service: backend)
          → triggers Dokploy "backend" app over localhost
            → Dokploy pulls new image, recreates ONLY the backend container
```

Dashboard follows the identical flow from its own release. The co-located data
services are brought up once by `bootstrap.sh` and are untouched by routine
service-scoped deploys.

### Why this respects the constraints

- **Outbound-only:** the runner connects out to GitHub; Dokploy pulls images out
  to GHCR; the deploy trigger crosses `localhost`, never the network boundary.
- **Trackable:** every deploy is a GitHub Actions run (logs in the Actions UI)
  *and* a Dokploy deployment record.
- **Independent:** each service is its own Dokploy resource triggered by its own
  release; no shared trigger, minimal blast radius.

## Out of scope

- Mobile/SmartWarehouse server deploy (APK artifact distribution handled
  separately).
- Public internet exposure / TLS (LAN-only now; Dokploy's built-in reverse
  proxy + Let's Encrypt is the clean upgrade path later).
- Multi-environment promotion (staging↔prod beyond the Proxmox-then-university
  re-target).

## Preconditions

- Merge `Dashboard`'s `feature/gitflow-dockerization` (its release pipeline)
  into `develop` so `dashboard` images publish from the mainline.
- A GHCR pull token usable by Dokploy on the server.
- A self-hosted runner registration token (org- or repo-scoped).

## Verification

A stable release of a single service results in:
- A green `deploy.yml` run on the self-hosted runner (visible in Actions).
- A new deployment record for *only that service* in Dokploy; the other
  service's version and the co-located data services (volumes intact) are
  unchanged.
- The backend health endpoint returns the new version on the LAN, and/or the
  Dashboard loads on the LAN.

## Reproducibility (config-as-code)

The `infra` repo — not Dokploy's internal database — is the source of truth.
Dokploy stores its app/env/domain config in its own DB, which is **not** a
git-committable artifact; so every decision made while experimenting on Proxmox
must be written back into the repo as a file (compose, env template, bootstrap
script). The payoff: standing up the university server is **`git clone` + one
command** (`./bootstrap.sh`), not a manual re-click of the Dokploy UI. Dokploy
provides the runtime UI/logs/rollback on top, but is replaceable — the repo
fully defines the deployment.

## Staging strategy

Stand up Dokploy + a self-hosted runner on the personal **Proxmox** lab, prove
the full release→runner→Dokploy→running-container chain end to end, capturing
every config decision back into the `infra` repo as you go. Then bring up the
**university server** with `git clone` + `./bootstrap.sh`, changing only host +
secrets.
