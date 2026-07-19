#!/usr/bin/env bash
# Brokkr · deploy the [TimeMachine] Samba share to the NAS Pi.
#
# Idempotent + self-migrating: installs timemachine.conf to /etc/samba/, ensures smb.conf
# `include`s it, and removes any inline [TimeMachine] stanza (the one-time migration, brokkr#30)
# so the share is defined in exactly one place. The safety-critical logic lives in the companion
# deploy-remote.sh (unit-tested by ../scripts/test/samba-deploy.test.sh); this wrapper just
# stages the file and runs it on the Pi. Safe to run repeatedly.
#
#   BROKKR_NAS_TARGET=brokkr@nas-host ./deploy.sh [user@host]
#
# Run from the laptop (needs ssh + passwordless sudo on the Pi). The staged file goes to a
# private per-run mktemp path (not a predictable /tmp name) and is cleaned up on exit.
set -euo pipefail

NAS="${1:-${BROKKR_NAS_TARGET:-brokkr@nas-host}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${BROKKR_SAMBA_CONFIG:-$HERE/timemachine.conf}"
[ -f "$CONFIG" ] || {
  echo "ERROR: live Samba config not found: $CONFIG" >&2
  echo "Copy samba/timemachine.example.conf to samba/timemachine.conf and adapt it first." >&2
  exit 1
}

echo "==> Staging timemachine.conf on $NAS"
STAGE="$(ssh "$NAS" 'mktemp -t brokkr-tm.XXXXXX')"
trap 'ssh "$NAS" "rm -f \"$STAGE\"" 2>/dev/null || true' EXIT
scp -q "$CONFIG" "$NAS:$STAGE"

echo "==> Installing + migrating + validating on $NAS"
ssh "$NAS" "STAGE='$STAGE' bash -s" < "$HERE/deploy-remote.sh"
echo "==> Done."
