#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$HOME/Applications"
case "${1:-}" in
  '') ;;
  --destination) [[ $# == 2 && "$2" == /* ]] || { echo 'Supply an absolute destination folder.' >&2; exit 2; }; destination="$2" ;;
  --help) echo 'Usage: bash scripts/install-app.sh [--destination /absolute/folder]'; exit 0 ;;
  *) echo 'Use --help for usage.' >&2; exit 2 ;;
esac
bash scripts/check-stopped.sh
app='build/Windows VM.app'
codesign --verify --deep --strict "$app"
mkdir -p "$destination"
stage="$(mktemp -d "$destination/.WindowsVM-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Windows VM.app"
codesign --verify --deep --strict "$stage/Windows VM.app"
target="$destination/Windows VM.app"
backup=''
if [[ -e "$target" ]]; then
  backup="$destination/Windows VM.backup-$(date +%Y%m%d-%H%M%S)-$$.app"
  mv "$target" "$backup"
fi
if ! mv "$stage/Windows VM.app" "$target"; then
  [[ -z "$backup" ]] || mv "$backup" "$target"
  exit 1
fi
echo "Installed: $target"
[[ -z "$backup" ]] || echo "Previous app: $backup"
echo 'Your VM library is stored separately and was not changed.'
