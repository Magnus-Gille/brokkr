#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKET="$ROOT/docs/maintenance-owner-ceremony.md"

test -f "$PACKET"

for required in \
  'Source release revision' \
  'Policy, plan, constitution, target-scope, configuration, evidence, baseline, and postconditions digests' \
  'Owner-authorization, owner-attestation, and recovery-registry digests' \
  'at most 300 seconds through durable watch anchoring' \
  'at least 3,600 seconds of watch' \
  'at most 4,200 seconds from prepare to deadline' \
  'delivery_disabled' \
  'two consecutive eligible scheduled windows' \
  'hold/disarm drill' \
  'R-forward recovery drill' \
  'Heimdall #16' \
  'root Codex, M5, and available Opus'; do
  grep -Fq "$required" "$PACKET"
done

# This public template must direct sensitive material to a private record and
# must never embed a concrete network address or a credential-shaped value.
grep -Fq 'owner-controlled private record' "$PACKET"
! grep -Eiq '(https?|ssh)://|[[:alnum:]_.%+-]+@[[:alnum:].-]+' "$PACKET"
! grep -Eiq '(api[_-]?key|password|secret|token)[[:space:]]*[:=][[:space:]]*[^ ]+' "$PACKET"
