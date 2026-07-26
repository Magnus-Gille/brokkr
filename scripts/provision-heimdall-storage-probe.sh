#!/usr/bin/env bash
# Provision/revoke the tracked forced-command NAS probe with content-blind network failures.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=lib/deploy-source.sh
source "$HERE/lib/deploy-source.sh"

PROBE_USER=heimdall-storage-probe
PROBE_PATH=/usr/local/lib/brokkr/heimdall-storage-probe
CONFIG_PATH=/etc/brokkr/heimdall-storage-probe.conf
MANAGED_MARKER=/var/lib/brokkr/heimdall-storage-probe.managed
AUTH_OPTIONS="command=\"$PROBE_PATH\",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty"

die() { echo "brokkr storage probe: $*" >&2; exit 64; }
protected() {
  local file=$1 mode
  [[ -f "$file" && ! -L "$file" ]] || return 1
  if ! mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
    mode="$(stat -f '%Lp' "$file")" || return 1
  fi
  (( (8#$mode & 077) == 0 ))
}
need() {
  local name=$1 value=${!1:-}
  [[ -n "$value" ]] || die "$name is required"
  protected "$value" || die "$name must be a protected non-symlink regular file"
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
[[ $# -eq 2 && ( $1 == apply || $1 == revoke ) ]] || die 'Usage: apply|revoke ADMIN_SSH_TARGET'
MODE=$1
TARGET=$2
[[ "$TARGET" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die 'ADMIN_SSH_TARGET has unsupported characters'
HOST=${TARGET##*@}
require_brokkr_deploy_source_binding "$REPO_ROOT"
need BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS
if [[ $MODE == apply ]]; then
  need BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE
  need BROKKR_HEIMDALL_STORAGE_SSH_KEY
  need BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG
  PUBKEY="$(awk 'NF {print $1 " " $2; exit}' "$BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE")"
  [[ "$PUBKEY" =~ ^ssh-ed25519[[:space:]]+AAAA[[:alnum:]+/=]+$ &&
    $(grep -cve '^[[:space:]]*$' "$BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE") -eq 1 ]] ||
    die 'probe public key must contain exactly one ssh-ed25519 key'
  FINGERPRINT="$(ssh-keygen -lf "$BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE" | awk 'NR==1 {print $2}')"
  [[ "$FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]+={0,2}$ ]] ||
    die 'could not read public-key fingerprint'
  bash -n "$HERE/heimdall-storage-probe.sh" || die 'tracked probe script has invalid shell syntax'
  [[ "$(grep -Ec '^echo ---[[:space:]]*$' "$HERE/heimdall-storage-probe.sh")" -eq 18 ]] ||
    die 'tracked probe script must declare exactly 19 sections'
  BROKKR_STORAGE_PROBE_CONFIG="$BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG" \
    bash "$HERE/heimdall-storage-probe.sh" --validate-config ||
    die 'probe configuration is invalid'
  PROBE_SHA256=$(sha256 "$HERE/heimdall-storage-probe.sh")
  CONFIG_SHA256=$(sha256 "$BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG")
fi
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS")
BASE="/tmp/brokkr-storage-probe.$$."
STAGE_PROBE="${BASE}probe.new"
STAGE_CONFIG="${BASE}config.new"
cleanup() {
  [[ ${STAGED:-0} == 1 ]] &&
    "${SSH[@]}" "$TARGET" "rm -f '$STAGE_PROBE' '$STAGE_CONFIG'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
if [[ $MODE == apply ]]; then
  STAGED=1
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS" "$HERE/heimdall-storage-probe.sh" "$TARGET:$STAGE_PROBE" 2>/dev/null || die 'probe staging failed'
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS" "$BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG" "$TARGET:$STAGE_CONFIG" 2>/dev/null || die 'config staging failed'
fi
env_args="$(printf '%q ' \
  "BROKKR_STORAGE_MODE=$MODE" \
  "BROKKR_STORAGE_USER=$PROBE_USER" \
  "BROKKR_STORAGE_PROBE_PATH=$PROBE_PATH" \
  "BROKKR_STORAGE_CONFIG_PATH=$CONFIG_PATH" \
  "BROKKR_STORAGE_MARKER=$MANAGED_MARKER" \
  "BROKKR_STORAGE_AUTH_OPTIONS=$AUTH_OPTIONS" \
  "BROKKR_STORAGE_STAGE_PROBE=$STAGE_PROBE" \
  "BROKKR_STORAGE_STAGE_CONFIG=$STAGE_CONFIG" \
  "BROKKR_STORAGE_PUBKEY=${PUBKEY:-}" \
  "BROKKR_STORAGE_FINGERPRINT=${FINGERPRINT:-}" \
  "BROKKR_STORAGE_EXPECTED_PROBE_SHA256=${PROBE_SHA256:-}" \
  "BROKKR_STORAGE_EXPECTED_CONFIG_SHA256=${CONFIG_SHA256:-}")"
metadata=$("${SSH[@]}" "$TARGET" "sudo env $env_args bash -s" \
  <"$HERE/lib/heimdall-storage-probe-reconcile.sh" 2>/dev/null) ||
  die 'remote reconciliation failed'
STAGED=0
if [[ $MODE == apply ]]; then
  output=$(ssh -i "$BROKKR_HEIMDALL_STORAGE_SSH_KEY" \
    -o BatchMode=yes -o IdentitiesOnly=yes \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS" \
    "$PROBE_USER@$HOST" true 2>/dev/null) ||
    die 'authenticated probe readback failed'
  sections=$(printf '%s\n' "$output" | awk '$0=="---"{n++} END{print n+1}')
  [[ $sections == 19 ]] ||
    die 'authenticated probe did not return the 19-section contract'
  [[ "$metadata" == "key_fingerprint=$FINGERPRINT probe_sha256=$PROBE_SHA256 config_sha256=$CONFIG_SHA256" ]] ||
    die 'remote metadata contract invalid'
  printf 'brokkr storage probe: applied; key_fingerprint=%s probe_sha256=%s config_bound=true sections=%s\n' \
    "$FINGERPRINT" "$PROBE_SHA256" "$sections"
else
  [[ $metadata == revoked=1 ]] || die 'remote revocation metadata invalid'
  echo 'brokkr storage probe: revoked managed authorization and locked dedicated account'
fi
