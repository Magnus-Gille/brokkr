// Typed W2a -> W2b composition seam.  W2a owns the authoritative outbox,
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

export function createBoundedRecoveryDispatcher({ recovery, attemptId, bindingDigest, descriptorDigest, publishActivation, dispatch }) {
  if (!plain(recovery) || !ID.test(attemptId) || !DIGEST.test(bindingDigest) || !DIGEST.test(descriptorDigest) || typeof publishActivation !== "function" || typeof dispatch !== "function") fail("bounded_recovery_dispatch_contract_invalid");
  return {
    ...recovery,
    recover: request => {
      if (!exactKeys(request, ["idempotency_key", "descriptor_digest", "target_scope_digest", "binding_digest", "lease_fence", "lease_fence_digest", "revalidation_fence", "revalidation_fence_digest"]) ||
        !ID.test(request.idempotency_key) || request.descriptor_digest !== descriptorDigest || request.binding_digest !== bindingDigest || !DIGEST.test(request.target_scope_digest) || !DIGEST.test(request.lease_fence_digest) || !DIGEST.test(request.revalidation_fence_digest) || request.revalidation_fence_digest !== digest(request.revalidation_fence) || request.lease_fence_digest !== digest(request.lease_fence) || request.revalidation_fence.epoch <= request.lease_fence.epoch || request.revalidation_fence.domain !== request.lease_fence.domain || request.revalidation_fence.target_scope_digest !== request.target_scope_digest || request.revalidation_fence.attempt_id !== request.lease_fence.attempt_id || request.revalidation_fence.mutation_id !== request.lease_fence.mutation_id || request.revalidation_fence.binding_digest !== bindingDigest) fail("bounded_recovery_dispatch_request_invalid");
      const activation = {
        kind: "brokkr-debian-recovery-activation", schema_version: "v1", attempt_id: attemptId,
        binding_digest: bindingDigest, recovery_descriptor_digest: descriptorDigest,
        fence: structuredClone(request.revalidation_fence), fence_digest: request.revalidation_fence_digest,
      };
      const published = publishActivation(structuredClone(activation));
      if (!exactKeys(published, ["activation_digest", "idempotent"]) || published.activation_digest !== digest(activation) || typeof published.idempotent !== "boolean") fail("bounded_recovery_activation_unverified");
      const dispatched = dispatch({ action: "recover", attempt_id: attemptId, activation_digest: published.activation_digest, recovery_request: structuredClone(request) });
      if (!exactKeys(dispatched, ["idempotency_key", "effect_lease_fence_digest", "revalidated_lease_fence_digest", "revalidated_at", "recovered", "safe_state_verified", "quarantine_active", "reason_code"]) || dispatched.idempotency_key !== request.idempotency_key || dispatched.effect_lease_fence_digest !== request.lease_fence_digest || dispatched.revalidated_lease_fence_digest !== request.revalidation_fence_digest) fail("bounded_recovery_dispatch_receipt_invalid");
      return dispatched;
    },
  };
}
