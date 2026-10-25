#!/usr/bin/env bash
# Hermetic tests for the offline rotation disk format ceremony helper. Every disk tool
# (wipefs, parted, udevadm, lsblk, cryptsetup, mkfs.ext4, mount, umount, mountpoint) is
# a PATH mock; the "disk" and "partition" are regular files. No real device is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../offline-rotation-format.sh"
# Every fixture path is built under $TMP, so stop before anything else if it is unusable.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-offline-format-test.XXXXXX")" || exit 1
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "cannot create test workspace" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2034 # assertions consume UUID through check/eval
UUID=0f1e2d3c-4b5a-4968-8776-655443322110
DISK_NAME=usb-Example_Disk_0001-0:0
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$TMP/bin"

# lsblk mock. MOCK_LSBLK_FAIL=<column list> prints plausible output but exits 1, and
# MOCK_LSBLK_EMPTY=<column list> prints nothing. MOCK_DURING_CONFIRM changes the world
# while the operator is at the ERASE prompt (the SIZE,MODEL query is shown just
# before it): unplug | reuse | mount | ident.
cat >"$TMP/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
printf 'lsblk %s\n' "$*" >>"$MOCK_CALLS"
[ ! -e "$MOCK_STATE/lsblk-fail" ] || exit 1
cols="$2"
[ "${MOCK_LSBLK_EMPTY:-}" != "$cols" ] || exit 0
case "$cols" in
  TYPE) echo "${MOCK_LSBLK_TYPE:-disk}" ;;
  TRAN) echo "${MOCK_LSBLK_TRAN:-usb}" ;;
  PKNAME) echo "${MOCK_LSBLK_PKNAME:-sdz}" ;;
  MAJ:MIN,SIZE,SERIAL) echo "8:208 1000204886016 $(cat "$MOCK_STATE/serial" 2>/dev/null || echo SERIAL0001)" ;;
  SIZE,MODEL)
    echo '931.5G Example Disk'
    case "${MOCK_DURING_CONFIRM:-}" in
      unplug) rm -f "$MOCK_BY_ID/$MOCK_DISK_NAME" ;;
      reuse) : >"$MOCK_DEV/sdq"; rm -f "$MOCK_BY_ID/$MOCK_DISK_NAME"; ln -s "$MOCK_DEV/sdq" "$MOCK_BY_ID/$MOCK_DISK_NAME" ;;
      mount) echo 'sdz1 part /media/automount' >"$MOCK_STATE/child" ;;
      ident) echo SERIAL9999 >"$MOCK_STATE/serial" ;;
    esac ;;
  NAME,TYPE,MOUNTPOINT)
    echo 'sdz disk '
    if [ -n "${MOCK_LSBLK_CHILD:-}" ]; then echo "$MOCK_LSBLK_CHILD"; fi
    if [ -f "$MOCK_STATE/child" ]; then cat "$MOCK_STATE/child"; fi ;;
  *) exit 64 ;;
esac
[ "${MOCK_LSBLK_FAIL:-}" != "$cols" ] || exit 1
MOCK

cat >"$TMP/bin/wipefs" <<'MOCK'
#!/usr/bin/env bash
printf 'wipefs %s\n' "$*" >>"$MOCK_CALLS"
# MOCK_AFTER_WIPEFS=ident: the device's identity changes between stages.
if [ "${MOCK_AFTER_WIPEFS:-}" = ident ]; then echo SERIAL9999 >"$MOCK_STATE/serial"; fi
MOCK

cat >"$TMP/bin/parted" <<'MOCK'
#!/usr/bin/env bash
printf 'parted %s\n' "$*" >>"$MOCK_CALLS"
if [ "${MOCK_PARTED_NO_PART:-}" != 1 ]; then
  : >"$MOCK_DEV/sdz1"
  ln -s "$MOCK_DEV/sdz1" "$MOCK_BY_ID/$MOCK_DISK_NAME-part1"
fi
# MOCK_AFTER_PARTED=ident|holder: late changes after partitioning.
case "${MOCK_AFTER_PARTED:-}" in
  ident) echo SERIAL9999 >"$MOCK_STATE/serial" ;;
  holder) echo 'md0 raid1 ' >"$MOCK_STATE/child" ;;
esac
MOCK

cat >"$TMP/bin/udevadm" <<'MOCK'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"$MOCK_CALLS"
MOCK

cat >"$TMP/bin/cryptsetup" <<'MOCK'
#!/usr/bin/env bash
printf 'cryptsetup %s\n' "$*" >>"$MOCK_CALLS"
case "$1" in
  luksFormat) exit "${MOCK_CS_FORMAT_RC:-0}" ;;
  isLuks) exit 0 ;;
  luksUUID)
    # MOCK_CS_UUID_LATER: the header changes after the first read (the backing check).
    n=$(cat "$MOCK_STATE/uuid-reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$MOCK_STATE/uuid-reads"
    if [ -n "${MOCK_CS_UUID_LATER:-}" ] && [ "$n" -gt 1 ]; then
      echo "$MOCK_CS_UUID_LATER"
    else
      echo "${MOCK_CS_UUID:-0f1e2d3c-4b5a-4968-8776-655443322110}"
    fi ;;
  luksHeaderBackup)
    prev=""
    for arg in "$@"; do
      if [ "$prev" = --header-backup-file ]; then printf 'header\n' >"$arg"; fi
      prev="$arg"
    done ;;
  status)
    if [ "${MOCK_CS_ACTIVE:-}" = 1 ]; then echo '  device:  /dev/other1'; exit 0; fi
    [ -e "$MOCK_STATE/open" ] || exit 4
    echo '  type:    LUKS2'
    echo "  device:  ${MOCK_CS_STATUS_DEVICE:-$(cat "$MOCK_STATE/open")}" ;;
  open)
    [ "${MOCK_CS_OPEN_RC:-0}" = 0 ] || exit "$MOCK_CS_OPEN_RC"
    for arg in "$@"; do
      case "$arg" in --key-file=*) cat "${arg#--key-file=}" >/dev/null || exit 2 ;; esac
    done
    dev="${*: -2:1}"
    printf '%s\n' "$dev" >"$MOCK_STATE/open"
    # MOCK_AFTER_OPEN=mount|ident|query: late changes after the mapping is open.
    case "${MOCK_AFTER_OPEN:-}" in
      mount) echo 'sdz1 part /media/automount' >"$MOCK_STATE/child" ;;
      ident) echo SERIAL9999 >"$MOCK_STATE/serial" ;;
      query) : >"$MOCK_STATE/lsblk-fail" ;;
    esac
    if [ "${MOCK_SIGNAL_AFTER:-}" = open ]; then kill -"$MOCK_SIGNAL" "$PPID"; fi ;;
  luksClose)
    [ ! -e "$MOCK_STATE/mounted" ] || exit 5
    rm -f "$MOCK_STATE/open" ;;
  *) exit 64 ;;
esac
MOCK

cat >"$TMP/bin/mkfs.ext4" <<'MOCK'
#!/usr/bin/env bash
printf 'mkfs.ext4 %s\n' "$*" >>"$MOCK_CALLS"
MOCK

cat >"$TMP/bin/mount" <<'MOCK'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$MOCK_CALLS"
mnt="${!#}"
[ -e "$MOCK_STATE/open" ] || exit 32
rmdir "$mnt" && mv "$MOCK_DISK" "$mnt" && printf '%s\n' "$mnt" >"$MOCK_STATE/mounted"
if [ "${MOCK_SIGNAL_AFTER:-}" = mount ]; then kill -"$MOCK_SIGNAL" "$PPID"; fi
MOCK

cat >"$TMP/bin/umount" <<'MOCK'
#!/usr/bin/env bash
printf 'umount %s\n' "$*" >>"$MOCK_CALLS"
[ -e "$MOCK_STATE/mounted" ] || exit 32
mv "$1" "$MOCK_DISK" && mkdir "$1" && rm -f "$MOCK_STATE/mounted"
MOCK

cat >"$TMP/bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = -q ] && shift
if [ -e "$MOCK_STATE/mounted" ] && [ "$(cat "$MOCK_STATE/mounted")" = "$1" ]; then exit 0; fi
exit 32
MOCK
chmod +x "$TMP/bin/"*

setup() {
  rm -rf "$TMP/case"
  F="$TMP/case"
  mkdir -p "$F/state" "$F/dev" "$F/by-id" "$F/disk" "$F/mnt" "$F/lock" "$F/out"
  : >"$F/dev/sdz"
  ln -s "$F/dev/sdz" "$F/by-id/$DISK_NAME"
  printf 'not-a-real-passphrase\n' >"$F/keyfile"
  chmod 0600 "$F/keyfile"
  : >"$F/calls"
  # shellcheck disable=SC2034 # assertions consume PART through check/eval
  PART="$(cd "$F/dev" && pwd -P)/sdz1"
  # shellcheck disable=SC2034
  DISK="$(cd "$F/dev" && pwd -P)/sdz"
}

run_format() {
  # shellcheck disable=SC2034 # assertions consume OUT/RC through check/eval
  OUT="$(printf '%s\n' "${ANSWER-ERASE}" | env PATH="$TMP/bin:$PATH" MOCK_CALLS="$F/calls" \
    MOCK_STATE="$F/state" MOCK_DISK="$F/disk" MOCK_DEV="$F/dev" MOCK_BY_ID="$F/by-id" \
    MOCK_DISK_NAME="$DISK_NAME" BROKKR_OFFLINE_BY_ID_DIR="$F/by-id" \
    BROKKR_OFFLINE_LOCK_DIR="$F/lock" OFFLINE_MOUNT_POINT="$F/mnt" \
    BROKKR_OFFLINE_SETTLE_SECONDS=0 bash "$SCRIPT" "$@" 2>&1)"
  # shellcheck disable=SC2034
  RC=$?
}
default_args() {
  run_format --i-understand-this-erases "$F/by-id/$DISK_NAME" \
    --header-backup "$F/out/header.img" --key-file "$F/keyfile"
}
called() { grep -q -- "$1" "$F/calls"; }
not_called() { ! grep -q -- "$1" "$F/calls"; }
first_index() { grep -n -- "$1" "$F/calls" | head -n 1 | cut -d: -f1; }
# Line of the first mapping-status query after the open (not the preflight one).
status_after_open() {
  awk '/^cryptsetup open/ { o = NR } /^cryptsetup status brokkr-offline/ && o && !s { s = NR } END { print s + 0 }' "$F/calls"
}
closed_cleanly() { [ ! -e "$F/state/open" ] && [ ! -e "$F/state/mounted" ] && [ -d "$F/disk" ]; }
lock_free() { [ -z "$(ls -A "$F/lock")" ]; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "offline-rotation-format.test.sh"

# ── happy path ──────────────────────────────────────────────────────────────
setup
default_args
check "format succeeds on a confirmed USB whole disk" '[ "$RC" -eq 0 ]'
check "the disk is wiped and partitioned by its resolved device" 'called "wipefs --all $DISK" && called "parted --script $DISK mklabel gpt mkpart brokkr-offline 1MiB 100%"'
check "LUKS2 is formatted on the new partition" 'called "cryptsetup luksFormat --type luks2 --batch-mode --key-file=$F/keyfile $PART"'
check "the mapping is opened from the formatted partition" 'called "cryptsetup open --type luks2 --key-file=$F/keyfile $PART brokkr-offline"'
check "the mapping backing device is checked after open and before mkfs" 's="$(status_after_open)"; [ "$s" -gt 0 ] && [ "$s" -lt "$(first_index "^mkfs.ext4")" ] && [ "$(grep -n "cryptsetup luksUUID" "$F/calls" | tail -n 1 | cut -d: -f1)" -lt "$(first_index "^mkfs.ext4")" ]'
check "the disk identity is re-checked after confirmation and before each stage" '[ "$(grep -c "MAJ:MIN,SIZE,SERIAL" "$F/calls")" -ge 5 ]'
check "mkfs targets only the mapper device" 'called "mkfs.ext4 -q -L brokkr-offline -m 0 /dev/mapper/brokkr-offline" && [ "$(grep -c "^mkfs.ext4" "$F/calls")" -eq 1 ]'
check "the marker records the LUKS UUID" 'grep -qx "luks_uuid=$UUID" "$F/disk/BROKKR-OFFLINE-DISK"'
check "the disk layout is created" '[ -d "$F/disk/archive" ] && [ -d "$F/disk/manifests" ] && [ -d "$F/disk/services" ] && [ -d "$F/disk/receipts" ]'
check "the header backup is written owner-only" '[ -f "$F/out/header.img" ] && [ "$(file_mode "$F/out/header.img")" = 600 ]'
check "the LUKS UUID to record is printed" '[[ "$OUT" == *"OFFLINE_LUKS_UUID=$UUID"* ]]'
check "the disk ends unmounted and closed with the lock released" 'closed_cleanly && lock_free'
check "the keyfile content is never printed" '[[ "$OUT" != *not-a-real-passphrase* ]]'

# ── refusals before anything is written ─────────────────────────────────────
setup
run_format "$F/by-id/$DISK_NAME" --header-backup "$F/out/header.img" --key-file "$F/keyfile"
check "the explicit erase flag is required" '[ "$RC" -eq 64 ] && not_called "wipefs"'

setup
run_format --i-understand-this-erases "$F/dev/sdz" --header-backup "$F/out/header.img" --key-file "$F/keyfile"
check "a /dev/sdX path is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"by-id"* ]] && not_called "wipefs"'

setup
: >"$F/dev/sdz9"; ln -s "$F/dev/sdz9" "$F/by-id/$DISK_NAME-part9"
run_format --i-understand-this-erases "$F/by-id/$DISK_NAME-part9" --header-backup "$F/out/header.img" --key-file "$F/keyfile"
check "a partition path is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"whole disk"* ]] && not_called "wipefs"'

setup
MOCK_LSBLK_TRAN=sata default_args
check "a non-USB disk is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"USB"* ]] && not_called "wipefs"'

setup
MOCK_LSBLK_TYPE=part default_args
check "a device lsblk does not call a disk is refused" '[ "$RC" -ne 0 ] && not_called "wipefs"'

setup
MOCK_LSBLK_CHILD='sdz1 part /media/photos' default_args
check "a disk with a mounted partition is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"mounted"* ]] && not_called "wipefs"'

setup
MOCK_LSBLK_CHILD='luks-old crypt ' default_args
check "a disk with an active holder is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"holder"* ]] && not_called "wipefs"'

setup
MOCK_CS_ACTIVE=1 default_args
check "an already-active mapping is refused before wiping" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"already active"* ]] && not_called "wipefs"'
check "an already-active mapping is never formatted or closed" 'not_called "^mkfs.ext4" && not_called "cryptsetup luksClose"'

setup
ANSWER=yes default_args
check "anything but ERASE at the prompt aborts" '[ "$RC" -ne 0 ] && not_called "wipefs"'

setup
: >"$F/out/header.img"
default_args
check "an existing header-backup path is never overwritten" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"header"* ]] && not_called "wipefs"'

setup
chmod 0644 "$F/keyfile"
default_args
check "an unsafe keyfile is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"keyfile"* ]] && not_called "wipefs"'

setup
run_format --i-understand-this-erases "$F/by-id/$DISK_NAME" --header-backup "$F/out/header.img"
check "no keyfile and no terminal refuses before wiping" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"terminal"* ]] && not_called "wipefs"'

setup
mkdir "$F/lock/brokkr-offline-rotation.lock"
default_args
check "a held rotation lock refuses the format" '[ "$RC" -ne 0 ] && not_called "wipefs" && [ -d "$F/lock/brokkr-offline-rotation.lock" ]'

# ── the world changing during confirmation or between stages ───────────────
for change in unplug reuse mount ident; do
  setup
  MOCK_DURING_CONFIRM="$change" default_args
  check "a disk $change during confirmation is refused before wiping" '[ "$RC" -ne 0 ] && not_called "wipefs" && lock_free'
done

setup
MOCK_AFTER_WIPEFS=ident default_args
check "an identity change between wipefs and parted stops before parted" '[ "$RC" -ne 0 ] && called "wipefs" && not_called "^parted"'

for late in ident holder; do
  setup
  MOCK_AFTER_PARTED="$late" default_args
  check "a late $late change after partitioning stops before luksFormat" '[ "$RC" -ne 0 ] && not_called "luksFormat" && lock_free'
done

for late in mount ident query; do
  setup
  MOCK_AFTER_OPEN="$late" default_args
  check "a late $late change after open stops before mkfs and closes the mapping" '[ "$RC" -ne 0 ] && not_called "^mkfs.ext4" && closed_cleanly && lock_free'
done

# ── identification must succeed and be complete ────────────────────────────
for cols in TYPE TRAN MAJ:MIN,SIZE,SERIAL SIZE,MODEL NAME,TYPE,MOUNTPOINT; do
  setup
  MOCK_LSBLK_FAIL="$cols" default_args
  check "a failing lsblk $cols query is refused before wiping" '[ "$RC" -ne 0 ] && not_called "wipefs"'
  setup
  MOCK_LSBLK_EMPTY="$cols" default_args
  check "empty lsblk $cols output is refused before wiping" '[ "$RC" -ne 0 ] && not_called "wipefs"'
done

setup
MOCK_LSBLK_FAIL=PKNAME default_args
check "a failing partition-parent query stops before luksFormat" '[ "$RC" -ne 0 ] && not_called "luksFormat"'

setup
MOCK_LSBLK_TRAN=nvme MOCK_LSBLK_CHILD='nvme0n1p2 part /' default_args
check "a system disk is refused" '[ "$RC" -ne 0 ] && not_called "wipefs"'

setup
MOCK_LSBLK_CHILD='sdz2 part [SWAP]' default_args
check "a disk with active swap is refused" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"mounted"* ]] && not_called "wipefs"'

# ── signals after open or mount still close the disk ───────────────────────
for sig in HUP INT QUIT TERM; do
  for after in open mount; do
    setup
    MOCK_SIGNAL="$sig" MOCK_SIGNAL_AFTER="$after" default_args
    check "$sig after $after closes the disk and releases the lock" '[ "$RC" -ne 0 ] && closed_cleanly && lock_free && [[ "$OUT" != *"OFFLINE_LUKS_UUID="* ]]'
  done
done

# ── failures after wiping never reach mkfs on the wrong device ─────────────
setup
MOCK_PARTED_NO_PART=1 default_args
check "a missing new partition stops before luksFormat" '[ "$RC" -ne 0 ] && not_called "luksFormat" && not_called "^mkfs.ext4"'

setup
MOCK_LSBLK_PKNAME=sdy default_args
check "a partition whose parent is another disk stops before luksFormat" '[ "$RC" -ne 0 ] && not_called "luksFormat"'

setup
MOCK_CS_FORMAT_RC=1 default_args
check "a failed luksFormat stops before open and mkfs" '[ "$RC" -ne 0 ] && not_called "cryptsetup open" && not_called "^mkfs.ext4"'

setup
MOCK_CS_OPEN_RC=5 default_args
check "a failed open never reaches mkfs" '[ "$RC" -ne 0 ] && not_called "^mkfs.ext4" && lock_free'

setup
MOCK_CS_STATUS_DEVICE=/dev/other1 default_args
check "a mapping backed by another device is never formatted" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"backed by"* ]] && not_called "^mkfs.ext4"'
check "a foreign-backed mapping is left for inspection, not closed" 'not_called "cryptsetup luksClose" && [[ "$OUT" == *"do NOT unplug"* ]]'

setup
MOCK_CS_UUID_LATER=11111111-2222-4333-8444-555555555555 default_args
check "a backing device with another LUKS UUID is never formatted" '[ "$RC" -ne 0 ] && [[ "$OUT" == *"backed by LUKS UUID"* ]] && not_called "^mkfs.ext4"'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
