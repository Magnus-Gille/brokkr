#!/usr/bin/env bash
# Brokkr · deploy the NAS [TimeMachine] Samba configuration (retired by default).
#
# Idempotent + self-migrating: installs timemachine.conf to /etc/samba/, ensures smb.conf
# `include`s it, and removes any inline [TimeMachine] stanza (the one-time migration, brokkr#30)
# so the share is defined in exactly one place. The safety-critical logic lives in the companion
# deploy-remote.sh (unit-tested by ../scripts/test/samba-deploy.test.sh); this wrapper just
# stages the file and runs it on the Pi. Safe to run repeatedly.
#
#   BROKKR_EXPECTED_SOURCE=/absolute/clean/worktree BROKKR_EXPECTED_COMMIT=FULL_SHA \
#     BROKKR_NAS_TARGET=brokkr@nas-host ./samba/deploy.sh [user@host]
#
# Run from the laptop (needs ssh + passwordless sudo on the Pi). The staged file goes to a
# private per-run mktemp path (not a predictable /tmp name) and is cleaned up on exit.
set -euo pipefail

NAS="${1:-${BROKKR_NAS_TARGET:-}}"
[[ "$NAS" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
  echo "ERROR: explicit NAS target must be user@hostname (or user@IPv4)" >&2
  exit 2
}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TIME_MACHINE_STATE="${BROKKR_SAMBA_TIME_MACHINE_STATE-retired}"
case "$TIME_MACHINE_STATE" in
  retired|active) ;;
  *) echo "ERROR: invalid BROKKR_SAMBA_TIME_MACHINE_STATE; expected retired or active" >&2; exit 2 ;;
esac
# Bind this deploy entry and its executable remote payload to the accepted SHA.
# shellcheck source=scripts/lib/deploy-source.sh
source "$ROOT/scripts/lib/deploy-source.sh"
reject_symlinked_deploy_entry "$0"
require_brokkr_deploy_source_binding "$ROOT"
CONFIG="${BROKKR_SAMBA_CONFIG:-$HERE/timemachine.conf}"
[[ "$CONFIG" == /* ]] || { echo "ERROR: Samba config path must be absolute" >&2; exit 2; }
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || {
  echo "ERROR: live Samba config not found: $CONFIG" >&2
  echo "Copy samba/timemachine.example.conf to samba/timemachine.conf and adapt it first." >&2
  exit 1
}
materialize_brokkr_deploy_payload "$ROOT" "$BROKKR_EXPECTED_COMMIT"
STAGE=""
SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no)
cleanup() {
  if [ -n "$STAGE" ]; then ssh "${SSH_OPTIONS[@]}" "$NAS" "/usr/bin/rm -f -- '$STAGE'" 2>/dev/null || true; fi
  rm -rf -- "$DEPLOY_PAYLOAD_PARENT"
}
trap cleanup EXIT
STAGE="$CONFIG" BROKKR_SAMBA_TIME_MACHINE_STATE="$TIME_MACHINE_STATE" \
  /bin/bash "$DEPLOY_PAYLOAD_ROOT/samba/deploy-remote.sh" --validate-stage

echo "==> Staging timemachine.conf on $NAS"
STAGE="$(ssh "${SSH_OPTIONS[@]}" "$NAS" '/usr/bin/mktemp /tmp/brokkr-tm.XXXXXX')"
[[ "$STAGE" =~ ^/tmp/brokkr-tm\.[a-zA-Z0-9]+$ ]] || { STAGE=""; echo "ERROR: invalid remote stage path" >&2; exit 2; }
scp "${SSH_OPTIONS[@]}" -q "$CONFIG" "$NAS:$STAGE"

echo "==> Installing + migrating + validating on $NAS"
ssh "${SSH_OPTIONS[@]}" "$NAS" "STAGE='$STAGE' BROKKR_SAMBA_TIME_MACHINE_STATE=$TIME_MACHINE_STATE /bin/bash -s" < "$DEPLOY_PAYLOAD_ROOT/samba/deploy-remote.sh"
echo "==> Done."
