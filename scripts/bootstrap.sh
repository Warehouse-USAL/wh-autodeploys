#!/usr/bin/env bash
# One-command setup for a fresh box (Proxmox staging or the university server).
# Idempotent: safe to re-run. Secrets are passed via env vars, never hardcoded.
#
# Usage:
#   GHCR_USER=... GHCR_PAT=... \
#   RUNNER_TOKEN_BACKEND=... RUNNER_TOKEN_DASHBOARD=... \
#   ./bootstrap.sh
#
# After it finishes: drop a `.env` into /opt/wh/wh-backend and /opt/wh/Dashboard,
# then run `make -C /opt/wh/wh-autodeploys reconcile` to bring services up.
set -euo pipefail

: "${GHCR_USER:?set GHCR_USER}" "${GHCR_PAT:?set GHCR_PAT}"
: "${RUNNER_TOKEN_BACKEND:?set RUNNER_TOKEN_BACKEND}"
: "${RUNNER_TOKEN_DASHBOARD:?set RUNNER_TOKEN_DASHBOARD}"

ORG=Warehouse-USAL
ROOT="${WH_ROOT:-/opt/wh}"
RUNNER_URL=https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz

# 1. Docker (skip if present)
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh

# 2. Shared proxy network + GHCR auth
docker network create wh-proxy 2>/dev/null || true
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# 3. Stable clones
sudo mkdir -p "$ROOT" && sudo chown "$USER" "$ROOT"
clone() { [ -d "$ROOT/$1/.git" ] || git clone "https://github.com/$ORG/$1.git" "$ROOT/$1"; }
clone wh-autodeploys
clone wh-backend
clone Dashboard

# 4. Per-repo self-hosted runners (one each), installed as services
register() { # $1=repo  $2=registration token
  local d="$ROOT/runners/$1"
  if [ -f "$d/.runner" ]; then echo "[$1] runner already registered"; return; fi
  mkdir -p "$d"
  ( cd "$d"
    curl -fsSL -o runner.tar.gz "$RUNNER_URL"
    tar xzf runner.tar.gz
    ./config.sh --url "https://github.com/$ORG/$1" --token "$2" \
                --labels prod --unattended --replace
    sudo ./svc.sh install "$USER"
    sudo ./svc.sh start )
}
register wh-backend "$RUNNER_TOKEN_BACKEND"
register Dashboard  "$RUNNER_TOKEN_DASHBOARD"

# 5. Reverse proxy
make -C "$ROOT/wh-autodeploys" up

# 6. Reconcile-on-boot unit (sets the User to the current account)
unit=/etc/systemd/system/wh-reconcile.service
sudo sed "s/<user>/$USER/" "$ROOT/wh-autodeploys/systemd/wh-reconcile.service" \
  | sudo tee "$unit" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable wh-reconcile.service

cat <<EOF

Bootstrap complete.
Next:
  1. Create /opt/wh/wh-backend/.env and /opt/wh/Dashboard/.env (see each repo).
  2. Run:  make -C $ROOT/wh-autodeploys reconcile
  3. Verify:  curl http://localhost/  and  curl http://localhost/api/<health-path>
EOF
