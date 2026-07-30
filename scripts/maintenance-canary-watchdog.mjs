#!/usr/bin/env node
// Read-only readiness/monitor probe for one maintenance canary. It owns no
// recovery or scheduling authority; failures are consumed by the ceremony or
// systemd and cause the separately reviewed disarm path to run.
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const STATE = "/var/lib/brokkr/debian-maintenance";
const CREDENTIAL =
  "/etc/credstore/brokkr-maintenance-result-delivery-v1";
const PROBE = `${STATE}/evidence/maintenance-execution-result.json`;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const MODES = new Set(["readiness", "pre-arm", "monitor"]);
const fail = code => {
  const error = new Error(code);
  error.code = code;
  throw error;
};
const rooted = (rootPrefix, absolute) =>
  rootPrefix === "" ? absolute : path.join(rootPrefix, absolute.slice(1));
const protectedDirectory = (directory, uid) => {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid ||
      (stat.mode & 0o077) !== 0) fail("watchdog_directory_unsafe");
};
const protectedJson = (file, uid) => {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== uid ||
        ![0o400, 0o600].includes(stat.mode & 0o7777) ||
        stat.size < 2 || stat.size > 256 * 1024) {
      fail("watchdog_input_unsafe");
    }
    try {
      return JSON.parse(fs.readFileSync(fd, "utf8"));
    } catch {
      fail("watchdog_input_invalid");
    }
  } finally {
    fs.closeSync(fd);
  }
};
const state = (systemd, method, unit) => {
  if (typeof systemd?.[method] !== "function") {
    fail("watchdog_systemd_adapter_invalid");
  }
  return systemd[method](unit);
};

export function probeMaintenanceCanaryWatchdog({
  canaryId,
  mode,
  rootPrefix = "",
  expectedUid = process.geteuid(),
  systemd,
}) {
  if (!ID.test(canaryId) || !MODES.has(mode) ||
      (rootPrefix !== "" && !path.isAbsolute(rootPrefix))) {
    fail("watchdog_arguments_invalid");
  }
  for (const relative of ["", "armed", "disarmed", "evidence"]) {
    protectedDirectory(rooted(
      rootPrefix,
      relative === "" ? STATE : `${STATE}/${relative}`,
    ), expectedUid);
  }
  const armedFile = rooted(rootPrefix, `${STATE}/armed/${canaryId}.json`);
  const disarmedFile =
    rooted(rootPrefix, `${STATE}/disarmed/${canaryId}.json`);
  const armed = fs.existsSync(armedFile);
  const disarmed = fs.existsSync(disarmedFile);
  if ((mode === "monitor" && (!armed || disarmed)) ||
      (mode !== "monitor" && (armed || !disarmed))) {
    fail("watchdog_lifecycle_state_invalid");
  }
  const marker = protectedJson(
    mode === "monitor" ? armedFile : disarmedFile,
    expectedUid,
  );
  if (marker.canary_id !== canaryId ||
      marker.evidence_preserved !== true) {
    fail("watchdog_marker_invalid");
  }
  const credential = protectedJson(rooted(rootPrefix, CREDENTIAL), expectedUid);
  if (credential.kind !==
        "brokkr-maintenance-result-delivery-config" ||
      credential.schema_version !== "v1" ||
      credential.enabled !== true) {
    fail("watchdog_delivery_not_ready");
  }
  const probe = protectedJson(rooted(rootPrefix, PROBE), expectedUid);
  if (probe.kind !== "maintenance-execution-result" ||
      probe.schema_version !== "v1" ||
      probe.source?.source_id !== "brokkr-maintenance") {
    fail("watchdog_probe_not_ready");
  }
  const scheduler =
    `brokkr-debian-maintenance-scheduler-${canaryId}.timer`;
  const watchdog =
    `brokkr-debian-maintenance-watchdog-${canaryId}.timer`;
  const shouldRun = mode !== "readiness";
  for (const unit of [scheduler, watchdog]) {
    const enabled = state(systemd, "enabledState", unit);
    const active = state(systemd, "activeState", unit);
    if (shouldRun ?
      enabled !== "enabled" || active !== "active" :
      enabled !== "disabled" ||
        !["inactive", "failed"].includes(active)) {
      fail("watchdog_timer_state_invalid");
    }
  }
  return {
    kind: "brokkr-maintenance-canary-watchdog-readiness",
    schema_version: "v1",
    canary_id: canaryId,
    mode,
    ready: true,
  };
}

function productionSystemd() {
  const query = (verb, unit, accepted) => {
    const result = spawnSync("/usr/bin/systemctl", [verb, unit], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const output = (result.stdout ?? "").trim();
    if (result.error || !accepted.includes(output)) {
      fail("watchdog_systemd_query_failed");
    }
    return output;
  };
  return {
    enabledState: unit => query("is-enabled", unit, [
      "enabled", "disabled", "not-found",
    ]),
    activeState: unit => query("is-active", unit, [
      "active", "inactive", "failed", "not-found",
    ]),
  };
}

function main() {
  const [actionFlag, mode, canaryFlag, canaryId] = process.argv.slice(2);
  if (process.geteuid() !== 0 ||
      actionFlag !== "--action" || canaryFlag !== "--canary" ||
      process.argv.length !== 6) fail("watchdog_cli_arguments_invalid");
  const result = probeMaintenanceCanaryWatchdog({
    canaryId,
    mode,
    systemd: productionSystemd(),
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(
      `maintenance-canary-watchdog: ${error.code ?? "internal_failure"}\n`,
    );
    process.exitCode = 1;
  }
}
