#!/usr/bin/env bash
# Brokkr · offline rotation disk — copy, verify and close a LUKS2 USB backup disk.
#
# Run on the control node, owner-attended, while the rotation disk is attached:
#   sudo ./scripts/offline-rotation.sh
# See docs/offline-rotation.md for the one-time format ceremony, the rotation routine
# and restore steps. The disk spends the rest of its life disconnected in a safe, so it
# is the one copy that ransomware or a sync error cannot reach.
#
# Safety contract:
#   • The disk is identified only by its LUKS UUID (never /dev/sdX). The header must be
#     LUKS2 and report that same UUID, and the filesystem must carry the marker written
#     at the format ceremony, before anything is copied.
#   • The passphrase comes from cryptsetup's own terminal prompt or from an owner-only
#     keyfile named in the env file. This script never reads, stores or prints it.
#   • Nothing is ever deleted. The archive is copied with --ignore-existing, so a
#     changed or encrypted source file cannot overwrite a good copy on the disk; the
#     sha256 check then fails loudly instead. Service snapshots go to a new dated tree
#     (hard-linked against the previous one) and are verified against a manifest built
#     from the source.
#   • A receipt is written only after copy, checksum and SMART checks all pass. The
#     local receipt (read by offline-rotation-freshness.sh) is written only after the
#     disk is unmounted and closed. "safe to unplug" is printed only once it is closed.
#
# Config comes from a private env file (default /etc/brokkr/offline-rotation.env; see
# offline-rotation.env.example). Exit: 0 = rotation complete, 64 = usage, other = failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/private-env.sh
. "$HERE/lib/private-env.sh"
# shellcheck source=scripts/lib/offline-disk.sh
. "$HERE/lib/offline-disk.sh"

MAPPER=brokkr-offline
MARKER=BROKKR-OFFLINE-DISK
RECEIPT_FORMAT=brokkr-offline-rotation-receipt-v1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# A hung-up terminal makes writes fail; logging must never abort cleanup.
log() { echo "$(ts) $*" >&2 || true; }
die() { log "ERROR: $*"; exit 1; }

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
  *) echo "usage: $0" >&2; exit 64 ;;
esac

# ---- Config ------------------------------------------------------------------
ENV_FILE="${BROKKR_OFFLINE_ENV_FILE:-/etc/brokkr/offline-rotation.env}"
brokkr_source_private_env "$ENV_FILE" || die "refusing to run without a valid private env file"

UUID="$(printf '%s' "${OFFLINE_LUKS_UUID:-}" | tr '[:upper:]' '[:lower:]')"
KEYFILE="${OFFLINE_KEYFILE:-}"
ARCHIVE_SRC="${OFFLINE_ARCHIVE_SRC:-}"
MANIFEST="${OFFLINE_ARCHIVE_MANIFEST:-}"
SERVICE_SOURCES="${OFFLINE_SERVICE_SOURCES:-}"
MNT="${OFFLINE_MOUNT_POINT:-/mnt/brokkr-offline}"
RECEIPT_DIR="${BROKKR_OFFLINE_RECEIPT_DIR:-/var/lib/brokkr/offline-rotation/receipts}"
BY_UUID_DIR="${BROKKR_OFFLINE_BY_UUID_DIR:-/dev/disk/by-uuid}"
SMART_POLL="${BROKKR_OFFLINE_SMART_POLL_SECONDS:-20}"
SMART_TIMEOUT="${BROKKR_OFFLINE_SMART_TIMEOUT_SECONDS:-1200}"
NOW="${BROKKR_OFFLINE_NOW_EPOCH:-$(date +%s)}"

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "$UUID" =~ $uuid_re ]] \
  || die "OFFLINE_LUKS_UUID must be the disk's LUKS UUID (8-4-4-4-12 hex), never a /dev path"
case "$SMART_POLL" in ''|*[!0-9]*) die "invalid BROKKR_OFFLINE_SMART_POLL_SECONDS" ;; esac
case "$SMART_TIMEOUT" in ''|*[!0-9]*|0) die "invalid BROKKR_OFFLINE_SMART_TIMEOUT_SECONDS" ;; esac
case "$NOW" in ''|*[!0-9]*) die "invalid BROKKR_OFFLINE_NOW_EPOCH" ;; esac
STAMP="$(date -u -d "@$NOW" +%Y-%m-%dT%H%M%SZ 2>/dev/null || date -u -r "$NOW" +%Y-%m-%dT%H%M%SZ)"

for tool in cryptsetup mount umount mountpoint lsblk smartctl rsync sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

[ -n "$ARCHIVE_SRC" ] && [ -d "$ARCHIVE_SRC" ] || die "OFFLINE_ARCHIVE_SRC is not a directory: ${ARCHIVE_SRC:-unset}"
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || die "OFFLINE_ARCHIVE_MANIFEST is not a file: ${MANIFEST:-unset}"

# ---- One run at a time ---------------------------------------------------------
# The lock makes "the mapping was inactive at preflight" mean "any mapping this run
# later finds is its own". mkdir is atomic; a lock left by a crash is removed by hand.
LOCK="${BROKKR_OFFLINE_LOCK_DIR:-/run/lock}/brokkr-offline-rotation.lock"
HELD_LOCK=0
MANIFEST_SNAPSHOT=""
release_local() {
  [ -z "$MANIFEST_SNAPSHOT" ] || rm -f "$MANIFEST_SNAPSHOT"
  if [ "$HELD_LOCK" = 1 ]; then rmdir "$LOCK" 2>/dev/null || log "WARN: cannot remove lock $LOCK"; fi
  HELD_LOCK=0
}
trap release_local EXIT
# Every catchable terminating signal exits through the EXIT trap (and so through
# cleanup). They are ignored between creating the lock and recording ownership, so a
# signal in that window cannot exit with the lock created but HELD_LOCK still 0.
on_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 131' QUIT; trap 'exit 143' TERM; }
trap '' HUP INT QUIT TERM
if mkdir "$LOCK" 2>/dev/null; then HELD_LOCK=1; fi
on_signals
[ "$HELD_LOCK" = 1 ] \
  || die "another offline rotation holds $LOCK; if none is running, remove it by hand"

# Validate a private snapshot of the manifest and verify against that same snapshot
# later, so a manifest replaced during the hours-long copy is never used unchecked.
# Every line must be "<sha256>  <relative path>": no absolute path, no '..' component
# and not '-' (stdin), so `sha256sum -c` can only ever read inside the copied archive.
MANIFEST_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/brokkr-offline-manifest.XXXXXX")" \
  || die "cannot create a private manifest snapshot"
cp "$MANIFEST" "$MANIFEST_SNAPSHOT" || die "cannot snapshot the archive manifest: $MANIFEST"
ARCHIVE_COUNT="$(awk '
  { line = $0 }
  line !~ /^[0-9a-f]{64} [ *]./ { bad = 1; exit }
  { path = substr(line, 67) }
  path == "-" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ { bad = 1; exit }
  { n++ }
  END { if (bad || n == 0) print "bad"; else print n }
' "$MANIFEST_SNAPSHOT")"
[ "$ARCHIVE_COUNT" != bad ] \
  || die "archive manifest has an empty, malformed, absolute, '..' or '-' entry: $MANIFEST"

SERVICE_DIRS=()
SERVICE_NAMES=()
if [ -n "$SERVICE_SOURCES" ]; then
  IFS=: read -r -a SERVICE_DIRS <<<"$SERVICE_SOURCES"
  for dir in "${SERVICE_DIRS[@]}"; do
    case "$dir" in /*) ;; *) die "service source must be an absolute path: $dir" ;; esac
    [ -d "$dir" ] || die "service source is not a directory: $dir"
    name="$(basename "$dir")"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "service source name is unsafe: $name"
    for seen in ${SERVICE_NAMES[@]+"${SERVICE_NAMES[@]}"}; do
      [ "$seen" != "$name" ] || die "duplicate service source name: $name"
    done
    SERVICE_NAMES+=("$name")
  done
fi

KEY_ARGS=()
if [ -n "$KEYFILE" ]; then
  if ! brokkr_private_file_ok "$KEYFILE" keyfile; then
    die "refusing an unsafe keyfile"
  fi
  KEY_ARGS=("--key-file=$KEYFILE")
elif [ ! -t 0 ]; then
  # Without a keyfile cryptsetup would read the passphrase from whatever stdin is.
  die "no OFFLINE_KEYFILE and stdin is not a terminal for the passphrase prompt"
fi

[ -d "$MNT" ] || die "mount point is not a directory: $MNT"
case "$(mount_state "$MNT")" in
  unmounted) ;;
  mounted) die "mount point is already in use: $MNT" ;;
  *) die "cannot determine whether $MNT is a mount point" ;;
esac
[ -z "$(ls -A "$MNT")" ] || die "mount point is not empty: $MNT"

# ---- Identify the disk by LUKS UUID -----------------------------------------
LINK="$BY_UUID_DIR/$UUID"
[ -e "$LINK" ] || die "rotation disk with LUKS UUID $UUID is not attached"
DEV="$(readlink -f "$LINK")" || die "cannot resolve $LINK"
cryptsetup isLuks --type luks2 "$DEV" || die "device for UUID $UUID is not LUKS2 — refusing"
HEADER_UUID="$(cryptsetup luksUUID "$DEV" | tr '[:upper:]' '[:lower:]')" \
  || die "cannot read the LUKS UUID from $DEV"
[ "$HEADER_UUID" = "$UUID" ] || die "LUKS UUID mismatch on $DEV: header reports '$HEADER_UUID'"
case "$(map_state "$MAPPER")" in
  inactive) ;;
  active) die "mapping $MAPPER is already active; close it deliberately before rotating" ;;
  *) die "cannot determine whether mapping $MAPPER is active" ;;
esac
PARENT="$(lsblk -ndo PKNAME "$DEV" 2>/dev/null | head -n 1 || true)"
if [ -n "$PARENT" ]; then SMART_DEV="/dev/$PARENT"; else SMART_DEV="$DEV"; fi

# ---- Open, mount, and always close on the way out ---------------------------
# Cleanup reads live state rather than flags set after each command: a signal can
# land after `cryptsetup open` or `mount` succeeds but before a flag is recorded.
# Under the run lock, the preflight proved the mapping inactive and the mount point
# unused, so once an attempt was made, an active mapping or mount there is this run's.
OPEN_ATTEMPTED=0
MOUNT_ATTEMPTED=0
COMPLETE=0
# The disk counts as closed only when unmount and close are confirmed: by the probe
# reporting unmounted/inactive, or by umount/luksClose succeeding. An unknown probe
# result triggers the close attempt and, if that fails, the do-NOT-unplug message.
finish() {
  local rc=$? unmounted=1 closed=1
  set +e
  trap - EXIT
  trap '' HUP INT QUIT TERM
  if [ "$COMPLETE" = 1 ]; then release_local; exit 0; fi
  if [ "$MOUNT_ATTEMPTED" = 1 ] && [ "$(mount_state "$MNT")" != unmounted ]; then
    sync
    umount "$MNT" || unmounted=0
  fi
  if [ "$OPEN_ATTEMPTED" = 1 ]; then
    if [ "$unmounted" = 0 ]; then
      closed=0
    elif [ "$(map_state "$MAPPER")" != inactive ]; then
      cryptsetup luksClose "$MAPPER" || closed=0
    fi
  fi
  if [ "$unmounted" = 0 ] || [ "$closed" = 0 ]; then
    log "offline rotation FAILED and the disk may still be open — do NOT unplug; unmount $MNT and luksClose $MAPPER by hand"
  elif [ "$rc" -ne 0 ]; then
    log "offline rotation FAILED; disk unmounted and closed (safe to unplug), but no valid receipt was recorded"
  fi
  release_local
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}
trap finish EXIT
on_signals

log "opening LUKS2 disk $UUID (${KEYFILE:+keyfile}${KEYFILE:-terminal prompt})"
OPEN_ATTEMPTED=1
cryptsetup open --type luks2 ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DEV" "$MAPPER" || die "cryptsetup open failed"
MOUNT_ATTEMPTED=1
mount -o nodev,nosuid,noexec "/dev/mapper/$MAPPER" "$MNT" || die "mount failed"
[ "$(mount_state "$MNT")" = mounted ] || die "$MNT is not confirmed as a mount point after mounting"
[ -f "$MNT/$MARKER" ] && [ ! -L "$MNT/$MARKER" ] && grep -qxF "luks_uuid=$UUID" "$MNT/$MARKER" \
  || die "disk lacks the $MARKER marker for UUID $UUID — not a prepared rotation disk"

# Layout directories must be real directories on the mounted backup filesystem: a
# symlink (or a directory on another filesystem) would put copies, manifests or
# receipts somewhere other than the offline disk while every check still passed.
LAYOUT="archive manifests services receipts"
fs_id() { stat -c %d "$1" 2>/dev/null || stat -f %d "$1"; }
MNT_FS="$(fs_id "$MNT")" || die "cannot stat $MNT"
check_layout() {
  local d fs
  for d in $LAYOUT; do
    [ ! -L "$MNT/$d" ] || die "disk layout directory $d is a symlink; refusing"
    [ -d "$MNT/$d" ] || die "disk layout entry $d is not a directory; refusing"
    fs="$(fs_id "$MNT/$d")" || die "cannot stat disk layout directory $d"
    [ "$fs" = "$MNT_FS" ] || die "disk layout directory $d is not on the backup filesystem; refusing"
  done
}
for d in $LAYOUT; do
  [ ! -L "$MNT/$d" ] || die "disk layout directory $d is a symlink; refusing"
  [ -e "$MNT/$d" ] || mkdir "$MNT/$d" || die "cannot create disk layout directory $d"
done
check_layout
# Writers never open a path that existed before this run. Final names must be
# absent (a dangling symlink counts as present); every temp file is created by
# mktemp inside a fresh 0700 work directory on the backup filesystem, so a planted
# link cannot alias two temp files or redirect a write to a host file.
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
place() { absent "$2" || die "refusing to replace existing $2"; mv "$1" "$2" || die "cannot place $2"; }
for existing in "receipts/$STAMP.receipt" "services/$STAMP" "services/.partial-$STAMP" \
  "manifests/$STAMP-archive.sha256" "manifests/$STAMP-services.sha256"; do
  absent "$MNT/$existing" || die "a rotation stamped $STAMP already exists on the disk ($existing)"
done
WORK="$(mktemp -d "$MNT/manifests/.work-$STAMP.XXXXXX")" || die "cannot create a private work directory on the disk"
[ -d "$WORK" ] && [ ! -L "$WORK" ] && [ "$(fs_id "$WORK")" = "$MNT_FS" ] \
  || die "work directory $WORK is not a private directory on the backup filesystem"

# ---- Archive: copy without overwrite or delete, then verify -----------------
log "copying archive (no overwrite, no delete) — slow over USB 2 is expected"
rsync -a --ignore-existing "$ARCHIVE_SRC/" "$MNT/archive/" || die "archive rsync failed"
# rsync -a keeps symlinks as links, and sha256sum -c would follow one back to the
# live source, so a link anywhere in the disk archive would prove nothing.
link="$(find "$MNT/archive" -type l -print -quit)" || die "cannot scan the disk archive for symlinks"
[ -z "$link" ] || die "disk archive contains a symlink (${link#"$MNT"/}); verification would read outside the disk"
ARCHIVE_MANIFEST="$(mktemp "$WORK/archive.XXXXXX")" || die "cannot create the archive manifest temp"
cp "$MANIFEST_SNAPSHOT" "$ARCHIVE_MANIFEST" || die "cannot copy the archive manifest to the disk"
log "verifying $ARCHIVE_COUNT archive files against the sha256 manifest"
(cd "$MNT/archive" && sha256sum -c --strict --quiet "$ARCHIVE_MANIFEST") \
  || die "archive verification failed on the disk copy"
MANIFEST_SHA="$(sha256sum "$ARCHIVE_MANIFEST" | awk '{print $1}')"
place "$ARCHIVE_MANIFEST" "$MNT/manifests/$STAMP-archive.sha256"

# ---- Service snapshots: new dated tree, verified against the source ---------
service_manifest() {
  # Called inside `|| die`, where errexit is off, so each failure must exit explicitly.
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    sha256sum "$f" || exit 1
  done)
}
SERVICE_FILES=0
if [ "${#SERVICE_NAMES[@]}" -gt 0 ]; then
  check_layout
  PREV="$(find "$MNT/services" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*Z' -print \
    | LC_ALL=C sort | tail -n 1)"
  PARTIAL="$MNT/services/.partial-$STAMP"
  absent "$PARTIAL" || die "leftover partial service tree exists: $PARTIAL"
  # rsync creates only the last destination component; mkdir fails on any existing
  # entry, including a link.
  mkdir "$PARTIAL" || die "cannot create $PARTIAL"
  SVC_MANIFEST="$(mktemp "$WORK/services-source.XXXXXX")" || die "cannot create the service manifest temp"
  i=0
  while [ "$i" -lt "${#SERVICE_NAMES[@]}" ]; do
    name="${SERVICE_NAMES[$i]}"; src="${SERVICE_DIRS[$i]}"; i=$((i + 1))
    LINK_ARGS=()
    if [ -n "$PREV" ] && [ -d "$PREV/$name" ]; then LINK_ARGS=("--link-dest=$PREV/$name"); fi
    log "copying service snapshot $name"
    service_manifest "$src" | sed "s|  \./|  $name/|" >>"$SVC_MANIFEST" \
      || die "cannot checksum service source $name"
    rsync -a ${LINK_ARGS[@]+"${LINK_ARGS[@]}"} "$src/" "$PARTIAL/$name/" || die "service rsync failed: $name"
  done
  SERVICE_FILES="$(grep -c . "$SVC_MANIFEST" || true)"
  # Verify by walking the disk copy the same non-following way (find -type f never
  # follows a link) and comparing manifests; `sha256sum -c` would follow a symlink
  # that replaced a hashed file back to live data. Links are kept but not verified.
  DEST_MANIFEST="$(mktemp "$WORK/services-disk.XXXXXX")" || die "cannot create the disk manifest temp"
  for name in "${SERVICE_NAMES[@]}"; do
    service_manifest "$PARTIAL/$name" | sed "s|  \./|  $name/|" >>"$DEST_MANIFEST" \
      || die "cannot checksum the disk copy of service $name"
  done
  cmp -s "$SVC_MANIFEST" "$DEST_MANIFEST" \
    || die "service snapshot verification failed on the disk copy"
  rm -f "$DEST_MANIFEST"
  place "$SVC_MANIFEST" "$MNT/manifests/$STAMP-services.sha256"
  place "$PARTIAL" "$MNT/services/$STAMP"
fi

# ---- SMART short test on the parent disk ------------------------------------
smart() {
  local rc=0
  smartctl -d sat "$@" "$SMART_DEV" || rc=$?
  # Bits 0-2 mean the command itself failed; higher bits report disk history and
  # are judged from the self-test log and health result below.
  return $((rc & 7))
}
log "running SMART short self-test on $SMART_DEV"
smart -t short >/dev/null || die "SMART short test could not be started"
seen_running=0
waited=0
while :; do
  status="$(smart -c)" || die "SMART capabilities query failed"
  case "$status" in
    *"in progress"*) seen_running=1 ;;
    *) break ;;
  esac
  [ "$waited" -lt "$SMART_TIMEOUT" ] || die "SMART short test still running after ${SMART_TIMEOUT}s"
  [ "$SMART_POLL" -eq 0 ] || sleep "$SMART_POLL"
  waited=$((waited + SMART_POLL + 1))
done
[ "$seen_running" = 1 ] || die "SMART short test was never observed running — result not trusted"
selftest_log="$(smart -l selftest)" || die "SMART self-test log query failed"
latest="$(printf '%s\n' "$selftest_log" | grep -E '^# *1 ' || true)"
case "$latest" in
  *"Short offline"*"Completed without error"*) ;;
  *) die "SMART short test did not pass: ${latest:-no self-test log entry}" ;;
esac
health="$(smart -H)" || die "SMART health query failed"
case "$health" in
  *"test result: PASSED"*) ;;
  *) die "SMART overall health is not PASSED — replace this disk" ;;
esac

# ---- Receipts and close ------------------------------------------------------
# write_receipt TEMP_DIR DEST: write into a fresh mktemp file in TEMP_DIR, make it
# world-readable (the freshness check may run unprivileged), then place it at DEST.
write_receipt() {
  local dest="$2" tmp
  tmp="$(mktemp "$1/.receipt.XXXXXX")" || return 1
  {
    echo "format=$RECEIPT_FORMAT"
    echo "completed_at=$STAMP"
    echo "completed_epoch=$NOW"
    echo "luks_uuid=$UUID"
    echo "archive_files_verified=$ARCHIVE_COUNT"
    echo "archive_manifest_sha256=$MANIFEST_SHA"
    echo "services=$(IFS=,; echo "${SERVICE_NAMES[*]+"${SERVICE_NAMES[*]}"}")"
    echo "service_files_verified=$SERVICE_FILES"
    echo "smart_short_test=passed"
    echo "smart_health=passed"
  } >"$tmp" || return 1
  chmod 0644 "$tmp" || return 1
  place "$tmp" "$dest"
}
check_layout
write_receipt "$WORK" "$MNT/receipts/$STAMP.receipt" || die "cannot write the disk receipt"
rmdir "$WORK" || die "cannot remove the empty work directory $WORK"
sync
umount "$MNT" || die "umount failed"
cryptsetup luksClose "$MAPPER" || die "luksClose failed"

mkdir -p "$RECEIPT_DIR" || die "cannot create local receipt dir $RECEIPT_DIR"
[ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || die "local receipt dir is not a real directory: $RECEIPT_DIR"
write_receipt "$RECEIPT_DIR" "$RECEIPT_DIR/$STAMP.receipt" || die "cannot write the local receipt"
COMPLETE=1
log "receipt $STAMP: $ARCHIVE_COUNT archive files and $SERVICE_FILES service files verified"
echo "offline rotation complete: safe to unplug"
