#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKET="$ROOT/docs/maintenance-owner-ceremony.md"

test -f "$PACKET"
FLAT="$(tr '\n' ' ' < "$PACKET" | tr -s '[:space:]' ' ')"

for required in \
  'Source release revision' \
  'Policy, plan, constitution, target-scope, configuration, evidence, baseline, and postconditions digests' \
  'Owner-authorization, owner-attestation, and recovery-registry digests' \
  'at most 300 seconds through durable watch anchoring' \
  'at least 3,600 seconds of watch' \
  'at most 4,200 seconds from prepare to deadline' \
  'delivery_disabled' \
  'future separately reviewed authenticated delivery adapter' \
  'requires no per-run human approval' \
  'two consecutive eligible scheduled windows' \
  'hold/disarm drill' \
  'R-forward recovery drill' \
  'Heimdall #16' \
  'root Codex, M5, and available Opus'; do
  grep -Fq "$required" <<< "$FLAT"
done

# This public template must direct sensitive material to a private record and
# must never embed a concrete network address or a credential-shaped value.
grep -Fq 'owner-controlled private record' <<< "$FLAT"
if grep -Fq 'delivery_disabled before and after the ceremony' <<< "$FLAT"; then
  echo 'packet incorrectly requires delivery to remain disabled through the ceremony' >&2
  exit 1
fi
if grep -Eiq '(https?|ssh)://|[[:alnum:]_.%+-]+@[[:alnum:].-]+' <<< "$FLAT"; then
  echo 'packet contains a concrete locator' >&2
  exit 1
fi
if grep -Eiq '(api[_-]?key|password|secret|token)[[:space:]]*[:=][[:space:]]*[^ ]+' <<< "$FLAT"; then
  echo 'packet contains a credential-shaped assignment' >&2
  exit 1
fi
