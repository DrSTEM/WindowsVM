#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash scripts/update.sh'
  echo 'After shutting down VMs and quitting the app: fast-forward this checkout, prepare, build, test, and install.'
  exit 0
fi
[[ $# == 0 ]] || { echo 'Use --help for usage.' >&2; exit 2; }
bash scripts/check-stopped.sh
git diff --quiet && git diff --cached --quiet || { echo 'Commit or stash your source changes before updating.' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main before using the update helper.' >&2; exit 1; }
git pull --ff-only
bash scripts/setup.sh
bash scripts/build-app.sh
bash scripts/test.sh
bash scripts/install-app.sh
