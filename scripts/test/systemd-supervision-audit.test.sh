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
  local output="$1" declarations="$2" observations="$3" registry="${4:-$REGISTRY}" baseline="${5:-$BASELINE}"
  node "$AUDIT" --baseline "$baseline" --registry "$registry" --declarations "$declarations" --observations "$observations" --now "$NOW" >"$output" 2>"$output.stderr"
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
for (const [mutationPath, value] of Object.entries(candidate.mutations)) {
  const parts = mutationPath.split(".");
  let target = base;
  for (const part of parts.slice(0, -1)) target = target[part];
  if (value && typeof value === "object" && !Array.isArray(value) && value.$delete === true) delete target[parts.at(-1)];
  else target[parts.at(-1)] = value;
}
fs.writeFileSync(outputPath, `${JSON.stringify(base, null, 2)}\n`);
NODE
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

expect_observation_finding() {
  local case_id="$1" code="$2"
  make_case observations-positive.json observations-negative.json "$TMP/$case_id-observations.json" "$case_id"
  run_audit "$TMP/$case_id.json" "$DECLARATIONS" "$TMP/$case_id-observations.json"
  if [[ "$RC" -eq 1 && -s "$TMP/$case_id.json" ]] && grep -q "\"code\": \"$code\"" "$TMP/$case_id.json"; then ok "$case_id emits $code (exit 1)"; else bad "$case_id emits $code (exit 1)"; fi
}

expect_declaration_finding() {
  local case_id="$1" code="$2" observations="${3:-$OBSERVATIONS}"
  make_case declarations-positive.json declarations-negative.json "$TMP/$case_id-declarations.json" "$case_id"
  run_audit "$TMP/$case_id.json" "$TMP/$case_id-declarations.json" "$observations"
  if [[ "$RC" -eq 1 && -s "$TMP/$case_id.json" ]] && grep -q "\"code\": \"$code\"" "$TMP/$case_id.json"; then ok "$case_id emits $code (exit 1)"; else bad "$case_id emits $code (exit 1)"; fi
}

expect_malformed_declaration() {
  local case_id="$1" marker="${2:-}"
  make_case declarations-positive.json declarations-negative.json "$TMP/$case_id-declarations.json" "$case_id"
  run_audit "$TMP/$case_id.json" "$TMP/$case_id-declarations.json" "$OBSERVATIONS"
  if [[ "$RC" -eq 2 && ! -s "$TMP/$case_id.json" ]] && { [[ -z "$marker" ]] || ! grep -q "$marker" "$TMP/$case_id.json.stderr"; }; then ok "$case_id is malformed, content-blind, and emits no record (exit 2)"; else bad "$case_id is malformed, content-blind, and emits no record (exit 2)"; fi
}

echo "systemd-supervision-audit.test.sh"

run_audit "$TMP/positive.json" "$DECLARATIONS" "$OBSERVATIONS"
check "positive system/user services and calendar/monotonic timers pass" '[[ "$RC" -eq 0 ]]'
check "registry shape and sanitized Type classify six units" 'node -e '\''const x=require(process.argv[1]); if(x.summary.status!=="pass"||x.summary.unit_count!==6||new Set(x.units.map(u=>u.workload_shape)).size!==3||!x.units.some(u=>u.scope==="user"&&u.workload_shape==="timer"))process.exit(1)'\'' "$TMP/positive.json"'
check "fixture replay stamps its deterministic clock source" 'node -e '\''const x=require(process.argv[1]); if(x.evaluated_at_source!=="fixture-override"||x.evaluated_at!=="2026-08-02T12:00:00Z")process.exit(1)'\'' "$TMP/positive.json"'
check "terminal user handler passes without recursive OnFailure" 'node -e '\''const x=require(process.argv[1]); const u=x.units.find(v=>v.unit==="workshop-failure.service"); if(!u||u.status!=="pass"||u.workload_shape!=="oneshot")process.exit(1)'\'' "$TMP/positive.json"'
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

run_audit "$TMP/repeated-name.json" "$REPEATED_DECLARATIONS" "$REPEATED_OBSERVATIONS" "$REPEATED_REGISTRY"
check "same effective name across nodes and manager scopes is unambiguous" '[[ "$RC" -eq 0 ]] && node -e '\''const x=require(process.argv[1]); const s=x.units.filter(u=>u.unit==="shared.service"); if(s.length!==3||new Set(s.map(u=>`${u.target_node_id}:${u.scope}`)).size!==3)process.exit(1)'\'' "$TMP/repeated-name.json"'

for CASE_ID in duplicate-effective wrong-suffix duplicate-component; do
  make_registry_case "$TMP/$CASE_ID-registry.json" "$CASE_ID"
  run_audit "$TMP/$CASE_ID.json" "$BARE_DECLARATIONS" "$BARE_OBSERVATIONS" "$TMP/$CASE_ID-registry.json"
  check "$CASE_ID registry identity is hard-rejected without a record" '[[ "$RC" -eq 2 && ! -s "$TMP/'"$CASE_ID"'.json" ]]'
done

expect_observation_finding restart-storm restart_storm
expect_observation_finding oom oom_kill_observed
expect_observation_finding missed-timer timer_persistence_observation_mismatch
expect_observation_finding missed-timer-warning timer_missed_runs
check "warning findings are nonzero and explicitly typed" 'node -e '\''const x=require(process.argv[1]); const f=x.findings.find(v=>v.code==="timer_missed_runs"); if(!f||f.severity!=="warning"||x.summary.status!=="fail")process.exit(1)'\'' "$TMP/missed-timer-warning.json"'
expect_observation_finding absent-notifier failure_delivery_unavailable
expect_observation_finding stale-audit evidence_stale
expect_observation_finding future-audit evidence_future
check "stale evidence fails every unit and compliant count" 'node -e '\''const x=require(process.argv[1]); if(x.summary.compliant_unit_count!==0||x.units.some(u=>u.status==="pass"))process.exit(1)'\'' "$TMP/stale-audit.json"'
check "future evidence fails every unit and compliant count" 'node -e '\''const x=require(process.argv[1]); if(x.summary.compliant_unit_count!==0||x.units.some(u=>u.status==="pass"))process.exit(1)'\'' "$TMP/future-audit.json"'
expect_observation_finding restart-window-mismatch restart_window_ancient
expect_observation_finding restart-window-end-mismatch restart_window_ancient
expect_observation_finding restart-window-contradictory restart_window_contradictory
expect_observation_finding timer-last-run-future timer_last_run_future
expect_observation_finding timer-last-run-ancient timer_last_run_ancient
expect_observation_finding timer-timestamps-contradictory timer_timestamp_contradictory
expect_observation_finding timer-next-run-absurd-future timer_next_run_future
expect_observation_finding timer-next-run-ancient timer_next_run_ancient
expect_observation_finding timer-overdue timer_overdue
expect_observation_finding timer-restart-contradiction restart_evidence_contradiction
expect_observation_finding watchdog-configured-not-requested watchdog_result_not_requested
expect_observation_finding watchdog-configured-unknown watchdog_result_unknown
expect_observation_finding watchdog-configured-timeout watchdog_timeout
expect_observation_finding watchdog-without-request watchdog_observation_contradiction
expect_observation_finding watchdog-without-request-unknown watchdog_observation_contradiction
expect_observation_finding watchdog-without-request-timeout watchdog_observation_contradiction

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

expect_declaration_finding unsafe-long-running restart_policy_unsafe
expect_declaration_finding oom-continue oom_policy_unsafe
expect_declaration_finding contradictory-oneshot restart_delay_forbidden
expect_declaration_finding system-wrong-target failure_delivery_missing
expect_declaration_finding user-system-delivery scope_delivery_contradiction
expect_declaration_finding user-failure-delivery-missing failure_delivery_missing
expect_declaration_finding user-failure-delivery-unregistered failure_delivery_target_missing

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
check "user failure target must retain the owning component" '[[ "$RC" -eq 1 ]] && grep -q '"'"'failure_delivery_target_mismatch'"'"' "$TMP/failure-owner.json"'

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
check "user failure target must retain the manager scope" '[[ "$RC" -eq 1 ]] && grep -q '"'"'failure_delivery_target_mismatch'"'"' "$TMP/failure-scope.json"'

node --input-type=module - "$DECLARATIONS" "$TMP/failure-undeclared-declarations.json" <<'NODE'
import fs from "node:fs";
const [source, output] = process.argv.slice(2);
const declarations = JSON.parse(fs.readFileSync(source, "utf8"));
declarations.units = declarations.units.filter(unit => unit.name !== "workshop-failure.service");
fs.writeFileSync(output, `${JSON.stringify(declarations, null, 2)}\n`);
NODE
run_audit "$TMP/failure-undeclared.json" "$TMP/failure-undeclared-declarations.json" "$OBSERVATIONS"
check "registered target without a terminal declaration cannot gain trust" '[[ "$RC" -eq 1 ]] && grep -q '"'"'failure_delivery_target_undeclared'"'"' "$TMP/failure-undeclared.json"'

expect_declaration_finding system-failure-delivery-repeated failure_delivery_duplicate
expect_declaration_finding duplicate-user-failure-target failure_delivery_duplicate
expect_declaration_finding user-failure-self-target failure_delivery_self_target
check "self-target also exposes the finite-graph cycle" 'grep -q '"'"'failure_delivery_cycle'"'"' "$TMP/user-failure-self-target.json"'
expect_declaration_finding user-failure-nonterminal-target failure_delivery_target_nonterminal
expect_declaration_finding user-failure-cycle failure_delivery_cycle
expect_declaration_finding terminal-failure-delivery terminal_failure_handler_delivery_forbidden
expect_declaration_finding terminal-failure-wrong-type terminal_failure_handler_type_unsafe
check "normal user service also fails when its terminal target is invalid" 'grep -q '"'"'failure_delivery_target_terminal_invalid'"'"' "$TMP/terminal-failure-wrong-type.json"'
expect_declaration_finding terminal-role-system-scope failure_handler_role_scope_contradiction
expect_declaration_finding terminal-role-timer failure_handler_role_timer_contradiction
expect_declaration_finding timer-calendar-false timer_schedule_value_unsafe
expect_declaration_finding timer-calendar-blank timer_schedule_value_unsafe
expect_declaration_finding timer-monotonic-false timer_schedule_value_unsafe
expect_declaration_finding timer-service-directive timer_service_directive_forbidden
expect_declaration_finding timer-calendar-monotonic-mixed timer_schedule_mixed
expect_declaration_finding timer-wrong-owner timer_target_mismatch
expect_declaration_finding timer-target-terminal timer_target_terminal_handler
expect_declaration_finding user-timer-wrong-scope timer_target_mismatch
expect_declaration_finding timer-persistence timer_not_persistent

make_case observations-positive.json observations-negative.json "$TMP/restart-storm-for-invalid-burst.json" restart-storm
expect_declaration_finding invalid-burst start_limit_burst_unsafe "$TMP/restart-storm-for-invalid-burst.json"
check "invalid burst never coerces to zero or emits a false restart storm" '! grep -q '"'"'restart_storm'"'"' "$TMP/invalid-burst.json"'

expect_malformed_declaration fractional-duration
expect_malformed_declaration compound-duration
expect_malformed_declaration persistent-string
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
check "production invocation defaults to the real clock and stamps its source" '[[ "$CLOCK_RC" -eq 1 && -s "$TMP/clock.json" ]] && node -e '\''const x=require(process.argv[1]); if(x.evaluated_at_source!=="clock"||x.evaluated_at==="2026-08-02T12:00:00Z")process.exit(1)'\'' "$TMP/clock.json"'

check "audit source has one unit status key and no external-command surface" 'SOURCE="$AUDIT" node --input-type=module <<'"'"'NODE'"'"'
import fs from "node:fs";
const source=fs.readFileSync(process.env.SOURCE,"utf8");
const start=source.indexOf("const output = {");
const end=source.indexOf("unitOutputs.push(output)",start);
const body=source.slice(start,end);
if((body.match(/\n\s+status:/g)??[]).length!==1)process.exit(1);
if(/node:(?:child_process|http|https|net)|\b(?:fetch|spawn|execFile|writeFileSync)\b/.test(source))process.exit(1);
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
