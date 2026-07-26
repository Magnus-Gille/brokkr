#!/usr/bin/env bash
# Hermetic controller inspection tests (brokkr#46).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INSPECT="$ROOT/scripts/brokkr.mjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "controller-inspect.test.sh: FAIL: $*" >&2; exit 1; }
test -f "$INSPECT" || fail "missing controller inspect command"
KEY="$TMP/key.pem"; PUB="$TMP/pub.pem"; DETAIL="$TMP/detail.json"; RECORD="$ROOT/tests/fixtures/node-inventory/fixture-nas.json"
node - "$KEY" "$PUB" "$DETAIL" "$RECORD" <<'NODE'
const fs = require("fs"), crypto = require("crypto");
const [keyFile, pubFile, detailFile, recordFile] = process.argv.slice(2);
const c = v => Array.isArray(v) ? `[${v.map(c).join(",")}]` : v && typeof v === "object" ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${c(v[k])}`).join(",")}}` : JSON.stringify(v);
const record = JSON.parse(fs.readFileSync(recordFile)); const {privateKey, publicKey} = crypto.generateKeyPairSync("ed25519");
fs.writeFileSync(keyFile, privateKey.export({type:"pkcs8",format:"pem"}), {mode:0o600}); fs.writeFileSync(pubFile, publicKey.export({type:"spki",format:"pem"}), {mode:0o600});
const keyId = "sha256:" + crypto.createHash("sha256").update(publicKey.export({type:"spki",format:"der"})).digest("hex");
const detail = {kind:"brokkr-node-inventory-detail",schema_version:"v1",observation_evidence_id:record.evidence.evidence_id,observation_digest:record.evidence.digest,observed_at:record.observed_at,valid_until:record.valid_until,signing_key_id:keyId,unit_state:{status:"known",units:[]},workloads:[],backup_roles:[]};
detail.detail_digest = "sha256:" + crypto.createHash("sha256").update(c(detail)).digest("hex"); detail.signature = crypto.sign(null, Buffer.from(c(detail)), privateKey).toString("base64"); fs.writeFileSync(detailFile, JSON.stringify(detail));
NODE
OVERLAY="$TMP/overlay.json"; KEY_JSON="$(node -pe 'JSON.stringify(require("fs").readFileSync(process.argv[1],"utf8"))' "$PUB")"
write_overlay() { printf '%s\n' "$1" >"$OVERLAY"; chmod 600 "$OVERLAY"; }
LOCATION_A=locv1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
LOCATION_B=locv1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
overlay_interval() { printf '{"schema_version":1,"nodes":{"fixture-nas":{"ssh_target":"fixture-agent","remote_dir":"/opt/brokkr","signing_public_key":%s,"location":{"location_secret":"%s","observed_at":"%s","valid_until":"%s","provenance":"%s"}}}}' "$KEY_JSON" "$1" "$2" "$3" "$4"; }
overlay() { overlay_interval "$1" 2026-07-23T10:00:00Z 2026-07-23T11:00:00Z "$2"; }
NODE_BIN="$(command -v node)"
MOCK="$TMP/mock"; mkdir "$MOCK"
make_ssh() { printf '%s\n' "$1" >"$MOCK/ssh"; chmod +x "$MOCK/ssh"; }
run() { env -i PATH="$MOCK:/usr/bin:/bin" BROKKR_INSPECT_OVERLAY="$OVERLAY" BROKKR_INSPECT_NOW="$1" "$NODE_BIN" "$INSPECT" inspect fixture-nas; }
assert() { node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); if (!Function("r", "return (" + process.argv[1] + ")")(r)) process.exit(1)' "$1"; }
write_overlay "$(overlay "$LOCATION_A" known)"
make_ssh "#!/bin/sh
printf '%s\\n' \"\$*\" >'$TMP/ssh-args'
cat '$RECORD'
printf 'Brokkr node inventory detail JSON: ' >&2; cat '$DETAIL' >&2; printf '\\n' >&2"
OUT="$(run 2026-07-23T10:30:00Z)" || fail "success inspect failed"
printf '%s' "$OUT" | assert 'r.inspection_status === "ok" && r.node_capability.node_id === "fixture-nas" && r.detail.kind === "brokkr-node-inventory-detail" && r.location_evidence.location_digest.startsWith("sha256:")'
printf '%s' "$OUT" | grep -q 'fixture-agent\|locv1_A\|/opt/brokkr' && fail "private overlay leaked into output"
grep -q 'BROKKR_NODE_ID=fixture-nas node scripts/node-inventory.mjs --detail' "$TMP/ssh-args" || fail "transport did not fix remote command"
make_ssh '#!/bin/sh
exit 255'
if OUT="$(run 2026-07-23T10:30:00Z)"; then fail "unreachable inspect succeeded"; fi
printf '%s' "$OUT" | assert 'r.inspection_status === "unreachable" && !Object.hasOwn(r, "node_capability")'
make_ssh "#!/bin/sh
cat '$RECORD'
printf 'Brokkr node inventory detail JSON: ' >&2; cat '$DETAIL' >&2; printf '\\n' >&2"
OUT="$(run 2026-07-23T12:00:00Z)" || fail "stale inspection should remain inspectable"
printf '%s' "$OUT" | assert 'r.inspection_status === "partial" && r.freshness === "stale"'
# Mixed freshness: current location evidence cannot make an expired capability
# look OK. The aggregate is stale and therefore partial.
write_overlay "$(overlay_interval "$LOCATION_A" 2026-07-23T11:30:00Z 2026-07-23T13:00:00Z known)"
OUT="$(run 2026-07-23T12:00:00Z)" || fail "mixed-freshness inspection should remain inspectable"
printf '%s' "$OUT" | assert 'r.inspection_status === "partial" && r.freshness === "stale" && r.location_evidence.valid_until === "2026-07-23T13:00:00Z" && r.node_capability.valid_until === "2026-07-23T11:00:00Z"'
# Location intervals are real observation intervals. Future observations,
# reversed intervals and low-entropy placeholder tokens fail before transport.
expect_overlay_fail() {
  write_overlay "$1"; local out
  if out="$(run 2026-07-23T10:30:00Z 2>"$TMP/invalid.err")"; then fail "$2 accepted"; fi
  [ -z "$out" ] || fail "$2 emitted output"
  grep -q 'invalid node configuration' "$TMP/invalid.err" || fail "$2 lacked closed diagnostic"
}
expect_overlay_fail "$(overlay_interval "$LOCATION_A" 2026-07-23T11:00:00Z 2026-07-23T12:00:00Z known)" "future location observation"
expect_overlay_fail "$(overlay_interval "$LOCATION_A" 2026-07-23T10:00:00Z 2026-07-23T10:00:00Z known)" "zero location interval"
expect_overlay_fail "$(overlay_interval REPLACE_WITH_OWNER_TOKEN 2026-07-23T10:00:00Z 2026-07-23T11:00:00Z known)" "placeholder location token"
write_overlay "$(overlay "$LOCATION_A" known)"
# A schema-shaped payload whose evidence digest no longer covers its contents
# is rejected rather than being silently accepted as signed-detail input.
TAMPERED_RECORD="$TMP/tampered-record.json"
node - "$RECORD" "$TAMPERED_RECORD" <<'NODE'
const fs=require("fs"); const r=JSON.parse(fs.readFileSync(process.argv[2])); r.resources.cpu_cores=99; fs.writeFileSync(process.argv[3],JSON.stringify(r));
NODE
make_ssh "#!/bin/sh
cat '$TAMPERED_RECORD'
printf 'Brokkr node inventory detail JSON: ' >&2; cat '$DETAIL' >&2; printf '\\n' >&2"
if OUT="$(run 2026-07-23T10:30:00Z)"; then fail "tampered shared evidence succeeded"; fi
printf '%s' "$OUT" | assert 'r.inspection_status === "partial" && r.reason === "invalid-shared-contract"'
BAD_RECORD="$TMP/bad-record.json"
node - "$RECORD" "$BAD_RECORD" <<'NODE'
const fs=require("fs"); const r=JSON.parse(fs.readFileSync(process.argv[2])); r.node_id="other-node"; fs.writeFileSync(process.argv[3],JSON.stringify(r));
NODE
make_ssh "#!/bin/sh
cat '$BAD_RECORD'
printf 'Brokkr node inventory detail JSON: ' >&2; cat '$DETAIL' >&2; printf '\\n' >&2"
if OUT="$(run 2026-07-23T10:30:00Z)"; then fail "identity mismatch succeeded"; fi
printf '%s' "$OUT" | assert 'r.inspection_status === "identity-mismatch" && !Object.hasOwn(r, "node_capability")'
write_overlay "$(overlay "$LOCATION_B" partial)"
make_ssh "#!/bin/sh
cat '$RECORD'
printf 'Brokkr node inventory detail JSON: ' >&2; cat '$DETAIL' >&2; printf '\\n' >&2"
OUT="$(run 2026-07-23T10:30:00Z)" || fail "relocation inspection should remain inspectable"
printf '%s' "$OUT" | assert 'r.inspection_status === "partial" && r.node_id === "fixture-nas" && r.node_capability.node_id === "fixture-nas" && r.location_evidence.provenance === "partial"'
echo "controller-inspect.test.sh: PASS"
