#!/usr/bin/env bash
# Regression coverage for the Mimir v1 fixed-record consumer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PROBE="$REPO/scripts/heimdall-storage-probe.sh"
TMP="$(mktemp -d /private/tmp/brokkr-heimdall-storage-probe.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/cat" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  /proc/meminfo) printf 'MemTotal: 1000 kB\nMemAvailable: 500 kB\n' ;;
  /proc/loadavg) printf '0 0 0 0/0 0\n' ;;
  /proc/uptime) printf '1 1\n' ;;
  /proc/net/dev) printf 'Inter-| Receive\n' ;;
  /proc/stat) printf 'cpu  1 1 1 1 1\n' ;;
  *) /bin/cat "$@" ;;
esac
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == %Y ]]; then
  /usr/bin/stat -f %m "$3"
else
  /usr/bin/stat "$@"
fi
EOF
cat >"$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$TMP/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo 1
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

write_config() {
  cat >"$TMP/probe.conf" <<EOF
TM_SNAPSHOT_PATH=$TMP/tm.snapshot
TM_ROOT=$TMP/tm-root
MUNIN_BACKUP_DIR=$TMP/munin
MIMIR_BACKUP_RECORD=$TMP/backup.json
MIMIR_SYNC_RECORD=$TMP/sync.json
EOF
}
run_probe() {
  OUT="$(BROKKR_STORAGE_PROBE_CONFIG="$TMP/probe.conf" bash "$PROBE" 2>&1)"
  # shellcheck disable=SC2034 # Assertions consume RC through check/eval.
  RC=$?
}
section() { printf '%s\n' "$OUT" | awk -v wanted="$1" 'BEGIN { n=0 } $0 == "---" { n++; next } n == wanted { print }'; }
write_record() { printf '%s\n' "$2" >"$TMP/$1.json"; }

mkdir -p "$TMP/tm-root" "$TMP/munin"
touch "$TMP/tm.snapshot"
write_config

echo heimdall-storage-probe.test.sh
BROKKR_STORAGE_PROBE_CONFIG="$TMP/probe.conf" bash "$PROBE" --validate-config
check 'v1 config validates' '[[ $? -eq 0 ]]'

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_record backup "{\"schema_version\":1,\"state\":\"fresh\",\"observed_at\":\"$now\"}"
write_record sync "{\"schema_version\":1,\"state\":\"fresh\",\"observed_at\":\"2000-01-01T00:00:00Z\"}"
run_probe
check 'fresh backup emits its normalized ISO timestamp in section 9' '[[ $RC -eq 0 && "$(section 9)" == "$now" ]]'
check 'stale sync still emits normalized epoch for Heimdall freshness policy in section 10' '[[ "$(section 10)" == 946684800 ]]'
check 'output retains exactly 19 sections' '[[ $(printf "%s\n" "$OUT" | awk '\''$0 == "---" { n++ } END { print n + 1 }'\'') -eq 19 ]]'

write_record backup '{"schema_version":1,"state":"error","observed_at":"2026-07-26T10:00:00Z"}'
run_probe
check 'explicit publisher error is unknown, never fresh' '[[ $RC -eq 0 && -z "$(section 9)" ]]'

for invalid in \
  '{not-json}' \
  '{"schema_version":2,"state":"fresh","observed_at":"2026-07-26T10:00:00Z"}' \
  '{"schema_version":1,"state":"other","observed_at":"2026-07-26T10:00:00Z"}' \
  '{"schema_version":1,"state":"fresh","observed_at":"not-a-time"}' \
  '{"schema_version":1,"state":"fresh","observed_at":"2026-07-26T10:00:00Z","extra":true}'; do
  write_record backup "$invalid"
  run_probe
  check "invalid Mimir record is unknown: $invalid" '[[ $RC -eq 0 && -z "$(section 9)" ]]'
done

rm -f "$TMP/backup.json"
run_probe
check 'absent Mimir record is unknown' '[[ $RC -eq 0 && -z "$(section 9)" ]]'

write_record backup "{\"schema_version\":1,\"state\":\"fresh\",\"observed_at\":\"$now\"}"
mv "$TMP/backup.json" "$TMP/record-target"
ln -s "$TMP/record-target" "$TMP/backup.json"
run_probe
check 'symlinked Mimir record is refused as unknown' '[[ $RC -eq 0 && -z "$(section 9)" ]]'
rm -f "$TMP/backup.json"

cat >>"$TMP/probe.conf" <<EOF
MIMIR_LOG=$TMP/legacy.log
MIMIR_SYNC_STAMP=$TMP/legacy.stamp
MIMIR_SYNC_DIR=$TMP/legacy-tree
EOF
BROKKR_STORAGE_PROBE_CONFIG="$TMP/probe.conf" bash "$PROBE" --validate-config >/dev/null 2>&1
check 'mixed legacy and v1 Mimir configuration is refused' '[[ $? -ne 0 ]]'

sed -i.bak 's|MIMIR_BACKUP_RECORD=.*|MIMIR_BACKUP_RECORD=/tmp/../backup.json|' "$TMP/probe.conf"
BROKKR_STORAGE_PROBE_CONFIG="$TMP/probe.conf" bash "$PROBE" --validate-config >/dev/null 2>&1
check 'traversal in configured record path is refused' '[[ $? -ne 0 ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
