// Delivery of Brokkr's closed `systemd-supervision-audit` v1 document to
// Heimdall (BROKKR-123). Observation-only: the audit JSON arrives on stdin, a
// protected systemd credential supplies endpoint + token, and nothing here
// touches units, journals, or the host. Every failure is a visible, content-free
// error code; success requires a 2xx from Heimdall.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkSchema, schemaErrors } from "./maintenance-policy-contract.mjs";

export const CREDENTIAL_NAME = "brokkr-systemd-supervision-delivery-v1";
export const ENDPOINT_PATH = "/api/systemd-supervision";
export const MAX_AUDIT_BYTES = 256 * 1024; // matches Heimdall's route bodyLimit
const MAX_CONFIG_BYTES = 16 * 1024;
const TOKEN = /^[A-Za-z0-9._~+/=-]{16,512}$/;
const RETRY_DELAYS_MS = [0, 500, 2000];
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const AUDIT_SCHEMA_PATH = path.join(ROOT, "docs/systemd-supervision-audit-v1.schema.json");

export class DeliveryError extends Error {
  constructor(code) {
    super(code);
    this.name = "DeliveryError";
  }
}
const fail = (code) => { throw new DeliveryError(code); };

const exact = (value, keys) => (
  value && typeof value === "object" && !Array.isArray(value) &&
  Object.keys(value).length === keys.length &&
  keys.every((key) => Object.hasOwn(value, key))
);

/** Read the protected credential. Mirrors the maintenance-result delivery guards. */
export function readProtectedConfig(env = process.env) {
  const directory = env.CREDENTIALS_DIRECTORY;
  if (!directory || !path.isAbsolute(directory)) fail("config_missing");
  const trustedOwners = new Set([0, process.geteuid()]);
  let directoryStat;
  try { directoryStat = fs.lstatSync(directory); } catch { fail("config_unsafe"); }
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink() ||
      !trustedOwners.has(directoryStat.uid) || (directoryStat.mode & 0o022) !== 0) {
    fail("config_unsafe");
  }
  let descriptor;
  let stat;
  try {
    descriptor = fs.openSync(path.join(directory, CREDENTIAL_NAME),
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    stat = fs.fstatSync(descriptor);
  } catch (error) {
    if (error?.code === "ENOENT") fail("config_missing");
    fail("config_unsafe");
  }
  try {
    const mode = stat.mode & 0o7777;
    if (!stat.isFile() || !trustedOwners.has(stat.uid) ||
        ![0o400, 0o600].includes(mode) || stat.size < 2 || stat.size > MAX_CONFIG_BYTES) {
      fail("config_unsafe");
    }
    try { return JSON.parse(fs.readFileSync(descriptor, "utf8")); } catch { fail("config_invalid"); }
  } finally {
    fs.closeSync(descriptor);
  }
  return undefined;
}

export function validateConfig(config) {
  const common = ["kind", "schema_version", "enabled"];
  if (!exact(config, config?.enabled === true ? [...common, "endpoint", "bearer_token"] : common) ||
      config.kind !== "brokkr-systemd-supervision-delivery-config" ||
      config.schema_version !== "v1" || typeof config.enabled !== "boolean") {
    fail("config_invalid");
  }
  if (!config.enabled) return { enabled: false };
  if (typeof config.endpoint !== "string" || typeof config.bearer_token !== "string" ||
      !TOKEN.test(config.bearer_token)) {
    fail("config_invalid");
  }
  let endpoint;
  try { endpoint = new URL(config.endpoint); } catch { fail("config_invalid"); }
  if (endpoint.protocol !== "https:" || endpoint.username !== "" || endpoint.password !== "" ||
      endpoint.pathname !== ENDPOINT_PATH || endpoint.search !== "" || endpoint.hash !== "" ||
      endpoint.href !== config.endpoint) {
    fail("endpoint_invalid");
  }
  return { enabled: true, endpoint: config.endpoint, bearerToken: config.bearer_token };
}

/**
 * Parse and gate the audit document. The exact bytes that pass are the exact
 * bytes delivered (no re-serialization), so a retry re-sends the identical
 * observation and Heimdall's monotonic `observed_at` makes it idempotent.
 */
export function parseAudit(bytes, nowMs = Date.now()) {
  if (bytes.length === 0) fail("audit_missing");
  if (bytes.length > MAX_AUDIT_BYTES) fail("audit_too_large");
  let audit;
  try { audit = JSON.parse(bytes.toString("utf8")); } catch { fail("audit_invalid"); }
  let schema;
  try {
    schema = JSON.parse(fs.readFileSync(AUDIT_SCHEMA_PATH, "utf8"));
    checkSchema(schema);
  } catch { fail("schema_unavailable"); }
  if (audit?.kind !== "systemd-supervision-audit" || audit?.schema_version !== "v1" ||
      schemaErrors(schema, audit).length > 0) {
    fail("audit_invalid");
  }
  // Never deliver a stale or future observation as if it were current evidence.
  const observed = Date.parse(audit.observed_at);
  const maxAgeMs = audit.freshness.max_age_seconds * 1000;
  if (audit.freshness.status !== "fresh" || !Number.isFinite(observed) ||
      nowMs - observed >= maxAgeMs || observed - nowMs > 5000) {
    fail("observation_stale");
  }
  return audit;
}

export async function deliver(bytes, transport, {
  fetchFn = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  delays = RETRY_DELAYS_MS,
} = {}) {
  for (let index = 0; index < delays.length; index += 1) {
    if (delays[index] > 0) await sleep(delays[index]);
    let status = null;
    try {
      const response = await fetchFn(transport.endpoint, {
        method: "POST",
        redirect: "error",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          Authorization: `Bearer ${transport.bearerToken}`,
        },
        body: bytes,
        signal: AbortSignal.timeout(10_000),
      });
      status = response.status;
      await response.body?.cancel().catch(() => undefined);
    } catch {
      status = null;
    }
    if (status !== null && status >= 200 && status <= 299) return;
    const retryable = status === null || (status >= 500 && status <= 599);
    if (!retryable || index === delays.length - 1) {
      fail(status === null ? "delivery_transport_failure" : "delivery_rejected");
    }
  }
  fail("delivery_transport_failure");
}
