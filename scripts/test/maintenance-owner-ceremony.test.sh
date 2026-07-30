#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKET="$ROOT/docs/maintenance-owner-ceremony.md"

test -f "$PACKET"
FLAT="$(tr '\n' ' ' < "$PACKET" | tr -s '[:space:]' ' ')"

for required in \
  'Source release revision' \
  'Executor revision and digest' \
  'Journal revision and digest' \
  'Bounded-recovery-dispatcher revision and digest' \
  'Installer revision and digest' \
  'Projector revision and digest' \
  'Inert delivery-boundary revision and digest' \
  'Fixture-corpus digest and readback' \
  'Ceremony-pinned coverage digests' \
  'Per-window attempt facts' \
  'never ceremony inputs' \
  'Owner-authorization, owner-attestation, and recovery-registry digests' \
  'at most 300 seconds through durable watch anchoring' \
  'at least 3,600 seconds of watch' \
  'at most 4,200 seconds from prepare to deadline' \
  'delivery_disabled' \
  'Brokkr #81 separately reviewed authenticated delivery adapter' \
  'scheduler/unit-enablement/arming mechanism' \
  'current installer and source do not provide live scheduling, unit enablement, or arming' \
  'delivery is configured, enabled, and readback-ready' \
  'Owner explicit approval must precede any live installation' \
  'A hold or abort leaves every reviewed artifact uninstalled' \
  'Arm one canary last' \
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
if grep -Fq 'authorizes the exact bound attempt' <<< "$FLAT"; then
  echo 'packet incorrectly makes a per-window attempt an owner-ceremony input' >&2
  exit 1
fi
if grep -Fq 'Policy, plan, constitution, target-scope, configuration, evidence, baseline, and postconditions digests' <<< "$FLAT"; then
  echo 'packet incorrectly mixes ceremony coverage with per-window facts' >&2
  exit 1
fi
if grep -Fq 'installed disabled and revision-bound before the ceremony' <<< "$FLAT"; then
  echo 'packet incorrectly installs artifacts before owner approval' >&2
  exit 1
fi
if grep -Fq 'before ceremony authorization' <<< "$FLAT"; then
  echo 'packet contains contradictory post-install authorization ordering' >&2
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
