#!/bin/bash
# Fail closed if process visibility is unavailable; never stop a guest here.
set -euo pipefail
for process in WindowsVM VMEngine; do
  if /usr/bin/pgrep -x "$process" >/dev/null; then
    echo 'Shut down your VMs and quit Windows VM before installing or updating. No processes were stopped.' >&2
    exit 1
  else
    status=$?
    if [[ "$status" != 1 ]]; then
      echo 'Cannot check running VM processes. Retry from Terminal with normal process visibility.' >&2
      exit 1
    fi
  fi
done
