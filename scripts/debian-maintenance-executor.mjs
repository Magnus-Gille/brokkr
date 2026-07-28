// Compatibility entry point for the closed production surface. The mandatory
// recovery bridge lives beside the private W2a runner, so importing either
// module reaches the same guarded function.
export {
  deriveDebianAutonomyExecution,
  runDebianMaintenance,
} from "./debian-maintenance-autonomy.mjs";
