#!/usr/bin/env node
// Zero-argument root entry point.  Target, policy, paths, packages and actor
// identities are never accepted from argv.
import crypto from "node:crypto";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import {
  runDebianMaintenanceAttemptFactory,
} from "./lib/debian-maintenance-attempt-factory.mjs";

const STATE_ROOT = "/var/lib/brokkr/debian-maintenance";
const CONFIG_FILE = "/etc/brokkr/debian-maintenance-attempt-factory.json";
const FRESHNESS_FILE =
  "/run/brokkr/debian-maintenance-window-freshness.json";
const CLI_FILE = fileURLToPath(import.meta.url);
const OPERATION_FILE = fileURLToPath(new URL(
  "./lib/fixed-debian-maintenance-host-operation.mjs", import.meta.url,
));
const read = file => {
  const descriptor = fs.openSync(
    file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
  );
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.uid !== 0 || (stat.mode & 0o077) !== 0 ||
        stat.size > 4_000_000) throw Error("attempt_factory_input_unsafe");
    return JSON.parse(fs.readFileSync(descriptor, "utf8"));
  } finally {
    fs.closeSync(descriptor);
  }
};
const releaseDigest = () => `sha256:${crypto.createHash("sha256")
  .update(fs.readFileSync(OPERATION_FILE)).digest("hex")}`;
const now = () => new Date(Math.floor(Date.now() / 1000) * 1000)
  .toISOString().replace(".000Z", "Z");

function cli() {
  if (process.argv.length !== 2) throw Error("attempt_factory_cli_arguments_invalid");
  if (process.getuid() !== 0) throw Error("attempt_factory_root_required");
  const result = runDebianMaintenanceAttemptFactory({
    stateRoot: STATE_ROOT,
    releaseDigest: releaseDigest(),
    readConfiguration: () => read(CONFIG_FILE),
    readFreshness: () => read(FRESHNESS_FILE),
    now,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
if (process.argv[1] === CLI_FILE) cli();
