// Dependency-free helpers for the pinned Grimnir maintenance-policy v1 contract
// (brokkr#33, grimnir#134). The validation semantics deliberately mirror the
// normative consumer validator in grimnir
// tests/scripts/validate-maintenance-policy-contract.mjs at the pinned revision
// recorded in docs/maintenance-policy-provenance.md. This module never executes
// a command and never mutates anything; it is pure data validation and
// mechanical derivation over JSON already read by the caller.
import crypto from "node:crypto";
import fs from "node:fs";

const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const typeMatches = (type, value) => ({
  object: plain(value),
  array: Array.isArray(value),
  string: typeof value === "string",
  integer: Number.isInteger(value),
  boolean: typeof value === "boolean",
  null: value === null,
})[type];

const UTC_SHAPE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
const CALENDAR_DATE_SHAPE = /^(\d{4})-(\d{2})-(\d{2})$/;

// Exact second-resolution UTC instant on a real calendar date.
export const strictUtc = (value) => {
  if (typeof value !== "string") return false;
  const match = UTC_SHAPE.exec(value);
  if (!match) return false;
  const instant = new Date(value);
  if (Number.isNaN(instant.getTime())) return false;
  const [, year, month, day, hour, minute, second] = match;
  return (
    instant.getUTCFullYear() === Number(year) &&
    instant.getUTCMonth() + 1 === Number(month) &&
    instant.getUTCDate() === Number(day) &&
    instant.getUTCHours() === Number(hour) &&
    instant.getUTCMinutes() === Number(minute) &&
    instant.getUTCSeconds() === Number(second)
  );
};

// A real Gregorian calendar date (rejects e.g. 2026-02-30).
export const realCalendarDate = (value) => {
  const match = CALENDAR_DATE_SHAPE.exec(value);
  if (!match) return false;
  const [, year, month, day] = match;
  const asUtc = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  return asUtc.getUTCFullYear() === Number(year) && asUtc.getUTCMonth() + 1 === Number(month) && asUtc.getUTCDate() === Number(day);
};

// Canonical JSON: recursively key-sorted (UTF-16 code unit order, JS default),
// no insignificant whitespace. Matches maintenance-policy-digest-jcs-v1's
// canonicalization rule and this repo's existing node-substrate-contract.mjs.
export const canonicalJson = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (plain(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
};

// maintenance-policy-digest-jcs-v1: sha256 over the canonical form of the full
// record with only the top-level policy_digest key removed.
export const policyDigest = (policy) => {
  const rest = { ...policy };
  delete rest.policy_digest;
  return `sha256:${crypto.createHash("sha256").update(canonicalJson(rest), "utf8").digest("hex")}`;
};

// --- Bounded ISO 8601 duration (day/hour/minute/second components only). ---
const DURATION_PATTERN = /^P(?=\d|T\d)(?:(\d+)D)?(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/;
export const isValidDuration = (value) => typeof value === "string" && DURATION_PATTERN.test(value);
export const durationToMs = (value) => {
  const match = DURATION_PATTERN.exec(value);
  if (!match) throw new Error(`invalid duration ${value}`);
  const [, d, h, mi, s] = match;
  return ((Number(d || 0) * 24 + Number(h || 0)) * 60 + Number(mi || 0)) * 60000 + Number(s || 0) * 1000;
};

// --- IANA timezone membership (Node's built-in tz database; UTC special-cased). ---
const KNOWN_TIME_ZONES = new Set(typeof Intl.supportedValuesOf === "function" ? Intl.supportedValuesOf("timeZone") : []);
export const isValidTimeZone = (tz) => tz === "UTC" || KNOWN_TIME_ZONES.has(tz);

// --- DST-aware local-time resolution using only built-in Intl (no external tz db). ---
function wallClockParts(instantMs, timeZone) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const parts = Object.fromEntries(dtf.formatToParts(new Date(instantMs)).filter((p) => p.type !== "literal").map((p) => [p.type, Number.parseInt(p.value, 10)]));
  return { year: parts.year, month: parts.month, day: parts.day, hour: parts.hour === 24 ? 0 : parts.hour, minute: parts.minute, second: parts.second };
}
function tzOffsetMinutes(instantMs, timeZone) {
  const p = wallClockParts(instantMs, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return Math.round((asUtc - instantMs) / 60000);
}

// Classifies one local wall-clock instant against a timezone: "normal" (one
// real instant), "ambiguous" (two, fall-back overlap), or "nonexistent"
// (zero, spring-forward gap). Mirrors grimnir's reference validator exactly.
export function classifyLocalTime(year, month, day, hour, minute, second, timeZone) {
  const wallAsUtc = Date.UTC(year, month - 1, day, hour, minute, second);
  const DAY = 24 * 3600 * 1000;
  const offsetEarly = tzOffsetMinutes(wallAsUtc - DAY, timeZone);
  const offsetLate = tzOffsetMinutes(wallAsUtc + DAY, timeZone);
  const candEarly = wallAsUtc - offsetEarly * 60000;
  const candLate = wallAsUtc - offsetLate * 60000;
  const reads = (instant) => {
    const p = wallClockParts(instant, timeZone);
    return p.year === year && p.month === month && p.day === day && p.hour === hour && p.minute === minute && p.second === second;
  };
  if (offsetEarly === offsetLate) return { kind: "normal", instant: candEarly };
  const earlyOk = reads(candEarly);
  const lateOk = reads(candLate);
  if (earlyOk && lateOk) return { kind: "ambiguous", first: Math.min(candEarly, candLate), second: Math.max(candEarly, candLate) };
  if (!earlyOk && !lateOk) return { kind: "nonexistent", shiftForward: Math.max(candEarly, candLate) };
  return { kind: "normal", instant: earlyOk ? candEarly : candLate };
}

const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
export const weekdayOf = (localDate) => {
  const [y, m, d] = localDate.split("-").map(Number);
  return WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
};

// Resolves the exact real instant (or instants) an explicitly-named scheduled
// occurrence date binds to, given the policy's window/dst_policy. This never
// enumerates "which date is due" itself (occurrence-calendar enumeration is
// explicitly out of scope for the v1 contract) -- the caller supplies the
// occurrence date; this only makes the DST resolution mechanical and
// checkable, exactly like the schema's window_occurrence.local_time_kind
// binding requires.
export function resolveWindowOccurrence(policy, localDate) {
  if (!realCalendarDate(localDate)) throw new Error("window occurrence date is not a real calendar date");
  if (!policy.window.days_of_week.includes(weekdayOf(localDate))) throw new Error("window occurrence date does not fall on a scheduled weekday");
  const [hh, mm] = policy.window.start_local_time.split(":").map(Number);
  const [y, mo, d] = localDate.split("-").map(Number);
  const resolved = classifyLocalTime(y, mo, d, hh, mm, 0, policy.timezone);
  let startMs;
  if (resolved.kind === "normal") {
    startMs = resolved.instant;
  } else if (resolved.kind === "nonexistent") {
    if (policy.dst_policy.nonexistent_time !== "shift_forward_to_next_valid") throw new Error(`no decision can exist for a nonexistent local time under nonexistent_time=${policy.dst_policy.nonexistent_time}`);
    startMs = resolved.shiftForward;
  } else {
    if (policy.dst_policy.ambiguous_time === "fail_closed") throw new Error("no decision can exist for an ambiguous local time under ambiguous_time=fail_closed");
    startMs = policy.dst_policy.ambiguous_time === "use_first_instant" ? resolved.first : resolved.second;
  }
  const endMs = startMs + durationToMs(policy.window.duration);
  const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  return { local_date: localDate, start: iso(startMs), end: iso(endMs), local_time_kind: resolved.kind };
}

// Mechanical decision-effect precedence (grimnir maintenance-policy-contract
// v1 "Missed-window, overdue, and maximum-deferral decision rules"), evaluated
// top to bottom -- the first matching rule wins. This is a pure function of
// the policy plus Brokkr-supplied missed_occurrences/deferral_elapsed; it is
// never itself a mutation authorization.
export function decisionEffect(policy, { missedOccurrences, deferralElapsedMs }) {
  if (policy.state.enabled === false) return { effect: "held", reason: "disabled" };
  if (policy.state.hold.active === true) return { effect: "held", reason: "hold_active" };
  if (missedOccurrences === 0) return { effect: "on_schedule", reason: "on_schedule" };
  const maxDeferralMs = durationToMs(policy.maximum_deferral.duration);
  if (deferralElapsedMs > maxDeferralMs) return { effect: "escalate_operator_gate", reason: "maximum_deferral_reached" };
  if (missedOccurrences >= policy.overdue.after_missed_windows) {
    return {
      escalate_operator_gate: { effect: "escalate_operator_gate", reason: "overdue_after_missed_windows" },
      run_as_soon_as_possible: { effect: "run_deferred", reason: "overdue_after_missed_windows" },
      hold: { effect: "held", reason: "overdue_after_missed_windows" },
    }[policy.overdue.behavior];
  }
  return {
    run_at_next_window: { effect: "deferred_to_next_window", reason: "missed_window" },
    run_as_soon_as_possible: { effect: "run_deferred", reason: "missed_window" },
    skip_occurrence: { effect: "skip_occurrence", reason: "missed_window" },
  }[policy.missed_window.behavior];
}

// --- Structural JSON-Schema-subset checker/validator, mirroring the reference
// --- validator's generic engine (adds "maximum", which the maintenance-policy
// --- schema uses and the node-substrate schema does not).
const SUPPORTED_KEYWORDS = new Set([
  "$schema", "$id", "$defs", "$ref", "title", "description", "oneOf", "const", "enum",
  "type", "minLength", "pattern", "format", "minimum", "maximum", "minItems", "uniqueItems",
  "items", "required", "properties", "additionalProperties",
]);
const resolveRef = (schema, ref) => {
  if (!ref.startsWith("#/")) throw new Error(`unsupported external schema ref ${ref}`);
  return ref.slice(2).split("/").reduce((value, raw) => value?.[raw.replaceAll("~1", "/").replaceAll("~0", "~")], schema);
};
export function checkSchema(schema, node = schema, at = "$") {
  if (typeof node === "boolean") return;
  if (!plain(node)) throw new Error(`schema node must be an object at ${at}`);
  for (const key of Object.keys(node)) {
    if (!SUPPORTED_KEYWORDS.has(key)) throw new Error(`unsupported JSON Schema keyword ${key} at ${at}`);
  }
  if (node.$ref !== undefined && !resolveRef(schema, node.$ref)) throw new Error(`unresolved ref ${node.$ref} at ${at}`);
  if (node.type !== undefined && !["object", "array", "string", "integer", "boolean", "null"].includes(node.type)) throw new Error(`unsupported type at ${at}`);
  if (node.format !== undefined && node.format !== "date-time") throw new Error(`unsupported format at ${at}`);
  for (const [key, child] of Object.entries(node.properties ?? {})) checkSchema(schema, child, `${at}.properties.${key}`);
  for (const [key, child] of Object.entries(node.$defs ?? {})) checkSchema(schema, child, `${at}.$defs.${key}`);
  if (node.items) checkSchema(schema, node.items, `${at}.items`);
  for (const [index, child] of (node.oneOf ?? []).entries()) checkSchema(schema, child, `${at}.oneOf[${index}]`);
}
export function schemaErrors(schema, value, node = schema, at = "$") {
  if (node === true) return [];
  if (node === false) return [`${at}: forbidden`];
  if (node.$ref) return schemaErrors(schema, value, resolveRef(schema, node.$ref), at);
  if (node.oneOf) {
    const attempts = node.oneOf.map((child) => schemaErrors(schema, value, child, at));
    return attempts.filter((errors) => errors.length === 0).length === 1 ? [] : [`${at}: expected exactly one branch (${attempts.flat().join("; ")})`];
  }
  const errors = [];
  if (Object.hasOwn(node, "const") && canonicalJson(value) !== canonicalJson(node.const)) errors.push(`${at}: const mismatch`);
  if (node.enum && !node.enum.some((candidate) => canonicalJson(candidate) === canonicalJson(value))) errors.push(`${at}: enum mismatch`);
  if (node.type && !typeMatches(node.type, value)) return [...errors, `${at}: expected ${node.type}`];
  if (typeof value === "string") {
    if (node.minLength !== undefined && value.length < node.minLength) errors.push(`${at}: minLength`);
    if (node.pattern && !new RegExp(node.pattern).test(value)) errors.push(`${at}: pattern`);
    if (node.format === "date-time" && !UTC_SHAPE.test(value)) errors.push(`${at}: date-time`);
  }
  if (typeof value === "number") {
    if (node.minimum !== undefined && value < node.minimum) errors.push(`${at}: minimum`);
    if (node.maximum !== undefined && value > node.maximum) errors.push(`${at}: maximum`);
  }
  if (Array.isArray(value)) {
    if (node.minItems !== undefined && value.length < node.minItems) errors.push(`${at}: minItems`);
    if (node.uniqueItems && new Set(value.map(canonicalJson)).size !== value.length) errors.push(`${at}: duplicate items`);
    if (node.items) value.forEach((item, index) => errors.push(...schemaErrors(schema, item, node.items, `${at}[${index}]`)));
  }
  if (plain(value)) {
    for (const field of node.required ?? []) if (!Object.hasOwn(value, field)) errors.push(`${at}.${field}: required`);
    for (const [field, child] of Object.entries(node.properties ?? {})) if (Object.hasOwn(value, field)) errors.push(...schemaErrors(schema, value[field], child, `${at}.${field}`));
    if (node.additionalProperties === false) for (const field of Object.keys(value)) if (!Object.hasOwn(node.properties ?? {}, field)) errors.push(`${at}.${field}: additional property`);
  }
  return errors;
}

// --- Byte pins recorded in docs/maintenance-policy-provenance.md. Checked
// --- before the schema is ever parsed so a hostile/accidental local edit
// --- cannot silently redefine the contract this planner enforces.
export const PINNED_CONTRACT_SHA256 = Object.freeze({
  schema: "c5d26173698c976ab8c330f41f6bf97c8a921ccecb81b7f4659954524b3503e1",
  provenance: "ec2ab1b23d3cbad94f5c576978f797fcde387b7881190a3800d4a1bdd3b9f562",
});
const sha256File = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
export function assertPinnedContractFiles({ schemaPath, provenancePath }) {
  for (const [name, file, expected] of [["schema", schemaPath, PINNED_CONTRACT_SHA256.schema], ["provenance", provenancePath, PINNED_CONTRACT_SHA256.provenance]]) {
    let actual;
    try { actual = sha256File(file); } catch { throw new Error(`pinned ${name} is unavailable`); }
    if (actual !== expected) throw new Error(`pinned ${name} SHA-256 mismatch`);
  }
}
