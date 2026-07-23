#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$HERE/../node-inventory.mjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/mock"; mkdir -p "$MOCK"
mock() { printf '%b\n' "$2" >"$MOCK/$1"; chmod +x "$MOCK/$1"; }
mock getconf '#!/bin/sh\necho 10'
mock awk '#!/bin/sh\necho 16384'
mock uname '#!/bin/sh\necho aarch64'
mock df '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 100 20 80 20%% /\\n"'
mock systemctl '#!/bin/sh\nif [ "$1" = --version ]; then echo systemd; else printf "mimir.service loaded active running\\ntunnel.service loaded active running\\nagent.service loaded active running\\nbackup.service loaded active running\\n"; fi'
mock ip '#!/bin/sh\necho "2: eth0: <BROADCAST>"'
mock tailscale '#!/bin/sh\necho "{}"'
PATH="$MOCK:$PATH" BROKKR_NODE_ID=fixture-nas BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z node "$INVENTORY" >"$TMP/record.json" 2>"$TMP/human"
node - "$TMP/record.json" <<'NODE'
const fs = require('fs'); const r = JSON.parse(fs.readFileSync(process.argv[2]));
const required = ['kind','schema_version','node_id','observed_at','valid_until','evidence','capability_status','architecture','resources','uptime_class','network_capabilities','logical_storage','service_manager','deployment_mechanisms','health_reporting','extensions'];
if (JSON.stringify(Object.keys(r).sort()) !== JSON.stringify(required.sort())) throw Error('not closed v1 record');
if (r.kind !== 'node-capability' || r.schema_version !== 'v1' || r.node_id !== 'fixture-nas' || r.capability_status !== 'known') throw Error('known fixture invalid');
if (!r.network_capabilities.includes('tailnet') || r.service_manager !== 'systemd' || r.resources.cpu_cores !== 10) throw Error('missing observations');
if (!/^sha256:[a-f0-9]{64}$/.test(r.evidence.digest)) throw Error('invalid evidence digest');
NODE
grep -q 'units=mimir.service,tunnel.service,agent.service,backup.service' "$TMP/human"
grep -q 'all probes collected' "$TMP/human"
mock getconf '#!/bin/sh\nexit 1'
PATH="$MOCK:$PATH" BROKKR_NODE_ID=fixture-m5 BROKKR_INVENTORY_NOW=2026-07-23T10:00:00Z node "$INVENTORY" >"$TMP/partial.json" 2>"$TMP/partial-human"
node - "$TMP/partial.json" <<'NODE'
const fs = require('fs'); const r = JSON.parse(fs.readFileSync(process.argv[2]));
if (r.capability_status !== 'unknown' || r.resources.cpu_cores !== 1) throw Error('failed probe did not fail closed');
NODE
grep -q 'partial probes=getconf' "$TMP/partial-human"
echo 'node-inventory.test.sh: PASS'
