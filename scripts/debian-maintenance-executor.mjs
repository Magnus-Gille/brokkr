// The only public no-reboot execution entry.  It deliberately composes W2a's
// authoritative recovery outbox with the fixed W2b recovery dispatcher so a
// caller cannot choose an apply-only path after an ambiguous host effect.
import {
  deriveDebianAutonomyExecution,
  runDebianMaintenance as runBoundAttempt,
} from "./debian-maintenance-autonomy.mjs";
import { createBoundedRecoveryDispatcher } from "./lib/bounded-recovery-dispatch.mjs";

const fail = code => { const error = new Error(code); error.code = code; throw error; };

export { deriveDebianAutonomyExecution, createBoundedRecoveryDispatcher };

export function runDebianMaintenance(options = {}) {
  const { binding, recovery } = options;
  if (!binding || !recovery || typeof recovery.publishActivation !== "function" || typeof recovery.authorizeBinding !== "function" ||
    typeof recovery.dispatch !== "function" || typeof binding.attempt_id !== "string" ||
    typeof binding.recovery?.descriptor_digest !== "string") {
    fail("bounded_recovery_dispatch_required");
  }
  const bridgedRecovery = createBoundedRecoveryDispatcher({
    recovery, attemptId: binding.attempt_id,
    descriptorDigest: binding.recovery.descriptor_digest,
    authorizeBinding: recovery.authorizeBinding,
    publishActivation: recovery.publishActivation,
    dispatch: recovery.dispatch,
  });
  return runBoundAttempt({ ...options, recovery: bridgedRecovery });
}
