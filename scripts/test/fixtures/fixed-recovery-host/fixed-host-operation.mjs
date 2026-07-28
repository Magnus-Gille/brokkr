// Loaded only by loader.mjs in hermetic child-process tests. It replaces the
// one public high-level operation, never a dependency, writer, command runner,
// or production core export.
import crypto from "node:crypto";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const canonicalJson = value => value === null || typeof value !== "object" ? JSON.stringify(value) : Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` : `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;

const productionFile = fileURLToPath(new URL(
  "../../../lib/fixed-debian-maintenance-host-operation.mjs", import.meta.url,
));
const testSource = fs.readFileSync(productionFile, "utf8")
  .replace(
    'const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";',
    'const STATE_ROOT = process.env.BROKKR_TEST_STATE_ROOT ?? "/var/lib/brokkr/debian-maintenance";',
  )
  .replace(
    "const OPERATION_FILE = fileURLToPath(import.meta.url);",
    `const OPERATION_FILE = ${JSON.stringify(productionFile)};`,
  )
  .replaceAll("stat.uid !== 0", "stat.uid !== process.getuid()")
  .replaceAll("lock.uid !== 0", "lock.uid !== process.getuid()")
  .replaceAll("if (process.getuid() !== 0)", "if (false)")
  .replace(
    "const fixedSpawnSync = (...args) => spawnSync(...args);",
    "const fixedSpawnSync = (...args) => " +
      "globalThis.__BROKKR_TEST_SPAWN_SYNC__?.(...args) ?? " +
      "spawnSync(...args);",
  )
  .concat(
    "\nexport { runHostAdapterCore as __testRunHostAdapterCore, " +
    "assertEffectLock as __testAssertEffectLock, " +
    "fixedNow as __testFixedNow };\n",
  );
const testModule = await import(
  `data:text/javascript;base64,${Buffer.from(testSource).toString("base64")}`,
);

export function runFixedDebianMaintenanceHostOperation({
  action, request, registration,
}) {
  if (action === "test-lock-proof") {
    return testModule.__testAssertEffectLock(request.attempt_id);
  }
  if (action === "test-fixed-now") {
    return testModule.__testFixedNow();
  }
  if (action === "test-production-dispatch") {
    return testModule.runFixedDebianMaintenanceHostOperation({
      action: "dispatch-recovery", request, registration,
    });
  }
  if (action !== "dispatch-recovery") {
    const env = globalThis.__BROKKR_TEST_HOST_ADAPTER_ENV__;
    if (!env) {
      throw Object.assign(new Error("test_host_adapter_environment_missing"), {
        code: "test_host_adapter_environment_missing",
      });
    }
    return testModule.__testRunHostAdapterCore({
      action, request, registration,
      env: {
        ...env,
        assertFenceCurrent: (fence, leaseFenceDigest) =>
          env.applyFenced({
            fence, lease_fence_digest: leaseFenceDigest,
            apply: () => undefined,
          }),
      },
    });
  }
  const host = globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__;
  if (!host || typeof host.persistActivation !== "function" || typeof host.runFixedAdapter !== "function") {
    throw Object.assign(new Error("test_fixed_recovery_host_missing"), { code: "test_fixed_recovery_host_missing" });
  }
  const activation = registration;
  const activationDigest = digest(activation);
  const published = host.persistActivation(structuredClone(activation));
  if (!published || published.activation_digest !== activationDigest || typeof published.idempotent !== "boolean") {
    throw Object.assign(new Error("bounded_recovery_activation_unverified"), { code: "bounded_recovery_activation_unverified" });
  }
  return {
    activation_digest: activationDigest,
    ...host.runFixedAdapter({
      action: "recover", attempt_id: activation.attempt_id,
      activation_digest: activationDigest,
      recovery_request: structuredClone(request),
    }),
  };
}
