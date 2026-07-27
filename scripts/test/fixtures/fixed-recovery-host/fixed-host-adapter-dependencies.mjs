// Test-only replacement for the concrete production host dependencies.
// The production adapter remains unchanged and exposes no injected core.
const env = () => {
  const value = globalThis.__BROKKR_TEST_HOST_ADAPTER_ENV__;
  if (!value) throw Object.assign(new Error("test_host_adapter_environment_missing"), {
    code: "test_host_adapter_environment_missing",
  });
  return value;
};

export const fixedUid = () => env().uid;
export const fixedNow = () => env().now();
export const fixedRun = (argv, options) => env().run(argv, options);
export const fixedRebootRequired = () => env().rebootRequired();
export const fixedAdapterReleaseDigest = () => env().adapterReleaseDigest();
export const assertFixedDependencyDigest = () => undefined;
export const fixedAssertEffectLock = () => undefined;
export const fixedActivateFence = (_attempt, fence) => env().activateFence(fence);
export const fixedAssertFenceCurrent = (_attempt, fence, leaseFenceDigest) => {
  env().applyFenced({ fence, lease_fence_digest: leaseFenceDigest, apply: () => undefined });
};
export const fixedReadRecoveryActivation = () => env().readRecoveryActivation();
export const fixedReadJournal = () => env().readJournal();
export const fixedWriteJournal = (_attempt, value) => env().writeJournal(value);
export const fixedWriteTerminal = (_attempt, value) => env().writeTerminal(value);

export function readFixedHostInputs() {
  throw Object.assign(new Error("test_fixed_host_inputs_unavailable"), {
    code: "test_fixed_host_inputs_unavailable",
  });
}
