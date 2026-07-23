#!/usr/bin/env bash
# Brokkr · verify authenticated Heimdall panel delivery without exposing a token.
#
# Runs on the deployment target. The fleet token stays in the protected source
# file and reaches curl only through its stdin configuration, never argv/output.
set -euo pipefail

HEIMDALL_URL="${1:-}"
TOKEN_SOURCE="${2:-}"

fail() {
  echo "brokkr Heimdall preflight: authenticated panel delivery failed" >&2
  exit 2
}

# The deployer validates both arguments and the source permissions before this
# helper runs. Recheck the token shape here so the helper stays safe to invoke
# directly from a controlled server-side deployment workflow.
[[ "$HEIMDALL_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || fail
if [ "$(grep -Ec '^HEIMDALL_FLEET_TOKEN=' "$TOKEN_SOURCE" 2>/dev/null)" -ne 1 ]; then
  fail
fi
token="$(grep -E '^HEIMDALL_FLEET_TOKEN=' "$TOKEN_SOURCE")"
[[ "$token" =~ ^HEIMDALL_FLEET_TOKEN=.+$ ]] || fail
token="${token#HEIMDALL_FLEET_TOKEN=}"
[[ "$token" =~ ^[[:alnum:]._~+/\-]+={0,2}$ ]] || fail

# The authenticated service readback is the non-mutating panel API operation.
# It returns 401 for a wrong fleet token, so a 2xx proves the endpoint is
# reachable and accepts this credential. Restricting the token to RFC 6750's
# b64token alphabet makes its interpolation into curl's quoted config safe.
probe_url="${HEIMDALL_URL}?service=brokkr"
status="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
  curl --disable --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 --config - --request GET "$probe_url")" || fail

case "$status" in
  2??) exit 0 ;;
  *) fail ;;
esac
