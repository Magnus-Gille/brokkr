#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/test.mjs" <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";

const adapter = await import(`${process.env.ROOT}/scripts/debian-maintenance-host-adapter.mjs`);
const digest = value => `sha256:${crypto.createHash("sha256").update(adapter.canonicalJson(value)).digest("hex")}`;
const candidate = {
  id: "openssl@3.0.17-1~deb12u2", name: "openssl", class: "security",
  source: "distro_repository", current_version: "3.0.17-1~deb12u1",
  candidate_version: "3.0.17-1~deb12u2", eligible: true, reasons: [],
};
const request = {
  kind: "brokkr-debian-host-adapter-request", schema_version: "v1", action: "apply",
  attempt_id: "attempt-67", binding_digest: "sha256:" + "1".repeat(64),
  plan_digest: "sha256:" + "2".repeat(64),
  constitution_digest: "sha256:" + "3".repeat(64),
  release_digest: "sha256:" + "4".repeat(64),
  execution_request: {
    kind: "brokkr-bounded-debian-maintenance-request", schema_version: "v1",
    target: { node_id: "test-node", platform: "debian", non_pillar: true },
    candidates: [candidate],
    config: {
      adapter_revision_digest: "sha256:" + "4".repeat(64),
      plan_digest: "sha256:" + "2".repeat(64), policy_digest: "sha256:" + "6".repeat(64),
      no_reboot: true, no_drain: true,
    },
    pre_state: { kernel: "6.1.0-test", packages: ["openssl=3.0.17-1~deb12u1"], reboot_required: false, dpkg_status: "clean" },
    expected_postconditions: { kernel: "6.1.0-test", packages: ["openssl=3.0.17-1~deb12u2"], reboot_required: false, dpkg_status: "clean" },
  },
  recovery_descriptor: {
    kind: "brokkr-debian-recovery-descriptor", schema_version: "v1",
    descriptor_id: "recovery-67", attempt_id: "attempt-67",
    binding_digest: "sha256:" + "1".repeat(64),
    packages: ["openssl"], restart_units: ["brokkr-maintenance-safe.service"],
    budget_seconds: 240,
  },
};
const aptPolicy = "openssl:\n  Installed: 3.0.17-1~deb12u1\n  Candidate: 3.0.17-1~deb12u2\n  Version table:\n     3.0.17-1~deb12u2 500\n        500 http://deb.debian.org/debian-security bookworm-security/main amd64 Packages\n";
const aptTrust = "APT::Get::Assume-Yes \"false\";\n";
request.apt_source_evidence = { kind: "brokkr-debian-apt-source-evidence", schema_version: "v1", plan_digest: request.plan_digest, policy_digest: request.execution_request.config.policy_digest, trust_config_digest: digest(aptTrust), candidates: [{ name: "openssl", policy_output_digest: digest(aptPolicy) }] };
request.apt_source_evidence_digest = digest(request.apt_source_evidence);
request.execution_request_digest = digest(request.execution_request);
request.recovery_descriptor_digest = digest(request.recovery_descriptor);
request.lease_fence = {
  kind: "brokkr-effect-lease-fence", schema_version: "v1", domain: "no-reboot-security-bugfix-maintenance",
  target_scope_digest: digest({ node_id: "test-node", platform: "debian" }), attempt_id: "attempt-67", mutation_id: "mutation-67",
  binding_digest: request.binding_digest, epoch: 1, holder_token: "test-fence-token-0123456789",
  activated_at: "2026-07-27T12:00:00Z", expires_at: "2026-07-27T12:05:00Z",
};
request.lease_fence_digest = digest(request.lease_fence);
const recoveryActivation = { kind: "brokkr-debian-recovery-activation", schema_version: "v1", attempt_id: request.attempt_id,
  binding_digest: request.binding_digest, recovery_descriptor_digest: request.recovery_descriptor_digest,
  fence: { ...request.lease_fence, epoch: 2, holder_token: "successor-fence-token-012345" }, };
recoveryActivation.fence_digest = digest(recoveryActivation.fence);
const registration = {
  kind: "brokkr-debian-host-adapter-registration", schema_version: "v1",
  attempt_id: request.attempt_id, binding_digest: request.binding_digest,
  plan_digest: request.plan_digest, constitution_digest: request.constitution_digest,
  release_digest: request.release_digest, execution_request_digest: request.execution_request_digest,
  recovery_descriptor_digest: request.recovery_descriptor_digest, lease_fence_digest: request.lease_fence_digest, apt_source_evidence_digest: request.apt_source_evidence_digest,
};

const state = { entries: [], terminal: null };
const calls = [];
let applied = false;
const run = (argv) => {
  calls.push(argv);
  const key = argv.join(" ");
  if (key === "/usr/bin/timedatectl show --property=NTPSynchronized --value") return { status: 0, stdout: "yes\n" };
  if (key === "/usr/bin/on_ac_power") return { status: 0, stdout: "" };
  if (key === "/usr/bin/flock --nonblock /var/lib/dpkg/lock-frontend /usr/bin/true") return { status: 0, stdout: "" };
  if (key === "/bin/df -Pk /var") return { status: 0, stdout: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 9999999 1 2097152 1% /var\n" };
  if (key === "/usr/bin/getent ahostsv4 deb.debian.org") return { status: 0, stdout: "151.101.2.132 STREAM deb.debian.org\n" };
  if (key === "/usr/bin/uname -r") return { status: 0, stdout: "6.1.0-test\n" };
  if (key === "/usr/bin/dpkg --audit") return { status: 0, stdout: "" };
  if (argv[0] === "/usr/bin/dpkg-query") return { status: 0, stdout: `openssl=${applied ? "3.0.17-1~deb12u2" : "3.0.17-1~deb12u1"}\n` };
  if (argv[0] === "/usr/bin/apt-cache") return { status: 0, stdout: aptPolicy };
  if (argv[0] === "/usr/bin/apt-config") return { status: 0, stdout: aptTrust };
  if (argv[0] === "/usr/bin/apt-get" && argv.includes("--simulate")) return { status: 0, stdout: "Inst openssl [3.0.17-1~deb12u1] (3.0.17-1~deb12u2 Debian:stable-security [amd64])\n" };
  if (argv[0] === "/usr/bin/apt-get") { applied = true; return { status: 0, stdout: "" }; }
  throw new Error(`unexpected fixed command: ${key}`);
};
const env = { uid: 0, now: () => "2026-07-27T12:00:00Z", run, rebootRequired: () => false,
  adapterReleaseDigest: () => request.release_digest,
  activateFence: fence => ({ activated: true, lease_fence_digest: digest(fence) }),
  readRecoveryActivation: () => structuredClone(recoveryActivation),
  applyFenced: ({ fence, lease_fence_digest, apply }) => {
    assert.equal(lease_fence_digest, digest(fence)); return apply();
  },
  readJournal: () => state.entries.length ? structuredClone(state) : null,
  writeJournal: value => { Object.assign(state, structuredClone(value)); },
  writeTerminal: value => { state.terminal = structuredClone(value); },
};
const result = adapter.runHostAdapter({ action: "apply", request, registration, env });
assert.equal(result.outcome, "applied");
assert.deepEqual(state.entries.map(entry => entry.phase), ["preflight", "inventory_before", "apply", "inventory_after", "verify"]);
assert(calls.some(argv => argv[0] === "/usr/bin/apt-get" && argv.includes("--only-upgrade") && argv.includes("openssl=3.0.17-1~deb12u2")));
assert(calls.every(argv => argv[0].startsWith("/")), "adapter invokes only absolute fixed binaries");

for (const [name, mutate, code] of [
  ["arbitrary action", value => { value.action = "shell"; }, /host_action_invalid/],
  ["kernel package", value => { value.execution_request.candidates[0].name = "linux-image-test"; }, /host_candidate_forbidden/],
  ["reboot", value => { value.execution_request.config.no_reboot = false; }, /host_request_scope_invalid/],
  ["wrong release", value => { value.release_digest = "sha256:" + "f".repeat(64); }, /host_registration_mismatch/],
]) {
  const unsafe = structuredClone(request); mutate(unsafe);
  const unsafeRegistration = structuredClone(registration);
  if (name === "kernel package") {
    unsafe.execution_request.candidates[0].id = "linux-image-test@3.0.17-1~deb12u2";
    unsafe.recovery_descriptor.packages = ["linux-image-test"];
    unsafe.execution_request_digest = digest(unsafe.execution_request);
    unsafe.recovery_descriptor_digest = digest(unsafe.recovery_descriptor);
    unsafeRegistration.execution_request_digest = unsafe.execution_request_digest;
    unsafeRegistration.recovery_descriptor_digest = unsafe.recovery_descriptor_digest;
  }
  if (name === "reboot") {
    unsafe.execution_request_digest = digest(unsafe.execution_request);
    unsafeRegistration.execution_request_digest = unsafe.execution_request_digest;
  }
  assert.throws(() => adapter.runHostAdapter({ action: "apply", request: unsafe, registration: unsafeRegistration, env: { ...env, readJournal: () => null } }), code, name);
}
assert.throws(() => adapter.runHostAdapter({ action: "apply", request, registration, env: { ...env, uid: 1000, readJournal: () => null } }), /host_root_required/);

const blocked = adapter.runHostAdapter({ action: "apply", request, registration, env: {
  ...env, readJournal: () => null,
  run: argv => argv[0] === "/usr/bin/flock" ? { status: 1, stdout: "" } : run(argv),
}});
assert.equal(blocked.outcome, "terminally-blocked");
assert.equal(blocked.reason, "host_package_lock_busy");

for (const [name, simulation] of [
  ["removal", "Inst openssl [3.0.17-1~deb12u1] (3.0.17-1~deb12u2 Debian:stable-security [amd64])\nRemv unrelated [1]\n"],
  ["dependency", "Inst openssl [3.0.17-1~deb12u1] (3.0.17-1~deb12u2 Debian:stable-security [amd64])\nInst unexpected (1 Debian:stable [amd64])\n"],
  ["wrong-version", "Inst openssl [3.0.17-1~deb12u1] (3.0.17-1~deb12u9 Debian:stable-security [amd64])\n"],
]) {
  applied = false;
  const widened = adapter.runHostAdapter({ action: "apply", request, registration, env: { ...env, readJournal: () => null,
    run: argv => argv[0] === "/usr/bin/apt-get" && argv.includes("--simulate") ? { status: 0, stdout: simulation } : run(argv),
  }});
  assert.equal(widened.outcome, "terminally-blocked", `${name} simulation must not apply`);
  assert.equal(widened.reason, "host_exact_upgrade_widened", `${name} is terminal/recovery-only`);
}
applied = false;
const changedSource = adapter.runHostAdapter({ action: "apply", request, registration, env: { ...env, readJournal: () => null,
  run: argv => argv[0] === "/usr/bin/apt-cache" ? { status: 0, stdout: aptPolicy.replace("deb.debian.org/debian-security", "mirror.example.invalid/debian") } : run(argv),
}});
assert.equal(changedSource.outcome, "terminally-blocked");
assert.equal(changedSource.reason, "host_apt_source_changed");
applied = false;
const changedTrust = adapter.runHostAdapter({ action: "apply", request, registration, env: { ...env, readJournal: () => null,
  run: argv => argv[0] === "/usr/bin/apt-config" ? { status: 0, stdout: "APT::Get::AllowInsecureRepositories true\n" } : run(argv),
}});
assert.equal(changedTrust.outcome, "terminally-blocked");
assert.equal(changedTrust.reason, "host_apt_trust_changed");

const recoveryEntry = ({ phase, previous_digest, detail }) => {
  const base = { phase, at: "2026-07-27T12:00:00Z", binding_digest: request.binding_digest,
    previous_digest, payload_digest: digest(detail) };
  return { ...base, digest: digest(base) };
};
const recoveryState = { entries: [
  recoveryEntry({ phase: "preflight", previous_digest: null, detail: {} }),
  recoveryEntry({ phase: "inventory_before", previous_digest: null, detail: {} }),
], terminal: null };
recoveryState.entries[1].previous_digest = recoveryState.entries[0].digest;
recoveryState.entries[1].digest = digest({ phase: recoveryState.entries[1].phase, at: recoveryState.entries[1].at,
  binding_digest: recoveryState.entries[1].binding_digest, previous_digest: recoveryState.entries[1].previous_digest,
  payload_digest: recoveryState.entries[1].payload_digest });
recoveryState.entries.push(recoveryEntry({ phase: "apply", previous_digest: recoveryState.entries[1].digest, detail: {} }));
const recoveryTemplate = structuredClone(recoveryState);
const recovered = adapter.runHostAdapter({ action: "recover", request, registration, env: {
  ...env, readJournal: () => structuredClone(recoveryState),
  writeJournal: value => Object.assign(recoveryState, structuredClone(value)),
  run: argv => {
    if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") return { status: 0, stdout: "" };
    if (argv[0] === "/usr/bin/apt-mark" || argv[0] === "/usr/bin/systemctl") return { status: 0, stdout: "" };
    if (argv[0] === "/usr/bin/dpkg-query") return { status: 0, stdout: "openssl=3.0.17-1~deb12u2\n" };
    return run(argv);
  },
}});
if (recovered.outcome !== "disarmed") console.error(recovered);
assert.equal(recovered.outcome, "disarmed");
assert(recoveryState.entries.some(entry => entry.phase === "quarantine"));
assert(calls.every(argv => argv[0] !== "/bin/sh"));

const staleRecoveryState = structuredClone(recoveryTemplate);
const stale = adapter.runHostAdapter({ action: "recover", request, registration, env: {
  ...env, readJournal: () => structuredClone(staleRecoveryState), writeJournal: value => Object.assign(staleRecoveryState, structuredClone(value)),
  activateFence: fence => fence.epoch <= 2 ? { activated: false, lease_fence_digest: digest(fence) } : { activated: true, lease_fence_digest: digest(fence) },
}});
assert.equal(stale.outcome, "terminally-blocked", "an old recovery activation cannot effect after successor takeover");
assert.equal(stale.reason, "host_revalidation_activation_failed");
for (const [field, value] of [["target_scope_digest", "sha256:" + "f".repeat(64)], ["mutation_id", "other-mutation"], ["domain", "other-domain"]]) {
  const mismatched = structuredClone(recoveryActivation); mismatched.fence[field] = value; mismatched.fence_digest = digest(mismatched.fence);
  const local = structuredClone(recoveryTemplate);
  const result = adapter.runHostAdapter({ action: "recover", request, registration, env: {
    ...env, readJournal: () => structuredClone(local), writeJournal: value => Object.assign(local, structuredClone(value)), readRecoveryActivation: () => mismatched,
  }});
  assert.equal(result.outcome, "terminally-blocked", `${field} successor mismatch terminalizes`);
  assert.equal(result.reason, "host_revalidation_fence_invalid");
}
const deadlineState = structuredClone(recoveryTemplate);
const deadline = adapter.runHostAdapter({ action: "recover", request, registration, env: {
  ...env, now: () => "2026-07-27T12:05:00Z", readJournal: () => structuredClone(deadlineState), writeJournal: value => Object.assign(deadlineState, structuredClone(value)),
}});
assert.equal(deadline.outcome, "terminally-blocked");
assert.equal(deadline.reason, "host_recovery_budget_exhausted");
console.log("debian host adapter: root-only exact allowlist, preflight, forward recovery and disarm OK");
NODE
env ROOT="$ROOT" node "$TMP/test.mjs"
UNIT="$ROOT/systemd/brokkr-debian-maintenance-recovery@.service"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$UNIT"
else
  rg -q '^User=root$' "$UNIT"
  rg -q '^NoNewPrivileges=yes$' "$UNIT"
  rg -q '^ExecStart=/usr/local/lib/brokkr/debian-maintenance-host-adapter --action recover --attempt %i$' "$UNIT"
fi
