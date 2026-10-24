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
  [ "${MOCK_STATS_RC:-0}" = 0 ] || exit "$MOCK_STATS_RC"
  exec cat "$MOCK_NIC_DIR/$2.stats"
elif [ "$#" -eq 1 ]; then
  exec cat "$MOCK_NIC_DIR/$1.link"
fi
exit 64
EOF
cat > "$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_JOURNAL_ARGS"
[ -z "${HEIMDALL_FLEET_TOKEN:-}" ] || echo leaked >> "$MOCK_JOURNAL_ARGS.leak"
# MOCK_QUIET_KERNEL=1: the kernel logged nothing for days, but the system journal
# itself (other transports) does reach back before the window.
case " $* " in
  *" --until "*)
    # Newest record before the 24 h window: proves history covers it.
    [ "${MOCK_NO_HISTORY:-0}" = 1 ] && exit 0
    case " $* " in *" _TRANSPORT=kernel "*) [ "${MOCK_QUIET_KERNEL:-0}" = 1 ] && exit 0 ;; esac
    echo "1792400000.000000 fixture-node systemd[1]: older history"
    exit 0
    ;;
  *" -n 1 "*)
    # Readability proof: the newest record visible to this reader.
    [ "${MOCK_JOURNAL_PROOF_EMPTY:-0}" = 1 ] && exit 0
    case " $* " in *" -k "*) [ "${MOCK_QUIET_KERNEL:-0}" = 1 ] && exit 0 ;; esac
    echo "1792497000.000000 fixture-node systemd[1]: proof"
    exit 0
    ;;
esac
[ -z "${MOCK_JOURNAL_STDERR:-}" ] || printf '%s\n' "$MOCK_JOURNAL_STDERR" >&2
[ "${MOCK_JOURNAL_RC:-0}" = 0 ] || exit "$MOCK_JOURNAL_RC"
exec cat "$MOCK_JOURNAL_FILE"
EOF
cat > "$TMP/bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
# MOCK_READKMSG: effective ReadKMsg= value ("" = only the commented default).
[ "${MOCK_ANALYZE_RC:-0}" = 0 ] || exit "$MOCK_ANALYZE_RC"
echo "# /etc/systemd/journald.conf"
echo "[Journal]"
echo "#ReadKMsg=yes"
[ -z "${MOCK_READKMSG:-}" ] || { echo "# /etc/systemd/journald.conf.d/50-test.conf"; echo "[Journal]"; echo "ReadKMsg=$MOCK_READKMSG"; }
[ -z "${MOCK_ANALYZE_EXTRA:-}" ] || printf '%b\n' "$MOCK_ANALYZE_EXTRA"
EOF
chmod +x "$TMP/bin/ethtool" "$TMP/bin/journalctl" "$TMP/bin/systemd-analyze"
export PATH="$TMP/bin:$PATH"
export BROKKR_NOW_EPOCH=1792497600 BROKKR_STATE_DIR="$TMP/state"
export MOCK_NIC_DIR="$TMP/nic" MOCK_JOURNAL_ARGS="$TMP/journal-args"
export BROKKR_LINK_HEALTH_CONFIG="$TMP/link-health.conf"
export BROKKR_SYSFS_NET="$TMP/sysfs"  # empty unless a test creates counters; never the host's
export BROKKR_BOOT_ID_FILE="$TMP/boot_id"  # never the host's
printf '00000000-0000-4000-8000-000000000001\n' > "$BROKKR_BOOT_ID_FILE"

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
# Record an error-counter baseline 15 minutes earlier so the next run can compare.
settled() {
  fresh_state
  BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - 900)) python3 "$PROBE" > /dev/null 2>&1
}
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
check "first run records a counter baseline and reports the error check unknown" '[[ "$RC" -eq 1 && "$OUT" == *"errors=baseline"* && "$OUT" == *"unknown: counter baseline recorded"* && -f "$TMP/state/link-health/enp1s0.json" ]]'
check "kernel records are queried across boots over 24 h (not -k, which implies -b)" 'grep -- "--since @1792411200" "$MOCK_JOURNAL_ARGS" | grep -q "_TRANSPORT=kernel" && ! grep -- "--since" "$MOCK_JOURNAL_ARGS" | grep -q -- " -k "'
check "journal readability is proven from the system journal" 'grep -q -- "--system -n 1" "$MOCK_JOURNAL_ARGS"'
check "journal history before the window is probed" 'grep -q -- "--until @1792411200" "$MOCK_JOURNAL_ARGS"'
BROKKR_NOW_EPOCH=1792498500 run_probe
check "healthy 2.5G link with no events passes once a baseline exists" '[[ "$RC" -eq 0 && "$OUT" == OK:* && "$OUT" == *"errors=+0/900s"* ]]'

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
settled
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
settled
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
mkdir -p "$TMP/sysfs/enp1s0/statistics"
printf '0\n' > "$TMP/sysfs/enp1s0/statistics/tx_errors"
printf '0\n' > "$TMP/sysfs/enp1s0/statistics/rx_errors"
settled
run_probe
check "generic sysfs error counters back up a driver without them in ethtool -S" '[[ "$RC" -eq 0 && "$OUT" == *"errors=+0/900s"* ]]'
printf 'garbage\n' > "$TMP/sysfs/enp1s0/statistics/rx_errors"
run_probe
check "an unparsable sysfs counter is unknown" '[[ "$RC" -eq 1 && "$OUT" == *"errors=unknown"* ]]'
rm -rf "$TMP/sysfs"

# --- driver wording, name prefixes, and window edges -----------------------------
scenario healthy
cp "$FIX/healthy/enp1s0.link" "$TMP/nic/eth1.link"
cp "$FIX/healthy/enp1s0.stats" "$TMP/nic/eth1.stats"
cat > "$TMP/edges.journal" <<'EOF'
1792411199.999999 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792411200.000000 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792493999.999999 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792494000.000000 fixture-node kernel: igb 0000:03:00.0 eth1: igb: eth1 NIC Link is Down
1792497600.000000 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792497601.000000 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792501200.000000 fixture-node kernel: e1000e: eth1 NIC Link is Down
1792497000.000000 fixture-node kernel: r8169 0000:02:00.0 eth10: Link is Down
1792497001.000000 fixture-node kernel: r8169 0000:02:00.0 eth1.10: Link is Down
1792497002.000000 fixture-node kernel: r8169 0000:02:00.0 veth1: Link is Down
EOF
write_config 'LINK=eth1,2500' 'DROPS_24H_WARN=100'
MOCK_JOURNAL_FILE="$TMP/edges.journal" run_probe
check "e1000e/igb wording counts once; eth10/eth1.10/veth1 are not eth1; now-24h and now-1h are inside, a second earlier or any record after now is outside" '[[ "$OUT" == *"drops1h=2 "* && "$OUT" == *"drops24h=4 "* ]]'

# --- journal history that starts inside the window (volatile journal after reboot) --
scenario volatile-after-reboot
write_config 'LINK=enp1s0,2500,r8169-0-100:00'
settled
MOCK_NO_HISTORY=1 run_probe
check "history starting mid-window is not OK: the 24 h count is a lower bound" '[[ "$RC" -eq 1 && "$OUT" == *"drops24h>=1"* && "$OUT" == *"unknown: kernel journal covers only"* ]]'
check "a 1 h window fully inside the history is still counted exactly" '[[ "$OUT" == *"drops1h=0 "* ]]'
settled
run_probe
check "the same records with history before the window are a clean count" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=1 "* ]]'
printf '%s\n' "1792497000.000000 fixture-node kernel: Linux version fixture" > "$TMP/recent.journal"
MOCK_NO_HISTORY=1 MOCK_JOURNAL_FILE="$TMP/recent.journal" run_probe
check "history younger than an hour makes the 1 h count partial too" '[[ "$RC" -eq 1 && "$OUT" == *"drops1h>=0"* && "$OUT" == *"drops24h>=0"* ]]'
for t in 1792496000 1792496300 1792496600 1792496900 1792497200; do
  printf '%s.000000 fixture-node kernel: r8169 0000:01:00.0 enp1s0: Link is Down\n' "$t"
done > "$TMP/flap-after-boot.journal"
MOCK_NO_HISTORY=1 MOCK_JOURNAL_FILE="$TMP/flap-after-boot.journal" run_probe
check "a partial count that already crosses a threshold still fails" '[[ "$RC" -eq 2 && "$OUT" == *"drops1h>=5"* ]]'
MOCK_NO_HISTORY=1 python3 "$PROBE" --signals > "$TMP/partial-signals.json"
check "partial history leaves the flapping signal unknown, not ok" 'grep -q "\"network_link_flapping\", \"state\": \"unknown\"" "$TMP/partial-signals.json"'
# --- quiet kernel: no kernel record for days, but the journal covers the window --
# Regression (a fleet node, 2026-10-24): coverage proven only by an old *kernel*
# record made a healthy, quiet host report "covers only Ns of 24h" forever.
scenario volatile-after-reboot
write_config 'LINK=enp1s0,2500,r8169-0-100:00'
settled
MOCK_QUIET_KERNEL=1 run_probe
check "a quiet kernel with older non-kernel journal history is a clean count" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=1 "* && "$OUT" != *"covers only"* ]]'
settled
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/recent.journal" run_probe
check "a quiet kernel does not make the journal look unreadable" '[[ "$OUT" != *"unreadable"* ]]'
: > "$TMP/empty.journal"
settled
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "no kernel record at all, but older history and kernel ingestion on, is a clean zero" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=0 "* ]]'
settled
MOCK_READKMSG=no MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "journald not reading kernel messages is unknown, never a clean zero" '[[ "$RC" -eq 1 && "$OUT" == *"unknown"* && "$OUT" == *"kernel messages"* ]]'
settled
MOCK_READKMSG=yes MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "an explicit ReadKMsg=yes drop-in keeps the clean count" '[[ "$RC" -eq 0 ]]'
settled
MOCK_READKMSG=no MOCK_ANALYZE_EXTRA='# /etc/systemd/journald.conf.d/90-other.conf\n[Other]\nReadKMsg=yes' MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "ReadKMsg outside [Journal] cannot re-enable kernel ingestion" '[[ "$RC" -eq 1 && "$OUT" == *"kernel messages"* ]]'
settled
MOCK_ANALYZE_EXTRA='# /etc/systemd/journald.conf.d/90-bad.conf\n[Journal]\nReadKMsg=perhaps' MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "an invalid ReadKMsg value is unknown, never assumed on" '[[ "$RC" -eq 1 && "$OUT" == *"unknown"* ]]'
settled
MOCK_ANALYZE_EXTRA='# /etc/systemd/journald.conf.d/90-ok.conf\n[Journal]\n  readkmsg = Yes  ' MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "case and whitespace in a valid ReadKMsg are accepted" '[[ "$RC" -eq 0 ]]'
settled
MOCK_ANALYZE_RC=1 MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "unverifiable kernel ingestion is unknown, never a clean zero" '[[ "$RC" -eq 1 && "$OUT" == *"unknown"* ]]'
scenario healthy
write_config 'LINK=enp1s0,2500,r8169-0-100:00'

# --- kernel carrier counters cross-check the journal ------------------------------
# carrier_down_count is kept by the kernel itself, so drops that journald never
# ingested still show up as a counter delta between runs.
set_carrier() { mkdir -p "$TMP/sysfs/enp1s0"; printf '%s\n' "$1" > "$TMP/sysfs/enp1s0/carrier_down_count"; }
scenario healthy
fresh_state
run_probe
check "without carrier_down_count the cross-check is unavailable, not ok" '[[ "$OUT" == *"carrier-down=unavailable"* ]]'
settled
run_probe
check "without carrier_down_count the other checks are unchanged" '[[ "$RC" -eq 0 && "$OUT" == OK:* && "$OUT" == *"errors=+0/900s"* && "$OUT" == *"drops24h=0 "* && "$OUT" == *"carrier-down=unavailable"* ]]'
set_carrier 5
settled
run_probe
check "equal carrier and journal counts pass" '[[ "$RC" -eq 0 && "$OUT" == OK:* && "$OUT" == *"carrier-down=+0/900s"* ]]'
set_carrier 5; settled; set_carrier 6
printf '%s\n' "1792497000.000000 fixture-node kernel: r8169 0000:01:00.0 enp1s0: Link is Down" > "$TMP/one-drop.journal"
MOCK_JOURNAL_FILE="$TMP/one-drop.journal" run_probe
check "a carrier drop matched by a logged drop passes" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=1 "* && "$OUT" == *"carrier-down=+1/900s"* ]]'
set_carrier 5; settled; set_carrier 6
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "a carrier drop missing from the journal is not ok" '[[ "$RC" -eq 1 && "$OUT" == *"drops24h>=1"* && "$OUT" == *"unknown: carrier went down 1x"*"journal shows 0"* ]]'
set_carrier 5; settled; set_carrier 6
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" python3 "$PROBE" --signals > "$TMP/carrier-signals.json"
check "an incomplete journal leaves the flapping signal unknown" 'grep -q "\"network_link_flapping\", \"state\": \"unknown\"" "$TMP/carrier-signals.json"'
set_carrier 5; settled; set_carrier 9
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "unlogged carrier drops within an hour cross the 1 h fail threshold" '[[ "$RC" -eq 2 && "$OUT" == FAIL:* && "$OUT" == *"drops1h>=4"* && "$OUT" == *"carrier went down 4x"* ]]'
set_carrier 5; settled; set_carrier 9
MOCK_JOURNAL_FILE="$TMP/one-drop.journal" run_probe
check "the excess over logged drops is added to the journal count" '[[ "$RC" -eq 2 && "$OUT" == *"drops1h>=4"* && "$OUT" == *"drops24h>=4"* && "$OUT" == *"journal shows 1"* ]]'
set_carrier 5; settled; set_carrier 9
MOCK_JOURNAL_RC=1 run_probe
check "carrier drops cross thresholds even when the journal is unreadable" '[[ "$RC" -eq 2 && "$OUT" == *"drops1h>=4"* && "$OUT" == *"unknown: journalctl failed"* ]]'
set_carrier 5; fresh_state
BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - 7200)) python3 "$PROBE" > /dev/null 2>&1
set_carrier 9
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "carrier drops over a 2 h interval count toward 24 h only" '[[ "$RC" -eq 1 && "$OUT" == *"drops1h>=0 "* && "$OUT" == *"drops24h>=4"* && "$OUT" == *"4 drops in 24h"* ]]'
set_carrier 5; settled; set_carrier 2
run_probe
check "a carrier counter reset is unknown, not ok" '[[ "$RC" -eq 1 && "$OUT" == *"carrier-down=baseline"* && "$OUT" == *"unknown: carrier counter reset"* ]]'
set_carrier garbage
run_probe
check "an unparsable carrier counter is unknown" '[[ "$RC" -eq 1 && "$OUT" == *"carrier-down=unknown"* && "$OUT" == *"unknown: carrier_down_count"* ]]'
rm -rf "$TMP/sysfs"; settled; set_carrier 5
run_probe
check "a baseline without a carrier count (upgrade) is unknown, not ok" '[[ "$RC" -eq 1 && "$OUT" == *"carrier-down=baseline"* && "$OUT" == *"unknown: carrier baseline recorded"* ]]'
rm -rf "$TMP/sysfs"; settled; set_carrier 5
python3 "$PROBE" --signals > "$TMP/carrier-signals.json"
check "a missing carrier baseline leaves the flapping signal unknown" 'grep -q "\"network_link_flapping\", \"state\": \"unknown\"" "$TMP/carrier-signals.json"'
settled
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["carrier_samples"]="5"; json.dump(d,open(sys.argv[1],"w"))' "$TMP/state/link-health/enp1s0.json"
run_probe
check "a corrupt carrier baseline is unknown, not ok" '[[ "$RC" -eq 1 && "$OUT" == *"unknown: carrier baseline unreadable"* ]]'
settled
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["carrier_samples"][0][1]=-3; json.dump(d,open(sys.argv[1],"w"))' "$TMP/state/link-health/enp1s0.json"
run_probe
check "a negative carrier baseline is unknown, not a large delta" '[[ "$RC" -eq 1 && "$OUT" == *"unknown: carrier baseline unreadable"* && "$OUT" != *"drops in"* ]]'
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 000 "$TMP/sysfs/enp1s0/carrier_down_count"
  run_probe
  check "an unreadable carrier counter is unknown" '[[ "$RC" -eq 1 && "$OUT" == *"unknown: carrier_down_count unreadable"* ]]'
  chmod 600 "$TMP/sysfs/enp1s0/carrier_down_count"
fi
baseline_at() { BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - $1)) python3 "$PROBE" > /dev/null 2>&1; }
# Regression (review): the excess counted for one run only, so drops the journal
# missed read as a clean zero 15 minutes later.
set_carrier 5; fresh_state; baseline_at 1800; set_carrier 7
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - 900)) run_probe
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "unlogged carrier drops stay counted on later runs within 24 h" '[[ "$RC" -eq 1 && "$OUT" == *"carrier-down=+0/900s"* && "$OUT" == *"drops24h>=2"* && "$OUT" == *"2 drops in 24h"* && "$OUT" == *"carrier went down 2x in 1800s"* ]]'
set_carrier 5; fresh_state; baseline_at 1800; set_carrier 6
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - 900)) run_probe
printf '%s\n' "1792496400.000000 fixture-node kernel: r8169 0000:01:00.0 enp1s0: Link is Down" > "$TMP/late.journal"
MOCK_JOURNAL_FILE="$TMP/late.journal" run_probe
check "a journal record that arrives late reconciles the carrier count" '[[ "$RC" -eq 0 && "$OUT" == *"drops24h=1 "* ]]'
set_carrier 5; fresh_state; baseline_at 900; set_carrier 6
printf '%s\n' "1792496700.000000 fixture-node kernel: r8169 0000:01:00.0 enp1s0: Link is Down" > "$TMP/same-second.journal"
MOCK_JOURNAL_FILE="$TMP/same-second.journal" run_probe
check "a record in the baseline's own second counts as logged" '[[ "$RC" -eq 0 && "$OUT" == *"carrier-down=+1/900s"* ]]'
set_carrier 5; fresh_state; baseline_at 3600; set_carrier 8
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "a sample exactly an hour old counts toward the 1 h window" '[[ "$RC" -eq 2 && "$OUT" == *"3 drops in 1h"* ]]'
set_carrier 5; fresh_state; baseline_at 3601; set_carrier 8
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "a sample just over an hour old counts toward 24 h only" '[[ "$RC" -eq 1 && "$OUT" != *"drops in 1h"* && "$OUT" == *"3 drops in 24h"* ]]'
# A reboot restarts the count; boot-time carrier events that log nothing must not
# read as missed drops against the previous boot's samples.
set_carrier 1; fresh_state; baseline_at 1800; set_carrier 2
printf '00000000-0000-4000-8000-000000000002\n' > "$BROKKR_BOOT_ID_FILE"
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" BROKKR_NOW_EPOCH=$((BROKKR_NOW_EPOCH - 900)) run_probe
check "a new boot id resets the carrier baseline instead of reporting missed drops" '[[ "$RC" -eq 1 && "$OUT" == *"carrier-down=baseline"* && "$OUT" == *"unknown: carrier counter reset (reboot)"* && "$OUT" != *"carrier went down"* ]]'
MOCK_QUIET_KERNEL=1 MOCK_JOURNAL_FILE="$TMP/empty.journal" run_probe
check "the run after a reboot reset compares within the new boot" '[[ "$RC" -eq 0 && "$OUT" == *"carrier-down=+0/900s"* ]]'
printf '00000000-0000-4000-8000-000000000001\n' > "$BROKKR_BOOT_ID_FILE"
# Regression (review): unreadable tx/rx counters must not stop the carrier baseline.
scenario healthy; set_carrier 5; fresh_state
MOCK_STATS_RC=1 baseline_at 900
MOCK_STATS_RC=1 python3 "$PROBE" --signals > "$TMP/carrier-signals.json"
check "carrier evidence is kept when the error counters are unreadable" 'grep -q "\"network_link_flapping\", \"state\": \"ok\"" "$TMP/carrier-signals.json" && grep -q "carrier-down=+0/900s" "$TMP/carrier-signals.json"'
rm -rf "$TMP/sysfs"

# --- error-counter deltas -------------------------------------------------------
scenario healthy
fresh_state
run_probe
set_counters 7 9
BROKKR_NOW_EPOCH=1792498500 run_probe
check "an error-counter increase at the threshold warns" '[[ "$RC" -eq 1 && "$OUT" == *"errors=+16/900s"* ]]'
set_counters 0 0
BROKKR_NOW_EPOCH=1792499400 run_probe
check "a counter reset (reboot/driver reload) rebaselines and reports the error check unknown" '[[ "$RC" -eq 1 && "$OUT" == *"errors=baseline"* && "$OUT" == *"unknown: error counters reset"* ]]'
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
check "an unreadable counter baseline rebaselines as unknown instead of crashing" '[[ "$RC" -eq 1 && "$OUT" == *"errors=baseline"* && "$OUT" == *"unknown: counter baseline unreadable"* ]]'
BROKKR_NOW_EPOCH=$((1792499400 + 86401)) run_probe
check "a baseline older than 24 h is stale, not a clean comparison" '[[ "$RC" -eq 1 && "$OUT" == *"unknown: counter baseline stale"* ]]'
BROKKR_NOW_EPOCH=1792499400 run_probe
check "a clock step backwards is stale, not a clean comparison" '[[ "$RC" -eq 1 && "$OUT" == *"unknown: counter baseline stale"* ]]'
BROKKR_NOW_EPOCH=1792500300 run_probe
check "the run after a rebaseline compares cleanly again" '[[ "$RC" -eq 0 && "$OUT" == *"errors=+0/900s"* ]]'

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
settled
run_probe
check "comments and blank lines are allowed" '[[ "$RC" -eq 0 ]]'

# --check-config validates the protected config with the probe's own parser and
# reads no NIC or journal (the mocks would fail loudly if it did).
write_config 'LINK=enp1s0,2500,r8169-0-100:00'
rm -f "$MOCK_JOURNAL_ARGS"
OUT="$(python3 "$PROBE" --check-config 2>&1)"; RC=$?
check "--check-config accepts a valid config and prints no detail beyond a count" '[[ "$RC" -eq 0 && "$OUT" == "OK: link-health config valid (1 link)" ]]'
check "--check-config does not read the journal or NIC" '[[ ! -e "$MOCK_JOURNAL_ARGS" ]]'
write_config 'LINK=enp1s0,2500' 'SURPRISE=1'
OUT="$(python3 "$PROBE" --check-config 2>&1)"; RC=$?
check "--check-config rejects an invalid config with exit 2" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
write_config 'LINK=enp1s0,2500'
chmod 640 "$BROKKR_LINK_HEALTH_CONFIG"
OUT="$(python3 "$PROBE" --check-config 2>&1)"; RC=$?
check "--check-config rejects a group-readable config" '[[ "$RC" -eq 2 && "$OUT" == FAIL:*config* ]]'
chmod 600 "$BROKKR_LINK_HEALTH_CONFIG"
OUT="$(python3 "$PROBE" --check-config --signals 2>&1)"; RC=$?
check "--check-config cannot be combined with other modes" '[[ "$RC" -eq 64 ]]'
OUT="$(python3 - --check-config < "$PROBE" 2>&1)"; RC=$?
check "--check-config works when the probe is piped on stdin" '[[ "$RC" -eq 0 && "$OUT" == OK:* ]]'
write_config 'LINK=enp1s0,2500'

# BROKKR_ETHTOOL pins the absolute ethtool path (the user manager's PATH may lack
# /usr/sbin); ethtool must not be looked up on PATH when it is set.
mkdir -p "$TMP/alt"
cat > "$TMP/alt/ethtool-alt" <<'EOF'
#!/usr/bin/env bash
echo used >> "$MOCK_ALT_USED"
exec "$MOCK_ETHTOOL_REAL" "$@"
EOF
chmod +x "$TMP/alt/ethtool-alt"
export MOCK_ALT_USED="$TMP/alt-used" MOCK_ETHTOOL_REAL="$TMP/bin/ethtool"
scenario healthy; fresh_state; rm -f "$MOCK_ALT_USED"
write_config 'LINK=enp1s0,2500'
BROKKR_ETHTOOL="$TMP/alt/ethtool-alt" run_probe
check "BROKKR_ETHTOOL selects the ethtool binary" '[[ -s "$MOCK_ALT_USED" && "$OUT" != *"ethtool failed"* ]]'
rm -f "$MOCK_ALT_USED"
mv "$TMP/bin/ethtool" "$TMP/bin/ethtool.real"; MOCK_ETHTOOL_REAL="$TMP/bin/ethtool.real" BROKKR_ETHTOOL="$TMP/alt/ethtool-alt" run_probe
check "with BROKKR_ETHTOOL set, ethtool need not be on PATH" '[[ -s "$MOCK_ALT_USED" && "$OUT" != *"ethtool failed"* ]]'
mv "$TMP/bin/ethtool.real" "$TMP/bin/ethtool"
BROKKR_ETHTOOL="$TMP/alt/missing-ethtool" run_probe
check "a bad BROKKR_ETHTOOL path is reported as unknown, not ok" '[[ "$RC" -eq 1 && "$OUT" == *"ethtool failed"* ]]'
write_config 'LINK=enp1s0,2500'

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
settled
python3 "$PROBE" --signals > "$TMP/signals.json"
check "a healthy link signals ok" '[[ "$(signal_state "$TMP/signals.json")" == "network_link_flapping=ok,network_link_degraded=ok" ]]'
MOCK_STATS_RC=75 python3 "$PROBE" --signals > "$TMP/signals.json"
check "missing error counters leave degraded unknown without hiding flapping evidence" '[[ "$(signal_state "$TMP/signals.json")" == "network_link_flapping=ok,network_link_degraded=unknown" ]]'
write_config 'LINK=enp1s0,2500' 'SURPRISE=1'
python3 "$PROBE" --signals > "$TMP/signals.json" 2> "$TMP/signals.err"; RC=$?
check "--signals with a bad config exits 2 and emits no signals" '[[ "$RC" -eq 2 && ! -s "$TMP/signals.json" ]] && grep -q config "$TMP/signals.err"'
write_config 'LINK=enp1s0,2500,r8169-0-100:00'

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
HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel BROKKR_LINK_HEALTH_NODE=node-a run_runner
check "runner delivers a failing link observation and exits 0" '[[ "$RC" -eq 0 && -f "$TMP/state/link-health.json" ]]'
check "runner pushes a per-node link-health panel" 'python3 -c '\''import json,sys; b=json.load(open(sys.argv[1])); assert b["panel"]=="link-health-node-a" and "node-a" in b["label"] and b["state"]=="fail" and "drops1h=12" in b["message"], b'\'' "$TMP/request.json"'

# Two nodes must never share one panel: the last push would hide the other node.
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\necho "Node_B.example.lan"\n' > "$TMP/fakebin/hostname"; chmod +x "$TMP/fakebin/hostname"
fresh_state; rm -f "$TMP/request.json"
PATH="$TMP/fakebin:$PATH" HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel run_runner
check "runner derives a sanitised panel name from the short hostname" 'python3 -c '\''import json,sys; b=json.load(open(sys.argv[1])); assert b["panel"]=="link-health-node-b", b'\'' "$TMP/request.json"'
fresh_state; rm -f "$TMP/request.json"
HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel BROKKR_LINK_HEALTH_NODE='***' run_runner
check "runner refuses a node name that sanitises to nothing" '[[ "$RC" -ne 0 && ! -e "$TMP/request.json" && "$OUT" == *"node name"* ]]'
fresh_state; rm -f "$TMP/request.json"
HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel BROKKR_LINK_HEALTH_NODE="$(printf 'n%.0s' {1..41})" run_runner
check "runner refuses an over-long node name instead of truncating it into a collision" '[[ "$RC" -ne 0 && ! -e "$TMP/request.json" && "$OUT" == *"node name"* ]]'
scenario incident-flapping; fresh_state; rm -f "$TMP/request.json"
HEIMDALL_HUB_URL=http://heimdall.invalid/api/panels HEIMDALL_FLEET_TOKEN=secret-sentinel BROKKR_LINK_HEALTH_NODE=node-a run_runner
check "runner stamps delivery under its own prefix" '[[ -s "$TMP/state/link-health-last-push-success" ]]'
check "the Heimdall token is not passed to probe child processes" '[[ ! -e "$MOCK_JOURNAL_ARGS.leak" ]]'
OUT="$(env -u HEIMDALL_HUB_URL -u HEIMDALL_FLEET_TOKEN bash "$ROOT/scripts/link-health-snapshot.sh" 2>&1)"; RC=$?
check "runner without Heimdall delivery fails instead of silently skipping" '[[ "$RC" -ne 0 && "$OUT" == *"not configured"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
