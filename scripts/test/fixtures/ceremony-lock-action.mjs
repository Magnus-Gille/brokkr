import fs from "node:fs";

const [log, label, hold] = process.argv.slice(2);
fs.appendFileSync(log, `${label}-start\n`);
Atomics.wait(
  new Int32Array(new SharedArrayBuffer(4)),
  0,
  0,
  Number.parseInt(hold, 10),
);
fs.appendFileSync(log, `${label}-end\n`);
