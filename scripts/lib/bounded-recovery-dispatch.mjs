// Private W2a -> W2b composition seam. W2a owns the authoritative outbox,
// lease and signed narrowing; this bridge owns only publishing the already
// authorized successor activation and dispatching the one fixed recovery action.
import crypto from "node:crypto";

const DIGEST = /^sha256:[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const canonicalJson = value => value === null || typeof value !== "object" ? JSON.stringify(value) : Array.isArray(value) ? `[${value.map(canonicalJson).join(",")}]` : `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
const digest = value => `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
const fail = code => { const error = new Error(code); error.code = code; throw error; };
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

function validFence(fence, expected) {
  return exactKeys(fence, [
    "kind", "schema_version", "domain", "target_scope_digest", "attempt_id",
    "mutation_id", "binding_digest", "epoch", "holder_token", "activated_at",
    "expires_at",
  ]) && fence.kind === "brokkr-effect-lease-fence" &&
    fence.schema_version === "v1" &&
    fence.domain === "no-reboot-security-bugfix-maintenance" &&
    fence.target_scope_digest === expected.targetScopeDigest &&
    fence.attempt_id === expected.attemptId &&
    fence.mutation_id === expected.mutationId &&
    fence.binding_digest === expected.bindingDigest &&
    Number.isSafeInteger(fence.epoch) && fence.epoch >= 1 &&
    typeof fence.holder_token === "string" && fence.holder_token.length >= 16 &&
    ISO.test(fence.activated_at) && ISO.test(fence.expires_at) &&
    Number.isFinite(Date.parse(fence.activated_at)) &&
    Number.isFinite(Date.parse(fence.expires_at)) &&
    Date.parse(fence.activated_at) <= Date.parse(fence.expires_at);
}

export function createBoundedRecoveryDispatcher({ recovery, expected, publishActivation, dispatch }) {
  if (!plain(recovery) || !exactKeys(expected, [
    "attemptId", "bindingDigest", "descriptorDigest", "idempotencyKey",
    "mutationId", "targetScopeDigest",
  ]) || !ID.test(expected.attemptId) || !ID.test(expected.mutationId) ||
    !ID.test(expected.idempotencyKey) || !DIGEST.test(expected.bindingDigest) ||
    !DIGEST.test(expected.descriptorDigest) || !DIGEST.test(expected.targetScopeDigest) ||
    typeof publishActivation !== "function" || typeof dispatch !== "function") {
    fail("bounded_recovery_dispatch_contract_invalid");
  }
  return {
    ...recovery,
    recover: request => {
      if (!exactKeys(request, ["idempotency_key", "descriptor_digest", "target_scope_digest", "binding_digest", "lease_fence", "lease_fence_digest", "revalidation_fence", "revalidation_fence_digest"])) fail("bounded_recovery_dispatch_shape_invalid");
      if (request.idempotency_key !== expected.idempotencyKey ||
        request.descriptor_digest !== expected.descriptorDigest ||
        request.target_scope_digest !== expected.targetScopeDigest ||
        request.binding_digest !== expected.bindingDigest) {
        fail("bounded_recovery_dispatch_binding_invalid");
      }
      if (!DIGEST.test(request.lease_fence_digest) || !DIGEST.test(request.revalidation_fence_digest)) fail("bounded_recovery_dispatch_digest_invalid");
      if (request.revalidation_fence_digest !== digest(request.revalidation_fence) || request.lease_fence_digest !== digest(request.lease_fence)) fail("bounded_recovery_dispatch_fence_digest_invalid");
      if (!validFence(request.lease_fence, expected) ||
        !validFence(request.revalidation_fence, expected) ||
        request.revalidation_fence.epoch <= request.lease_fence.epoch ||
        request.revalidation_fence.holder_token === request.lease_fence.holder_token ||
        Date.parse(request.revalidation_fence.activated_at) < Date.parse(request.lease_fence.activated_at) ||
        Date.parse(request.revalidation_fence.expires_at) <= Date.parse(request.revalidation_fence.activated_at)) {
        fail("bounded_recovery_dispatch_fence_invalid");
      }
      const activation = {
        kind: "brokkr-debian-recovery-activation", schema_version: "v1", attempt_id: expected.attemptId,
        binding_digest: expected.bindingDigest, recovery_descriptor_digest: expected.descriptorDigest,
        fence: structuredClone(request.revalidation_fence), fence_digest: request.revalidation_fence_digest,
      };
      const published = publishActivation(structuredClone(activation));
      if (!exactKeys(published, ["activation_digest", "idempotent"]) || published.activation_digest !== digest(activation) || typeof published.idempotent !== "boolean") fail("bounded_recovery_activation_unverified");
      const dispatched = dispatch({ action: "recover", attempt_id: expected.attemptId, activation_digest: published.activation_digest, recovery_request: structuredClone(request) });
      if (!exactKeys(dispatched, ["idempotency_key", "effect_lease_fence_digest", "revalidated_lease_fence_digest", "revalidated_at", "recovered", "safe_state_verified", "quarantine_active", "reason_code"]) || dispatched.idempotency_key !== request.idempotency_key || !DIGEST.test(dispatched.effect_lease_fence_digest) || dispatched.revalidated_lease_fence_digest !== request.revalidation_fence_digest || !ISO.test(dispatched.revalidated_at) || !Number.isFinite(Date.parse(dispatched.revalidated_at)) || typeof dispatched.recovered !== "boolean" || typeof dispatched.safe_state_verified !== "boolean" || typeof dispatched.quarantine_active !== "boolean" || (dispatched.reason_code !== null && typeof dispatched.reason_code !== "string")) fail("bounded_recovery_dispatch_receipt_invalid");
      return dispatched;
    },
  };
}
