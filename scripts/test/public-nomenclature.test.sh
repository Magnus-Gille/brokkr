#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
legacy="hugin""munin"
FAIL=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -e "$ROOT/$path" ] || continue
  path_lc="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$path_lc" == *"$legacy"* ]]; then
    printf 'not ok - legacy control-node hostname remains in path: %s\n' "$path" >&2
    FAIL=$((FAIL + 1))
  fi
  if [ -f "$ROOT/$path" ] && grep -Iqi "$legacy" "$ROOT/$path"; then
    printf 'not ok - legacy control-node hostname remains in content: %s\n' "$path" >&2
    FAIL=$((FAIL + 1))
  fi
done < <(cd "$ROOT" && git ls-files -co --exclude-standard)

if [ "$FAIL" -eq 0 ]; then
  echo "ok - tracked public interface uses generic control-node nomenclature"
fi
[ "$FAIL" -eq 0 ]
