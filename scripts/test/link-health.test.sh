#!/usr/bin/env bash
# Hermetic tests for the wired-link health probe, its Heimdall report row,
# standalone snapshot runner, and platform-fault signals. ethtool, journalctl,
# and the Heimdall HTTP transport are mocked; no host NIC or journal is read.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FIX="$ROOT/tests/fixtures/link-health"
PROBE="$ROOT/network/check-link-health.py"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/nic"
cat > "$TMP/bin/ethtool" <<'EOF'
#!/usr/bin/env bash
[ "${MOCK_ETHTOOL_RC:-0}" = 0 ] || { echo "mock ethtool failure" >&2; exit "$MOCK_ETHTOOL_RC"; }
if [ "${1:-}" = -S ] && [ "$#" -eq 2 ]; then
  exec cat "$MOCK_NIC_DIR/$2.stats"
elif [ "$#" -eq 1 ]; then
  exec cat "$MOCK_NIC_DIR/$1.link"
fi
exit 64
EOF
cat > "$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_JOURNAL_ARGS"
case " $* " in
  *" -n 1 "*)
    # Readability proof: the newest kernel record of the current boot.
    [ "${MOCK_JOURNAL_PROOF_EMPTY:-0}" = 1 ] || echo "1792497000.000000 fixture-node kernel: proof"
    exit 0
    ;;
esac
[ -z "${MOCK_JOURNAL_STDERR:-}" ] || printf '%s\n' "$MOCK_JOURNAL_STDERR" >&2
[ "${MOCK_JOURNAL_RC:-0}" = 0 ] || exit "$MOCK_JOURNAL_RC"
exec cat "$MOCK_JOURNAL_FILE"
EOF
chmod +x "$TMP/bin/ethtool" "$TMP/bin/journalctl"
export PATH="$TMP/bin:$PATH"
export BROKKR_NOW_EPOCH=1792497600 BROKKR_STATE_DIR="$TMP/state"
export MOCK_NIC_DIR="$TMP/nic" MOCK_JOURNAL_ARGS="$TMP/journal-args"
export BROKKR_LINK_HEALTH_CONFIG="$TMP/link-health.conf"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; printf '        rc=%s out=%s\n' "${RC:-}" "${OUT:-}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

write_config() {
  printf '%s\n' "$@" > "$BROKKR_LINK_HEALTH_CONFIG"
  chmod 600 "$BROKKR_LINK_HEALTH_CONFIG"
}
# Select a scenario: NIC files are copied so a test can edit counters in place.
scenario() {
  rm -f "$TMP/nic/"*
  cp "$FIX/$1/enp1s0.link" "$FIX/$1/enp1s0.stats" "$TMP/nic/"
  export MOCK_JOURNAL_FILE="$FIX/$1/journal"
}
set_counters() {
  sed -i.bak -E "s/^( +tx_errors: ).*/\\1$1/; s/^( +rx_errors: ).*/\\1$2/" "$TMP/nic/enp1s0.stats"
}
fresh_state() { rm -rf "$TMP/state/link-health"; }
run_probe() {
  OUT="$(python3 "$PROBE" 2>&1)"
  RC=$?
}

echo "link-health.test.sh"

write_config 'LINK=enp1s0,2500,r8169-0-100:00'

# --- healthy -----------------------------------------------------------------
scenario healthy
fresh_state
run_probe
check "healthy 2.5G link with no events passes" '[[ "$RC" -eq 0 && "$OUT" == OK:* ]]'
check "first run records a counter baseline without claiming an error rate" '[[ "$OUT" == *"errors=baseline"* && -f "$TMP/state/link-health/enp1s0.json" ]]'
check "journal is queried for the kernel ring over 24 h" 'grep -q -- "-k" "$MOCK_JOURNAL_ARGS" && grep -q -- "--since @1792411200" "$MOCK_JOURNAL_ARGS"'
BROKKR_NOW_EPOCH=1792498500 run_probe
check "second healthy run reports a zero error delta over its interval" '[[ "$RC" -eq 0 && "$OUT" == *"errors=+0/900s"* ]]'

# --- the real incident, phase 1: flapping with PHY downshift -----------------
scenario incident-flapping
fresh_state
run_probe
check "incident flapping fixture fails" '[[ "$RC" -eq 2 && "$OUT" == FAIL:* ]]'
check "flapping counts only in-window drops (288/24 h, 12/1 h)" '[[ "$OUT" == *"drops1h=12"* && "$OUT" == *"drops24h=288"* ]]'
check "PHY downshift lines are attributed through the configured PHY name" '[[ "$OUT" == *"downshifts24h=288"* && "$OUT" == *"2.5Gbps->1Gbps"* ]]'
check "flapping also reports the speed below expected" '[[ "$OUT" == *"speed 1000Mb/s < 2500Mb/s"* ]]'

write_config 'LINK=enp1s0,2500'
run_probe
check "without a PHY name, PHY-labelled downshift lines are not misattributed" '[[ "$OUT" == *"downshifts24h=0"* && "$RC" -eq 2 ]]'

write_config 'LINK=enp1s0,1000,r8169-0-100:00' 'DROPS_1H_FAIL=100' 'DROPS_24H_FAIL=1000' 'DROPS_24H_WARN=1000'
run_probe
check "drop thresholds are configurable; a downshift alone still warns" '[[ "$RC" -eq 1 && "$OUT" == WARN:* && "$OUT" == *"downshift"* ]]'
write_config 'LINK=enp1s0,2500,r8169-0-100:00'

# --- the real incident, phase 2: stable but 25x slower ------------------------
scenario incident-stable-100
fresh_state
run_probe
check "stable 100 Mb/s link with no recent drops still alerts via the speed check" '[[ "$RC" -eq 1 && "$OUT" == WARN:* && "$OUT" == *"speed 100Mb/s < 2500Mb/s"* ]]'
check "stable-slow detail names the partner's 100 Mb/s ceiling" '[[ "$OUT" == *"partner-max=100Mb/s"* ]]'
check "the drop older than 24 h is not counted" '[[ "$OUT" == *"drops24h=0"* ]]'
write_config 'LINK=enp1s0,1000'
run_probe
check "a 1G expectation still flags the 100 Mb/s state" '[[ "$RC" -eq 1 && "$OUT" == *"speed 100Mb/s < 1000Mb/s"* ]]'
write_config 'LINK=enp1s0,100'
run_probe
check "meeting a lowered expectation passes" '[[ "$RC" -eq 0 && "$OUT" == OK:* ]]'
write_config 'LINK=enp1s0,2500,r8169-0-100:00'

# --- fail-closed: missing or unparsable evidence is never healthy -------------
scenario healthy
fresh_state
MOCK_JOURNAL_RC=1 run_probe
check "journalctl failure is unknown (warn), never OK" '[[ "$RC" -eq 1 && "$OUT" == WARN:* && "$OUT" == *"unknown"* && "$OUT" == *"drops1h=unknown"* ]]'
MOCK_JOURNAL_STDERR="Hint: You are currently not seeing messages from other users and the system." run_probe
check "a journal permission hint is unknown, not zero drops" '[[ "$RC" -eq 1 && "$OUT" == *"drops24h=unknown"* ]]'
MOCK_JOURNAL_PROOF_EMPTY=1 run_probe
check "an empty current-boot kernel journal is unknown" '[[ "$RC" -eq 1 && "$OUT" == *"drops24h=unknown"* ]]'
printf 'not-a-timestamp fixture-node kernel: garbage\n' > "$TMP/garbage.journal"
MOCK_JOURNAL_FILE="$TMP/garbage.journal" run_probe
check "an unparsable journal line is unknown" '[[ "$RC" -eq 1 && "$OUT" == *"drops24h=unknown"* ]]'
printf -- '-- Boot 0123456789abcdef --\n1792490000.000000 fixture-node kernel: line one\n    continuation of a multi-line record\n' > "$TMP/boot.journal"
MOCK_JOURNAL_FILE="$TMP/boot.journal" run_probe
check "boot separators and continuation lines are tolerated" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=0"* ]]'

MOCK_ETHTOOL_RC=75 run_probe
check "ethtool failure is unknown (warn), never OK" '[[ "$RC" -eq 1 && "$OUT" == *"speed=unknown"* && "$OUT" == *"errors=unknown"* ]]'
sed -i.bak 's/Speed: 2500Mb\/s/Speed: Unknown!/' "$TMP/nic/enp1s0.link"
run_probe
check "an unknown negotiated speed is unknown, not OK" '[[ "$RC" -eq 1 && "$OUT" == *"speed=unknown"* ]]'
scenario healthy
sed -i.bak 's/Link detected: yes/Link detected: no/' "$TMP/nic/enp1s0.link"
run_probe
check "a link that is down right now fails" '[[ "$RC" -eq 2 && "$OUT" == *"link down"* ]]'
scenario healthy
sed -i.bak '/tx_errors/d' "$TMP/nic/enp1s0.stats"
run_probe
check "a missing error counter is unknown, not zero" '[[ "$RC" -eq 1 && "$OUT" == *"errors=unknown"* ]]'

# --- error-counter deltas -------------------------------------------------------
scenario healthy
fresh_state
run_probe
set_counters 7 9
BROKKR_NOW_EPOCH=1792498500 run_probe
check "an error-counter increase at the threshold warns" '[[ "$RC" -eq 1 && "$OUT" == *"errors=+16/900s"* ]]'
set_counters 0 0
BROKKR_NOW_EPOCH=1792499400 run_probe
check "a counter reset (reboot/driver reload) rebaselines without alerting" '[[ "$RC" -eq 0 && "$OUT" == *"errors=baseline"* ]]'
set_counters 2 2
write_config 'LINK=enp1s0,2500,r8169-0-100:00' 'ERRORS_WARN=5'
BROKKR_NOW_EPOCH=1792500300 run_probe
check "an error delta below a configured threshold stays OK" '[[ "$RC" -eq 0 && "$OUT" == *"errors=+4/900s"* ]]'
write_config 'LINK=enp1s0,2500,r8169-0-100:00' 'ERRORS_WARN=4'
set_counters 4 4
BROKKR_NOW_EPOCH=1792501200 run_probe
check "an error delta at a configured threshold warns" '[[ "$RC" -eq 1 && "$OUT" == *"errors=+4/900s"* ]]'
write_config 'LINK=enp1s0,2500,r8169-0-100:00'
printf '{broken' > "$TMP/state/link-health/enp1s0.json"
BROKKR_NOW_EPOCH=1792499400 run_probe
check "an unreadable counter baseline rebaselines instead of crashing" '[[ "$RC" -eq 0 && "$OUT" == *"errors=baseline"* ]]'

# --- protected configuration ----------------------------------------------------
scenario healthy
config_rejected() { # name, then config lines
  local name="$1"; shift
  write_config "$@"
  run_probe
  check "$name" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
}
config_rejected "unknown config key is rejected" 'LINK=enp1s0,2500' 'SURPRISE=1'
config_rejected "a config without links is rejected" 'DROPS_1H_FAIL=3'
config_rejected "a traversal-shaped interface name is rejected" 'LINK=../enp1s0,2500'
config_rejected "a duplicate interface is rejected" 'LINK=enp1s0,2500' 'LINK=enp1s0,1000'
config_rejected "a non-numeric speed is rejected" 'LINK=enp1s0,fast'
config_rejected "a zero threshold is rejected" 'LINK=enp1s0,2500' 'DROPS_1H_FAIL=0'
config_rejected "a shell-looking value is never executed" 'LINK=enp1s0,2500' 'ERRORS_WARN=$(touch '"$TMP"'/pwned)'
check "config is parsed as data" '[[ ! -e "$TMP/pwned" ]]'
write_config 'LINK=enp1s0,2500'
chmod 640 "$BROKKR_LINK_HEALTH_CONFIG"
run_probe
check "a group-readable config is rejected" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
chmod 600 "$BROKKR_LINK_HEALTH_CONFIG"
ln -s "$BROKKR_LINK_HEALTH_CONFIG" "$TMP/link.conf"
BROKKR_LINK_HEALTH_CONFIG="$TMP/link.conf" run_probe
check "a symlinked config is rejected" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
BROKKR_LINK_HEALTH_CONFIG="$TMP/missing.conf" run_probe
check "a missing config fails" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
write_config '# wired uplink' '' 'LINK=enp1s0,2500,r8169-0-100:00'
run_probe
check "comments and blank lines are allowed" '[[ "$RC" -eq 0 ]]'

# --- platform-fault signals -----------------------------------------------------
observation() { # signals JSON on stdin -> observation file $1
  python3 -c 'import json,sys; sig=json.load(sys.stdin); json.dump({"kind":"brokkr-platform-observation","schema_version":"v1","now":"2026-10-20T12:00:00Z","observed_at":"2026-10-20T11:59:00Z","valid_until":"2026-10-20T12:14:00Z","node_substrate_ref":{"contract":"grimnir.node-substrate/v1","node_id":"fixture-node","observation_evidence_id":"obs-fixture-001"},"signals":sig}, open(sys.argv[1],"w"))' "$1"
}
categories() { node -e 'const x=require(process.argv[1]); console.log(x.faults.map(f=>f.category+":"+f.severity).sort().join(","))' "$1"; }
signal_state() { python3 -c 'import json,sys; print(",".join(s["name"]+"="+s["state"] for s in json.load(open(sys.argv[1]))))' "$1"; }

scenario incident-flapping; fresh_state
python3 "$PROBE" --signals > "$TMP/signals.json"; RC=$?
observation "$TMP/obs.json" < "$TMP/signals.json"
node "$ROOT/scripts/platform-fault-detector.mjs" --input "$TMP/obs.json" > "$TMP/faults.json"
check "flapping incident yields critical flapping and warning degraded faults" '[[ "$RC" -eq 0 && "$(categories "$TMP/faults.json")" == "network-link-degraded:warning,network-link-flapping:critical" ]]'
check "faults carry ethtool/journal provenance" 'grep -q "ethtool+journalctl-k:enp1s0" "$TMP/faults.json"'

scenario incident-stable-100; fresh_state
python3 "$PROBE" --signals > "$TMP/signals.json"
observation "$TMP/obs.json" < "$TMP/signals.json"
node "$ROOT/scripts/platform-fault-detector.mjs" --input "$TMP/obs.json" > "$TMP/faults.json"
check "stable 100 Mb/s yields only a degraded fault" '[[ "$(categories "$TMP/faults.json")" == "network-link-degraded:warning" ]]'

scenario healthy; fresh_state
MOCK_JOURNAL_RC=1 MOCK_ETHTOOL_RC=75 python3 "$PROBE" --signals > "$TMP/signals.json"
check "missing evidence is signalled unknown, never ok" '[[ "$(signal_state "$TMP/signals.json")" == "network_link_flapping=unknown,network_link_degraded=unknown" ]]'
python3 "$PROBE" --signals > "$TMP/signals.json"
check "a healthy link signals ok" '[[ "$(signal_state "$TMP/signals.json")" == "network_link_flapping=ok,network_link_degraded=ok" ]]'

# --- Heimdall report row (optional) ---------------------------------------------
mkdir -p "$TMP/mount"
cat > "$TMP/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
echo /dev/mock-backup
EOF
cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 1000 700 300 70%% /mock\n'
EOF
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"BackendState":"Running","TailscaleIPs":["192.0.2.10"],"Self":{"Online":true,"DNSName":"nas.example.ts.net"}}'
EOF
chmod +x "$TMP/bin/mountpoint" "$TMP/bin/findmnt" "$TMP/bin/df" "$TMP/bin/tailscale"
report_names() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], ",".join(c["name"]+"="+c["status"] for c in d["checks"]))'; }

scenario incident-stable-100; fresh_state
REPORT="$(BROKKR_DISK_MOUNT="$TMP/mount" BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled \
  BROKKR_TAILSCALE_EXPECTED_DNS_NAME=nas.example.ts.net bash "$ROOT/heimdall/report.sh" | report_names)"
check "configured report adds a link-health row that raises the aggregate" '[[ "$REPORT" == "warn disk-mount=pass,disk-capacity=pass,tailscale-auth=pass,link-health=warn" ]]'
REPORT="$(env -u BROKKR_LINK_HEALTH_CONFIG BROKKR_DISK_MOUNT="$TMP/mount" BROKKR_TAILSCALE_KEY_EXPIRY_POLICY=disabled \
  BROKKR_TAILSCALE_EXPECTED_DNS_NAME=nas.example.ts.net bash "$ROOT/heimdall/report.sh" | report_names)"
check "unconfigured report keeps exactly the three platform checks" '[[ "$REPORT" == "pass disk-mount=pass,disk-capacity=pass,tailscale-auth=pass" ]]'

# --- standalone snapshot runner -> link-health panel ----------------------------
mkdir -p "$TMP/python"
cat > "$TMP/python/sitecustomize.py" <<'PY'
import json, os, urllib.request

class Response:
    status = 200
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return False

class Opener:
    def open(self, request, timeout):
        with open(os.environ["MOCK_REQUEST_FILE"], "w", encoding="utf-8") as fh:
            json.dump(json.loads(request.data.decode()), fh)
        return Response()

urllib.request.build_opener = lambda *handlers: Opener()
PY
run_runner() {
  OUT="$(PYTHONPATH="$TMP/python" MOCK_REQUEST_FILE="$TMP/request.json" bash "$ROOT/scripts/link-health-snapshot.sh" 2>&1)"
  RC=$?
}
scenario incident-flapping; fresh_state; rm -f "$TMP/request.json"
HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel run_runner
check "runner delivers a failing link observation and exits 0" '[[ "$RC" -eq 0 && -f "$TMP/state/link-health.json" ]]'
check "runner pushes the dedicated link-health panel" 'python3 -c '\''import json,sys; b=json.load(open(sys.argv[1])); assert b["panel"]=="link-health" and b["state"]=="fail" and "drops1h=12" in b["message"], b'\'' "$TMP/request.json"'
check "runner stamps delivery under its own prefix" '[[ -s "$TMP/state/link-health-last-push-success" ]]'
OUT="$(env -u HEIMDALL_HUB_URL -u HEIMDALL_FLEET_TOKEN bash "$ROOT/scripts/link-health-snapshot.sh" 2>&1)"; RC=$?
check "runner without Heimdall delivery fails instead of silently skipping" '[[ "$RC" -ne 0 && "$OUT" == *"not configured"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
