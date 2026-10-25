#!/usr/bin/env bash
# Hermetic offline-rotation tests. cryptsetup, mount, umount, mountpoint, smartctl,
# rsync and lsblk are PATH mocks; the "device" is a regular file and the "disk" is a
# directory that the mount mock moves onto the mount point. No real device is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../offline-rotation.sh"
# Every fixture path is built under $TMP, so stop before anything else if it is unusable.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-offline-rotation-test.XXXXXX")" || exit 1
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "cannot create test workspace" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

UUID=0f1e2d3c-4b5a-4968-8776-655443322110
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$TMP/bin"

cat >"$TMP/bin/cryptsetup" <<'MOCK'
#!/usr/bin/env bash
printf 'cryptsetup %s\n' "$*" >>"$MOCK_CALLS"
case "$1" in
  isLuks)
    [ "${2:-}" = --type ] && [ "${3:-}" = luks2 ] || exit 64
    exit "${MOCK_CS_ISLUKS_RC:-0}" ;;
  luksUUID) printf '%s\n' "${MOCK_CS_UUID:-}" ;;
  status)
    # MOCK_CS_STATUS_ERR_AFTER_OPEN: the query itself fails (not "inactive") once open.
    if [ "${MOCK_CS_STATUS_ERR_AFTER_OPEN:-}" = 1 ] && [ -e "$MOCK_STATE/open" ]; then exit 2; fi
    if [ -e "$MOCK_STATE/open" ] || [ "${MOCK_CS_ACTIVE:-}" = 1 ]; then exit 0; fi
    exit 4 ;;
  open)
    for arg in "$@"; do
      case "$arg" in --key-file=*) cat "${arg#--key-file=}" >/dev/null || exit 2 ;; esac
    done
    # MOCK_CS_OPEN_LEAK: the mapping exists but the caller saw a failure (for example a
    # signal between the command finishing and the script recording it).
    [ "${MOCK_CS_OPEN_LEAK:-}" != 1 ] || { : >"$MOCK_STATE/open"; exit 1; }
    [ "${MOCK_CS_OPEN_RC:-0}" = 0 ] || exit "$MOCK_CS_OPEN_RC"
    : >"$MOCK_STATE/open"
    if [ "${MOCK_SIGNAL_AFTER:-}" = open ]; then kill -"$MOCK_SIGNAL" "$PPID"; fi ;;
  luksClose)
    [ ! -e "$MOCK_STATE/mounted" ] || exit 5
    [ "${MOCK_CS_CLOSE_RC:-0}" = 0 ] || exit "$MOCK_CS_CLOSE_RC"
    rm -f "$MOCK_STATE/open" ;;
  *) exit 64 ;;
esac
MOCK

cat >"$TMP/bin/mount" <<'MOCK'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$MOCK_CALLS"
mnt="${!#}"
[ -e "$MOCK_STATE/open" ] || exit 32
[ "${MOCK_MOUNT_RC:-0}" = 0 ] || exit "$MOCK_MOUNT_RC"
rmdir "$mnt" && mv "$MOCK_DISK" "$mnt" && printf '%s\n' "$mnt" >"$MOCK_STATE/mounted"
if [ "${MOCK_SIGNAL_AFTER:-}" = mount ]; then kill -"$MOCK_SIGNAL" "$PPID"; fi
[ "${MOCK_MOUNT_LEAK:-}" != 1 ] || exit 1
MOCK

cat >"$TMP/bin/umount" <<'MOCK'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >>"$MOCK_CALLS"
[ "${MOCK_UMOUNT_RC:-0}" = 0 ] || exit "$MOCK_UMOUNT_RC"
[ -e "$MOCK_STATE/mounted" ] || exit 32
mv "$1" "$MOCK_DISK" && mkdir "$1" && rm -f "$MOCK_STATE/mounted"
MOCK

cat >"$TMP/bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
# util-linux contract: 0 = mount point, 32 = not a mount point, anything else = error.
[ "${1:-}" = -q ] && shift
[ "${MOCK_MOUNTPOINT_ERR:-}" != 1 ] || exit 1
if [ -e "$MOCK_STATE/mounted" ] && [ "$(cat "$MOCK_STATE/mounted")" = "$1" ]; then
  [ "${MOCK_MOUNTPOINT_ERR_AFTER_MOUNT:-}" != 1 ] || exit 1
  exit 0
fi
exit 32
MOCK

cat >"$TMP/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
printf 'lsblk %s\n' "$*" >>"$MOCK_CALLS"
printf '%s\n' "${MOCK_LSBLK_PARENT-sdz}"
MOCK

cat >"$TMP/bin/smartctl" <<'MOCK'
#!/usr/bin/env bash
printf 'smartctl %s\n' "$*" >>"$MOCK_CALLS"
[ "${1:-}" = -d ] && [ "${2:-}" = sat ] || exit 1
case "$3" in
  -t) rm -f "$MOCK_STATE/smart-polls"; exit "${MOCK_SMART_START_RC:-0}" ;;
  -c)
    n=$(cat "$MOCK_STATE/smart-polls" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" >"$MOCK_STATE/smart-polls"
    if [ "$n" -le "${MOCK_SMART_PROGRESS_POLLS:-2}" ]; then
      echo 'Self-test execution status:      ( 241) Self-test routine in progress...'
    else
      echo 'Self-test execution status:      (   0) The previous self-test routine completed'
    fi ;;
  -l)
    echo 'Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error'
    if [ "${MOCK_SMART_CMD_FAIL:-}" = -l ]; then
      echo '# 1  Short offline       Completed without error       00%        31         -'; exit 4
    fi
    if [ "${MOCK_SMART_RESULT:-pass}" = pass ]; then
      echo '# 1  Short offline       Completed without error       00%        31         -'
    else
      echo '# 1  Short offline       Completed: read failure       90%        31         123456'
    fi ;;
  -H)
    if [ "${MOCK_SMART_CMD_FAIL:-}" = -H ]; then
      echo 'SMART overall-health self-assessment test result: PASSED'; exit 2
    fi
    if [ "${MOCK_SMART_HEALTH:-PASSED}" = PASSED ]; then
      echo 'SMART overall-health self-assessment test result: PASSED'
    else
      echo 'SMART overall-health self-assessment test result: FAILED!'; exit 8
    fi ;;
esac
MOCK

# rsync mock: copies regular files and symlinks (as links, like -a), honours
# --ignore-existing, creates only the last destination component (like real rsync
# without --mkpath), and fails hard on any deletion flag so a test cannot pass while
# the script asks rsync to delete.
cat >"$TMP/bin/rsync" <<'MOCK'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
ignore=0
args=()
for arg in "$@"; do
  case "$arg" in
    --delete*|--remove-source-files) echo "mock rsync: deletion flag $arg" >&2; exit 99 ;;
    --ignore-existing) ignore=1 ;;
    -*) ;;
    *) args+=("$arg") ;;
  esac
done
src="${args[0]%/}"; dst="${args[1]%/}"
# MOCK_RSYNC_LINKIFY: a hashed regular source file becomes a symlink to a live copy
# just before this copy runs.
if [ -n "${MOCK_RSYNC_LINKIFY:-}" ] && [ -f "$src/$MOCK_RSYNC_LINKIFY" ] && [ ! -L "$src/$MOCK_RSYNC_LINKIFY" ]; then
  mv "$src/$MOCK_RSYNC_LINKIFY" "$MOCK_STATE/live-target"
  ln -s "$MOCK_STATE/live-target" "$src/$MOCK_RSYNC_LINKIFY"
fi
[ -d "$(dirname "$dst")" ] || { echo "mock rsync: mkdir $dst failed: No such file or directory" >&2; exit 11; }
[ -d "$dst" ] || mkdir "$dst" || exit 11
(cd "$src" && find . \( -type f -o -type l \)) | while IFS= read -r rel; do
  rel="${rel#./}"
  if [ "$ignore" = 1 ] && { [ -e "$dst/$rel" ] || [ -L "$dst/$rel" ]; }; then continue; fi
  mkdir -p "$(dirname "$dst/$rel")"
  if [ -L "$src/$rel" ]; then
    ln -s "$(readlink "$src/$rel")" "$dst/$rel"
  else
    cp -p "$src/$rel" "$dst/$rel"
  fi
done
# MOCK_RSYNC_SWAP_FROM/TO: replace a file mid-run (for example the source manifest).
if [ -n "${MOCK_RSYNC_SWAP_FROM:-}" ]; then cp "$MOCK_RSYNC_SWAP_FROM" "$MOCK_RSYNC_SWAP_TO"; fi
if [ -n "${MOCK_RSYNC_CORRUPT:-}" ] && [ -f "$dst/$MOCK_RSYNC_CORRUPT" ]; then
  echo corrupted >>"$dst/$MOCK_RSYNC_CORRUPT"
fi
exit "${MOCK_RSYNC_RC:-0}"
MOCK
# mkdir pass-through; with MOCK_MKDIR_SIGNAL=1 it sends TERM to the script right after
# creating the run lock, to hit the window before the script records owning it.
cat >"$TMP/bin/mkdir" <<'MOCK'
#!/usr/bin/env bash
/bin/mkdir "$@"; rc=$?
if [ "${MOCK_MKDIR_SIGNAL:-}" = 1 ] && [ "$rc" = 0 ]; then
  case "${!#}" in *brokkr-offline-rotation.lock) kill -TERM "$PPID" ;; esac
fi
exit "$rc"
MOCK
chmod +x "$TMP/bin/"*

# Build a fresh fixture: sources, manifest, fake device, by-uuid link, prepared disk.
setup() {
  rm -rf "$TMP/case"
  F="$TMP/case"
  mkdir -p "$F/state" "$F/dev" "$F/by-uuid" "$F/disk" "$F/mnt" "$F/receipts" "$F/lock" \
    "$F/archive/2019" "$F/svc/alpha/db" "$F/svc/beta"
  printf 'photo one\n' >"$F/archive/2019/one.jpg"
  printf 'photo two\n' >"$F/archive/two.jpg"
  (cd "$F/archive" && sha256sum 2019/one.jpg two.jpg) >"$F/archive.sha256"
  printf 'alpha dump\n' >"$F/svc/alpha/db/dump.sql"
  printf 'beta state\n' >"$F/svc/beta/state.json"
  : >"$F/dev/sdz1"
  ln -s "$F/dev/sdz1" "$F/by-uuid/$UUID"
  # shellcheck disable=SC2034 # assertions consume DEV through check/eval
  DEV="$(readlink -f "$F/dev/sdz1")"
  printf 'luks_uuid=%s\n' "$UUID" >"$F/disk/BROKKR-OFFLINE-DISK"
  printf 'not-a-real-passphrase\n' >"$F/keyfile"
  chmod 0600 "$F/keyfile"
  : >"$F/calls"
  cat >"$F/env" <<EOF
OFFLINE_LUKS_UUID=$UUID
OFFLINE_KEYFILE='$F/keyfile'
OFFLINE_ARCHIVE_SRC='$F/archive'
OFFLINE_ARCHIVE_MANIFEST='$F/archive.sha256'
OFFLINE_SERVICE_SOURCES='$F/svc/alpha:$F/svc/beta'
OFFLINE_MOUNT_POINT='$F/mnt'
BROKKR_OFFLINE_RECEIPT_DIR='$F/receipts'
BROKKR_OFFLINE_BY_UUID_DIR='$F/by-uuid'
BROKKR_OFFLINE_SMART_POLL_SECONDS=0
BROKKR_OFFLINE_LOCK_DIR='$F/lock'
EOF
  chmod 0600 "$F/env"
}

NOW=1793000000
run_rotation() {
  # shellcheck disable=SC2034 # assertions consume OUT/RC through check/eval
  OUT="$(env PATH="$TMP/bin:$PATH" MOCK_CALLS="$F/calls" MOCK_STATE="$F/state" \
    MOCK_DISK="$F/disk" MOCK_CS_UUID="${MOCK_CS_UUID:-$UUID}" \
    BROKKR_OFFLINE_ENV_FILE="${ENV_FILE:-$F/env}" BROKKR_OFFLINE_NOW_EPOCH="$NOW" \
    BROKKR_TEST_MARKER="$F/executed" \
    bash "$SCRIPT" "$@" </dev/null 2>&1)"
  # shellcheck disable=SC2034
  RC=$?
}
called() { grep -q -- "$1" "$F/calls"; }
not_called() { ! grep -q -- "$1" "$F/calls"; }
closed_cleanly() { [ ! -e "$F/state/open" ] && [ ! -e "$F/state/mounted" ] && [ -d "$F/disk" ]; }
dir_empty() { local listing; listing="$(ls -A "$1")" || return 1; [ -z "$listing" ]; }
no_receipts() {
  dir_empty "$F/receipts" || return 1
  [ -d "$F/disk" ] || return 1
  [ ! -e "$F/disk/receipts" ] || dir_empty "$F/disk/receipts"
}
completed() { [[ "$OUT" == *"offline rotation complete: safe to unplug"* ]]; }
first_index() { grep -n -- "$1" "$F/calls" | head -n 1 | cut -d: -f1; }

echo "offline-rotation.test.sh"

# ── happy path ──────────────────────────────────────────────────────────────
setup
run_rotation
check "rotation succeeds with valid config, keyfile and LUKS2 disk" '[ "$RC" -eq 0 ]'
check "success ends with the safe-to-unplug line" 'completed'
check "device is resolved through the LUKS UUID link" 'called "cryptsetup isLuks --type luks2 $DEV"'
check "LUKS UUID is re-read from the header" 'called "cryptsetup luksUUID $DEV"'
check "open requires LUKS2 and uses the keyfile" 'called "cryptsetup open --type luks2 --key-file=$F/keyfile $DEV brokkr-offline"'
check "mount uses the mapper with nodev,nosuid,noexec" 'called "mount -o nodev,nosuid,noexec /dev/mapper/brokkr-offline $F/mnt"'
check "archive copy never overwrites existing files" 'called "rsync -a --ignore-existing $F/archive/ $F/mnt/archive/"'
check "no rsync call carries a deletion flag" 'not_called "rsync .*--delete"'
check "archive copied to disk" '[ "$(cat "$F/disk/archive/2019/one.jpg")" = "photo one" ]'
check "archive manifest stored on disk" '[ -f "$F/disk/manifests/2026-10-26T073320Z-archive.sha256" ]'
check "service snapshots land in a dated tree" '[ -f "$F/disk/services/2026-10-26T073320Z/alpha/db/dump.sql" ] && [ -f "$F/disk/services/2026-10-26T073320Z/beta/state.json" ]'
check "service copy manifest stored on disk" '[ -s "$F/disk/manifests/2026-10-26T073320Z-services.sha256" ]'
check "every smartctl call uses -d sat on the parent disk" '! grep "^smartctl" "$F/calls" | grep -qv -- "-d sat .* /dev/sdz$"'
check "SMART short test was started" 'called "smartctl -d sat -t short /dev/sdz"'
check "disk receipt written" 'grep -qx "format=brokkr-offline-rotation-receipt-v1" "$F/disk/receipts/2026-10-26T073320Z.receipt"'
check "local receipt written with epoch" 'grep -qx "completed_epoch=$NOW" "$F/receipts/2026-10-26T073320Z.receipt"'
check "receipt counts verified archive files" 'grep -qx "archive_files_verified=2" "$F/receipts/2026-10-26T073320Z.receipt"'
check "receipt records SMART result" 'grep -qx "smart_short_test=passed" "$F/receipts/2026-10-26T073320Z.receipt"'
check "receipt names services, not their paths" 'grep -qx "services=alpha,beta" "$F/receipts/2026-10-26T073320Z.receipt"'
check "disk unmounted and closed" 'closed_cleanly'
check "umount precedes luksClose" '[ "$(first_index "^umount")" -lt "$(first_index "cryptsetup luksClose")" ]'
check "SMART test precedes receipt-free close" '[ "$(first_index "smartctl -d sat -t short")" -lt "$(first_index "^umount")" ]'
check "keyfile content is never printed" '[[ "$OUT" != *not-a-real-passphrase* ]]'

# ── second rotation reuses unchanged service files via --link-dest ─────────
NOW=1795000000
run_rotation
check "second rotation succeeds" '[ "$RC" -eq 0 ] && completed'
check "second rotation hard-links against the previous service tree" 'called "rsync -a --link-dest=$F/mnt/services/2026-10-26T073320Z/alpha $F/svc/alpha/ $F/mnt/services/.partial-2026-11-18T110640Z/alpha/"'
check "first rotation's service tree is kept" '[ -f "$F/disk/services/2026-10-26T073320Z/alpha/db/dump.sql" ]'
check "two local receipts exist" '[ "$(ls "$F/receipts" | grep -c "\.receipt$")" -eq 2 ]'
NOW=1793000000

# ── identity and encryption guards ─────────────────────────────────────────
setup
MOCK_CS_ISLUKS_RC=1 run_rotation
check "non-LUKS2 device is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"not LUKS2"* ]]'
check "non-LUKS2 device is never opened" 'not_called "cryptsetup open"'

setup
MOCK_CS_UUID=11111111-2222-4333-8444-555555555555 run_rotation
check "LUKS header UUID mismatch is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"UUID mismatch"* ]] && not_called "cryptsetup open"'

setup
rm "$F/by-uuid/$UUID"
run_rotation
check "absent disk is refused before cryptsetup" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"not attached"* ]] && not_called "cryptsetup"'

setup
sed -i.bak "s|^OFFLINE_LUKS_UUID=.*|OFFLINE_LUKS_UUID=/dev/sdb1|" "$F/env" && rm -f "$F/env.bak"
run_rotation
check "a device path instead of a UUID is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"OFFLINE_LUKS_UUID"* ]] && not_called "cryptsetup"'

setup
MOCK_CS_ACTIVE=1 run_rotation
check "an already-active mapping is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"already active"* ]]'
check "a foreign active mapping is neither opened nor closed" 'not_called "cryptsetup open" && not_called "cryptsetup luksClose"'

# ── passphrase sources ─────────────────────────────────────────────────────
setup
chmod 0644 "$F/keyfile"
run_rotation
check "group/world-readable keyfile is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"keyfile mode"* ]] && not_called "cryptsetup open"'

setup
mv "$F/keyfile" "$F/keyfile.real" && ln -s "$F/keyfile.real" "$F/keyfile"
run_rotation
check "symlinked keyfile is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"symlink"* ]] && not_called "cryptsetup open"'

setup
sed -i.bak '/^OFFLINE_KEYFILE=/d' "$F/env" && rm -f "$F/env.bak"
run_rotation
check "no keyfile and no terminal refuses instead of reading stdin" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"terminal"* ]] && not_called "cryptsetup open"'

# ── env-file rules ─────────────────────────────────────────────────────────
setup
printf 'touch "$BROKKR_TEST_MARKER"\n' >"$F/unsafe.env"
chmod 0644 "$F/unsafe.env"
ENV_FILE="$F/unsafe.env" run_rotation
check "group/world-readable env file is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"mode"* ]]'
check "unsafe env file is not executed" '[ ! -e "$F/executed" ]'

setup
printf 'touch "$BROKKR_TEST_MARKER"\n' >"$F/target.env"
chmod 0600 "$F/target.env"
ln -s "$F/target.env" "$F/link.env"
ENV_FILE="$F/link.env" run_rotation
check "symlinked env file is refused and not executed" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"symlink"* ]] && [ ! -e "$F/executed" ]'

setup
ENV_FILE="$F/missing.env" run_rotation
check "missing env file is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"env file"* ]] && not_called "cryptsetup"'

# ── manifest and source validation ─────────────────────────────────────────
setup
printf '%064d  /etc/passwd\n' 0 >>"$F/archive.sha256"
run_rotation
check "absolute manifest path is refused before opening" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"manifest"* ]] && not_called "cryptsetup"'

setup
printf '%064d  2019/../../escape\n' 0 >>"$F/archive.sha256"
run_rotation
check "parent-directory manifest path is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"manifest"* ]] && not_called "cryptsetup"'

setup
mkdir -p "$F/svc2/alpha"
sed -i.bak "s|^OFFLINE_SERVICE_SOURCES=.*|OFFLINE_SERVICE_SOURCES='$F/svc/alpha:$F/svc2/alpha'|" "$F/env" && rm -f "$F/env.bak"
run_rotation
check "duplicate service names are refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"duplicate"* ]] && not_called "cryptsetup"'

setup
: >"$F/mnt/leftover"
run_rotation
check "non-empty mount point is refused before opening" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"not empty"* ]] && not_called "cryptsetup open"'

setup
run_rotation --bogus
check "unknown argument is a usage error" '[ "$RC" -eq 64 ] && not_called "cryptsetup"'

# ── concurrency and time-of-check guards ───────────────────────────────────
setup
run_rotation
check "the run lock is released after a successful rotation" '[ "$RC" -eq 0 ] && dir_empty "$F/lock"'

setup
mkdir "$F/lock/brokkr-offline-rotation.lock"
run_rotation
check "a concurrent run holding the lock is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"another offline rotation"* ]]'
check "a refused concurrent run neither opens nor closes the mapping" 'not_called "cryptsetup open" && not_called "cryptsetup luksClose"'
check "a refused concurrent run leaves the other run's lock in place" '[ -d "$F/lock/brokkr-offline-rotation.lock" ]'

setup
MOCK_MKDIR_SIGNAL=1 run_rotation
check "a signal while taking the run lock cannot leave a stale lock" 'dir_empty "$F/lock" && closed_cleanly'

setup
printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -\n' >>"$F/archive.sha256"
run_rotation
check "a manifest entry naming stdin is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"manifest"* ]] && not_called "cryptsetup"'

setup
printf 'live secret\n' >"$F/live-secret"
cp "$F/archive.sha256" "$F/swapped.sha256"
sha256sum "$F/live-secret" >>"$F/swapped.sha256"
MOCK_RSYNC_SWAP_FROM="$F/swapped.sha256" MOCK_RSYNC_SWAP_TO="$F/archive.sha256" run_rotation
check "a manifest replaced mid-run is not the one verified" '! grep -qF "$F/live-secret" "$F/disk/manifests/2026-10-26T073320Z-archive.sha256"'
check "the validated manifest snapshot still verifies the archive" '[ "$RC" -eq 0 ] && grep -qx "archive_files_verified=2" "$F/receipts/2026-10-26T073320Z.receipt"'

if [ "$(id -u)" -ne 0 ]; then
  setup
  printf 'unreadable\n' >"$F/svc/alpha/a-unreadable"
  chmod 0000 "$F/svc/alpha/a-unreadable"
  run_rotation
  check "a service file that cannot be checksummed fails the rotation" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"checksum service source"* ]] && no_receipts'
  chmod 0600 "$F/svc/alpha/a-unreadable"
fi

# ── signals after open/mount run the cleanup path ──────────────────────────
for sig in HUP QUIT TERM INT; do
  for after in open mount; do
    setup
    MOCK_SIGNAL="$sig" MOCK_SIGNAL_AFTER="$after" run_rotation
    check "$sig after $after unmounts, closes and releases the lock" '[ "$RC" -ne 0 ] && closed_cleanly && dir_empty "$F/lock" && no_receipts && ! completed'
  done
done

# ── unknown state is never reported as safe ────────────────────────────────
setup
MOCK_MOUNTPOINT_ERR=1 run_rotation
check "a failing mount-point query refuses before opening" '[ "$RC" -ne 0 ] && not_called "cryptsetup open"'

setup
MOCK_CS_STATUS_ERR_AFTER_OPEN=1 MOCK_CS_CLOSE_RC=5 MOCK_RSYNC_RC=23 run_rotation
check "unknown mapping state after a failure says do NOT unplug" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"do NOT unplug"* ]] && [[ "$OUT" != *"(safe to unplug)"* ]]'

setup
MOCK_MOUNTPOINT_ERR_AFTER_MOUNT=1 MOCK_UMOUNT_RC=32 run_rotation
check "unknown mount state after a failure says do NOT unplug" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"do NOT unplug"* ]] && [[ "$OUT" != *"(safe to unplug)"* ]]'

setup
MOCK_MOUNTPOINT_ERR_AFTER_MOUNT=1 run_rotation
check "an unknown mount state is still unmounted and closed when that succeeds" '[ "$RC" -ne 0 ] && closed_cleanly && no_receipts'

# ── layout directories must be real directories on the backup filesystem ───
for layout in archive manifests services receipts; do
  setup
  mkdir -p "$F/host-$layout"
  ln -s "$F/host-$layout" "$F/disk/$layout"
  run_rotation
  check "a symlinked $layout directory on the disk is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"$layout"* ]] && no_receipts && closed_cleanly'
  check "nothing is written through a symlinked $layout directory" 'dir_empty "$F/host-$layout"'
done

setup
: >"$F/disk/services"
run_rotation
check "a regular file in place of a layout directory is refused" '[ "$RC" -ne 0 ] && no_receipts && closed_cleanly'

# ── service verification never follows links ───────────────────────────────
setup
MOCK_RSYNC_LINKIFY=db/dump.sql run_rotation
check "a service file swapped for a symlink before the copy fails verification" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"service snapshot verification failed"* ]] && no_receipts && closed_cleanly'

# ── failures after opening still close the disk and write no receipt ───────
setup
rm "$F/disk/BROKKR-OFFLINE-DISK"
run_rotation
check "unprepared filesystem is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"marker"* ]] && not_called "^rsync"'
check "unprepared filesystem is unmounted and closed" 'closed_cleanly'

setup
MOCK_RSYNC_CORRUPT=two.jpg run_rotation
check "archive checksum mismatch fails the rotation" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"verification failed"* ]] && ! completed'
check "checksum failure writes no receipt" 'no_receipts'
check "checksum failure still closes the disk" 'closed_cleanly && [[ "$OUT" == *"FAILED"* ]]'

setup
mkdir -p "$F/disk/archive"
printf 'tampered\n' >"$F/disk/archive/two.jpg"
run_rotation
check "a differing copy already on disk is not overwritten" '[ "$(cat "$F/disk/archive/two.jpg")" = "tampered" ]'
check "the differing copy fails verification" '[ "$RC" -ne 0 ] && no_receipts'

setup
mv "$F/archive/two.jpg" "$F/live-two.jpg"
ln -s "$F/live-two.jpg" "$F/archive/two.jpg"
run_rotation
check "a symlink in the archive cannot satisfy verification from live data" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"symlink"* ]] && no_receipts && closed_cleanly'

setup
mkdir "$F/live-2019" && mv "$F/archive/2019/one.jpg" "$F/live-2019/" && rmdir "$F/archive/2019"
ln -s "$F/live-2019" "$F/archive/2019"
run_rotation
check "a symlinked archive directory is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"symlink"* ]] && no_receipts'

setup
MOCK_CS_OPEN_LEAK=1 run_rotation
check "a mapping that appears despite a failed open is still closed" '[ "$RC" -ne 0 ] && closed_cleanly && no_receipts'

setup
MOCK_MOUNT_LEAK=1 run_rotation
check "a mount that appears despite a failed mount is still unmounted and closed" '[ "$RC" -ne 0 ] && closed_cleanly && no_receipts'

setup
MOCK_SMART_CMD_FAIL=-l run_rotation
check "a failed self-test-log query is not trusted even with passing output" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"SMART"* ]] && no_receipts'

setup
MOCK_SMART_CMD_FAIL=-H run_rotation
check "a failed health query is not trusted even with PASSED output" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"SMART"* ]] && no_receipts'

setup
MOCK_RSYNC_RC=23 run_rotation
check "rsync failure fails the rotation and closes the disk" '[ "$RC" -ne 0 ] && no_receipts && closed_cleanly'

setup
MOCK_SMART_RESULT=fail run_rotation
check "failed SMART short test fails the rotation" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"SMART"* ]] && no_receipts && closed_cleanly'

setup
MOCK_SMART_PROGRESS_POLLS=0 run_rotation
check "a short test never seen running is not trusted" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"SMART"* ]] && no_receipts'

setup
MOCK_SMART_HEALTH=FAILED run_rotation
check "failed SMART overall health fails the rotation" '[ "$RC" -ne 0 ] && no_receipts && closed_cleanly'

setup
MOCK_UMOUNT_RC=32 run_rotation
check "unmount failure is not reported as safe" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"do NOT unplug"* ]] && ! completed'
check "unmount failure writes no local receipt" '[ -z "$(ls -A "$F/receipts")" ]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
