#!/usr/bin/env node
// Read-only systemd supervision audit for brokkr#98.
//
// Grimnir remains the only topology authority. Brokkr consumes only the stable
// target_node_id/scope/effective-unit join key plus sanitized declarations and
// content-blind observations. This program never invokes systemctl, executes a
// child process, writes a unit, enables a timer, or delivers a notification.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkSchema, schemaErrors } from "./lib/maintenance-policy-contract.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const UNIT_BASE_NAME = /^(?!.*[\r\n])[A-Za-z0-9:_.@-]+$/;
const UNIT_NAME = /^(?!.*[\r\n])[A-Za-z0-9:_.@-]+\.(?:service|timer)$/;
const USER_FAILURE_TARGET = /^(?!.*[\r\n%])[A-Za-z0-9:_.@-]+\.service$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const SCOPES = new Set(["system", "user"]);
const CANONICAL_FAILURE_TARGET = "brokkr-systemd-failure@%n.service";
const TIMER_SCHEDULE_DIRECTIVES = ["OnCalendar", "OnBootSec", "OnStartupSec", "OnUnitActiveSec", "OnUnitInactiveSec"];
const TIMER_SERVICE_DIRECTIVES = ["Type", "Restart", "RestartSec", "StartLimitIntervalSec", "StartLimitBurst", "TimeoutStartSec", "TimeoutStopSec", "RuntimeMaxSec", "OOMPolicy", "OnFailure", "WatchdogSec"];
const SERVICE_TIMER_DIRECTIVES = ["Unit", ...TIMER_SCHEDULE_DIRECTIVES, "Persistent", "AccuracySec"];
const REQUIRED_OBSERVATION_FIELDS = ["unit_result", "restart_count_window", "watchdog_result", "oom_result", "timer_last_next_run", "audit_freshness"];
const MAX_TOTAL_UNITS = 512;
const MAX_DIRECTIVES = 20;
const MAX_UNIT_FINDINGS = 64;
const MAX_FINDINGS = 4096;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const INPUT_LIMITS = Object.freeze({ baseline: 64 * 1024, registry: 1024 * 1024, declarations: 1024 * 1024, observations: 2 * 1024 * 1024 });
const SCHEMA_PATHS = Object.freeze({
  baseline: "docs/systemd-supervision-baseline-v1.schema.json",
  registry: "docs/grimnir-systemd-registry-input-v1.schema.json",
  declarations: "docs/systemd-unit-declarations-v1.schema.json",
  observations: "docs/systemd-supervision-observations-v1.schema.json",
  audit: "docs/systemd-supervision-audit-v1.schema.json",
});

const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const has = (value, key) => plain(value) && Object.hasOwn(value, key);
const id = value => typeof value === "string" && ID.test(value);
const utc = value => {
  if (typeof value !== "string" || !UTC.test(value)) return false;
  const instant = new Date(value);
  return !Number.isNaN(instant.getTime()) && instant.toISOString().replace(".000Z", "Z") === value;
};
const die = message => {
  process.stderr.write(`systemd-supervision-audit: ${message}\n`);
  process.exit(2);
};
const usage = () => die("usage: systemd-supervision-audit.mjs --baseline file --registry file --declarations file --observations file [--now UTC-fixture-override]");
const unitKey = (targetNodeId, scope, unit) => `${targetNodeId}\u0000${scope}\u0000${unit}`;
const clockNow = () => new Date(Math.floor(Date.now() / 1000) * 1000).toISOString().replace(".000Z", "Z");

function parseArgs(argv) {
  const parsed = {};
  const allowed = new Set(["--baseline", "--registry", "--declarations", "--observations", "--now"]);
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!allowed.has(key) || has(parsed, key.slice(2))) usage();
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) usage();
    parsed[key.slice(2)] = value;
    index += 1;
  }
  for (const field of ["baseline", "registry", "declarations", "observations"]) if (!has(parsed, field)) usage();
  if (Object.keys(parsed).some(field => !["baseline", "registry", "declarations", "observations", "now"].includes(field))) usage();
  if (has(parsed, "now") && !utc(parsed.now)) usage();
  return {
    ...parsed,
    evaluatedAt: parsed.now ?? clockNow(),
    evaluatedAtSource: has(parsed, "now") ? "fixture-override" : "clock",
  };
}

function readJsonBounded(file, label) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    die(`cannot read ${label} JSON`);
  }
  if (!stat.isFile() || stat.size < 2 || stat.size > INPUT_LIMITS[label]) die(`invalid ${label} input size`);
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    die(`cannot read ${label} JSON`);
  }
}

function loadSchemas() {
  const schemas = {};
  for (const [name, relative] of Object.entries(SCHEMA_PATHS)) {
    try {
      schemas[name] = JSON.parse(fs.readFileSync(path.join(ROOT, relative), "utf8"));
      checkSchema(schemas[name]);
    } catch {
      die(`invalid tracked ${name} schema`);
    }
  }
  return schemas;
}

function validateAgainstSchema(schema, value, label) {
  if (schemaErrors(schema, value).length > 0) die(`${label} does not satisfy the v1 schema`);
}

function assertInteger(value, label, min = 0, max = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < min || value > max) die(`invalid ${label}`);
}

function validateBound(policy, label) {
  if (!plain(policy) || typeof policy.required !== "boolean") die(`invalid ${label}`);
  assertInteger(policy.min_seconds, `${label} minimum`, 0, 31536000);
  assertInteger(policy.max_seconds, `${label} maximum`, 0, 31536000);
  if (policy.min_seconds > policy.max_seconds) die(`invalid ${label} range`);
}

function validateCountBound(policy, label) {
  if (!plain(policy) || typeof policy.required !== "boolean") die(`invalid ${label}`);
  assertInteger(policy.min, `${label} minimum`, 0, 100000);
  assertInteger(policy.max, `${label} maximum`, 1, 100000);
  if (policy.min > policy.max) die(`invalid ${label} range`);
}

function validateBaseline(baseline) {
  for (const shape of ["long-running", "oneshot"]) {
    const policy = baseline.workloads[shape];
    if (policy.unit_type !== "service" || !Array.isArray(policy.restart.allowed) || policy.restart.allowed.length === 0 || new Set(policy.restart.allowed).size !== policy.restart.allowed.length) die(`invalid ${shape} policy`);
    validateBound(policy.restart.delay, `${shape} restart delay`);
    validateBound(policy.start_limits.interval, `${shape} start-limit interval`);
    validateCountBound(policy.start_limits.burst, `${shape} start-limit burst`);
    validateBound(policy.timeouts.start, `${shape} start timeout`);
    validateBound(policy.timeouts.stop, `${shape} stop timeout`);
    if (typeof policy.timeouts.runtime.allow_infinity !== "boolean") die(`invalid ${shape} runtime policy`);
    validateBound(policy.timeouts.runtime, `${shape} runtime timeout`);
    if (!policy.oom.allowed.every(value => ["stop", "kill"].includes(value))) die(`invalid ${shape} OOM policy`);
  }
  const timer = baseline.workloads.timer;
  validateBound(timer.accuracy, "timer accuracy");
  if (timer.schedule.calendar_directive !== "OnCalendar" || timer.schedule.classes_exclusive !== true ||
      timer.schedule.monotonic_directives.length !== 4 || !timer.schedule.monotonic_directives.every(value => TIMER_SCHEDULE_DIRECTIVES.includes(value))) die("invalid timer schedule policy");
  if (baseline.watchdog.min_seconds > baseline.watchdog.max_seconds) die("invalid watchdog range");
  if (baseline.observations.fields.length !== REQUIRED_OBSERVATION_FIELDS.length || !REQUIRED_OBSERVATION_FIELDS.every(field => baseline.observations.fields.includes(field))) die("observation policy omits required evidence");
}

function normalizeRegistryUnitName(rawName, type) {
  const expectedSuffix = `.${type}`;
  const actualSuffix = rawName.endsWith(".service") ? ".service" : rawName.endsWith(".timer") ? ".timer" : null;
  if (rawName.endsWith(".service.service") || rawName.endsWith(".timer.timer")) die("registry contains a duplicate or contradictory unit");
  if (actualSuffix !== null && actualSuffix !== expectedSuffix) die("registry contains a duplicate or contradictory unit");
  const base = actualSuffix === null ? rawName : rawName.slice(0, -actualSuffix.length);
  if (!base || !UNIT_BASE_NAME.test(base) || base.endsWith(".service") || base.endsWith(".timer")) die("registry contains a duplicate or contradictory unit");
  return { base, effective: `${base}${expectedSuffix}` };
}

function loadRegistry(registry) {
  const units = new Map();
  const unitsByEffective = new Map();
  const componentNames = new Set();
  let totalUnits = 0;
  for (const component of registry.components) {
    if (componentNames.has(component.name)) die("registry contains a duplicate component identity");
    componentNames.add(component.name);
    const declared = component.systemd_units ?? [];
    if (declared.length > 0 && !id(component.target_node_id)) die("registry component with systemd units lacks a stable target node identity");
    for (const unit of declared) {
      totalUnits += 1;
      if (totalUnits > MAX_TOTAL_UNITS) die("registry unit limit exceeded");
      const scope = unit.scope ?? "system";
      if (!SCOPES.has(scope)) die("registry contains an unsupported manager scope");
      const normalized = normalizeRegistryUnitName(unit.name, unit.type);
      if (!UNIT_NAME.test(normalized.effective)) die("registry contains an unsupported unit declaration");
      const key = unitKey(component.target_node_id, scope, normalized.effective);
      if (units.has(key)) die("registry contains a duplicate or contradictory unit");
      const record = {
        key,
        target_node_id: component.target_node_id,
        unit: normalized.effective,
        base: normalized.base,
        owner: component.name,
        type: unit.type,
        scope,
      };
      units.set(key, record);
      const effectiveCandidates = unitsByEffective.get(normalized.effective) ?? [];
      effectiveCandidates.push(record);
      unitsByEffective.set(normalized.effective, effectiveCandidates);
    }
  }
  if (units.size === 0) die("registry contains no systemd units");
  return { units, unitsByEffective };
}

function loadDeclarations(declarations, registry) {
  const result = new Map();
  for (const declaration of declarations.units) {
    if (Object.keys(declaration.directives).length > MAX_DIRECTIVES) die("unit declaration directive limit exceeded");
    const key = unitKey(declaration.target_node_id, declaration.scope, declaration.name);
    if (!registry.units.has(key)) die("unit declarations reference a unit outside the registry");
    if (result.has(key)) die("unit declarations contain a duplicate record");
    result.set(key, declaration);
  }
  return result;
}

function loadObservations(observations, registry) {
  if (!utc(observations.observed_at)) die("observed timestamp is malformed");
  const result = new Map();
  for (const unit of observations.units) {
    const key = unitKey(unit.target_node_id, unit.scope, unit.name);
    if (!registry.units.has(key) || result.has(key)) die("observations contain an unknown or duplicate unit");
    if (unit.restart !== null && (!utc(unit.restart.window_start) || !utc(unit.restart.window_end))) die("observed restart evidence is malformed");
    if (unit.timer !== null && ((unit.timer.last_run_at !== null && !utc(unit.timer.last_run_at)) || (unit.timer.next_run_at !== null && !utc(unit.timer.next_run_at)))) die("observed timer evidence is malformed");
    result.set(key, unit);
  }
  return result;
}

function parseNumber(value) {
  if (typeof value !== "string") return null;
  if (value === "infinity") return Infinity;
  const match = /^(\d+)(ms|s|m|min|h|d)?$/.exec(value);
  if (!match) return null;
  const amount = Number(match[1]);
  if (!Number.isSafeInteger(amount)) return null;
  return amount * ({ ms: 0.001, s: 1, m: 60, min: 60, h: 3600, d: 86400, undefined: 1 }[match[2]]);
}

function parseCount(value) {
  if (Number.isSafeInteger(value)) return value;
  if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function directiveValue(directives, key) {
  return has(directives, key) ? directives[key] : undefined;
}

function listValue(value) {
  if (Array.isArray(value)) return value;
  return typeof value === "string" ? [value] : [];
}

function stateFor(unit) {
  return { unit, findings: [], findingKeys: new Set() };
}

function addFinding(state, code, severity = "error", route = "substrate") {
  const key = `${code}\u0000${severity}\u0000${route}`;
  if (state.findingKeys.has(key)) return;
  if (state.findings.length >= MAX_UNIT_FINDINGS) die("unit finding limit exceeded");
  state.findingKeys.add(key);
  state.findings.push({ code, severity, route });
}

function addGlobalFinding(findings, keys, code, severity = "error", route = "substrate") {
  const key = `${code}\u0000${severity}\u0000${route}`;
  if (keys.has(key)) return;
  if (findings.length >= MAX_FINDINGS) die("audit finding limit exceeded");
  keys.add(key);
  findings.push({ code, severity, route });
}

function checkRequiredValue(state, directives, key, policy, missingCode, unsafeCode) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    if (policy.required) addFinding(state, missingCode);
    return null;
  }
  if (typeof value !== "string" || !policy.allowed.includes(value)) {
    addFinding(state, unsafeCode);
    return null;
  }
  return value;
}

function checkBoundDirective(state, directives, key, policy, missingCode, unsafeCode, allowInfinity = false) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    if (policy.required) addFinding(state, missingCode);
    return null;
  }
  const parsed = parseNumber(value);
  if (parsed === null || (!allowInfinity && parsed === Infinity) || (parsed !== Infinity && (parsed < policy.min_seconds || parsed > policy.max_seconds))) {
    addFinding(state, unsafeCode);
    return null;
  }
  return parsed;
}

function checkCountDirective(state, directives, key, policy, missingCode, unsafeCode) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    if (policy.required) addFinding(state, missingCode);
    return null;
  }
  const parsed = parseCount(value);
  if (parsed === null || parsed < policy.min || parsed > policy.max) {
    addFinding(state, unsafeCode);
    return null;
  }
  return parsed;
}

function findReferenceElsewhere(registry, effective) {
  return (registry.unitsByEffective.get(effective) ?? []).length > 0;
}

function userFailureDeliveryHasCycle(startKey, declarations, registry) {
  const seen = new Set();
  let currentKey = startKey;
  while (currentKey !== null) {
    if (seen.has(currentKey)) return true;
    seen.add(currentKey);
    const current = declarations.get(currentKey);
    if (!current) return false;
    const configured = listValue(directiveValue(current.directives, "OnFailure"));
    if (configured.length !== 1 || !USER_FAILURE_TARGET.test(configured[0])) return false;
    const target = registry.units.get(unitKey(current.target_node_id, current.scope, configured[0]));
    currentKey = target?.key ?? null;
  }
  return false;
}

function terminalFailureHandlerValid(declaration, policy) {
  return declaration.failure_handler_role === policy.terminal_handler_role &&
    directiveValue(declaration.directives, "Type") === policy.terminal_handler_type &&
    directiveValue(declaration.directives, "Restart") === policy.terminal_handler_restart &&
    directiveValue(declaration.directives, "OnFailure") === undefined;
}

function terminalFailureHandlerIncomingCount(terminal, declarations, registry, policy) {
  let incoming = 0;
  for (const source of registry.units.values()) {
    if (source.key === terminal.key || source.type !== "service" || source.scope !== "user" ||
        source.target_node_id !== terminal.target_node_id || source.owner !== terminal.owner) continue;
    const declaration = declarations.get(source.key);
    if (!declaration || declaration.failure_handler_role !== policy.service_role) continue;
    const configured = listValue(directiveValue(declaration.directives, "OnFailure"));
    if (configured.length !== 1 || !USER_FAILURE_TARGET.test(configured[0])) continue;
    if (registry.units.get(unitKey(source.target_node_id, source.scope, configured[0]))?.key === terminal.key) incoming += 1;
  }
  return incoming;
}

function checkFailureDelivery(state, declaration, registry, baseline, declarations) {
  const policy = baseline.scopes[state.unit.scope].failure_delivery;
  const configured = listValue(directiveValue(declaration.directives, "OnFailure"));
  if (policy.mode === "brokkr-systemd-failure") {
    if (declaration.failure_handler_role !== policy.service_role) addFinding(state, "failure_handler_role_scope_contradiction");
    if (configured.length === 0) addFinding(state, "failure_delivery_missing");
    if (configured.length > 1) addFinding(state, "failure_delivery_duplicate");
    if (configured.length === 1 && configured[0] !== CANONICAL_FAILURE_TARGET) addFinding(state, "failure_delivery_missing");
    return;
  }
  if (policy.mode !== "component-owner") {
    addFinding(state, "failure_delivery_policy_unsupported");
    return;
  }
  if (declaration.failure_handler_role === policy.terminal_handler_role) {
    if (directiveValue(declaration.directives, "Type") !== policy.terminal_handler_type) addFinding(state, "terminal_failure_handler_type_unsafe", "error", "component-owner");
    if (directiveValue(declaration.directives, "Restart") !== policy.terminal_handler_restart) addFinding(state, "terminal_failure_handler_restart_unsafe", "error", "component-owner");
    if (policy.terminal_handler_on_failure === "forbidden" && configured.length !== 0) addFinding(state, "terminal_failure_handler_delivery_forbidden", "error", "component-owner");
    if (terminalFailureHandlerIncomingCount(state.unit, declarations, registry, policy) < policy.terminal_handler_min_incoming) addFinding(state, "terminal_handler_unreferenced", "error", "component-owner");
    return;
  }
  if (declaration.failure_handler_role !== policy.service_role) {
    addFinding(state, "failure_handler_role_unsupported", "error", "component-owner");
    return;
  }
  if (configured.length === 0) {
    addFinding(state, "failure_delivery_missing", "error", "component-owner");
    return;
  }
  if (configured.length > 1) {
    addFinding(state, "failure_delivery_duplicate", "error", "component-owner");
    return;
  }
  const targetName = configured[0];
  if (targetName === CANONICAL_FAILURE_TARGET || targetName.includes("brokkr-systemd-failure")) {
    addFinding(state, "scope_delivery_contradiction", "error", "component-owner");
    return;
  }
  if (!USER_FAILURE_TARGET.test(targetName)) {
    addFinding(state, "failure_delivery_unsafe", "error", "component-owner");
    return;
  }
  const target = registry.units.get(unitKey(state.unit.target_node_id, state.unit.scope, targetName));
  if (!target) {
    addFinding(state, findReferenceElsewhere(registry, targetName) ? "failure_delivery_target_mismatch" : "failure_delivery_target_missing", "error", "component-owner");
    return;
  }
  if (target.key === state.unit.key) addFinding(state, "failure_delivery_self_target", "error", "component-owner");
  if (target.type !== "service" || target.owner !== state.unit.owner) {
    addFinding(state, "failure_delivery_target_mismatch", "error", "component-owner");
    return;
  }
  const targetDeclaration = declarations.get(target.key);
  if (!targetDeclaration) addFinding(state, "failure_delivery_target_undeclared", "error", "component-owner");
  else if (targetDeclaration.failure_handler_role !== policy.terminal_handler_role) addFinding(state, "failure_delivery_target_nonterminal", "error", "component-owner");
  else if (!terminalFailureHandlerValid(targetDeclaration, policy)) addFinding(state, "failure_delivery_target_terminal_invalid", "error", "component-owner");
  if (userFailureDeliveryHasCycle(state.unit.key, declarations, registry)) addFinding(state, "failure_delivery_cycle", "error", "component-owner");
}

function checkServiceDirectives(state, declaration, policy, shape, registry, baseline, declarations) {
  const directives = declaration.directives;
  if (SERVICE_TIMER_DIRECTIVES.some(key => has(directives, key))) addFinding(state, "service_timer_directive_forbidden");
  const type = directiveValue(directives, "Type");
  const allowedTypes = shape === "oneshot" ? ["oneshot"] : ["simple", "exec", "notify", "forking"];
  if (type === undefined) addFinding(state, "service_type_missing");
  else if (typeof type !== "string" || !allowedTypes.includes(type)) addFinding(state, "service_type_unsafe");

  const restart = checkRequiredValue(state, directives, "Restart", policy.restart, "restart_policy_missing", "restart_policy_unsafe");
  const restartDelay = directiveValue(directives, "RestartSec");
  if (policy.restart.delay.required) checkBoundDirective(state, directives, "RestartSec", policy.restart.delay, "restart_delay_missing", "restart_delay_unsafe");
  else if (restartDelay !== undefined) addFinding(state, "restart_delay_forbidden");
  if (restart === "no" && restartDelay !== undefined) addFinding(state, "restart_delay_forbidden");

  const burst = checkCountDirective(state, directives, "StartLimitBurst", policy.start_limits.burst, "start_limit_burst_missing", "start_limit_burst_unsafe");
  const interval = checkBoundDirective(state, directives, "StartLimitIntervalSec", policy.start_limits.interval, "start_limit_interval_missing", "start_limit_interval_unsafe");
  checkBoundDirective(state, directives, "TimeoutStartSec", policy.timeouts.start, "timeout_start_missing", "timeout_start_unsafe");
  checkBoundDirective(state, directives, "TimeoutStopSec", policy.timeouts.stop, "timeout_stop_missing", "timeout_stop_unsafe");
  checkBoundDirective(state, directives, "RuntimeMaxSec", policy.timeouts.runtime, "runtime_timeout_missing", "runtime_timeout_unsafe", policy.timeouts.runtime.allow_infinity);
  checkRequiredValue(state, directives, "OOMPolicy", policy.oom, "oom_policy_missing", "oom_policy_unsafe");
  checkFailureDelivery(state, declaration, registry, baseline, declarations);

  if (policy.readiness.required && declaration.readiness !== "present") addFinding(state, "readiness_missing", "error", "component-owner");
  if (shape === "long-running" && declaration.heartbeat.app_heartbeat !== "present") addFinding(state, "heartbeat_missing", "error", "component-owner");
  if (shape === "oneshot" && declaration.heartbeat.app_heartbeat !== "not-applicable") addFinding(state, "heartbeat_shape_contradiction", "error", "component-owner");

  const watchdog = directiveValue(directives, baseline.watchdog.directive);
  const watchdogConfigured = watchdog !== undefined;
  if (watchdogConfigured) {
    const seconds = parseNumber(watchdog);
    if (seconds === null || seconds === Infinity || seconds < baseline.watchdog.min_seconds || seconds > baseline.watchdog.max_seconds) addFinding(state, "watchdog_unsafe");
    if (type !== baseline.watchdog.requires_type) addFinding(state, "watchdog_requires_notify", "error", "component-owner");
    if ((baseline.watchdog.requires_app_heartbeat && declaration.heartbeat.app_heartbeat !== "present") ||
        (baseline.watchdog.requires_live_lock_fixture && declaration.heartbeat.live_lock_fixture !== "passed")) addFinding(state, "watchdog_heartbeat_unverified", "error", "component-owner");
  }
  return { burst, interval, watchdogConfigured };
}

function resolveTimerTarget(rawTarget, timer, registry) {
  const implicit = `${timer.unit.slice(0, -".timer".length)}.service`;
  if (rawTarget === undefined) {
    const target = registry.units.get(unitKey(timer.target_node_id, timer.scope, implicit));
    return { target, effective: implicit, elsewhere: !target && findReferenceElsewhere(registry, implicit) };
  }
  if (typeof rawTarget !== "string") return { target: null, effective: null, elsewhere: false };
  if (rawTarget.endsWith(".service") || rawTarget.endsWith(".timer")) {
    const target = registry.units.get(unitKey(timer.target_node_id, timer.scope, rawTarget));
    return { target, effective: rawTarget, elsewhere: !target && findReferenceElsewhere(registry, rawTarget) };
  }
  const effective = `${rawTarget}.service`;
  const target = registry.units.get(unitKey(timer.target_node_id, timer.scope, effective));
  return { target, effective, elsewhere: !target && findReferenceElsewhere(registry, effective) };
}

function validCalendarValue(value) {
  return typeof value === "string" && value.trim().length > 0 && value.trim().toLowerCase() !== "false" && !/[\r\n]/.test(value);
}

function validMonotonicValue(value) {
  const parsed = parseNumber(value);
  return parsed !== null && parsed !== Infinity && parsed >= 0;
}

function checkTimerDirectives(state, declaration, registry, baseline, declarations) {
  const directives = declaration.directives;
  if (declaration.failure_handler_role !== baseline.scopes[state.unit.scope].failure_delivery.service_role) addFinding(state, "failure_handler_role_timer_contradiction");
  if (TIMER_SERVICE_DIRECTIVES.some(key => has(directives, key))) addFinding(state, "timer_service_directive_forbidden");

  const targetResolution = resolveTimerTarget(directiveValue(directives, "Unit"), state.unit, registry);
  if (!targetResolution.target) addFinding(state, targetResolution.elsewhere ? "timer_target_mismatch" : "timer_target_missing");
  else if (targetResolution.target.type !== "service" || targetResolution.target.owner !== state.unit.owner) addFinding(state, "timer_target_mismatch");
  else {
    const targetDeclaration = declarations.get(targetResolution.target.key);
    if (!targetDeclaration) addFinding(state, "timer_target_declaration_missing");
    else if (targetDeclaration.failure_handler_role !== baseline.scopes[state.unit.scope].failure_delivery.service_role) addFinding(state, "timer_target_terminal_handler");
  }

  const policy = baseline.workloads.timer;
  const calendarDirective = policy.schedule.calendar_directive;
  const calendarPresent = has(directives, calendarDirective);
  const calendarValid = calendarPresent && validCalendarValue(directiveValue(directives, calendarDirective));
  if (calendarPresent && !calendarValid) addFinding(state, "timer_schedule_value_unsafe");

  let monotonicPresent = false;
  let monotonicValid = false;
  for (const key of policy.schedule.monotonic_directives) {
    if (!has(directives, key)) continue;
    monotonicPresent = true;
    if (validMonotonicValue(directiveValue(directives, key))) monotonicValid = true;
    else addFinding(state, "timer_schedule_value_unsafe");
  }
  if (!calendarValid && !monotonicValid) addFinding(state, "timer_schedule_missing");
  if (policy.schedule.classes_exclusive && calendarValid && monotonicValid) addFinding(state, "timer_schedule_mixed");
  const timerClass = calendarValid && !monotonicValid ? "calendar" : monotonicValid && !calendarValid ? "monotonic" : null;

  const persistent = directiveValue(directives, "Persistent");
  if (timerClass === "calendar" && policy.calendar.persistence_required && persistent !== true) addFinding(state, "timer_not_persistent");
  if (timerClass === "monotonic" && policy.monotonic.persistence_directive === "absent-or-false" && persistent !== undefined && persistent !== false) addFinding(state, "timer_persistence_forbidden");
  const accuracy = checkBoundDirective(state, directives, "AccuracySec", policy.accuracy, "timer_accuracy_missing", "timer_accuracy_unsafe");
  return { timerClass, accuracy, calendarPresent, monotonicPresent };
}

function checkRestartEvidence(state, observation, shape, burst, interval, observedAt, toleranceSeconds) {
  if (shape === "timer") {
    if (observation.restart !== null) addFinding(state, "restart_evidence_contradiction");
    return;
  }
  if (observation.restart === null) {
    addFinding(state, "restart_evidence_missing");
    return;
  }
  const restart = observation.restart;
  const start = Date.parse(restart.window_start);
  const end = Date.parse(restart.window_end);
  const observed = Date.parse(observedAt);
  const tolerance = toleranceSeconds * 1000;
  let windowValid = true;
  if (end < start) {
    addFinding(state, "restart_window_contradictory");
    windowValid = false;
  }
  if (start > observed + tolerance || end > observed + tolerance) {
    addFinding(state, "restart_window_future");
    windowValid = false;
  }
  if (Math.abs(end - observed) > tolerance) {
    addFinding(state, end < observed - tolerance ? "restart_window_ancient" : "restart_window_mismatch");
    windowValid = false;
  }
  if (interval === null) {
    addFinding(state, "restart_window_unverifiable");
    windowValid = false;
  } else {
    const expectedStart = observed - interval * 1000;
    if (Math.abs(start - expectedStart) > tolerance) {
      addFinding(state, start < expectedStart - tolerance ? "restart_window_ancient" : "restart_window_mismatch");
      windowValid = false;
    }
  }
  if (windowValid && Number.isSafeInteger(burst) && restart.count >= burst) addFinding(state, "restart_storm");
}

function checkWatchdogEvidence(state, observation, watchdogConfigured) {
  const result = observation.watchdog.result;
  if (!watchdogConfigured) {
    if (result !== "not-requested") addFinding(state, "watchdog_observation_contradiction");
    return;
  }
  if (result === "ok") return;
  if (result === "timeout") addFinding(state, "watchdog_timeout");
  else if (result === "not-requested") addFinding(state, "watchdog_result_not_requested");
  else addFinding(state, "watchdog_result_unknown");
}

function checkTimerEvidence(state, observation, declaration, timerClass, accuracy, observedAt, baseline) {
  if (observation.timer === null) {
    addFinding(state, "timer_evidence_missing");
    return;
  }
  const timer = observation.timer;
  const observed = Date.parse(observedAt);
  const tolerance = baseline.observations.restart_window_tolerance_seconds * 1000;
  const maxAge = baseline.observations.timer_timestamp_max_age_seconds * 1000;
  const maxFuture = baseline.observations.timer_timestamp_max_future_seconds * 1000;
  const last = timer.last_run_at === null ? null : Date.parse(timer.last_run_at);
  const next = timer.next_run_at === null ? null : Date.parse(timer.next_run_at);

  if (last === null) addFinding(state, "timer_last_run_missing", "warning");
  else {
    if (last > observed + tolerance) addFinding(state, "timer_last_run_future");
    if (last < observed - maxAge) addFinding(state, "timer_last_run_ancient");
  }
  if (next === null) addFinding(state, "timer_next_run_missing", "warning");
  else {
    if (next > observed + maxFuture) addFinding(state, "timer_next_run_future");
    if (next < observed - maxAge) addFinding(state, "timer_next_run_ancient");
    if (accuracy !== null && next + accuracy * 1000 < observed) addFinding(state, "timer_overdue");
  }
  if (last !== null && next !== null && next < last) addFinding(state, "timer_timestamp_contradictory");
  if (timer.last_result !== "success" && timer.last_result !== "not-run") addFinding(state, "timer_last_result_unhealthy");

  if (timerClass === "calendar") {
    if (baseline.workloads.timer.calendar.missed_runs_evidence === "count" && !Number.isSafeInteger(timer.missed_runs)) addFinding(state, "timer_missed_runs_evidence_missing");
    else if (Number.isSafeInteger(timer.missed_runs) && timer.missed_runs > 0) addFinding(state, "timer_missed_runs", "warning");
    if (timer.persistent !== true) addFinding(state, "timer_persistence_observation_mismatch");
    if (directiveValue(declaration.directives, "Persistent") !== true) addFinding(state, "timer_not_persistent");
  } else if (timerClass === "monotonic") {
    if (baseline.workloads.timer.monotonic.missed_runs_evidence === "not-applicable" && timer.missed_runs !== null) addFinding(state, "timer_missed_runs_evidence_contradiction");
    if (timer.persistent !== null) addFinding(state, "timer_persistence_evidence_contradiction");
  } else {
    addFinding(state, "timer_class_unresolved");
  }
}

function projectEvidence(observation) {
  if (!observation) return null;
  return {
    unit_result: { active_state: observation.result.active_state, sub_state: observation.result.sub_state, result: observation.result.result },
    restart: observation.restart === null ? null : { count: observation.restart.count, window_start: observation.restart.window_start, window_end: observation.restart.window_end },
    watchdog: { result: observation.watchdog.result },
    oom: { result: observation.oom.result },
    timer: observation.timer === null ? null : {
      last_run_at: observation.timer.last_run_at,
      next_run_at: observation.timer.next_run_at,
      last_result: observation.timer.last_result,
      missed_runs: observation.timer.missed_runs,
      persistent: observation.timer.persistent,
    },
  };
}

function checkObservedState(state, observation, shape, serviceState, timerState, declaration, observedAt, baseline) {
  if (!observation) {
    addFinding(state, "observation_missing");
    return;
  }
  const healthyResult = observation.result.result === "success";
  const healthyState = shape === "long-running" ? observation.result.active_state === "active" :
    shape === "oneshot" ? ["active", "inactive"].includes(observation.result.active_state) :
      shape === "timer" ? observation.result.active_state === "active" : true;
  if (!healthyResult || (shape !== "unknown" && !healthyState)) addFinding(state, "unit_result_unhealthy");

  if (shape !== "unknown") {
    checkRestartEvidence(state, observation, shape, serviceState?.burst ?? null, serviceState?.interval ?? null, observedAt, baseline.observations.restart_window_tolerance_seconds);
    checkWatchdogEvidence(state, observation, serviceState?.watchdogConfigured ?? false);
  }
  if (observation.oom.result === "killed") addFinding(state, "oom_kill_observed");
  if (observation.oom.result === "unknown") addFinding(state, "oom_result_unknown", "warning");

  if (shape === "timer") checkTimerEvidence(state, observation, declaration, timerState?.timerClass ?? null, timerState?.accuracy ?? null, observedAt, baseline);
  else if (observation.timer !== null) addFinding(state, "timer_evidence_contradiction");
}

function runAudit({ baseline, registry, declarations, observationsRecord, observations, evaluatedAt, evaluatedAtSource }) {
  const findings = [];
  const globalFindingKeys = new Set();
  const unitOutputs = [];
  const observationAge = Date.parse(evaluatedAt) - Date.parse(observationsRecord.observed_at);
  const futureSkew = baseline.freshness.future_skew_seconds * 1000;
  const freshnessStatus = observationAge < -futureSkew ? "future" : observationAge > baseline.freshness.max_age_seconds * 1000 ? "stale" : "fresh";
  if (freshnessStatus === "future") addGlobalFinding(findings, globalFindingKeys, "audit_time_in_future");
  if (freshnessStatus === "stale") addGlobalFinding(findings, globalFindingKeys, "audit_stale");

  const hasSystemService = [...registry.units.values()].some(unit => unit.scope === "system" && unit.type === "service");
  if (hasSystemService && (!observationsRecord.notifier || observationsRecord.notifier.status !== "available")) addGlobalFinding(findings, globalFindingKeys, "failure_delivery_unavailable");

  for (const unit of registry.units.values()) {
    const declaration = declarations.get(unit.key);
    const observation = observations.get(unit.key);
    const shape = unit.type === "timer" ? "timer" : !declaration ? "unknown" : declaration.directives.Type === "oneshot" ? "oneshot" : "long-running";
    const state = stateFor(unit);
    if (freshnessStatus === "stale") addFinding(state, "evidence_stale");
    if (freshnessStatus === "future") addFinding(state, "evidence_future");
    let serviceState = null;
    let timerState = null;
    if (!declaration) addFinding(state, "declaration_missing");
    else if (shape === "timer") timerState = checkTimerDirectives(state, declaration, registry, baseline, declarations);
    else serviceState = checkServiceDirectives(state, declaration, baseline.workloads[shape], shape, registry, baseline, declarations);
    checkObservedState(state, observation, shape, serviceState, timerState, declaration, observationsRecord.observed_at, baseline);
    const output = {
      target_node_id: unit.target_node_id,
      unit: unit.unit,
      owner: unit.owner,
      scope: unit.scope,
      workload_shape: shape,
      timer_class: shape === "timer" ? timerState?.timerClass ?? null : null,
      status: state.findings.length === 0 ? "pass" : "fail",
      findings: state.findings,
      evidence: projectEvidence(observation),
    };
    unitOutputs.push(output);
    for (const finding of state.findings) {
      if (findings.length >= MAX_FINDINGS) die("audit finding limit exceeded");
      findings.push({ ...finding, target_node_id: unit.target_node_id, scope: unit.scope, unit: unit.unit, owner: unit.owner });
    }
  }

  return {
    kind: "systemd-supervision-audit",
    schema_version: "v1",
    baseline_id: baseline.baseline_id,
    topology_authority: "grimnir-service-registry",
    observed_at: observationsRecord.observed_at,
    evaluated_at: evaluatedAt,
    evaluated_at_source: evaluatedAtSource,
    freshness: {
      status: freshnessStatus,
      age_seconds: Math.max(0, Math.floor(observationAge / 1000)),
      max_age_seconds: baseline.freshness.max_age_seconds,
    },
    notifier: { status: observationsRecord.notifier?.status ?? "unknown" },
    summary: {
      status: findings.length === 0 ? "pass" : "fail",
      unit_count: unitOutputs.length,
      compliant_unit_count: unitOutputs.filter(unit => unit.status === "pass").length,
      finding_count: findings.length,
    },
    units: unitOutputs,
    findings,
    extensions: [],
  };
}

const args = parseArgs(process.argv.slice(2));
const schemas = loadSchemas();
const baseline = readJsonBounded(args.baseline, "baseline");
const registryRecord = readJsonBounded(args.registry, "registry");
const declarationsRecord = readJsonBounded(args.declarations, "declarations");
const observationsRecord = readJsonBounded(args.observations, "observations");
validateAgainstSchema(schemas.baseline, baseline, "baseline");
validateAgainstSchema(schemas.registry, registryRecord, "registry");
validateAgainstSchema(schemas.declarations, declarationsRecord, "declarations");
validateAgainstSchema(schemas.observations, observationsRecord, "observations");
validateBaseline(baseline);
const registry = loadRegistry(registryRecord);
const declarations = loadDeclarations(declarationsRecord, registry);
const observations = loadObservations(observationsRecord, registry);
const audit = runAudit({ baseline, registry, declarations, observationsRecord, observations, evaluatedAt: args.evaluatedAt, evaluatedAtSource: args.evaluatedAtSource });
validateAgainstSchema(schemas.audit, audit, "audit output");
const serialized = `${JSON.stringify(audit, null, 2)}\n`;
if (Buffer.byteLength(serialized, "utf8") > MAX_OUTPUT_BYTES) die("audit output size limit exceeded");
process.stdout.write(serialized);
if (audit.summary.finding_count > 0) process.exitCode = 1;
