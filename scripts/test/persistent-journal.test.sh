#!/usr/bin/env bash
# Hermetic safety regression for persistent journal installation (brokkr#3).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INSTALLER="$ROOT/scripts/setup-persistent-journal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/dropins" "$TMP/journal"
CALLS="$TMP/calls"
: >"$CALLS"

cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -u ]]; then printf '%s\n' "${MOCK_UID:-1000}"; else command id "$@"; fi
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_CALLS"
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/systemctl"

export PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS"
export JOURNALD_DROPIN_DIR="$TMP/dropins" JOURNALD_LOG_DIR="$TMP/journal"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # assertions consume OUT and RC through eval.
run() { OUT="$(bash "$INSTALLER" "$@" 2>&1)"; RC=$?; }

echo "persistent-journal.test.sh"

run --dry-run
check "dry run is non-mutating" '[[ "$RC" -eq 0 && "$OUT" == *"DRY RUN"* && ! -e "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && ! -s "$CALLS" ]]'

run --restart
check "restart without apply is refused" '[[ "$RC" -eq 64 && "$OUT" == *"requires --apply"* && ! -s "$CALLS" ]]'

export MOCK_UID=0
run --apply --dry-run
check "conflicting apply and dry-run modes are refused without mutation" '[[ "$RC" -eq 64 && "$OUT" == *"mutually exclusive"* && ! -e "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && ! -s "$CALLS" ]]'

export MOCK_UID=1000
run --apply
check "non-root apply is refused before mutation" '[[ "$RC" -eq 64 && "$OUT" == *"must be run as root"* && ! -e "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && ! -s "$CALLS" ]]'

export MOCK_UID=0
run --apply
check "root apply installs the tracked bounded policy" '[[ "$RC" -eq 0 && "$OUT" == *"next boot"* && -f "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && ! -L "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && "$(stat -c %a "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" 2>/dev/null || stat -f %Lp "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf")" == 644 && ! -s "$CALLS" ]]'
check "installed policy keeps persistent storage and a finite cap" 'grep -Fqx "Storage=persistent" "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && grep -Fqx "SystemMaxUse=256M" "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf" && grep -Fqx "SystemKeepFree=1G" "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf"'

: >"$CALLS"
run --apply --restart
check "journald restart needs the explicit restart flag and confirms recovery" '[[ "$RC" -eq 0 && "$OUT" == *"explicit journald restart"* && "$(cat "$CALLS")" == $'\''restart systemd-journald.service\nis-active --quiet systemd-journald.service'\'' ]]'

rm -f "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf"
printf 'sentinel\n' >"$TMP/sentinel"
ln -s "$TMP/sentinel" "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf"
: >"$CALLS"
run --apply
check "symlinked destination is refused without target replacement" '[[ "$RC" -eq 64 && "$OUT" == *"symlinked destination"* && "$(cat "$TMP/sentinel")" == sentinel && ! -s "$CALLS" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
