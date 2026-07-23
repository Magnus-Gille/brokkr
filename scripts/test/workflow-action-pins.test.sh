#!/usr/bin/env bash
# Regression for issue #29: workflow actions must be pinned to immutable full
# commit SHAs with a version comment, and must not use action revisions that
# run on the deprecated Node.js 20 action runtime. Hermetic; no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0

# Full-SHA revisions of actions known to declare a deprecated Node 20 runtime.
DEPRECATED_NODE20_SHAS=(
  11bd71901bbe5b1630ceea73d27597364c9af683 # actions/checkout v4.2.2
)

while IFS= read -r workflow; do
  while IFS= read -r line; do
    uses="$(printf '%s' "$line" | sed -E 's/^.*uses:[[:space:]]*//')"
    if ! printf '%s' "$uses" | grep -Eq '^[^@]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]'; then
      printf 'not ok - action not pinned to full SHA with version comment: %s (%s)\n' "$uses" "$workflow" >&2
      FAIL=$((FAIL + 1))
    fi
    for sha in "${DEPRECATED_NODE20_SHAS[@]}"; do
      if [[ "$uses" == *"@$sha"* ]]; then
        printf 'not ok - deprecated Node 20 runtime action revision: %s (%s)\n' "$uses" "$workflow" >&2
        FAIL=$((FAIL + 1))
      fi
    done
  done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow" || true)
done < <(cd "$ROOT" && git ls-files -co --exclude-standard -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | sed "s#^#$ROOT/#")

if [ "$FAIL" -eq 0 ]; then
  echo "ok - workflow actions are SHA-pinned on a supported runtime"
fi
[ "$FAIL" -eq 0 ]
