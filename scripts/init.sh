#!/usr/bin/env bash
# Guided, one-command setup for a fresh deployment box.
#
# Scope: INFRA ONLY — Docker, the shared network, GHCR login, repo clones,
# self-hosted runners, the reverse proxy, and the reconcile-on-boot unit.
# It prompts for exactly two kinds of secret that belong to *this* layer:
#   - GHCR pull credentials
#   - runner registration tokens
#
# App runtime config (Mongo URI, JWT secret, BACKEND_URL, ...) is NOT handled
# here. Each app repo ships its own `.env.example`; you copy it to `.env` in the
# app's clone and fill it in. This script will tell you when one is missing.
#
# Any prompt can be pre-set as an env var to run unattended (e.g. over SSH).
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

ask() {  # var, prompt
  [ -n "${!1:-}" ] && return
  read -rp "  $2: " "$1"
}
ask_secret() {  # var, prompt
  [ -n "${!1:-}" ] && return
  read -rsp "  $2: " "$1"; echo
}
require() { [ -n "${!1:-}" ] || { echo "ERROR: $1 is required"; exit 1; }; }

bold "Warehouse-USAL — deployment box setup (infra)"
echo

# ── 0. sanity checks ─────────────────────────────────────────────────────────
arch=$(uname -m)
if [ "$arch" != "x86_64" ]; then
  warn "This box is '$arch'. Your images are amd64 — they will NOT run here."
  read -rp "  Continue anyway? [y/N] " yn; [ "$yn" = y ] || exit 1
fi
sudo -n true 2>/dev/null || warn "sudo may prompt for a password during setup."

# ── 1. infra credentials (the ONLY secrets this layer owns) ──────────────────
bold "1/3  Infra credentials"
ask        GHCR_USER             "GitHub username (for GHCR)"
ask_secret GHCR_PAT              "GHCR token (PAT with read:packages)"
ask_secret RUNNER_TOKEN_BACKEND  "wh-backend runner registration token"
ask_secret RUNNER_TOKEN_DASHBOARD "Dashboard runner registration token (blank to skip Dashboard)"
require GHCR_USER; require GHCR_PAT; require RUNNER_TOKEN_BACKEND

# ── 2. box plumbing (Docker, network, GHCR, clones, runners, proxy, unit) ────
bold "2/3  Bootstrapping box (Docker, runners, proxy)"
export GHCR_USER GHCR_PAT RUNNER_TOKEN_BACKEND
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
ok "Box bootstrapped (runners registered, proxy up)"

# ── 3. bring up each app IF the operator has configured its .env ─────────────
# App config lives in each repo's own .env (copied from its .env.example).
bold "3/3  Starting services"
bring_up() {  # repo, friendly-name
  local dir="$ROOT/$1"
  if [ ! -f "$dir/.env" ]; then
    warn "$1 not started — missing $dir/.env"
    echo "      Configure it:  cp $dir/.env.example $dir/.env  &&  \$EDITOR $dir/.env"
    return 1
  fi
  make -C "$dir" up-prod && ok "$2 up"
}

bring_up wh-backend "backend + data services" || true

if [ "$RUNNER_TOKEN_DASHBOARD" = SKIP ]; then
  warn "Dashboard skipped (no runner token provided)."
elif ! docker pull "ghcr.io/$(echo "$ORG" | tr '[:upper:]' '[:lower:]')/dashboard:latest" >/dev/null 2>&1; then
  warn "Dashboard image not in GHCR yet — skipping. (Merge + release feature/gitflow-dockerization, then: make -C $ROOT/Dashboard up-prod)"
else
  bring_up Dashboard "dashboard" || true
fi

# ── done ─────────────────────────────────────────────────────────────────────
ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip="${ip:-<box-ip>}"
echo
bold "Done."
echo "  Dashboard : http://$ip/"
echo "  API       : http://$ip/api/"
echo
echo "  Runners are registered; a stable release now deploys automatically."
echo "  Verify locally:  curl -fsS http://localhost/   &&   curl -fsS http://localhost/api/"
