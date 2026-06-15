#!/usr/bin/env bash
# One-command setup for a fresh box. Everything runs as containers — the only
# host install is the Docker engine. After this, the whole deployment is a
# single `docker compose up`.
#
#   curl -fsSL https://raw.githubusercontent.com/Warehouse-USAL/wh-autodeploys/master/scripts/init.sh | bash
set -euo pipefail

ORG=Warehouse-USAL
ROOT="${WH_ROOT:-/opt/wh}"

# 1. Host dependencies: Docker engine, the compose plugin, and make.
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
# compose plugin (docker.io packages sometimes ship without it)
docker compose version >/dev/null 2>&1 || {
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}
# make (used by this ops Makefile on the host)
command -v make >/dev/null || sudo apt-get install -y make 2>/dev/null || true

# 2. Clone this repo to its stable path
sudo mkdir -p "$ROOT" && sudo chown "$USER" "$ROOT"
[ -d "$ROOT/wh-autodeploys/.git" ] \
  || git clone "https://github.com/$ORG/wh-autodeploys.git" "$ROOT/wh-autodeploys"
cd "$ROOT/wh-autodeploys"

# 3. Ensure the infra .env exists (GH_PAT etc.)
if [ ! -f .env ]; then
  cp .env.example .env
  echo
  echo "Created $ROOT/wh-autodeploys/.env"
  echo "Fill in GH_OWNER, GH_PAT (PAT: repo + read:packages), then re-run this script."
  exit 1
fi

# 4. Bring up caddy + the two runners + reconcile
docker network create wh-proxy 2>/dev/null || true
docker compose up -d --build

ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip="${ip:-<box-ip>}"
echo
echo "Up. The runners will appear under each repo's Settings -> Actions -> Runners."
echo "Once the apps have a .env and a release, they deploy automatically."
echo "  Dashboard : http://$ip/"
echo "  API       : http://$ip/api/"
echo
echo "App config still lives per-repo:"
echo "  cp $ROOT/wh-backend/.env.example $ROOT/wh-backend/.env   && edit it"
echo "  cp $ROOT/Dashboard/.env.example  $ROOT/Dashboard/.env    && edit it"
