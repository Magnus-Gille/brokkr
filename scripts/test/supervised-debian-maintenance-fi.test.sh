#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
mkdir -p "$SOURCE"
while IFS= read -r -d '' file; do
  [[ -e "$ROOT/$file" || -L "$ROOT/$file" ]] || continue
  mkdir -p "$SOURCE/$(dirname "$file")"
  cp -P "$ROOT/$file" "$SOURCE/$file"
done < <(git -C "$ROOT" ls-files -co --exclude-standard -z)
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name "Brokkr hermetic test"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm "fixture"
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

REPORT="$TMP/dossier.json"
"$SOURCE/scripts/supervised-debian-maintenance-fi.sh" \
  --revision "$REVISION" \
  --output "$REPORT"

node --input-type=module - "$REPORT" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
const dossier = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.deepEqual(Object.keys(dossier).sort(), [
  "clean_runs", "generated_at", "induced_failures", "kind",
  "production_path", "redaction", "release_sha", "schema_version",
  "scenarios",
].sort());
assert.equal(dossier.kind, "brokkr-supervised-debian-fault-injection-dossier");
assert.equal(dossier.schema_version, "v1");
assert.match(dossier.release_sha, /^[a-f0-9]{40}$/);
assert.equal(dossier.clean_runs, 1);
assert.equal(dossier.induced_failures, 10);
assert.equal(dossier.scenarios.length, 11);
assert.deepEqual(dossier.scenarios.map(value => value.id).sort(), [
  "clean-run",
  "controller-kill-9",
  "disk-headroom-failure",
  "interrupted-package-state",
  "lock-contention",
  "network-loss",
  "postcondition-failure",
  "progress-loop-wedge",
  "recovery-crash-loop",
  "terminal-exhaustion",
  "unknown-reachability",
].sort());
for (const scenario of dossier.scenarios) {
  assert.equal(scenario.path_id, "w2a-w2b-production-v1");
  assert.equal(scenario.passed, true, scenario.id);
  assert.equal(scenario.quarantine_active,
    scenario.id === "clean-run" ? false : true, scenario.id);
  assert.equal(scenario.new_plan_mutations, 0, scenario.id);
  assert.equal(Number.isSafeInteger(scenario.budget_seconds), true);
  assert.equal(scenario.budget_seconds > 0, true);
  assert.equal(
    Number.isSafeInteger(scenario.observed_elapsed_seconds),
    true,
    scenario.id,
  );
  assert.equal(
    scenario.observed_elapsed_seconds <= scenario.budget_seconds,
    true,
    scenario.id,
  );
  assert.match(
    scenario.terminal_at,
    /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
    scenario.id,
  );
}
assert.deepEqual(Object.keys(dossier.production_path).sort(), [
  "bounded_recovery_dispatcher", "controller", "host_operation",
  "recovery_unit",
].sort());
for (const value of Object.values(dossier.production_path)) {
  assert.match(value, /^sha256:[a-f0-9]{64}$/);
}
assert.equal(dossier.redaction.private_locators, "excluded");
assert.equal(dossier.redaction.package_logs, "excluded");
assert.equal(JSON.stringify(dossier).includes("/home/"), false);
assert.equal(JSON.stringify(dossier).includes("/Users/"), false);
assert.equal(JSON.stringify(dossier).includes("192.168."), false);
NODE

# The production runner refuses to produce evidence from source that differs
# from the named release, including an otherwise irrelevant untracked file.
printf '%s\n' 'dirty' >"$SOURCE/untracked-drift"
if "$SOURCE/scripts/supervised-debian-maintenance-fi.sh" \
  --revision "$REVISION" \
  --output "$TMP/dirty-dossier.json" >"$TMP/dirty.out" 2>&1; then
  echo "dirty source unexpectedly produced a dossier" >&2
  exit 1
fi
grep -Fq "source worktree is dirty" "$TMP/dirty.out"
test ! -e "$TMP/dirty-dossier.json"

# Split a valid dossier back into exact fragments, then prove a fractional
# timestamp cannot be certified even if every other field and digest is valid.
node --input-type=module - \
  "$REPORT" "$TMP/controller.json" "$TMP/host-fractional.json" <<'NODE'
import fs from "node:fs";
const [reportFile, controllerFile, hostFile] = process.argv.slice(2);
const dossier = JSON.parse(fs.readFileSync(reportFile, "utf8"));
const controllerIds = new Set([
  "clean-run", "controller-kill-9", "progress-loop-wedge",
  "recovery-crash-loop", "unknown-reachability",
]);
const base = {
  kind: "brokkr-supervised-debian-fi-fragment",
  schema_version: "v1",
  path_id: "w2a-w2b-production-v1",
};
fs.writeFileSync(controllerFile, JSON.stringify({
  ...base,
  production_path: {
    controller: dossier.production_path.controller,
    bounded_recovery_dispatcher:
      dossier.production_path.bounded_recovery_dispatcher,
  },
  scenarios: dossier.scenarios.filter(value => controllerIds.has(value.id)),
}));
const hostScenarios =
  dossier.scenarios.filter(value => !controllerIds.has(value.id));
hostScenarios[0].terminal_at =
  hostScenarios[0].terminal_at.replace("Z", ".123Z");
fs.writeFileSync(hostFile, JSON.stringify({
  ...base,
  production_path: {
    host_operation: dossier.production_path.host_operation,
    recovery_unit: dossier.production_path.recovery_unit,
  },
  scenarios: hostScenarios,
}));
NODE
if node "$SOURCE/scripts/supervised-debian-maintenance-fi.mjs" \
  --revision "$REVISION" \
  --controller "$TMP/controller.json" \
  --host "$TMP/host-fractional.json" \
  --output "$TMP/fractional-dossier.json" \
  >"$TMP/fractional.out" 2>&1; then
  echo "fractional terminal timestamp unexpectedly certified" >&2
  exit 1
fi
grep -Fq "supervised_fi_scenario_invalid" "$TMP/fractional.out"
test ! -e "$TMP/fractional-dossier.json"

echo "supervised Debian FI: one clean and ten induced exact-path scenarios OK"
