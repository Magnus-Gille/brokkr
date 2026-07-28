// Private W2a -> W2b composition seam. W2a owns the authoritative outbox,
// lease and signed narrowing; this bridge owns only publishing the already
// authorized successor activation and dispatching the one fixed recovery action.
import crypto from "node:crypto";
import { runFixedDebianMaintenanceHostOperation } from "./fixed-debian-maintenance-host-operation.mjs";

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

export function createBoundedRecoveryDispatcher({ expected }) {
  if (!exactKeys(expected, [
    "attemptId", "bindingDigest", "descriptorDigest", "idempotencyKey",
    "mutationId", "targetScopeDigest",
  ]) || !ID.test(expected.attemptId) || !ID.test(expected.mutationId) ||
    !ID.test(expected.idempotencyKey) || !DIGEST.test(expected.bindingDigest) ||
    !DIGEST.test(expected.descriptorDigest) || !DIGEST.test(expected.targetScopeDigest)) {
    fail("bounded_recovery_dispatch_contract_invalid");
  }
  return {
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
      const dispatched = runFixedDebianMaintenanceHostOperation({
        action: "dispatch-recovery",
        request: structuredClone(request),
        registration: structuredClone(activation),
      });
      if (!plain(dispatched) || dispatched.activation_digest !== digest(activation)) fail("bounded_recovery_activation_unverified");
      const { activation_digest: activationDigest, ...receipt } = dispatched;
      if (!exactKeys(receipt, ["idempotency_key", "effect_lease_fence_digest", "revalidated_lease_fence_digest", "revalidated_at", "recovered", "safe_state_verified", "quarantine_active", "reason_code"]) || receipt.idempotency_key !== request.idempotency_key || receipt.effect_lease_fence_digest !== request.lease_fence_digest || receipt.revalidated_lease_fence_digest !== request.revalidation_fence_digest || !ISO.test(receipt.revalidated_at) || !Number.isFinite(Date.parse(receipt.revalidated_at)) || typeof receipt.recovered !== "boolean" || typeof receipt.safe_state_verified !== "boolean" || typeof receipt.quarantine_active !== "boolean" || (receipt.reason_code !== null && typeof receipt.reason_code !== "string")) fail("bounded_recovery_dispatch_receipt_invalid");
      // The outbox receipt carries the durable activation identity as well as
      // a digest of the fixed-adapter terminal receipt.  Both are explicitly
      // bound to the successor fence; a successful-looking adapter response
      // cannot be replayed under another successor lease.
      const terminalReceipt = {
        activation_digest: activationDigest,
        revalidation_fence_digest: request.revalidation_fence_digest,
        host_receipt_digest: digest(receipt),
      };
      return {
        ...receipt,
        activation_digest: activationDigest,
        terminal_receipt_digest: digest(terminalReceipt),
      };
    },
  };
}
