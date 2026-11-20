#!/bin/bash
# Prepare dependencies locally. Does not launch Windows or modify VM packages.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash scripts/setup.sh [--refresh]'
  echo 'Checks prerequisites, installs missing Homebrew tools, and verifies/prepares the pinned runtime.'
  exit 0
fi
refresh=false
case "${1:-}" in '') ;; --refresh) refresh=true ;; *) echo 'Use --help for usage.' >&2; exit 2 ;; esac
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Use an Apple Silicon Mac, outside Rosetta.' >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || { echo 'Install and open Xcode 26 or newer, complete its setup, then select it in Xcode > Settings > Locations > Command Line Tools.' >&2; exit 1; }
sdk="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk%%.*}" -ge 26 ]] || { echo 'Select Xcode with the macOS 26 SDK or newer.' >&2; exit 1; }
command -v brew >/dev/null || { echo 'Install Homebrew from https://brew.sh, then follow its shellenv instructions and rerun this script.' >&2; exit 1; }
missing=()
for formula in python qemu swtpm; do
  case "$formula" in python) tool=python3 ;; qemu) tool=qemu-img ;; *) tool=swtpm ;; esac
  [[ -x "$(brew --prefix)/bin/$tool" ]] || missing+=("$formula")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "Installing missing Homebrew dependencies: ${missing[*]}"
  brew install "${missing[@]}"
fi
export PATH="$(brew --prefix)/bin:$PATH"
if $refresh; then python3 scripts/setup-runtime.py --refresh; else python3 scripts/setup-runtime.py; fi
echo 'Dependencies ready. Next: bash scripts/build-app.sh'
