#!/usr/bin/env bash
# Hermetic regression for BROKKR-123: delivery of the systemd-supervision audit
# to Heimdall. No network: lib-level tests inject fetch; CLI tests stop before
# any transport (disabled / missing / unsafe config, stale or invalid audit).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/systemd-supervision"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A real, schema-valid audit produced by the real audit program (replay clock).
BROKKR_SYSTEMD_AUDIT_ALLOW_REPLAY=1 node "$ROOT/scripts/systemd-supervision-audit.mjs" \
  --baseline "$ROOT/docs/systemd-supervision-baseline-v1.json" \
  --registry "$FIXTURES/registry.json" --declarations "$FIXTURES/declarations-positive.json" \
  --observations "$FIXTURES/observations-positive.json" --now 2026-08-02T12:00:00Z \
  >"$TMP/audit.json" 2>/dev/null
check "fixture audit generated" '[[ -s "$TMP/audit.json" ]]'

# The same audit made current against the real clock.
node --input-type=module - "$TMP/audit.json" "$TMP/fresh.json" <<'NODE'
import fs from "node:fs";
const [src, dst] = process.argv.slice(2);
const audit = JSON.parse(fs.readFileSync(src, "utf8"));
const now = new Date(Math.floor(Date.now() / 1000) * 1000).toISOString().replace(".000Z", "Z");
audit.observed_at = now;
audit.evaluated_at = now;
audit.freshness = { status: "fresh", age_seconds: 0, max_age_seconds: 900 };
fs.writeFileSync(dst, JSON.stringify(audit, null, 2));
NODE

# ---- lib-level behaviour with injected fetch ----
cat >"$TMP/lib-test.mjs" <<'NODE'
import fs from "node:fs";
import assert from "node:assert/strict";
const lib = await import(`${process.env.ROOT}/scripts/lib/systemd-supervision-delivery.mjs`);
const staleBytes = fs.readFileSync(process.env.STALE);
const freshBytes = fs.readFileSync(process.env.FRESH);
const TOKEN = "dedicated-token-sentinel_1234567890";
const transport = { endpoint: "https://heimdall.example.invalid/api/systemd-supervision", bearerToken: TOKEN };
const code = async (fn) => { try { await fn(); return "ok"; } catch (e) { return e.message; } };
const res = (status) => new Response("{}", { status });
const results = [];
const t = async (name, fn) => { try { await fn(); results.push(`PASS ${name}`); } catch (e) { results.push(`FAIL ${name}: ${e.message}`); } };

await t("stale observation is rejected (not delivered as current)", async () => {
  assert.equal(await code(() => lib.parseAudit(staleBytes)), "observation_stale");
});
await t("replayed clock accepts the same doc when it is current", async () => {
  const audit = lib.parseAudit(staleBytes, Date.parse("2026-08-02T12:00:30Z"));
  assert.equal(audit.kind, "systemd-supervision-audit");
});
await t("future-dated observation is rejected", async () => {
  assert.equal(await code(() => lib.parseAudit(staleBytes, Date.parse("2026-08-02T11:00:00Z"))), "observation_stale");
});
await t("non-fresh freshness status is rejected even when timestamps look current", async () => {
  const a = JSON.parse(staleBytes); a.freshness.status = "stale";
  assert.equal(await code(() => lib.parseAudit(Buffer.from(JSON.stringify(a)), Date.parse("2026-08-02T12:00:30Z"))), "observation_stale");
});
await t("unknown field (e.g. raw journal text) is rejected by the closed schema", async () => {
  const a = JSON.parse(freshBytes); a.journal = "secret raw output";
  assert.equal(await code(() => lib.parseAudit(Buffer.from(JSON.stringify(a)))), "audit_invalid");
});
await t("wrong kind / malformed / empty / oversize audit rejected", async () => {
  const a = JSON.parse(freshBytes); a.kind = "other";
  assert.equal(await code(() => lib.parseAudit(Buffer.from(JSON.stringify(a)))), "audit_invalid");
  assert.equal(await code(() => lib.parseAudit(Buffer.from("not json"))), "audit_invalid");
  assert.equal(await code(() => lib.parseAudit(Buffer.alloc(0))), "audit_missing");
  assert.equal(await code(() => lib.parseAudit(Buffer.alloc(lib.MAX_AUDIT_BYTES + 1))), "audit_too_large");
});
await t("delivery POSTs the exact bytes with the dedicated Bearer and no redirects", async () => {
  const calls = [];
  const fetchFn = async (url, init) => { calls.push([url, init]); return res(200); };
  await lib.deliver(freshBytes, transport, { fetchFn, sleep: async () => {} });
  assert.equal(calls.length, 1);
  const [url, init] = calls[0];
  assert.equal(url, transport.endpoint);
  assert.equal(init.method, "POST");
  assert.equal(init.redirect, "error");
  assert.equal(init.headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(Buffer.compare(Buffer.from(init.body), freshBytes), 0);
});
await t("5xx and transport errors retry with identical bytes (idempotent), then succeed", async () => {
  const bodies = [];
  const seq = [() => { throw new TypeError("down"); }, () => res(503), () => res(200)];
  const fetchFn = async (_u, init) => { bodies.push(Buffer.from(init.body).toString("base64")); return seq.shift()(); };
  await lib.deliver(freshBytes, transport, { fetchFn, sleep: async () => {} });
  assert.equal(bodies.length, 3);
  assert.equal(new Set(bodies).size, 1);
});
await t("4xx (auth/schema/replay rejection) is a visible failure and not retried", async () => {
  for (const status of [400, 401, 409, 422]) {
    let n = 0;
    const fetchFn = async () => { n += 1; return res(status); };
    assert.equal(await code(() => lib.deliver(freshBytes, transport, { fetchFn, sleep: async () => {} })), "delivery_rejected");
    assert.equal(n, 1);
  }
});
await t("credential mode predicate: 0440 only for root:root (BROKKR-175)", () => {
  const owners = new Set([0, 1000]);
  const st = (uid, gid, mode) => ({ uid, gid, mode: 0o100000 | mode });
  assert.equal(lib.credentialModeAllowed(st(0, 0, 0o440), owners), true);
  assert.equal(lib.credentialModeAllowed(st(1000, 1000, 0o440), owners), false);
  assert.equal(lib.credentialModeAllowed(st(0, 1000, 0o440), owners), false);
  assert.equal(lib.credentialModeAllowed(st(0, 0, 0o660), owners), false);
  assert.equal(lib.credentialModeAllowed(st(0, 0, 0o640), owners), false);
  assert.equal(lib.credentialModeAllowed(st(1000, 1000, 0o600), owners), true);
  assert.equal(lib.credentialModeAllowed(st(1000, 1000, 0o400), owners), true);
  assert.equal(lib.credentialModeAllowed(st(4242, 0, 0o400), owners), false);
});
await t("exhausted retries fail visibly without leaking the token", async () => {
  const fetchFn = async () => { throw new TypeError(`boom ${TOKEN}`); };
  const message = await code(() => lib.deliver(freshBytes, transport, { fetchFn, sleep: async () => {} }));
  assert.equal(message, "delivery_transport_failure");
  assert.ok(!message.includes(TOKEN));
});
await t("config validation: https + exact path + token shape; disabled form has no secrets", async () => {
  const good = { kind: "brokkr-systemd-supervision-delivery-config", schema_version: "v1", enabled: true,
    endpoint: transport.endpoint, bearer_token: TOKEN };
  assert.equal(lib.validateConfig(good).enabled, true);
  assert.deepEqual(lib.validateConfig({ kind: good.kind, schema_version: "v1", enabled: false }), { enabled: false });
  for (const mutate of [
    (c) => { c.endpoint = "http://heimdall.example.invalid/api/systemd-supervision"; },
    (c) => { c.endpoint = "https://heimdall.example.invalid/api/other"; },
    (c) => { c.endpoint = "https://user:pw@heimdall.example.invalid/api/systemd-supervision"; },
    (c) => { c.endpoint = "https://heimdall.example.invalid/api/systemd-supervision?x=1"; },
    (c) => { c.bearer_token = "short"; },
    (c) => { c.extra = 1; },
    (c) => { delete c.bearer_token; },
  ]) {
    const c = { ...good }; mutate(c);
    assert.ok((await code(() => lib.validateConfig(c))) !== "ok");
  }
});
console.log(results.join("\n"));
process.exit(results.some((r) => r.startsWith("FAIL")) ? 1 : 0);
NODE
LIB_OUT="$(ROOT="$ROOT" STALE="$TMP/audit.json" FRESH="$TMP/fresh.json" node "$TMP/lib-test.mjs" 2>&1)"; LIB_RC=$?
: "$LIB_RC"
while IFS= read -r line; do
  case "$line" in PASS*) ok "${line#PASS }";; FAIL*) bad "${line#FAIL }";; esac
done <<<"$LIB_OUT"
check "lib suite exits 0" '[[ $LIB_RC -eq 0 ]]'

# ---- CLI behaviour (never reaches the network) ----
CREDS="$TMP/creds"; mkdir -m 0700 "$CREDS"
CRED_NAME="brokkr-systemd-supervision-delivery-v1"
# shellcheck disable=SC2120,SC2034  # RC is read inside check's eval; cli takes no args
cli() { CREDENTIALS_DIRECTORY="$CREDS" node "$ROOT/scripts/systemd-supervision-delivery.mjs" "$@" <"$INPUT" >"$TMP/out" 2>"$TMP/err"; RC=$?; }

INPUT="$TMP/fresh.json"
cli
check "missing credential fails closed (config_missing)" '[[ $RC -eq 1 ]] && grep -q "config_missing" "$TMP/err"'

printf '{"kind":"brokkr-systemd-supervision-delivery-config","schema_version":"v1","enabled":false}' >"$CREDS/$CRED_NAME"; chmod 0644 "$CREDS/$CRED_NAME"
cli
check "group/other-readable credential is unsafe" '[[ $RC -eq 1 ]] && grep -q "config_unsafe" "$TMP/err"'

chmod 0660 "$CREDS/$CRED_NAME"
cli
check "group-writable credential is unsafe" '[[ $RC -eq 1 ]] && grep -q "config_unsafe" "$TMP/err"'

chmod 0600 "$CREDS/$CRED_NAME"
cli
check "disabled config delivers nothing and exits 0 (rollback path)" '[[ $RC -eq 0 ]] && grep -q "\"delivered\":false" "$TMP/out" && grep -q delivery_disabled "$TMP/out"'

INPUT="$TMP/audit.json"
cli
check "stale audit is a visible failure even when delivery is disabled" '[[ $RC -eq 1 ]] && grep -q observation_stale "$TMP/err"'

INPUT="$TMP/fresh.json"
CREDENTIALS_DIRECTORY="$CREDS" node "$ROOT/scripts/systemd-supervision-delivery.mjs" --endpoint x <"$INPUT" >"$TMP/out" 2>"$TMP/err"; RC=$?
: "$RC"
check "arguments (endpoint/token) are refused" '[[ $RC -eq 1 ]] && grep -q arguments_forbidden "$TMP/err"'

printf 'garbage' >"$TMP/garbage"; INPUT="$TMP/garbage"; cli
check "garbage stdin is rejected" '[[ $RC -eq 1 ]] && grep -q audit_invalid "$TMP/err"'

printf '{"kind":"brokkr-systemd-supervision-delivery-config","schema_version":"v1","enabled":true,"endpoint":"http://heimdall.example.invalid/api/systemd-supervision","bearer_token":"dedicated-token-sentinel_1234567890"}' >"$CREDS/$CRED_NAME"
INPUT="$TMP/fresh.json"
# Non-https endpoint fails config validation before any network use, so this
# exercises the real error path with the token present in the credential.
cli
check "invalid enabled config fails without network" '[[ $RC -eq 1 ]] && grep -q endpoint_invalid "$TMP/err"'
check "token never appears in CLI output" '! grep -rq "dedicated-token-sentinel" "$TMP/out" "$TMP/err"'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
