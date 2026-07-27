// Exact public execution surface. The generic journal state machine and raw
// effect seam are private in the composed module so callers cannot substitute
// arbitrary phase callbacks behind a valid lease.
export {
  deriveDebianAutonomyExecution,
  runDebianMaintenance,
} from "./debian-maintenance-autonomy.mjs";
export { createBoundedRecoveryDispatcher } from "./lib/bounded-recovery-dispatch.mjs";
