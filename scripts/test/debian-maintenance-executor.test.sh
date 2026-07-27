#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/test.mjs" <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
const module = await import(`${process.env.ROOT}/scripts/debian-maintenance-executor.mjs`);
const { deriveDebianAutonomyExecution, runDebianMaintenance } = module;
const { canonicalJson, policyDigest } = await import(
  `${process.env.ROOT}/scripts/lib/maintenance-policy-contract.mjs`
);
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;

assert.deepEqual(
  Object.keys(module).sort(),
  ["deriveDebianAutonomyExecution", "runDebianMaintenance"],
  "the raw drain/reboot executor is not an exported journal-bypass capability",
);
assert.throws(() => runDebianMaintenance({}), /attempt_journal_contract_invalid/);

const policy = JSON.parse(fs.readFileSync(
  `${process.env.ROOT}/tests/fixtures/maintenance-policy/normal-window.json`, "utf8",
)).records.find(record => record.kind === "maintenance-policy");
policy.timezone = "UTC";
policy.window.days_of_week = ["sun"];
policy.window.start_local_time = "00:00";
policy.window.duration = "PT2H";
policy.selector.node_ids = ["node-a"];
policy.reboot.policy = "never";
policy.updates.allowed_sources = ["distro_repository"];
policy.updates.allowed_classes = ["security", "bugfix"];
delete policy.policy_digest;
policy.policy_digest = policyDigest(policy);
const plan = {
  kind: "brokkr-maintenance-plan", schema_version: "v1", plan_id: "bounded-plan",
  outcome: "planned", node_id: "node-a", policy_id: policy.policy_id,
  policy_digest: policy.policy_digest, inventory_evidence_id: "observation-test",
  running_kernel: "kernel-old", decision: { effect: "on_schedule" }, blockers: [],
  hook_gaps: [], unmet_policy_classes: [], created_at: "2026-07-26T00:00:00Z",
  gates: {
    package_manager_lock: "unlocked", disk: "sufficient", power: "mains",
    clock: "synchronized", workload_hooks: "not_applicable",
    kernel_recovery: "not_applicable",
  },
  candidates: [{ eligible: true, source: "distro_repository", class: "security" }],
};
plan.plan_digest = digest(plan);
const target = { node_id: "node-a", platform: "debian", non_pillar: true };
const before = { kernel: "old", packages: ["a"], reboot_required: false, dpkg_status: "clean" };
const after = { kernel: "new", packages: ["b"], reboot_required: false, dpkg_status: "clean" };
const adapterRevision = "sha256:" + "9".repeat(64);
const execution = deriveDebianAutonomyExecution({
  plan, policy, target, inventory: before,
  adapterRevisionDigest: adapterRevision, postconditions: after,
});
assert.equal(execution.execution_request_digest, digest(execution.execution_request));
assert.deepEqual(execution.execution_request.target, target);
assert.deepEqual(execution.execution_request.candidates, plan.candidates);
assert.deepEqual(execution.execution_request.config, {
  adapter_revision_digest: adapterRevision,
  plan_digest: plan.plan_digest,
  policy_digest: policy.policy_digest,
  no_reboot: true,
  no_drain: true,
});

for (const [name, mutate] of [
  ["pillar", input => { input.target.non_pillar = false; }],
  ["drain", input => { input.plan.gates.workload_hooks = "ready"; }],
  ["kernel", input => { input.plan.candidates[0].class = "kernel"; }],
  ["source", input => { input.plan.candidates[0].source = "third_party"; }],
  ["reboot", input => { input.policy.reboot.policy = "if_required"; }],
]) {
  const input = {
    plan: structuredClone(plan), policy: structuredClone(policy),
    target: structuredClone(target), inventory: before,
    adapterRevisionDigest: adapterRevision, postconditions: after,
  };
  mutate(input);
  if (["drain", "kernel", "source"].includes(name)) {
    delete input.plan.plan_digest;
    input.plan.plan_digest = digest(input.plan);
  }
  if (name === "reboot") {
    delete input.policy.policy_digest;
    input.policy.policy_digest = policyDigest(input.policy);
  }
  assert.throws(
    () => deriveDebianAutonomyExecution(input),
    /autonomy_execution_out_of_scope/,
    name,
  );
}
console.log("debian executor: closed export surface and immutable no-reboot/no-drain request OK");
NODE
env ROOT="$ROOT" node "$TMP/test.mjs"
