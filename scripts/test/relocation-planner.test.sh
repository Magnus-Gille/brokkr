#!/usr/bin/env bash
# Hermetic acceptance tests for the read-only relocation planner (brokkr#9).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLANNER="$ROOT/scripts/relocation-planner.mjs"
SCHEMA="$ROOT/docs/node-substrate-contract-v1.schema.json"
LIB="$ROOT/scripts/lib/node-substrate-contract.mjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "relocation-planner.test.sh: FAIL: $1" >&2; exit 1; }

# Build signed, public-safe fixtures for a genuine Hugin -> clean M5 target.
node - "$ROOT" "$TMP" <<'NODE'
const fs = require("fs"), crypto = require("crypto");
const [root, tmp] = process.argv.slice(2);
const canonical = (v) => Array.isArray(v) ? `[${v.map(canonical).join(",")}]` : v && typeof v === "object" ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}` : JSON.stringify(v);
const digest = (v) => `sha256:${crypto.createHash("sha256").update(canonical(v)).digest("hex")}`;
const rawDigest = (v) => `sha256:${crypto.createHash("sha256").update(v).digest("hex")}`;
const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
fs.writeFileSync(`${tmp}/detail-private.pem`, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
fs.writeFileSync(`${tmp}/detail-public.pem`, publicKey.export({ type: "spki", format: "pem" }));
const keyId = rawDigest(publicKey.export({ type: "spki", format: "der" }));
const signDetail = (value) => {
  const detail = structuredClone(value);
  delete detail.detail_digest; delete detail.signature;
  detail.detail_digest = digest(detail);
  detail.signature = crypto.sign(null, Buffer.from(canonical(detail).replace(`,"signature":undefined`, "")), privateKey).toString("base64");
  return detail;
};
const bind = (value) => { const out = structuredClone(value); delete out.digest; out.digest = digest(out); return out; };
const inventory = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-inventory/fixture-m5.json`));
inventory.extensions = inventory.extensions.filter(e => !e.id.startsWith("workload-"));
inventory.extensions.push({ id: "workload-existing", version: "v1", decision_effect: "informational" });
delete inventory.evidence.digest; inventory.evidence.digest = digest(inventory);
const records = JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-substrate-contract/positive.json`)).records;
const workload = records.find(r => r.kind === "workload-requirement");
const intent = records.find(r => r.kind === "placement-intent");
const profile = JSON.parse(fs.readFileSync(`${root}/profiles/location-network-storage.example.json`));
profile.locations["house-2"].backup_roles = [{ logical_storage_id: "backup-primary", producer: "fixture-hugin", consumer: "fixture-backup", bytes: 1000, window_minutes: 30 }];
const profileBytes = JSON.stringify(profile);
const detail = signDetail({
  kind: "brokkr-node-inventory-detail", schema_version: "v1",
  observation_evidence_id: inventory.evidence.evidence_id, observation_digest: inventory.evidence.digest,
  observed_at: inventory.observed_at, valid_until: inventory.valid_until, signing_key_id: keyId,
  unit_state: { status: "known", units: [{ name: "existing.service", installed_state: "loaded", active_state: "running", sub_state: "exited" }] },
  workloads: ["existing"], backup_roles: []
});
const evidence = bind({
  kind: "brokkr-location-preflight-evidence", schema_version: "v1", location: "house-2", node_id: inventory.node_id,
  observation_evidence_id: inventory.evidence.evidence_id, observed_at: inventory.observed_at, valid_until: inventory.valid_until,
  profile_digest: rawDigest(Buffer.from(profileBytes)), outcome: "verified", network_capabilities: ["wired", "wifi", "tailnet"],
  storage: [{ logical_storage_id: "backup-primary", class: "local_ssd", status: "known", writable: true, capacity: "sufficient", transfer_window: "sufficient" }],
  backup_roles: [
    { role: "producer", actor: "fixture-hugin", logical_storage_id: "backup-primary", status: "verified" },
    { role: "consumer", actor: "fixture-backup", logical_storage_id: "backup-primary", status: "verified" }
  ]
});
const requirements = bind({
  kind: "brokkr-relocation-requirements", schema_version: "v1",
  workloads: [
    { workload_id: "existing", owner_repo: "existing", min_cpu_cores: 2, min_memory_mib: 2048, units: ["existing.service"], timers: [], dependencies: [], required_backup_roles: [], cohost_forbidden: [] },
    { workload_id: "fixture-hugin", owner_repo: "hugin", min_cpu_cores: 4, min_memory_mib: 4096, units: ["hugin.service"], timers: [], dependencies: ["fixture-munin"], required_backup_roles: [
      { role: "producer", actor: "fixture-hugin", logical_storage_id: "backup-primary" },
      { role: "consumer", actor: "fixture-backup", logical_storage_id: "backup-primary" }
    ], cohost_forbidden: [] }
  ],
  dependency_evidence: [bind({ workload_id: "fixture-munin", owner_repo: "munin-memory", status: "available", observed_at: inventory.observed_at, valid_until: inventory.valid_until, evidence_id: "dep-munin-001" })]
});
for (const [name, value] of Object.entries({ inventory, workload, intent, detail, evidence, requirements })) fs.writeFileSync(`${tmp}/${name}.json`, JSON.stringify(value));
fs.writeFileSync(`${tmp}/profile.json`, profileBytes);
NODE

run_plan() {
  local requirements="$TMP/requirements.json" detail="$TMP/detail.json" profile="$TMP/profile.json" inventory="$TMP/inventory.json"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --requirements) requirements="$2" ;;
      --detail) detail="$2" ;;
      --location-profile) profile="$2" ;;
      --inventory) inventory="$2" ;;
      *) fail "unsupported test override $1" ;;
    esac
    shift 2
  done
  node "$PLANNER" --json --now 2026-07-23T10:05:00Z \
    --intent "$TMP/intent.json" --workload "$TMP/workload.json" --requirements "$requirements" \
    --inventory "$inventory" --detail "$detail" --detail-public-key "$TMP/detail-public.pem" \
    --location-profile "$profile" --location-evidence "$TMP/evidence.json"
}
assert_blocked() {
  local file="$1" code="$2" owner="$3"
  node - "$file" "$code" "$owner" "$SCHEMA" "$LIB" <<'NODE'
import fs from "node:fs"; const [file, code, owner, schemaFile, libFile] = process.argv.slice(2); const v = JSON.parse(fs.readFileSync(file));
const { schemaErrors } = await import(libFile); const schema = JSON.parse(fs.readFileSync(schemaFile));
if (v.kind !== "brokkr-relocation-plan" || v.schema_version !== "v1" || v.outcome !== "blocked") throw new Error("failure is not a versioned blocked plan");
if (v.lifecycle_result?.kind !== "lifecycle-result" || v.lifecycle_result.outcome !== "blocked") throw new Error("failure lacks blocked lifecycle result");
if (schemaErrors(schema, v.lifecycle_result).length) throw new Error("failure lifecycle violates pinned schema");
if (!v.blockers.some(b => b.code === code && b.owner_repo === owner)) throw new Error(`missing ${owner}/${code}`);
NODE
}
mutate_json() {
  local source="$1" target="$2" expression="$3"
  node - "$source" "$target" "$expression" <<'NODE'
const fs = require("fs"); const [source, target, expression] = process.argv.slice(2); const v = JSON.parse(fs.readFileSync(source)); Function("v", expression)(v); fs.writeFileSync(target, JSON.stringify(v));
NODE
}

# Red gate: all new evidence/resource semantics must exist before this passes.
if run_plan >"$TMP/plan.json" 2>"$TMP/plan.err"; then :; else
  cat "$TMP/plan.json" >&2
  fail "golden clean-target plan is blocked"
fi

node - "$TMP/plan.json" <<'NODE'
const v = JSON.parse(require("fs").readFileSync(process.argv[2]));
if (v.outcome !== "promoted" || v.workloads.length !== 2) throw new Error("clean-target move was not promoted or cohosts omitted");
if (!v.workloads.some(w => w.workload_id === "fixture-hugin" && w.placement === "planned")) throw new Error("requested workload was required to be pre-hosted");
if (!v.workloads.some(w => w.workload_id === "existing" && w.placement === "current")) throw new Error("current cohost omitted");
if (v.resources.required_cpu_cores !== 6 || v.resources.required_memory_mib !== 6144) throw new Error("resource minima not totaled");
if (v.dependencies[0].status !== "available") throw new Error("dependency evidence omitted");
NODE

# Fresh signed detail is mandatory; unhealthy or unsupported states fail closed.
mutate_json "$TMP/detail.json" "$TMP/stale-detail.json" 'v.valid_until="2026-07-23T10:00:00Z"'
if run_plan --detail "$TMP/stale-detail.json" >"$TMP/stale-detail.out"; then fail "tampered detail passed"; fi
assert_blocked "$TMP/stale-detail.out" "detail-signature-invalid" "brokkr"

# Re-sign selected semantic adversarial cases with the fixture key.
resign_detail() {
  local source="$1" target="$2" expression="$3"
  node - "$source" "$target" "$expression" "$TMP/detail-private.pem" <<'NODE'
const fs = require("fs"), crypto = require("crypto"); const [source,target,expression,keyFile]=process.argv.slice(2); const v=JSON.parse(fs.readFileSync(source)); Function("v",expression)(v);
const c=x=>Array.isArray(x)?`[${x.map(c).join(",")}]`:x&&typeof x==="object"?`{${Object.keys(x).sort().map(k=>`${JSON.stringify(k)}:${c(x[k])}`).join(",")}}`:JSON.stringify(x);
delete v.detail_digest; delete v.signature; v.detail_digest=`sha256:${crypto.createHash("sha256").update(c(v)).digest("hex")}`; v.signature=crypto.sign(null,Buffer.from(c(v)),crypto.createPrivateKey(fs.readFileSync(keyFile))).toString("base64"); fs.writeFileSync(target,JSON.stringify(v));
NODE
}
resign_detail "$TMP/detail.json" "$TMP/expired-detail.json" 'v.valid_until="2026-07-23T10:00:00Z"'
if run_plan --detail "$TMP/expired-detail.json" >"$TMP/expired-detail.out"; then fail "stale signed detail passed"; fi
assert_blocked "$TMP/expired-detail.out" "stale-detail-evidence" "brokkr"
resign_detail "$TMP/detail.json" "$TMP/bad-unit.json" 'v.unit_state.units[0].active_state="failed"'
if run_plan --detail "$TMP/bad-unit.json" >"$TMP/bad-unit.out"; then fail "failed unit passed"; fi
assert_blocked "$TMP/bad-unit.out" "unit-not-healthy" "existing"
resign_detail "$TMP/detail.json" "$TMP/unknown-unit.json" 'v.unit_state.units[0].active_state="wonderful"'
if run_plan --detail "$TMP/unknown-unit.json" >"$TMP/unknown-unit.out"; then fail "unsupported unit state passed"; fi
assert_blocked "$TMP/unknown-unit.out" "detail-unit-state-invalid" "brokkr"

# Resource, dependency, backup, and cohost semantics each block independently.
for case_name in cpu memory dependency dependency-down backup cohost; do
  case "$case_name" in
    cpu) expression='v.workloads[1].min_cpu_cores=20' code='cpu-capacity-insufficient' owner='hugin' ;;
    memory) expression='v.workloads[1].min_memory_mib=20000' code='memory-capacity-insufficient' owner='hugin' ;;
    dependency) expression='v.dependency_evidence=[]' code='dependency-evidence-missing' owner='hugin' ;;
    dependency-down) expression='v.dependency_evidence[0].status="unavailable"; delete v.dependency_evidence[0].digest; const c=x=>Array.isArray(x)?`[${x.map(c).join(",")}]`:x&&typeof x==="object"?`{${Object.keys(x).sort().map(k=>`${JSON.stringify(k)}:${c(x[k])}`).join(",")}}`:JSON.stringify(x); v.dependency_evidence[0].digest=`sha256:${require("crypto").createHash("sha256").update(c(v.dependency_evidence[0])).digest("hex")}`' code='dependency-unavailable' owner='munin-memory' ;;
    backup) expression='v.workloads[1].required_backup_roles=v.workloads[1].required_backup_roles.slice(0,1)' code='backup-role-requirement-incomplete' owner='hugin' ;;
    cohost) expression='v.workloads[1].cohost_forbidden=["existing"]' code='cohost-forbidden' owner='hugin' ;;
  esac
  node - "$TMP/requirements.json" "$TMP/$case_name.json" "$expression" <<'NODE'
const fs=require("fs"),crypto=require("crypto");const [source,target,expression]=process.argv.slice(2);const v=JSON.parse(fs.readFileSync(source));Function("v",expression)(v);const c=x=>Array.isArray(x)?`[${x.map(c).join(",")}]`:x&&typeof x==="object"?`{${Object.keys(x).sort().map(k=>`${JSON.stringify(k)}:${c(x[k])}`).join(",")}}`:JSON.stringify(x);delete v.digest;v.digest=`sha256:${crypto.createHash("sha256").update(c(v)).digest("hex")}`;fs.writeFileSync(target,JSON.stringify(v));
NODE
  if run_plan --requirements "$TMP/$case_name.json" >"$TMP/$case_name.out"; then fail "$case_name gap passed"; fi
  assert_blocked "$TMP/$case_name.out" "$code" "$owner"
done

# Even unreadable/malformed inputs produce machine-readable lifecycle failures.
if run_plan --location-profile "$TMP/missing.json" >"$TMP/missing.out"; then fail "missing profile passed"; fi
assert_blocked "$TMP/missing.out" "location-profile-unavailable" "brokkr"
printf '{bad' >"$TMP/malformed.json"
if run_plan --location-profile "$TMP/malformed.json" >"$TMP/malformed.out"; then fail "malformed profile passed"; fi
assert_blocked "$TMP/malformed.out" "location-profile-invalid" "brokkr"

# Real NAS -> house-2 keeps the profile's Wi-Fi requirement. Golden evidence
# passes; removing Wi-Fi from fresh signed evidence blocks.
node - "$ROOT" "$TMP" <<'NODE'
const fs=require("fs"),crypto=require("crypto");const [root,tmp]=process.argv.slice(2);
const c=x=>Array.isArray(x)?`[${x.map(c).join(",")}]`:x&&typeof x==="object"?`{${Object.keys(x).sort().map(k=>`${JSON.stringify(k)}:${c(x[k])}`).join(",")}}`:JSON.stringify(x);
const d=x=>`sha256:${crypto.createHash("sha256").update(c(x)).digest("hex")}`, raw=x=>`sha256:${crypto.createHash("sha256").update(x).digest("hex")}`;
const privateKey=crypto.createPrivateKey(fs.readFileSync(`${tmp}/detail-private.pem`)),publicKey=crypto.createPublicKey(privateKey),keyId=raw(publicKey.export({type:"spki",format:"der"}));
const bind=v=>{const o=structuredClone(v);delete o.digest;o.digest=d(o);return o};
const sign=(v,inv)=>{const o={...structuredClone(v),observation_evidence_id:inv.evidence.evidence_id,observation_digest:inv.evidence.digest,observed_at:inv.observed_at,valid_until:inv.valid_until,signing_key_id:keyId};delete o.detail_digest;delete o.signature;o.detail_digest=d(o);o.signature=crypto.sign(null,Buffer.from(c(o)),privateKey).toString("base64");return o};
const inventory=JSON.parse(fs.readFileSync(`${root}/tests/fixtures/node-inventory/fixture-nas.json`));if(!inventory.network_capabilities.includes("wifi"))inventory.network_capabilities.splice(1,0,"wifi");delete inventory.evidence.digest;inventory.evidence.digest=d(inventory);
const noWifi=structuredClone(inventory);noWifi.network_capabilities=noWifi.network_capabilities.filter(x=>x!=="wifi");delete noWifi.evidence.digest;noWifi.evidence.digest=d(noWifi);
const profile=JSON.parse(fs.readFileSync(`${root}/profiles/location-network-storage.example.json`));profile.locations["house-2"].backup_roles=[{logical_storage_id:"backup-primary",producer:"mimir",consumer:"fixture-backup",bytes:1000,window_minutes:30}];const profileBytes=JSON.stringify(profile);
const workload={kind:"workload-requirement",schema_version:"v1",workload_id:"mimir",supported_architectures:["arm64"],persistent_data:"required",ports:[8080],units:["mimir.service"],timers:["backup-offsite.timer"],secrets_boundary:"owner_overlay",dependencies:[],backup_restore:"required",health:"external_probe",hooks:[{name:"preflight",mode:"read_only",contract_versions:["v1"],deadline_seconds:60,idempotency_required:true},{name:"drain",mode:"mutating",contract_versions:["v1"],deadline_seconds:60,idempotency_required:true,compensation_hook:"rollback"},{name:"verify",mode:"read_only",contract_versions:["v1"],deadline_seconds:60,idempotency_required:true},{name:"rollback",mode:"mutating",contract_versions:["v1"],deadline_seconds:60,idempotency_required:true}],extensions:[]};
const intent={kind:"placement-intent",schema_version:"v1",placement_id:"place-mimir-nas",workload_id:"mimir",target_node_id:inventory.node_id,desired_revision:`sha256:${"c".repeat(64)}`,created_at:"2026-07-23T10:01:00Z",planned_drift:["placement","network"],extensions:[]};
const requirements=bind({kind:"brokkr-relocation-requirements",schema_version:"v1",workloads:[{workload_id:"mimir",owner_repo:"mimir",min_cpu_cores:2,min_memory_mib:2048,units:["mimir.service"],timers:["backup-offsite.timer"],dependencies:[],required_backup_roles:[{role:"producer",actor:"mimir",logical_storage_id:"backup-primary"},{role:"consumer",actor:"fixture-backup",logical_storage_id:"backup-primary"}],cohost_forbidden:[]}],dependency_evidence:[]});
const detailBase={kind:"brokkr-node-inventory-detail",schema_version:"v1",unit_state:{status:"known",units:[{name:"mimir.service",installed_state:"enabled",active_state:"active",sub_state:"running"},{name:"backup-offsite.timer",installed_state:"enabled",active_state:"active",sub_state:"waiting"}]},workloads:["mimir"],backup_roles:["producer","consumer"]};
const locationBase={kind:"brokkr-location-preflight-evidence",schema_version:"v1",location:"house-2",observed_at:inventory.observed_at,valid_until:inventory.valid_until,profile_digest:raw(Buffer.from(profileBytes)),outcome:"verified",network_capabilities:["wired","wifi","tailnet"],storage:[{logical_storage_id:"backup-primary",class:"external_ssd",status:"known",writable:true,capacity:"sufficient",transfer_window:"sufficient"}],backup_roles:[{role:"producer",actor:"mimir",logical_storage_id:"backup-primary",status:"verified"},{role:"consumer",actor:"fixture-backup",logical_storage_id:"backup-primary",status:"verified"}]};
const location=(inv,net)=>bind({...structuredClone(locationBase),node_id:inv.node_id,observation_evidence_id:inv.evidence.evidence_id,network_capabilities:net});
for(const [name,value] of Object.entries({inventory,workload,intent,requirements,"detail":sign(detailBase,inventory),"evidence":location(inventory,["wired","wifi","tailnet"]),"no-wifi-inventory":noWifi,"no-wifi-detail":sign(detailBase,noWifi),"no-wifi-evidence":location(noWifi,["wired","tailnet"])}))fs.writeFileSync(`${tmp}/nas-${name}.json`,JSON.stringify(value));fs.writeFileSync(`${tmp}/nas-profile.json`,profileBytes);
NODE
nas_args=(--json --now 2026-07-23T10:05:00Z --intent "$TMP/nas-intent.json" --workload "$TMP/nas-workload.json" --requirements "$TMP/nas-requirements.json" --detail-public-key "$TMP/detail-public.pem" --location-profile "$TMP/nas-profile.json")
node "$PLANNER" "${nas_args[@]}" --inventory "$TMP/nas-inventory.json" --detail "$TMP/nas-detail.json" --location-evidence "$TMP/nas-evidence.json" >"$TMP/nas-plan.out"
node - "$TMP/nas-plan.out" <<'NODE'
const v=JSON.parse(require("fs").readFileSync(process.argv[2]));if(v.outcome!=="promoted"||!v.network_tunnel_dependencies.includes("wifi"))throw new Error("NAS -> house-2 Wi-Fi golden failed");
NODE
if node "$PLANNER" "${nas_args[@]}" --inventory "$TMP/nas-no-wifi-inventory.json" --detail "$TMP/nas-no-wifi-detail.json" --location-evidence "$TMP/nas-no-wifi-evidence.json" >"$TMP/nas-no-wifi.out"; then fail "NAS missing Wi-Fi passed"; fi
assert_blocked "$TMP/nas-no-wifi.out" "network-wifi-missing" "brokkr"

echo "relocation-planner.test.sh: PASS"
