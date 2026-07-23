#!/usr/bin/env bash
# Every repository script invoked directly by a tracked systemd unit must keep
# its executable bit. Commands explicitly run through an interpreter are out of
# scope because systemd executes that interpreter instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0
FOUND=0

while IFS= read -r unit; do
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    FOUND=$((FOUND + 1))
    if [ ! -f "$ROOT/$script" ]; then
      printf 'not ok - ExecStart references missing repository script: %s\n' "$script" >&2
      FAIL=$((FAIL + 1))
    elif [ ! -x "$ROOT/$script" ]; then
      printf 'not ok - direct ExecStart script is not executable: %s\n' "$script" >&2
      FAIL=$((FAIL + 1))
    else
      printf 'ok - direct ExecStart script is executable: %s\n' "$script"
    fi
  done < <(sed -nE 's@^ExecStart=(/opt/brokkr|%h/repos/brokkr)/(scripts/[A-Za-z0-9._/-]+\.sh)([[:space:]].*)?$@\2@p' "$unit")
done < <(find "$ROOT/systemd" -type f -name '*.service' -print | sort)

if [ "$FOUND" -eq 0 ]; then
  echo 'not ok - no direct repository ExecStart scripts found' >&2
  exit 1
fi

[ "$FAIL" -eq 0 ]
