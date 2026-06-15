#!/usr/bin/env bash
# Converge each app repo on the box to its latest published release tag.
# Runs in the `reconcile` container on a loop (see docker-compose.yml). It is
# the state-driven safety net: it clones repos that are missing, brings the full
# stack up on first boot, and catches up after long power-offs or drift — the
# cases the runners' event queue does not cover.
set -euo pipefail

ROOT="${WH_ROOT:-/opt/wh}"
ORG="${GH_OWNER:-Warehouse-USAL}"
APPS=(wh-backend Dashboard)

# GHCR login so `docker compose pull` can fetch private images outside Actions.
if [ -n "${GHCR_PAT:-}" ]; then
  echo "${GHCR_PAT}" | docker login ghcr.io -u "${GHCR_USER:-$ORG}" --password-stdin >/dev/null 2>&1 \
    || echo "! GHCR login failed (private images may not pull)"
fi

for repo in "${APPS[@]}"; do
  dir="$ROOT/$repo"

  if [ ! -d "$dir/.git" ]; then
    echo "[$repo] cloning…"
    git clone "https://github.com/$ORG/$repo.git" "$dir" || { echo "[$repo] clone failed"; continue; }
  fi

  git -C "$dir" fetch --tags --force origin
  # Canonical "latest release" from the GitHub API — NOT a tag glob/sort, since
  # the repo's release tags aren't strictly sortable (e.g. v2026-05-28 vs vsuperadmin).
  latest=$(curl -fsS -H "Authorization: Bearer ${GHCR_PAT:-}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$ORG/$repo/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  if [ -z "$latest" ]; then echo "[$repo] no published release yet"; continue; fi

  current=$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo "none")
  if [ "$current" = "$latest" ]; then echo "[$repo] already at $latest"; continue; fi

  if [ ! -f "$dir/.env" ]; then
    echo "[$repo] $latest available but $dir/.env is missing — configure it (cp .env.example .env) to deploy"
    continue
  fi

  echo "[$repo] $current -> $latest"
  git -C "$dir" checkout "$latest"
  make -C "$dir" up-prod   # ensure the full stack (incl. data services) is up; pulls on first boot
  make -C "$dir" deploy    # pull the newest app image + restart the app service
done
