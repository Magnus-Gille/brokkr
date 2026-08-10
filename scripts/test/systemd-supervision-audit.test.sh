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
REPEATED_REGISTRY="$FIXTURES/registry-repeated-name.json"
REPEATED_DECLARATIONS="$FIXTURES/declarations-repeated-name.json"
REPEATED_OBSERVATIONS="$FIXTURES/observations-repeated-name.json"
NOW="2026-08-02T12:00:00Z"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

run_audit() {
  local output="$1" declarations="$2" observations="$3" registry="${4:-$REGISTRY}" baseline="${5:-$BASELINE}" now="${6:-$NOW}"
  BROKKR_SYSTEMD_AUDIT_ALLOW_REPLAY=1 node "$AUDIT" --baseline "$baseline" --registry "$registry" --declarations "$declarations" --observations "$observations" --now "$now" >"$output" 2>"$output.stderr"
  RC=$?
}

make_case() {
  local base="$1" descriptor="$2" output="$3" case_id="$4"
  node --input-type=module - "$FIXTURES/$base" "$FIXTURES/$descriptor" "$output" "$case_id" <<'NODE'
import fs from "node:fs";
const [basePath, descriptorPath, outputPath, caseId] = process.argv.slice(2);
const base = JSON.parse(fs.readFileSync(basePath, "utf8"));
const descriptor = JSON.parse(fs.readFileSync(descriptorPath, "utf8"));
if (descriptor.base !== basePath.split("/").at(-1)) throw new Error(`fixture base mismatch for ${caseId}`);
const candidate = descriptor.cases.find(row => row.id === caseId);
if (!candidate) throw new Error(`unknown fixture case ${caseId}`);
if (!candidate.mutations || Object.keys(candidate.mutations).length === 0) throw new Error(`fixture case ${caseId} has no mutations`);
const before = JSON.stringify(base);
for (const [mutationPath, value] of Object.entries(candidate.mutations)) {
  const parts = mutationPath.split(".");
  let target = base;
  for (const part of parts.slice(0, -1)) {
    if (target === null || typeof target !== "object" || !Object.hasOwn(target, part)) throw new Error(`fixture path is missing for ${caseId}`);
    target = target[part];
  }
  const leaf = parts.at(-1);
  if (target === null || typeof target !== "object") throw new Error(`fixture target is invalid for ${caseId}`);
  if (value && typeof value === "object" && !Array.isArray(value) && value.$delete === true) {
    if (!Object.hasOwn(target, leaf)) throw new Error(`fixture delete path is missing for ${caseId}`);
    delete target[leaf];
  }
  else if (value && typeof value === "object" && !Array.isArray(value) && value.$remove === true) {
    if (!Array.isArray(target) || !/^\d+$/.test(leaf) || Number(leaf) >= target.length) throw new Error(`fixture remove path is invalid for ${caseId}`);
    target.splice(Number(leaf), 1);
  }
  else target[parts.at(-1)] = value;
}
if (JSON.stringify(base) === before) throw new Error(`fixture case ${caseId} did not change its base`);
fs.writeFileSync(outputPath, `${JSON.stringify(base, null, 2)}\n`);
NODE
  local status=$?
  [[ "$status" -eq 0 && -s "$output" ]] || return 1
}

make_baseline_case() {
  local output="$1" case_id="$2"
  node --input-type=module - "$BASELINE" "$FIXTURES/baseline-negative.json" "$output" "$case_id" <<'NODE'
import fs from "node:fs";
const [basePath, descriptorPath, outputPath, caseId] = process.argv.slice(2);
const base = JSON.parse(fs.readFileSync(basePath, "utf8"));
const descriptor = JSON.parse(fs.readFileSync(descriptorPath, "utf8"));
if (descriptor.base !== basePath.split("/").at(-1)) throw new Error(`fixture base mismatch for ${caseId}`);
const candidate = descriptor.cases.find(row => row.id === caseId);
if (!candidate || !candidate.mutations || Object.keys(candidate.mutations).length === 0) throw new Error(`invalid fixture case ${caseId}`);
const before = JSON.stringify(base);
for (const [mutationPath, value] of Object.entries(candidate.mutations)) {
  const parts = mutationPath.split(".");
  let target = base;
  for (const part of parts.slice(0, -1)) {
    if (target === null || typeof target !== "object" || !Object.hasOwn(target, part)) throw new Error(`fixture path is missing for ${caseId}`);
    target = target[part];
  }
  target[parts.at(-1)] = value;
}
if (JSON.stringify(base) === before) throw new Error(`fixture case ${caseId} did not change its base`);
fs.writeFileSync(outputPath, `${JSON.stringify(base, null, 2)}\n`);
NODE
  local status=$?
  [[ "$status" -eq 0 && -s "$output" ]] || return 1
}

make_registry_case() {
  local output="$1" kind="$2"
  node --input-type=module - "$BARE_REGISTRY" "$output" "$kind" <<'NODE'
import fs from "node:fs";
const [basePath, outputPath, kind] = process.argv.slice(2);
const candidate = JSON.parse(fs.readFileSync(basePath, "utf8"));
const units = candidate.components[0].systemd_units;
if (kind === "duplicate-effective") units.push({ name: "heimdall.service", type: "service" });
if (kind === "wrong-suffix") units.push({ name: "contradictory.timer", type: "service" });
if (kind === "duplicate-component") candidate.components.push({ name: "heimdall", systemd_units: [] });
fs.writeFileSync(outputPath, `${JSON.stringify(candidate, null, 2)}\n`);
NODE
}

assert_finding() {
  local audit_file="$1" expected_unit="$2" code="$3" severity="$4" route="$5"
  node --input-type=module - "$audit_file" "$expected_unit" "$code" "$severity" "$route" <<'NODE'
import fs from "node:fs";
const [auditPath, expectedUnit, code, severity, route] = process.argv.slice(2);
const audit = JSON.parse(fs.readFileSync(auditPath, "utf8"));
if (expectedUnit === "@global") {
  if (!audit.findings.some(finding => finding.code === code && finding.severity === severity && finding.route === route && !Object.hasOwn(finding, "unit"))) process.exit(1);
} else {
  const identity = expectedUnit.split("/");
  const unit = identity.length === 3
    ? audit.units.find(candidate => candidate.target_node_id === identity[0] && candidate.scope === identity[1] && candidate.unit === identity[2])
    : audit.units.find(candidate => candidate.unit === expectedUnit);
  if (!unit) process.exit(1);
  if (!audit.findings.some(finding => finding.code === code && finding.severity === severity && finding.route === route && finding.unit === unit.unit && finding.target_node_id === unit.target_node_id && finding.scope === unit.scope && finding.owner === unit.owner)) process.exit(1);
}
NODE
}

expect_observation_finding() {
  local case_id="$1" expected_unit="$2" code="$3" severity="${4:-error}" route="${5:-substrate}" now="${6:-$NOW}"
  if ! make_case observations-positive.json observations-negative.json "$TMP/$case_id-observations.json" "$case_id"; then bad "$case_id fixture mutation succeeds"; return; fi
  run_audit "$TMP/$case_id.json" "$DECLARATIONS" "$TMP/$case_id-observations.json" "$REGISTRY" "$BASELINE" "$now"
  if [[ "$RC" -eq 1 && -s "$TMP/$case_id.json" ]] && assert_finding "$TMP/$case_id.json" "$expected_unit" "$code" "$severity" "$route"; then ok "$case_id emits $expected_unit/$code/$severity/$route (exit 1)"; else bad "$case_id emits $expected_unit/$code/$severity/$route (exit 1)"; fi
}

expect_declaration_finding() {
  local case_id="$1" expected_unit="$2" code="$3" severity="${4:-error}" route="${5:-substrate}" observations="${6:-$OBSERVATIONS}"
  if ! make_case declarations-positive.json declarations-negative.json "$TMP/$case_id-declarations.json" "$case_id"; then bad "$case_id fixture mutation succeeds"; return; fi
  run_audit "$TMP/$case_id.json" "$TMP/$case_id-declarations.json" "$observations"
  if [[ "$RC" -eq 1 && -s "$TMP/$case_id.json" ]] && assert_finding "$TMP/$case_id.json" "$expected_unit" "$code" "$severity" "$route"; then ok "$case_id emits $expected_unit/$code/$severity/$route (exit 1)"; else bad "$case_id emits $expected_unit/$code/$severity/$route (exit 1)"; fi
}

expect_malformed_declaration() {
  local case_id="$1" marker="${2:-}"
  if ! make_case declarations-positive.json declarations-negative.json "$TMP/$case_id-declarations.json" "$case_id"; then bad "$case_id fixture mutation succeeds before malformed assertion"; return; fi
  run_audit "$TMP/$case_id.json" "$TMP/$case_id-declarations.json" "$OBSERVATIONS"
  if [[ "$RC" -eq 2 && ! -s "$TMP/$case_id.json" ]] && { [[ -z "$marker" ]] || ! grep -q "$marker" "$TMP/$case_id.json.stderr"; }; then ok "$case_id is malformed, content-blind, and emits no record (exit 2)"; else bad "$case_id is malformed, content-blind, and emits no record (exit 2)"; fi
}

echo "systemd-supervision-audit.test.sh"

if make_case declarations-positive.json declarations-negative.json "$TMP/unexpected-case-output.json" case-does-not-exist >/dev/null 2>&1 || [[ -e "$TMP/unexpected-case-output.json" ]]; then
  bad "fixture mutation helper rejects unknown cases without output"
else
  ok "fixture mutation helper rejects unknown cases without output"
fi

run_audit "$TMP/positive.json" "$DECLARATIONS" "$OBSERVATIONS"
check "positive system/user services and calendar/monotonic timers pass" '[[ "$RC" -eq 0 ]]'
check "audit pins the canonical v1 baseline identity and digest" 'ROOT="$ROOT" node --input-type=module - "$TMP/positive.json" "$BASELINE" <<'"'"'NODE'"'"'
import crypto from "node:crypto";
import fs from "node:fs";
const {canonicalJson}=await import(`${process.env.ROOT}/scripts/lib/maintenance-policy-contract.mjs`);
const [auditPath,baselinePath]=process.argv.slice(2);
const audit=JSON.parse(fs.readFileSync(auditPath,"utf8"));
const baseline=JSON.parse(fs.readFileSync(baselinePath,"utf8"));
const expected=`sha256:${crypto.createHash("sha256").update(canonicalJson(baseline)).digest("hex")}`;
if(audit.baseline_id!=="fleet-systemd-supervision"||audit.baseline_digest!==expected)process.exit(1);
NODE'
check "registry shape and sanitized Type classify six units" 'node -e '\''const x=require(process.argv[1]); if(x.summary.status!=="pass"||x.summary.unit_count!==6||new Set(x.units.map(u=>u.workload_shape)).size!==3||!x.units.some(u=>u.scope==="user"&&u.workload_shape==="timer"))process.exit(1)'\'' "$TMP/positive.json"'
check "fixture replay stamps its deterministic clock source" 'node -e '\''const x=require(process.argv[1]); if(x.evaluated_at_source!=="fixture-override"||x.evaluated_at!=="2026-08-02T12:00:00Z")process.exit(1)'\'' "$TMP/positive.json"'
check "terminal user handler passes without recursive OnFailure" 'node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="workshop-failure.service"); if(!u||u.status!=="pass"||u.workload_shape!=="oneshot")process.exit(1)'\'' "$TMP/positive.json"'
check "node-keyed notifier evidence is projected without a fleet scalar" 'node -e '\''const x=require(process.argv[1]); if(Object.hasOwn(x,"notifier")||x.notifiers.length!==1||x.notifiers[0].target_node_id!=="node-core"||x.notifiers[0].status!=="available")process.exit(1)'\'' "$TMP/positive.json"'
check "audit projection is content-blind and carries only stable node identity" 'node -e '\''const x=require(process.argv[1]); const raw=JSON.stringify(x); if(raw.includes("OnFailure")||raw.includes("directives")||raw.includes("failure_handler_role")||raw.includes("host"))process.exit(1); if(x.units.some(u=>!u.target_node_id||Object.hasOwn(u,"failure_target")))process.exit(1)'\'' "$TMP/positive.json"'
check "typed findings are deduplicated per unit" 'node -e '\''const x=require(process.argv[1]); for(const u of x.units)if(new Set(u.findings.map(JSON.stringify)).size!==u.findings.length)process.exit(1)'\'' "$TMP/positive.json"'

ROOT="$ROOT" POSITIVE_OUTPUT="$TMP/positive.json" node --input-type=module <<'NODE'
import fs from "node:fs";
const root = process.env.ROOT;
const { checkSchema, schemaErrors } = await import(`${root}/scripts/lib/maintenance-policy-contract.mjs`);
const schemas = {
  baseline: "docs/systemd-supervision-baseline-v1.schema.json",
  registry: "docs/grimnir-systemd-registry-input-v1.schema.json",
  declarations: "docs/systemd-unit-declarations-v1.schema.json",
  observations: "docs/systemd-supervision-observations-v1.schema.json",
  audit: "docs/systemd-supervision-audit-v1.schema.json",
};
for (const file of Object.values(schemas)) checkSchema(JSON.parse(fs.readFileSync(`${root}/${file}`, "utf8")));
const pairs = [
  [schemas.baseline, "docs/systemd-supervision-baseline-v1.json"],
  [schemas.registry, "tests/fixtures/systemd-supervision/registry.json"],
  [schemas.registry, "tests/fixtures/systemd-supervision/registry-bare.json"],
  [schemas.registry, "tests/fixtures/systemd-supervision/registry-repeated-name.json"],
  [schemas.declarations, "tests/fixtures/systemd-supervision/declarations-positive.json"],
  [schemas.declarations, "tests/fixtures/systemd-supervision/declarations-bare-registry.json"],
  [schemas.declarations, "tests/fixtures/systemd-supervision/declarations-repeated-name.json"],
  [schemas.observations, "tests/fixtures/systemd-supervision/observations-positive.json"],
  [schemas.observations, "tests/fixtures/systemd-supervision/observations-bare-registry.json"],
  [schemas.observations, "tests/fixtures/systemd-supervision/observations-repeated-name.json"],
  [schemas.audit, process.env.POSITIVE_OUTPUT],
];
for (const [schemaFile, valueFile] of pairs) {
  const errors = schemaErrors(JSON.parse(fs.readFileSync(`${root}/${schemaFile}`, "utf8")), JSON.parse(fs.readFileSync(valueFile, "utf8")));
  if (errors.length) throw new Error(`${schemaFile}: ${errors.join("; ")}`);
}
NODE
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
SCHEMA_RC=$?
check "all five published schemas validate positive and compatibility fixtures" '[[ "$SCHEMA_RC" -eq 0 ]]'

if [[ -n "${GRIMNIR_REGISTRY:-}" ]]; then
  ROOT="$ROOT" GRIMNIR_REGISTRY="$GRIMNIR_REGISTRY" node --input-type=module <<'NODE'
import fs from "node:fs";
const root = process.env.ROOT;
const { checkSchema, schemaErrors } = await import(`${root}/scripts/lib/maintenance-policy-contract.mjs`);
const schema = JSON.parse(fs.readFileSync(`${root}/docs/grimnir-systemd-registry-input-v1.schema.json`, "utf8"));
checkSchema(schema);
if (schemaErrors(schema, JSON.parse(fs.readFileSync(process.env.GRIMNIR_REGISTRY, "utf8"))).length) process.exit(1);
NODE
  # shellcheck disable=SC2034 # consumed by the fixed check expression below.
  GRIMNIR_RC=$?
  check "explicitly supplied Grimnir registry satisfies the adapter schema" '[[ "$GRIMNIR_RC" -eq 0 ]]'
fi

run_audit "$TMP/bare-registry.json" "$BARE_DECLARATIONS" "$BARE_OBSERVATIONS" "$BARE_REGISTRY"
check "representative bare Grimnir names normalize to canonical effective names" '[[ "$RC" -eq 0 ]]'
check "explicit and implicit timer targets resolve after normalization" 'node -e '\''const x=require(process.argv[1]); if(x.summary.unit_count!==5||x.units.some(u=>u.status!=="pass")||x.units.some(u=>!u.unit.endsWith(".service")&&!u.unit.endsWith(".timer")))process.exit(1)'\'' "$TMP/bare-registry.json"'
check "calendar and monotonic timer evidence remain distinct" 'node -e '\''const x=require(process.argv[1]); const c=x.units.find(u=>u.unit==="heimdall-collect.timer"),m=x.units.find(u=>u.unit==="heimdall-maintain.timer"); if(c.timer_class!=="calendar"||c.evidence.timer.persistent!==true||m.timer_class!=="monotonic"||m.evidence.timer.persistent!==null||m.evidence.timer.missed_runs!==null)process.exit(1)'\'' "$TMP/bare-registry.json"'

if make_case declarations-bare-registry.json declarations-bare-cases.json "$TMP/bare-unit-shared-name-declarations.json" bare-unit-shared-service-timer-name; then
  run_audit "$TMP/bare-unit-shared-name.json" "$TMP/bare-unit-shared-name-declarations.json" "$BARE_OBSERVATIONS" "$BARE_REGISTRY"
  check "bare timer Unit=name resolves name.service even when name.timer exists" '[[ "$RC" -eq 0 ]] && node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="nightly.timer"); if(!u||u.status!=="pass"||u.findings.some(f=>f.code.startsWith("timer_target")))process.exit(1)'\'' "$TMP/bare-unit-shared-name.json"'
else
  bad "bare shared-name fixture mutation succeeds"
fi

run_audit "$TMP/repeated-name.json" "$REPEATED_DECLARATIONS" "$REPEATED_OBSERVATIONS" "$REPEATED_REGISTRY"
check "same effective name across nodes and manager scopes is unambiguous" '[[ "$RC" -eq 0 ]] && node -e '\''const x=require(process.argv[1]); const s=x.units.filter(u=>u.unit==="shared.service"); if(s.length!==3||new Set(s.map(u=>`${u.target_node_id}:${u.scope}`)).size!==3)process.exit(1)'\'' "$TMP/repeated-name.json"'
check "multi-node notifier evidence remains node-specific" 'node -e '\''const x=require(process.argv[1]); if(x.notifiers.length!==2||x.notifiers.some(v=>v.status!=="available")||new Set(x.notifiers.map(v=>v.target_node_id)).size!==2)process.exit(1)'\'' "$TMP/repeated-name.json"'

for CASE_ID in node-beta-absent node-beta-null node-beta-missing; do
  if make_case observations-repeated-name.json observations-notifier-cases.json "$TMP/$CASE_ID-observations.json" "$CASE_ID"; then
    run_audit "$TMP/$CASE_ID.json" "$REPEATED_DECLARATIONS" "$TMP/$CASE_ID-observations.json" "$REPEATED_REGISTRY"
    check "$CASE_ID fails only the affected node's system unit" '[[ "$RC" -eq 1 ]] && assert_finding "$TMP/'"$CASE_ID"'.json" node-beta/system/shared.service failure_delivery_unavailable error substrate && node -e '\''const x=require(process.argv[1]); const alpha=x.units.find(v=>v.target_node_id==="node-alpha"&&v.scope==="system"),beta=x.units.find(v=>v.target_node_id==="node-beta"&&v.scope==="system"),n=x.notifiers.find(v=>v.target_node_id==="node-beta"); if(!alpha||!beta||alpha.status!=="pass"||beta.status!=="fail"||!n||n.status==="available"||x.summary.compliant_unit_count!==3)process.exit(1)'\'' "$TMP/'"$CASE_ID"'.json"'
  else
    bad "$CASE_ID fixture mutation succeeds"
  fi
done

if make_case observations-repeated-name.json observations-notifier-cases.json "$TMP/all-notifiers-null-observations.json" all-notifiers-null; then
  run_audit "$TMP/all-notifiers-null.json" "$REPEATED_DECLARATIONS" "$TMP/all-notifiers-null-observations.json" "$REPEATED_REGISTRY"
  check "null notifier collection projects unknown and fails each system node" '[[ "$RC" -eq 1 ]] && node -e '\''const x=require(process.argv[1]); const system=x.units.filter(v=>v.scope==="system"); if(x.notifiers.length!==2||x.notifiers.some(v=>v.status!=="unknown")||system.length!==2||system.some(v=>v.status!=="fail"||!v.findings.some(f=>f.code==="failure_delivery_unavailable"))||x.summary.compliant_unit_count!==2)process.exit(1)'\'' "$TMP/all-notifiers-null.json"'
else
  bad "all-notifiers-null fixture mutation succeeds"
fi

for CASE_ID in notifier-duplicate notifier-unknown-node; do
  if make_case observations-repeated-name.json observations-notifier-cases.json "$TMP/$CASE_ID-observations.json" "$CASE_ID"; then
    run_audit "$TMP/$CASE_ID.json" "$REPEATED_DECLARATIONS" "$TMP/$CASE_ID-observations.json" "$REPEATED_REGISTRY"
    check "$CASE_ID is hard-rejected without a record" '[[ "$RC" -eq 2 && ! -s "$TMP/'"$CASE_ID"'.json" ]]'
  else
    bad "$CASE_ID fixture mutation succeeds"
  fi
done

for CASE_ID in duplicate-effective wrong-suffix duplicate-component; do
  make_registry_case "$TMP/$CASE_ID-registry.json" "$CASE_ID"
  run_audit "$TMP/$CASE_ID.json" "$BARE_DECLARATIONS" "$BARE_OBSERVATIONS" "$TMP/$CASE_ID-registry.json"
  check "$CASE_ID registry identity is hard-rejected without a record" '[[ "$RC" -eq 2 && ! -s "$TMP/'"$CASE_ID"'.json" ]]'
done

expect_observation_finding restart-storm grimnir-api.service restart_storm
if make_case observations-positive.json observations-negative.json "$TMP/restart-pre-lockout-below-observations.json" restart-pre-lockout-below; then
  run_audit "$TMP/restart-pre-lockout-below.json" "$DECLARATIONS" "$TMP/restart-pre-lockout-below-observations.json"
  check "burst minus one remains below the conservative pre-lockout threshold" '[[ "$RC" -eq 0 ]] && ! grep -q '"'"'restart_storm'"'"' "$TMP/restart-pre-lockout-below.json"'
else
  bad "restart-pre-lockout-below fixture mutation succeeds"
fi
expect_observation_finding oom grimnir-api.service oom_kill_observed
expect_observation_finding missed-timer grimnir-worker.timer timer_persistence_observation_mismatch
expect_observation_finding missed-timer-warning grimnir-worker.timer timer_missed_runs warning
check "warning findings are nonzero and explicitly typed" 'node -e '\''const x=require(process.argv[1]); const f=x.findings.find(v=>v.code==="timer_missed_runs"); if(!f||f.severity!=="warning"||x.summary.status!=="fail")process.exit(1)'\'' "$TMP/missed-timer-warning.json"'
expect_observation_finding absent-notifier grimnir-api.service failure_delivery_unavailable
check "null notifier evidence projects unknown and fails every affected system unit" 'node -e '\''const x=require(process.argv[1]); const n=x.notifiers.find(v=>v.target_node_id==="node-core"); const affected=x.units.filter(v=>v.target_node_id==="node-core"&&v.scope==="system"); if(!n||n.status!=="unknown"||affected.length!==3||affected.some(v=>v.status!=="fail"||!v.findings.some(f=>f.code==="failure_delivery_unavailable")))process.exit(1)'\'' "$TMP/absent-notifier.json"'
expect_observation_finding missing-observation grimnir-api.service observation_missing
expect_observation_finding missing-restart-evidence grimnir-api.service restart_evidence_missing
expect_observation_finding missing-timer-evidence grimnir-worker.timer timer_evidence_missing
expect_observation_finding stale-audit grimnir-api.service evidence_stale
expect_observation_finding future-audit grimnir-api.service evidence_future
check "stale evidence fails every unit and compliant count" 'node -e '\''const x=require(process.argv[1]); if(x.summary.compliant_unit_count!==0||x.units.some(u=>u.status==="pass"))process.exit(1)'\'' "$TMP/stale-audit.json"'
check "future evidence fails every unit and compliant count" 'node -e '\''const x=require(process.argv[1]); if(x.summary.compliant_unit_count!==0||x.units.some(u=>u.status==="pass"))process.exit(1)'\'' "$TMP/future-audit.json"'
if make_case observations-positive.json observations-negative.json "$TMP/future-skew-inside-observations.json" future-skew-inside; then
  run_audit "$TMP/future-skew-inside.json" "$DECLARATIONS" "$TMP/future-skew-inside-observations.json"
  check "future skew just inside five seconds is fresh" '[[ "$RC" -eq 0 ]] && node -e '\''const x=require(process.argv[1]); if(x.freshness.status!=="fresh"||x.findings.some(f=>f.code==="audit_time_in_future"||f.code==="evidence_future"))process.exit(1)'\'' "$TMP/future-skew-inside.json"'
else
  bad "future-skew-inside fixture mutation succeeds"
fi
expect_observation_finding future-skew-outside grimnir-api.service evidence_future error substrate
check "future skew just outside five seconds is future" 'node -e '\''const x=require(process.argv[1]); if(x.freshness.status!=="future")process.exit(1)'\'' "$TMP/future-skew-outside.json"'
expect_observation_finding restart-window-mismatch grimnir-api.service restart_window_ancient
expect_observation_finding restart-window-end-mismatch grimnir-api.service restart_window_ancient
expect_observation_finding restart-window-contradictory grimnir-api.service restart_window_contradictory
expect_observation_finding timer-last-run-future grimnir-worker.timer timer_last_run_future
expect_observation_finding timer-last-run-ancient grimnir-worker.timer timer_last_run_ancient
expect_observation_finding timer-timestamps-contradictory grimnir-worker.timer timer_timestamp_contradictory
expect_observation_finding timer-next-run-absurd-future grimnir-worker.timer timer_next_run_future
expect_observation_finding timer-next-run-ancient grimnir-worker.timer timer_next_run_ancient
expect_observation_finding timer-overdue grimnir-worker.timer timer_overdue
if make_case observations-positive.json observations-negative.json "$TMP/timer-fresh-lag-observations.json" timer-fresh-lag; then
  run_audit "$TMP/timer-fresh-lag.json" "$DECLARATIONS" "$TMP/timer-fresh-lag-observations.json" "$REGISTRY" "$BASELINE" "2026-08-02T12:05:00Z"
  check "fresh lag cannot turn a future-at-snapshot timer into overdue" '[[ "$RC" -eq 0 ]] && ! grep -q '"'"'timer_overdue'"'"' "$TMP/timer-fresh-lag.json"'
else
  bad "timer-fresh-lag fixture mutation succeeds"
fi
expect_observation_finding timer-restart-contradiction grimnir-worker.timer restart_evidence_contradiction
expect_observation_finding watchdog-configured-not-requested grimnir-api.service watchdog_result_not_requested
expect_observation_finding watchdog-configured-unknown grimnir-api.service watchdog_result_unknown
expect_observation_finding watchdog-configured-timeout grimnir-api.service watchdog_timeout
expect_observation_finding watchdog-without-request workshop.service watchdog_observation_contradiction
expect_observation_finding watchdog-without-request-unknown workshop.service watchdog_observation_contradiction
expect_observation_finding watchdog-without-request-timeout workshop.service watchdog_observation_contradiction

node --input-type=module - "$BARE_OBSERVATIONS" "$TMP/monotonic-contradiction-observations.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(source, "utf8"));
value.units[2].timer.missed_runs = 1;
value.units[2].timer.persistent = true;
fs.writeFileSync(output, `${JSON.stringify(value, null, 2)}\n`);
NODE
run_audit "$TMP/monotonic-contradiction.json" "$BARE_DECLARATIONS" "$TMP/monotonic-contradiction-observations.json" "$BARE_REGISTRY"
check "monotonic timers reject calendar catch-up evidence" '[[ "$RC" -eq 1 ]] && grep -q '"'"'timer_missed_runs_evidence_contradiction'"'"' "$TMP/monotonic-contradiction.json" && grep -q '"'"'timer_persistence_evidence_contradiction'"'"' "$TMP/monotonic-contradiction.json"'

expect_declaration_finding unsafe-long-running grimnir-api.service restart_policy_unsafe
expect_declaration_finding watchdog-unsafe grimnir-api.service watchdog_unsafe
expect_declaration_finding watchdog-requires-notify grimnir-api.service watchdog_requires_notify error component-owner
expect_declaration_finding watchdog-heartbeat-unverified grimnir-api.service watchdog_heartbeat_unverified error component-owner
if make_case declarations-positive.json declarations-negative.json "$TMP/watchdog-notify-reload-declarations.json" watchdog-notify-reload; then
  run_audit "$TMP/watchdog-notify-reload.json" "$TMP/watchdog-notify-reload-declarations.json" "$OBSERVATIONS"
  check "Type=notify-reload satisfies negotiated watchdog type semantics" '[[ "$RC" -eq 0 ]] && ! grep -q '"'"'watchdog_requires_notify'"'"' "$TMP/watchdog-notify-reload.json"'
else
  bad "watchdog-notify-reload fixture mutation succeeds"
fi
expect_declaration_finding readiness-missing grimnir-api.service readiness_missing error component-owner
expect_declaration_finding heartbeat-missing grimnir-api.service heartbeat_missing error component-owner
expect_declaration_finding heartbeat-shape-contradiction grimnir-worker.service heartbeat_shape_contradiction error component-owner
expect_declaration_finding oom-continue grimnir-api.service oom_policy_unsafe
expect_declaration_finding contradictory-oneshot grimnir-worker.service restart_delay_forbidden
expect_declaration_finding system-wrong-target grimnir-api.service failure_delivery_target_unexpected
check "wrong system failure target is not misreported as missing" '! assert_finding "$TMP/system-wrong-target.json" grimnir-api.service failure_delivery_missing error substrate'
expect_declaration_finding user-system-delivery workshop.service scope_delivery_contradiction error component-owner
expect_declaration_finding user-failure-delivery-missing workshop.service failure_delivery_missing error component-owner
expect_declaration_finding user-failure-delivery-unregistered workshop.service failure_delivery_target_missing error component-owner

node --input-type=module - "$REGISTRY" "$DECLARATIONS" "$TMP/failure-owner-registry.json" "$TMP/failure-owner-declarations.json" <<'NODE'
import fs from "node:fs";
const [registryPath, declarationsPath, registryOutput, declarationsOutput] = process.argv.slice(2);
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
registry.components.push({ name: "outsider", target_node_id: "node-workshop", systemd_units: [{ name: "outsider-failure", type: "service", scope: "user" }] });
const declarations = JSON.parse(fs.readFileSync(declarationsPath, "utf8"));
declarations.units.find(unit => unit.name === "workshop.service").directives.OnFailure = "outsider-failure.service";
fs.writeFileSync(registryOutput, `${JSON.stringify(registry, null, 2)}\n`);
fs.writeFileSync(declarationsOutput, `${JSON.stringify(declarations, null, 2)}\n`);
NODE
run_audit "$TMP/failure-owner.json" "$TMP/failure-owner-declarations.json" "$OBSERVATIONS" "$TMP/failure-owner-registry.json"
check "user failure target must retain the owning component" '[[ "$RC" -eq 1 ]] && assert_finding "$TMP/failure-owner.json" workshop.service failure_delivery_target_mismatch error component-owner'

node --input-type=module - "$REGISTRY" "$DECLARATIONS" "$TMP/failure-scope-registry.json" "$TMP/failure-scope-declarations.json" <<'NODE'
import fs from "node:fs";
const [registryPath, declarationsPath, registryOutput, declarationsOutput] = process.argv.slice(2);
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
registry.components.find(component => component.name === "workshop").systemd_units.push({ name: "system-failure", type: "service", scope: "system" });
const declarations = JSON.parse(fs.readFileSync(declarationsPath, "utf8"));
declarations.units.find(unit => unit.name === "workshop.service").directives.OnFailure = "system-failure.service";
fs.writeFileSync(registryOutput, `${JSON.stringify(registry, null, 2)}\n`);
fs.writeFileSync(declarationsOutput, `${JSON.stringify(declarations, null, 2)}\n`);
NODE
run_audit "$TMP/failure-scope.json" "$TMP/failure-scope-declarations.json" "$OBSERVATIONS" "$TMP/failure-scope-registry.json"
check "user failure target must retain the manager scope" '[[ "$RC" -eq 1 ]] && assert_finding "$TMP/failure-scope.json" workshop.service failure_delivery_target_mismatch error component-owner'

node --input-type=module - "$REGISTRY" "$DECLARATIONS" "$OBSERVATIONS" "$TMP/substr-registry.json" "$TMP/substr-declarations.json" "$TMP/substr-observations.json" <<'NODE'
import fs from "node:fs";
const [registryPath, declarationsPath, observationsPath, registryOutput, declarationsOutput, observationsOutput] = process.argv.slice(2);
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
const component = registry.components.find(value => value.name === "workshop");
component.systemd_units.find(unit => unit.name === "workshop-failure.service").name = "workshop-brokkr-systemd-failure-local.service";
const declarations = JSON.parse(fs.readFileSync(declarationsPath, "utf8"));
for (const unit of declarations.units) {
  if (unit.directives.OnFailure === "workshop-failure.service") unit.directives.OnFailure = "workshop-brokkr-systemd-failure-local.service";
}
declarations.units.find(unit => unit.name === "workshop-failure.service").name = "workshop-brokkr-systemd-failure-local.service";
const observations = JSON.parse(fs.readFileSync(observationsPath, "utf8"));
observations.units.find(unit => unit.name === "workshop-failure.service").name = "workshop-brokkr-systemd-failure-local.service";
fs.writeFileSync(registryOutput, `${JSON.stringify(registry, null, 2)}\n`);
fs.writeFileSync(declarationsOutput, `${JSON.stringify(declarations, null, 2)}\n`);
fs.writeFileSync(observationsOutput, `${JSON.stringify(observations, null, 2)}\n`);
NODE
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
SUBSTRING_FIXTURE_RC=$?
run_audit "$TMP/substr.json" "$TMP/substr-declarations.json" "$TMP/substr-observations.json" "$TMP/substr-registry.json"
check "canonical system target comparison does not reject a legitimate user component substring" '[[ "$SUBSTRING_FIXTURE_RC" -eq 0 && "$RC" -eq 0 ]] && ! grep -q '"'"'scope_delivery_contradiction'"'"' "$TMP/substr.json"'

node --input-type=module - "$DECLARATIONS" "$TMP/failure-undeclared-declarations.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const declarations = JSON.parse(fs.readFileSync(source, "utf8"));
declarations.units = declarations.units.filter(unit => unit.name !== "workshop-failure.service");
fs.writeFileSync(output, `${JSON.stringify(declarations, null, 2)}\n`);
NODE
run_audit "$TMP/failure-undeclared.json" "$TMP/failure-undeclared-declarations.json" "$OBSERVATIONS"
check "registered target without a terminal declaration cannot gain trust" '[[ "$RC" -eq 1 ]] && assert_finding "$TMP/failure-undeclared.json" workshop.service failure_delivery_target_undeclared error component-owner'

node --input-type=module - "$DECLARATIONS" "$TMP/missing-service-declaration.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const declarations = JSON.parse(fs.readFileSync(source, "utf8"));
declarations.units = declarations.units.filter(unit => unit.name !== "grimnir-api.service");
fs.writeFileSync(output, `${JSON.stringify(declarations, null, 2)}\n`);
NODE
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
MISSING_DECLARATION_FIXTURE_RC=$?
run_audit "$TMP/missing-service-declaration-audit.json" "$TMP/missing-service-declaration.json" "$OBSERVATIONS"
check "missing service declaration keeps workload shape unknown without invented health failures" '[[ "$MISSING_DECLARATION_FIXTURE_RC" -eq 0 && "$RC" -eq 1 ]] && node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="grimnir-api.service"); if(!u||u.workload_shape!=="unknown"||u.findings.length!==1||u.findings[0].code!=="declaration_missing")process.exit(1)'\'' "$TMP/missing-service-declaration-audit.json"'

expect_declaration_finding system-failure-delivery-repeated grimnir-api.service failure_delivery_duplicate
expect_declaration_finding duplicate-user-failure-target workshop.service failure_delivery_duplicate error component-owner
expect_declaration_finding user-failure-self-target workshop.service failure_delivery_self_target error component-owner
check "self-target also exposes the finite-graph cycle" 'assert_finding "$TMP/user-failure-self-target.json" workshop.service failure_delivery_cycle error component-owner'
expect_declaration_finding user-failure-nonterminal-target workshop.service failure_delivery_target_nonterminal error component-owner
expect_declaration_finding user-failure-cycle workshop.service failure_delivery_cycle error component-owner
expect_declaration_finding terminal-failure-delivery workshop-failure.service terminal_failure_handler_delivery_forbidden error component-owner
expect_declaration_finding terminal-failure-wrong-type workshop-failure.service terminal_failure_handler_type_unsafe error component-owner
check "normal user service also fails when its terminal target is invalid" 'assert_finding "$TMP/terminal-failure-wrong-type.json" workshop.service failure_delivery_target_terminal_invalid error component-owner'
expect_declaration_finding timer-only-terminal-reference workshop.service failure_delivery_missing error component-owner
check "a valid timer-only inbound edge keeps the terminal handler referenced" 'node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="workshop-failure.service"); if(!u||u.status!=="pass"||u.findings.some(f=>f.code==="terminal_handler_unreferenced"))process.exit(1)'\'' "$TMP/timer-only-terminal-reference.json"'
expect_declaration_finding orphan-terminal workshop-failure.service terminal_handler_unreferenced error component-owner
expect_declaration_finding all-services-terminal workshop.service terminal_handler_unreferenced error component-owner
check "all-terminal fixture rejects the second orphan terminal too" 'assert_finding "$TMP/all-services-terminal.json" workshop-failure.service terminal_handler_unreferenced error component-owner'
expect_declaration_finding terminal-role-system-scope grimnir-api.service failure_handler_role_scope_contradiction
expect_declaration_finding terminal-role-timer workshop.timer failure_handler_role_timer_contradiction
check "timer role contradiction does not over-fire terminal-service findings" 'node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="workshop.timer"); if(!u||u.findings.length!==1||u.findings[0].code!=="failure_handler_role_timer_contradiction")process.exit(1)'\'' "$TMP/terminal-role-timer.json"'
expect_declaration_finding timer-calendar-false grimnir-worker.timer timer_schedule_value_unsafe
expect_declaration_finding timer-calendar-blank grimnir-worker.timer timer_schedule_value_unsafe
expect_declaration_finding timer-monotonic-false workshop.timer timer_schedule_value_unsafe
expect_declaration_finding timer-service-directive grimnir-worker.timer timer_service_directive_forbidden
expect_declaration_finding timer-calendar-monotonic-mixed grimnir-worker.timer timer_schedule_mixed
expect_declaration_finding timer-wrong-owner grimnir-worker.timer timer_target_mismatch
expect_declaration_finding timer-target-terminal workshop.timer timer_target_terminal_handler
expect_declaration_finding user-timer-wrong-scope workshop.timer timer_target_mismatch
expect_declaration_finding timer-persistence grimnir-worker.timer timer_not_persistent
expect_declaration_finding timer-start-limit-missing grimnir-worker.timer start_limit_burst_missing
expect_declaration_finding timer-start-limit-unsafe grimnir-worker.timer start_limit_interval_unsafe
expect_declaration_finding timer-wrong-failure-target grimnir-worker.timer failure_delivery_target_unexpected
expect_declaration_finding user-timer-failure-missing workshop.timer failure_delivery_missing error component-owner

if ! make_case observations-positive.json observations-negative.json "$TMP/restart-storm-for-invalid-burst.json" restart-storm; then bad "restart-storm fixture mutation succeeds"; fi
expect_declaration_finding invalid-burst grimnir-api.service start_limit_burst_unsafe error substrate "$TMP/restart-storm-for-invalid-burst.json"
check "invalid burst never coerces to zero or emits a false restart storm" '! grep -q '"'"'restart_storm'"'"' "$TMP/invalid-burst.json"'

expect_malformed_declaration fractional-duration
expect_malformed_declaration compound-duration
expect_malformed_declaration persistent-string
expect_malformed_declaration timer-unit-crlf "Injected=yes"
expect_malformed_declaration user-failure-delivery-unsafe "private path"
expect_malformed_declaration unsupported-failure-target-type
expect_malformed_declaration failure-target-array-too-long
expect_malformed_declaration unsupported-content "private content"
expect_malformed_declaration record-extension
expect_malformed_declaration rogue-unit

node --input-type=module - "$BASELINE" "$TMP/baseline-extension.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(source, "utf8"));
value.extensions = [{ unsafe: true }];
fs.writeFileSync(output, `${JSON.stringify(value, null, 2)}\n`);
NODE
run_audit "$TMP/baseline-extension-output.json" "$DECLARATIONS" "$OBSERVATIONS" "$REGISTRY" "$TMP/baseline-extension.json"
check "nonempty baseline extensions are malformed and emit no record" '[[ "$RC" -eq 2 && ! -s "$TMP/baseline-extension-output.json" ]]'

if make_baseline_case "$TMP/weakened-baseline.json" schema-valid-weakened-baseline; then
  ROOT="$ROOT" node --input-type=module - "$TMP/weakened-baseline.json" <<'NODE'
import fs from "node:fs";
const {checkSchema,schemaErrors}=await import(`${process.env.ROOT}/scripts/lib/maintenance-policy-contract.mjs`);
const schema=JSON.parse(fs.readFileSync(`${process.env.ROOT}/docs/systemd-supervision-baseline-v1.schema.json`,"utf8"));
const candidate=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
checkSchema(schema);
if(schemaErrors(schema,candidate).length!==0)process.exit(1);
NODE
  # shellcheck disable=SC2034 # consumed by the fixed check expression below.
  WEAKENED_SCHEMA_RC=$?
  run_audit "$TMP/weakened-baseline-output.json" "$DECLARATIONS" "$OBSERVATIONS" "$REGISTRY" "$TMP/weakened-baseline.json"
  check "schema-valid policy drift is rejected against tracked canonical content" '[[ "$WEAKENED_SCHEMA_RC" -eq 0 && "$RC" -eq 2 && ! -s "$TMP/weakened-baseline-output.json" && "$(<"$TMP/weakened-baseline-output.json.stderr")" == "systemd-supervision-audit: rejected" ]]'
else
  bad "schema-valid weakened-baseline fixture mutation succeeds"
fi

node --input-type=module - "$REGISTRY" "$TMP/too-many-components.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(source, "utf8"));
while (value.components.length <= 128) value.components.push({ name: `extra-${String(value.components.length).padStart(3, "0")}` });
fs.writeFileSync(output, `${JSON.stringify(value)}\n`);
NODE
run_audit "$TMP/too-many-components-output.json" "$DECLARATIONS" "$OBSERVATIONS" "$TMP/too-many-components.json"
check "component cardinality bound rejects oversized registry with no record" '[[ "$RC" -eq 2 && ! -s "$TMP/too-many-components-output.json" ]]'

node --input-type=module - "$TMP/oversized-declarations.json" <<'NODE'
import fs from "node:fs";
fs.writeFileSync(process.argv[2], `{"padding":"${"x".repeat(1024 * 1024)}"}\n`);
NODE
run_audit "$TMP/oversized-output.json" "$TMP/oversized-declarations.json" "$OBSERVATIONS"
check "byte bound rejects oversized declaration input with no record" '[[ "$RC" -eq 2 && ! -s "$TMP/oversized-output.json" ]]'

node "$AUDIT" --baseline "$BASELINE" --registry "$REGISTRY" --declarations "$DECLARATIONS" --observations "$OBSERVATIONS" >"$TMP/clock.json" 2>"$TMP/clock.json.stderr"
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
CLOCK_RC=$?
check "production clock source is valid independently of fixture age" '[[ "$CLOCK_RC" -eq 0 || "$CLOCK_RC" -eq 1 ]] && [[ -s "$TMP/clock.json" ]] && node -e '\''const x=require(process.argv[1]); const d=new Date(x.evaluated_at); if(x.evaluated_at_source!=="clock"||Number.isNaN(d.getTime())||d.toISOString().replace(".000Z","Z")!==x.evaluated_at)process.exit(1)'\'' "$TMP/clock.json"'

node "$AUDIT" --baseline "$BASELINE" --registry "$REGISTRY" --declarations "$DECLARATIONS" --observations "$OBSERVATIONS" --now "$NOW" >"$TMP/replay-without-opt-in.json" 2>"$TMP/replay-without-opt-in.json.stderr"
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
REPLAY_WITHOUT_OPT_IN_RC=$?
check "--now is rejected without the explicit replay opt-in" '[[ "$REPLAY_WITHOUT_OPT_IN_RC" -eq 2 && ! -s "$TMP/replay-without-opt-in.json" && "$(<"$TMP/replay-without-opt-in.json.stderr")" == "systemd-supervision-audit: rejected" ]]'

BROKKR_SYSTEMD_AUDIT_ALLOW_REPLAY=1 node "$AUDIT" --baseline "$BASELINE" --registry "$REGISTRY" --declarations "$DECLARATIONS" --observations "$OBSERVATIONS" --now malformed >"$TMP/malformed-now.json" 2>"$TMP/malformed-now.json.stderr"
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
MALFORMED_NOW_RC=$?
check "malformed replay time is a content-blind exit 2 with no record" '[[ "$MALFORMED_NOW_RC" -eq 2 && ! -s "$TMP/malformed-now.json" && "$(<"$TMP/malformed-now.json.stderr")" == "systemd-supervision-audit: rejected" ]]'

ROOT="$ROOT" AUDIT="$AUDIT" node --input-type=module - "$TMP/throwing-audit.mjs" <<'NODE'
import fs from "node:fs";
const output = process.argv[2];
let source = fs.readFileSync(process.env.AUDIT, "utf8");
source = source.replace('"./lib/maintenance-policy-contract.mjs"', `"file://${process.env.ROOT}/scripts/lib/maintenance-policy-contract.mjs"`);
const marker = "function main() {";
if (!source.includes(marker)) throw new Error("top-level main boundary missing");
source = source.replace(marker, `${marker}\n  throw new Error("private-exception-marker");`);
fs.writeFileSync(output, source);
NODE
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
THROWING_FIXTURE_RC=$?
BROKKR_SYSTEMD_AUDIT_ALLOW_REPLAY=1 node "$TMP/throwing-audit.mjs" --baseline "$BASELINE" --registry "$REGISTRY" --declarations "$DECLARATIONS" --observations "$OBSERVATIONS" --now "$NOW" >"$TMP/throwing-audit.json" 2>"$TMP/throwing-audit.json.stderr"
# shellcheck disable=SC2034 # consumed by the fixed check expression below.
THROWING_AUDIT_RC=$?
check "unexpected exceptions cross one constant content-blind exit-2 boundary" '[[ "$THROWING_FIXTURE_RC" -eq 0 && "$THROWING_AUDIT_RC" -eq 2 && ! -s "$TMP/throwing-audit.json" && "$(<"$TMP/throwing-audit.json.stderr")" == "systemd-supervision-audit: rejected" ]] && ! grep -q '"'"'private-exception-marker\|Error:\| at '"'"' "$TMP/throwing-audit.json.stderr"'

check "audit source has one unit status key and no external-command surface" 'SOURCE="$AUDIT" node --input-type=module <<'"'"'NODE'"'"'
import fs from "node:fs";
const source=fs.readFileSync(process.env.SOURCE,"utf8");
const imports=[...source.matchAll(/from\s+"([^"]+)"/g)].map(match=>match[1]);
const allowedImports=new Set(["node:crypto","node:fs","node:path","node:url","./lib/maintenance-policy-contract.mjs"]);
if(imports.some(specifier=>!allowedImports.has(specifier))||new Set(imports).size!==allowedImports.size)process.exit(1);
const start=source.indexOf("const output = {");
const end=source.indexOf("unitOutputs.push(output)",start);
const body=source.slice(start,end);
if((body.match(/\n\s+status:/g)??[]).length!==1)process.exit(1);
if((source.match(/"heartbeat_missing"/g)??[]).length!==1)process.exit(1);
const forbiddenModule=/"(?:node:)?(?:child_process|http|https|http2|net|tls|dgram|dns|undici|worker_threads|cluster|quic)(?:\/[^" ]*)?"/;
const forbiddenBareChildApi=/(?<![.\w])(?:spawn|spawnSync|exec|execSync|execFile|execFileSync|fork)\s*\(/;
const forbiddenExternalApi=/\b(?:fetch|XMLHttpRequest|WebSocket|writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|truncate|truncateSync|rm|rmSync|unlink|unlinkSync|rename|renameSync|copyFile|copyFileSync|mkdir|mkdirSync|rmdir|rmdirSync|mkdtemp|mkdtempSync|chmod|chmodSync|chown|chownSync|link|linkSync|symlink|symlinkSync)\s*\(/;
if(forbiddenModule.test(source)||forbiddenBareChildApi.test(source)||forbiddenExternalApi.test(source))process.exit(1);
NODE'

check "shared schema helper enforces maxLength" 'ROOT="$ROOT" node --input-type=module <<'"'"'NODE'"'"'
const {checkSchema,schemaErrors}=await import(`${process.env.ROOT}/scripts/lib/maintenance-policy-contract.mjs`);
const schema={type:"string",maxLength:3};
checkSchema(schema);
if(schemaErrors(schema,"abc").length!==0||schemaErrors(schema,"abcd").length===0)process.exit(1);
NODE'

check "published schemas expose conservative input/output cardinality bounds" 'ROOT="$ROOT" node --input-type=module <<'"'"'NODE'"'"'
import fs from "node:fs";
const load=p=>JSON.parse(fs.readFileSync(`${process.env.ROOT}/${p}`,"utf8"));
const r=load("docs/grimnir-systemd-registry-input-v1.schema.json");
const d=load("docs/systemd-unit-declarations-v1.schema.json");
const o=load("docs/systemd-supervision-observations-v1.schema.json");
const a=load("docs/systemd-supervision-audit-v1.schema.json");
if(r.properties.components.maxItems!==128||r.$defs.component.properties.systemd_units.maxItems!==32||d.properties.units.maxItems!==512||o.properties.units.maxItems!==512||a.properties.units.maxItems!==512||a.properties.findings.maxItems!==4096)process.exit(1);
NODE'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
