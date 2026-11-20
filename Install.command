#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
trap 'status=$?; if [[ $status -ne 0 ]]; then echo "Setup stopped. Read the error above; see docs/TROUBLESHOOTING.md."; fi; echo; read -r -p "Press Return to close…"; exit "$status"' EXIT
echo 'Windows VM — build and install on this Mac'
echo 'Requires Apple Silicon, Xcode 26+, and Homebrew. Downloads verified upstream dependencies.'
bash scripts/check-stopped.sh
bash scripts/setup.sh
bash scripts/build-app.sh
bash scripts/test.sh
bash scripts/install-app.sh
open "$HOME/Applications/Windows VM.app"
