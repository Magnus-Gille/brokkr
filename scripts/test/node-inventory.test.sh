#!/usr/bin/env bash
# Hermetic tests for the read-only node-capability producer (brokkr#7).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INVENTORY="$ROOT/scripts/node-inventory.mjs"
LIB="$ROOT/scripts/lib/node-substrate-contract.mjs"
SCHEMA="$ROOT/docs/node-substrate-contract-v1.schema.json"
FIXTURES="$ROOT/tests/fixtures/node-inventory"
NODE_BIN="$(command -v node)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DETAIL_KEY="$TMP/detail-private.pem"
DETAIL_PUBLIC_KEY="$TMP/detail-public.pem"
"$NODE_BIN" - "$DETAIL_KEY" "$DETAIL_PUBLIC_KEY" <<'NODE'
const fs = require("fs"), crypto = require("crypto");
const [privateFile, publicFile] = process.argv.slice(2);
const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
fs.writeFileSync(privateFile, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
fs.writeFileSync(publicFile, publicKey.export({ type: "spki", format: "pem" }));
NODE

fail() { echo "node-inventory.test.sh: FAIL: $1" >&2; exit 1; }

# --- 1. Provenance: vendored schema and fixtures are byte-identical to the pins.
PROVENANCE="$ROOT/docs/node-substrate-contract-provenance.md"
for file in "$SCHEMA" \
  "$ROOT"/tests/fixtures/node-substrate-contract/consumer-fixture-set.json \
  "$ROOT"/tests/fixtures/node-substrate-contract/negative.json \
  "$ROOT"/tests/fixtures/node-substrate-contract/partial-drain.json \
  "$ROOT"/tests/fixtures/node-substrate-contract/partial-substrate.json \
  "$ROOT"/tests/fixtures/node-substrate-contract/positive.json; do
  hash="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  grep -q "$hash" "$PROVENANCE" || fail "vendored $(basename "$file") drifted from pinned SHA-256 $hash"
done

# --- Shared JSON assertion helper (uses the same dependency-free validator the
# --- producer uses, so tests and producer cannot diverge silently).
cat >"$TMP/check.mjs" <<NODE
import fs from "node:fs";
import crypto from "node:crypto";
import { schemaErrors, checkSchema, canonicalJson, evidenceDigest, strictUtc, assertPinnedContractFiles } from "${LIB}";
const schema = JSON.parse(fs.readFileSync("${SCHEMA}", "utf8"));
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const die = (message) => { console.error(message); process.exit(1); };
const scanPrivate = (value, at = "\$") => {
  if (typeof value === "string") {
    if (/(?:\b(?:10|127|192\.168)\.|\b172\.(?:1[6-9]|2\d|3[01])\.)|\/Users\/|\.ssh\/|password=|token=/i.test(value)) die(at + ": private locator");
    return;
  }
  if (Array.isArray(value)) return value.forEach((item, index) => scanPrivate(item, at + "[" + index + "]"));
  if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      if (/^(?:wifi_?ssid|ssid|wifi_?name|credential|token|password)\$/i.test(key)) die(at + "." + key + ": private key");
      scanPrivate(item, at + "." + key);
    }
  }
};
const validRecord = (record, label) => {
  const errors = schemaErrors(schema, record);
  if (errors.length) die(label + " violates schema: " + errors.join("; "));
  if (!strictUtc(record.observed_at) || !strictUtc(record.valid_until)) die(label + ": non-strict UTC timestamps");
  if (record.evidence.observed_at !== record.observed_at || record.evidence.producer !== "brokkr") die(label + ": evidence not brokkr-bound");
  if (record.evidence.digest !== "sha256:" + evidenceDigest(record)) die(label + ": evidence digest does not recompute");
};
const [command, ...rest] = process.argv.slice(2);
if (command === "schema-selfcheck") {
  checkSchema(schema);
  const positive = read("${ROOT}/tests/fixtures/node-substrate-contract/positive.json");
  for (const record of positive.records) {
    if (schemaErrors(schema, record).length) die("pinned positive fixture rejected: " + record.kind);
  }
  const negative = read("${ROOT}/tests/fixtures/node-substrate-contract/negative.json");
  if (!schemaErrors(schema, negative.schema_unsupported_version).length) die("unsupported schema_version accepted");
  const mutated = structuredClone(positive.records[0]);
  mutated.private_note = "x";
  if (!schemaErrors(schema, mutated).length) die("additional property accepted");
} else if (command === "pinned-contract") {
  assertPinnedContractFiles({ schemaPath: rest[0], manifestPath: rest[1], provenancePath: rest[2] });
} else if (command === "record") {
  validRecord(read(rest[0]), rest[0]);
} else if (command === "compare") {
  const [outFile, fixtureFile] = rest;
  const out = read(outFile);
  const fixture = read(fixtureFile);
  validRecord(fixture, fixtureFile);
  scanPrivate(fixture);
  if (canonicalJson(out) !== canonicalJson(fixture)) die("output diverged from golden fixture " + fixtureFile);
} else if (command === "assert") {
  const r = read(rest[0]);
  for (const expression of rest.slice(1)) {
    if (!Function("r", "return (" + expression + ");")(r)) die("assertion failed on " + rest[0] + ": " + expression);
  }
} else if (command === "evidence-ids") {
  const [sameA, sameB, distinct] = rest.map(read);
  if (sameA.evidence.evidence_id !== sameB.evidence.evidence_id) die("identical observations received different evidence ids");
  if (sameA.evidence.evidence_id === distinct.evidence.evidence_id) die("distinct observations reused an evidence id");
} else if (command === "detail") {
  const line = fs.readFileSync(rest[0], "utf8").split("\n").find((entry) => entry.startsWith("Brokkr node inventory detail JSON: "));
  if (!line) die("missing detail record");
  const detail = JSON.parse(line.slice("Brokkr node inventory detail JSON: ".length));
  const expected = ["backup_roles", "detail_digest", "kind", "observation_digest", "observation_evidence_id", "observed_at", "schema_version", "signature", "signing_key_id", "unit_state", "valid_until", "workloads"];
  if (JSON.stringify(Object.keys(detail).sort()) !== JSON.stringify(expected)) die("detail record is not closed");
  if (detail.kind !== "brokkr-node-inventory-detail" || detail.schema_version !== "v1") die("detail record is not versioned");
  if (!strictUtc(detail.observed_at) || !strictUtc(detail.valid_until)) die("detail lacks strict freshness");
  const signature = detail.signature;
  delete detail.signature;
  const claimedDigest = detail.detail_digest;
  delete detail.detail_digest;
  const actualDigest = "sha256:" + crypto.createHash("sha256").update(canonicalJson(detail)).digest("hex");
  if (claimedDigest !== actualDigest) die("detail digest does not verify");
  detail.detail_digest = claimedDigest;
  const publicKey = crypto.createPublicKey(fs.readFileSync("${DETAIL_PUBLIC_KEY}"));
  if (!crypto.verify(null, Buffer.from(canonicalJson(detail)), publicKey, Buffer.from(signature, "base64"))) die("detail signature does not verify");
  if (!Array.isArray(detail.unit_state.units) || detail.unit_state.status !== "known") die("detail omits known unit state");
  for (const unit of detail.unit_state.units) {
    if (JSON.stringify(Object.keys(unit).sort()) !== JSON.stringify(["active_state", "installed_state", "name", "sub_state"])) die("detail unit has an unsafe field");
  }
} else {
  die("unknown check command " + command);
}
NODE

check() { "$NODE_BIN" "$TMP/check.mjs" "$@"; }

# --- 2. Vendored contract self-check with the dependency-free validator.
check schema-selfcheck

# --- 3. The runtime preflight, not only this test, pins the exact shared
# --- schema, consumer manifest, and provenance before parsing the schema.
check pinned-contract "$SCHEMA" \
  "$ROOT/tests/fixtures/node-substrate-contract/consumer-fixture-set.json" "$PROVENANCE"
PINNED_COPY="$TMP/pinned-contract"; mkdir -p "$PINNED_COPY"
cp "$SCHEMA" "$PINNED_COPY/schema.json"
cp "$ROOT/tests/fixtures/node-substrate-contract/consumer-fixture-set.json" "$PINNED_COPY/manifest.json"
cp "$PROVENANCE" "$PINNED_COPY/provenance.md"
printf '\n' >>"$PINNED_COPY/schema.json"
if check pinned-contract "$PINNED_COPY/schema.json" "$PINNED_COPY/manifest.json" "$PINNED_COPY/provenance.md" 2>/dev/null; then
  fail "tampered pinned schema was accepted"
fi

new_mock() { MOCK="$TMP/mock-$1"; rm -rf "$MOCK"; mkdir -p "$MOCK"; }
mock() { cat >"$MOCK/$1"; chmod +x "$MOCK/$1"; }
run_inventory() { env -i PATH="$MOCK" "$@" "$NODE_BIN" "$INVENTORY"; }
run_inventory_detail() { env -i PATH="$MOCK" BROKKR_INVENTORY_DETAIL_SIGNING_KEY="$DETAIL_KEY" "$@" "$NODE_BIN" "$INVENTORY" --detail; }
expect_fail() {
  local desc="$1" pattern="$2"; shift 2
  local out
  if out=$(env -i PATH="$MOCK" "$@" "$NODE_BIN" "$INVENTORY" 2>"$TMP/err"); then
    fail "expected failure: $desc"
  fi
  [ -z "$out" ] || fail "stdout must stay empty on $desc"
  grep -qi "$pattern" "$TMP/err" || { cat "$TMP/err" >&2; fail "stderr lacks '$pattern' on $desc"; }
}

nas_mocks() {
  new_mock nas
  mock getconf <<'EOF'
#!/bin/sh
echo 4
EOF
  mock awk <<'EOF'
#!/bin/sh
echo 7914
EOF
  mock uname <<'EOF'
#!/bin/sh
echo aarch64
EOF
  mock df <<'EOF'
#!/bin/sh
printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n'
printf '/dev/root 117000 24000 88000 22%% /\n'
printf '/dev/sda1 953869 400000 553869 42%% /srv/fixture-t7\n'
EOF
  mock systemctl <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then
  echo 'systemd 252'
elif [ "$1" = list-unit-files ]; then
  printf 'mimir.service enabled\n'
  printf 'tunnel.service enabled\n'
  printf 'agent.service enabled\n'
  printf 'backup-offsite.timer enabled\n'
else
  printf 'mimir.service loaded active running Fixture\n'
  printf 'tunnel.service loaded active running Fixture\n'
  printf 'agent.service loaded active running Fixture\n'
  printf 'backup-offsite.timer loaded active waiting Fixture\n'
fi
EOF
  mock ip <<'EOF'
#!/bin/sh
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\n'
printf '3: wlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000\n'
EOF
  mock tailscale <<'EOF'
#!/bin/sh
echo '{"BackendState":"Running","Self":{"Online":true}}'
EOF
}

write_overlay() { # path, then JSON on stdin
  cat >"$1"
  chmod 600 "$1"
}

NAS_OVERLAY="$TMP/nas-overlay.json"
write_overlay "$NAS_OVERLAY" <<'EOF'
{
  "uptime_class": "always_on",
  "deployment_mechanisms": ["guarded_deploy", "systemd"],
  "health_reporting": "supported",
  "logical_storage": [
    { "class": "local_ssd", "mount": "/" },
    { "class": "external_ssd", "mount": "/srv/fixture-t7" }
  ],
  "workloads": ["mimir"],
  "backup_roles": ["consumer", "producer"]
}
EOF

# --- 4. NAS golden path: exact fixture, digest recomputation, active-path parsing.
nas_mocks
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/nas.json" 2>"$TMP/nas.err"
check compare "$TMP/nas.json" "$FIXTURES/fixture-nas.json"
check assert "$TMP/nas.json" \
  'r.capability_status === "known"' \
  'r.valid_until === "2026-07-23T11:00:00Z"' \
  'JSON.stringify(r.network_capabilities) === JSON.stringify(["wired","tailnet"])' \
  'r.logical_storage.length === 2 && r.logical_storage[0].class === "local_ssd" && r.logical_storage[0].available_mib === 88000 && r.logical_storage[0].status === "known"' \
  'r.logical_storage[1].class === "external_ssd" && r.logical_storage[1].available_mib === 553869 && r.logical_storage[1].status === "known"' \
  'r.extensions.map((e) => e.id).join(",") === "backup-role-consumer,backup-role-producer,workload-mimir"' \
  'r.extensions.every((e) => e.version === "v1" && e.decision_effect === "informational")'
grep -q 'units=mimir.service\[active/running\],tunnel.service\[active/running\],agent.service\[active/running\],backup-offsite.timer\[active/waiting\]' "$TMP/nas.err"
grep -q 'workloads=mimir' "$TMP/nas.err"
grep -q 'backup-roles=consumer,producer' "$TMP/nas.err"
grep -q 'all probes collected' "$TMP/nas.err"

# The optional detail record preserves stdout as exactly the normative v1
# record while making installed/active unit state and overlay observations
# available without a second SSH exploration.
nas_mocks
run_inventory_detail BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/nas-detail.json" 2>"$TMP/nas-detail.err"
check compare "$TMP/nas-detail.json" "$FIXTURES/fixture-nas.json"
check detail "$TMP/nas-detail.err"

nas_mocks
if env -i PATH="$MOCK" BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" "$NODE_BIN" "$INVENTORY" --detail \
  >"$TMP/unsigned-detail.out" 2>"$TMP/unsigned-detail.err"; then
  fail "unsigned operational detail was emitted"
fi
[ ! -s "$TMP/unsigned-detail.out" ] || fail "unsigned detail failure emitted inventory stdout"
grep -q 'DETAIL_SIGNING_KEY is required' "$TMP/unsigned-detail.err" || fail "missing signing key was not named"

# The same material is stable, but a new observation instant gets a new,
# contract-valid id rather than reusing obs-<node> forever.
nas_mocks
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/nas-stable.json" 2>/dev/null
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:01Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/nas-next.json" 2>/dev/null
check evidence-ids "$TMP/nas.json" "$TMP/nas-stable.json" "$TMP/nas-next.json"

m5_mocks() {
  new_mock m5
  mock getconf <<'EOF'
#!/bin/sh
echo 10
EOF
  mock awk <<'EOF'
#!/bin/sh
exit 2
EOF
  mock sysctl <<'EOF'
#!/bin/sh
echo 17179869184
EOF
  mock uname <<'EOF'
#!/bin/sh
if [ "$1" = -s ]; then
  echo Darwin
else
  echo arm64
fi
EOF
mock launchctl <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then
  echo 'Darwin Bootstrapper Version 8.0.0'
else
  printf '%s\t%s\t%s\n' 411 0 com.example.fixture-hugin
  printf '%s\t%s\t%s\n' - 0 com.example.fixture-backup
fi
EOF
  mock df <<'EOF'
#!/bin/sh
printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk3s5 3901000 1200000 500000 31%% /\n'
EOF
  mock ifconfig <<'EOF'
#!/bin/sh
printf 'en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n'
printf 'en7: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n'
EOF
  mock networksetup <<'EOF'
#!/bin/sh
printf 'Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: 00:00:00:00:00:00\n\n'
printf 'Hardware Port: USB 10/100/1000 LAN\nDevice: en7\nEthernet Address: 00:00:00:00:00:01\n'
EOF
  mock tailscale <<'EOF'
#!/bin/sh
echo '{"BackendState":"Running","Self":{"Online":true}}'
EOF
}

M5_OVERLAY="$TMP/m5-overlay.json"
write_overlay "$M5_OVERLAY" <<'EOF'
{
  "uptime_class": "always_on",
  "deployment_mechanisms": ["guarded_deploy"],
  "health_reporting": "supported",
  "logical_storage": [{ "class": "local_ssd", "mount": "/" }],
  "workloads": ["fixture-hugin"],
  "backup_roles": ["producer"]
}
EOF

# --- 5. M5 golden path: launchd, sysctl memory fallback, Darwin network classification.
m5_mocks
run_inventory BROKKR_NODE_ID=fixture-m5 BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$M5_OVERLAY" >"$TMP/m5.json" 2>"$TMP/m5.err"
check compare "$TMP/m5.json" "$FIXTURES/fixture-m5.json"
check assert "$TMP/m5.json" \
  'r.capability_status === "known"' \
  'r.service_manager === "launchd"' \
  'r.resources.cpu_cores === 10 && r.resources.memory_mib === 16384' \
  'JSON.stringify(r.network_capabilities) === JSON.stringify(["wired","wifi","tailnet"])' \
  'r.extensions.map((e) => e.id).join(",") === "backup-role-producer,workload-fixture-hugin"'
grep -q 'units=com.example.fixture-hugin\[running/exited\],com.example.fixture-backup\[not-running/exited\]' "$TMP/m5.err"
grep -q 'all probes collected' "$TMP/m5.err"

# --- 6. Stopped, offline, and malformed Tailscale states are distinct
# --- fail-closed observations and never advertise tailnet.
nas_mocks
mock ip <<'EOF'
#!/bin/sh
printf '2: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq state DOWN mode DEFAULT group default qlen 1000\n'
EOF
mock tailscale <<'EOF'
#!/bin/sh
echo '{"BackendState":"Stopped"}'
EOF
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/down.json" 2>/dev/null
check record "$TMP/down.json"
check assert "$TMP/down.json" \
  'JSON.stringify(r.network_capabilities) === JSON.stringify(["unknown"])' \
  'r.capability_status === "unknown"' \
  'r.extensions.some((e) => e.id === "probe-failed-tailnet-stopped")'

nas_mocks
mock tailscale <<'EOF'
#!/bin/sh
echo '{"BackendState":"Running","Self":{"Online":false}}'
EOF
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/offline.json" 2>/dev/null
check assert "$TMP/offline.json" \
  '!r.network_capabilities.includes("tailnet")' \
  'r.capability_status === "unknown"' \
  'r.extensions.some((e) => e.id === "probe-failed-tailnet-offline")'

# --- 6. Malformed tailscale JSON is a probe failure, never a tailnet capability.
nas_mocks
mock tailscale <<'EOF'
#!/bin/sh
echo 'Tailscale was not running'
EOF
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/malformed.json" 2>"$TMP/malformed.err"
check record "$TMP/malformed.json"
check assert "$TMP/malformed.json" \
  '!r.network_capabilities.includes("tailnet")' \
  'r.capability_status === "unknown"' \
  'r.extensions.some((e) => e.id === "probe-failed-tailnet-malformed")'
grep -q 'partial probes=tailnet-malformed' "$TMP/malformed.err"

# --- 7. Partial probe failure stays schema-valid, explicit, and keeps known facts.
nas_mocks
mock getconf <<'EOF'
#!/bin/sh
exit 1
EOF
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/partial.json" 2>"$TMP/partial.err"
check record "$TMP/partial.json"
check assert "$TMP/partial.json" \
  'r.capability_status === "unknown"' \
  'r.resources.cpu_cores === 1' \
  'r.resources.memory_mib === 7914' \
  'r.extensions.some((e) => e.id === "probe-failed-cpu" && e.decision_effect === "informational")' \
  'JSON.stringify(r.network_capabilities) === JSON.stringify(["wired","tailnet"])'
grep -q 'partial probes=cpu' "$TMP/partial.err"

# --- 8. A declared but unmounted store is reported unknown, never invented.
nas_mocks
mock df <<'EOF'
#!/bin/sh
printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\n'
printf '/dev/root 117000 24000 88000 22%% /\n'
EOF
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_OVERLAY="$NAS_OVERLAY" >"$TMP/unmounted.json" 2>/dev/null
check record "$TMP/unmounted.json"
check assert "$TMP/unmounted.json" \
  'r.logical_storage[0].status === "known" && r.logical_storage[0].available_mib === 88000' \
  'r.logical_storage[1].class === "external_ssd" && r.logical_storage[1].status === "unknown" && r.logical_storage[1].available_mib === 0'

# --- 9. Without an owner overlay nothing is invented: explicit unknowns only.
nas_mocks
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  >"$TMP/bare.json" 2>/dev/null
check record "$TMP/bare.json"
check assert "$TMP/bare.json" \
  'JSON.stringify(r.logical_storage) === JSON.stringify([{class:"unknown",available_mib:0,status:"unknown"}])' \
  'r.uptime_class === "unknown"' \
  'JSON.stringify(r.deployment_mechanisms) === JSON.stringify(["unknown"])' \
  'r.health_reporting === "unknown"' \
  'r.extensions.length === 0'

# --- 10. Malformed input fails clearly before collection, without emitting JSON.
nas_mocks
expect_fail 'invalid node id' 'node id' BROKKR_NODE_ID='Bad_ID'
expect_fail 'overlong node id' 'node id' BROKKR_NODE_ID="n$(printf 'a%.0s' {1..70})"
expect_fail 'impossible calendar date' 'BROKKR_INVENTORY_NOW' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-02-30T10:00:00Z
expect_fail 'subsecond timestamp' 'BROKKR_INVENTORY_NOW' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00.000Z
expect_fail 'offset timestamp' 'BROKKR_INVENTORY_NOW' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00+02:00
expect_fail 'zero ttl' 'TTL' BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_TTL_SECONDS=0
expect_fail 'non-numeric ttl' 'TTL' BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_TTL_SECONDS=abc
expect_fail 'unbounded ttl' 'TTL' BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_TTL_SECONDS=100000

BAD_OVERLAY="$TMP/bad-overlay.json"
write_overlay "$BAD_OVERLAY" <<'EOF'
{ "uptime_class": "always_on" }
EOF
chmod 644 "$BAD_OVERLAY"
expect_fail 'group/other-readable overlay' 'overlay' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_OVERLAY="$BAD_OVERLAY"
chmod 600 "$BAD_OVERLAY"
ln -sf "$BAD_OVERLAY" "$TMP/overlay-link.json"
expect_fail 'symlinked overlay' 'overlay' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_OVERLAY="$TMP/overlay-link.json"
write_overlay "$BAD_OVERLAY" <<'EOF'
{ "uptime_class": "always_on", "surprise": true }
EOF
expect_fail 'unknown overlay key' 'overlay' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_OVERLAY="$BAD_OVERLAY"
write_overlay "$BAD_OVERLAY" <<'EOF'
{ "logical_storage": [{ "class": "ramdisk", "mount": "/" }] }
EOF
expect_fail 'invalid storage class' 'overlay' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_OVERLAY="$BAD_OVERLAY"
write_overlay "$BAD_OVERLAY" <<'EOF'
{ "workloads": ["Bad Workload"] }
EOF
expect_fail 'invalid overlay workload id' 'overlay' \
  BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_OVERLAY="$BAD_OVERLAY"

# --- 11. TTL bounds drive valid_until exactly.
nas_mocks
run_inventory BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z \
  BROKKR_INVENTORY_TTL_SECONDS=60 >"$TMP/ttl.json" 2>/dev/null
check assert "$TMP/ttl.json" 'r.valid_until === "2026-07-23T10:01:00Z"'

echo 'node-inventory.test.sh: PASS'
