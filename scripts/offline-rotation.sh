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

MAPPER=brokkr-offline
MARKER=BROKKR-OFFLINE-DISK
RECEIPT_FORMAT=brokkr-offline-rotation-receipt-v1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >&2; }
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

# Every manifest line must be "<sha256>  <relative path>" with no absolute path and no
# '..' component, so `sha256sum -c` can only ever read inside the copied archive.
ARCHIVE_COUNT="$(awk '
  { line = $0 }
  line !~ /^[0-9a-f]{64} [ *]./ { bad = 1; exit }
  { path = substr(line, 67) }
  path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ { bad = 1; exit }
  { n++ }
  END { if (bad || n == 0) print "bad"; else print n }
' "$MANIFEST")"
[ "$ARCHIVE_COUNT" != bad ] \
  || die "archive manifest has an empty, malformed, absolute or '..' entry: $MANIFEST"

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
! mountpoint -q "$MNT" || die "mount point is already in use: $MNT"
[ -z "$(ls -A "$MNT")" ] || die "mount point is not empty: $MNT"

# ---- Identify the disk by LUKS UUID -----------------------------------------
LINK="$BY_UUID_DIR/$UUID"
[ -e "$LINK" ] || die "rotation disk with LUKS UUID $UUID is not attached"
DEV="$(readlink -f "$LINK")" || die "cannot resolve $LINK"
cryptsetup isLuks --type luks2 "$DEV" || die "device for UUID $UUID is not LUKS2 — refusing"
HEADER_UUID="$(cryptsetup luksUUID "$DEV" | tr '[:upper:]' '[:lower:]')" \
  || die "cannot read the LUKS UUID from $DEV"
[ "$HEADER_UUID" = "$UUID" ] || die "LUKS UUID mismatch on $DEV: header reports '$HEADER_UUID'"
if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
  die "mapping $MAPPER is already active; close it deliberately before rotating"
fi
PARENT="$(lsblk -ndo PKNAME "$DEV" 2>/dev/null | head -n 1 || true)"
if [ -n "$PARENT" ]; then SMART_DEV="/dev/$PARENT"; else SMART_DEV="$DEV"; fi

# ---- Open, mount, and always close on the way out ---------------------------
# Cleanup reads live state rather than flags set after each command: a signal can
# land after `cryptsetup open` or `mount` succeeds but before a flag is recorded.
# The preflight proved the mapping inactive and the mount point unused, so once an
# attempt was made, an active mapping or mount at those names is this run's.
OPEN_ATTEMPTED=0
MOUNT_ATTEMPTED=0
COMPLETE=0
is_open() { cryptsetup status "$MAPPER" >/dev/null 2>&1; }
finish() {
  local rc=$? mounted=0 opened=0
  trap - EXIT INT TERM
  [ "$COMPLETE" = 1 ] && exit 0
  if [ "$MOUNT_ATTEMPTED" = 1 ] && mountpoint -q "$MNT"; then
    sync || true
    umount "$MNT" || mounted=1
  fi
  if [ "$OPEN_ATTEMPTED" = 1 ] && [ "$mounted" = 0 ] && is_open; then
    cryptsetup luksClose "$MAPPER" || opened=1
  fi
  if [ "$OPEN_ATTEMPTED" = 1 ] && [ "$mounted" = 1 ]; then opened=1; fi
  if [ "$mounted" = 1 ] || [ "$opened" = 1 ]; then
    log "offline rotation FAILED and the disk is still open — do NOT unplug; unmount $MNT and luksClose $MAPPER by hand"
  elif [ "$rc" -ne 0 ]; then
    log "offline rotation FAILED; disk unmounted and closed (safe to unplug), but no valid receipt was recorded"
  fi
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT TERM

log "opening LUKS2 disk $UUID (${KEYFILE:+keyfile}${KEYFILE:-terminal prompt})"
OPEN_ATTEMPTED=1
cryptsetup open --type luks2 ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DEV" "$MAPPER" || die "cryptsetup open failed"
MOUNT_ATTEMPTED=1
mount -o nodev,nosuid,noexec "/dev/mapper/$MAPPER" "$MNT" || die "mount failed"
mountpoint -q "$MNT" || die "$MNT is not a mount point after mounting"
[ -f "$MNT/$MARKER" ] && [ ! -L "$MNT/$MARKER" ] && grep -qxF "luks_uuid=$UUID" "$MNT/$MARKER" \
  || die "disk lacks the $MARKER marker for UUID $UUID — not a prepared rotation disk"

mkdir -p "$MNT/archive" "$MNT/manifests" "$MNT/services" "$MNT/receipts"
for existing in "$MNT/receipts/$STAMP.receipt" "$MNT/services/$STAMP" "$MNT/manifests/$STAMP-archive.sha256"; do
  [ ! -e "$existing" ] || die "a rotation stamped $STAMP already exists on the disk"
done

# ---- Archive: copy without overwrite or delete, then verify -----------------
log "copying archive (no overwrite, no delete) — slow over USB 2 is expected"
rsync -a --ignore-existing "$ARCHIVE_SRC/" "$MNT/archive/" || die "archive rsync failed"
# rsync -a keeps symlinks as links, and sha256sum -c would follow one back to the
# live source, so a link anywhere in the disk archive would prove nothing.
link="$(find "$MNT/archive" -type l -print -quit)" || die "cannot scan the disk archive for symlinks"
[ -z "$link" ] || die "disk archive contains a symlink (${link#"$MNT"/}); verification would read outside the disk"
cp "$MANIFEST" "$MNT/manifests/.$STAMP-archive.sha256.tmp"
mv "$MNT/manifests/.$STAMP-archive.sha256.tmp" "$MNT/manifests/$STAMP-archive.sha256"
log "verifying $ARCHIVE_COUNT archive files against the sha256 manifest"
(cd "$MNT/archive" && sha256sum -c --strict --quiet "$MNT/manifests/$STAMP-archive.sha256") \
  || die "archive verification failed on the disk copy"
MANIFEST_SHA="$(sha256sum "$MNT/manifests/$STAMP-archive.sha256" | awk '{print $1}')"

# ---- Service snapshots: new dated tree, verified against the source ---------
service_manifest() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    sha256sum "$f"
  done)
}
SERVICE_FILES=0
if [ "${#SERVICE_NAMES[@]}" -gt 0 ]; then
  PREV="$(find "$MNT/services" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*Z' -print \
    | LC_ALL=C sort | tail -n 1)"
  PARTIAL="$MNT/services/.partial-$STAMP"
  [ ! -e "$PARTIAL" ] || die "leftover partial service tree exists: $PARTIAL"
  # rsync creates only the last destination component.
  mkdir "$PARTIAL" || die "cannot create $PARTIAL"
  SVC_MANIFEST="$MNT/manifests/.$STAMP-services.sha256.tmp"
  : >"$SVC_MANIFEST"
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
  if [ "$SERVICE_FILES" -gt 0 ]; then
    (cd "$PARTIAL" && sha256sum -c --strict --quiet "$SVC_MANIFEST") \
      || die "service snapshot verification failed on the disk copy"
  fi
  mv "$SVC_MANIFEST" "$MNT/manifests/$STAMP-services.sha256"
  mv "$PARTIAL" "$MNT/services/$STAMP"
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
write_receipt() {
  local dest="$1" tmp
  tmp="$(dirname "$dest")/.$(basename "$dest").tmp"
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
  } >"$tmp" && mv "$tmp" "$dest"
}
write_receipt "$MNT/receipts/$STAMP.receipt" || die "cannot write the disk receipt"
sync
umount "$MNT" || die "umount failed"
cryptsetup luksClose "$MAPPER" || die "luksClose failed"

mkdir -p "$RECEIPT_DIR" || die "cannot create local receipt dir $RECEIPT_DIR"
write_receipt "$RECEIPT_DIR/$STAMP.receipt" || die "cannot write the local receipt"
COMPLETE=1
log "receipt $STAMP: $ARCHIVE_COUNT archive files and $SERVICE_FILES service files verified"
echo "offline rotation complete: safe to unplug"
