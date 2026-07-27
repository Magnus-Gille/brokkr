// Loaded only by loader.mjs in hermetic child-process tests. The production
// module has no callback or configurable execution seam.
import crypto from "node:crypto";

const canonicalJson = value => value === null || typeof value !== "object" ? JSON.stringify(value) : Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` : `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;

export function runFixedBoundedRecoveryHost({ action, attempt_id, activation, recovery_request }) {
  const host = globalThis.__BROKKR_TEST_FIXED_RECOVERY_HOST__;
  if (!host || typeof host.persistActivation !== "function" || typeof host.runFixedAdapter !== "function") {
    throw Object.assign(new Error("test_fixed_recovery_host_missing"), { code: "test_fixed_recovery_host_missing" });
  }
  const activationDigest = digest(activation);
  const published = host.persistActivation(structuredClone(activation));
  if (!published || published.activation_digest !== activationDigest || typeof published.idempotent !== "boolean") {
    throw Object.assign(new Error("bounded_recovery_activation_unverified"), { code: "bounded_recovery_activation_unverified" });
  }
  return {
    activation_digest: activationDigest,
    ...host.runFixedAdapter({ action, attempt_id, activation_digest: activationDigest, recovery_request: structuredClone(recovery_request) }),
  };
}
