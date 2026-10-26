#!/usr/bin/env bash
# Structural regression for the control-node Tailscale SSH removal fragment.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMPLATE="$ROOT/network/tailscale/control-node-ssh-policy.example.json"
RUNBOOK="$ROOT/runbooks/control-node-openssh-cutover.md"

echo "control-node-ssh-policy.test.sh"

node --input-type=module - "$TEMPLATE" <<'NODE'
import fs from "node:fs";
import assert from "node:assert/strict";

const policy = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

assert.deepEqual(Object.keys(policy).sort(), ["grants", "hosts", "ssh", "sshTests", "tests"]);
assert.deepEqual(policy.hosts, {
  "control-node": "__BROKKR_CONTROL_NODE_ADDRESS__",
  "control-node-operator-device": "__BROKKR_OPERATOR_ADDRESS__",
  "control-node-peer-deny-probe": "__BROKKR_PEER_DENY_PROBE_ADDRESS__",
});

// OpenSSH over the tailnet stays reachable from the exact operator device only.
assert.deepEqual(policy.grants, [
  { src: ["control-node-operator-device"], dst: ["control-node"], ip: ["tcp:22"] },
]);
assert.deepEqual(policy.tests, [
  { src: "control-node-operator-device", proto: "tcp", accept: ["control-node:22"] },
]);

// No Tailscale SSH rule may survive the merge for the control node: the
// strongest source (the operator device) and an ordinary same-user peer are
// both denied root and a non-root probe account.
assert.deepEqual(policy.ssh, []);
assert.deepEqual(policy.sshTests, [
  { src: "control-node-operator-device", dst: ["control-node"], deny: ["root", "operator"] },
  { src: "control-node-peer-deny-probe", dst: ["control-node"], deny: ["root", "operator"] },
]);
for (const test of policy.sshTests) {
  assert.equal(test.accept, undefined);
  assert.equal(test.check, undefined);
}

const text = JSON.stringify(policy);
for (const forbidden of ["*", "autogroup:", "tag:"]) {
  assert.equal(text.includes(forbidden), false, `fragment must not contain ${forbidden}`);
}
NODE
echo "  PASS  fragment keeps OpenSSH for the operator and denies every Tailscale SSH path"

PRIVATE_PATTERN='([[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|100\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|[fF][dD][0-9a-fA-F]{2}:|tskey-|SHA256:[A-Za-z0-9+/]{43}|hugin ?munin)'
if grep -EIin "$PRIVATE_PATTERN" "$TEMPLATE" "$RUNBOOK"; then
  echo "  FAIL  public control-node SSH artifacts contain private locator material" >&2
  exit 1
fi
echo "  PASS  public control-node SSH artifacts contain no private locators"

CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brokkr-control-node-ssh-policy.XXXXXX")
trap 'rm -rf "$CASE_DIR"' EXIT
printf 'host=%s%s\n' 'hugin' 'munin' > "$CASE_DIR/name.fixture"
printf 'key=SHA256:%s\n' "$(printf 'A%.0s' $(seq 43))" > "$CASE_DIR/fingerprint.fixture"
for fixture in "$CASE_DIR/name.fixture" "$CASE_DIR/fingerprint.fixture"; do
  grep -EIiq "$PRIVATE_PATTERN" "$fixture" || { echo "  FAIL  private locator scan regressed" >&2; exit 1; }
done
echo "  PASS  private locator scan catches host names and fingerprints"
