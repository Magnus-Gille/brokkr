#!/usr/bin/env node
// Authenticated, observation-only maintenance-result delivery. The exact v1
// result arrives on stdin and the protected systemd credential supplies the
// gate and transport settings. No endpoint, token, or source path is accepted
// in argv or emitted in output.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { validateMaintenanceExecutionResult } from
  "./maintenance-execution-result.mjs";

const CREDENTIAL_NAME = "brokkr-maintenance-result-delivery-v1";
const ENDPOINT_PATH = "/api/maintenance-execution-results";
const MAX_RESULT_BYTES = 64 * 1024;
const MAX_CONFIG_BYTES = 16 * 1024;
const REVISION = /^[a-f0-9]{40}$/;
const DIGEST = /^sha256:[a-f0-9]{64}$/;
const TOKEN = /^[A-Za-z0-9._~+/=-]{16,512}$/;
const RETRY_DELAYS_MS = [0, 100, 250];

class DeliveryError extends Error {
  constructor(code) {
    super(code);
    this.name = "DeliveryError";
  }
}

const fail = code => {
  throw new DeliveryError(code);
};

const exact = (value, keys) => (
  value && typeof value === "object" && !Array.isArray(value) &&
  Object.keys(value).length === keys.length &&
  keys.every(key => Object.hasOwn(value, key))
);

async function readBoundedStdin() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_RESULT_BYTES) fail("result_too_large");
    chunks.push(chunk);
  }
  if (size === 0) fail("result_missing");
  return Buffer.concat(chunks, size);
}

function readProtectedConfig() {
  const directory = process.env.CREDENTIALS_DIRECTORY;
  if (!directory || !path.isAbsolute(directory)) fail("config_missing");
  let directoryStat;
  try {
    directoryStat = fs.lstatSync(directory);
  } catch {
    fail("config_unsafe");
  }
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink() ||
      directoryStat.uid !== process.geteuid() ||
      (directoryStat.mode & 0o022) !== 0) {
    fail("config_unsafe");
  }

  const configPath = path.join(directory, CREDENTIAL_NAME);
  let descriptor;
  let stat;
  try {
    descriptor = fs.openSync(
      configPath,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
    );
    stat = fs.fstatSync(descriptor);
  } catch (error) {
    if (error?.code === "ENOENT") fail("config_missing");
    fail("config_unsafe");
  }
  const mode = stat.mode & 0o7777;
  if (!stat.isFile() || stat.uid !== process.geteuid() ||
      ![0o400, 0o600].includes(mode) ||
      stat.size < 2 || stat.size > MAX_CONFIG_BYTES) {
    fs.closeSync(descriptor);
    fail("config_unsafe");
  }

  let config;
  try {
    config = JSON.parse(fs.readFileSync(descriptor, "utf8"));
  } catch {
    fs.closeSync(descriptor);
    fail("config_invalid");
  }
  fs.closeSync(descriptor);
  return config;
}

function validateConfig(config) {
  const revision = process.env.BROKKR_ADAPTER_REVISION;
  const digest = process.env.BROKKR_ADAPTER_DIGEST;
  if (!REVISION.test(revision ?? "") || !DIGEST.test(digest ?? "")) {
    fail("adapter_binding_missing");
  }
  const common = [
    "kind", "schema_version", "enabled", "adapter_revision",
    "adapter_digest",
  ];
  if (!exact(config, config?.enabled === true ?
    [...common, "endpoint", "bearer_token"] : common) ||
      config.kind !== "brokkr-maintenance-result-delivery-config" ||
      config.schema_version !== "v1" ||
      typeof config.enabled !== "boolean" ||
      config.adapter_revision !== revision ||
      config.adapter_digest !== digest) {
    fail("config_invalid");
  }
  if (!config.enabled) return { enabled: false };

  if (typeof config.endpoint !== "string" ||
      typeof config.bearer_token !== "string" ||
      !TOKEN.test(config.bearer_token)) {
    fail("config_invalid");
  }
  let endpoint;
  try {
    endpoint = new URL(config.endpoint);
  } catch {
    fail("config_invalid");
  }
  if (endpoint.protocol !== "https:" ||
      endpoint.username !== "" || endpoint.password !== "" ||
      endpoint.pathname !== ENDPOINT_PATH ||
      endpoint.search !== "" || endpoint.hash !== "" ||
      endpoint.href !== config.endpoint) {
    fail("endpoint_invalid");
  }
  return {
    enabled: true,
    endpoint: config.endpoint,
    bearerToken: config.bearer_token,
  };
}

const wait = milliseconds => new Promise(resolve =>
  setTimeout(resolve, milliseconds));

function curlOnce(resultBytes, result, transport) {
  return new Promise(resolve => {
    const child = spawn("curl", [
      "--disable",
      "--noproxy", "*",
      "--config", "/dev/fd/3",
      "--proto", "=https",
      "--proto-redir", "=https",
      "--tlsv1.2",
      "--max-redirs", "0",
      "--connect-timeout", "5",
      "--max-time", "10",
      "--max-filesize", String(MAX_RESULT_BYTES),
      "--request", "POST",
      "--header", "Content-Type: application/json",
      "--header", "Accept: application/json",
      "--header", `Idempotency-Key: ${result.result_digest}`,
      "--data-binary", "@-",
      "--output", "/dev/null",
      "--write-out", "%{http_code}",
      "--silent",
      "--show-error",
    ], {
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        LANG: "C",
        LC_ALL: "C",
      },
      stdio: ["pipe", "pipe", "ignore", "pipe"],
    });
    let status = "";
    let outputOverflow = false;
    child.stdout.setEncoding("ascii");
    child.stdout.on("data", chunk => {
      status += chunk;
      if (status.length > 16) {
        outputOverflow = true;
        child.kill("SIGKILL");
      }
    });
    child.on("error", () => resolve({ curlOk: false, status: null }));
    child.on("close", code => {
      const httpStatus = /^[0-9]{3}$/.test(status) ?
        Number.parseInt(status, 10) : null;
      resolve({
        curlOk: code === 0 && !outputOverflow,
        status: httpStatus,
      });
    });
    child.stdin.on("error", () => {});
    child.stdio[3].on("error", () => {});
    const curlConfig = [
      `url = "${transport.endpoint}"`,
      `header = "Authorization: Bearer ${transport.bearerToken}"`,
      "",
    ].join("\n");
    child.stdio[3].end(curlConfig);
    child.stdin.end(resultBytes);
  });
}

async function deliver(resultBytes, result, transport) {
  for (let index = 0; index < RETRY_DELAYS_MS.length; index += 1) {
    if (RETRY_DELAYS_MS[index] > 0) {
      await wait(RETRY_DELAYS_MS[index]);
    }
    const outcome = await curlOnce(resultBytes, result, transport);
    if (outcome.curlOk &&
        outcome.status >= 200 && outcome.status <= 299) {
      return;
    }
    const retryable = outcome.status === null ||
      outcome.status === 0 ||
      (outcome.status >= 500 && outcome.status <= 599);
    if (!retryable || index === RETRY_DELAYS_MS.length - 1) {
      fail(outcome.status === null || outcome.status === 0 ?
        "delivery_transport_failure" : "delivery_rejected");
    }
  }
  fail("delivery_transport_failure");
}

try {
  if (process.argv.length !== 2) fail("arguments_forbidden");
  const resultBytes = await readBoundedStdin();
  let result;
  try {
    result = JSON.parse(resultBytes.toString("utf8"));
    validateMaintenanceExecutionResult(result);
  } catch {
    fail("result_invalid");
  }
  if (result.source.source_id !== "brokkr-maintenance") {
    fail("result_source_invalid");
  }
  const transport = validateConfig(readProtectedConfig());
  if (!transport.enabled) {
    process.stdout.write(`${JSON.stringify({
      kind: "maintenance-execution-result-delivery",
      schema_version: "v1",
      delivered: false,
      reason: "delivery_disabled",
      result_id: result.result_id,
    })}\n`);
  } else {
    await deliver(resultBytes, result, transport);
    process.stdout.write(`${JSON.stringify({
      kind: "maintenance-execution-result-delivery",
      schema_version: "v1",
      delivered: true,
      result_id: result.result_id,
      result_digest: result.result_digest,
      execution_epoch: result.execution_epoch,
    })}\n`);
  }
} catch (error) {
  const code = error instanceof DeliveryError ?
    error.message : "internal_failure";
  process.stderr.write(`maintenance-result-delivery: ${code}\n`);
  process.exitCode = 1;
}
