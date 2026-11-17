#!/usr/bin/env node
// Observation-only delivery of the `systemd-supervision-audit` v1 document to
// Heimdall (BROKKR-123). Usage: the audit's stdout is piped in; no endpoint,
// token, or path is accepted in argv or emitted in output.
//
//   node scripts/systemd-supervision-audit.mjs ... | \
//     node scripts/systemd-supervision-delivery.mjs
//
// Rollback: set `enabled:false` in the protected credential (or stop the unit);
// the local audit producer is untouched.
import {
  DeliveryError, MAX_AUDIT_BYTES, deliver, parseAudit, readProtectedConfig, validateConfig,
} from "./lib/systemd-supervision-delivery.mjs";

const fail = (code) => { throw new DeliveryError(code); };

async function readBoundedStdin() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_AUDIT_BYTES) fail("audit_too_large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

try {
  if (process.argv.length !== 2) fail("arguments_forbidden");
  const bytes = await readBoundedStdin();
  const audit = parseAudit(bytes);
  const transport = validateConfig(readProtectedConfig());
  if (!transport.enabled) {
    process.stdout.write(`${JSON.stringify({
      kind: "systemd-supervision-delivery", schema_version: "v1",
      delivered: false, reason: "delivery_disabled", observed_at: audit.observed_at,
    })}\n`);
  } else {
    await deliver(bytes, transport);
    process.stdout.write(`${JSON.stringify({
      kind: "systemd-supervision-delivery", schema_version: "v1",
      delivered: true, observed_at: audit.observed_at,
      finding_count: audit.summary.finding_count,
    })}\n`);
  }
} catch (error) {
  const code = error instanceof DeliveryError ? error.message : "internal_failure";
  process.stderr.write(`systemd-supervision-delivery: ${code}\n`);
  process.exitCode = 1;
}
