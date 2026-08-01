#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMPLATE="$ROOT/network/tailscale/m5-policy.example.json"
RENDERER="$ROOT/scripts/render-m5-tailnet-policy.mjs"
AUDIT="$ROOT/scripts/m5-tailnet-drift-audit.mjs"

TMPDIR_ROOT=${TMPDIR:-/tmp}
CASE_DIR=$(mktemp -d "$TMPDIR_ROOT/brokkr-m5-tailnet-test.XXXXXX")
trap 'rm -rf "$CASE_DIR"' EXIT
chmod 700 "$CASE_DIR"

node --input-type=module - "$TEMPLATE" <<'NODE'
import fs from "node:fs";
import assert from "node:assert/strict";

const policy = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const ports = {
  ssh: "tag:m5-server:22",
  samba: "tag:m5-server:445",
  gateway: "tag:m5-inference:8080",
  whisper: "tag:m5-inference:8092",
  runtime: "tag:m5-inference:8091",
};
const all = Object.values(ports);
const expected = new Map([
  ["m5-operator-device", { accept: [ports.ssh, ports.samba, ports.gateway], deny: [ports.whisper, ports.runtime] }],
  ["tag:m5-gateway-client", { accept: [ports.gateway], deny: [ports.ssh, ports.samba, ports.whisper, ports.runtime] }],
  ["tag:m5-whisper-client", { accept: [ports.whisper], deny: [ports.ssh, ports.samba, ports.gateway, ports.runtime] }],
  ["tag:m5-runtime-client", { accept: [ports.runtime], deny: [ports.ssh, ports.samba, ports.gateway, ports.whisper] }],
  ["tag:ordinary-client", { accept: [], deny: all }],
  ["tag:guest-client", { accept: [], deny: all }],
]);

assert.deepEqual(policy.hosts, { "m5-operator-device": "__BROKKR_OPERATOR_ADDRESS__" });
assert.equal(policy.groups, undefined);
assert.equal(policy.postures, undefined);
assert.deepEqual(policy.tagOwners, {
  "tag:m5-server": ["autogroup:owner"],
  "tag:m5-inference": ["autogroup:owner"],
  "tag:m5-gateway-client": ["autogroup:owner"],
  "tag:m5-whisper-client": ["autogroup:owner"],
  "tag:m5-runtime-client": ["autogroup:owner"],
  "tag:ordinary-client": ["autogroup:owner"],
  "tag:guest-client": ["autogroup:owner"],
});
assert.deepEqual(policy.grants, [
  { src: ["m5-operator-device"], dst: ["tag:m5-server"], ip: ["tcp:22", "tcp:445"] },
  { src: ["m5-operator-device"], dst: ["tag:m5-inference"], ip: ["tcp:8080"] },
  { src: ["tag:m5-gateway-client"], dst: ["tag:m5-inference"], ip: ["tcp:8080"] },
  { src: ["tag:m5-whisper-client"], dst: ["tag:m5-inference"], ip: ["tcp:8092"] },
  { src: ["tag:m5-runtime-client"], dst: ["tag:m5-inference"], ip: ["tcp:8091"] },
]);
assert.equal(policy.grants.some((grant) => grant.src.includes("*") || grant.dst.includes("*") || grant.ip.includes("*")), false);
assert.equal(policy.grants.some((grant) => grant.src.includes("tag:m5-operator")), false);
assert.deepEqual(policy.ssh, []);

const tests = new Map(policy.tests.map((test) => [test.src, { accept: test.accept ?? [], deny: test.deny ?? [] }]));
assert.deepEqual(tests, expected);
assert.deepEqual(policy.sshTests, [{
  src: "m5-operator-device",
  dst: ["tag:m5-server"],
  deny: ["root", "operator"],
}]);
NODE

PRIVATE_PATTERN='([[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|100\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|[fF][dD][0-9a-fA-F]{2}:|tskey-|device[Ii][Dd]|tailnet name)'
if rg -n --glob '*.json' --glob '*.md' --glob '*.mjs' --glob '*.sh' \
  "$PRIVATE_PATTERN" "$ROOT/network/tailscale" "$ROOT/runbooks/m5-tailnet-access.md" "$AUDIT" "$RENDERER"; then
  echo "public M5 tailnet artifacts contain forbidden private locator material" >&2
  exit 1
fi
printf 'peer=%s%s\n' 'fd' '7a:115c:a1e0::1' > "$CASE_DIR/private-v6.fixture"
rg -q "$PRIVATE_PATTERN" "$CASE_DIR/private-v6.fixture" || { echo "private IPv6 locator scan regressed" >&2; exit 1; }

cat > "$CASE_DIR/bindings.json" <<JSON
{
  "schema_version": "v1",
  "bindings": [
    {"stable_id":"opaque-operator","identity_kind":"user","observed_user":"opaque-user","operator_address":"192.0.2.10","roles":["m5-operator"],"managed_tags":[]},
    {"stable_id":"opaque-m5","identity_kind":"tagged","roles":["m5-server","m5-inference"],"managed_tags":["tag:m5-inference","tag:m5-server"]},
    {"stable_id":"opaque-gateway","identity_kind":"tagged","roles":["m5-gateway-client"],"managed_tags":["tag:m5-gateway-client"]},
    {"stable_id":"opaque-whisper","identity_kind":"tagged","roles":["m5-whisper-client"],"managed_tags":["tag:m5-whisper-client"]},
    {"stable_id":"opaque-runtime","identity_kind":"tagged","roles":["m5-runtime-client"],"managed_tags":["tag:m5-runtime-client"]}
  ]
}
JSON
chmod 600 "$CASE_DIR/bindings.json"

node "$RENDERER" --template "$TEMPLATE" --bindings "$CASE_DIR/bindings.json" --output "$CASE_DIR/expected-policy.json"
[[ $(stat -f '%Lp' "$CASE_DIR/expected-policy.json" 2>/dev/null || stat -c '%a' "$CASE_DIR/expected-policy.json") == 600 ]]
node --input-type=module - "$CASE_DIR/expected-policy.json" <<'NODE'
import fs from "node:fs";
import assert from "node:assert/strict";
const policy = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.deepEqual(policy.hosts, { "m5-operator-device": "192.0.2.10" });
assert.equal(JSON.stringify(policy).includes("__BROKKR_OPERATOR_ADDRESS__"), false);
NODE

cp "$CASE_DIR/expected-policy.json" "$CASE_DIR/observed-policy.json"
printf '%s\n' '{"devicesApprovalOn":true}' > "$CASE_DIR/settings.json"
cat > "$CASE_DIR/devices.json" <<'JSON'
{"devices":[
  {"id":"opaque-operator","user":"opaque-user","addresses":["192.0.2.10"],"authorized":true,"tags":[]},
  {"id":"opaque-m5","authorized":true,"tags":["tag:m5-server","tag:m5-inference"]},
  {"id":"opaque-gateway","authorized":true,"tags":["tag:m5-gateway-client"]},
  {"id":"opaque-whisper","authorized":true,"tags":["tag:m5-whisper-client"]},
  {"id":"opaque-runtime","authorized":true,"tags":["tag:m5-runtime-client"]},
  {"id":"opaque-phone","user":"opaque-user","addresses":["192.0.2.20"],"authorized":true,"tags":[]}
]}
JSON
chmod 600 "$CASE_DIR/observed-policy.json" "$CASE_DIR/settings.json" "$CASE_DIR/devices.json"

node "$AUDIT" \
  --expected-policy "$CASE_DIR/expected-policy.json" \
  --expected-bindings "$CASE_DIR/bindings.json" \
  --observed-policy "$CASE_DIR/observed-policy.json" \
  --observed-settings "$CASE_DIR/settings.json" \
  --observed-devices "$CASE_DIR/devices.json" > "$CASE_DIR/pass.json"

node --input-type=module - "$CASE_DIR/pass.json" <<'NODE'
import fs from "node:fs";
import assert from "node:assert/strict";
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.deepEqual(result, {
  schema_version: "v1",
  outcome: "pass",
  policy_matches: true,
  device_approval_enabled: true,
  role_bindings_match: true,
  pending_device_approvals: 0,
});
NODE

# Moving a managed role to a different device is drift even when tag counts match.
cat > "$CASE_DIR/devices.json" <<'JSON'
{"devices":[
  {"id":"opaque-operator","user":"opaque-user","addresses":["192.0.2.10"],"authorized":true,"tags":[]},
  {"id":"opaque-m5","authorized":true,"tags":["tag:m5-server","tag:m5-inference"]},
  {"id":"opaque-gateway","authorized":true,"tags":[]},
  {"id":"opaque-whisper","authorized":true,"tags":["tag:m5-whisper-client"]},
  {"id":"opaque-runtime","authorized":true,"tags":["tag:m5-runtime-client"]},
  {"id":"opaque-phone","user":"opaque-user","addresses":["192.0.2.20"],"authorized":true,"tags":["tag:m5-gateway-client"]}
]}
JSON
chmod 600 "$CASE_DIR/devices.json"
set +e
node "$AUDIT" \
  --expected-policy "$CASE_DIR/expected-policy.json" \
  --expected-bindings "$CASE_DIR/bindings.json" \
  --observed-policy "$CASE_DIR/observed-policy.json" \
  --observed-settings "$CASE_DIR/settings.json" \
  --observed-devices "$CASE_DIR/devices.json" > "$CASE_DIR/drift.json" 2> "$CASE_DIR/drift.err"
status=$?
set -e
[[ $status -eq 2 ]] || { echo "expected binding drift exit 2, got $status" >&2; exit 1; }
rg -q '"role_bindings_match":false' "$CASE_DIR/drift.json"
if rg -n 'opaque-|m5-gateway-client|must-not-leak' "$CASE_DIR/drift.json" "$CASE_DIR/drift.err"; then
  echo "audit exposed private role-binding metadata" >&2
  exit 1
fi

# Moving the exact operator address to a phone is also binding drift.
cat > "$CASE_DIR/devices.json" <<'JSON'
{"devices":[
  {"id":"opaque-operator","user":"opaque-user","addresses":["192.0.2.20"],"authorized":true,"tags":[]},
  {"id":"opaque-m5","authorized":true,"tags":["tag:m5-server","tag:m5-inference"]},
  {"id":"opaque-gateway","authorized":true,"tags":["tag:m5-gateway-client"]},
  {"id":"opaque-whisper","authorized":true,"tags":["tag:m5-whisper-client"]},
  {"id":"opaque-runtime","authorized":true,"tags":["tag:m5-runtime-client"]},
  {"id":"opaque-phone","user":"opaque-user","addresses":["192.0.2.10"],"authorized":true,"tags":[]}
]}
JSON
chmod 600 "$CASE_DIR/devices.json"
set +e
node "$AUDIT" \
  --expected-policy "$CASE_DIR/expected-policy.json" \
  --expected-bindings "$CASE_DIR/bindings.json" \
  --observed-policy "$CASE_DIR/observed-policy.json" \
  --observed-settings "$CASE_DIR/settings.json" \
  --observed-devices "$CASE_DIR/devices.json" > "$CASE_DIR/address-drift.json" 2> "$CASE_DIR/address-drift.err"
status=$?
set -e
[[ $status -eq 2 ]]
rg -q '"role_bindings_match":false' "$CASE_DIR/address-drift.json"
if rg -n 'opaque-|192\.0\.2\.' "$CASE_DIR/address-drift.json" "$CASE_DIR/address-drift.err"; then
  echo "audit exposed private operator binding metadata" >&2
  exit 1
fi

# Every private input must be an owner-owned, non-symlink regular file with mode 0600.
chmod 644 "$CASE_DIR/settings.json"
set +e
node "$AUDIT" \
  --expected-policy "$CASE_DIR/expected-policy.json" \
  --expected-bindings "$CASE_DIR/bindings.json" \
  --observed-policy "$CASE_DIR/observed-policy.json" \
  --observed-settings "$CASE_DIR/settings.json" \
  --observed-devices "$CASE_DIR/devices.json" > "$CASE_DIR/mode.out" 2> "$CASE_DIR/mode.err"
status=$?
set -e
[[ $status -eq 1 ]]
rg -q 'private_input_unsafe' "$CASE_DIR/mode.err"
chmod 600 "$CASE_DIR/settings.json"
ln -s "$CASE_DIR/settings.json" "$CASE_DIR/settings-link.json"
set +e
node "$AUDIT" \
  --expected-policy "$CASE_DIR/expected-policy.json" \
  --expected-bindings "$CASE_DIR/bindings.json" \
  --observed-policy "$CASE_DIR/observed-policy.json" \
  --observed-settings "$CASE_DIR/settings-link.json" \
  --observed-devices "$CASE_DIR/devices.json" > "$CASE_DIR/link.out" 2> "$CASE_DIR/link.err"
status=$?
set -e
[[ $status -eq 1 ]]
rg -q 'private_input_unsafe' "$CASE_DIR/link.err"

echo "m5 tailnet policy tests passed"
