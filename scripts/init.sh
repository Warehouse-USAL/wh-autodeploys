#!/usr/bin/env bash
# Guided, one-command setup for a fresh box. Run it and answer the prompts —
# or pre-set any value as an env var to skip that prompt (handy for automation
# over SSH). Safe to re-run: existing .env files and registered runners are left
# in place unless you delete them first.
#
#   curl -fsSL https://raw.githubusercontent.com/Warehouse-USAL/wh-autodeploys/main/scripts/init.sh | bash
#   # or, from a clone:  ./scripts/init.sh
set -euo pipefail

ORG=Warehouse-USAL
ROOT="${WH_ROOT:-/opt/wh}"
SELF_REPO=wh-autodeploys
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }

# ── input helpers: use env var if set, else prompt ───────────────────────────
ask() {  # var, prompt
  local cur="${!1:-}"
  if [ -n "$cur" ]; then return; fi
  read -rp "  $2: " "$1"
}
ask_secret() {  # var, prompt
  local cur="${!1:-}"
  if [ -n "$cur" ]; then return; fi
  read -rsp "  $2: " "$1"; echo
}
require() { [ -n "${!1:-}" ] || { echo "ERROR: $1 is required"; exit 1; }; }

bold "Warehouse-USAL — deployment box setup"
echo

# ── 0. sanity checks ─────────────────────────────────────────────────────────
arch=$(uname -m)
if [ "$arch" != "x86_64" ]; then
  warn "This box is '$arch'. Your images are amd64 — they will NOT run here."
  read -rp "  Continue anyway? [y/N] " yn; [ "$yn" = y ] || exit 1
fi
sudo -n true 2>/dev/null || warn "sudo may prompt for a password during setup."

# ── 1. gather inputs ─────────────────────────────────────────────────────────
bold "1/5  Credentials"
ask        GHCR_USER             "GitHub username (for GHCR)"
ask_secret GHCR_PAT              "GHCR token (PAT with read:packages)"
ask_secret RUNNER_TOKEN_BACKEND  "wh-backend runner registration token"
ask_secret RUNNER_TOKEN_DASHBOARD "Dashboard runner registration token (blank to skip Dashboard)"
require GHCR_USER; require GHCR_PAT; require RUNNER_TOKEN_BACKEND

bold "2/5  Backend runtime secrets"
ask_secret SPRING_DATA_MONGODB_URI "MongoDB URI (mongodb://user:pass@mongodb:27017/smartwarehouse?authSource=admin)"
ask_secret JWT_SECRET              "JWT secret (32+ chars)"
ask        MONGO_ROOT_USER         "Mongo root user"
ask_secret MONGO_ROOT_PASSWORD     "Mongo root password"
REDPANDA_BOOTSTRAP_SERVERS="${REDPANDA_BOOTSTRAP_SERVERS:-redpanda:9092}"
JWT_EXPIRATION_MS="${JWT_EXPIRATION_MS:-86400000}"
BACKEND_URL="${BACKEND_URL:-/api}"
require SPRING_DATA_MONGODB_URI; require JWT_SECRET
require MONGO_ROOT_USER; require MONGO_ROOT_PASSWORD

# ── 2. base box setup (Docker, network, GHCR, clones, runners, proxy, unit) ──
bold "3/5  Bootstrapping box (Docker, runners, proxy)"
export GHCR_USER GHCR_PAT RUNNER_TOKEN_BACKEND
# bootstrap requires a Dashboard token; provide a placeholder if skipping so it
# doesn't abort, then we just won't bring the dashboard up.
export RUNNER_TOKEN_DASHBOARD="${RUNNER_TOKEN_DASHBOARD:-SKIP}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/bootstrap.sh" ]; then
  WH_ROOT="$ROOT" "$SCRIPT_DIR/bootstrap.sh"
else
  # running via curl|bash — clone ourselves first, then delegate
  [ -d "$ROOT/$SELF_REPO/.git" ] || { sudo mkdir -p "$ROOT"; sudo chown "$USER" "$ROOT"; \
    git clone "https://github.com/$ORG/$SELF_REPO.git" "$ROOT/$SELF_REPO"; }
  WH_ROOT="$ROOT" "$ROOT/$SELF_REPO/scripts/bootstrap.sh"
fi
ok "Box bootstrapped"

# ── 3. write per-app .env files (skip if present) ────────────────────────────
bold "4/5  Writing app .env files"
write_env() {  # dir, heredoc-content via stdin
  if [ -f "$1/.env" ]; then warn "$1/.env exists — leaving as-is"; return; fi
  cat > "$1/.env"; ok "wrote $1/.env"
}
write_env "$ROOT/wh-backend" <<EOF
SPRING_DATA_MONGODB_URI=$SPRING_DATA_MONGODB_URI
REDPANDA_BOOTSTRAP_SERVERS=$REDPANDA_BOOTSTRAP_SERVERS
JWT_SECRET=$JWT_SECRET
JWT_EXPIRATION_MS=$JWT_EXPIRATION_MS
MONGO_ROOT_USER=$MONGO_ROOT_USER
MONGO_ROOT_PASSWORD=$MONGO_ROOT_PASSWORD
EOF
write_env "$ROOT/Dashboard" <<EOF
BACKEND_URL=$BACKEND_URL
EOF

# ── 4. initial bring-up ──────────────────────────────────────────────────────
bold "5/5  Starting services"
make -C "$ROOT/wh-backend" up-prod
ok "backend + data services up"

if docker pull "ghcr.io/$(echo "$ORG" | tr '[:upper:]' '[:lower:]')/dashboard:latest" >/dev/null 2>&1; then
  make -C "$ROOT/Dashboard" up-prod
  ok "dashboard up"
else
  warn "Dashboard image not found in GHCR — skipping. (Merge feature/gitflow-dockerization and release it, then run: make -C $ROOT/Dashboard up-prod)"
fi

# ── done: print URLs ─────────────────────────────────────────────────────────
ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip="${ip:-<box-ip>}"
echo
bold "Done."
echo "  Dashboard : http://$ip/"
echo "  API       : http://$ip/api/"
echo
echo "  Runners are registered and Idle; a stable release now deploys automatically."
echo "  Verify locally:  curl -fsS http://localhost/   &&   curl -fsS http://localhost/api/"
