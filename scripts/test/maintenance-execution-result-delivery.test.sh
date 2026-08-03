#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ADAPTER="$ROOT/scripts/maintenance-execution-result-delivery.mjs"
FIXTURE="$ROOT/tests/fixtures/maintenance-execution-result/clean.json"
NODE_BIN="$(command -v node)"
REVISION="1111111111111111111111111111111111111111"
DIGEST="sha256:$(printf '2%.0s' {1..64})"
ENDPOINT="https://heimdall.example.invalid/api/maintenance-execution-results"
TOKEN="dedicated-token-sentinel_1234567890"
CREDENTIAL_NAME="brokkr-maintenance-result-delivery-v1"
CREDENTIALS="$TMP/credentials"
CALLS="$TMP/curl.calls"
BODY="$TMP/curl.body"
CONFIG="$TMP/curl.config"
COUNT="$TMP/curl.count"
STATUSES="$TMP/curl.statuses"
CURL_ENV="$TMP/curl.env"
TEST_CURL_PATH="$TMP/bin:/usr/bin:/bin"
mkdir -m 0700 "$CREDENTIALS" "$TMP/bin"

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
MOCK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALLS="$MOCK_ROOT/curl.calls"
BODY="$MOCK_ROOT/curl.body"
CONFIG="$MOCK_ROOT/curl.config"
COUNT="$MOCK_ROOT/curl.count"
STATUSES="$MOCK_ROOT/curl.statuses"
CURL_ENV="$MOCK_ROOT/curl.env"
env >"$CURL_ENV"
printf '%s\n' "$@" >>"$CALLS"
cat <&3 >"$CONFIG"
cat >"$BODY"
count=0
[[ ! -f "$COUNT" ]] || read -r count <"$COUNT"
count=$((count + 1))
printf '%s\n' "$count" >"$COUNT"
IFS=',' read -r -a statuses <"$STATUSES"
index=$((count - 1))
[[ "$index" -lt "${#statuses[@]}" ]] || index=$((${#statuses[@]} - 1))
status="${statuses[$index]}"
if [[ "$status" == exit:* ]]; then
  printf 'transport-secret-sentinel\n' >&2
  exit "${status#exit:}"
fi
printf '%s' "$status"
MOCK
chmod 0755 "$TMP/bin/curl"

write_enabled_config() {
  printf '%s\n' \
    "{\"kind\":\"brokkr-maintenance-result-delivery-config\",\"schema_version\":\"v1\",\"enabled\":true,\"endpoint\":\"$ENDPOINT\",\"bearer_token\":\"$TOKEN\",\"adapter_revision\":\"$REVISION\",\"adapter_digest\":\"$DIGEST\"}" \
    >"$CREDENTIALS/$CREDENTIAL_NAME"
  chmod 0600 "$CREDENTIALS/$CREDENTIAL_NAME"
}

write_disabled_config() {
  printf '%s\n' \
    "{\"kind\":\"brokkr-maintenance-result-delivery-config\",\"schema_version\":\"v1\",\"enabled\":false,\"adapter_revision\":\"$REVISION\",\"adapter_digest\":\"$DIGEST\"}" \
    >"$CREDENTIALS/$CREDENTIAL_NAME"
  chmod 0600 "$CREDENTIALS/$CREDENTIAL_NAME"
}

run_adapter() {
  local statuses="${1:-200}"
  shift || true
  printf '%s\n' "$statuses" >"$STATUSES"
  env \
    PATH="$TEST_CURL_PATH" \
    CREDENTIALS_DIRECTORY="$CREDENTIALS" \
    BROKKR_ADAPTER_REVISION="$REVISION" \
    BROKKR_ADAPTER_DIGEST="$DIGEST" \
    "$@" \
    "$NODE_BIN" "$ADAPTER" <"$FIXTURE"
}

reset_transport() {
  rm -f "$CALLS" "$BODY" "$CONFIG" "$COUNT" "$STATUSES" "$CURL_ENV"
}

write_enabled_config
reset_transport
if ! run_adapter 200 >"$TMP/positive.out" 2>"$TMP/positive.err"; then
  sed -n '1,20p' "$TMP/positive.err" >&2
  exit 1
fi
"$NODE_BIN" -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value.kind !== "maintenance-execution-result-delivery" ||
      value.schema_version !== "v1" || value.delivered !== true ||
      value.result_id !== "result-33333333333333333333333333333333" ||
      value.execution_epoch !== 7) process.exit(1);
' "$TMP/positive.out"
test ! -s "$TMP/positive.err"
cmp "$FIXTURE" "$BODY"
grep -Fqx "url = \"$ENDPOINT\"" "$CONFIG"
grep -Fqx "header = \"Authorization: Bearer $TOKEN\"" "$CONFIG"
grep -Fqx -- "--disable" "$CALLS"
grep -Fqx -- "--max-redirs" "$CALLS"
grep -Fqx -- "--max-time" "$CALLS"
grep -Fqx -- "--max-filesize" "$CALLS"
! grep -Fq "$ENDPOINT" "$CALLS"
! grep -Fq "$TOKEN" "$CALLS"
! grep -Fq "$CREDENTIALS" "$CALLS"
! grep -Fq "$ENDPOINT" "$TMP/positive.out" "$TMP/positive.err"
! grep -Fq "$TOKEN" "$TMP/positive.out" "$TMP/positive.err"
! grep -Fq "$CREDENTIALS" "$TMP/positive.out" "$TMP/positive.err"
printf 'ok - exact v1 bytes reach the exact authenticated endpoint without argv or output leakage\n'

reset_transport
if ! run_adapter 200 \
  HTTP_PROXY=transport-env-sentinel \
  http_proxy=transport-env-sentinel \
  HTTPS_PROXY=transport-env-sentinel \
  https_proxy=transport-env-sentinel \
  ALL_PROXY=transport-env-sentinel \
  all_proxy=transport-env-sentinel \
  NO_PROXY=transport-env-sentinel \
  no_proxy=transport-env-sentinel \
  CURL_CA_BUNDLE=transport-env-sentinel \
  CURL_SSL_BACKEND=transport-env-sentinel \
  SSL_CERT_FILE=transport-env-sentinel \
  SSL_CERT_DIR=transport-env-sentinel \
  CURL_HOME=transport-env-sentinel \
  XDG_CONFIG_HOME=transport-env-sentinel \
  HOME=transport-env-sentinel \
  USERPROFILE=transport-env-sentinel \
  NETRC=transport-env-sentinel \
  REQUESTS_CA_BUNDLE=transport-env-sentinel \
  AWS_CA_BUNDLE=transport-env-sentinel \
  GIT_SSL_CAINFO=transport-env-sentinel \
  SSLKEYLOGFILE=transport-env-sentinel \
  MOCK_CURL_CALLS=transport-env-sentinel \
  MOCK_CURL_BODY=transport-env-sentinel \
  MOCK_CURL_CONFIG=transport-env-sentinel \
  MOCK_CURL_COUNT=transport-env-sentinel \
  MOCK_CURL_STATUSES=transport-env-sentinel \
  >"$TMP/environment.out" 2>"$TMP/environment.err"; then
  sed -n '1,20p' "$TMP/environment.err" >&2
  exit 1
fi
"$NODE_BIN" --input-type=module - "$CURL_ENV" "$TEST_CURL_PATH" <<'NODE'
import fs from "node:fs";
const [environmentPath, expectedPath] = process.argv.slice(2);
const entries = fs.readFileSync(environmentPath, "utf8").trim().split("\n")
  .map(line => line.split(/=(.*)/s).slice(0, 2));
const environment = Object.fromEntries(entries);
if (environment.PATH !== expectedPath || environment.LANG !== "C" ||
    environment.LC_ALL !== "C") {
  throw new Error("curl_environment_not_deterministic");
}
const shellInternals = new Set(["PATH", "LANG", "LC_ALL", "PWD", "SHLVL", "_"]);
const unexpected = Object.keys(environment)
  .filter(name => !shellInternals.has(name));
if (unexpected.length > 0) {
  throw new Error(`curl_environment_not_minimal:${unexpected.join(",")}`);
}
NODE
grep -Fqx -- "--disable" "$CALLS"
grep -Fqx -- "--noproxy" "$CALLS"
grep -Fqx -- "*" "$CALLS"
! grep -Fq 'transport-env-sentinel' "$CURL_ENV"
printf 'ok - curl receives only pinned path and locale with explicit no-proxy semantics\n'

write_disabled_config
reset_transport
run_adapter 200 >"$TMP/disabled.out" 2>"$TMP/disabled.err"
"$NODE_BIN" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1]));
  if (value.delivered !== false || value.reason !== "delivery_disabled")
    process.exit(1);
' "$TMP/disabled.out"
test ! -e "$CALLS"
test ! -s "$TMP/disabled.err"
printf 'ok - disabled gate is side-effect free\n'

write_enabled_config
chmod 0644 "$CREDENTIALS/$CREDENTIAL_NAME"
reset_transport
if run_adapter 200 >"$TMP/unsafe.out" 2>&1; then
  echo "unsafe credential unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CALLS"
! grep -Fq "$CREDENTIALS" "$TMP/unsafe.out"
! grep -Fq "$TOKEN" "$TMP/unsafe.out"
printf 'ok - unsafe protected runtime source fails before transport without leakage\n'

write_enabled_config
printf '%s\n' \
  "{\"kind\":\"brokkr-maintenance-result-delivery-config\",\"schema_version\":\"v1\",\"enabled\":true,\"endpoint\":\"$ENDPOINT\",\"bearer_token\":\"$TOKEN\",\"adapter_revision\":\"$REVISION\",\"adapter_digest\":\"sha256:$(printf '3%.0s' {1..64})\"}" \
  >"$CREDENTIALS/$CREDENTIAL_NAME"
chmod 0600 "$CREDENTIALS/$CREDENTIAL_NAME"
reset_transport
if run_adapter 200 >"$TMP/binding.out" 2>&1; then
  echo "mismatched adapter binding unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CALLS"
printf 'ok - mismatched revision/digest binding fails before transport\n'

write_enabled_config
printf '{"kind":"maintenance-execution-result"}\n' >"$TMP/malformed.json"
reset_transport
if env \
  PATH="$TEST_CURL_PATH" \
  CREDENTIALS_DIRECTORY="$CREDENTIALS" \
  BROKKR_ADAPTER_REVISION="$REVISION" \
  BROKKR_ADAPTER_DIGEST="$DIGEST" \
  "$NODE_BIN" "$ADAPTER" <"$TMP/malformed.json" >"$TMP/malformed.out" 2>&1; then
  echo "malformed result unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CALLS"
printf 'ok - malformed result fails before transport\n'

for status in 302 401 409; do
  reset_transport
  if run_adapter "$status" >"$TMP/status-$status.out" 2>&1; then
    echo "HTTP $status unexpectedly accepted" >&2
    exit 1
  fi
  test "$(cat "$COUNT")" -eq 1
  ! grep -Fq "$TOKEN" "$TMP/status-$status.out"
done
printf 'ok - redirects, authentication failure, and replay rejection fail without retry\n'

reset_transport
if run_adapter 500,500,500 >"$TMP/retry-500.out" 2>&1; then
  echo "repeated server failure unexpectedly accepted" >&2
  exit 1
fi
test "$(cat "$COUNT")" -eq 3
printf 'ok - server failure uses the bounded deterministic retry count\n'

reset_transport
if run_adapter exit:28,exit:28,exit:28 >"$TMP/timeout.out" 2>&1; then
  echo "repeated timeout unexpectedly accepted" >&2
  exit 1
fi
test "$(cat "$COUNT")" -eq 3
! grep -Fq "transport-secret-sentinel" "$TMP/timeout.out"
printf 'ok - timeouts fail closed without leaking transport stderr\n'

write_enabled_config
printf '%s\n' \
  "{\"kind\":\"brokkr-maintenance-result-delivery-config\",\"schema_version\":\"v1\",\"enabled\":true,\"endpoint\":\"$ENDPOINT/alternate\",\"bearer_token\":\"$TOKEN\",\"adapter_revision\":\"$REVISION\",\"adapter_digest\":\"$DIGEST\"}" \
  >"$CREDENTIALS/$CREDENTIAL_NAME"
chmod 0600 "$CREDENTIALS/$CREDENTIAL_NAME"
reset_transport
if run_adapter 200 >"$TMP/alternate.out" 2>&1; then
  echo "alternate endpoint unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CALLS"
printf 'ok - alternate endpoint paths and silent downgrade fail before transport\n'

write_enabled_config
reset_transport
if env -u CREDENTIALS_DIRECTORY \
  PATH="$TEST_CURL_PATH" \
  BROKKR_ADAPTER_REVISION="$REVISION" \
  BROKKR_ADAPTER_DIGEST="$DIGEST" \
  "$NODE_BIN" "$ADAPTER" <"$FIXTURE" >"$TMP/missing.out" 2>&1; then
  echo "missing credential source unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CALLS"
printf 'ok - missing configuration fails closed\n'
