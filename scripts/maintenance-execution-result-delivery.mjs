#!/usr/bin/env node
// Deliberately inert W3a.0 delivery boundary: validates a result then reports
// that delivery is disabled. It imports no transport or host-management code.
import fs from "node:fs";
import { validateMaintenanceExecutionResult } from "./maintenance-execution-result.mjs";
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== "--result") {
  process.stderr.write("usage: maintenance-execution-result-delivery.mjs --result result.json\n"); process.exit(64);
}
try {
  const result = JSON.parse(fs.readFileSync(args[1], "utf8"));
  validateMaintenanceExecutionResult(result);
  process.stdout.write(JSON.stringify({ kind: "maintenance-execution-result-delivery", schema_version: "v1", delivered: false, reason: "delivery_disabled", result_id: result.result_id }) + "\n");
} catch (error) { process.stderr.write(`maintenance-result-delivery: ${error.message}\n`); process.exit(1); }
