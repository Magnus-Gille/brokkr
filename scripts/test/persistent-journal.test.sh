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
cat >"$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_CALLS"
[[ "$*" == "--flush" ]] || exit 98
[[ "${MOCK_JOURNALCTL_EXIT:-0}" -eq 0 ]] || exit "$MOCK_JOURNALCTL_EXIT"
case "${MOCK_JOURNALCTL_CREATE:-0}" in
  1)
    install -d -m 2755 "$JOURNALD_LOG_DIR/mock-machine-id"
    printf 'mock-journal\n' >"$JOURNALD_LOG_DIR/mock-machine-id/system.journal"
    ;;
  tilde)
    install -d -m 2755 "$JOURNALD_LOG_DIR/mock-machine-id"
    printf 'unclean-journal\n' >"$JOURNALD_LOG_DIR/mock-machine-id/system.journal~"
    ;;
  symlink)
    install -d -m 2755 "$JOURNALD_LOG_DIR/mock-machine-id"
    printf 'outside-journal\n' >"$JOURNALD_LOG_DIR/mock-target"
    ln -s "$JOURNALD_LOG_DIR/mock-target" \
      "$JOURNALD_LOG_DIR/mock-machine-id/system.journal"
    ;;
esac
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/systemctl" "$TMP/bin/journalctl"

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
export MOCK_JOURNALCTL_CREATE=1 MOCK_JOURNALCTL_EXIT=0
run --apply --restart
check "journald restart explicitly flushes before confirming service recovery" '[[ "$RC" -eq 0 && "$OUT" == *"verified persistent journal"* && "$(cat "$CALLS")" == $'\''restart systemd-journald.service\njournalctl --flush\nis-active --quiet systemd-journald.service'\'' ]]'
check "successful restart verifies a non-empty persistent journal file" '[[ -s "$JOURNALD_LOG_DIR/mock-machine-id/system.journal" ]]'

export JOURNALD_LOG_DIR="$TMP/journal-missing"
mkdir -p "$JOURNALD_LOG_DIR"
: >"$CALLS"
export MOCK_JOURNALCTL_CREATE=0
run --apply --restart
check "flush success without an on-disk journal fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"no persistent journal file"* && "$(cat "$CALLS")" == $'\''restart systemd-journald.service\njournalctl --flush\nis-active --quiet systemd-journald.service'\'' ]]'

export JOURNALD_LOG_DIR="$TMP/journal-unclean"
mkdir -p "$JOURNALD_LOG_DIR"
: >"$CALLS"
export MOCK_JOURNALCTL_CREATE=tilde
run --apply --restart
check "an unclean journal~ artifact does not prove persistence" '[[ "$RC" -ne 0 && "$OUT" == *"no persistent journal file"* ]]'

export JOURNALD_LOG_DIR="$TMP/journal-symlink"
mkdir -p "$JOURNALD_LOG_DIR"
: >"$CALLS"
export MOCK_JOURNALCTL_CREATE=symlink
run --apply --restart
check "a symlinked journal file does not prove persistence" '[[ "$RC" -ne 0 && "$OUT" == *"no persistent journal file"* ]]'

export JOURNALD_LOG_DIR="$TMP/journal-flush-failure"
mkdir -p "$JOURNALD_LOG_DIR"
: >"$CALLS"
export MOCK_JOURNALCTL_EXIT=23
run --apply --restart
check "flush command failure stops before success verification" '[[ "$RC" -eq 23 && "$OUT" != *"verified persistent journal"* && "$(cat "$CALLS")" == $'\''restart systemd-journald.service\njournalctl --flush'\'' ]]'

export JOURNALD_LOG_DIR="$TMP/journal"
export MOCK_JOURNALCTL_CREATE=0 MOCK_JOURNALCTL_EXIT=0

rm -f "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf"
printf 'sentinel\n' >"$TMP/sentinel"
ln -s "$TMP/sentinel" "$JOURNALD_DROPIN_DIR/60-brokkr-persistent.conf"
: >"$CALLS"
run --apply
check "symlinked destination is refused without target replacement" '[[ "$RC" -eq 64 && "$OUT" == *"symlinked destination"* && "$(cat "$TMP/sentinel")" == sentinel && ! -s "$CALLS" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
