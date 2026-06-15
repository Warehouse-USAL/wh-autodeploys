# Warehouse-USAL CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a stable GitHub release, the (outbound-only) server pulls the new image and restarts only that service — automatically, trackably, and resilient to the box being powered off.

**Architecture:** Per-repo GitHub self-hosted runners on the box pick up a `release: published` job and run `make deploy` (`docker compose pull && up -d <svc>`). A small `infra` repo owns a Caddy reverse proxy (single exposed port → all services) + a reconcile-on-boot systemd unit that converges the box to the latest release after long outages. App repos deploy themselves; `infra` owns how you reach them.

**Tech Stack:** GitHub Actions (self-hosted runners), Docker + Compose, Caddy, systemd, bash.

**Test target:** A throwaway **Proxmox VM** (x86) acting as staging. Do NOT test on the Pi (arm64 — your images are amd64). Verification is operational (run command → observe behavior), not unit tests.

---

## Prerequisites (checklist, not build tasks)

- [ ] A Proxmox VM running a recent Ubuntu/Debian, reachable over SSH.
- [ ] A GitHub PAT with `read:packages` (for GHCR pull) and the per-repo **runner registration tokens** (Settings → Actions → Runners → New self-hosted runner) for `wh-backend` and `Dashboard`.
- [ ] Dashboard's `feature/gitflow-dockerization` merged to `develop` so its image publishes from mainline (precondition noted in the design).
- [ ] The real secret values for backend (`SPRING_DATA_MONGODB_URI`, `JWT_SECRET`, `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD`, etc.) ready to drop into `.env` files on the box.

---

## File Structure

**`infra` repo (new):**
- `docker-compose.yml` — the Caddy proxy service.
- `Caddyfile` — routing for the one exposed port.
- `Makefile` — `up` / `down` for the proxy.
- `scripts/bootstrap.sh` — one-command fresh-box setup.
- `scripts/reconcile.sh` — converge to latest release (shared by boot unit).
- `systemd/wh-reconcile.service` — runs reconcile on boot.
- `.env.example`, `README.md`.

**`wh-backend` repo (small changes):**
- `Makefile` — add `deploy` target.
- `.github/workflows/deploy.yml` — new.
- `docker-compose.prod.yml` — join the shared `wh-proxy` network.

**`Dashboard` repo (small changes):**
- `Makefile` — add `deploy` target.
- `.github/workflows/deploy.yml` — new.
- `docker-compose.prod.yml` — join `wh-proxy`, set `BACKEND_URL`.

**On the box (created by bootstrap, not in git):** `/opt/wh/{infra,wh-backend,Dashboard}` clones, each app dir holding a gitignored `.env`.

---

## Phase 1 — Prove the core deploy loop (backend only)

### Task 1: Shared network + GHCR login on the staging VM

**Files:** none (host setup).

- [ ] **Step 1: Create the shared proxy network**

SSH to the VM, then:
```bash
docker network create wh-proxy || true
```

- [ ] **Step 2: Log in to GHCR so private images pull**

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
```
Expected: `Login Succeeded`.

- [ ] **Step 3: Verify image is pullable**

```bash
docker pull ghcr.io/warehouse-usal/wh-backend:latest
```
Expected: pulls without `denied`/`unauthorized`.

### Task 2: Add the `deploy` target to wh-backend

**Files:**
- Modify: `wh-backend/Makefile`

- [ ] **Step 1: Add the target** (after the existing `up-prod` target)

```makefile
deploy: ## Pull newest backend image and restart ONLY the backend (data services untouched)
	docker compose -f docker-compose.yml -f docker-compose.prod.yml pull backend
	docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d backend
```

- [ ] **Step 2: Add `deploy` to `.PHONY`** (line 1)

Append ` deploy` to the existing `.PHONY:` list.

- [ ] **Step 3: Commit**

```bash
cd wh-backend
git checkout -b feature/cd-deploy-target
git add Makefile && git commit -m "feat(ci): add make deploy target for server-side CD"
```

### Task 3: Join backend to the shared proxy network

**Files:**
- Modify: `wh-backend/docker-compose.prod.yml`

- [ ] **Step 1: Add the network to the backend service and declare it external**

In `docker-compose.prod.yml`, add to the `backend` service and to the top-level `networks:`:
```yaml
services:
  backend:
    networks:
      - wh-network
      - wh-proxy

networks:
  wh-proxy:
    external: true
```
(Keep the existing `wh-network` block.)

- [ ] **Step 2: Commit**

```bash
git add docker-compose.prod.yml
git commit -m "feat(infra): attach backend to shared wh-proxy network"
```

### Task 4: Manually clone + bootstrap the backend on the VM

**Files:** none (host setup; this is what `bootstrap.sh` will later automate).

- [ ] **Step 1: Clone the repo to the stable path**

```bash
sudo mkdir -p /opt/wh && sudo chown "$USER" /opt/wh
git clone https://github.com/Warehouse-USAL/wh-backend.git /opt/wh/wh-backend
cd /opt/wh/wh-backend && git checkout feature/cd-deploy-target
```

- [ ] **Step 2: Create the prod `.env`** (real secret values)

```bash
cat > /opt/wh/wh-backend/.env <<'EOF'
SPRING_DATA_MONGODB_URI=mongodb://<user>:<pass>@mongodb:27017/smartwarehouse?authSource=admin
REDPANDA_BOOTSTRAP_SERVERS=redpanda:9092
JWT_SECRET=<32+ char secret>
JWT_EXPIRATION_MS=86400000
MONGO_ROOT_USER=<user>
MONGO_ROOT_PASSWORD=<pass>
EOF
```

- [ ] **Step 3: Bring the full stack up once**

```bash
cd /opt/wh/wh-backend && make up-prod
```
Expected: backend + mongodb + redpanda + minio start. Give Mongo ~30s to init its replica set.

- [ ] **Step 4: Verify backend is healthy**

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
curl -fsS http://localhost:8080/actuator/health || docker compose logs backend --tail=50
```
Expected: backend container `running`; health endpoint returns `{"status":"UP"}` (adjust path to the backend's real health route).

### Task 5: Register the backend's self-hosted runner

**Files:** none (host setup).

- [ ] **Step 1: Download + configure the runner** (per-repo, in its own dir)

```bash
mkdir -p /opt/wh/runners/wh-backend && cd /opt/wh/runners/wh-backend
curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/Warehouse-USAL/wh-backend --token "$RUNNER_TOKEN_BACKEND" --labels prod --unattended --replace
```

- [ ] **Step 2: Install + start as a service**

```bash
sudo ./svc.sh install "$USER" && sudo ./svc.sh start
./svc.sh status
```
Expected: service active; runner shows **Idle** under repo Settings → Actions → Runners.

### Task 6: Add the deploy workflow to wh-backend

**Files:**
- Create: `wh-backend/.github/workflows/deploy.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: Deploy
on:
  release:
    types: [published]
concurrency:
  group: deploy-backend
  cancel-in-progress: true
jobs:
  deploy:
    if: github.event.release.prerelease == false
    runs-on: [self-hosted, prod]
    environment: production
    steps:
      - name: Deploy released tag
        run: |
          cd /opt/wh/wh-backend
          git fetch --tags --force origin
          git checkout "${GITHUB_REF_NAME}"
          make deploy
```

- [ ] **Step 2: Commit + push the branch, open PR, merge to develop**

```bash
cd /path/to/your/wh-backend/checkout   # your dev machine, not the VM
git add .github/workflows/deploy.yml && git commit -m "feat(ci): add release-triggered deploy job on self-hosted runner"
git push -u origin feature/cd-deploy-target
gh pr create --base develop --fill && gh pr merge --merge
```

- [ ] **Step 3: Update the VM clone to track the deployable branch/tag**

On the VM:
```bash
git -C /opt/wh/wh-backend fetch origin && git -C /opt/wh/wh-backend checkout develop && git -C /opt/wh/wh-backend pull
```

### Task 7: End-to-end test — cut a release, watch it deploy

**Files:** none.

- [ ] **Step 1: Trigger a stable release** via your existing flow (merge a `beta/<version>` PR into `master`, which runs `stable-release.yml` → publishes a release).

- [ ] **Step 2: Watch the deploy** in GitHub → Actions → "Deploy" workflow.
Expected: the job runs on the `prod` self-hosted runner, `make deploy` pulls the new image, recreates only `backend`.

- [ ] **Step 3: Confirm on the VM**

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
docker inspect --format='{{.Config.Image}}' $(docker compose ... ps -q backend)
```
Expected: backend running the new tag; `mongodb`/`redpanda`/`minio` containers show the **same uptime as before** (untouched).

---

## Phase 2 — Reverse proxy + Dashboard

### Task 8: Create the infra Caddy proxy

**Files:**
- Create: `infra/docker-compose.yml`, `infra/Caddyfile`, `infra/Makefile`

- [ ] **Step 1: Write `infra/docker-compose.yml`**

```yaml
services:
  caddy:
    image: caddy:2
    ports:
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - wh-proxy
    restart: always
networks:
  wh-proxy:
    external: true
volumes:
  caddy_data:
  caddy_config:
```

- [ ] **Step 2: Write `infra/Caddyfile`**

```
:80 {
	handle_path /api/* {
		reverse_proxy backend:8080
	}
	handle {
		reverse_proxy dashboard:80
	}
}
```
Note: `handle_path` strips the `/api` prefix, so `/api/auth` → `/auth` at the backend. If the backend uses a `/api` context-path, switch `handle_path` to `handle` (no strip).

- [ ] **Step 3: Write `infra/Makefile`**

```makefile
.PHONY: up down logs
up: ## Start the reverse proxy
	docker network create wh-proxy || true
	docker compose up -d
down:
	docker compose down
logs:
	docker compose logs -f caddy
```

- [ ] **Step 4: Commit**

```bash
cd infra && git add docker-compose.yml Caddyfile Makefile
git commit -m "feat: add Caddy reverse proxy (single exposed port)"
```

- [ ] **Step 5: Bring it up on the VM and verify it routes to the backend**

```bash
git clone https://github.com/Warehouse-USAL/infra.git /opt/wh/infra && cd /opt/wh/infra && make up
curl -fsS http://localhost/api/actuator/health
```
Expected: proxied backend health via port 80.

### Task 9: Dashboard deploy target + network + backend URL

**Files:**
- Modify: `Dashboard/Makefile`, `Dashboard/docker-compose.prod.yml`

- [ ] **Step 1: Add the `deploy` target to `Dashboard/Makefile`**

```makefile
deploy: ## Pull newest dashboard image and restart
	docker compose -f docker-compose.prod.yml pull
	docker compose -f docker-compose.prod.yml up -d
```
Add ` deploy` to the `.PHONY:` line.

- [ ] **Step 2: Join `wh-proxy` and point at the proxy in `docker-compose.prod.yml`**

```yaml
services:
  dashboard:
    environment:
      BACKEND_URL: /api
    networks:
      - wh-proxy
networks:
  wh-proxy:
    external: true
```
(Adjust the service key `dashboard` to match the actual service name in that file.)

- [ ] **Step 3: Commit**

```bash
cd Dashboard && git checkout -b feature/cd-deploy-target
git add Makefile docker-compose.prod.yml
git commit -m "feat(infra): add deploy target + join wh-proxy network"
```

### Task 10: Dashboard runner + workflow + bootstrap

**Files:**
- Create: `Dashboard/.github/workflows/deploy.yml`

- [ ] **Step 1: Write the workflow** (identical shape to backend; different concurrency group)

```yaml
name: Deploy
on:
  release:
    types: [published]
concurrency:
  group: deploy-dashboard
  cancel-in-progress: true
jobs:
  deploy:
    if: github.event.release.prerelease == false
    runs-on: [self-hosted, prod]
    environment: production
    steps:
      - name: Deploy released tag
        run: |
          cd /opt/wh/Dashboard
          git fetch --tags --force origin
          git checkout "${GITHUB_REF_NAME}"
          make deploy
```

- [ ] **Step 2: Register the Dashboard runner on the VM** (its own dir + token)

```bash
mkdir -p /opt/wh/runners/Dashboard && cd /opt/wh/runners/Dashboard
curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/Warehouse-USAL/Dashboard --token "$RUNNER_TOKEN_DASHBOARD" --labels prod --unattended --replace
sudo ./svc.sh install "$USER" && sudo ./svc.sh start
```

- [ ] **Step 3: Clone + env + first up on the VM**

```bash
git clone https://github.com/Warehouse-USAL/Dashboard.git /opt/wh/Dashboard
cd /opt/wh/Dashboard && git checkout feature/cd-deploy-target
printf 'BACKEND_URL=/api\n' > .env
make up-prod
```

- [ ] **Step 4: Commit + merge the workflow** (dev machine), then verify proxy serves the dashboard

```bash
curl -fsS http://localhost/    # should return the dashboard HTML
```
Expected: dashboard at `/`, backend at `/api/*`, both via port 80.

---

## Phase 3 — Resilience & one-command reproducibility

### Task 11: Reconcile-on-boot script

**Files:**
- Create: `infra/scripts/reconcile.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail
for repo in wh-backend Dashboard; do
  dir="/opt/wh/$repo"
  [ -d "$dir" ] || { echo "skip $repo (not cloned)"; continue; }
  git -C "$dir" fetch --tags --force origin
  latest=$(git -C "$dir" tag -l 'v*' | sort -V | tail -1)
  [ -n "$latest" ] || { echo "skip $repo (no version tags)"; continue; }
  current=$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo "")
  if [ "$current" != "$latest" ]; then
    echo "[$repo] $current -> $latest"
    git -C "$dir" checkout "$latest"
    make -C "$dir" deploy
  else
    echo "[$repo] already at $latest"
  fi
done
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x infra/scripts/reconcile.sh
git add infra/scripts/reconcile.sh
git commit -m "feat: reconcile box to latest release (boot safety net)"
```

- [ ] **Step 3: Verify it converges** on the VM

```bash
git -C /opt/wh/wh-backend checkout "$(git -C /opt/wh/wh-backend tag -l 'v*' | sort -V | head -1)"  # force an OLD tag
/opt/wh/infra/scripts/reconcile.sh
```
Expected: it detects the newer tag, checks it out, runs `make deploy`, backend ends on the latest version.

### Task 12: Reconcile systemd unit

**Files:**
- Create: `infra/systemd/wh-reconcile.service`

- [ ] **Step 1: Write the unit**

```ini
[Unit]
Description=Reconcile Warehouse services to latest release on boot
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/wh/infra/scripts/reconcile.sh
User=%i

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Install + enable on the VM**

```bash
sudo cp /opt/wh/infra/systemd/wh-reconcile.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable wh-reconcile.service
sudo systemctl start wh-reconcile.service && systemctl status wh-reconcile.service
```
Expected: unit runs reconcile.sh, exits 0.

- [ ] **Step 3: Reboot test**

```bash
sudo reboot
# after it comes back:
journalctl -u wh-reconcile.service -b
docker ps
```
Expected: services come up on the latest release after a cold boot, unattended.

- [ ] **Step 4: Commit**

```bash
git add infra/systemd/wh-reconcile.service
git commit -m "feat: run reconcile on boot via systemd oneshot"
```

### Task 13: One-command `bootstrap.sh`

**Files:**
- Create: `infra/scripts/bootstrap.sh`, `infra/.env.example`, `infra/README.md`

- [ ] **Step 1: Write `bootstrap.sh`** (idempotent; secrets passed via env)

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${GHCR_USER:?}" "${GHCR_PAT:?}" "${RUNNER_TOKEN_BACKEND:?}" "${RUNNER_TOKEN_DASHBOARD:?}"
ORG=Warehouse-USAL
ROOT=/opt/wh
RUNNER_URL=https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz

command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
docker network create wh-proxy 2>/dev/null || true
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

sudo mkdir -p "$ROOT" && sudo chown "$USER" "$ROOT"
clone() { [ -d "$ROOT/$1" ] || git clone "https://github.com/$ORG/$1.git" "$ROOT/$1"; }
clone infra; clone wh-backend; clone Dashboard

register() { # repo, token
  local d="$ROOT/runners/$1"
  [ -f "$d/.runner" ] && { echo "$1 runner already registered"; return; }
  mkdir -p "$d"; ( cd "$d"; curl -fsSL -o r.tar.gz "$RUNNER_URL"; tar xzf r.tar.gz
    ./config.sh --url "https://github.com/$ORG/$1" --token "$2" --labels prod --unattended --replace
    sudo ./svc.sh install "$USER"; sudo ./svc.sh start )
}
register wh-backend "$RUNNER_TOKEN_BACKEND"
register Dashboard "$RUNNER_TOKEN_DASHBOARD"

make -C "$ROOT/infra" up
sudo cp "$ROOT/infra/systemd/wh-reconcile.service" /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable wh-reconcile.service
echo "Bootstrap complete. Add per-app .env files in $ROOT/wh-backend and $ROOT/Dashboard, then run reconcile.sh."
```

- [ ] **Step 2: Write `.env.example` + README** documenting the required env vars (`GHCR_USER`, `GHCR_PAT`, `RUNNER_TOKEN_*`) and the per-app `.env` keys.

- [ ] **Step 3: Commit**

```bash
chmod +x infra/scripts/bootstrap.sh
git add infra/scripts/bootstrap.sh infra/.env.example infra/README.md
git commit -m "feat: one-command bootstrap for a fresh box"
```

- [ ] **Step 4: Full reproducibility test on a SECOND clean Proxmox VM**

```bash
GHCR_USER=... GHCR_PAT=... RUNNER_TOKEN_BACKEND=... RUNNER_TOKEN_DASHBOARD=... \
  bash <(curl -fsSL https://raw.githubusercontent.com/Warehouse-USAL/infra/develop/scripts/bootstrap.sh)
# add /opt/wh/*/.env files, then:
/opt/wh/infra/scripts/reconcile.sh
curl -fsS http://localhost/ && curl -fsS http://localhost/api/actuator/health
```
Expected: from a blank box, one command + env vars + the `.env` files brings the full stack up on the latest release.

---

## Re-target to the university server

Once green on Proxmox: run `bootstrap.sh` on the university box with the same env vars, drop in the prod `.env` files, point DNS/host references at it. No code changes — only host + secrets differ.

## Out of scope

Mobile/SmartWarehouse (APK artifact). Public TLS (Caddy adds it with a one-line domain change when you expose publicly).
