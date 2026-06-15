#!/usr/bin/env bash
# Converge each app repo on the box to its latest published release tag.
# Runs on boot (via wh-reconcile.service) and on demand (`make reconcile`).
# This is the safety net for outages longer than the runner's job-queue window.
set -euo pipefail

ROOT="${WH_ROOT:-/opt/wh}"
APPS=(wh-backend Dashboard)

for repo in "${APPS[@]}"; do
  dir="$ROOT/$repo"
  if [ ! -d "$dir/.git" ]; then
    echo "[$repo] skip — not cloned at $dir"
    continue
  fi

  git -C "$dir" fetch --tags --force origin

  latest=$(git -C "$dir" tag -l 'v*' | sort -V | tail -1)
  if [ -z "$latest" ]; then
    echo "[$repo] skip — no version tags yet"
    continue
  fi

  current=$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo "none")
  if [ "$current" = "$latest" ]; then
    echo "[$repo] already at $latest"
    continue
  fi

  echo "[$repo] $current -> $latest"
  git -C "$dir" checkout "$latest"
  make -C "$dir" deploy
done
