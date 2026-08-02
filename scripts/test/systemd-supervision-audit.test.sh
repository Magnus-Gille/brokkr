#!/usr/bin/env bash
# Hermetic regression for the read-only systemd supervision baseline audit (brokkr#98).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
AUDIT="$ROOT/scripts/systemd-supervision-audit.mjs"
FIXTURES="$ROOT/tests/fixtures/systemd-supervision"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASELINE="$ROOT/docs/systemd-supervision-baseline-v1.json"
REGISTRY="$FIXTURES/registry.json"
DECLARATIONS="$FIXTURES/declarations-positive.json"
OBSERVATIONS="$FIXTURES/observations-positive.json"
BARE_REGISTRY="$FIXTURES/registry-bare.json"
BARE_DECLARATIONS="$FIXTURES/declarations-bare-registry.json"
BARE_OBSERVATIONS="$FIXTURES/observations-bare-registry.json"
NOW="2026-08-02T12:00:00Z"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

run_audit() {
  local output="$1" declarations="$2" observations="$3" registry="${4:-$REGISTRY}"
  node "$AUDIT" \
    --baseline "$BASELINE" \
    --registry "$registry" \
    --declarations "$declarations" \
    --observations "$observations" \
    --now "$NOW" >"$output" 2>"$output.stderr"
  # shellcheck disable=SC2034 # checks consume RC through eval.
  RC=$?
}

make_case() {
  local base="$1" descriptor="$2" output="$3" case_id="$4"
  node --input-type=module - "$FIXTURES/$base" "$FIXTURES/$descriptor" "$output" "$case_id" <<'NODE'
import fs from "node:fs";
const [basePath, descriptorPath, outputPath, caseId] = process.argv.slice(2);
const base = JSON.parse(fs.readFileSync(basePath, "utf8"));
const descriptor = JSON.parse(fs.readFileSync(descriptorPath, "utf8"));
const candidate = descriptor.cases.find(row => row.id === caseId);
if (!candidate) throw new Error(`unknown fixture case ${caseId}`);
for (const [path, value] of Object.entries(candidate.mutations)) {
  const parts = path.split(".");
  let target = base;
  for (const part of parts.slice(0, -1)) target = target[part];
  target[parts.at(-1)] = value;
}
fs.writeFileSync(outputPath, `${JSON.stringify(base, null, 2)}\n`);
NODE
}

make_registry_case() {
  local base="$1" output="$2" kind="$3"
  node --input-type=module - "$FIXTURES/$base" "$output" "$kind" <<'NODE'
import fs from "node:fs";
const [basePath, outputPath, kind] = process.argv.slice(2);
const candidate = JSON.parse(fs.readFileSync(basePath, "utf8"));
const units = candidate.components[0].systemd_units;
if (kind === "duplicate-effective") units.push({ name: "heimdall.service", type: "service" });
if (kind === "wrong-suffix") units.push({ name: "contradictory.timer", type: "service" });
fs.writeFileSync(outputPath, `${JSON.stringify(candidate, null, 2)}\n`);
NODE
}

echo "systemd-supervision-audit.test.sh"

run_audit "$TMP/positive.json" "$DECLARATIONS" "$OBSERVATIONS"
check "positive system/user, long-running/oneshot/timer fixture passes" '[[ "$RC" -eq 0 ]]'
check "positive audit classifies all four registry units" 'node -e '\''const x=require(process.argv[1]); if(x.summary.status!=="pass"||x.summary.unit_count!==4||new Set(x.units.map(u=>u.workload_shape)).size!==3||!x.units.some(u=>u.scope==="user"))process.exit(1)'\'' "$TMP/positive.json"'
check "audit emits content-blind evidence fields only" 'node -e '\''const x=require(process.argv[1]); const u=x.units.find(row=>row.unit==="grimnir-api.service"); if(!u.evidence.unit_result||!u.evidence.restart||!u.evidence.watchdog||!u.evidence.oom||Object.hasOwn(u,"directives"))process.exit(1); const t=x.units.find(row=>row.unit.endsWith(".timer")); if(!t.evidence.timer.last_run_at||!t.evidence.timer.next_run_at)process.exit(1)'\'' "$TMP/positive.json"'
check "user failure target is not echoed in the content-blind audit" '! grep -q "workshop-failure" "$TMP/positive.json"'
ROOT="$ROOT" POSITIVE_OUTPUT="$TMP/positive.json" node --input-type=module <<'NODE'
import fs from "node:fs";
const root = process.env.ROOT;
const { checkSchema, schemaErrors } = await import(`${root}/scripts/lib/maintenance-policy-contract.mjs`);
const schemaFiles = [
  "docs/systemd-supervision-baseline-v1.schema.json",
  "docs/systemd-unit-declarations-v1.schema.json",
  "docs/systemd-supervision-observations-v1.schema.json",
  "docs/systemd-supervision-audit-v1.schema.json",
];
for (const file of schemaFiles) checkSchema(JSON.parse(fs.readFileSync(`${root}/${file}`, "utf8")));
const pairs = [
  [schemaFiles[0], "docs/systemd-supervision-baseline-v1.json"],
  [schemaFiles[1], "tests/fixtures/systemd-supervision/declarations-positive.json"],
  [schemaFiles[2], "tests/fixtures/systemd-supervision/observations-positive.json"],
  [schemaFiles[1], "tests/fixtures/systemd-supervision/declarations-bare-registry.json"],
  [schemaFiles[2], "tests/fixtures/systemd-supervision/observations-bare-registry.json"],
  [schemaFiles[3], process.env.POSITIVE_OUTPUT],
];
for (const [schemaFile, valueFile] of pairs) {
  const schema = JSON.parse(fs.readFileSync(`${root}/${schemaFile}`, "utf8"));
  const value = JSON.parse(fs.readFileSync(valueFile, "utf8"));
  const errors = schemaErrors(schema, value);
  if (errors.length) throw new Error(`${schemaFile}: ${errors.join("; ")}`);
}
NODE
# shellcheck disable=SC2034 # checks consume SCHEMA_RC through eval.
SCHEMA_RC=$?
check "versioned baseline and projection schemas validate positive fixtures" '[[ "$SCHEMA_RC" -eq 0 ]]'

run_audit "$TMP/bare-registry.json" "$BARE_DECLARATIONS" "$BARE_OBSERVATIONS" "$BARE_REGISTRY"
check "bare Grimnir-shaped registry normalizes to effective unit names" '[[ "$RC" -eq 0 ]]'
check "bare registry timer targets are checked after normalization" 'node -e '\''const x=require(process.argv[1]); if(x.summary.unit_count!==5||x.summary.status!=="pass"||x.units.some(u=>!u.unit.endsWith(".service")&&!u.unit.endsWith(".timer"))||x.units.some(u=>u.findings.some(f=>f.code==="timer_target_missing")))process.exit(1)'\'' "$TMP/bare-registry.json"'

for CASE_ID in duplicate-effective wrong-suffix; do
  make_registry_case registry-bare.json "$TMP/$CASE_ID-registry.json" "$CASE_ID"
  run_audit "$TMP/$CASE_ID.json" "$BARE_DECLARATIONS" "$BARE_OBSERVATIONS" "$TMP/$CASE_ID-registry.json"
  check "$CASE_ID registry identity is rejected" '[[ "$RC" -ne 0 ]]'
done

for CASE_ID in restart-storm oom missed-timer absent-notifier stale-audit; do
  make_case observations-positive.json observations-negative.json "$TMP/$CASE_ID-observations.json" "$CASE_ID"
  run_audit "$TMP/$CASE_ID.json" "$DECLARATIONS" "$TMP/$CASE_ID-observations.json"
  check "$CASE_ID observation is rejected or flagged" '[[ "$RC" -ne 0 ]]'
done
check "restart storm is routed as a finding" "grep -q '\"code\": \"restart_storm\"' \"$TMP/restart-storm.json\""
check "OOM result is preserved as evidence and flagged" "grep -q '\"code\": \"oom_kill_observed\"' \"$TMP/oom.json\" && grep -q '\"result\": \"killed\"' \"$TMP/oom.json\""
check "missed non-persistent timer is flagged" "grep -q '\"code\": \"timer_missed_runs\"' \"$TMP/missed-timer.json\" && grep -q '\"code\": \"timer_not_persistent\"' \"$TMP/missed-timer.json\""
check "absent notifier is flagged without delivery side effects" "grep -q '\"code\": \"failure_delivery_unavailable\"' \"$TMP/absent-notifier.json\" && [[ ! -e \"$TMP/absent-notifier.json.sent\" ]]"
check "stale audit freshness is flagged" "grep -q '\"status\": \"stale\"' \"$TMP/stale-audit.json\" && grep -q '\"code\": \"audit_stale\"' \"$TMP/stale-audit.json\""

for CASE_ID in unsafe-long-running contradictory-oneshot user-system-delivery user-failure-delivery-missing user-failure-delivery-unsafe timer-persistence unsupported-content rogue-unit; do
  make_case declarations-positive.json declarations-negative.json "$TMP/$CASE_ID-declarations.json" "$CASE_ID"
  run_audit "$TMP/$CASE_ID.json" "$TMP/$CASE_ID-declarations.json" "$OBSERVATIONS"
  check "$CASE_ID directive fixture fails closed" '[[ "$RC" -ne 0 ]]'
done
check "unsafe directives produce typed findings" "grep -q '\"code\": \"restart_policy_unsafe\"' \"$TMP/unsafe-long-running.json\" && grep -q '\"code\": \"oom_policy_unsafe\"' \"$TMP/unsafe-long-running.json\" && grep -q '\"code\": \"watchdog_heartbeat_unverified\"' \"$TMP/unsafe-long-running.json\""
check "contradictory oneshot restart is flagged" "grep -q '\"code\": \"restart_policy_unsafe\"' \"$TMP/contradictory-oneshot.json\" && grep -q '\"code\": \"restart_delay_forbidden\"' \"$TMP/contradictory-oneshot.json\""
check "user scope cannot use the system failure target" "grep -q '\"code\": \"scope_delivery_contradiction\"' \"$TMP/user-system-delivery.json\""
check "user scope cannot self-assert delivery with an empty target" "grep -q '\"code\": \"failure_delivery_missing\"' \"$TMP/user-failure-delivery-missing.json\""
check "user failure targets must be sanitized without echoing values" "grep -q '\"code\": \"failure_delivery_unsafe\"' \"$TMP/user-failure-delivery-unsafe.json\" && ! grep -q 'private path' \"$TMP/user-failure-delivery-unsafe.json\" && ! grep -q 'private path' \"$TMP/user-failure-delivery-unsafe.json.stderr\""
check "timer persistence and normalized scope contradictions are flagged" "grep -q '\"code\": \"timer_not_persistent\"' \"$TMP/timer-persistence.json\" && grep -q '\"code\": \"timer_target_missing\"' \"$TMP/timer-persistence.json\""
check "unsupported directive content is never echoed" '[[ ! -s "$TMP/unsupported-content.json" ]] && ! grep -q "private content" "$TMP/unsupported-content.json.stderr"'
check "registry remains the only topology authority" '[[ ! -s "$TMP/rogue-unit.json" ]] && grep -q "outside the registry" "$TMP/rogue-unit.json.stderr"'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
