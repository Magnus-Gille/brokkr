// Authoritative Brokkr journal for Grimnir ADR-008's bounded no-reboot
// security/bugfix maintenance class. No production authority is bundled here:
// every attempt must independently verify W0.2 owner authorization, coverage,
// owner attestation, recovery keys, and the protected narrowing tail.
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { performance } from "node:perf_hooks";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  autonomyDigest, canonicalJson, effectiveTargetState, strictUtc,
  verifyOwnerAuthorizationBundle, verifyRuntimeNarrowingLedger,
} from "./lib/autonomy-authorization.mjs";
import {
  durationToMs, policyDigest,
} from "./lib/maintenance-policy-contract.mjs";
import { createBoundedRecoveryDispatcher } from "./lib/bounded-recovery-dispatch.mjs";
import { windowStatus } from "./maintenance-controller.mjs";

const DOMAIN = "no-reboot-security-bugfix-maintenance";
const SCHEMA_ID = "https://grimnir.gille.ai/contracts/autonomous-mutation-journal/v2/schema.json";
const SCHEMA_SHA256 = "fc0d87d815c6fda3b14116e0e8840e8ecbe8e3df77bbeaf74b2064184ad036f4";
const LOCAL_SCHEMA_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../docs/autonomous-mutation-journal-v2.schema.json",
);
const PINNED_SCHEMAS = new WeakSet();
const MAX_BYTES = 256 * 1024;
const ID = /^[a-z][a-z0-9-]{2,62}$/;
const REF = /^ref:[a-z][a-z0-9-]{2,120}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const TERMINAL = new Set(["commit", "disarm", "terminally-blocked"]);
const BOUNDED_RECOVERY_FACTORY = Symbol("bounded-recovery-factory");
const OUTCOME = Object.freeze({
  prepare: "prepared", apply: "applied", verify: "verified", watch: "watching",
  commit: "committed", unknown: "unknown", recover: "recovered",
  quarantine: "quarantined", disarm: "disarmed", "terminally-blocked": "terminally-blocked",
});
const NEXT = Object.freeze({
  prepare: new Set(["apply", "unknown"]),
  apply: new Set(["verify", "unknown"]),
  verify: new Set(["watch", "unknown"]),
  watch: new Set(["commit", "unknown"]),
  commit: new Set(),
  unknown: new Set(["recover", "terminally-blocked"]),
  recover: new Set(["quarantine", "terminally-blocked"]),
  quarantine: new Set(["disarm", "terminally-blocked"]),
  disarm: new Set(),
  "terminally-blocked": new Set(),
});
const fail = (code, cause = undefined) => {
  const error = new Error(code, cause === undefined ? undefined : { cause });
  error.code = code;
  throw error;
};
const diagnosticCode = error => String(
  error?.code ?? error?.message ?? "unknown-error",
).slice(0, 96);
const assert = (condition, code) => { if (!condition) fail(code); };
const plain = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => (
  plain(value) && Object.keys(value).sort().join(",") === [...keys].sort().join(",")
);
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
const LOCK_TICKET_FILE = /^(\d+)\.json$/;
const LOCK_TICKET_DONE_FILE = /^(\d+)\.done$/;
const LOCK_TICKET_IMMUTABLE_CHECKPOINT_FILE = /^checkpoint\.(\d+)\.json$/;
const LOCK_TICKET_TMP_FILE =
  /^((?:\d+\.json)|(?:\d+\.done)|(?:checkpoint(?:\.\d+)?\.json))\.(\d+)(?:\.([a-f0-9]{16}))?\.([0-9a-f-]{36})\.tmp$/;
const LOCK_TICKET_CHECKPOINT = "checkpoint.json";
const LOCK_TICKET_COMPACTION_THRESHOLD = 256;
const LOCK_TICKET_ACQUIRE_RETRIES = 8;
const LOCK_TICKET_LIVE_HARD_LIMIT = LOCK_TICKET_COMPACTION_THRESHOLD;
const LOCK_TICKET_TMP_HARD_LIMIT = 64;
const LOCK_TICKET_OWNER_STAMP_HEX = 16;
const LEGACY_LOCK_TICKET_REUSE_MARGIN_MS = 5_000;
const LOCK_OWNER_PROBE_ENV = "BROKKR_ENABLE_TEST_LOCK_OWNER_PROBE";
const AUTHORITATIVE_PROCESS_START = /^linux-start:[1-9]\d*$/;
const ESTIMATED_BOOT_ID = /^(boot-estimate:|boot-id-unavailable(?::|$))/;
const testLockOwnerProbe = () => (
  process.env[LOCK_OWNER_PROBE_ENV] === "1" ?
    globalThis.__BROKKR_TEST_LOCK_OWNER_PROBE__ ?? null :
    null
);
const inferBootIdAuthoritative = value => !ESTIMATED_BOOT_ID.test(value);
const inferProcessStartAuthoritative = value => AUTHORITATIVE_PROCESS_START.test(value);
function normalizeLockOwnerEvidence(value, inferAuthoritative) {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value === "string" && value.length >= 1) {
    return { value, authoritative: inferAuthoritative(value) };
  }
  if (plain(value) &&
      typeof value.value === "string" &&
      value.value.length >= 1 &&
      typeof value.authoritative === "boolean") {
    return { value: value.value, authoritative: value.authoritative };
  }
  return undefined;
}
const parsePositiveInteger = value => {
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
};
const readLinuxProcessStartTime = pid => {
  try {
    const raw = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
    const close = raw.lastIndexOf(")");
    if (close < 0) return null;
    const fields = raw.slice(close + 2).trim().split(/\s+/);
    const startTime = fields[19];
    return /^[1-9]\d*$/.test(startTime) ? {
      value: `linux-start:${startTime}`,
      authoritative: true,
    } : null;
  } catch (error) {
    if (["ENOENT", "ENOTDIR", "EACCES", "EPERM"].includes(error?.code)) return null;
    throw error;
  }
};
let linuxClockTicksPerSecond;
const readLinuxClockTicksPerSecond = () => {
  if (linuxClockTicksPerSecond !== undefined) return linuxClockTicksPerSecond;
  try {
    const raw = execFileSync("/usr/bin/getconf", ["CLK_TCK"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1_000,
    }).trim();
    const parsed = parsePositiveInteger(raw);
    linuxClockTicksPerSecond = parsed;
  } catch {
    linuxClockTicksPerSecond = null;
  }
  return linuxClockTicksPerSecond;
};
const readLinuxBootEpochMs = () => {
  try {
    const raw = fs.readFileSync("/proc/stat", "utf8");
    const matched = /^btime\s+([1-9]\d*)$/m.exec(raw);
    const seconds = matched ? Number.parseInt(matched[1], 10) : NaN;
    return Number.isSafeInteger(seconds) ? seconds * 1_000 : null;
  } catch (error) {
    if (["ENOENT", "ENOTDIR", "EACCES", "EPERM"].includes(error?.code)) return null;
    throw error;
  }
};
const legacyLockOwnerPidReused = owner => {
  const testValue = testLockOwnerProbe()?.processStartedAfterLegacyTicket?.(
    owner.pid,
    owner.legacy_ticket_mtime_ms,
  );
  if (typeof testValue === "boolean") return testValue;
  if (!Number.isFinite(owner.legacy_ticket_mtime_ms) ||
      owner.legacy_ticket_mtime_ms <= 0) return false;
  const processStart = readLinuxProcessStartTime(owner.pid);
  const ticksPerSecond = readLinuxClockTicksPerSecond();
  const bootEpochMs = readLinuxBootEpochMs();
  const ticks = processStart?.authoritative === true ?
    Number.parseInt(processStart.value.slice("linux-start:".length), 10) :
    NaN;
  if (!Number.isSafeInteger(ticks) || ticks <= 0 ||
      ticksPerSecond === null || bootEpochMs === null) return false;
  const processStartEpochMs = bootEpochMs + ticks * 1_000 / ticksPerSecond;
  return processStartEpochMs >=
    owner.legacy_ticket_mtime_ms + LEGACY_LOCK_TICKET_REUSE_MARGIN_MS;
};
const FALLBACK_BOOT_IDENTITY = (() => {
  try {
    // This stays an estimate, but bucket it at a host-wide second boundary so
    // concurrent processes do not trivially diverge by millisecond jitter.
    return {
      value: `boot-estimate:${Math.max(0, Math.round(Date.now() / 1000 - os.uptime()))}`,
      authoritative: false,
    };
  } catch {
    try {
      return { value: `boot-id-unavailable:${os.hostname()}`, authoritative: false };
    } catch {
      return { value: "boot-id-unavailable", authoritative: false };
    }
  }
})();
const SYSTEM_BOOT_IDENTITY = (() => {
  try {
    const bootId = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
    return bootId.length >= 1 ? {
      value: bootId,
      authoritative: true,
    } : FALLBACK_BOOT_IDENTITY;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return FALLBACK_BOOT_IDENTITY;
  }
})();
const SELF_PROCESS_START_IDENTITY =
  readLinuxProcessStartTime(process.pid) ?? {
    value: `time-origin:${Math.trunc(performance.timeOrigin)}`,
    authoritative: false,
  };
const currentBootIdentity = () => {
  const value = normalizeLockOwnerEvidence(
    testLockOwnerProbe()?.currentBootId?.(),
    inferBootIdAuthoritative,
  );
  return value ?? SYSTEM_BOOT_IDENTITY;
};
const currentProcessStartIdentity = () => {
  const value = normalizeLockOwnerEvidence(
    testLockOwnerProbe()?.processStartTime?.(process.pid),
    inferProcessStartAuthoritative,
  );
  return value ?? SELF_PROCESS_START_IDENTITY;
};
const lockOwnerIdentityStamp = ({
  boot_id,
  boot_id_authoritative = false,
  process_start_time,
  process_start_time_authoritative = false,
}) => sha256([
  boot_id_authoritative ? "1" : "0",
  boot_id ?? "",
  process_start_time_authoritative ? "1" : "0",
  process_start_time ?? "",
].join("\n")).slice(0, LOCK_TICKET_OWNER_STAMP_HEX);
const currentLockOwnerIdentity = () => {
  const bootIdentity = currentBootIdentity();
  const processStartIdentity = currentProcessStartIdentity();
  return {
    pid: process.pid,
    boot_id: bootIdentity.value,
    boot_id_authoritative: bootIdentity.authoritative,
    process_start_time: processStartIdentity.value,
    process_start_time_authoritative: processStartIdentity.authoritative,
  };
};
const readProcessStartIdentity = pid => {
  const testValue = normalizeLockOwnerEvidence(
    testLockOwnerProbe()?.processStartTime?.(pid),
    inferProcessStartAuthoritative,
  );
  if (testValue !== undefined) return testValue;
  if (pid === process.pid) return currentProcessStartIdentity();
  return readLinuxProcessStartTime(pid);
};
const readLiveOwnerStamp = pid => {
  const bootIdentity = currentBootIdentity();
  const processStartIdentity = readProcessStartIdentity(pid);
  if (processStartIdentity === null ||
      !bootIdentity.authoritative ||
      !processStartIdentity.authoritative) {
    return null;
  }
  return lockOwnerIdentityStamp({
    boot_id: bootIdentity.value,
    boot_id_authoritative: bootIdentity.authoritative,
    process_start_time: processStartIdentity.value,
    process_start_time_authoritative: processStartIdentity.authoritative,
  });
};
const boundedJson = file => {
  const raw = fs.readFileSync(file, "utf8");
  assert(Buffer.byteLength(raw) <= MAX_BYTES, "journal_too_large");
  try { return JSON.parse(raw); }
  catch (error) { fail("journal_invalid_json", error); }
};
const fsyncDirectory = directory => {
  const fd = fs.openSync(directory, "r");
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
};
const lockTicketFault = point => {
  if (process.env.BROKKR_ENABLE_TEST_LOCK_TICKET_FAULTS === "1") {
    globalThis.__BROKKR_TEST_LOCK_TICKET_FAULT__?.(point);
  }
};
const publishFault = (tag, boundary) => {
  if (tag) lockTicketFault(`after-${tag}-${boundary}`);
};
const unlinkIfExists = file => {
  try { fs.unlinkSync(file); }
  catch (error) { if (error.code !== "ENOENT") throw error; }
};
function writeAtomic(file, value, options = {}) {
  const { faultTag = null } = options;
  const encoded = `${canonicalJson(value)}\n`;
  assert(Buffer.byteLength(encoded) <= MAX_BYTES, "journal_too_large");
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  publishFault(faultTag, "open");
  try {
    fs.writeFileSync(fd, encoded);
    publishFault(faultTag, "write");
    fs.fsyncSync(fd);
    publishFault(faultTag, "fsync");
  } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, file);
  publishFault(faultTag, "rename");
  fsyncDirectory(path.dirname(file));
}
function createExclusive(file, value, options = {}) {
  const { faultTag = null } = options;
  const directory = path.dirname(file);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const encoded = `${canonicalJson(value)}\n`;
  assert(Buffer.byteLength(encoded) <= MAX_BYTES, "journal_too_large");
  const temporary = `${file}.${process.pid}.${lockOwnerIdentityStamp(
    currentLockOwnerIdentity(),
  )}.${crypto.randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  publishFault(faultTag, "open");
  try {
    fs.writeFileSync(fd, encoded);
    publishFault(faultTag, "write");
    fs.fsyncSync(fd);
    publishFault(faultTag, "fsync");
  } finally { fs.closeSync(fd); }
  try { fs.linkSync(temporary, file); }
  catch (error) {
    unlinkIfExists(temporary);
    if (error.code === "EEXIST") return false;
    throw error;
  }
  publishFault(faultTag, "link");
  fsyncDirectory(directory);
  unlinkIfExists(temporary);
  fsyncDirectory(directory);
  return true;
}
function readOptional(file) {
  try { return boundedJson(file); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
}
const stateRoot = journalDir => path.join(journalDir, ".autonomy-state");
const targetKey = binding => binding.target_scope_digest.slice("sha256:".length);
const domainStateFile = journalDir => path.join(stateRoot(journalDir), "domain-state.json");
const domainLockDir = journalDir => path.join(stateRoot(journalDir), "domain-state.lock");
const lockTicketPrefix = sequence => String(sequence).padStart(8, "0");
const lockTicketCheckpointFile = sequence => `checkpoint.${lockTicketPrefix(sequence)}.json`;
function readLockCheckpointRecord(file, sequence = null) {
  const checkpoint = readOptional(file);
  if (checkpoint === null) return null;
  assert(exactKeys(checkpoint, [
    "kind", "schema_version", "last_completed_sequence",
    "last_completed_token", "next_sequence",
  ]) && checkpoint.kind === "brokkr-lock-ticket-checkpoint" &&
    checkpoint.schema_version === "v1" &&
    Number.isSafeInteger(checkpoint.last_completed_sequence) &&
    checkpoint.last_completed_sequence >= 0 &&
    typeof checkpoint.last_completed_token === "string" &&
    checkpoint.last_completed_token.length >= 1 &&
    Number.isSafeInteger(checkpoint.next_sequence) &&
    checkpoint.next_sequence === checkpoint.last_completed_sequence + 1,
  "lock_checkpoint_invalid");
  if (sequence !== null) {
    assert(
      checkpoint.last_completed_sequence === sequence &&
      checkpoint.next_sequence === sequence + 1,
      "lock_checkpoint_invalid",
    );
  }
  return checkpoint;
}
function selectLockCheckpoint(current, candidate) {
  if (candidate === null) return current;
  if (current === null) return candidate;
  if (candidate.record.last_completed_sequence > current.record.last_completed_sequence) {
    return candidate;
  }
  if (candidate.record.last_completed_sequence < current.record.last_completed_sequence) {
    return current;
  }
  assert(
    candidate.record.last_completed_token === current.record.last_completed_token,
    "lock_checkpoint_conflict",
  );
  if (current.name === LOCK_TICKET_CHECKPOINT && candidate.name !== LOCK_TICKET_CHECKPOINT) {
    return candidate;
  }
  return current;
}
function selectedLockCheckpoint(tickets) {
  let selected = null;
  for (const name of fs.readdirSync(tickets)) {
    if (name === LOCK_TICKET_CHECKPOINT) {
      const record = readLockCheckpointRecord(path.join(tickets, name));
      if (record !== null) {
        selected = selectLockCheckpoint(selected, { name, record });
      }
      continue;
    }
    const sequence = parsePositiveInteger(LOCK_TICKET_IMMUTABLE_CHECKPOINT_FILE.exec(name)?.[1]);
    if (sequence === null) continue;
    const record = readLockCheckpointRecord(path.join(tickets, name), sequence);
    if (record !== null) {
      selected = selectLockCheckpoint(selected, { name, record });
    }
  }
  return selected;
}
function readLockCheckpoint(tickets) {
  return selectedLockCheckpoint(tickets)?.record ?? null;
}
function lockTicketTemp(name) {
  if (!name.endsWith(".tmp")) return null;
  const match = LOCK_TICKET_TMP_FILE.exec(name);
  if (!match) return { name, pid: null, ownerStamp: null };
  return {
    name,
    pid: parsePositiveInteger(match[2]),
    ownerStamp: match[3] ?? null,
  };
}
function reclaimInvalidLockTicketArtifacts(tickets) {
  let reclaimed = false;
  for (const name of fs.readdirSync(tickets)) {
    const rawSequence = LOCK_TICKET_FILE.exec(name)?.[1] ??
      LOCK_TICKET_DONE_FILE.exec(name)?.[1] ??
      LOCK_TICKET_IMMUTABLE_CHECKPOINT_FILE.exec(name)?.[1];
    if (rawSequence === undefined || parsePositiveInteger(rawSequence) !== null) continue;
    try {
      fs.unlinkSync(path.join(tickets, name));
      reclaimed = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (reclaimed) fsyncDirectory(tickets);
}
function pruneCheckpointedLockTickets(tickets, floor) {
  let pruned = false;
  const selected = selectedLockCheckpoint(tickets);
  for (const name of fs.readdirSync(tickets)) {
    if (name === LOCK_TICKET_CHECKPOINT) {
      if (selected?.name === name && selected.record.last_completed_sequence >= floor) continue;
    } else {
      const sequence = parsePositiveInteger(LOCK_TICKET_FILE.exec(name)?.[1]) ??
        parsePositiveInteger(LOCK_TICKET_DONE_FILE.exec(name)?.[1]) ??
        parsePositiveInteger(LOCK_TICKET_IMMUTABLE_CHECKPOINT_FILE.exec(name)?.[1]);
      if (sequence === null || sequence > floor) continue;
      if (selected?.name === name && sequence === floor) continue;
    }
    lockTicketFault("before-lock-prune-unlink");
    try {
      fs.unlinkSync(path.join(tickets, name));
      pruned = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (pruned) fsyncDirectory(tickets);
}
function lockTicketEntries(tickets, floor) {
  return fs.readdirSync(tickets).flatMap(name => {
    const sequence = parsePositiveInteger(LOCK_TICKET_FILE.exec(name)?.[1]);
    if (sequence === null || sequence <= floor) return [];
    return [{ name, prefix: lockTicketPrefix(sequence), sequence }];
  }).sort((left, right) => left.sequence - right.sequence);
}
function readLockTicketRecord(tickets, entry) {
  let existing;
  let ticketMtimeMs;
  const ticketPath = path.join(tickets, entry.name);
  try {
    existing = boundedJson(ticketPath);
    ticketMtimeMs = fs.statSync(ticketPath).mtimeMs;
  }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  const legacyOwner = exactKeys(existing, [
    "kind", "schema_version", "pid", "token", "sequence",
  ]);
  const stampedOwner = exactKeys(existing, [
    "kind", "schema_version", "pid", "boot_id", "process_start_time", "token", "sequence",
  ]);
  const stampedOwnerWithAuthority = exactKeys(existing, [
    "kind", "schema_version", "pid", "boot_id", "boot_id_authoritative",
    "process_start_time", "process_start_time_authoritative", "token", "sequence",
  ]);
  assert((legacyOwner || stampedOwner || stampedOwnerWithAuthority) &&
    existing.kind === "brokkr-lock-ticket" && existing.schema_version === "v1" &&
    Number.isSafeInteger(existing.pid) && existing.pid > 0 &&
    typeof existing.token === "string" && existing.token.length >= 1 &&
    existing.sequence === entry.sequence &&
    (!(stampedOwner || stampedOwnerWithAuthority) || (
      typeof existing.boot_id === "string" && existing.boot_id.length >= 1 &&
      typeof existing.process_start_time === "string" &&
      existing.process_start_time.length >= 1
    )) &&
    (!stampedOwnerWithAuthority || (
      typeof existing.boot_id_authoritative === "boolean" &&
      typeof existing.process_start_time_authoritative === "boolean"
    )),
  "lock_owner_invalid");
  return (stampedOwner || stampedOwnerWithAuthority) ? {
    ...existing,
    boot_id_authoritative: stampedOwnerWithAuthority ?
      existing.boot_id_authoritative :
      inferBootIdAuthoritative(existing.boot_id),
    process_start_time_authoritative: stampedOwnerWithAuthority ?
      existing.process_start_time_authoritative :
      inferProcessStartAuthoritative(existing.process_start_time),
  } : {
    ...existing,
    boot_id: null,
    boot_id_authoritative: false,
    process_start_time: null,
    process_start_time_authoritative: false,
    legacy_ticket_mtime_ms: ticketMtimeMs,
  };
}
function checkpointCompletesLockTicket(checkpoint, ticket) {
  if (checkpoint === null || checkpoint.last_completed_sequence < ticket.sequence) return false;
  if (checkpoint.last_completed_sequence === ticket.sequence) {
    assert(checkpoint.last_completed_token === ticket.token, "lock_checkpoint_conflict");
  }
  return true;
}
function hasValidLockCompletion(tickets, entry, ticket, checkpoint) {
  if (checkpointCompletesLockTicket(checkpoint, ticket)) return true;
  try {
    const completion = boundedJson(path.join(tickets, `${entry.prefix}.done`));
    assert(exactKeys(completion, ["kind", "schema_version", "token", "sequence"]) &&
      completion.kind === "brokkr-lock-ticket-completion" &&
      completion.schema_version === "v1" &&
      completion.token === ticket.token &&
      completion.sequence === ticket.sequence,
    "lock_completion_invalid");
    return true;
  } catch (error) {
    if (["ENOENT", "journal_invalid_json", "journal_too_large", "lock_completion_invalid"]
      .includes(error.code)) {
      return false;
    }
    throw error;
  }
}
function lockOwnerProvablyDead(owner) {
  assert(Number.isSafeInteger(owner.pid) && owner.pid > 0, "lock_owner_invalid");
  if (owner.boot_id !== null) {
    assert(typeof owner.boot_id === "string" && owner.boot_id.length >= 1 &&
      typeof owner.boot_id_authoritative === "boolean" &&
      typeof owner.process_start_time === "string" &&
      owner.process_start_time.length >= 1 &&
      typeof owner.process_start_time_authoritative === "boolean",
    "lock_owner_invalid");
  }
  try {
    process.kill(owner.pid, 0);
  } catch (error) {
    if (error.code === "ESRCH") return true;
    if (error.code !== "EPERM") throw error;
  }
  if (owner.boot_id !== null) {
    const bootIdentity = currentBootIdentity();
    if (owner.boot_id_authoritative &&
        bootIdentity.authoritative &&
        owner.boot_id !== bootIdentity.value) {
      return true;
    }
  }
  if (owner.process_start_time === null) {
    return legacyLockOwnerPidReused(owner);
  }
  const processStartIdentity = readProcessStartIdentity(owner.pid);
  if (processStartIdentity === null) return false;
  return owner.process_start_time_authoritative &&
    processStartIdentity.authoritative &&
    owner.process_start_time !== processStartIdentity.value;
}
function lockOwnerAlive(owner) {
  return !lockOwnerProvablyDead(owner);
}
function lockTicketTempAlive(temporary) {
  if (temporary.pid === null) return false;
  try {
    process.kill(temporary.pid, 0);
  } catch (error) {
    if (error.code === "ESRCH") return false;
    if (error.code !== "EPERM") throw error;
  }
  if (temporary.ownerStamp === null) return true;
  const liveStamp = readLiveOwnerStamp(temporary.pid);
  if (liveStamp === null) return true;
  return liveStamp === temporary.ownerStamp;
}
function reclaimLockTicketCandidate(tickets, ticket) {
  try {
    fs.unlinkSync(path.join(tickets, `${lockTicketPrefix(ticket.sequence)}.json`));
    fsyncDirectory(tickets);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
function reclaimLockTicketTemps(tickets) {
  let reclaimed = false;
  for (const name of fs.readdirSync(tickets)) {
    const temporary = lockTicketTemp(name);
    if (!temporary || lockTicketTempAlive(temporary)) continue;
    try {
      fs.unlinkSync(path.join(tickets, temporary.name));
      reclaimed = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (reclaimed) fsyncDirectory(tickets);
  let remainingTemps = 0;
  for (const name of fs.readdirSync(tickets)) {
    if (lockTicketTemp(name)) remainingTemps += 1;
  }
  assert(remainingTemps <= LOCK_TICKET_TMP_HARD_LIMIT, "lock_ticket_tmp_limit");
}
function publishLockCheckpoint(tickets, ticket) {
  const current = readLockCheckpoint(tickets);
  if (checkpointCompletesLockTicket(current, ticket)) return current;
  if (current !== null && current.last_completed_sequence > ticket.sequence) {
    return current;
  }
  createExclusive(path.join(
    tickets,
    lockTicketCheckpointFile(ticket.sequence),
  ), {
    kind: "brokkr-lock-ticket-checkpoint",
    schema_version: "v1",
    last_completed_sequence: ticket.sequence,
    last_completed_token: ticket.token,
    next_sequence: ticket.sequence + 1,
  }, { faultTag: "lock-checkpoint" });
  const published = readLockCheckpoint(tickets);
  assert(published !== null &&
    published.last_completed_sequence >= ticket.sequence,
  "lock_checkpoint_regressed");
  if (published.last_completed_sequence === ticket.sequence) {
    assert(published.last_completed_token === ticket.token, "lock_checkpoint_conflict");
  }
  return published;
}
function completedLockTicketPrefix(tickets, checkpoint = readLockCheckpoint(tickets)) {
  const floor = checkpoint?.last_completed_sequence ?? 0;
  let nextSequence = floor + 1;
  let candidate = null;
  let length = 0;
  for (const entry of lockTicketEntries(tickets, floor)) {
    if (entry.sequence !== nextSequence) break;
    const ticket = readLockTicketRecord(tickets, entry);
    if (ticket === null || !hasValidLockCompletion(tickets, entry, ticket, checkpoint)) break;
    candidate = ticket;
    length += 1;
    nextSequence += 1;
  }
  return { candidate, length };
}
function compactCompletedLockTicketPrefix(
  tickets,
  checkpoint = readLockCheckpoint(tickets),
  options = {},
) {
  const { allowTailCompaction = true } = options;
  const prefix = completedLockTicketPrefix(tickets, checkpoint);
  const floor = checkpoint?.last_completed_sequence ?? 0;
  const unresolvedTail = lockTicketEntries(tickets, floor).length - prefix.length;
  if (prefix.candidate === null ||
      (prefix.length < LOCK_TICKET_COMPACTION_THRESHOLD &&
        (!allowTailCompaction || unresolvedTail === 0))) {
    return checkpoint;
  }
  const current = publishLockCheckpoint(tickets, prefix.candidate);
  pruneCheckpointedLockTickets(tickets, current.last_completed_sequence);
  return current;
}
function completionFailure(error) {
  if ([
    "lock_completion_conflict",
    "lock_checkpoint_conflict",
    "lock_checkpoint_invalid",
    "lock_checkpoint_regressed",
    "lock_ticket_stale_below_floor",
  ].includes(error?.code)) {
    return error;
  }
  const wrapped = new Error("lock_completion_ambiguous", { cause: error });
  wrapped.code = "lock_completion_ambiguous";
  return wrapped;
}
function preserveReleaseFailure(operationError, releaseError) {
  if (!operationError) return;
  operationError.lock_release_error = completionFailure(releaseError);
  if (operationError.cause === undefined) {
    operationError.cause = operationError.lock_release_error;
  }
}
function releaseLockTicket(tickets, ticket) {
  const startingCheckpoint = readLockCheckpoint(tickets);
  let checkpoint = compactCompletedLockTicketPrefix(tickets, startingCheckpoint, {
    allowTailCompaction: false,
  });
  if (checkpoint !== null && checkpoint.last_completed_sequence >= ticket.sequence) {
    if (checkpoint.last_completed_sequence === ticket.sequence) {
      assert(checkpoint.last_completed_token === ticket.token, "lock_checkpoint_conflict");
      try {
        lockTicketFault("after-lock-release-visible-before-prune");
        pruneCheckpointedLockTickets(tickets, checkpoint.last_completed_sequence);
        return;
      } catch (error) { return error; }
    }
    fail("lock_ticket_stale_below_floor");
  }
  const floor = checkpoint?.last_completed_sequence ?? 0;
  const releasePrefix = completedLockTicketPrefix(tickets, checkpoint);
  if (releasePrefix.length + 1 >= LOCK_TICKET_COMPACTION_THRESHOLD &&
      ticket.sequence === floor + releasePrefix.length + 1) {
    checkpoint = publishLockCheckpoint(tickets, ticket);
    try {
      lockTicketFault("after-lock-release-visible-before-prune");
      pruneCheckpointedLockTickets(tickets, checkpoint.last_completed_sequence);
      return;
    } catch (error) { return error; }
  }
  assert(createExclusive(path.join(
    tickets,
    `${lockTicketPrefix(ticket.sequence)}.done`,
  ), {
    kind: "brokkr-lock-ticket-completion",
    schema_version: "v1",
    token: ticket.token,
    sequence: ticket.sequence,
  }, {
    faultTag: "lock-completion",
  }), "lock_completion_conflict");
  try {
    lockTicketFault("after-lock-release-visible-before-prune");
    return;
  } catch (error) { return error; }
}
function withExclusiveDirectory(lockDir, code, operation) {
  const tickets = `${lockDir}.tickets`;
  fs.mkdirSync(tickets, { recursive: true, mode: 0o700 });
  const token = crypto.randomUUID();
  let ticket = null;
  for (let attempt = 0; attempt < LOCK_TICKET_ACQUIRE_RETRIES; attempt += 1) {
    reclaimLockTicketTemps(tickets);
    reclaimInvalidLockTicketArtifacts(tickets);
    let checkpoint = readLockCheckpoint(tickets);
    if (checkpoint !== null) pruneCheckpointedLockTickets(tickets, checkpoint.last_completed_sequence);
    checkpoint = compactCompletedLockTicketPrefix(tickets, checkpoint);
    const floor = checkpoint?.last_completed_sequence ?? 0;
    const entries = lockTicketEntries(tickets, floor);
    const unresolvedEntries = entries.length - completedLockTicketPrefix(tickets, checkpoint).length;
    assert(unresolvedEntries < LOCK_TICKET_LIVE_HARD_LIMIT, "lock_ticket_live_limit");
    let sequence = checkpoint?.next_sequence ?? 1;
    if (entries.length) {
      const latestEntry = entries.at(-1);
      sequence = latestEntry.sequence + 1;
      lockTicketFault("before-lock-ticket-read");
      const existing = readLockTicketRecord(tickets, latestEntry);
      if (existing === null) continue;
      const refreshedCheckpoint = compactCompletedLockTicketPrefix(
        tickets,
        readLockCheckpoint(tickets),
      );
      if (refreshedCheckpoint?.last_completed_sequence >= latestEntry.sequence) {
        if (refreshedCheckpoint.last_completed_sequence === latestEntry.sequence) {
          assert(refreshedCheckpoint.last_completed_token === existing.token,
            "lock_checkpoint_conflict");
        }
        continue;
      }
      if (!hasValidLockCompletion(tickets, latestEntry, existing, refreshedCheckpoint)) {
        if (lockOwnerAlive(existing)) fail(code);
        reclaimLockTicketCandidate(tickets, existing);
        attempt -= 1;
        continue;
      }
    }
    const candidate = {
      kind: "brokkr-lock-ticket",
      schema_version: "v1",
      ...currentLockOwnerIdentity(),
      token,
      sequence,
    };
    if (!createExclusive(path.join(
      tickets,
      `${lockTicketPrefix(sequence)}.json`,
    ), candidate, {
      faultTag: "lock-ticket",
    })) {
      continue;
    }
    checkpoint = readLockCheckpoint(tickets);
    if (checkpoint !== null && checkpoint.last_completed_sequence >= candidate.sequence) {
      reclaimLockTicketCandidate(tickets, candidate);
      pruneCheckpointedLockTickets(tickets, checkpoint.last_completed_sequence);
      continue;
    }
    ticket = candidate;
    break;
  }
  assert(ticket !== null, "lock_ticket_acquire_retry_exhausted");
  let result = true;
  let operationError = null;
  try { result = operation(); }
  catch (error) { operationError = error; }
  try {
    lockTicketFault("after-lock-owner-operation");
    const compactionError = releaseLockTicket(tickets, ticket);
    if (operationError) {
      if (compactionError) preserveReleaseFailure(operationError, compactionError);
      throw operationError;
    }
    // A successful owner operation remains committed even if best-effort
    // post-release compaction or prune work later faults.
    return result;
  } catch (error) {
    if (operationError) {
      preserveReleaseFailure(operationError, error);
      throw operationError;
    }
    throw completionFailure(error);
  }
}
function claimTarget({
  journalDir, binding, bindingDigest, now, policy, resumeWatch = false,
}) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_claim_contended", () => {
    const leaseExpiry = new Date(Math.min(
      Date.parse(binding.deadline),
      Date.parse(now) + policy.bounds.max_silence_seconds * 1000,
    )).toISOString().replace(".000Z", "Z");
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile) ?? {
      kind: "brokkr-autonomy-domain-state", schema_version: "v1",
      active_target_scope_digest: null, active_attempt_id: null, recent_starts: [],
      targets: {}, revision: 0,
    };
    assert(exactKeys(domain, [
      "kind", "schema_version", "active_target_scope_digest", "active_attempt_id",
      "recent_starts", "targets", "revision",
    ]) && domain.kind === "brokkr-autonomy-domain-state" && domain.schema_version === "v1" &&
      Array.isArray(domain.recent_starts) && plain(domain.targets) &&
      Number.isSafeInteger(domain.revision), "domain_state_invalid");
    const key = targetKey(binding);
    const current = domain.targets[key] ?? {
      state: binding.admission_binding_state, lease_epoch: 0, execution_lease: null,
      last_started_at: null, proposal_attempts: {},
    };
    assert(exactKeys(current, [
      "state", "lease_epoch", "execution_lease", "last_started_at", "proposal_attempts",
    ]) && plain(current.proposal_attempts), "target_state_invalid");
    const suspendedWatch = resumeWatch && current.state === "watching" &&
      current.execution_lease === null;
    if (domain.active_attempt_id !== binding.attempt_id) {
      assert(domain.active_attempt_id === null && domain.active_target_scope_digest === null,
        "domain_concurrency_exceeded");
      if (!suspendedWatch) {
        const nowMs = Date.parse(now);
        domain.recent_starts = domain.recent_starts.filter(start => (
          strictUtc(start) && nowMs - Date.parse(start) <
            policy.bounds.attempt_window_seconds * 1000
        ));
        assert(!domain.recent_starts.some(start => (
          nowMs - Date.parse(start) <
            policy.bounds.min_seconds_between_attempts * 1000
        )), "attempt_interval_exceeded");
        assert(domain.recent_starts.length < policy.bounds.max_attempts_per_window,
          "attempt_window_exceeded");
        domain.recent_starts.push(now);
      }
      domain.active_target_scope_digest = binding.target_scope_digest;
      domain.active_attempt_id = binding.attempt_id;
    } else {
      assert(domain.active_target_scope_digest === binding.target_scope_digest,
        "domain_target_mismatch");
    }
    if (current.execution_lease !== null) {
      assert(exactKeys(current.execution_lease, [
        "attempt_id", "mutation_id", "binding_digest", "epoch", "holder_pid",
        "holder_token", "activated_at", "expires_at",
      ]) && current.execution_lease.attempt_id === binding.attempt_id &&
        current.execution_lease.mutation_id === binding.mutation_id &&
        current.execution_lease.binding_digest === bindingDigest &&
        current.execution_lease.epoch === current.lease_epoch &&
        Number.isSafeInteger(current.execution_lease.holder_pid) &&
        typeof current.execution_lease.holder_token === "string" &&
        strictUtc(current.execution_lease.activated_at) &&
        strictUtc(current.execution_lease.expires_at),
      "execution_lease_invalid");
      if (Date.parse(now) <= Date.parse(current.execution_lease.expires_at)) {
        return { acquired: false, lease: current.execution_lease, target: current };
      }
      current.lease_epoch += 1;
      current.execution_lease = {
        attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
        binding_digest: bindingDigest, epoch: current.lease_epoch,
        holder_pid: process.pid, holder_token: crypto.randomUUID(),
        activated_at: now, expires_at: leaseExpiry,
      };
      domain.revision += 1;
      writeAtomic(domainFile, domain);
      return { acquired: true, transferred: true, lease: current.execution_lease, target: current };
    }
    const attempts = current.proposal_attempts[binding.mutation_id] ?? 0;
    if (resumeWatch) {
      assert(current.state === "watching" && attempts === 1,
        "watch_continuation_invalid");
    } else {
      assert(current.state === binding.admission_binding_state,
        "target_state_not_armed");
      assert(attempts < policy.bounds.max_attempts,
        "proposal_attempts_exceeded");
    }
    current.lease_epoch += 1;
    current.execution_lease = {
      attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
      binding_digest: bindingDigest, epoch: current.lease_epoch,
      holder_pid: process.pid, holder_token: crypto.randomUUID(),
      activated_at: now, expires_at: leaseExpiry,
    };
    if (!resumeWatch) {
      current.last_started_at = now;
      current.proposal_attempts[binding.mutation_id] = attempts + 1;
    }
    domain.targets[key] = current;
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return { acquired: true, transferred: false, lease: current.execution_lease, target: current };
  });
}
function supersedeExecutionLease({
  journalDir, binding, bindingDigest, lease, now, policy,
}) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile);
    const current = assertLeaseRecord(domain, binding, bindingDigest, lease);
    const expiresAt = new Date(Math.min(
      Date.parse(binding.deadline),
      Date.parse(now) + policy.bounds.max_silence_seconds * 1000,
    )).toISOString().replace(".000Z", "Z");
    assert(Date.parse(now) <= Date.parse(lease.expires_at) &&
      Date.parse(now) <= Date.parse(expiresAt), "recovery_successor_lease_expired");
    current.lease_epoch += 1;
    current.execution_lease = {
      attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
      binding_digest: bindingDigest, epoch: current.lease_epoch,
      holder_pid: process.pid, holder_token: crypto.randomUUID(),
      activated_at: now, expires_at: expiresAt,
    };
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return current.execution_lease;
  });
}
function assertLeaseRecord(domain, binding, bindingDigest, lease) {
  const current = domain?.targets?.[targetKey(binding)];
  assert(current?.execution_lease?.attempt_id === binding.attempt_id &&
    current.execution_lease.binding_digest === bindingDigest &&
    current.execution_lease.epoch === lease?.epoch &&
    current.execution_lease.holder_pid === process.pid &&
    current.execution_lease.holder_token === lease?.holder_token &&
    domain.active_attempt_id === binding.attempt_id &&
    domain.active_target_scope_digest === binding.target_scope_digest,
  "execution_lease_fenced");
  return current;
}
function assertExecutionLease({ journalDir, binding, bindingDigest, lease }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => (
    assertLeaseRecord(readOptional(domainStateFile(journalDir)), binding, bindingDigest, lease)
  ));
}
function executionLeaseFence(binding, bindingDigest, lease) {
  const fence = {
    kind: "brokkr-effect-lease-fence", schema_version: "v1", domain: DOMAIN,
    target_scope_digest: binding.target_scope_digest,
    attempt_id: binding.attempt_id, mutation_id: binding.mutation_id,
    binding_digest: bindingDigest, epoch: lease.epoch,
    holder_token: lease.holder_token, activated_at: lease.activated_at,
    expires_at: lease.expires_at,
  };
  assert(DIGEST.test(fence.target_scope_digest) && DIGEST.test(fence.binding_digest) &&
    Number.isSafeInteger(fence.epoch) && fence.epoch >= 1 &&
    typeof fence.holder_token === "string" && fence.holder_token.length >= 16 &&
    strictUtc(fence.activated_at) && strictUtc(fence.expires_at) &&
    Date.parse(fence.activated_at) <= Date.parse(fence.expires_at),
  "execution_lease_fence_invalid");
  return Object.freeze(fence);
}
function assertFenceFreshAt(fence, checkedAt, code) {
  assert(strictUtc(checkedAt) &&
    Date.parse(checkedAt) >= Date.parse(fence.activated_at) &&
    Date.parse(checkedAt) <= Date.parse(fence.expires_at), code);
}
function activateResourceFence(resource, binding, bindingDigest, lease) {
  const fence = executionLeaseFence(binding, bindingDigest, lease);
  const receipt = resource.activateFence(structuredClone(fence));
  const fenceDigest = autonomyDigest(fence);
  assert(exactKeys(receipt, ["activated", "lease_fence_digest"]) &&
    receipt.activated === true && receipt.lease_fence_digest === fenceDigest,
  "effect_lease_fence_unconfirmed");
  return fence;
}
function transitionTarget({ journalDir, binding, bindingDigest, lease, state, release = false }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const domainFile = domainStateFile(journalDir);
    const domain = readOptional(domainFile);
    const current = assertLeaseRecord(domain, binding, bindingDigest, lease);
    current.state = state;
    if (release) {
      current.execution_lease = null;
      domain.active_attempt_id = null;
      domain.active_target_scope_digest = null;
    }
    domain.revision += 1;
    writeAtomic(domainFile, domain);
    return current;
  });
}
function repairTerminalRelease({ journalDir, binding, bindingDigest, state }) {
  return withExclusiveDirectory(domainLockDir(journalDir), "domain_state_contended", () => {
    const file = domainStateFile(journalDir);
    const domain = readOptional(file);
    const current = domain?.targets?.[targetKey(binding)];
    if (domain?.active_attempt_id === null && current?.execution_lease === null) {
      assert(current.state === state, "terminal_release_state_mismatch");
      return true;
    }
    assert(domain?.active_attempt_id === binding.attempt_id &&
      domain.active_target_scope_digest === binding.target_scope_digest &&
      current?.execution_lease?.attempt_id === binding.attempt_id &&
      current.execution_lease.binding_digest === bindingDigest,
    "terminal_release_owner_mismatch");
    current.state = state;
    current.execution_lease = null;
    domain.active_attempt_id = null;
    domain.active_target_scope_digest = null;
    domain.revision += 1;
    writeAtomic(file, domain);
    return true;
  });
}

// Dependency-free Draft-2020-12 subset used by the exact Grimnir journal
// schema. This refuses unknown schema keywords so a future contract cannot be
// silently interpreted with old semantics.
function schemaChecker(rootSchema) {
  const supported = new Set([
    "$schema", "$id", "$defs", "$ref", "title", "description", "oneOf", "const", "enum",
    "type", "minLength", "pattern", "format", "minimum", "maximum", "minItems", "maxItems",
    "uniqueItems", "items", "required", "properties", "additionalProperties",
  ]);
  const resolve = ref => ref.slice(2).split("/").reduce((value, raw) => value?.[raw.replaceAll("~1", "/").replaceAll("~0", "~")], rootSchema);
  const inspect = (node, at = "$") => {
    if (typeof node === "boolean") return;
    assert(plain(node), `schema_node_invalid:${at}`);
    for (const key of Object.keys(node)) assert(supported.has(key), `schema_keyword_unsupported:${key}`);
    if (node.$ref) assert(node.$ref.startsWith("#/") && resolve(node.$ref), "schema_ref_invalid");
    for (const child of Object.values(node.properties ?? {})) inspect(child, at);
    for (const child of Object.values(node.$defs ?? {})) inspect(child, at);
    if (node.items) inspect(node.items, at);
    for (const child of node.oneOf ?? []) inspect(child, at);
  };
  const typeMatches = (type, value) => ({
    object: plain(value), array: Array.isArray(value), string: typeof value === "string",
    integer: Number.isInteger(value), boolean: typeof value === "boolean", null: value === null,
  })[type];
  const errors = (node, value, at = "$") => {
    if (node === true) return [];
    if (node === false) return [`${at}:forbidden`];
    if (node.$ref) return errors(resolve(node.$ref), value, at);
    if (node.oneOf) return node.oneOf.filter(branch => errors(branch, value, at).length === 0).length === 1 ? [] : [`${at}:oneOf`];
    const result = [];
    if (Object.hasOwn(node, "const") && canonicalJson(node.const) !== canonicalJson(value)) result.push(`${at}:const`);
    if (node.enum && !node.enum.some(item => canonicalJson(item) === canonicalJson(value))) result.push(`${at}:enum`);
    if (node.type && !typeMatches(node.type, value)) return [...result, `${at}:type`];
    if (typeof value === "string") {
      if (node.minLength !== undefined && value.length < node.minLength) result.push(`${at}:minLength`);
      if (node.pattern && !new RegExp(node.pattern).test(value)) result.push(`${at}:pattern`);
      if (node.format === "date-time" && !strictUtc(value)) result.push(`${at}:date-time`);
    }
    if (Number.isInteger(value)) {
      if (node.minimum !== undefined && value < node.minimum) result.push(`${at}:minimum`);
      if (node.maximum !== undefined && value > node.maximum) result.push(`${at}:maximum`);
    }
    if (Array.isArray(value)) {
      if (node.minItems !== undefined && value.length < node.minItems) result.push(`${at}:minItems`);
      if (node.maxItems !== undefined && value.length > node.maxItems) result.push(`${at}:maxItems`);
      if (node.uniqueItems && new Set(value.map(canonicalJson)).size !== value.length) result.push(`${at}:uniqueItems`);
      value.forEach((item, index) => { if (node.items) result.push(...errors(node.items, item, `${at}[${index}]`)); });
    }
    if (plain(value)) {
      for (const required of node.required ?? []) if (!Object.hasOwn(value, required)) result.push(`${at}.${required}:required`);
      if (node.additionalProperties === false) for (const key of Object.keys(value)) if (!Object.hasOwn(node.properties ?? {}, key)) result.push(`${at}.${key}:additional`);
      for (const [key, child] of Object.entries(node.properties ?? {})) if (Object.hasOwn(value, key)) result.push(...errors(child, value[key], `${at}.${key}`));
    }
    return result;
  };
  inspect(rootSchema);
  return value => errors(rootSchema, value);
}

function ownerBindingFor({ coverage, ownerAttestations, binding }) {
  const rows = coverage.domains?.filter(entry => entry.domain === DOMAIN) ?? [];
  const row = rows[0];
  const ownerBindings = row?.bindings?.filter(entry => (
    entry.target_scope_digest === binding.target_scope_digest &&
    entry.writer_owner === binding.writer_owner &&
    entry.owner_authority_ref === binding.owner_authority_ref &&
    entry.owner_authority_digest === binding.owner_authority_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.configuration_owner_authority_ref === binding.configuration_owner_authority_ref &&
    entry.configuration_owner_authority_digest === binding.configuration_owner_authority_digest
  )) ?? [];
  const ownerBinding = ownerBindings[0];
  const attestations = ownerAttestations.attestations?.filter(entry => (
    `ref:${entry.attestation_id}` === binding.configuration_owner_authority_ref &&
    entry.attestation_digest === binding.configuration_owner_authority_digest &&
    entry.domain === DOMAIN && entry.target_scope_digest === binding.target_scope_digest &&
    entry.configuration_owner === binding.configuration_owner &&
    entry.attestation_digest === autonomyDigest(entry, "attestation_digest")
  )) ?? [];
  assert(rows.length === 1 && ownerBindings.length === 1 && attestations.length === 1, "target_owner_attestation_invalid");
  assert(coverage.global_state === "armed" && row.coverage === row.target_state &&
    row.coverage === ownerBinding.state && ["armed-canary", "armed-fleet"].includes(row.coverage), "coverage_not_armed");
  assert(binding.admission_coverage_digest === coverage.registry_digest && binding.admission_binding_state === ownerBinding.state, "coverage_binding_mismatch");
  assert(binding.writer_owner === "brokkr" && binding.configuration_owner === "brokkr", "maintenance_owner_invalid");
  const identities = ownerBinding.identities;
  assert(exactKeys(identities, ["owner", "controller", "watchdog", "kill_switch", "recovery_worker"]) &&
    new Set(Object.values(identities)).size === 5, "coverage_identity_ambiguity");
  assert(binding.owner_identity === identities.owner && binding.controller_identity === identities.controller &&
    binding.watchdog_identity === identities.watchdog && binding.kill_switch_identity === identities.kill_switch &&
    binding.recovery_worker_identity === identities.recovery_worker, "coverage_identity_mismatch");
  return ownerBinding;
}
function classPolicy(constitution) {
  const policies = constitution.autonomous_classes?.filter(entry => entry.class === DOMAIN) ?? [];
  const policy = policies[0];
  assert(policies.length === 1 && policy.recovery_class === "R-forward" && policy.owner === "brokkr" &&
    policy.bounds?.max_concurrent_targets === 1 && policy.bounds?.max_attempts === 1 &&
    policy.bounds?.apply_verify_budget_seconds === 300 &&
    policy.bounds?.minimum_watch_seconds === 3600 &&
    policy.bounds?.commit_grace_seconds === 300 &&
    policy.bounds?.deadline_seconds === 4200 &&
    policy.bounds?.trusted_watchdog_time_required === true, "maintenance_constitution_invalid");
  return policy;
}
function trustedNow(clock, previous = null) {
  const proof = clock();
  assert(exactKeys(proof, ["trusted", "now"]) && proof.trusted === true && strictUtc(proof.now), "trusted_clock_invalid");
  if (previous !== null) assert(Date.parse(proof.now) >= Date.parse(previous), "trusted_clock_backdated");
  return proof.now;
}
function checkKillSwitch(killSwitch, binding) {
  const proof = killSwitch();
  assert(exactKeys(proof, ["safe", "identity"]) && proof.safe === true && proof.identity === binding.kill_switch_identity, "kill_switch_unsafe");
}
function makeEntry(journal, { phase, at, actor, contentRef, reason = null, quarantine = false, coverageTransition = null }) {
  const previous = journal.entries.at(-1);
  assert(!previous || NEXT[previous.phase].has(phase), "journal_transition_invalid");
  const entry = {
    entry_id: `entry-${crypto.createHash("sha256").update(`${journal.journal_id}:${phase}:${journal.entries.length + 1}`).digest("hex").slice(0, 32)}`,
    sequence: journal.entries.length + 1,
    recorded_at: at,
    phase,
    outcome: OUTCOME[phase],
    executor_identity: actor,
    binding_digest: journal.binding_digest,
    quarantine: { state: quarantine ? "active" : "not-applicable", reason_digest: journal.binding.recovery.descriptor_digest },
    coverage_transition: coverageTransition,
    terminal_reason_digest: reason,
    previous_receipt_digest: previous?.receipt_digest ?? null,
    receipt_digest: "sha256:".padEnd(71, "0"),
    content_refs: [contentRef],
  };
  entry.receipt_digest = autonomyDigest(entry, "receipt_digest");
  return entry;
}
function append(file, journal, options) {
  const lock = `${file}.append-lock`;
  return withExclusiveDirectory(lock, "journal_append_contended", () => {
    const current = boundedJson(file);
    assert(current.binding_digest === journal.binding_digest, "journal_binding_changed");
    const expectedTail = journal.entries.at(-1)?.receipt_digest ?? null;
    const actualTail = current.entries.at(-1)?.receipt_digest ?? null;
    assert(actualTail === expectedTail, "journal_tail_conflict");
    current.entries.push(makeEntry(current, options));
    writeAtomic(file, current);
    return current;
  });
}
function appendExact(file, journal, entry) {
  const lock = `${file}.append-lock`;
  return withExclusiveDirectory(lock, "journal_append_contended", () => {
    const current = boundedJson(file);
    const expectedTail = journal.entries.at(-1)?.receipt_digest ?? null;
    const actualTail = current.entries.at(-1)?.receipt_digest ?? null;
    assert(current.binding_digest === journal.binding_digest && actualTail === expectedTail,
      "journal_tail_conflict");
    assert(entry.previous_receipt_digest === actualTail &&
      entry.sequence === current.entries.length + 1 &&
      entry.binding_digest === current.binding_digest &&
      entry.receipt_digest === autonomyDigest(entry, "receipt_digest"), "journal_prepared_entry_invalid");
    current.entries.push(structuredClone(entry));
    writeAtomic(file, current);
    return current;
  });
}
function appendFenced(file, journal, options, leaseContext) {
  return withExclusiveDirectory(domainLockDir(leaseContext.journalDir), "domain_state_contended", () => {
    assertLeaseRecord(
      readOptional(domainStateFile(leaseContext.journalDir)), journal.binding,
      journal.binding_digest, leaseContext.lease,
    );
    return append(file, journal, options);
  });
}
const watchAnchorFile = file => `${file}.watch-anchor.json`;
function validateWatchAnchor(anchor, journal) {
  const watch = journal.entries.find(entry => entry.phase === "watch");
  assert(exactKeys(anchor, [
    "kind", "schema_version", "journal_id", "mutation_id", "attempt_id",
    "target_scope_digest", "candidate_digest", "binding_digest",
    "journal_tail_digest", "anchored_at", "anchor_digest",
  ]) && anchor.kind === "brokkr-durable-watch-anchor" &&
    anchor.schema_version === "v1" && watch &&
    anchor.journal_id === journal.journal_id &&
    anchor.mutation_id === journal.binding.mutation_id &&
    anchor.attempt_id === journal.binding.attempt_id &&
    anchor.target_scope_digest === journal.binding.target_scope_digest &&
    anchor.candidate_digest === journal.binding.candidate_digest &&
    anchor.binding_digest === journal.binding_digest &&
    anchor.journal_tail_digest === watch.receipt_digest &&
    strictUtc(anchor.anchored_at) &&
    Date.parse(anchor.anchored_at) >= Date.parse(watch.recorded_at) &&
    anchor.anchor_digest === autonomyDigest(anchor, "anchor_digest"),
  "watch_anchor_invalid");
  return anchor;
}
function readWatchAnchor(file, journal) {
  return validateWatchAnchor(boundedJson(watchAnchorFile(file)), journal);
}
function persistWatchAnchor({
  file, journal, admission, recovery, previousAt,
}) {
  const durableJournal = boundedJson(file);
  assert(canonicalJson(durableJournal) === canonicalJson(journal) &&
    durableJournal.entries.at(-1)?.phase === "watch",
  "watch_journal_readback_invalid");
  recovery.fault?.("after-watch-journal-readback");
  const anchoredAt = trustedNow(admission.trustedClock, previousAt);
  const anchor = {
    kind: "brokkr-durable-watch-anchor", schema_version: "v1",
    journal_id: journal.journal_id,
    mutation_id: journal.binding.mutation_id,
    attempt_id: journal.binding.attempt_id,
    target_scope_digest: journal.binding.target_scope_digest,
    candidate_digest: journal.binding.candidate_digest,
    binding_digest: journal.binding_digest,
    journal_tail_digest: journal.entries.at(-1).receipt_digest,
    anchored_at: anchoredAt,
    anchor_digest: "sha256:".padEnd(71, "0"),
  };
  anchor.anchor_digest = autonomyDigest(anchor, "anchor_digest");
  assert(createExclusive(watchAnchorFile(file), anchor),
    "watch_anchor_conflict");
  const readback = readWatchAnchor(file, journal);
  assert(canonicalJson(readback) === canonicalJson(anchor),
    "watch_anchor_readback_invalid");
  recovery.fault?.("after-watch-anchor");
  return readback;
}
function ensureFencedEntry(file, entry, leaseContext) {
  return withExclusiveDirectory(domainLockDir(leaseContext.journalDir), "domain_state_contended", () => {
    const current = boundedJson(file);
    assertLeaseRecord(
      readOptional(domainStateFile(leaseContext.journalDir)), current.binding,
      current.binding_digest, leaseContext.lease,
    );
    const existing = current.entries[entry.sequence - 1];
    if (existing !== undefined) {
      assert(canonicalJson(existing) === canonicalJson(entry), "journal_exact_entry_conflict");
      return current;
    }
    assert(current.entries.length === entry.sequence - 1, "journal_exact_entry_gap");
    return appendExact(file, current, entry);
  });
}
function coverageTransition(binding) {
  return {
    from_state: binding.admission_binding_state,
    to_state: "shadow",
    target_scope_digest: binding.target_scope_digest,
    actor_identity: binding.recovery_worker_identity,
  };
}
function validateJournalSemantics(
  journal,
  { schema, constitution, coverage, ownerAttestations },
  { allowActive = false, watchAnchor = null } = {},
) {
  assert(PINNED_SCHEMAS.has(schema) && schema.$id === SCHEMA_ID, "journal_schema_not_pinned");
  const shapeErrors = schemaChecker(schema)(journal);
  if (!(allowActive && journal.entries.length === 1 && shapeErrors.every(error => error.endsWith(":minItems")))) {
    assert(shapeErrors.length === 0, `journal_schema_invalid:${shapeErrors[0] ?? "unknown"}`);
  }
  assert(journal.constitution_digest === constitution.constitution_digest, "journal_constitution_mismatch");
  const policy = classPolicy(constitution);
  const binding = journal.binding;
  if (watchAnchor !== null) validateWatchAnchor(watchAnchor, journal);
  ownerBindingFor({ coverage, ownerAttestations, binding });
  assert(journal.binding_digest === autonomyDigest(binding), "journal_binding_digest_invalid");
  assert(journal.journal_id === binding.mutation_id,
    "journal_mutation_identity_mismatch");
  assert(new Set([
    binding.mutation_id, binding.attempt_id, binding.recovery_disarm_id,
    binding.idempotency_key,
  ]).size === 4, "journal_envelope_identity_aliased");
  assert(binding.risk_scope === DOMAIN && binding.recovery.class === "R-forward" &&
    binding.recovery.worker_identity === binding.recovery_worker_identity &&
    binding.recovery.disarms_after_action === true, "journal_recovery_binding_invalid");
  assert(binding.canary.scope_digest === binding.target_scope_digest &&
    binding.canary.target_count === 1, "journal_canary_invalid");
  const preparedAt = Date.parse(journal.entries[0].recorded_at);
  const deadlineAt = Date.parse(binding.deadline);
  assert(deadlineAt >= preparedAt &&
    deadlineAt - preparedAt <= policy.bounds.deadline_seconds * 1000,
  "journal_deadline_bound_invalid");
  let previous = null;
  const entryIds = new Set();
  for (let index = 0; index < journal.entries.length; index += 1) {
    const entry = journal.entries[index];
    assert(entry.phase !== "revert", "journal_r_forward_revert_forbidden");
    assert(!entryIds.has(entry.entry_id), "journal_entry_identity_replayed");
    entryIds.add(entry.entry_id);
    assert(entry.sequence === index + 1 && entry.previous_receipt_digest === previous &&
      entry.binding_digest === journal.binding_digest && entry.receipt_digest === autonomyDigest(entry, "receipt_digest"), "journal_receipt_invalid");
    assert(entry.outcome === OUTCOME[entry.phase], "journal_outcome_invalid");
    if (index) {
      assert(Date.parse(entry.recorded_at) >= Date.parse(journal.entries[index - 1].recorded_at), "journal_clock_backdated");
      assert(NEXT[journal.entries[index - 1].phase].has(entry.phase), "journal_transition_invalid");
    }
    if (["prepare", "apply", "verify", "watch", "commit"].includes(entry.phase)) {
      assert(Date.parse(entry.recorded_at) <= deadlineAt &&
        Date.parse(entry.recorded_at) - preparedAt <=
          policy.bounds.deadline_seconds * 1000,
      "journal_deadline_exceeded");
    }
    if (entry.phase === "watch") {
      const durableWatchAt = Date.parse(
        watchAnchor?.anchored_at ?? entry.recorded_at,
      );
      assert(durableWatchAt - preparedAt <=
        policy.bounds.apply_verify_budget_seconds * 1000,
      "journal_apply_verify_budget_exceeded");
    }
    if (entry.phase === "commit") {
      const watch = journal.entries.slice(0, index).find(
        candidate => candidate.phase === "watch",
      );
      const durableWatchAt = Date.parse(
        watchAnchor?.anchored_at ?? watch?.recorded_at,
      );
      assert(watch && Date.parse(entry.recorded_at) - durableWatchAt >=
        policy.bounds.minimum_watch_seconds * 1000,
      "journal_watch_incomplete");
      assert(Date.parse(entry.recorded_at) - durableWatchAt <=
        (policy.bounds.minimum_watch_seconds +
          policy.bounds.commit_grace_seconds) * 1000,
      "journal_commit_grace_exceeded");
    }
    const recoveryPhase = ["recover", "quarantine", "disarm", "terminally-blocked"].includes(entry.phase);
    if (entry.phase === "unknown") assert([binding.controller_identity, binding.watchdog_identity].includes(entry.executor_identity), "journal_actor_invalid");
    else assert(entry.executor_identity === (recoveryPhase ? binding.recovery_worker_identity : binding.controller_identity), "journal_actor_invalid");
    if (["unknown", "disarm", "terminally-blocked"].includes(entry.phase)) assert(DIGEST.test(entry.terminal_reason_digest), "journal_reason_missing");
    if (entry.phase === "terminally-blocked") {
      assert(entry.quarantine.state === "active",
        "journal_terminally_blocked_not_quarantined");
    }
    if (["disarm", "terminally-blocked"].includes(entry.phase)) assert(canonicalJson(entry.coverage_transition) === canonicalJson(coverageTransition(binding)), "journal_narrowing_invalid");
    else assert(entry.coverage_transition === null, "journal_unexpected_narrowing");
    assert(entry.content_refs.every(ref => REF.test(ref) && !/[/:.]/.test(ref.slice(4))), "journal_content_ref_invalid");
    previous = entry.receipt_digest;
  }
  assert(journal.entries[0].phase === "prepare", "journal_prepare_missing");
  if (!allowActive) assert(TERMINAL.has(journal.entries.at(-1).phase), "journal_not_terminal");
  return true;
}

export function loadPinnedJournalSchema(schemaPath) {
  const raw = fs.readFileSync(schemaPath);
  assert(sha256(raw) === SCHEMA_SHA256, "journal_schema_pin_mismatch");
  const schema = JSON.parse(raw);
  assert(schema.$id === SCHEMA_ID, "journal_schema_id_invalid");
  PINNED_SCHEMAS.add(schema);
  return schema;
}
export function validateJournalConformance(journal, context, options = {}) {
  return validateJournalSemantics(journal, context, options);
}
export function attemptIdentity(binding) {
  assert(ID.test(binding?.idempotency_key), "attempt_identity_invalid");
  return binding.idempotency_key;
}
function readArtifacts(artifacts) {
  const snapshot = typeof artifacts?.read === "function" ? artifacts.read() : artifacts;
  assert(plain(snapshot), "authorization_artifacts_unavailable");
  return snapshot;
}
function historicalAuthoritySnapshot(snapshot, recovery, immutableAdmissionDigest) {
  return {
    kind: "brokkr-autonomy-authority-snapshot", schema_version: "v1",
    authorization: structuredClone(snapshot.authorization),
    constitution: structuredClone(snapshot.constitution),
    coverage: structuredClone(snapshot.coverage),
    ownerAttestations: structuredClone(snapshot.ownerAttestations),
    recoveryRegistry: structuredClone(snapshot.recoveryRegistry),
    pinnedOwnerPublicKeyPem: snapshot.pinnedOwnerPublicKeyPem,
    authorizationCheckpoint: structuredClone(snapshot.authorizationCheckpoint),
    runtimeNarrowing: structuredClone(snapshot.runtimeNarrowing),
    runtimeNarrowingCheckpoint: structuredClone(snapshot.runtimeNarrowingCheckpoint),
    recoveryWorkerIdentity: recovery.workerIdentity,
    recoveryPublicKeyFingerprint: recovery.publicKeyFingerprint,
    immutableAdmissionDigest,
  };
}
function verifyHistoricalAuthority(snapshot, binding, recovery) {
  assert(exactKeys(snapshot, [
    "kind", "schema_version", "authorization", "constitution", "coverage",
    "ownerAttestations", "recoveryRegistry", "pinnedOwnerPublicKeyPem",
    "authorizationCheckpoint", "runtimeNarrowing", "runtimeNarrowingCheckpoint",
    "recoveryWorkerIdentity", "recoveryPublicKeyFingerprint", "immutableAdmissionDigest",
  ]) && snapshot.kind === "brokkr-autonomy-authority-snapshot" &&
    snapshot.schema_version === "v1" &&
    snapshot.recoveryWorkerIdentity === recovery.workerIdentity &&
    snapshot.recoveryPublicKeyFingerprint === recovery.publicKeyFingerprint &&
    DIGEST.test(snapshot.immutableAdmissionDigest),
  "historical_authority_invalid");
  return verifyAuthority({ binding, snapshot, recovery });
}
function verifyAuthority({ binding, snapshot, recovery }) {
  const bundle = verifyOwnerAuthorizationBundle(snapshot);
  const narrowing = verifyRuntimeNarrowingLedger({
    ledger: snapshot.runtimeNarrowing,
    recoveryRegistry: bundle.recoveryRegistry,
    authorizationDigest: bundle.authorizationDigest,
    tailCheckpoint: snapshot.runtimeNarrowingCheckpoint,
  });
  ownerBindingFor({ coverage: bundle.coverage, ownerAttestations: bundle.ownerAttestations, binding });
  const recoveryBindings = bundle.recoveryRegistry.entries.filter(entry => (
    entry.domain === DOMAIN && entry.target_scope_digest === binding.target_scope_digest &&
    entry.recovery_worker_identity === binding.recovery_worker_identity
  ));
  assert(recoveryBindings.length === 1 && recovery?.workerIdentity === binding.recovery_worker_identity &&
    recovery.publicKeyFingerprint === recoveryBindings[0].public_key_fingerprint, "recovery_capability_unbound");
  return { bundle, narrowing, recoveryBinding: recoveryBindings[0] };
}
function verifyAdmission({
  binding, snapshot, admission, recovery, journalDir, conformance,
  allowDeadlineEquality = false,
}) {
  const authority = verifyAuthority({ binding, snapshot, recovery });
  const { bundle, narrowing } = authority;
  assert(effectiveTargetState({ coverage: bundle.coverage, narrowingEntries: narrowing.entries, targetScopeDigest: binding.target_scope_digest }) === binding.admission_binding_state, "runtime_demotion_consumed");
  const policy = classPolicy(bundle.constitution);
  const now = trustedNow(admission.trustedClock);
  checkKillSwitch(admission.killSwitch, binding);
  const evidence = admission.evidence();
  assert(exactKeys(evidence, ["fresh", "eligible", "digest"]) && evidence.fresh === true && evidence.eligible === true && evidence.digest === binding.evidence_digest, "maintenance_evidence_ineligible");
  const liveness = admission.liveness();
  assert(exactKeys(liveness, ["healthy", "observed_at"]) && liveness.healthy === true && strictUtc(liveness.observed_at) &&
    Date.parse(liveness.observed_at) <= Date.parse(now) &&
    Date.parse(now) - Date.parse(liveness.observed_at) <= policy.bounds.max_silence_seconds * 1000, "maintenance_liveness_stale");
  const maintenance = admission.maintenance();
  assert(exactKeys(maintenance, ["window", "target", "plan"]) &&
    exactKeys(maintenance.window, ["start", "end"]) && strictUtc(maintenance.window.start) && strictUtc(maintenance.window.end) &&
    Date.parse(maintenance.window.start) <= Date.parse(now) && Date.parse(now) < Date.parse(maintenance.window.end), "maintenance_window_closed");
  assert(exactKeys(maintenance.target, ["platform", "non_pillar"]) && maintenance.target.platform === "debian" && maintenance.target.non_pillar === true, "maintenance_target_ineligible");
  assert(exactKeys(maintenance.plan, ["classes", "reboot_policy", "source", "workload_hooks"]) &&
    Array.isArray(maintenance.plan.classes) && maintenance.plan.classes.length > 0 && maintenance.plan.classes.length <= 2 &&
    new Set(maintenance.plan.classes).size === maintenance.plan.classes.length &&
    maintenance.plan.classes.every(item => ["security", "bugfix"].includes(item)) &&
    maintenance.plan.reboot_policy === "never" && maintenance.plan.source === "distro_repository" &&
    maintenance.plan.workload_hooks === "not_applicable", "maintenance_plan_out_of_scope");
  assert(allowDeadlineEquality ?
    Date.parse(now) <= Date.parse(binding.deadline) :
    Date.parse(now) < Date.parse(binding.deadline), "attempt_deadline_closed");
  return {
    ...authority, policy, now, maintenance,
    immutableAdmissionDigest: autonomyDigest({
      authorization_digest: bundle.authorizationDigest,
      coverage_digest: bundle.coverage.registry_digest,
      evidence_digest: evidence.digest,
      maintenance,
      recovery_registry_digest: bundle.recoveryRegistry.registry_digest,
      target_state: binding.admission_binding_state,
    }),
  };
}
function verifyRecoveryPosture({
  binding, snapshot, admission, snapshotError = null,
}) {
  let authorityDigest = null;
  let coverageDigest = null;
  let narrowingTailDigest = null;
  let postureAvailable = false;
  let authorityError = snapshotError;
  try {
    const bundle = verifyOwnerAuthorizationBundle(snapshot);
    const narrowing = verifyRuntimeNarrowingLedger({
      ledger: snapshot.runtimeNarrowing,
      recoveryRegistry: bundle.recoveryRegistry,
      authorizationDigest: bundle.authorizationDigest,
      tailCheckpoint: snapshot.runtimeNarrowingCheckpoint,
    });
    authorityDigest = bundle.authorizationDigest;
    coverageDigest = bundle.coverage.registry_digest;
    narrowingTailDigest = narrowing.tailDigest;
    postureAvailable = true;
  } catch (error) {
    // Current corruption cannot authorize mutation, but it also cannot strand
    // containment of an authenticated historical attempt.
    authorityError = diagnosticCode(error);
  }
  let killSafe = false;
  let killError = null;
  try {
    const proof = admission.killSwitch();
    killSafe = exactKeys(proof, ["safe", "identity"]) &&
      proof.safe === true && proof.identity === binding.kill_switch_identity;
  } catch (error) {
    killSafe = false;
    killError = diagnosticCode(error);
  }
  return {
    now: trustedNow(admission.trustedClock),
    mustRecover: !postureAvailable || !killSafe,
    authorityDigest, coverageDigest, narrowingTailDigest, postureAvailable,
    authorityError, killError,
  };
}
function reasonDigest(code) {
  return autonomyDigest({ code: String(code || "unknown").slice(0, 96) });
}
function verifyTerminalNarrowing({ narrowed, authorizationDigest, recoveryRegistry, terminal }) {
  const verified = verifyRuntimeNarrowingLedger({
    ledger: narrowed.ledger, recoveryRegistry,
    authorizationDigest, tailCheckpoint: narrowed.tailCheckpoint,
  });
  const tail = verified.entries.at(-1);
  assert(tail?.journal_receipt_digest === terminal.receipt_digest &&
    tail.domain === DOMAIN &&
    tail.target_scope_digest === terminal.coverage_transition.target_scope_digest &&
    tail.from_state === terminal.coverage_transition.from_state &&
    tail.recovery_worker_identity === terminal.coverage_transition.actor_identity &&
    tail.to_state === "shadow", "runtime_narrowing_not_consumed");
  return verified;
}
function outboxCheckpoint(file, outbox, stage, recovery, faultPoint) {
  outbox.stage = stage;
  writeAtomic(file, outbox);
  recovery.fault?.(faultPoint);
}
function syntheticCheckpoint(authorizationDigest, ledger) {
  return {
    kind: "autonomy-runtime-narrowing-checkpoint", schema_version: "v1",
    owner_authorization_digest: authorizationDigest,
    ledger_tail_digest: ledger.entries.at(-1)?.entry_digest ?? null,
    minimum_entries: ledger.entries.length,
  };
}
function verifiedRawNarrowing({ history, authorizationDigest, recoveryRegistry }) {
  return verifyRuntimeNarrowingLedger({
    ledger: history.ledger, recoveryRegistry, authorizationDigest,
    tailCheckpoint: syntheticCheckpoint(authorizationDigest, history.ledger),
  });
}
function exactNarrowingEntry(entry, terminal) {
  return entry.journal_receipt_digest === terminal.receipt_digest &&
    entry.domain === DOMAIN &&
    entry.target_scope_digest === terminal.coverage_transition.target_scope_digest &&
    entry.from_state === terminal.coverage_transition.from_state &&
    entry.to_state === terminal.coverage_transition.to_state &&
    entry.recovery_worker_identity === terminal.coverage_transition.actor_identity;
}
function finishRecoveryOutbox({ file, journal, context, admission, recovery, outboxFile, lease }) {
  return withExclusiveDirectory(`${outboxFile}.lock`, "recovery_outbox_contended", () => {
    let outbox = boundedJson(outboxFile);
    assert(exactKeys(outbox, [
      "kind", "schema_version", "binding_digest", "stage", "owner_authorization_digest",
      "previous_narrowing_digest", "narrowing_sequence", "narrowing_tail_digest",
      "authorized_recovery_fence_digests",
      "revalidation_fence", "revalidation_fence_digest",
      "recovery_request", "recovery_result", "recovery_error", "unknown_entry",
      "recover_entry", "quarantine_entry", "terminal_entry",
    ]) && outbox.kind === "brokkr-autonomy-recovery-outbox" &&
      outbox.schema_version === "v1" && outbox.binding_digest === journal.binding_digest,
    "recovery_outbox_invalid");
    const currentFence = executionLeaseFence(
      journal.binding, journal.binding_digest, lease,
    );
    const currentFenceDigest = autonomyDigest(currentFence);
    assert(exactKeys(outbox.recovery_request, [
      "idempotency_key", "descriptor_digest", "target_scope_digest",
      "binding_digest", "lease_fence", "lease_fence_digest",
    ]) && outbox.recovery_request.idempotency_key ===
      journal.binding.recovery_disarm_id &&
      outbox.recovery_request.descriptor_digest ===
        journal.binding.recovery.descriptor_digest &&
      outbox.recovery_request.target_scope_digest ===
        journal.binding.target_scope_digest &&
      outbox.recovery_request.binding_digest === journal.binding_digest,
    "recovery_request_invalid");
    assert(Array.isArray(outbox.authorized_recovery_fence_digests) &&
      outbox.authorized_recovery_fence_digests.length >= 1 &&
      outbox.authorized_recovery_fence_digests.length <= 16 &&
      new Set(outbox.authorized_recovery_fence_digests).size ===
        outbox.authorized_recovery_fence_digests.length &&
      outbox.authorized_recovery_fence_digests.every(digest => DIGEST.test(digest)) &&
      outbox.authorized_recovery_fence_digests[0] ===
        outbox.recovery_request.lease_fence_digest,
    "recovery_fence_history_invalid");
    assert(DIGEST.test(outbox.recovery_request.lease_fence_digest) &&
      outbox.recovery_request.lease_fence?.kind ===
        "brokkr-effect-lease-fence" &&
      autonomyDigest(outbox.recovery_request.lease_fence) ===
        outbox.recovery_request.lease_fence_digest,
    "recovery_request_fence_invalid");
    assert(DIGEST.test(outbox.revalidation_fence_digest) &&
      outbox.revalidation_fence?.kind === "brokkr-effect-lease-fence" &&
      autonomyDigest(outbox.revalidation_fence) ===
        outbox.revalidation_fence_digest &&
      outbox.authorized_recovery_fence_digests.includes(
        outbox.revalidation_fence_digest,
      ),
    "recovery_revalidation_fence_invalid");
    const recoveryEffectPending = [
      "intent", "unknown-journaled", "target-unknown", "recovering",
    ].includes(outbox.stage);
    if (recoveryEffectPending) {
      if (outbox.revalidation_fence_digest !== currentFenceDigest) {
        if (!outbox.authorized_recovery_fence_digests.includes(currentFenceDigest)) {
          assert(outbox.authorized_recovery_fence_digests.length < 16,
            "recovery_fence_history_exhausted");
          outbox.authorized_recovery_fence_digests.push(currentFenceDigest);
        }
        outbox.revalidation_fence = structuredClone(currentFence);
        outbox.revalidation_fence_digest = currentFenceDigest;
        writeAtomic(outboxFile, outbox);
      }
      assert(outbox.revalidation_fence_digest === currentFenceDigest &&
        canonicalJson(outbox.revalidation_fence) ===
          canonicalJson(currentFence), "recovery_request_stale_fence");
    }
    const leaseContext = { journalDir: context.journalDir, lease };
    const historical = context.authoritySnapshot;
    const historicalAuthority = verifyHistoricalAuthority(historical, journal.binding, recovery);
    assert(historicalAuthority.bundle.authorizationDigest === outbox.owner_authorization_digest,
      "recovery_authority_history_mismatch");

    journal = ensureFencedEntry(file, outbox.unknown_entry, leaseContext);
    if (outbox.stage === "intent") {
      recovery.fault?.("after-unknown-append");
      outboxCheckpoint(outboxFile, outbox, "unknown-journaled", recovery, "after-unknown-journal");
    }
    transitionTarget({
      journalDir: context.journalDir, binding: journal.binding,
      bindingDigest: journal.binding_digest, lease, state: "unknown",
    });
    if (outbox.stage === "unknown-journaled") {
      recovery.fault?.("after-target-transition");
      outboxCheckpoint(outboxFile, outbox, "target-unknown", recovery, "after-target-unknown");
    }
    if (["target-unknown", "recovering"].includes(outbox.stage)) {
      if (outbox.stage === "target-unknown") {
        outboxCheckpoint(outboxFile, outbox, "recovering", recovery, "before-recover-invocation");
      }
      assertExecutionLease({
        journalDir: context.journalDir, binding: journal.binding,
        bindingDigest: journal.binding_digest, lease,
      });
      const result = recovery.recover({
        ...structuredClone(outbox.recovery_request),
        revalidation_fence: structuredClone(outbox.revalidation_fence),
        revalidation_fence_digest: outbox.revalidation_fence_digest,
      });
      recovery.fault?.("after-recover-return");
      assert(exactKeys(result, [
        "idempotency_key", "effect_lease_fence_digest",
        "revalidated_lease_fence_digest", "revalidated_at", "recovered",
        "safe_state_verified", "quarantine_active", "reason_code",
        "activation_digest", "terminal_receipt_digest",
      ]) && result.idempotency_key === outbox.recovery_request.idempotency_key &&
        outbox.authorized_recovery_fence_digests.includes(
          result.effect_lease_fence_digest,
        ) &&
        result.revalidated_lease_fence_digest === currentFenceDigest &&
        DIGEST.test(result.activation_digest) && DIGEST.test(result.terminal_receipt_digest) &&
        typeof result.recovered === "boolean" && typeof result.safe_state_verified === "boolean" &&
        typeof result.quarantine_active === "boolean" &&
        (result.reason_code === null || typeof result.reason_code === "string"),
      "recovery_receipt_invalid");
      assertFenceFreshAt(
        currentFence, result.revalidated_at, "recovery_fence_expired",
      );
      outbox.recovery_result = structuredClone(result);
      outbox.recovery_error = result.reason_code;
      let at = trustedNow(admission.trustedClock, outbox.unknown_entry.recorded_at);
      let prepared = structuredClone(journal);
      if (result.recovered && result.safe_state_verified && result.quarantine_active) {
        outbox.recover_entry = makeEntry(prepared, {
          phase: "recover", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, quarantine: true,
        });
        prepared.entries.push(outbox.recover_entry);
        at = trustedNow(admission.trustedClock, at);
        outbox.quarantine_entry = makeEntry(prepared, {
          phase: "quarantine", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, quarantine: true,
        });
        prepared.entries.push(outbox.quarantine_entry);
        at = trustedNow(admission.trustedClock, at);
        outbox.terminal_entry = makeEntry(prepared, {
          phase: "disarm", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef, reason: outbox.unknown_entry.terminal_reason_digest,
          quarantine: true, coverageTransition: coverageTransition(journal.binding),
        });
      } else {
        outbox.terminal_entry = makeEntry(prepared, {
          phase: "terminally-blocked", at, actor: journal.binding.recovery_worker_identity,
          contentRef: context.contentRef,
          reason: reasonDigest(result.reason_code ?? "recovery-postconditions-failed"),
          quarantine: true, coverageTransition: coverageTransition(journal.binding),
        });
      }
      outboxCheckpoint(outboxFile, outbox, "recovery-recorded", recovery, "after-recovery-result");
    }
    if (outbox.stage === "recovery-recorded") {
      if (outbox.recover_entry) {
        journal = ensureFencedEntry(file, outbox.recover_entry, leaseContext);
        recovery.fault?.("after-recover-journal");
      }
      if (outbox.quarantine_entry) {
        journal = ensureFencedEntry(file, outbox.quarantine_entry, leaseContext);
        recovery.fault?.("after-quarantine-journal");
      }
      outboxCheckpoint(outboxFile, outbox, "journal-recovery-recorded", recovery, "after-recovery-journal-checkpoint");
    }
    if (outbox.stage === "journal-recovery-recorded") {
      const history = recovery.readNarrowingHistory({
        authorization_digest: outbox.owner_authorization_digest,
      });
      const verified = verifiedRawNarrowing({
        history, authorizationDigest: outbox.owner_authorization_digest,
        recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
      });
      const exact = verified.entries.filter(entry => exactNarrowingEntry(entry, outbox.terminal_entry));
      assert(exact.length <= 1, "runtime_narrowing_duplicate");
      if (exact.length === 0) {
        outbox.previous_narrowing_digest = verified.tailDigest;
        outbox.narrowing_sequence = verified.entries.length + 1;
        writeAtomic(outboxFile, outbox);
        const appended = recovery.appendSignedNarrowing({
          journal_receipt_digest: outbox.terminal_entry.receipt_digest,
          recorded_at: outbox.terminal_entry.recorded_at,
          binding: journal.binding,
          authorization_digest: outbox.owner_authorization_digest,
          previous_entry_digest: outbox.previous_narrowing_digest,
          sequence: outbox.narrowing_sequence,
        });
        const appendedVerified = verifiedRawNarrowing({
          history: appended, authorizationDigest: outbox.owner_authorization_digest,
          recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
        });
        const appendedExact = appendedVerified.entries.filter(entry => (
          exactNarrowingEntry(entry, outbox.terminal_entry)
        ));
        assert(appendedExact.length === 1, "runtime_narrowing_append_unverified");
        outbox.narrowing_tail_digest = appendedExact[0].entry_digest;
        recovery.fault?.("after-ledger-return");
      } else {
        outbox.narrowing_tail_digest = exact[0].entry_digest;
      }
      outboxCheckpoint(outboxFile, outbox, "narrowing-appended", recovery, "after-ledger-append");
    }
    if (outbox.stage === "narrowing-appended") {
      recovery.advanceNarrowingCheckpoint({
        authorization_digest: outbox.owner_authorization_digest,
        ledger_tail_digest: outbox.narrowing_tail_digest,
        minimum_entries: outbox.narrowing_sequence,
      });
      recovery.fault?.("after-checkpoint-return");
      outboxCheckpoint(outboxFile, outbox, "checkpointed", recovery, "after-checkpoint-advance");
    }
    if (outbox.stage === "checkpointed") {
      const narrowedHistory = recovery.readNarrowingHistory({
        authorization_digest: outbox.owner_authorization_digest,
      });
      const verified = verifyTerminalNarrowing({
        narrowed: narrowedHistory, authorizationDigest: outbox.owner_authorization_digest,
        recoveryRegistry: historicalAuthority.bundle.recoveryRegistry,
        terminal: outbox.terminal_entry,
      });
      assert(verified.tailDigest === outbox.narrowing_tail_digest,
        "recovery_outbox_narrowing_missing");
      journal = ensureFencedEntry(file, outbox.terminal_entry, leaseContext);
      outboxCheckpoint(outboxFile, outbox, "terminal-journaled", recovery, "after-terminal-journal");
    }
    if (outbox.stage === "terminal-journaled") {
      const terminalState = outbox.terminal_entry.phase === "disarm" ? "shadow" : "terminally-blocked";
      transitionTarget({
        journalDir: context.journalDir, binding: journal.binding,
        bindingDigest: journal.binding_digest, lease, state: terminalState, release: true,
      });
      recovery.fault?.("after-terminal-release-before-stage");
      outboxCheckpoint(outboxFile, outbox, "released", recovery, "after-terminal-release");
    }
    if (outbox.stage === "released") {
      outboxCheckpoint(outboxFile, outbox, "complete", recovery, "after-outbox-complete");
    }
    journal = boundedJson(file);
    validateJournalSemantics(journal, {
      schema: context.conformance.schema, constitution: historical.constitution,
      coverage: historical.coverage, ownerAttestations: historical.ownerAttestations,
    });
    return {
      journal, ran: false,
      reason: outbox.terminal_entry.phase === "disarm" ? "recovered-disarmed" : "terminally-blocked",
      recovery_error: outbox.recovery_error,
    };
  });
}
function recoveryForBinding(recovery, binding, bindingDigest) {
  const factory = recovery?.[BOUNDED_RECOVERY_FACTORY];
  assert(typeof factory === "function", "bounded_recovery_dispatch_required");
  const bounded = factory({ binding: structuredClone(binding), bindingDigest });
  assert(plain(bounded) && typeof bounded.recover === "function",
    "bounded_recovery_dispatch_required");
  return { ...recovery, recover: bounded.recover };
}
function enterRecovery({ file, journal, context, admission, phases, recovery, code, lastAt, lease }) {
  const outboxFile = `${file}.recovery-outbox.json`;
  if (!readOptional(outboxFile)) {
    const at = trustedNow(admission.trustedClock, lastAt);
    const unknownEntry = journal.entries.at(-1).phase === "unknown" ?
      structuredClone(journal.entries.at(-1)) :
      makeEntry(journal, {
        phase: "unknown", at, actor: journal.binding.watchdog_identity,
        contentRef: context.contentRef, reason: reasonDigest(code), quarantine: true,
      });
    const outbox = {
      kind: "brokkr-autonomy-recovery-outbox", schema_version: "v1",
      binding_digest: journal.binding_digest, stage: "intent",
      owner_authorization_digest: context.bundle.authorizationDigest,
      previous_narrowing_digest: context.narrowing.tailDigest,
      narrowing_sequence: context.narrowing.entries.length + 1,
      narrowing_tail_digest: null,
      authorized_recovery_fence_digests: [
        autonomyDigest(executionLeaseFence(
          journal.binding, journal.binding_digest, lease,
        )),
      ],
      revalidation_fence: structuredClone(executionLeaseFence(
        journal.binding, journal.binding_digest, lease,
      )),
      revalidation_fence_digest: autonomyDigest(executionLeaseFence(
        journal.binding, journal.binding_digest, lease,
      )),
      recovery_request: {
        idempotency_key: journal.binding.recovery_disarm_id,
        descriptor_digest: journal.binding.recovery.descriptor_digest,
        target_scope_digest: journal.binding.target_scope_digest,
        binding_digest: journal.binding_digest,
        lease_fence: structuredClone(executionLeaseFence(
          journal.binding, journal.binding_digest, lease,
        )),
        lease_fence_digest: autonomyDigest(executionLeaseFence(
          journal.binding, journal.binding_digest, lease,
        )),
      },
      recovery_result: null, recovery_error: null, unknown_entry: unknownEntry,
      recover_entry: null, quarantine_entry: null, terminal_entry: null,
    };
    if (createExclusive(outboxFile, outbox)) {
      recovery.fault?.("after-recovery-intent");
    } else {
      const adopted = boundedJson(outboxFile);
      assert(adopted?.kind === outbox.kind &&
        adopted.schema_version === outbox.schema_version &&
        adopted.binding_digest === outbox.binding_digest &&
        adopted.recovery_request?.idempotency_key ===
          outbox.recovery_request.idempotency_key,
      "recovery_outbox_conflict");
    }
  }
  const boundedRecovery = recoveryForBinding(
    recovery, journal.binding, journal.binding_digest,
  );
  const successorAt = trustedNow(admission.trustedClock, lastAt);
  const successorLease = supersedeExecutionLease({
    journalDir: context.journalDir, binding: journal.binding,
    bindingDigest: journal.binding_digest, lease, now: successorAt,
    policy: context.policy,
  });
  activateResourceFence(
    phases, journal.binding, journal.binding_digest, successorLease,
  );
  activateResourceFence(
    boundedRecovery, journal.binding, journal.binding_digest, successorLease,
  );
  return finishRecoveryOutbox({
    file, journal, context, admission, recovery: boundedRecovery, outboxFile,
    lease: successorLease,
  });
}

function executionBindingDigest(binding) {
  return autonomyDigest({
    baseline_digest: binding.baseline_digest,
    candidate_digest: binding.candidate_digest,
    config_digest: binding.config_digest,
    evidence_digest: binding.evidence_digest,
    policy_digest: binding.policy_digest,
    postconditions_digest: binding.postconditions_digest,
    target_scope_digest: binding.target_scope_digest,
  });
}
function verifyExecutionPreflight(phases, binding) {
  const result = phases.preflight();
  assert(exactKeys(result, ["execution_digest"]) &&
    result.execution_digest === executionBindingDigest(binding), "execution_binding_substituted");
}
function verifyExecutionCommitBinding(phases, binding) {
  const result = phases.commitBinding();
  assert(exactKeys(result, ["execution_digest"]) &&
    result.execution_digest === executionBindingDigest(binding), "execution_binding_substituted");
}
function runMaintenanceAttempt({
  journalDir, binding, artifacts, admission, phases, recovery, contentRef = "ref:maintenance-candidate",
  reconcile = null,
}) {
  assert(typeof journalDir === "string" && path.isAbsolute(journalDir) && REF.test(contentRef), "attempt_arguments_invalid");
  assert(plain(binding) && plain(artifacts) && typeof artifacts.read === "function" &&
    plain(admission) && plain(phases) && plain(recovery), "attempt_arguments_invalid");
  for (const fn of ["trustedClock", "killSwitch", "evidence", "liveness", "maintenance"]) assert(typeof admission[fn] === "function", "admission_verifier_missing");
  for (const fn of [
    "preflight", "commitBinding", "activateFence", "applyFenced",
    "verify", "safeStateReadback",
  ]) assert(typeof phases[fn] === "function", "maintenance_phase_missing");
  for (const fn of [
    "activateFence", "recover", "appendSignedNarrowing",
    "advanceNarrowingCheckpoint", "readNarrowingHistory",
  ]) {
    assert(typeof recovery[fn] === "function", "maintenance_recovery_missing");
  }
  const file = path.join(journalDir, `${attemptIdentity(binding)}.json`);
  const authorityFile = `${file}.authority.json`;
  const bindingDigest = autonomyDigest(binding);
  let existing = readOptional(file);
  let pendingOutbox = null;
  let authoritySnapshot = readOptional(authorityFile);
  let initialSnapshot = null;
  let initialSnapshotError = null;
  if (!authoritySnapshot) {
    initialSnapshot = readArtifacts(artifacts);
  } else {
    try { initialSnapshot = readArtifacts(artifacts); }
    catch (error) { initialSnapshotError = diagnosticCode(error); }
  }
  const schema = initialSnapshot?.journalSchema ??
    loadPinnedJournalSchema(LOCAL_SCHEMA_PATH);
  let admitted;
  let recoveryPosture = null;
  if (!authoritySnapshot) {
    assert(!existing, "historical_authority_missing");
    const currentConformance = {
      schema, constitution: initialSnapshot.constitution, coverage: initialSnapshot.coverage,
      ownerAttestations: initialSnapshot.ownerAttestations,
    };
    admitted = verifyAdmission({
      binding, snapshot: initialSnapshot, admission, recovery,
      journalDir, conformance: currentConformance,
    });
    verifyExecutionPreflight(phases, binding);
    authoritySnapshot = historicalAuthoritySnapshot(
      initialSnapshot, recovery, admitted.immutableAdmissionDigest,
    );
    assert(createExclusive(authorityFile, authoritySnapshot), "historical_authority_conflict");
    recovery.fault?.("after-authority-snapshot");
  }
  const persistedAuthority = verifyHistoricalAuthority(authoritySnapshot, existing?.binding ?? binding, recovery);
  const conformance = {
    schema, constitution: authoritySnapshot.constitution, coverage: authoritySnapshot.coverage,
    ownerAttestations: authoritySnapshot.ownerAttestations,
  };
  const context = {
    ...persistedAuthority, policy: classPolicy(persistedAuthority.bundle.constitution),
    contentRef, conformance, journalDir, authoritySnapshot,
  };
  let durableWatchAnchor = null;
  let watchAnchorError = null;
  let watchAnchorTimingError = null;
  if (existing?.entries.some(entry => entry.phase === "watch")) {
    try { durableWatchAnchor = readWatchAnchor(file, existing); }
    catch (error) { watchAnchorError = diagnosticCode(error); }
  }
  if (existing?.entries.at(-1)?.phase === "commit") {
    assert(durableWatchAnchor !== null,
      `watch_anchor_${watchAnchorError ?? "missing"}`);
  }
  if (existing) {
    try {
      validateJournalSemantics(existing, conformance, {
        allowActive: true, watchAnchor: durableWatchAnchor,
      });
    } catch (error) {
      const code = diagnosticCode(error);
      // A durable late anchor invalidates success timing, not the R-forward
      // receipts produced to contain it. Commit-bearing histories stay strict.
      const recoverableWatchTimingFailure =
        durableWatchAnchor !== null &&
        !existing.entries.some(entry => entry.phase === "commit") &&
        code === "journal_apply_verify_budget_exceeded";
      if (!recoverableWatchTimingFailure) throw error;
      validateJournalSemantics(existing, conformance, { allowActive: true });
      watchAnchorTimingError = code;
    }
    const conflicting = canonicalJson(existing.binding) !== canonicalJson(binding);
    pendingOutbox = readOptional(`${file}.recovery-outbox.json`);
    if (pendingOutbox) {
      recoveryPosture = verifyRecoveryPosture({
        binding: existing.binding, snapshot: initialSnapshot, admission,
        snapshotError: initialSnapshotError,
      });
    }
    if (pendingOutbox?.stage === "complete") {
      assert(!conflicting, "attempt_conflicting_replay");
      assert(TERMINAL.has(existing.entries.at(-1).phase), "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
    if (pendingOutbox?.stage === "released") {
      assert(!conflicting && TERMINAL.has(existing.entries.at(-1).phase),
        "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "complete", recovery,
        "after-outbox-complete",
      );
      return {
        journal: existing, ran: false,
        reason: existing.entries.at(-1).phase === "disarm" ?
          "recovered-disarmed" : "terminally-blocked",
        recovery_error: pendingOutbox.recovery_error,
      };
    }
    if (pendingOutbox?.stage === "terminal-journaled") {
      assert(!conflicting && TERMINAL.has(existing.entries.at(-1).phase),
        "recovery_outbox_terminal_missing");
      const state = existing.entries.at(-1).phase === "disarm" ?
        "shadow" : "terminally-blocked";
      assert(repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      }), "execution_lease_active");
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "released", recovery,
        "after-terminal-release",
      );
      outboxCheckpoint(
        `${file}.recovery-outbox.json`, pendingOutbox, "complete", recovery,
        "after-outbox-complete",
      );
      return {
        journal: existing, ran: false,
        reason: existing.entries.at(-1).phase === "disarm" ?
          "recovered-disarmed" : "terminally-blocked",
        recovery_error: pendingOutbox.recovery_error,
      };
    }
    if (TERMINAL.has(existing.entries.at(-1).phase) && !pendingOutbox) {
      assert(!conflicting, "attempt_conflicting_replay");
      const state = existing.entries.at(-1).phase === "commit" ?
        existing.binding.admission_binding_state :
        existing.entries.at(-1).phase === "disarm" ? "shadow" : "terminally-blocked";
      if (!repairTerminalRelease({
        journalDir, binding: existing.binding, bindingDigest: existing.binding_digest, state,
      })) return { journal: existing, ran: false, reason: "execution-lease-active" };
      return { journal: existing, ran: false, reason: `terminal-${existing.entries.at(-1).phase}` };
    }
  }

  let recoveryOnly = false;
  let recoveryOnlyCode = "current-posture-requires-recovery";
  if (!admitted && pendingOutbox) {
    admitted = {
      now: recoveryPosture.now,
      immutableAdmissionDigest: authoritySnapshot.immutableAdmissionDigest,
    };
    recoveryOnly = true;
  } else if (!admitted) {
    recoveryPosture = verifyRecoveryPosture({
      binding: existing?.binding ?? binding, snapshot: initialSnapshot, admission,
      snapshotError: initialSnapshotError,
    });
    admitted = {
      now: recoveryPosture.now,
      immutableAdmissionDigest: authoritySnapshot.immutableAdmissionDigest,
    };
    recoveryOnly = recoveryPosture.mustRecover ||
      recoveryPosture.authorityDigest !==
        persistedAuthority.bundle.authorizationDigest ||
      recoveryPosture.coverageDigest !==
        persistedAuthority.bundle.coverage.registry_digest ||
      recoveryPosture.narrowingTailDigest !== persistedAuthority.narrowing.tailDigest;
  }
  const activeBinding = existing?.binding ?? binding;
  const activeBindingDigest = existing?.binding_digest ?? bindingDigest;
  const watchStateResume = existing?.entries.at(-1).phase === "watch" &&
    pendingOutbox === null;
  const watchContinuation = watchStateResume &&
    durableWatchAnchor !== null && watchAnchorTimingError === null;
  const claimed = claimTarget({
    journalDir, binding: activeBinding, bindingDigest: activeBindingDigest,
    now: admitted.now, policy: context.policy, resumeWatch: watchStateResume,
  });
  if (!claimed.acquired) return {
    journal: existing, ran: false, reason: "execution-lease-active",
  };
  const lease = claimed.lease;
  recovery.fault?.(claimed.transferred ? "after-lease-transfer" : "after-lease-claim");

  let journal = existing;
  if (!journal) {
    journal = {
      kind: "autonomous-mutation-journal", schema_version: "v2", journal_id: binding.mutation_id,
      domain: DOMAIN, constitution_digest: authoritySnapshot.constitution.constitution_digest,
      binding: structuredClone(binding), binding_digest: bindingDigest, entries: [], extensions: [],
    };
    journal.entries.push(makeEntry(journal, {
      phase: "prepare", at: admitted.now, actor: binding.controller_identity, contentRef,
    }));
    validateJournalSemantics(journal, conformance, { allowActive: true });
    assert(createExclusive(file, journal), "journal_prepare_conflict");
    recovery.fault?.("after-prepare-journal");
  }
  const leaseFence = activateResourceFence(
    phases, activeBinding, activeBindingDigest, lease,
  );
  activateResourceFence(recovery, activeBinding, activeBindingDigest, lease);
  if (existing) {
    if (canonicalJson(journal.binding) !== canonicalJson(binding)) {
      return enterRecovery({
        file, journal, context, admission, phases, recovery, lease,
        code: "attempt-conflicting-replay", lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (readOptional(`${file}.recovery-outbox.json`)) {
      const boundedRecovery = recoveryForBinding(
        recovery, journal.binding, journal.binding_digest,
      );
      return finishRecoveryOutbox({
        file, journal, context, admission, recovery: boundedRecovery,
        outboxFile: `${file}.recovery-outbox.json`, lease,
      });
    }
    if (!recoveryOnly) {
      try {
        const resumedAdmission = verifyAdmission({
          binding: journal.binding, snapshot: initialSnapshot, admission, recovery,
          journalDir, conformance, allowDeadlineEquality: watchContinuation,
        });
        recoveryOnly = resumedAdmission.immutableAdmissionDigest !==
          authoritySnapshot.immutableAdmissionDigest;
      } catch (error) {
        recoveryOnly = true;
        recoveryOnlyCode =
          `current-posture-${diagnosticCode(error)}`.slice(0, 96);
      }
    }
    if (recoveryOnly) {
      return enterRecovery({
        file, journal, context, admission, phases, recovery, lease,
        code: recoveryOnlyCode,
        lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (watchStateResume && !watchContinuation) {
      return enterRecovery({
        file, journal, context, admission, phases, recovery, lease,
        code: `watch-anchor-${
          watchAnchorError ?? watchAnchorTimingError ?? "missing"
        }`,
        lastAt: journal.entries.at(-1).recorded_at,
      });
    }
    if (!watchContinuation) {
      let reconciliation;
      try {
        if (typeof reconcile !== "function") {
          fail("attempt-reconciliation-unavailable");
        }
        reconciliation = reconcile({
          phase: journal.entries.at(-1).phase, lease_epoch: lease.epoch,
        });
        assert(exactKeys(reconciliation, ["state"]) &&
          ["not-applied", "applied", "indeterminate"].includes(
            reconciliation.state,
          ), "attempt_reconciliation_invalid");
      } catch (error) {
        return enterRecovery({
          file, journal, context, admission, phases, recovery, lease,
          code: String(error?.code ?? error?.message ??
            "attempt-reconciliation-failed"),
          lastAt: journal.entries.at(-1).recorded_at,
        });
      }
      if (journal.entries.at(-1).phase !== "prepare" ||
          reconciliation.state !== "not-applied") {
        return enterRecovery({
          file, journal, context, admission, phases, recovery, lease,
          code: `reconcile-${journal.entries.at(-1).phase}-${reconciliation.state}`,
          lastAt: journal.entries.at(-1).recorded_at,
        });
      }
    }
  }

  let at = trustedNow(admission.trustedClock, journal.entries.at(-1).recorded_at);
  try {
    if (watchContinuation) {
      const watchAt = Date.parse(durableWatchAnchor.anchored_at);
      const commitEarliest = watchAt +
        context.policy.bounds.minimum_watch_seconds * 1000;
      const commitLatest = commitEarliest +
        context.policy.bounds.commit_grace_seconds * 1000;
      if (Date.parse(admitted.now) < commitEarliest) {
        transitionTarget({
          journalDir, binding, bindingDigest, lease,
          state: "watching", release: true,
        });
        return { journal, ran: false, reason: "watching" };
      }
      assert(Date.parse(admitted.now) <= commitLatest,
        "maintenance_commit_grace_exceeded");
    }
    if (!watchContinuation) {
      const beforeApplySnapshot = readArtifacts(artifacts);
      const beforeApply = verifyAdmission({
        binding, snapshot: beforeApplySnapshot, admission, recovery,
        journalDir, conformance,
      });
      assert(beforeApply.immutableAdmissionDigest ===
        authoritySnapshot.immutableAdmissionDigest,
      "immutable_admission_drifted");
      verifyExecutionPreflight(phases, binding);
      checkKillSwitch(admission.killSwitch, binding);
      assertExecutionLease({ journalDir, binding, bindingDigest, lease });
      const applied = phases.applyFenced({
        lease_fence: structuredClone(leaseFence),
        lease_fence_digest: autonomyDigest(leaseFence),
      });
      assertExecutionLease({ journalDir, binding, bindingDigest, lease });
      assert(applied?.applied === true, "maintenance_apply_failed");
      at = trustedNow(admission.trustedClock, at);
      journal = appendFenced(file, journal, {
        phase: "apply", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      checkKillSwitch(admission.killSwitch, binding);
      const verified = phases.verify();
      assert(verified?.verified === true, "maintenance_verify_failed");
      at = trustedNow(admission.trustedClock, at);
      journal = appendFenced(file, journal, {
        phase: "verify", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      checkKillSwitch(admission.killSwitch, binding);
      journal = appendFenced(file, journal, {
        phase: "watch", at, actor: binding.controller_identity, contentRef,
      }, { journalDir, lease });
      durableWatchAnchor = persistWatchAnchor({
        file, journal, admission, recovery, previousAt: at,
      });
      assert(Date.parse(durableWatchAnchor.anchored_at) -
          Date.parse(journal.entries[0].recorded_at) <=
        context.policy.bounds.apply_verify_budget_seconds * 1000,
      "maintenance_apply_verify_budget_exceeded");
      assert(Date.parse(binding.deadline) -
          Date.parse(durableWatchAnchor.anchored_at) >=
        context.policy.bounds.minimum_watch_seconds * 1000,
      "maintenance_watch_deadline_unreachable");
      transitionTarget({
        journalDir, binding, bindingDigest, lease,
        state: "watching", release: true,
      });
      return { journal, ran: true, reason: "watching" };
    }
    const watchAt = Date.parse(durableWatchAnchor.anchored_at);
    assert(Date.parse(at) - watchAt >=
      context.policy.bounds.minimum_watch_seconds * 1000,
    "maintenance_watch_incomplete");
    assert(Date.parse(at) - watchAt <=
      (context.policy.bounds.minimum_watch_seconds +
        context.policy.bounds.commit_grace_seconds) * 1000,
    "maintenance_commit_grace_exceeded");
    checkKillSwitch(admission.killSwitch, binding);
    const readback = phases.safeStateReadback();
    assert(readback?.safe === true && readback.postconditions_digest === binding.postconditions_digest, "maintenance_safe_state_unverified");
    const beforeCommitSnapshot = readArtifacts(artifacts);
    const beforeCommit = verifyAdmission({
      binding, snapshot: beforeCommitSnapshot, admission, recovery, journalDir,
      conformance, allowDeadlineEquality: true,
    });
    assert(beforeCommit.immutableAdmissionDigest === authoritySnapshot.immutableAdmissionDigest,
      "immutable_admission_drifted");
    verifyExecutionCommitBinding(phases, binding);
    at = trustedNow(admission.trustedClock, at);
    assert(Date.parse(at) <= Date.parse(binding.deadline), "attempt_deadline_closed");
    journal = appendFenced(file, journal, {
      phase: "commit", at, actor: binding.controller_identity, contentRef,
    }, { journalDir, lease });
    recovery.fault?.("after-commit-journal");
    validateJournalSemantics(journal, conformance, {
      watchAnchor: durableWatchAnchor,
    });
    transitionTarget({
      journalDir, binding, bindingDigest, lease,
      state: binding.admission_binding_state, release: true,
    });
    recovery.fault?.("after-commit-release");
    return { journal, ran: true, reason: "committed" };
  } catch (error) {
    return enterRecovery({
      file, journal, context, admission, phases, recovery, lease,
      code: String(error?.code ?? error?.message ?? "maintenance-phase-error"),
      lastAt: at,
    });
  }
}

const DEBIAN_API = (() => {
  const MAX_PLAN_AGE_MS = 5 * 60 * 1000;
  const MAX_EVENTS = 24;
  const MAX_INVENTORY_BYTES = 16_384;
  const MAX_CANDIDATES = 256;
  const PACKAGE_NAME = /^[a-z0-9][a-z0-9+.-]{0,127}$/i;
  const PACKAGE_VERSION = /^[A-Za-z0-9:+.~-]{1,128}$/;
  const hash = value => `sha256:${crypto.createHash("sha256")
    .update(canonicalJson(value)).digest("hex")}`;
  const parseUtc = value => strictUtc(value) ? Date.parse(value) :
    fail("invalid_timestamp");
  const read = file => {
    try { return JSON.parse(fs.readFileSync(file, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
  };
  const write = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
    const fd = fs.openSync(temporary, "wx", 0o600);
    try {
      fs.writeFileSync(fd, `${canonicalJson(value)}\n`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temporary, file);
    fsyncDirectory(path.dirname(file));
  };
  const safeDetail = value => {
    const text = value && typeof value === "object" ?
      canonicalJson(value) : String(value ?? "");
    return {
      digest: hash(text), bytes: Buffer.byteLength(text),
      summary: typeof value?.code === "string" ?
        value.code.slice(0, 96) :
        typeof value?.ok === "boolean" ? `ok=${value.ok}` : "adapter-evidence",
    };
  };
  const inventory = value => {
    if (!plain(value)) fail("inventory_invalid");
    if (!exactKeys(value, [
      "kernel", "packages", "reboot_required", "dpkg_status",
    ])) fail("inventory_shape_invalid");
    if (typeof value.kernel !== "string" || value.kernel.length < 1 ||
        value.kernel.length > 256 || !PACKAGE_VERSION.test(value.kernel)) {
      fail("inventory_kernel_invalid");
    }
    if (!Array.isArray(value.packages) || value.packages.length < 1 ||
        value.packages.length > 256 ||
        !value.packages.every(element => (
          typeof element === "string" && element.length <= 256 &&
          /^[A-Za-z0-9][A-Za-z0-9:+.~=_-]{0,255}$/.test(element)
        )) || new Set(value.packages).size !== value.packages.length) {
      fail("inventory_packages_invalid");
    }
    if (value.reboot_required !== false) fail("inventory_reboot_unsafe");
    if (value.dpkg_status !== "clean") fail("inventory_dpkg_unsafe");
    const output = {
      kernel: value.kernel,
      packages: [...value.packages].sort(),
      reboot_required: false,
      dpkg_status: "clean",
    };
    if (Buffer.byteLength(canonicalJson(output)) > MAX_INVENTORY_BYTES) {
      fail("inventory_too_large");
    }
    return output;
  };
  const debianCandidates = candidates => {
    if (!Array.isArray(candidates) || candidates.length < 1 ||
        candidates.length > MAX_CANDIDATES) fail("debian_candidates_invalid");
    const result = candidates.map(candidate => {
      if (!exactKeys(candidate, [
        "id", "name", "class", "source", "current_version",
        "candidate_version", "eligible", "reasons",
      ]) || !PACKAGE_NAME.test(candidate.name) ||
          !PACKAGE_VERSION.test(candidate.candidate_version) ||
          (candidate.current_version !== null &&
            !PACKAGE_VERSION.test(candidate.current_version)) ||
          candidate.id !== `${candidate.name}@${candidate.candidate_version}` ||
          !["security", "bugfix"].includes(candidate.class) ||
          candidate.source !== "distro_repository" ||
          candidate.eligible !== true || !Array.isArray(candidate.reasons) ||
          candidate.reasons.length !== 0) {
        fail("debian_candidate_invalid");
      }
      return structuredClone(candidate);
    });
    const identities = result.map(candidate => candidate.id);
    const packages = result.map(candidate => candidate.name);
    if (new Set(identities).size !== identities.length ||
        new Set(packages).size !== packages.length) {
      fail("debian_candidate_duplicate");
    }
    const sorted = [...identities].sort();
    if (canonicalJson(identities) !== canonicalJson(sorted)) {
      fail("debian_candidates_not_canonical");
    }
    return result;
  };
  const deepFreeze = value => {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const child of Object.values(value)) deepFreeze(child);
    }
    return value;
  };
  const assertPolicy = policy => {
    if (!policy || policy.kind !== "maintenance-policy" ||
        policy.schema_version !== "v1" ||
        typeof policy.policy_id !== "string" ||
        policy.policy_digest !== policyDigest(policy)) fail("policy_invalid");
    return policy;
  };
  const verifyPlan = ({ plan, policy, nowMs, nodeId }) => {
    if (!plan || plan.kind !== "brokkr-maintenance-plan" ||
        plan.schema_version !== "v1" || plan.outcome !== "planned") {
      fail("plan_not_planned");
    }
    const copy = structuredClone(plan);
    const supplied = copy.plan_digest;
    delete copy.plan_digest;
    if (supplied !== hash(copy)) fail("plan_digest_invalid");
    if (!plain(plan.decision) ||
        !["on_schedule", "run_deferred"].includes(plan.decision.effect) ||
        !Array.isArray(plan.blockers) || plan.blockers.length !== 0 ||
        !Array.isArray(plan.hook_gaps) ||
        !Array.isArray(plan.unmet_policy_classes) ||
        typeof plan.inventory_evidence_id !== "string" ||
        typeof plan.running_kernel !== "string" ||
        typeof plan.plan_id !== "string" || plan.plan_id.length > 128 ||
        typeof plan.node_id !== "string" || plan.node_id.length > 128 ||
        plan.hook_gaps.length > 64 || plan.unmet_policy_classes.length > 64 ||
        plan.node_id !== nodeId || !policy.selector.node_ids.includes(nodeId) ||
        plan.policy_digest !== policy.policy_digest ||
        plan.policy_id !== policy.policy_id) fail("plan_not_authorized");
    const age = nowMs - parseUtc(plan.created_at);
    if (age < 0 || age > MAX_PLAN_AGE_MS) fail("plan_stale");
    const gates = plan.gates;
    if (!plain(gates) || gates.package_manager_lock !== "unlocked" ||
        gates.disk !== "sufficient" ||
        !["mains", "not_applicable"].includes(gates.power) ||
        gates.clock !== "synchronized" ||
        gates.workload_hooks !== "not_applicable" ||
        plan.hook_gaps.length !== 0) fail("plan_gates_not_safe");
    const candidates = debianCandidates(plan.candidates);
    if (!candidates.every(candidate => (
          policy.updates.allowed_classes.includes(candidate.class) &&
          policy.updates.allowed_sources.includes(candidate.source)
        ))) fail("plan_gates_not_safe");
  };
  const currentAdmission = ({ plan, policy, nodeId, adapters }) => {
    const clock = adapters.clock();
    if (!clock || clock.synchronized !== true || !strictUtc(clock.now)) {
      fail("clock_uncertain");
    }
    const current = assertPolicy(adapters.currentPolicy());
    assertPolicy(policy);
    if (current.policy_id !== policy.policy_id ||
        current.policy_digest !== policy.policy_digest) {
      fail("policy_changed_before_mutation");
    }
    if (current.state?.enabled !== true ||
        current.state?.hold?.active === true ||
        adapters.hold().active === true) fail("held");
    const status = windowStatus(current, parseUtc(clock.now));
    if (!status.eligible) fail("window_closed_before_mutation");
    verifyPlan({ plan, policy: current, nowMs: parseUtc(clock.now), nodeId });
    return {
      policy: current, now: clock.now,
      remaining_window_ms:
        Date.parse(status.occurrence.end) - parseUtc(clock.now),
    };
  };

  function deriveDebianAutonomyExecution({
    plan, policy, target, inventory: preState, adapterRevisionDigest,
    postconditions,
  }) {
    assertPolicy(policy);
    if (!target ||
        Object.keys(target).sort().join(",") !==
          "node_id,non_pillar,platform" ||
        target.platform !== "debian" || target.non_pillar !== true ||
        target.node_id !== plan?.node_id ||
        !DIGEST.test(adapterRevisionDigest) || !plain(postconditions)) {
      fail("autonomy_execution_out_of_scope");
    }
    const planCopy = structuredClone(plan);
    const suppliedPlanDigest = planCopy?.plan_digest;
    delete planCopy?.plan_digest;
    if (!DIGEST.test(suppliedPlanDigest) ||
        suppliedPlanDigest !== hash(planCopy) ||
        plan.gates?.workload_hooks !== "not_applicable" ||
        policy.reboot?.policy !== "never" ||
        !Array.isArray(policy.updates?.allowed_classes) ||
        !policy.updates.allowed_classes.every(item => (
          ["security", "bugfix"].includes(item)
        )) || !Array.isArray(policy.updates?.allowed_sources) ||
        !policy.updates.allowed_sources.every(item => (
          item === "distro_repository"
        ))) fail("autonomy_execution_out_of_scope");
    const normalizedCandidates = debianCandidates(plan.candidates);
    if (!normalizedCandidates.every(item => (
      policy.updates.allowed_classes.includes(item.class) &&
      policy.updates.allowed_sources.includes(item.source)
    ))) fail("autonomy_execution_out_of_scope");
    const normalizedPreState = inventory(preState);
    const normalizedPostconditions = inventory(postconditions);
    const targetScopeDigest = hash({
      node_id: target.node_id, platform: target.platform,
    });
    const configDigest = hash({
      adapter_revision_digest: adapterRevisionDigest,
      node_id: target.node_id, target_scope_digest: targetScopeDigest,
    });
    const baselineDigest = hash({
      inventory: normalizedPreState, node_id: target.node_id,
      target_scope_digest: targetScopeDigest,
    });
    const postconditionsDigest = hash(normalizedPostconditions);
    const evidenceDigest = hash({
      baseline_digest: baselineDigest,
      candidate_digest: suppliedPlanDigest, config_digest: configDigest,
      policy_digest: policy.policy_digest,
    });
    const executionRequest = {
      kind: "brokkr-bounded-debian-maintenance-request",
      schema_version: "v1", target: structuredClone(target),
      candidates: normalizedCandidates,
      config: {
        adapter_revision_digest: adapterRevisionDigest,
        plan_digest: suppliedPlanDigest,
        policy_digest: policy.policy_digest,
        no_reboot: true, no_drain: true,
      },
      pre_state: normalizedPreState,
      expected_postconditions: normalizedPostconditions,
    };
    return {
      node_id: target.node_id, target_scope_digest: targetScopeDigest,
      candidate_digest: suppliedPlanDigest, config_digest: configDigest,
      evidence_digest: evidenceDigest, policy_digest: policy.policy_digest,
      baseline_digest: baselineDigest,
      postconditions_digest: postconditionsDigest,
      pre_state: normalizedPreState,
      postconditions: normalizedPostconditions,
      adapter_revision_digest: adapterRevisionDigest,
      execution_request: executionRequest,
      execution_request_digest: hash(executionRequest),
    };
  }

  const execute = ({
    plan, policy, nodeId, journalFile, adapters, boundInitialInventory,
    boundExecutionRequest, leaseFence,
  }) => {
    for (const name of [
      "applyFenced", "afterInventory", "currentPolicy", "clock", "hold",
      "substrateHealth",
    ]) if (typeof adapters?.[name] !== "function") {
      fail("adapter_contract_invalid");
    }
    if (read(journalFile) !== null) fail("journal_already_exists");
    const initial = currentAdmission({ plan, policy, nodeId, adapters });
    if (policy.reboot?.policy !== "never" ||
        plan.gates?.workload_hooks !== "not_applicable" ||
        !leaseFence || leaseFence.kind !== "brokkr-effect-lease-fence" ||
        leaseFence.schema_version !== "v1" ||
        !Number.isSafeInteger(leaseFence.epoch) || leaseFence.epoch < 1 ||
        !DIGEST.test(leaseFence.target_scope_digest) ||
        !DIGEST.test(leaseFence.binding_digest) ||
        typeof leaseFence.holder_token !== "string" ||
        !strictUtc(leaseFence.activated_at) ||
        !strictUtc(leaseFence.expires_at) ||
        Date.parse(leaseFence.activated_at) > Date.parse(leaseFence.expires_at) ||
        boundExecutionRequest?.kind !==
          "brokkr-bounded-debian-maintenance-request" ||
        boundExecutionRequest.schema_version !== "v1" ||
        boundExecutionRequest.config?.no_reboot !== true ||
        boundExecutionRequest.config?.no_drain !== true) {
      fail("autonomous_adapter_capability_invalid");
    }
    const journal = {
      kind: "brokkr-debian-mutation-journal", schema_version: "v1",
      plan_id: plan.plan_id, plan_digest: plan.plan_digest,
      policy_digest: policy.policy_digest, node_id: nodeId,
      execution_request_digest: hash(boundExecutionRequest),
      lease_epoch: leaseFence.epoch, adapter_receipt_digest: null,
      unmet_policy_classes: plan.unmet_policy_classes.map(item => ({
        class: String(item.class ?? "unknown").slice(0, 64),
        reason: String(item.reason ?? "unspecified").slice(0, 96),
      })),
      outcome: "running", events: [],
      before_inventory: inventory(boundInitialInventory),
      after_inventory: null, reversal: null, failure: null,
    };
    let eventAt = initial.now;
    const event = (phase, outcome, detail) => {
      if (journal.events.length >= MAX_EVENTS) fail("journal_event_limit");
      journal.events.push({
        at: eventAt, phase, outcome, detail: safeDetail(detail),
      });
      write(journalFile, journal);
    };
    try {
      event("inventory_before", "succeeded", journal.before_inventory);
      const immediate = currentAdmission({ plan, policy, nodeId, adapters });
      eventAt = immediate.now;
      event("admission_revalidated", "succeeded", {});
      const limits = {
        timeout_ms: durationToMs(policy.execution_limits.timeout),
        remaining_window_ms: immediate.remaining_window_ms,
      };
      const invocation = deepFreeze({
        kind: "brokkr-bounded-debian-adapter-invocation",
        schema_version: "v1",
        execution_request: structuredClone(boundExecutionRequest),
        execution_request_digest: hash(boundExecutionRequest),
        lease_fence: structuredClone(leaseFence),
        lease_fence_digest: hash(leaseFence), limits,
      });
      event("apply_started", "started", invocation);
      const applied = adapters.applyFenced(invocation);
      const receipt = structuredClone(applied);
      const suppliedReceiptDigest = receipt?.receipt_digest;
      delete receipt?.receipt_digest;
      if (!exactKeys(receipt, [
        "ok", "elapsed_ms", "execution_request_digest",
        "lease_fence_digest", "fence_checked_at", "reboot_required",
      ]) || receipt.ok !== true ||
          receipt.execution_request_digest !== hash(boundExecutionRequest) ||
          receipt.lease_fence_digest !== hash(leaseFence) ||
          receipt.reboot_required !== false ||
          !Number.isFinite(receipt.elapsed_ms) || receipt.elapsed_ms < 0 ||
          receipt.elapsed_ms >
            Math.min(limits.timeout_ms, limits.remaining_window_ms) ||
          suppliedReceiptDigest !== hash(receipt)) {
        fail("adapter_receipt_unbound");
      }
      assertFenceFreshAt(
        leaseFence, receipt.fence_checked_at, "effect_lease_expired",
      );
      journal.adapter_receipt_digest = suppliedReceiptDigest;
      event("apply", "succeeded", applied);
      const substrate = adapters.substrateHealth();
      event("substrate_health", substrate?.ok ? "succeeded" : "failed",
        substrate);
      if (!substrate?.ok) fail("substrate_health_failed");
      journal.after_inventory = inventory(adapters.afterInventory());
      event("inventory_after", "succeeded", journal.after_inventory);
      journal.outcome = "succeeded";
      write(journalFile, journal);
      return { outcome: "succeeded", journal };
    } catch (error) {
      journal.failure = {
        code: String(error?.code ?? "executor_failed").slice(0, 96),
        diagnostic: safeDetail({
          message: String(error?.message ?? error).slice(0, 256),
        }),
      };
      journal.outcome = "operator_recovery_required";
      write(journalFile, journal);
      return {
        outcome: journal.outcome, reason: journal.failure.code, journal,
      };
    }
  };

  function runBoundDebianMaintenance(options) {
    const {
      binding, attemptJournalDir, artifacts, admission, recovery,
      reconcile = null, target, expectedPostconditions, plan, policy,
      nodeId = plan?.node_id, adapters,
    } = options ?? {};
    if (!binding || typeof attemptJournalDir !== "string" || !artifacts ||
        !admission || !recovery || !target || !expectedPostconditions ||
        !plan || !policy || !adapters ||
        typeof adapters.revisionDigest !== "function" ||
        typeof adapters.targetMetadata !== "function") {
      fail("attempt_journal_contract_invalid");
    }
    const journalFile = path.join(
      attemptJournalDir, "mutation", `${binding.attempt_id}.json`,
    );
    let executionResult = null;
    let captured = null;
    const staticTarget = () => {
      const actual = adapters.targetMetadata();
      if (canonicalJson(actual) !== canonicalJson(target) ||
          actual.node_id !== nodeId ||
          canonicalJson(adapters.currentPolicy()) !== canonicalJson(policy)) {
        fail("execution_binding_substituted");
      }
      return actual;
    };
    const accept = actual => {
      for (const field of [
        "target_scope_digest", "candidate_digest", "config_digest",
        "evidence_digest", "policy_digest", "baseline_digest",
        "postconditions_digest",
      ]) if (binding[field] !== actual[field]) {
        fail("execution_binding_substituted");
      }
      captured = actual;
      return {
        execution_digest: executionBindingDigest(actual),
      };
    };
    const capture = () => accept(deriveDebianAutonomyExecution({
      plan, policy, target: staticTarget(),
      inventory: inventory(adapters.inventory()),
      adapterRevisionDigest: adapters.revisionDigest(),
      postconditions: expectedPostconditions,
    }));
    const commitBinding = () => {
      const actualTarget = staticTarget();
      if (!captured) {
        const mutation = read(journalFile);
        if (mutation?.outcome !== "succeeded" ||
            !mutation.before_inventory) {
          fail("execution_binding_evidence_missing");
        }
        const actual = deriveDebianAutonomyExecution({
          plan, policy, target: actualTarget,
          inventory: mutation.before_inventory,
          adapterRevisionDigest: adapters.revisionDigest(),
          postconditions: expectedPostconditions,
        });
        if (mutation.execution_request_digest !==
            actual.execution_request_digest) {
          fail("execution_binding_substituted");
        }
        return accept(actual);
      }
      if (adapters.revisionDigest() !== captured.adapter_revision_digest) {
        fail("execution_binding_substituted");
      }
      return { execution_digest: executionBindingDigest(captured) };
    };
    return runMaintenanceAttempt({
      journalDir: attemptJournalDir, binding, artifacts, admission, recovery,
      reconcile,
      phases: {
        preflight: capture, commitBinding,
        activateFence: fence => {
          if (typeof adapters.activateFence !== "function") {
            fail("adapter_fence_capability_missing");
          }
          return adapters.activateFence(
            deepFreeze(structuredClone(fence)),
          );
        },
        applyFenced: ({ lease_fence, lease_fence_digest }) => {
          if (lease_fence_digest !== hash(lease_fence)) {
            fail("effect_lease_fence_unconfirmed");
          }
          executionResult = execute({
            plan, policy, nodeId, journalFile, adapters,
            boundInitialInventory: captured.pre_state,
            boundExecutionRequest: deepFreeze(
              structuredClone(captured.execution_request),
            ),
            leaseFence: deepFreeze(structuredClone(lease_fence)),
          });
          if (executionResult.outcome !== "succeeded") {
            fail("executor_postconditions_unmet");
          }
          return { applied: true };
        },
        verify: () => ({
          verified: executionResult?.outcome === "succeeded",
        }),
        safeStateReadback: () => {
          const fresh = inventory(adapters.inventory());
          return {
            safe: hash(fresh) === binding.postconditions_digest,
            postconditions_digest: hash(fresh),
          };
        },
      },
    });
  }
  return { deriveDebianAutonomyExecution, runBoundDebianMaintenance };
})();

export const { deriveDebianAutonomyExecution } = DEBIAN_API;
export const __BROKKR_TEST_ONLY__LOCK_TICKET_LIMITS = Object.freeze({
  compaction_threshold: LOCK_TICKET_COMPACTION_THRESHOLD,
  live_hard_limit: LOCK_TICKET_LIVE_HARD_LIMIT,
  tmp_hard_limit: LOCK_TICKET_TMP_HARD_LIMIT,
});
export function __BROKKR_TEST_ONLY__currentLockOwnerIdentity() {
  return currentLockOwnerIdentity();
}
export function __BROKKR_TEST_ONLY__probeExclusiveDirectory(lockDir, operation = () => true) {
  return withExclusiveDirectory(lockDir, "lock_probe_contended", operation);
}

// The raw W2a runner stays in DEBIAN_API's closure.  This is intentionally the
// only exported production runner so every ambiguous effect must cross the
// target-bound W2a -> W2b activation and fixed-recover dispatcher.
export function runDebianMaintenance(options = {}) {
  const { binding, recovery } = options;
  if (!plain(binding) || !plain(recovery) || !ID.test(binding.attempt_id) ||
    !ID.test(binding.mutation_id) || !ID.test(binding.recovery_disarm_id) ||
    !DIGEST.test(binding.target_scope_digest) ||
    !DIGEST.test(binding.recovery?.descriptor_digest)) {
    fail("bounded_recovery_dispatch_required");
  }
  const boundedRecoveryFactory = ({ binding: recoveredBinding, bindingDigest }) => {
    if (!plain(recoveredBinding) || !DIGEST.test(bindingDigest) ||
      bindingDigest !== autonomyDigest(recoveredBinding) ||
      !ID.test(recoveredBinding.attempt_id) ||
      !ID.test(recoveredBinding.mutation_id) ||
      !ID.test(recoveredBinding.recovery_disarm_id) ||
      !DIGEST.test(recoveredBinding.target_scope_digest) ||
      !DIGEST.test(recoveredBinding.recovery?.descriptor_digest)) {
      fail("bounded_recovery_dispatch_required");
    }
    return createBoundedRecoveryDispatcher({
      expected: {
        attemptId: recoveredBinding.attempt_id,
        bindingDigest,
        descriptorDigest: recoveredBinding.recovery.descriptor_digest,
        idempotencyKey: recoveredBinding.recovery_disarm_id,
        mutationId: recoveredBinding.mutation_id,
        targetScopeDigest: recoveredBinding.target_scope_digest,
      },
    });
  };
  return DEBIAN_API.runBoundDebianMaintenance({
    ...options,
    recovery: { ...recovery, [BOUNDED_RECOVERY_FACTORY]: boundedRecoveryFactory },
  });
}
