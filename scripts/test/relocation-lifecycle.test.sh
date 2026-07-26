#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; EXEC="$ROOT/scripts/relocation-lifecycle.mjs"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "relocation-lifecycle.test.sh: FAIL: $1" >&2; exit 1; }
hook(){ local name="$1"; cat >"$TMP/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${HOOK_MODE:-ok}" in
  lost-network) [ "$name" = apply ] && exit 7 ;;
  failed-hook) [ "$name" = verify ] && exit 7 ;;
  interrupt) [ "$name" = drain ] && exit 75 ;;
esac
echo "$name-ok"
EOF
chmod 700 "$TMP/$name"; }
for name in preflight drain apply verify representative_data rollback; do hook "$name"; done
node - "$ROOT" "$TMP" <<'NODE'
const fs=require('fs'),crypto=require('crypto');const [root,tmp]=process.argv.slice(2);const c=x=>Array.isArray(x)?`[${x.map(c).join(',')}]`:x&&typeof x==='object'?`{${Object.keys(x).sort().map(k=>`${JSON.stringify(k)}:${c(x[k])}`).join(',')}}`:JSON.stringify(x); const d=x=>`sha256:${crypto.createHash('sha256').update(c(x)).digest('hex')}`;
const life={kind:'lifecycle-result',schema_version:'v1',result_id:'result-001',attempt_id:'attempt-001',plan_id:'plan-001',plan_digest:`sha256:${'a'.repeat(64)}`,desired_revision:`sha256:${'b'.repeat(64)}`,observation_evidence_id:'obs-001',action:'preflight',deadline:'2026-07-26T11:00:00Z',idempotency_key:'idem-001',phase:'preflight',outcome:'promoted',drift:'planned',hook_results:[],substrate:{outcome:'not_started',rollback:'not_applicable',pre_state_evidence_id:'obs-001'},created_at:'2026-07-26T10:00:00Z',extensions:[]};
const plan={kind:'brokkr-relocation-plan',schema_version:'v1',plan_id:'plan-001',plan_digest:life.plan_digest,outcome:'promoted',lifecycle_result:life,rollback:{available:true,hook:'rollback'},hooks:[{name:'preflight'},{name:'drain'},{name:'verify'}]};
const hooks=['preflight','drain','apply','verify','representative_data','rollback'].map(name=>({name,command:[`${tmp}/${name}`],timeout_seconds:2,required_output:`${name}-ok`,attribution:{owner_repo:'hugin',actor:'fixture-hugin'}}));
const operation={kind:'brokkr-relocation-operation',schema_version:'v1',id:'operation-001',reversal_recipe:'run the allowlisted rollback hook; old placement remains retained until promotion',physical_move_required:false,irreversible:{allowed:false},monitoring:{contract:'heimdall-monitoring-agent-capability/v1',required_capabilities:['lifecycle-result','node-capability-freshness']},platform_fault_refs:['fault-fixture-nas-1'],hooks}; fs.writeFileSync(`${tmp}/plan.json`,JSON.stringify(plan));fs.writeFileSync(`${tmp}/op.json`,JSON.stringify(operation));
NODE
run(){ node "$EXEC" --plan "$TMP/plan.json" --operation "$TMP/op.json" --journal "$TMP/$1.json" --now 2026-07-26T10:30:00Z "${@:2}"; }
run success >"$TMP/success.out" || fail success
node - "$TMP/success.json" <<'NODE'
const j=require(process.argv[2]);if(j.outcome!=='promoted'||j.old_placement_retained||!j.events.some(x=>x.phase==='representative_data'&&x.outcome==='succeeded')||!j.events.every(x=>x.platform_fault_refs[0]==='fault-fixture-nas-1'&&x.capability_contract?.required?.includes('lifecycle-result')))process.exit(1)
NODE
node - "$TMP/plan.json" "$TMP/stale-plan.json" <<'NODE'
const fs=require('fs');const [a,b]=process.argv.slice(2);const x=require(a);x.lifecycle_result.deadline='2026-07-26T10:29:59Z';fs.writeFileSync(b,JSON.stringify(x));
NODE
if node "$EXEC" --plan "$TMP/stale-plan.json" --operation "$TMP/op.json" --journal "$TMP/stale.json" --now 2026-07-26T10:30:00Z >"$TMP/stale.out" 2>&1; then fail 'stale plan passed'; fi
[[ ! -e "$TMP/stale.json" ]] || fail 'stale plan created a mutation journal'
if HOOK_MODE=lost-network run network >"$TMP/network.out" 2>&1; then fail 'lost network passed'; fi
node - "$TMP/network.json" <<'NODE'
const j=require(process.argv[2]);if(j.phase!=='rollback'||j.outcome!=='blocked'||!j.old_placement_retained||!j.events.some(x=>x.phase==='rollback'&&x.outcome==='succeeded'))process.exit(1)
NODE
if HOOK_MODE=failed-hook run failed >"$TMP/failed.out" 2>&1; then fail 'failed hook passed'; fi
node - "$TMP/failed.json" <<'NODE'
const j=require(process.argv[2]);if(j.phase!=='rollback'||!j.events.some(x=>x.phase==='verify'&&x.outcome==='failed'))process.exit(1)
NODE
if HOOK_MODE=interrupt run resume >"$TMP/interrupted.out" 2>&1; then fail 'interruption passed'; fi
run resume --resume >"$TMP/resumed.out" || fail 'resume did not continue idempotently'
node - "$TMP/resume.json" <<'NODE'
const j=require(process.argv[2]);if(j.outcome!=='promoted'||j.events.filter(x=>x.phase==='preflight'&&x.outcome==='started').length!==1)process.exit(1)
NODE
node - "$TMP/op.json" "$TMP/physical.json" <<'NODE'
const fs=require('fs');const [a,b]=process.argv.slice(2);const x=require(a);x.physical_move_required=true;fs.writeFileSync(b,JSON.stringify(x));
NODE
if node "$EXEC" --plan "$TMP/plan.json" --operation "$TMP/physical.json" --journal "$TMP/physical-journal.json" --now 2026-07-26T10:30:00Z >"$TMP/physical.out" 2>&1; then fail 'physical move did not wait'; fi
node "$EXEC" --plan "$TMP/plan.json" --operation "$TMP/physical.json" --journal "$TMP/physical-journal.json" --now 2026-07-26T10:31:00Z --resume --operator-confirm physical-move >"$TMP/physical-resume.out" || fail physical-resume
echo 'relocation-lifecycle.test.sh: PASS'
