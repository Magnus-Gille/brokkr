#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DETECTOR="$ROOT/scripts/platform-fault-detector.mjs"
NEGOTIATE="$ROOT/scripts/node-agent-compatibility.mjs"

pass=0; fail=0
check() { if eval "$2"; then printf 'ok - %s\n' "$1"; pass=$((pass+1)); else printf 'not ok - %s\n' "$1" >&2; fail=$((fail+1)); fi; }

node "$DETECTOR" --input "$ROOT/tests/fixtures/platform-faults/faulty-observation.json" >"$TMP/faults.json"
check "detector emits typed, severe, fresh faults linked to node/substrate evidence" \
  'node -e '\''const x=require(process.argv[1]); if (!Array.isArray(x.faults)||x.faults.length!==3)process.exit(1); for(const f of x.faults){if(f.kind!=="brokkr-platform-fault"||f.schema_version!=="v1"||!f.evidence.provenance||!f.freshness.valid_until||f.node_substrate_ref.contract!=="grimnir.node-substrate/v1"||!f.recovery_owner)process.exit(1)} if(!x.faults.some(f=>f.category==="filesystem-read-only"&&f.severity==="critical"))process.exit(1)'\'' "$TMP/faults.json"'

if node "$DETECTOR" --input "$ROOT/tests/fixtures/platform-faults/stale-observation.json" >"$TMP/stale.json" 2>&1; then rc=0; else rc=$?; fi
check "stale observation fails closed" '[ "$rc" -ne 0 ] && grep -q "stale" "$TMP/stale.json"'

node "$NEGOTIATE" --agent "$ROOT/tests/fixtures/platform-faults/agent-v1.json" --deployment "$ROOT/tests/fixtures/platform-faults/deployment-v1.json" >"$TMP/compatible.json"
check "node agent negotiates both contract versions explicitly" \
  'node -e '\''const x=require(process.argv[1]); if(x.outcome!=="compatible"||x.negotiated.platform_fault!=="v1"||x.negotiated.node_substrate!=="v1")process.exit(1)'\'' "$TMP/compatible.json"'
if node "$NEGOTIATE" --agent "$ROOT/tests/fixtures/platform-faults/agent-v1.json" --deployment "$ROOT/tests/fixtures/platform-faults/deployment-v2.json" >"$TMP/incompatible.json" 2>&1; then rc=0; else rc=$?; fi
check "unsupported deployment contract is rejected before install" '[ "$rc" -ne 0 ] && grep -q "incompatible" "$TMP/incompatible.json"'

printf '%s tests, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
