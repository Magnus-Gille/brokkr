#!/usr/bin/env bash
# Brokkr · build the Heimdall runtime env without clobbering a provisioned token.
#
# Runs as root on the deployment target, invoked by the deploy scripts. Heimdall
# issues each producer its own write token under the same HEIMDALL_FLEET_TOKEN
# key, so an existing runtime token is preserved by default; the protected
# source token only seeds a runtime env that has none, or replaces it when the
# operator explicitly passed replace=1 (BROKKR_REPLACE_HEIMDALL_TOKEN=1).
#
# Usage: prepare-heimdall-runtime-env.sh PROFILE RUNTIME_ENV RUNTIME_USER SOURCE REPLACE [URL]
#   PROFILE  control-node: write HEIMDALL_HUB_URL=URL plus the token, and verify
#                          authenticated delivery with the token about to be used.
#            nas:          copy the Heimdall URL and Tailscale policy assignments
#                          from SOURCE; the token follows the same rules.
#   REPLACE  0 = preserve an existing token, 1 = take the token from SOURCE.
#
# The new file is built beside the target and renamed into place, so a failed
# run leaves the previous runtime env untouched. Token values are handled only
# through shell variables and builtins: never argv, never output.
set -euo pipefail
umask 077

PROFILE="${1:-}"
RUNTIME_ENV="${2:-}"
RUNTIME_USER="${3:-}"
SOURCE="${4:-}"
REPLACE="${5:-}"
HEIMDALL_URL="${6:-}"
VERIFY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/verify-heimdall-delivery.sh"

fail() { echo "ERROR: $*" >&2; exit 2; }

case "$PROFILE" in control-node|nas) ;; *) fail "unknown runtime env profile" ;; esac
case "$REPLACE" in 0|1) ;; *) fail "replace flag must be 0 or 1" ;; esac
[[ -n "$RUNTIME_ENV" && -n "$RUNTIME_USER" && -n "$SOURCE" ]] || fail "runtime env, user and source are required"
if [[ "$PROFILE" == control-node ]]; then
  [[ "$HEIMDALL_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || fail "invalid Heimdall panel endpoint"
fi

# Print the number of token assignments in a file; a read error is fatal.
count_tokens() {
  local n rc=0
  n="$(grep -Ec '^HEIMDALL_FLEET_TOKEN=' "$1")" || rc=$?
  [[ "$rc" -le 1 ]] || return 2
  printf '%s' "$n"
}

[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || fail "Heimdall token source is not a regular file"
source_count="$(count_tokens "$SOURCE")" || fail "Heimdall token source is unreadable"
[[ "$source_count" -eq 1 ]] || fail "Heimdall token source must contain exactly one non-empty fleet token"
source_line="$(grep -E '^HEIMDALL_FLEET_TOKEN=' "$SOURCE")"
source_token="${source_line#HEIMDALL_FLEET_TOKEN=}"
[[ -n "$source_token" ]] || fail "Heimdall token source must contain exactly one non-empty fleet token"
unset source_line

# Inspect the existing runtime env first. Anything ambiguous fails closed with
# the file untouched: a symlink, a duplicate or an empty assignment.
existing_token=""
if [[ -e "$RUNTIME_ENV" || -L "$RUNTIME_ENV" ]]; then
  [[ -f "$RUNTIME_ENV" && ! -L "$RUNTIME_ENV" ]] || fail "existing Heimdall runtime environment is not a regular file"
  env_count="$(count_tokens "$RUNTIME_ENV")" || fail "existing Heimdall runtime environment is unreadable"
  case "$env_count" in
    0) ;;
    1)
      env_line="$(grep -E '^HEIMDALL_FLEET_TOKEN=' "$RUNTIME_ENV")"
      existing_token="${env_line#HEIMDALL_FLEET_TOKEN=}"
      unset env_line
      [[ -n "$existing_token" ]] || fail "existing Heimdall runtime environment has an empty fleet token"
      ;;
    *) fail "existing Heimdall runtime environment has duplicate fleet token assignments" ;;
  esac
fi

if [[ -n "$existing_token" && "$REPLACE" -eq 0 ]]; then
  token="$existing_token"
  outcome="preserved from existing runtime env"
else
  token="$source_token"
  outcome="provisioned from protected source"
  [[ "$REPLACE" -eq 0 ]] || outcome="$outcome (replacement requested)"
fi
unset existing_token source_token

env_dir="$(dirname "$RUNTIME_ENV")"
[[ -d "$env_dir" && ! -L "$env_dir" ]] || fail "runtime env directory is not usable"
tmp_env="$(mktemp "$env_dir/.env.XXXXXX")"
trap 'rm -f "$tmp_env"' EXIT

{
  case "$PROFILE" in
    control-node) printf 'HEIMDALL_HUB_URL=%s\n' "$HEIMDALL_URL" ;;
    nas)
      grep -E '^(HEIMDALL_HUB_URL|BROKKR_TAILSCALE_(KEY_EXPIRY_POLICY|EXPECTED_DNS_NAME|EXPIRY_WARN_SECS))=' "$SOURCE" \
        || [[ $? -eq 1 ]]
      ;;
  esac
  printf 'HEIMDALL_FLEET_TOKEN=%s\n' "$token"
} >"$tmp_env"
unset token

case "$PROFILE" in
  control-node) chown "$RUNTIME_USER:$RUNTIME_USER" "$tmp_env" ;;
  nas) chown "$RUNTIME_USER" "$tmp_env" ;;
esac
chmod 0600 "$tmp_env"

# A read-back that only proves the source token would pass for a legacy
# credential Heimdall no longer accepts for writes. Probe the file being
# installed, so the token that will actually be used is the one verified.
if [[ "$PROFILE" == control-node ]]; then
  bash "$VERIFY_HELPER" "$HEIMDALL_URL" "$tmp_env" \
    || fail "Heimdall endpoint preflight failed; refusing to enable timers"
fi

mv -f "$tmp_env" "$RUNTIME_ENV"
echo "   Heimdall token $outcome"
