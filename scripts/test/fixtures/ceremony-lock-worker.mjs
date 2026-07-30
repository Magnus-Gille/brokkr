import { runUnderLifecycleLock } from
  "../../maintenance-owner-ceremony-transition.mjs";

const [lock, action, log, label, hold] = process.argv.slice(2);
process.exitCode = runUnderLifecycleLock({
  lockPath: lock,
  command: [process.execPath, action, log, label, hold],
});
