#!/usr/bin/env node
// Read-only systemd supervision audit for brokkr#98.
//
// The registry remains the only topology authority. The declarations file is
// a deliberately content-blind projection of audited directives; scope,
// component ownership, and unit shape are taken from the Grimnir registry.
// Observations are metadata-only state evidence. This program never invokes
// systemctl, writes a unit, enables a timer, delivers a notification, or
// mutates any input.
import fs from "node:fs";

const UNIT_BASE_NAME = /^(?!.*[\r\n])[A-Za-z0-9:_.@-]+$/;
const UNIT_NAME = /^(?!.*[\r\n])[A-Za-z0-9:_.@-]+\.(?:service|timer)$/;
const FAILURE_TARGET = /^(?!.*[\r\n])[A-Za-z0-9:_.@%+-]+\.(?:service|target)$/;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const DIRECTIVES = new Set([
  "Type", "Restart", "RestartSec", "StartLimitIntervalSec",
  "StartLimitBurst", "TimeoutStartSec", "TimeoutStopSec", "RuntimeMaxSec",
  "OOMPolicy", "OnFailure", "WatchdogSec", "Unit", "OnCalendar",
  "OnBootSec", "OnStartupSec", "OnUnitActiveSec", "OnUnitInactiveSec",
  "Persistent", "AccuracySec",
]);
const SCOPES = new Set(["system", "user"]);
const ACTIVE_STATES = new Set(["active", "inactive", "failed", "activating", "deactivating", "unknown"]);
const RESULTS = new Set(["success", "exit-code", "signal", "core-dump", "watchdog", "oom-kill", "timeout", "start-limit-hit", "resources", "protocol", "condition", "unknown"]);
const WATCHDOG_RESULTS = new Set(["not-requested", "ok", "timeout", "unknown"]);
const OOM_RESULTS = new Set(["not-applicable", "none", "killed", "unknown"]);
const TIMER_RESULTS = new Set(["success", "failed", "not-run", "unknown"]);
const CANONICAL_FAILURE_TARGET = "brokkr-systemd-failure@%n.service";
const TIMER_SCHEDULE_DIRECTIVES = ["OnCalendar", "OnBootSec", "OnStartupSec", "OnUnitActiveSec", "OnUnitInactiveSec"];

const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => plain(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const has = (value, key) => plain(value) && Object.hasOwn(value, key);
const utc = value => {
  if (typeof value !== "string" || !UTC.test(value)) return false;
  const instant = new Date(value);
  if (Number.isNaN(instant.getTime())) return false;
  return instant.toISOString().replace(".000Z", "Z") === value;
};
const id = value => typeof value === "string" && ID.test(value);
const die = message => {
  process.stderr.write(`systemd-supervision-audit: ${message}\n`);
  process.exit(2);
};
const usage = () => die("usage: systemd-supervision-audit.mjs --baseline file --registry file --declarations file --observations file --now UTC");

function parseArgs(argv) {
  const parsed = {};
  const allowed = new Set(["--baseline", "--registry", "--declarations", "--observations", "--now"]);
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const field = key.slice(2);
    if (!allowed.has(key) || has(parsed, field)) usage();
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) usage();
    parsed[field] = value;
    index += 1;
  }
  if (!exactKeys(parsed, ["baseline", "registry", "declarations", "observations", "now"]) || !utc(parsed.now)) usage();
  return parsed;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    die(`cannot read ${label} JSON`);
  }
}

function assertInteger(value, label, min = 0, max = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < min || value > max) die(`invalid ${label}`);
}

function parseNumber(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value !== "string") return null;
  if (!/^\d+(?:ms|s|m|min|h|d)?$/.test(value) && value !== "infinity") return null;
  if (value === "infinity") return Infinity;
  const match = /^(\d+)(ms|s|m|min|h|d)?$/.exec(value);
  const amount = Number(match[1]);
  if (!Number.isSafeInteger(amount)) return null;
  return amount * ({ ms: 0.001, s: 1, m: 60, min: 60, h: 3600, d: 86400, undefined: 1 }[match[2]]);
}

function parseCount(value) {
  if (Number.isSafeInteger(value)) return value;
  if (typeof value === "string" && /^\d+$/.test(value)) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) ? parsed : null;
  }
  return null;
}

function validBound(value, _label, allowInfinity, min, max) {
  const parsed = parseNumber(value);
  if (parsed === null || (!allowInfinity && parsed === Infinity) || (parsed !== Infinity && (parsed < min || parsed > max))) {
    return `${_label}_unsafe`;
  }
  return null;
}

function validateBaseline(baseline) {
  if (!exactKeys(baseline, ["kind", "schema_version", "baseline_id", "authority", "freshness", "scopes", "workloads", "watchdog", "observations", "extensions"]) ||
      baseline.kind !== "systemd-supervision-baseline" || baseline.schema_version !== "v1" || !id(baseline.baseline_id) ||
      !Array.isArray(baseline.extensions) || baseline.extensions.length !== 0) die("unsupported supervision baseline");
  if (!exactKeys(baseline.authority, ["topology", "failure_delivery", "audit"]) ||
      baseline.authority.topology !== "grimnir-service-registry" ||
      baseline.authority.failure_delivery !== "brokkr-systemd-failure-v1" ||
      baseline.authority.audit !== "brokkr-systemd-supervision-audit-v1") die("invalid baseline authority");
  if (!exactKeys(baseline.freshness, ["max_age_seconds", "future_skew_seconds"])) die("invalid baseline freshness");
  assertInteger(baseline.freshness.max_age_seconds, "baseline max age", 1, 86400);
  assertInteger(baseline.freshness.future_skew_seconds, "baseline future skew", 0, 300);
  if (!exactKeys(baseline.scopes, ["system", "user"])) die("invalid baseline scopes");
  for (const [scope, mode] of [["system", "brokkr-systemd-failure"], ["user", "component-owner"]]) {
    const policy = baseline.scopes[scope];
    if (!exactKeys(policy, ["manager", "failure_delivery"]) || policy.manager !== scope ||
        !exactKeys(policy.failure_delivery, ["required", "mode"]) || policy.failure_delivery.required !== true || policy.failure_delivery.mode !== mode) {
      die(`invalid ${scope} scope policy`);
    }
  }
  if (!exactKeys(baseline.workloads, ["long-running", "oneshot", "timer"])) die("invalid baseline workloads");
  for (const shape of ["long-running", "oneshot"]) validateServicePolicy(baseline.workloads[shape], shape);
  validateTimerPolicy(baseline.workloads.timer);
  if (!exactKeys(baseline.watchdog, ["directive", "requires_type", "min_seconds", "max_seconds", "requires_app_heartbeat", "requires_live_lock_fixture"]) ||
      baseline.watchdog.directive !== "WatchdogSec" || baseline.watchdog.requires_type !== "notify" ||
      baseline.watchdog.requires_app_heartbeat !== true || baseline.watchdog.requires_live_lock_fixture !== true) die("invalid watchdog policy");
  assertInteger(baseline.watchdog.min_seconds, "watchdog minimum", 1, 3600);
  assertInteger(baseline.watchdog.max_seconds, "watchdog maximum", 1, 3600);
  if (baseline.watchdog.min_seconds > baseline.watchdog.max_seconds) die("invalid watchdog range");
  if (!exactKeys(baseline.observations, ["content_blind", "fields"]) || baseline.observations.content_blind !== true ||
      !Array.isArray(baseline.observations.fields) || new Set(baseline.observations.fields).size !== baseline.observations.fields.length) die("invalid observation policy");
  const requiredFields = new Set(["unit_result", "restart_count_window", "watchdog_result", "oom_result", "timer_last_next_run", "audit_freshness"]);
  if (![...requiredFields].every(field => baseline.observations.fields.includes(field))) die("observation policy omits required evidence");
}

function validateServicePolicy(policy, shape) {
  if (!exactKeys(policy, ["unit_type", "restart", "start_limits", "timeouts", "oom", "failure_delivery", "readiness"]) || policy.unit_type !== "service") die(`invalid ${shape} policy`);
  if (!exactKeys(policy.restart, ["required", "allowed", "delay"]) || typeof policy.restart.required !== "boolean" ||
      !Array.isArray(policy.restart.allowed) || policy.restart.allowed.length === 0 || new Set(policy.restart.allowed).size !== policy.restart.allowed.length) die(`invalid ${shape} restart policy`);
  validateBound(policy.restart.delay, `${shape} restart delay`);
  if (!exactKeys(policy.start_limits, ["interval", "burst"])) die(`invalid ${shape} start-limit policy`);
  validateBound(policy.start_limits.interval, `${shape} start-limit interval`);
  validateCountBound(policy.start_limits.burst, `${shape} start-limit burst`);
  if (!exactKeys(policy.timeouts, ["start", "stop", "runtime"])) die(`invalid ${shape} timeout policy`);
  validateBound(policy.timeouts.start, `${shape} start timeout`);
  validateBound(policy.timeouts.stop, `${shape} stop timeout`);
  if (!exactKeys(policy.timeouts.runtime, ["required", "allow_infinity", "min_seconds", "max_seconds"]) || typeof policy.timeouts.runtime.required !== "boolean" || typeof policy.timeouts.runtime.allow_infinity !== "boolean") die(`invalid ${shape} runtime timeout policy`);
  assertInteger(policy.timeouts.runtime.min_seconds, `${shape} runtime timeout minimum`, 0, 31536000);
  assertInteger(policy.timeouts.runtime.max_seconds, `${shape} runtime timeout maximum`, 1, 31536000);
  if (policy.timeouts.runtime.min_seconds > policy.timeouts.runtime.max_seconds) die(`invalid ${shape} runtime timeout range`);
  if (!exactKeys(policy.oom, ["required", "allowed"]) || policy.oom.required !== true || !Array.isArray(policy.oom.allowed) || policy.oom.allowed.length === 0) die(`invalid ${shape} OOM policy`);
  if (!exactKeys(policy.failure_delivery, ["required", "mode"]) || policy.failure_delivery.required !== true || policy.failure_delivery.mode !== "brokkr-systemd-failure") die(`invalid ${shape} failure policy`);
  if (!exactKeys(policy.readiness, ["required"]) || typeof policy.readiness.required !== "boolean") die(`invalid ${shape} readiness policy`);
}

function validateTimerPolicy(policy) {
  if (!exactKeys(policy, ["unit_type", "persistence", "accuracy", "schedule", "missed_runs"]) || policy.unit_type !== "timer" || policy.missed_runs !== true) die("invalid timer policy");
  if (!exactKeys(policy.persistence, ["required", "allowed"]) || policy.persistence.required !== true || !Array.isArray(policy.persistence.allowed) || !policy.persistence.allowed.includes(true)) die("invalid timer persistence policy");
  validateBound(policy.accuracy, "timer accuracy");
  if (!exactKeys(policy.schedule, ["required", "directives"]) || policy.schedule.required !== true || !Array.isArray(policy.schedule.directives) || !TIMER_SCHEDULE_DIRECTIVES.every(key => policy.schedule.directives.includes(key))) die("invalid timer schedule policy");
}

function validateBound(value, label) {
  if (!exactKeys(value, ["required", "min_seconds", "max_seconds"]) || typeof value.required !== "boolean") die(`invalid ${label}`);
  assertInteger(value.min_seconds, `${label} minimum`, 0, 31536000);
  assertInteger(value.max_seconds, `${label} maximum`, 0, 31536000);
  if (value.min_seconds > value.max_seconds) die(`invalid ${label} range`);
}

function validateCountBound(value, label) {
  if (!exactKeys(value, ["required", "min", "max"]) || typeof value.required !== "boolean") die(`invalid ${label}`);
  assertInteger(value.min, `${label} minimum`, 0, 100000);
  assertInteger(value.max, `${label} maximum`, 0, 100000);
  if (value.min > value.max) die(`invalid ${label} range`);
}

function normalizeRegistryUnitName(rawName, type) {
  const expectedSuffix = `.${type}`;
  const hasServiceSuffix = rawName.endsWith(".service");
  const hasTimerSuffix = rawName.endsWith(".timer");
  if (rawName.endsWith(".service.service") || rawName.endsWith(".timer.timer")) die("registry contains a duplicate or contradictory unit");
  const hasSuffix = hasServiceSuffix || hasTimerSuffix;
  const base = hasSuffix ? rawName.slice(0, -expectedSuffix.length) : rawName;
  if (!base || !UNIT_BASE_NAME.test(base) || base.endsWith(".service") || base.endsWith(".timer")) die("registry contains a duplicate or contradictory unit");
  if (hasSuffix && !rawName.endsWith(expectedSuffix)) die("registry contains a duplicate or contradictory unit");
  return { base, effective: `${base}${expectedSuffix}` };
}

function loadRegistry(registry) {
  if (!plain(registry) || !Array.isArray(registry.components)) die("registry must contain a components array");
  const units = new Map();
  const bareToEffective = new Map();
  for (const component of registry.components) {
    if (!plain(component) || !id(component.name)) die("registry contains an unsafe component name");
    const declared = component.systemd_units ?? [];
    if (!Array.isArray(declared)) die("registry systemd_units must be an array");
    for (const unit of declared) {
      if (!plain(unit) || typeof unit.name !== "string" || !["service", "timer"].includes(unit.type)) die("registry contains an unsupported unit declaration");
      const scope = unit.scope ?? "system";
      if (!SCOPES.has(scope)) die("registry contains an unsupported manager scope");
      const normalized = normalizeRegistryUnitName(unit.name, unit.type);
      if (!UNIT_NAME.test(normalized.effective) || units.has(normalized.effective)) die("registry contains a duplicate or contradictory unit");
      units.set(normalized.effective, { unit: normalized.effective, owner: component.name, type: unit.type, scope });
      const candidates = bareToEffective.get(normalized.base) ?? [];
      candidates.push(normalized.effective);
      bareToEffective.set(normalized.base, candidates);
    }
  }
  if (units.size === 0) die("registry contains no systemd units");
  return { units, bareToEffective };
}

function validateDirectiveValue(value) {
  if (typeof value === "string" || typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) return true;
  return Array.isArray(value) && value.every(item => typeof item === "string");
}

function loadDeclarations(declarations, registry) {
  if (!exactKeys(declarations, ["kind", "schema_version", "topology_authority", "units"]) || declarations.kind !== "systemd-unit-declarations" || declarations.schema_version !== "v1" || declarations.topology_authority !== "grimnir-service-registry" || !Array.isArray(declarations.units)) die("unsupported unit declarations");
  const result = new Map();
  for (const declaration of declarations.units) {
    if (!exactKeys(declaration, ["name", "directives", "heartbeat", "readiness", "failure_delivery"]) || typeof declaration.name !== "string" || result.has(declaration.name)) die("unit declarations contain a duplicate or malformed record");
    if (!registry.units.has(declaration.name)) die("unit declarations reference a unit outside the registry");
    if (!plain(declaration.directives)) die("unit declarations contain malformed directives");
    for (const [key, value] of Object.entries(declaration.directives)) {
      if (!DIRECTIVES.has(key) || !validateDirectiveValue(value)) die("unit declarations contain unsupported directive content");
    }
    if (!exactKeys(declaration.heartbeat, ["app_heartbeat", "live_lock_fixture"]) ||
        !["present", "absent", "unknown", "not-applicable"].includes(declaration.heartbeat.app_heartbeat) ||
        !["passed", "absent", "unknown", "not-applicable"].includes(declaration.heartbeat.live_lock_fixture) ||
        !["present", "absent", "unknown", "not-applicable"].includes(declaration.readiness) ||
        !["brokkr-systemd-failure", "component-owner", "not-declared", "unknown"].includes(declaration.failure_delivery)) die("unit declarations contain malformed capability projections");
    result.set(declaration.name, declaration);
  }
  return result;
}

function validateObservedUnit(unit) {
  if (!exactKeys(unit, ["name", "result", "restart", "watchdog", "oom", "timer"]) || typeof unit.name !== "string") die("observed unit record is malformed");
  if (!exactKeys(unit.result, ["active_state", "sub_state", "result"]) || !ACTIVE_STATES.has(unit.result.active_state) || typeof unit.result.sub_state !== "string" || !/^[A-Za-z0-9_-]{1,32}$/.test(unit.result.sub_state) || !RESULTS.has(unit.result.result)) die("observed unit result is malformed");
  if (!exactKeys(unit.restart, ["count", "window_start", "window_end"]) || !Number.isSafeInteger(unit.restart.count) || unit.restart.count < 0 || unit.restart.count > 100000 || !utc(unit.restart.window_start) || !utc(unit.restart.window_end) || Date.parse(unit.restart.window_end) < Date.parse(unit.restart.window_start)) die("observed restart evidence is malformed");
  if (!exactKeys(unit.watchdog, ["result"]) || !WATCHDOG_RESULTS.has(unit.watchdog.result)) die("observed watchdog evidence is malformed");
  if (!exactKeys(unit.oom, ["result"]) || !OOM_RESULTS.has(unit.oom.result)) die("observed OOM evidence is malformed");
  if (unit.timer !== null) {
    if (!exactKeys(unit.timer, ["last_run_at", "next_run_at", "last_result", "missed_runs", "persistent"]) ||
        (unit.timer.last_run_at !== null && !utc(unit.timer.last_run_at)) ||
        (unit.timer.next_run_at !== null && !utc(unit.timer.next_run_at)) ||
        !TIMER_RESULTS.has(unit.timer.last_result) || !Number.isSafeInteger(unit.timer.missed_runs) || unit.timer.missed_runs < 0 || unit.timer.missed_runs > 100000 || typeof unit.timer.persistent !== "boolean") die("observed timer evidence is malformed");
    if (unit.timer.last_run_at && unit.timer.next_run_at && Date.parse(unit.timer.next_run_at) < Date.parse(unit.timer.last_run_at)) die("observed timer evidence has contradictory run times");
  }
}

function loadObservations(observations, registry) {
  if (!exactKeys(observations, ["kind", "schema_version", "observed_at", "notifier", "units"]) || observations.kind !== "systemd-supervision-observations" || observations.schema_version !== "v1" || !utc(observations.observed_at) || !Array.isArray(observations.units)) die("unsupported supervision observations");
  if (observations.notifier !== null && (!exactKeys(observations.notifier, ["status"]) || !["available", "absent", "unknown"].includes(observations.notifier.status))) die("observed notifier evidence is malformed");
  const result = new Map();
  for (const unit of observations.units) {
    validateObservedUnit(unit);
    if (!registry.units.has(unit.name) || result.has(unit.name)) die("observations contain an unknown or duplicate unit");
    result.set(unit.name, unit);
  }
  return result;
}

function directiveValue(directives, key) {
  return has(directives, key) ? directives[key] : undefined;
}

function listValue(value) {
  if (Array.isArray(value)) return value;
  if (typeof value === "string") return [value];
  return [];
}

function addFinding(state, code, severity = "error", route = "substrate") {
  const finding = { code, severity, route };
  if (state.unit) {
    finding.unit = state.unit.unit;
    finding.owner = state.unit.owner;
    state.findings.push({ code, severity, route });
  } else {
    state.findings.push(finding);
  }
}

function checkRequiredValue(state, directives, key, allowed, missingCode, unsafeCode) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    addFinding(state, missingCode);
    return undefined;
  }
  if (typeof value !== "string" || !allowed.includes(value)) addFinding(state, unsafeCode);
  return value;
}

function checkBoundDirective(state, directives, key, policy, missingCode, unsafeCode, allowInfinity = false) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    if (policy.required) addFinding(state, missingCode);
    return undefined;
  }
  const error = validBound(value, key, allowInfinity, policy.min_seconds, policy.max_seconds);
  if (error) addFinding(state, unsafeCode);
  return parseNumber(value);
}

function checkCountDirective(state, directives, key, policy, missingCode, unsafeCode) {
  const value = directiveValue(directives, key);
  if (value === undefined) {
    if (policy.required) addFinding(state, missingCode);
    return undefined;
  }
  const parsed = parseCount(value);
  if (parsed === null || parsed < policy.min || parsed > policy.max) addFinding(state, unsafeCode);
  return parsed;
}

function checkServiceDirectives(state, declaration, policy, shape, baseline) {
  const directives = declaration?.directives ?? {};
  const type = directiveValue(directives, "Type");
  const allowedTypes = shape === "oneshot" ? ["oneshot"] : ["simple", "exec", "notify", "forking"];
  if (type === undefined) addFinding(state, "service_type_missing");
  else if (typeof type !== "string" || !allowedTypes.includes(type)) addFinding(state, "service_type_unsafe");

  const restart = checkRequiredValue(state, directives, "Restart", policy.restart.allowed, "restart_policy_missing", "restart_policy_unsafe");
  const restartDelay = directiveValue(directives, "RestartSec");
  if (policy.restart.delay.required) checkBoundDirective(state, directives, "RestartSec", policy.restart.delay, "restart_delay_missing", "restart_delay_unsafe");
  else if (restartDelay !== undefined) addFinding(state, "restart_delay_forbidden");
  if (restart === "no" && restartDelay !== undefined) addFinding(state, "restart_delay_forbidden");

  const burst = checkCountDirective(state, directives, "StartLimitBurst", policy.start_limits.burst, "start_limit_burst_missing", "start_limit_burst_unsafe");
  checkBoundDirective(state, directives, "StartLimitIntervalSec", policy.start_limits.interval, "start_limit_interval_missing", "start_limit_interval_unsafe");
  checkBoundDirective(state, directives, "TimeoutStartSec", policy.timeouts.start, "timeout_start_missing", "timeout_start_unsafe");
  checkBoundDirective(state, directives, "TimeoutStopSec", policy.timeouts.stop, "timeout_stop_missing", "timeout_stop_unsafe");
  checkBoundDirective(state, directives, "RuntimeMaxSec", policy.timeouts.runtime, "runtime_timeout_missing", "runtime_timeout_unsafe", policy.timeouts.runtime.allow_infinity);

  const oom = checkRequiredValue(state, directives, "OOMPolicy", policy.oom.allowed, "oom_policy_missing", "oom_policy_unsafe");
  if (oom === "continue") addFinding(state, "oom_policy_unsafe");
  checkFailureDelivery(state, declaration, directives, baseline);

  if (policy.readiness.required && declaration.readiness !== "present") addFinding(state, "readiness_missing", "error", "component-owner");
  if (shape === "long-running" && declaration.heartbeat.app_heartbeat !== "present") addFinding(state, "heartbeat_missing", "error", "component-owner");
  if (shape === "oneshot" && declaration.heartbeat.app_heartbeat !== "not-applicable") addFinding(state, "heartbeat_shape_contradiction", "error", "component-owner");

  const watchdog = directiveValue(directives, baseline.watchdog.directive);
  if (watchdog !== undefined) {
    const seconds = parseNumber(watchdog);
    if (seconds === null || seconds === Infinity || seconds < baseline.watchdog.min_seconds || seconds > baseline.watchdog.max_seconds) addFinding(state, "watchdog_unsafe");
    if (type !== baseline.watchdog.requires_type) addFinding(state, "watchdog_requires_notify", "error", "component-owner");
    if (declaration.heartbeat.app_heartbeat !== "present" || declaration.heartbeat.live_lock_fixture !== "passed") addFinding(state, "watchdog_heartbeat_unverified", "error", "component-owner");
  }
  return burst;
}

function checkFailureDelivery(state, declaration, directives, baseline) {
  const system = state.unit.scope === "system";
  const configured = listValue(directiveValue(directives, "OnFailure"));
  if (system) {
    if (declaration.failure_delivery !== "brokkr-systemd-failure") addFinding(state, "failure_delivery_declaration_missing");
    if (!configured.includes(CANONICAL_FAILURE_TARGET)) addFinding(state, "failure_delivery_missing");
    if (configured.some(target => target !== CANONICAL_FAILURE_TARGET)) addFinding(state, "failure_delivery_duplicate");
  } else {
    if (declaration.failure_delivery !== "component-owner") addFinding(state, "failure_delivery_missing", "error", "component-owner");
    if (configured.length === 0) addFinding(state, "failure_delivery_missing", "error", "component-owner");
    else if (configured.some(target => typeof target !== "string" || !FAILURE_TARGET.test(target))) addFinding(state, "failure_delivery_unsafe", "error", "component-owner");
    if (configured.some(target => typeof target === "string" && (target === CANONICAL_FAILURE_TARGET || target.includes("brokkr-systemd-failure")))) addFinding(state, "scope_delivery_contradiction", "error", "component-owner");
  }
  if (!baseline.scopes[state.unit.scope]) addFinding(state, "manager_scope_unsafe");
}

function resolveTimerTarget(rawTarget, timer, registry) {
  if (rawTarget === undefined) {
    const implicitTarget = `${timer.unit.slice(0, -".timer".length)}.service`;
    return registry.units.has(implicitTarget) ? implicitTarget : null;
  }
  if (typeof rawTarget !== "string") return null;
  if (registry.units.has(rawTarget)) return rawTarget;
  if (rawTarget.endsWith(".service") || rawTarget.endsWith(".timer")) {
    const base = rawTarget.slice(0, rawTarget.lastIndexOf("."));
    const candidates = registry.bareToEffective.get(base) ?? [];
    return candidates.includes(rawTarget) ? rawTarget : null;
  }
  const candidates = registry.bareToEffective.get(rawTarget) ?? [];
  return candidates.length === 1 ? candidates[0] : null;
}

function checkTimerDirectives(state, declaration, registry, baseline) {
  const directives = declaration?.directives ?? {};
  if (has(directives, "Restart")) addFinding(state, "timer_restart_forbidden");
  if (listValue(directiveValue(directives, "OnFailure")).length > 0) addFinding(state, "timer_failure_delivery_duplicate");
  const unitTarget = directiveValue(directives, "Unit");
  const targetName = resolveTimerTarget(unitTarget, state.unit, registry);
  const target = targetName ? registry.units.get(targetName) : undefined;
  if (!target || target.type !== "service" || target.scope !== state.unit.scope || target.owner !== state.unit.owner) addFinding(state, "timer_target_missing");
  const persistent = directiveValue(directives, "Persistent");
  if (persistent !== true) addFinding(state, "timer_not_persistent");
  const accuracy = parseNumber(directiveValue(directives, "AccuracySec"));
  const policy = baseline.workloads.timer;
  if (accuracy === null || accuracy === Infinity || accuracy < policy.accuracy.min_seconds || accuracy > policy.accuracy.max_seconds) addFinding(state, "timer_accuracy_unsafe");
  if (!TIMER_SCHEDULE_DIRECTIVES.some(key => has(directives, key))) addFinding(state, "timer_schedule_missing");
  if (declaration.failure_delivery !== "not-declared") addFinding(state, "timer_failure_delivery_duplicate");
}

function projectEvidence(observation) {
  if (!observation) return null;
  return {
    unit_result: { active_state: observation.result.active_state, sub_state: observation.result.sub_state, result: observation.result.result },
    restart: { count: observation.restart.count, window_start: observation.restart.window_start, window_end: observation.restart.window_end },
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

function checkObservedState(state, observation, shape, burst, declaration) {
  if (!observation) {
    addFinding(state, "observation_missing");
    return;
  }
  const healthyResult = observation.result.result === "success";
  const healthyState = shape === "long-running" ? observation.result.active_state === "active" :
    shape === "oneshot" ? ["active", "inactive"].includes(observation.result.active_state) : observation.result.active_state === "active";
  if (!healthyResult || !healthyState) addFinding(state, "unit_result_unhealthy");
  if (shape !== "timer" && burst !== undefined && observation.restart.count >= burst) addFinding(state, "restart_storm");
  if (observation.oom.result === "killed") addFinding(state, "oom_kill_observed");
  if (observation.oom.result === "unknown") addFinding(state, "oom_result_unknown", "warning");
  if (declaration && has(declaration.directives, "WatchdogSec")) {
    if (observation.watchdog.result === "timeout") addFinding(state, "watchdog_timeout");
    else if (observation.watchdog.result !== "ok") addFinding(state, "watchdog_result_unknown", "warning");
  }
  if (shape === "timer") {
    if (observation.timer === null) {
      addFinding(state, "timer_evidence_missing");
      return;
    }
    if (!observation.timer.last_run_at) addFinding(state, "timer_last_run_missing", "warning");
    if (!observation.timer.next_run_at) addFinding(state, "timer_next_run_missing", "warning");
    if (observation.timer.last_result !== "success" && observation.timer.last_result !== "not-run") addFinding(state, "timer_last_result_unhealthy");
    if (observation.timer.missed_runs > 0) addFinding(state, "timer_missed_runs", "warning");
    const persistent = declaration ? directiveValue(declaration.directives, "Persistent") : undefined;
    if (observation.timer.persistent !== persistent) addFinding(state, "timer_persistence_observation_mismatch");
    if (observation.timer.missed_runs > 0 && (persistent !== true || observation.timer.persistent !== true)) addFinding(state, "timer_not_persistent");
  } else if (observation.timer !== null) addFinding(state, "timer_evidence_contradiction");
}

function runAudit({ baseline, registry, declarations, observations, now }) {
  const findings = [];
  const unitOutputs = [];
  const observationAge = Date.parse(now) - Date.parse(observations.observed_at);
  const futureSkew = baseline.freshness.future_skew_seconds * 1000;
  const freshnessStatus = observationAge < -futureSkew ? "future" : observationAge > baseline.freshness.max_age_seconds * 1000 ? "stale" : "fresh";
  if (freshnessStatus === "future") findings.push({ code: "audit_time_in_future", severity: "error", route: "substrate" });
  if (freshnessStatus === "stale") findings.push({ code: "audit_stale", severity: "error", route: "substrate" });

  const hasSystemService = [...registry.units.values()].some(unit => unit.scope === "system" && unit.type === "service");
  if (hasSystemService && (!observations.notifier || observations.notifier.status !== "available")) findings.push({ code: "failure_delivery_unavailable", severity: "error", route: "substrate" });

  for (const unit of registry.units.values()) {
    const declaration = declarations.get(unit.unit);
    const observation = observations.units.get(unit.unit);
    const shape = unit.type === "timer" ? "timer" : declaration?.directives?.Type === "oneshot" ? "oneshot" : "long-running";
    const state = { unit, findings: [] };
    let burst;
    if (!declaration) addFinding(state, "declaration_missing");
    else if (shape === "timer") checkTimerDirectives(state, declaration, registry, baseline);
    else burst = checkServiceDirectives(state, declaration, baseline.workloads[shape], shape, baseline);
    checkObservedState(state, observation, shape, burst, declaration);
    const evidence = projectEvidence(observation);
    const output = {
      unit: unit.unit,
      owner: unit.owner,
      scope: unit.scope,
      workload_shape: shape,
      status: state.findings.length === 0 ? "pass" : "fail",
      findings: state.findings,
      evidence,
    };
    unitOutputs.push(output);
    for (const finding of state.findings) findings.push({ ...finding, unit: unit.unit, owner: unit.owner });
  }

  const summary = {
    status: findings.length === 0 ? "pass" : "fail",
    unit_count: unitOutputs.length,
    compliant_unit_count: unitOutputs.filter(unit => unit.status === "pass").length,
    finding_count: findings.length,
  };
  return {
    kind: "systemd-supervision-audit",
    schema_version: "v1",
    baseline_id: baseline.baseline_id,
    topology_authority: "grimnir-service-registry",
    observed_at: observations.observed_at,
    evaluated_at: now,
    freshness: {
      status: freshnessStatus,
      age_seconds: Math.max(0, Math.floor(observationAge / 1000)),
      max_age_seconds: baseline.freshness.max_age_seconds,
    },
    notifier: { status: observations.notifier?.status ?? "absent" },
    summary,
    units: unitOutputs,
    findings,
    extensions: [],
  };
}

const args = parseArgs(process.argv.slice(2));
const baseline = readJson(args.baseline, "baseline");
validateBaseline(baseline);
const registry = loadRegistry(readJson(args.registry, "registry"));
const declarations = loadDeclarations(readJson(args.declarations, "declarations"), registry);
const observationsRecord = readJson(args.observations, "observations");
const observations = loadObservations(observationsRecord, registry);
const audit = runAudit({ baseline, registry, declarations, observations: { ...observationsRecord, units: observations }, now: args.now });
process.stdout.write(`${JSON.stringify(audit, null, 2)}\n`);
if (audit.summary.finding_count > 0) process.exitCode = 1;
