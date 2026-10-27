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
# Root never operates on a path inside the runtime user's writable config
# directory (a symlink swap there would turn chown/chmod/mv into a privilege
# escalation). Root only reads the protected source and builds the content in
# shell variables; the runtime user reads the existing env, creates the
# directory, and writes the temp file and renames it into place, receiving the
# content on stdin. A failed run leaves the previous runtime env untouched.
# Token values are handled only through shell variables, builtins and stdin:
# never argv, never output. The control-node preflight probes a copy staged in a
# private root-owned directory, never in the runtime user's directory.
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

# Print the number of token assignments read from stdin; a read error is fatal.
count_tokens() {
  local n rc=0
  n="$(grep -Ec '^HEIMDALL_FLEET_TOKEN=')" || rc=$?
  [[ "$rc" -le 1 ]] || return 2
  printf '%s' "$n"
}

# Run a command as the runtime user (stdin is passed through).
as_user() { sudo -u "$RUNTIME_USER" -- "$@"; }

[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || fail "Heimdall token source is not a regular file"
source_count="$(count_tokens <"$SOURCE")" || fail "Heimdall token source is unreadable"
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
  # Root only stats the path above. The content is read as the runtime user, so
  # a symlink swapped in after the check cannot make root read another file.
  env_content="$(as_user cat -- "$RUNTIME_ENV")" || fail "existing Heimdall runtime environment is unreadable"
  env_count="$(printf '%s\n' "$env_content" | count_tokens)" || fail "existing Heimdall runtime environment is unreadable"
  case "$env_count" in
    0) ;;
    1)
      env_line="$(printf '%s\n' "$env_content" | grep -E '^HEIMDALL_FLEET_TOKEN=')"
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
unset existing_token source_token env_content

# Build the final content in memory only.
case "$PROFILE" in
  control-node) managed="HEIMDALL_HUB_URL=$HEIMDALL_URL" ;;
  nas)
    managed="$(grep -E '^(HEIMDALL_HUB_URL|BROKKR_TAILSCALE_(KEY_EXPIRY_POLICY|EXPECTED_DNS_NAME|EXPIRY_WARN_SECS))=' "$SOURCE" \
      || [[ $? -eq 1 ]])"
    ;;
esac
content="$managed"$'\n'"HEIMDALL_FLEET_TOKEN=$token"
[[ -n "$managed" ]] || content="HEIMDALL_FLEET_TOKEN=$token"
unset token managed

# A read-back that only proves the source token would pass for a legacy
# credential Heimdall no longer accepts for writes. Probe exactly the content
# about to be installed, staged in a private root-owned directory.
if [[ "$PROFILE" == control-node ]]; then
  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-heimdall-stage.XXXXXX")"
  trap 'rm -rf "$stage_dir"' EXIT
  printf '%s\n' "$content" >"$stage_dir/env"
  bash "$VERIFY_HELPER" "$HEIMDALL_URL" "$stage_dir/env" \
    || fail "Heimdall endpoint preflight failed; refusing to enable timers"
  rm -rf "$stage_dir"
fi

# Create the directory, the temp file and the rename as the runtime user; the
# content arrives on stdin. mv -f replaces a symlinked final name rather than
# following it. The file is owned by the runtime user (its primary group).
env_dir="$(dirname "$RUNTIME_ENV")"
printf '%s\n' "$content" | as_user sh -c 'umask 077
  d=$1; f=$2
  [ ! -L "$d" ] || exit 2
  mkdir -p "$d" && chmod 0700 "$d" || exit 2
  t=$(mktemp "$d/.env.XXXXXX") || exit 2
  if cat >"$t" && chmod 0600 "$t" && mv -f "$t" "$f"; then exit 0; fi
  rm -f "$t"; exit 2' sh "$env_dir" "$RUNTIME_ENV" \
  || fail "could not write the Heimdall runtime environment"
unset content
echo "   Heimdall token $outcome"
