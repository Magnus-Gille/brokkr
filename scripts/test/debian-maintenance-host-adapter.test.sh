#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
HOLDER_PID=""
cleanup() {
  if [[ -n "$HOLDER_PID" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
cat >"$TMP/test.mjs" <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const productionAdapter = await import(
  `${process.env.ROOT}/scripts/lib/fixed-debian-maintenance-host-operation.mjs`
);
const canonicalJson = value => value === null || typeof value !== "object" ? JSON.stringify(value) :
  Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` :
    `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
const adapter = {
  ...productionAdapter,
  canonicalJson,
  runHostAdapter: ({ env, ...input }) => {
    globalThis.__BROKKR_TEST_HOST_ADAPTER_ENV__ = env;
    return productionAdapter.runFixedDebianMaintenanceHostOperation(input);
  },
};
assert.deepEqual(
  Object.keys(productionAdapter),
  ["runFixedDebianMaintenanceHostOperation"],
  "the production host boundary exports only one closed high-level operation",
);
assert.match(
  productionAdapter.runFixedDebianMaintenanceHostOperation({
    action: "test-fixed-now", request: {}, registration: {},
  }),
  /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
  "the production clock used by strict journal and fence timestamps is canonical UTC",
);
const { createBoundedRecoveryDispatcher } = await import(
  `${process.env.ROOT}/scripts/lib/bounded-recovery-dispatch.mjs`
);
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
  readTerminal: () => state.terminal ? structuredClone(state.terminal) : null,
  writeJournal: value => { Object.assign(state, structuredClone(value)); },
  writeTerminal: value => { state.terminal = structuredClone(value); },
};
const isolatedEnvironment = overrides => {
  const local = { entries: [], terminal: null };
  return {
    state: local,
    env: {
      ...env,
      readJournal: () =>
        local.entries.length || local.terminal ? structuredClone(local) : null,
      readTerminal: () =>
        local.terminal ? structuredClone(local.terminal) : null,
      writeJournal: value => { Object.assign(local, structuredClone(value)); },
      writeTerminal: value => { local.terminal = structuredClone(value); },
      ...overrides,
    },
  };
};
const result = adapter.runHostAdapter({ action: "apply", request, registration, env });
assert.equal(result.outcome, "applied");
assert.deepEqual(state.entries.map(entry => entry.phase), ["preflight", "inventory_before", "apply", "inventory_after", "verify"]);
assert(calls.some(argv => argv[0] === "/usr/bin/apt-get" && argv.includes("--only-upgrade") && argv.includes("openssl=3.0.17-1~deb12u2")));
assert(calls.every(argv => argv[0].startsWith("/")), "adapter invokes only absolute fixed binaries");
let injectedCallbackCalled = false;
const injectedResult = productionAdapter.runFixedDebianMaintenanceHostOperation({
  action: "apply", request, registration,
  env: {
    run: () => { injectedCallbackCalled = true; throw Error("public callback reached"); },
    activateFence: () => { injectedCallbackCalled = true; throw Error("public callback reached"); },
    applyFenced: () => { injectedCallbackCalled = true; throw Error("public callback reached"); },
  },
});
assert.equal(injectedCallbackCalled, false, "public imports cannot inject host effects");
assert.equal(injectedResult.outcome, "applied",
  "a completed apply is an idempotent readback without another effect");
assert.equal(state.terminal, null,
  "an idempotent applied readback does not terminalize the successful attempt");

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
for (const packageName of [
  "intel-microcode", "amd64-microcode", "rpi-eeprom", "raspi-firmware",
  "linux-image-amd64", "linux-headers-amd64", "linux-perf",
  "linux-support", "firmware-linux-free",
  "grub-efi-amd64", "shim-signed", "u-boot-tools", "initramfs-tools",
  "syslinux", "syslinux-common", "extlinux", "efibootmgr",
  "lilo", "elilo", "refind", "limine", "systemd-ukify", "ukify",
  "kexec-tools", "mokutil",
]) {
  const unsafe = structuredClone(request);
  unsafe.execution_request.candidates[0].name = packageName;
  unsafe.execution_request.candidates[0].id =
    `${packageName}@${candidate.candidate_version}`;
  unsafe.recovery_descriptor.packages = [packageName];
  unsafe.execution_request_digest = digest(unsafe.execution_request);
  unsafe.recovery_descriptor_digest = digest(unsafe.recovery_descriptor);
  const unsafeRegistration = {
    ...structuredClone(registration),
    execution_request_digest: unsafe.execution_request_digest,
    recovery_descriptor_digest: unsafe.recovery_descriptor_digest,
  };
  assert.throws(
    () => adapter.runHostAdapter({
      action: "apply", request: unsafe, registration: unsafeRegistration,
      env: { ...env, readJournal: () => null },
    }),
    /host_candidate_forbidden/,
    `${packageName} is a protected kernel, firmware, or boot-chain package`,
  );
}
assert.throws(() => adapter.runHostAdapter({ action: "apply", request, registration, env: { ...env, uid: 1000, readJournal: () => null } }), /host_root_required/);

const lockScenario = isolatedEnvironment({
  run: argv => argv[0] === "/usr/bin/flock" ? { status: 1, stdout: "" } : run(argv),
});
const blocked = adapter.runHostAdapter({
  action: "apply", request, registration, env: lockScenario.env,
});
assert.equal(blocked.outcome, "terminally-blocked");
assert.equal(blocked.reason, "host_package_lock_busy");
assert.equal(
  lockScenario.state.entries.some(entry => entry.phase === "apply"),
  false,
);

const diskScenario = isolatedEnvironment({
  run: argv => argv[0] === "/bin/df" ?
    {
      status: 0,
      stdout: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 9999999 9999998 1 100% /var\n",
    } : run(argv),
});
const diskFailure = adapter.runHostAdapter({
  action: "apply", request, registration, env: diskScenario.env,
});
assert.equal(diskFailure.outcome, "terminally-blocked");
assert.equal(diskFailure.reason, "host_disk_exhausted");
assert.equal(diskScenario.state.terminal.state, "terminally-blocked");
assert.equal(
  diskScenario.state.entries.some(entry => entry.phase === "apply"),
  false,
);

const networkScenario = isolatedEnvironment({
  run: argv => argv[0] === "/usr/bin/getent" ?
    { status: 2, stdout: "" } : run(argv),
});
const networkFailure = adapter.runHostAdapter({
  action: "apply", request, registration, env: networkScenario.env,
});
assert.equal(networkFailure.outcome, "terminally-blocked");
assert.equal(networkFailure.reason, "host_network_unreachable");
assert.equal(networkScenario.state.terminal.state, "terminally-blocked");
assert.equal(
  networkScenario.state.entries.some(entry => entry.phase === "apply"),
  false,
);

applied = false;
let interruptedAptEffects = 0;
const interruptedScenario = isolatedEnvironment({
  run: argv => {
    if (argv[0] === "/usr/bin/apt-get" && !argv.includes("--simulate")) {
      interruptedAptEffects += 1;
      applied = true;
      return { status: 1, stdout: "" };
    }
    return run(argv);
  },
});
const interruptedApply = adapter.runHostAdapter({
  action: "apply", request, registration, env: interruptedScenario.env,
});
assert.equal(interruptedApply.outcome, "unknown");
assert.equal(interruptedApply.reason, "host_apply_failed");
const interruptedRecovery = adapter.runHostAdapter({
  action: "recover",
  request,
  registration,
  env: {
    ...interruptedScenario.env,
    run: argv => {
      if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") {
        return { status: 0, stdout: "" };
      }
      if (argv[0] === "/usr/bin/apt-mark" ||
          (argv[0] === "/usr/bin/systemctl" &&
            argv[1] === "try-restart")) {
        return { status: 0, stdout: "" };
      }
      return run(argv);
    },
  },
});
assert.equal(interruptedRecovery.outcome, "disarmed");
assert.equal(interruptedScenario.state.terminal.state, "disarmed");
assert.equal(interruptedAptEffects, 1,
  "recovery repairs and disarms without applying a new apt plan");

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
for (const origin of [
  "https://attacker-debian.org/debian-security",
  "https://debian.org.evil.example/path/debian.org/debian",
  "https://deb.debian.org.evil.example/debian-security",
  "https://user@deb.debian.org/debian-security",
  "https://deb.debian.org:8443/debian-security",
  "https://deb.debian.org/debian-security/extra",
]) {
  applied = false;
  const policy = aptPolicy.replace(
    "http://deb.debian.org/debian-security", origin,
  );
  const unsafe = structuredClone(request);
  unsafe.apt_source_evidence.candidates[0].policy_output_digest =
    digest(policy);
  unsafe.apt_source_evidence_digest = digest(unsafe.apt_source_evidence);
  const unsafeRegistration = {
    ...structuredClone(registration),
    apt_source_evidence_digest: unsafe.apt_source_evidence_digest,
  };
  const result = adapter.runHostAdapter({
    action: "apply", request: unsafe, registration: unsafeRegistration,
    env: {
      ...env, readJournal: () => null,
      run: argv => argv[0] === "/usr/bin/apt-cache" ?
        { status: 0, stdout: policy } : run(argv),
    },
  });
  assert.equal(
    result.outcome, "terminally-blocked",
    `${origin} must not satisfy the exact Debian repository boundary`,
  );
  assert.equal(result.reason, "host_apt_source_changed");
  assert.equal(applied, false, "a rejected repository cannot reach apt effect");
}
{
  applied = false;
  const policy = aptPolicy.replace(
    "bookworm-security/main", "bookworm-security/non-free-firmware",
  );
  const unsafe = structuredClone(request);
  unsafe.apt_source_evidence.candidates[0].policy_output_digest =
    digest(policy);
  unsafe.apt_source_evidence_digest = digest(unsafe.apt_source_evidence);
  const unsafeRegistration = {
    ...structuredClone(registration),
    apt_source_evidence_digest: unsafe.apt_source_evidence_digest,
  };
  const result = adapter.runHostAdapter({
    action: "apply", request: unsafe, registration: unsafeRegistration,
    env: {
      ...env, readJournal: () => null,
      run: argv => argv[0] === "/usr/bin/apt-cache" ?
        { status: 0, stdout: policy } : run(argv),
    },
  });
  assert.equal(result.outcome, "terminally-blocked");
  assert.equal(result.reason, "host_apt_source_changed");
  assert.equal(
    applied, false,
    "only Debian main is positively allowed; firmware components cannot act",
  );
}
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
assert.equal(recoveryState.terminal.activation_digest, digest(recoveryActivation));
assert.equal(recoveryState.terminal.revalidation_fence_digest, recoveryActivation.fence_digest);
assert(calls.every(argv => argv[0] !== "/bin/sh"));

for (const crashPhase of ["recover", "quarantine", "disarm"]) {
  const crashState = structuredClone(recoveryState);
  const phaseIndex = crashState.entries.findIndex(
    entry => entry.phase === crashPhase,
  );
  crashState.entries = crashState.entries.slice(0, phaseIndex + 1);
  crashState.terminal = null;
  let recoveryEffects = 0;
  const resumed = adapter.runHostAdapter({
    action: "recover", request, registration, env: {
      ...env,
      readJournal: () => structuredClone(crashState),
      readTerminal: () => null,
      writeJournal: value => Object.assign(
        crashState, structuredClone(value),
      ),
      writeTerminal: value => {
        crashState.terminal = structuredClone(value);
      },
      run: argv => {
        if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") {
          recoveryEffects += 1;
          return { status: 0, stdout: "" };
        }
        if (argv[0] === "/usr/bin/apt-mark" ||
            (argv[0] === "/usr/bin/systemctl" &&
              argv[1] === "try-restart")) {
          recoveryEffects += 1;
          return { status: 0, stdout: "" };
        }
        if (argv[0] === "/usr/bin/dpkg-query") {
          return {
            status: 0, stdout: "openssl=3.0.17-1~deb12u2\n",
          };
        }
        return run(argv);
      },
    },
  });
  assert.equal(resumed.outcome, "disarmed",
    `${crashPhase} journal crash resumes to disarm`);
  assert.equal(
    crashState.entries.filter(entry => entry.phase === "recover").length,
    1,
    `${crashPhase} replay never duplicates the recover phase`,
  );
  assert.equal(
    crashState.entries.filter(entry => entry.phase === "quarantine").length,
    1,
    `${crashPhase} replay never duplicates quarantine`,
  );
  assert.equal(
    crashState.entries.filter(entry => entry.phase === "disarm").length,
    1,
    `${crashPhase} replay never duplicates disarm`,
  );
  assert.equal(
    recoveryEffects > 0, crashPhase === "recover",
    "only an interrupted recovery effect is safely replayed",
  );
}

const missingTerminalState = structuredClone(recoveryState);
let repairedTerminal = null;
const repaired = adapter.runHostAdapter({
  action: "recover", request, registration, env: {
    ...env,
    readJournal: () => structuredClone(missingTerminalState),
    readTerminal: () => null,
    writeJournal: value => Object.assign(
      missingTerminalState, structuredClone(value),
    ),
    writeTerminal: value => { repairedTerminal = structuredClone(value); },
    readRecoveryActivation: () => structuredClone(recoveryActivation),
    run: argv => argv[0] === "/usr/bin/dpkg-query" ?
      { status: 0, stdout: "openssl=3.0.17-1~deb12u2\n" } : run(argv),
  },
});
assert.equal(repaired.outcome, "disarmed");
assert.deepEqual(
  repairedTerminal, missingTerminalState.terminal,
  "replay repairs a terminal sidecar lost after the journal commit",
);

const advancedActivation = structuredClone(recoveryActivation);
advancedActivation.fence.epoch += 1;
advancedActivation.fence.holder_token = "advanced-fence-token-012345";
advancedActivation.fence_digest = digest(advancedActivation.fence);
const advancedState = structuredClone(recoveryState);
const rebound = adapter.runHostAdapter({
  action: "recover", request, registration, env: {
    ...env,
    readJournal: () => structuredClone(advancedState),
    readTerminal: () => structuredClone(advancedState.terminal),
    writeJournal: value => Object.assign(
      advancedState, structuredClone(value),
    ),
    writeTerminal: value => {
      advancedState.terminal = structuredClone(value);
    },
    readRecoveryActivation: () => structuredClone(advancedActivation),
    activateFence: fence => ({
      activated: true, lease_fence_digest: digest(fence),
    }),
    run: argv => argv[0] === "/usr/bin/dpkg-query" ?
      { status: 0, stdout: "openssl=3.0.17-1~deb12u2\n" } : run(argv),
  },
});
assert.equal(rebound.outcome, "disarmed");
assert.equal(
  advancedState.terminal.activation_digest, digest(advancedActivation),
  "a strictly advancing authorized successor rebinds the durable receipt",
);

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
let deadlineNewPlanMutations = 0;
const deadlineInvocationAt = "2026-07-27T12:05:00Z";
const deadline = adapter.runHostAdapter({ action: "recover", request, registration, env: {
  ...env, now: () => deadlineInvocationAt,
  readJournal: () => structuredClone(deadlineState),
  writeJournal: value => Object.assign(deadlineState, structuredClone(value)),
  run: argv => {
    if (argv[0] === "/usr/bin/apt-get" && !argv.includes("--simulate")) {
      deadlineNewPlanMutations += 1;
    }
    return run(argv);
  },
}});
assert.equal(deadline.outcome, "terminally-blocked");
assert.equal(deadline.reason, "host_recovery_budget_exhausted");
assert.equal(deadlineNewPlanMutations, 0);
assert.equal(deadlineState.terminal.activation_digest, digest(recoveryActivation));
assert.equal(
  deadlineState.terminal.revalidation_fence_digest,
  recoveryActivation.fence_digest,
);
let postconditionAptEffects = 0;
const postconditionScenario = isolatedEnvironment({
  readJournal: () => structuredClone(recoveryTemplate),
  run: argv => {
    if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") {
      return { status: 0, stdout: "" };
    }
    if (argv[0] === "/usr/bin/apt-mark" ||
        (argv[0] === "/usr/bin/systemctl" &&
          argv[1] === "try-restart")) {
      return { status: 0, stdout: "" };
    }
    if (argv[0] === "/usr/bin/dpkg-query") {
      return { status: 0, stdout: "openssl=3.0.17-1~deb12u1\n" };
    }
    if (argv[0] === "/usr/bin/apt-get" && !argv.includes("--simulate")) {
      postconditionAptEffects += 1;
    }
    return run(argv);
  },
});
const postconditionFailure = adapter.runHostAdapter({
  action: "recover", request, registration, env: postconditionScenario.env,
});
assert.equal(postconditionFailure.outcome, "terminally-blocked");
assert.equal(postconditionFailure.reason, "host_postconditions_unverifiable");
assert.equal(postconditionAptEffects, 0,
  "forward recovery never adopts or applies a replacement apt plan");
for (const [name, expectedReason, recoveryRun] of [
  [
    "repair", "host_recovery_repair_failed",
    argv => argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure" ?
      { status: 1, stdout: "" } : run(argv),
  ],
  [
    "postcondition", "host_postconditions_unverifiable",
    argv => {
      if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") {
        return { status: 0, stdout: "" };
      }
      if (argv[0] === "/usr/bin/apt-mark" ||
          (argv[0] === "/usr/bin/systemctl" &&
            argv[1] === "try-restart")) {
        return { status: 0, stdout: "" };
      }
      if (argv[0] === "/usr/bin/dpkg-query") {
        return {
          status: 0, stdout: "openssl=3.0.17-1~deb12u1\n",
        };
      }
      return run(argv);
    },
  ],
]) {
  const failureState = structuredClone(recoveryTemplate);
  const failure = adapter.runHostAdapter({
    action: "recover", request, registration, env: {
      ...env,
      readJournal: () => structuredClone(failureState),
      writeJournal: value => Object.assign(
        failureState, structuredClone(value),
      ),
      writeTerminal: value => {
        failureState.terminal = structuredClone(value);
      },
      run: recoveryRun,
    },
  });
  assert.equal(failure.outcome, "terminally-blocked");
  assert.equal(failure.reason, expectedReason);
  assert.equal(
    failureState.terminal.activation_digest, digest(recoveryActivation),
    `${name} terminal binds the exact recovery activation`,
  );
  assert.equal(
    failureState.terminal.revalidation_fence_digest,
    recoveryActivation.fence_digest,
    `${name} terminal binds the exact successor fence`,
  );
}
const successorFailureState = structuredClone(deadlineState);
let successorFailureFenceActivated = false;
const successorFailure = adapter.runHostAdapter({
  action: "recover", request, registration, env: {
    ...env,
    readJournal: () => structuredClone(successorFailureState),
    readTerminal: () => structuredClone(successorFailureState.terminal),
    writeJournal: value => Object.assign(
      successorFailureState, structuredClone(value),
    ),
    writeTerminal: value => {
      successorFailureState.terminal = structuredClone(value);
    },
    readRecoveryActivation: () => structuredClone(advancedActivation),
    activateFence: fence => {
      successorFailureFenceActivated = true;
      return {
        activated: true, lease_fence_digest: digest(fence),
      };
    },
  },
});
assert.equal(successorFailure.outcome, "terminally-blocked");
assert.equal(
  successorFailure.reason, "host_recovery_budget_exhausted",
);
assert.equal(
  successorFailureFenceActivated, true,
  "a successor activates its fence before rebinding a failed terminal",
);
assert.equal(
  successorFailureState.terminal.activation_digest,
  digest(advancedActivation),
);
assert.equal(
  successorFailureState.terminal.revalidation_fence_digest,
  advancedActivation.fence_digest,
);

for (const instant of [
  "2026-02-30T12:00:00Z",
  "2026-07-27T24:00:00Z",
]) {
  const unsafe = structuredClone(request);
  unsafe.lease_fence.activated_at = instant;
  unsafe.lease_fence_digest = digest(unsafe.lease_fence);
  const unsafeRegistration = {
    ...structuredClone(registration),
    lease_fence_digest: unsafe.lease_fence_digest,
  };
  assert.throws(
    () => adapter.runHostAdapter({
      action: "apply", request: unsafe, registration: unsafeRegistration,
      env: { ...env, readJournal: () => null },
    }),
    /host_fence_invalid/,
    `${instant} is not a canonical real UTC instant`,
  );
}
const callerMintedLookalike = {
  persistActivation: () => { throw Error("caller callback must stay unreachable"); },
  runFixedAdapter: () => { throw Error("caller callback must stay unreachable"); },
};
assert.deepEqual(
  Object.keys(await import(`${process.env.ROOT}/scripts/lib/bounded-recovery-dispatch.mjs`)).sort(),
  ["createBoundedRecoveryDispatcher"],
  "the bridge exports no recovery host factory or runner",
);
assert.doesNotThrow(() => createBoundedRecoveryDispatcher({
  recovery: {}, expected: {
    attemptId: request.attempt_id, bindingDigest: request.binding_digest,
    descriptorDigest: request.recovery_descriptor_digest,
    idempotencyKey: "recovery-67", mutationId: request.lease_fence.mutation_id,
    targetScopeDigest: request.lease_fence.target_scope_digest,
  },
  host: callerMintedLookalike,
}), "a caller look-alike is ignored; it cannot mint production recovery authority");
const published = [];
let bridgeActivation = null;
let fixedHostAdapterExecutions = 0;
const bridgeHostState = structuredClone(recoveryTemplate);
const bridge = createBoundedRecoveryDispatcher({
  recovery: {}, expected: {
    attemptId: request.attempt_id, bindingDigest: request.binding_digest,
    descriptorDigest: request.recovery_descriptor_digest,
    idempotencyKey: "recovery-67", mutationId: request.lease_fence.mutation_id,
    targetScopeDigest: request.lease_fence.target_scope_digest,
  },
});
globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__ = {
    persistActivation: activation => {
      published.push(activation); bridgeActivation = structuredClone(activation);
      return { activation_digest: digest(activation), idempotent: published.length > 1 };
    },
    runFixedAdapter: input => {
      fixedHostAdapterExecutions += 1;
      assert.equal(input.action, "recover");
      assert.equal(input.attempt_id, request.attempt_id);
      assert.equal(input.activation_digest, digest(bridgeActivation));
      const result = adapter.runHostAdapter({ action: "recover", request, registration, env: {
        ...env, readRecoveryActivation: () => structuredClone(bridgeActivation),
        readJournal: () => structuredClone(bridgeHostState),
        writeJournal: value => Object.assign(bridgeHostState, structuredClone(value)),
        run: argv => {
          if (argv[0] === "/usr/bin/dpkg" && argv[1] === "--configure") return { status: 0, stdout: "" };
          if (argv[0] === "/usr/bin/apt-mark" || argv[0] === "/usr/bin/systemctl") return { status: 0, stdout: "" };
          if (argv[0] === "/usr/bin/dpkg-query") return { status: 0, stdout: "openssl=3.0.17-1~deb12u2\n" };
          return run(argv);
        },
      }});
      assert.equal(result.outcome, "disarmed", "the fixed host adapter must durably complete recovery");
      return { idempotency_key: input.recovery_request.idempotency_key, effect_lease_fence_digest: request.lease_fence_digest, revalidated_lease_fence_digest: bridgeActivation.fence_digest, revalidated_at: "2026-07-27T12:00:00Z", recovered: true, safe_state_verified: true, quarantine_active: true, reason_code: null };
    },
};
const bridgeRequest = { idempotency_key: "recovery-67", descriptor_digest: request.recovery_descriptor_digest, target_scope_digest: request.lease_fence.target_scope_digest, binding_digest: request.binding_digest, lease_fence: request.lease_fence, lease_fence_digest: request.lease_fence_digest, revalidation_fence: recoveryActivation.fence, revalidation_fence_digest: recoveryActivation.fence_digest };
const bridgeResult = bridge.recover(bridgeRequest);
assert.equal(bridgeResult.recovered, true);
assert.equal(published.length, 1, "the bridge persists one successor activation before dispatch");
assert.equal(fixedHostAdapterExecutions, 1, "recovery success requires fixed host-adapter execution, not a shape-only callback");
assert(bridgeHostState.entries.some(entry => entry.phase === "disarm"), "the host adapter durably disarmed the recovered attempt");
assert.equal(bridgeHostState.terminal.activation_digest, bridgeResult.activation_digest,
  "the durable terminal record binds the dispatcher activation");
assert.equal(bridgeHostState.terminal.revalidation_fence_digest, bridgeRequest.revalidation_fence_digest,
  "the durable terminal record binds the successor fence");
const successfulBridgeRunner =
  globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__.runFixedAdapter;
globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__.runFixedAdapter = input => ({
  idempotency_key: input.recovery_request.idempotency_key,
  effect_lease_fence_digest:
    input.recovery_request.lease_fence_digest,
  revalidated_lease_fence_digest:
    input.recovery_request.revalidation_fence_digest,
  revalidated_at: "2026-07-27T12:00:00Z",
  recovered: false,
  safe_state_verified: false,
  quarantine_active: true,
  reason_code: "host_recovery_repair_failed",
});
const negativeBridgeResult = bridge.recover(bridgeRequest);
assert.equal(negativeBridgeResult.recovered, false);
assert.equal(
  negativeBridgeResult.reason_code, "host_recovery_repair_failed",
);
assert.match(
  negativeBridgeResult.terminal_receipt_digest, /^sha256:[a-f0-9]{64}$/,
  "the bridge authenticates a durable negative host receipt",
);
globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__.runFixedAdapter = input => ({
  idempotency_key: input.recovery_request.idempotency_key,
  effect_lease_fence_digest:
    input.recovery_request.lease_fence_digest,
  revalidated_lease_fence_digest:
    input.recovery_request.revalidation_fence_digest,
  revalidated_at: "2026-02-30T12:00:00Z",
  recovered: false,
  safe_state_verified: false,
  quarantine_active: true,
  reason_code: "host_recovery_repair_failed",
});
assert.throws(
  () => bridge.recover(bridgeRequest),
  /bounded_recovery_dispatch_receipt_invalid/,
  "an impossible terminal receipt instant cannot cross the bridge",
);
globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__.runFixedAdapter =
  successfulBridgeRunner;
for (const [name, mutate] of [
  ["binding", value => { value.binding_digest = "sha256:" + "f".repeat(64); }],
  ["target", value => { value.revalidation_fence.target_scope_digest = "sha256:" + "f".repeat(64); }],
  ["attempt", value => { value.revalidation_fence.attempt_id = "other-attempt"; }],
  ["mutation", value => { value.revalidation_fence.mutation_id = "other-mutation"; }],
  ["holder", value => { value.revalidation_fence.holder_token = value.lease_fence.holder_token; }],
]) {
  const unsafe = structuredClone(bridgeRequest); mutate(unsafe);
  unsafe.lease_fence_digest = digest(unsafe.lease_fence);
  unsafe.revalidation_fence_digest = digest(unsafe.revalidation_fence);
  assert.throws(() => bridge.recover(unsafe), /bounded_recovery_dispatch_(binding|fence)_invalid/, name);
}
for (const instant of [
  "2026-02-30T12:00:00Z",
  "2026-07-27T24:00:00Z",
]) {
  const unsafe = structuredClone(bridgeRequest);
  unsafe.revalidation_fence.activated_at = instant;
  unsafe.revalidation_fence_digest = digest(unsafe.revalidation_fence);
  assert.throws(
    () => bridge.recover(unsafe),
    /bounded_recovery_dispatch_fence_invalid/,
    `${instant} cannot cross the production recovery bridge`,
  );
}

const productionStateRoot = process.env.BROKKR_TEST_STATE_ROOT;
for (const directory of [
  productionStateRoot,
  ...["recovery-authorizations", "recovery-activations", "terminals"]
    .map(name => path.join(productionStateRoot, name)),
]) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
}
const writeProtectedJson = (directory, attempt, value) => {
  const file = path.join(productionStateRoot, directory, `${attempt}.json`);
  fs.writeFileSync(file, `${adapter.canonicalJson(value)}\n`, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
};
const dispatchProduction = (recoveryRequest, activation) =>
  productionAdapter.runFixedDebianMaintenanceHostOperation({
    action: "test-production-dispatch",
    request: recoveryRequest,
    registration: activation,
  });
let productionStarts = 0;
let activeProductionAttempt = request.attempt_id;
let productionTerminalState = "disarmed";
let productionTerminalReason = "forward_recovery_verified";
let productionTerminalAt = "2026-07-27T12:00:00Z";
let productionStartStatus = 0;
globalThis.__BROKKR_TEST_SPAWN_SYNC__ = (binary, argv) => {
  assert.equal(binary, "/usr/bin/systemctl");
  assert.deepEqual(argv, [
    "start",
    `brokkr-debian-maintenance-recovery-${activeProductionAttempt}.service`,
  ]);
  productionStarts += 1;
  const activation = JSON.parse(fs.readFileSync(path.join(
    productionStateRoot, "recovery-activations",
    `${activeProductionAttempt}.json`,
  )));
  writeProtectedJson("terminals", activeProductionAttempt, {
    kind: "brokkr-debian-host-adapter-terminal", schema_version: "v1",
    state: productionTerminalState, reason: productionTerminalReason,
    at: productionTerminalAt, binding_digest: request.binding_digest,
    activation_digest: digest(activation),
    revalidation_fence_digest: activation.fence_digest,
  });
  return {
    status: productionStartStatus, stdout: "", stderr: "",
    error: productionStartStatus === null ?
      Object.assign(new Error("test timeout"), { code: "ETIMEDOUT" }) :
      undefined,
  };
};
const authorizeDispatch = (recoveryRequest, activation) =>
  writeProtectedJson("recovery-authorizations", activation.attempt_id, {
    kind: "brokkr-debian-recovery-authorization", schema_version: "v1",
    attempt_id: activation.attempt_id, activation,
    recovery_request: recoveryRequest,
  });
authorizeDispatch(bridgeRequest, recoveryActivation);
const firstProductionDispatch = dispatchProduction(
  bridgeRequest, recoveryActivation,
);
assert.equal(firstProductionDispatch.recovered, true);
assert.equal(productionStarts, 1);
assert.equal(
  dispatchProduction(bridgeRequest, recoveryActivation).activation_digest,
  firstProductionDispatch.activation_digest,
  "an exact duplicate production dispatch returns its durable receipt",
);
assert.equal(productionStarts, 1,
  "an exact duplicate production dispatch does not restart the unit");

const advancedDispatchRequest = structuredClone(bridgeRequest);
advancedDispatchRequest.revalidation_fence = structuredClone(
  advancedActivation.fence,
);
advancedDispatchRequest.revalidation_fence_digest =
  advancedActivation.fence_digest;
authorizeDispatch(advancedDispatchRequest, advancedActivation);
const advancedProductionDispatch = dispatchProduction(
  advancedDispatchRequest, advancedActivation,
);
assert.equal(advancedProductionDispatch.recovered, true);
assert.equal(productionStarts, 2,
  "a strictly advancing authorized activation resumes through the fixed unit");

const failedDispatch = ({ suffix, reason, status = 1, at =
  "2026-07-27T12:00:00Z" }) => {
  const attemptId = `attempt-${suffix}`;
  const recoveryRequest = structuredClone(bridgeRequest);
  recoveryRequest.idempotency_key = `recovery-${suffix}`;
  recoveryRequest.lease_fence.attempt_id = attemptId;
  recoveryRequest.lease_fence.mutation_id = `mutation-${suffix}`;
  recoveryRequest.lease_fence.holder_token =
    `effect-${suffix}-token-0123456789`;
  recoveryRequest.lease_fence_digest =
    digest(recoveryRequest.lease_fence);
  recoveryRequest.revalidation_fence = {
    ...structuredClone(recoveryRequest.lease_fence),
    epoch: recoveryRequest.lease_fence.epoch + 1,
    holder_token: `recovery-${suffix}-token-0123456789`,
  };
  recoveryRequest.revalidation_fence_digest =
    digest(recoveryRequest.revalidation_fence);
  const activation = {
    ...structuredClone(recoveryActivation),
    attempt_id: attemptId,
    fence: structuredClone(recoveryRequest.revalidation_fence),
    fence_digest: recoveryRequest.revalidation_fence_digest,
  };
  activeProductionAttempt = attemptId;
  productionTerminalState = "terminally-blocked";
  productionTerminalReason = reason;
  productionTerminalAt = at;
  productionStartStatus = status;
  authorizeDispatch(recoveryRequest, activation);
  return {
    activation, recoveryRequest,
    dispatch: () => dispatchProduction(recoveryRequest, activation),
  };
};
for (const failure of [
  {
    suffix: "repair-failure",
    reason: "host_recovery_repair_failed",
  },
  {
    suffix: "budget-failure",
    reason: "host_recovery_budget_exhausted",
  },
  {
    suffix: "postcondition-failure",
    reason: "host_postconditions_unverifiable",
  },
  {
    suffix: "timeout-terminal",
    reason: "host_recovery_hold_failed",
    status: null,
  },
]) {
  const before = productionStarts;
  const failed = failedDispatch(failure);
  const receipt = failed.dispatch();
  assert.equal(receipt.recovered, false, `${failure.suffix} is durable`);
  assert.equal(receipt.safe_state_verified, false);
  assert.equal(receipt.quarantine_active, true);
  assert.equal(receipt.reason_code, failure.reason);
  assert.equal(receipt.activation_digest, digest(failed.activation));
  assert.equal(
    receipt.revalidated_lease_fence_digest,
    failed.recoveryRequest.revalidation_fence_digest,
  );
  assert.equal(productionStarts, before + 1);
  assert.deepEqual(
    failed.dispatch(), receipt,
    `${failure.suffix} replays its authenticated negative receipt`,
  );
  assert.equal(
    productionStarts, before + 1,
    `${failure.suffix} does not restart after durable terminalization`,
  );
}

const invalidTerminal = failedDispatch({
  suffix: "invalid-terminal-time",
  reason: "host_recovery_repair_failed",
  at: "2026-02-30T12:00:00Z",
});
assert.throws(
  invalidTerminal.dispatch,
  /bounded_recovery_fixed_adapter_failed/,
  "a terminal receipt with an impossible instant is unauthenticated",
);

activeProductionAttempt = request.attempt_id;
productionTerminalState = "disarmed";
productionTerminalReason = "forward_recovery_verified";
productionTerminalAt = "2026-07-27T12:00:00Z";
productionStartStatus = 0;
const downgradeActivation = structuredClone(recoveryActivation);
const downgradeRequest = structuredClone(bridgeRequest);
authorizeDispatch(downgradeRequest, downgradeActivation);
const beforeDowngrade = productionStarts;
assert.throws(
  () => dispatchProduction(downgradeRequest, downgradeActivation),
  /bounded_recovery_activation_conflict/,
  "an authorized but stale activation cannot replace a newer activation",
);
assert.equal(productionStarts, beforeDowngrade);
if (process.env.BROKKR_FI_HOST_RECEIPT) {
  const root = process.env.ROOT;
  const elapsed = (terminalRecord, startedAt, budgetSeconds) => {
    assert(terminalRecord && typeof terminalRecord.at === "string");
    const observed = Math.max(
      0,
      (Date.parse(terminalRecord.at) - Date.parse(startedAt)) / 1000,
    );
    assert.equal(Number.isSafeInteger(observed), true);
    assert.equal(
      observed <= budgetSeconds,
      true,
      `${terminalRecord.at} exceeds ${startedAt} + ${budgetSeconds}s`,
    );
    return observed;
  };
  const noApply = scenario =>
    Number(scenario.entries.some(entry => entry.phase === "apply"));
  const fileDigest = relative =>
    `sha256:${crypto.createHash("sha256")
      .update(fs.readFileSync(`${root}/${relative}`)).digest("hex")}`;
  const scenarios = [
    {
      id: "interrupted-package-state", outcome: interruptedRecovery.outcome,
      terminal: interruptedScenario.state.terminal,
      startedAt: recoveryActivation.fence.activated_at,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: interruptedAptEffects - 1,
    },
    {
      id: "lock-contention", outcome: blocked.outcome,
      terminal: lockScenario.state.terminal,
      startedAt: request.lease_fence.activated_at,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: noApply(lockScenario.state),
    },
    {
      id: "network-loss", outcome: networkFailure.outcome,
      terminal: networkScenario.state.terminal,
      startedAt: request.lease_fence.activated_at,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: noApply(networkScenario.state),
    },
    {
      id: "disk-headroom-failure", outcome: diskFailure.outcome,
      terminal: diskScenario.state.terminal,
      startedAt: request.lease_fence.activated_at,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: noApply(diskScenario.state),
    },
    {
      id: "postcondition-failure", outcome: postconditionFailure.outcome,
      terminal: postconditionScenario.state.terminal,
      startedAt: recoveryActivation.fence.activated_at,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: postconditionAptEffects,
    },
    {
      id: "terminal-exhaustion", outcome: deadline.outcome,
      terminal: deadlineState.terminal,
      startedAt: deadlineInvocationAt,
      budgetSeconds: request.recovery_descriptor.budget_seconds,
      newPlanMutations: deadlineNewPlanMutations,
    },
  ].map(value => {
    assert.equal(value.newPlanMutations, 0, value.id);
    assert.equal(
      ["disarmed", "terminally-blocked"].includes(value.outcome),
      true,
      value.id,
    );
    return {
      id: value.id,
      outcome: value.outcome,
      path_id: "w2a-w2b-production-v1",
      passed: true,
      quarantine_active: true,
      new_plan_mutations: value.newPlanMutations,
      budget_seconds: value.budgetSeconds,
      observed_elapsed_seconds: elapsed(
        value.terminal, value.startedAt, value.budgetSeconds,
      ),
      terminal_at: value.terminal.at,
    };
  });
  fs.writeFileSync(
    process.env.BROKKR_FI_HOST_RECEIPT,
    `${JSON.stringify({
      kind: "brokkr-supervised-debian-fi-fragment",
      schema_version: "v1",
      path_id: "w2a-w2b-production-v1",
      production_path: {
        host_operation: fileDigest(
          "scripts/lib/fixed-debian-maintenance-host-operation.mjs",
        ),
        recovery_unit: fileDigest(
          "systemd/brokkr-debian-maintenance-recovery.service.in",
        ),
      },
      scenarios,
    })}\n`,
    { mode: 0o600 },
  );
}
console.log("debian host adapter: root-only exact allowlist, preflight, forward recovery and disarm OK");
NODE
env ROOT="$ROOT" BROKKR_TEST_STATE_ROOT="$TMP/production-state" \
  node --experimental-loader \
  "$ROOT/scripts/test/fixtures/fixed-recovery-host/loader.mjs" "$TMP/test.mjs"
if [[ -d /proc/self/fd && -x /usr/bin/flock ]]; then
  LOCK_ROOT="$TMP/lock-state"
  mkdir -p "$LOCK_ROOT/fences"
  chmod 0700 "$LOCK_ROOT" "$LOCK_ROOT/fences"
  LOCK_FILE="$LOCK_ROOT/fences/attempt-67.effect-lock"
  : >"$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
  cat >"$TMP/lock-holder.mjs" <<'NODE'
import fs from "node:fs";
fs.writeFileSync(process.env.READY, "ready\n");
setTimeout(() => {}, 30_000);
NODE
  cat >"$TMP/lock-proof.mjs" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
const operation = await import(
  `${process.env.ROOT}/scripts/lib/fixed-debian-maintenance-host-operation.mjs`
);
const invoke = () => operation.runFixedDebianMaintenanceHostOperation({
  action: "test-lock-proof",
  request: { attempt_id: "attempt-67" },
  registration: {},
});
if (process.env.EXPECT_UNLOCKED_REJECTION === "1") {
  const fd = fs.openSync(process.env.LOCK_FILE, "r");
  try {
    assert.throws(invoke, /host_effect_lock_unverified/,
      "an unlocked same-inode fd cannot borrow another process's flock");
  } finally {
    fs.closeSync(fd);
  }
} else {
  assert.doesNotThrow(invoke,
    "flock --no-fork preserves the current lock-holder PID and descriptor");
}
NODE
  READY="$TMP/lock-ready"
  /usr/bin/flock --no-fork "$LOCK_FILE" \
    /usr/bin/env READY="$READY" node "$TMP/lock-holder.mjs" &
  HOLDER_PID=$!
  for _ in {1..100}; do
    [[ -f "$READY" ]] && break
    sleep 0.01
  done
  [[ -f "$READY" ]]
  env ROOT="$ROOT" LOCK_FILE="$LOCK_FILE" \
    BROKKR_TEST_STATE_ROOT="$LOCK_ROOT" EXPECT_UNLOCKED_REJECTION=1 \
    node --experimental-loader "$ROOT/scripts/test/fixtures/fixed-recovery-host/loader.mjs" \
    "$TMP/lock-proof.mjs"
  kill "$HOLDER_PID"
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=""
  /usr/bin/flock --no-fork "$LOCK_FILE" /usr/bin/env \
    ROOT="$ROOT" LOCK_FILE="$LOCK_FILE" BROKKR_TEST_STATE_ROOT="$LOCK_ROOT" \
    node --experimental-loader "$ROOT/scripts/test/fixtures/fixed-recovery-host/loader.mjs" \
    "$TMP/lock-proof.mjs"
fi
if env BROKKR_EFFECT_LOCKED=1 node "$ROOT/scripts/debian-maintenance-host-adapter.mjs" \
  --effect-locked --action recover --attempt attempt-67 >"$TMP/direct-bypass.out" 2>&1; then
  echo "direct --effect-locked invocation unexpectedly succeeded" >&2
  exit 1
fi
grep -Eq 'host_cli_arguments_invalid' "$TMP/direct-bypass.out"
! grep -Eq -- '--effect-locked' "$ROOT/scripts/debian-maintenance-host-adapter.mjs"
env ROOT="$ROOT" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import crypto from "node:crypto";
const fixedHost = await import(
  `${process.env.ROOT}/scripts/lib/fixed-debian-maintenance-host-operation.mjs`
);
assert.deepEqual(
  Object.keys(fixedHost),
  ["runFixedDebianMaintenanceHostOperation"],
);
assert.deepEqual(
  Object.keys(await import(
    `${process.env.ROOT}/scripts/debian-maintenance-host-adapter.mjs`
  )),
  [],
  "the CLI exports no production helper",
);
assert.throws(() => fixedHost.runFixedDebianMaintenanceHostOperation({
  action: "recover",
  request: { attempt_id: "../../tmp/traversal" },
  registration: {},
}), /host_action_invalid/,
"a direct production import rejects traversal before touching fixed state");
let callbackReached = false;
assert.throws(() => fixedHost.runFixedDebianMaintenanceHostOperation({
  action: "apply", request: {}, registration: {},
  run: () => { callbackReached = true; },
}), /host_operation_contract_invalid/);
assert.equal(callbackReached, false, "the closed operation rejects callbacks");
const canonical = value => value === null || typeof value !== "object" ?
  JSON.stringify(value) : Array.isArray(value) ?
    `[${value.map(canonical).join(",")}]` :
    `{${Object.keys(value).sort().map(key =>
      `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
const digest = value => `sha256:${crypto.createHash("sha256")
  .update(canonical(value)).digest("hex")}`;
const fence = {
  kind: "brokkr-effect-lease-fence", schema_version: "v1",
  domain: "no-reboot-security-bugfix-maintenance",
  target_scope_digest: "sha256:" + "1".repeat(64),
  attempt_id: "../../tmp/traversal", mutation_id: "mutation-67",
  binding_digest: "sha256:" + "2".repeat(64), epoch: 1,
  holder_token: "original-token-0123456789",
  activated_at: "2026-07-27T12:00:00Z",
  expires_at: "2026-07-27T12:05:00Z",
};
const successor = {
  ...fence, epoch: 2, holder_token: "successor-token-0123456789",
};
const dispatch = {
  idempotency_key: "recovery-67",
  descriptor_digest: "sha256:" + "3".repeat(64),
  target_scope_digest: fence.target_scope_digest,
  binding_digest: fence.binding_digest,
  lease_fence: fence, lease_fence_digest: digest(fence),
  revalidation_fence: successor,
  revalidation_fence_digest: digest(successor),
};
const activation = {
  kind: "brokkr-debian-recovery-activation", schema_version: "v1",
  attempt_id: fence.attempt_id, binding_digest: fence.binding_digest,
  recovery_descriptor_digest: dispatch.descriptor_digest,
  fence: successor, fence_digest: dispatch.revalidation_fence_digest,
};
assert.throws(() => fixedHost.runFixedDebianMaintenanceHostOperation({
  action: "dispatch-recovery", request: dispatch, registration: activation,
}), /bounded_recovery_dispatch_fence_invalid/,
"a fully shaped dispatch rejects a non-canonical attempt before fixed paths or systemd");
NODE
grep -Eq '/proc/self/fdinfo/' "$ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs"
grep -Fq 'fields[5] === String(process.pid)' "$ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs"
grep -Eq '"--nonblock", "--no-fork"' "$ROOT/scripts/debian-maintenance-host-adapter.mjs"
! grep -Eq 'fixedRun|fixedWriteJournal|fixedWriteTerminal|fixedActivateFence' \
  "$ROOT/scripts/debian-maintenance-host-adapter.mjs" \
  "$ROOT/scripts/lib/bounded-recovery-dispatch.mjs"
UNIT="$ROOT/systemd/brokkr-debian-maintenance-recovery.service.in"
grep -Eq '^ExecStart=/usr/local/lib/brokkr/releases/@RELEASE_SHA@/scripts/debian-maintenance-host-adapter.mjs --action recover --attempt @CANARY_ID@$' "$UNIT"
if command -v systemd-analyze >/dev/null 2>&1; then
  UNIT_ROOT="$TMP/systemd-root"
  RELEASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  RENDERED_UNIT="brokkr-debian-maintenance-recovery-attempt-67.service"
  mkdir -p "$UNIT_ROOT/etc/systemd/system" \
    "$UNIT_ROOT/usr/local/lib/brokkr/releases/$RELEASE_SHA/scripts"
  sed \
    -e "s/@RELEASE_SHA@/$RELEASE_SHA/g" \
    -e 's/@CANARY_ID@/attempt-67/g' \
    "$UNIT" >"$UNIT_ROOT/etc/systemd/system/$RENDERED_UNIT"
  for target in \
    basic.target local-fs.target network-online.target shutdown.target \
    sysinit.target; do
    printf '[Unit]\nDescription=Hermetic test %s\nDefaultDependencies=no\n' \
      "$target" >"$UNIT_ROOT/etc/systemd/system/$target"
  done
  printf '#!/bin/sh\nexit 0\n' \
    >"$UNIT_ROOT/usr/local/lib/brokkr/releases/$RELEASE_SHA/scripts/debian-maintenance-host-adapter.mjs"
  chmod 0755 \
    "$UNIT_ROOT/usr/local/lib/brokkr/releases/$RELEASE_SHA/scripts/debian-maintenance-host-adapter.mjs"
  systemd-analyze verify --root="$UNIT_ROOT" "$RENDERED_UNIT"
else
  grep -Eq '^User=root$' "$UNIT"
  grep -Eq '^NoNewPrivileges=yes$' "$UNIT"
fi
