#!/usr/bin/env bash
# Brokkr · offline rotation disk — one-time, owner-attended format ceremony.
#
#   sudo ./scripts/offline-rotation-format.sh --i-understand-this-erases \
#     /dev/disk/by-id/usb-<model>_<serial>-0:0 --header-backup /root/brokkr-offline-header.img
#
# ERASES the named disk: one GPT partition, LUKS2, ext4, the BROKKR-OFFLINE-DISK marker
# and the rotation layout. See docs/offline-rotation.md for the surrounding ceremony
# (passphrase in the password manager, recording the UUID, the key-recovery check).
#
# Every step stops the run on failure, and each guard runs before the step it protects:
#   • The disk is named by its stable /dev/disk/by-id link, must be a whole USB disk with
#     nothing mounted and no holders, and the operator must type ERASE after seeing it.
#   • The brokkr-offline mapping must be inactive, and the run holds the rotation lock,
#     so no other rotation or format can race it.
#   • The new partition must belong to the resolved disk before luksFormat.
#   • Immediately before mkfs, the mapping must be backed by that partition and carry
#     the LUKS UUID just created; otherwise nothing is formatted and the mapping is left
#     for inspection.
# The passphrase comes from cryptsetup's own prompt (verified twice), or from
# --key-file, whose exact bytes become the key. This script never reads or prints it.
# Exit: 0 = formatted, 64 = usage, other = failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/private-env.sh
. "$HERE/lib/private-env.sh"
# shellcheck source=scripts/lib/offline-disk.sh
. "$HERE/lib/offline-disk.sh"

MAPPER=brokkr-offline
MARKER=BROKKR-OFFLINE-DISK
BY_ID_DIR="${BROKKR_OFFLINE_BY_ID_DIR:-/dev/disk/by-id}"
MNT="${OFFLINE_MOUNT_POINT:-/mnt/brokkr-offline}"
LOCK="${BROKKR_OFFLINE_LOCK_DIR:-/run/lock}/brokkr-offline-rotation.lock"
SETTLE="${BROKKR_OFFLINE_SETTLE_SECONDS:-10}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >&2 || true; }
die() { log "ERROR: $*"; exit 1; }
usage() {
  echo "usage: $0 --i-understand-this-erases /dev/disk/by-id/<usb-disk> --header-backup FILE [--key-file FILE]" >&2
  exit 64
}

# ---- Arguments ---------------------------------------------------------------
ERASE_OK=0
DISK_ID=""
HEADER=""
KEYFILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --i-understand-this-erases) ERASE_OK=1; shift ;;
    --header-backup) [ "$#" -ge 2 ] || usage; HEADER="$2"; shift 2 ;;
    --key-file) [ "$#" -ge 2 ] || usage; KEYFILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    -*) usage ;;
    *) [ -z "$DISK_ID" ] || usage; DISK_ID="$1"; shift ;;
  esac
done
[ "$ERASE_OK" = 1 ] && [ -n "$DISK_ID" ] && [ -n "$HEADER" ] || usage

case "$DISK_ID" in
  "$BY_ID_DIR"/*) ;;
  *) die "name the disk by its stable $BY_ID_DIR link, never /dev/sdX: $DISK_ID" ;;
esac
id_name="${DISK_ID#"$BY_ID_DIR"/}"
case "$id_name" in
  ''|*/*|.|..) die "invalid by-id name: $DISK_ID" ;;
  *-part[0-9]*) die "name the whole disk, not a partition: $DISK_ID" ;;
esac
[ -L "$DISK_ID" ] || die "no such by-id link: $DISK_ID"

case "$HEADER" in /*) ;; *) die "--header-backup must be an absolute path" ;; esac
[ ! -e "$HEADER" ] && [ ! -L "$HEADER" ] || die "header backup path already exists; refusing to overwrite: $HEADER"
[ -d "$(dirname "$HEADER")" ] || die "header backup directory does not exist: $(dirname "$HEADER")"

KEY_ARGS=()
if [ -n "$KEYFILE" ]; then
  brokkr_private_file_ok "$KEYFILE" keyfile || die "refusing an unsafe keyfile"
  KEY_ARGS=("--key-file=$KEYFILE")
elif [ ! -t 0 ]; then
  die "no --key-file and stdin is not a terminal for the passphrase prompt"
fi

for tool in cryptsetup wipefs parted udevadm lsblk mkfs.ext4 mount umount mountpoint; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ---- One run at a time (shared with offline-rotation.sh) ---------------------
HELD_LOCK=0
release_lock() {
  if [ "$HELD_LOCK" = 1 ]; then rmdir "$LOCK" 2>/dev/null || log "WARN: cannot remove lock $LOCK"; fi
  HELD_LOCK=0
}
on_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 131' QUIT; trap 'exit 143' TERM; }
trap release_lock EXIT
trap '' HUP INT QUIT TERM
if mkdir "$LOCK" 2>/dev/null; then HELD_LOCK=1; fi
on_signals
[ "$HELD_LOCK" = 1 ] || die "an offline rotation or format holds $LOCK; if none is running, remove it by hand"

# ---- Inspect the disk before touching it -------------------------------------
DISK="$(readlink -f "$DISK_ID")" || die "cannot resolve $DISK_ID"
[ -e "$DISK" ] || die "$DISK_ID does not resolve to a device"
[ "$(lsblk -ndo TYPE "$DISK")" = disk ] || die "$DISK_ID is not a whole disk according to lsblk"
[ "$(lsblk -ndo TRAN "$DISK")" = usb ] || die "$DISK_ID is not a USB disk; refusing"
tree="$(lsblk -nro NAME,TYPE,MOUNTPOINT "$DISK")" || die "cannot list $DISK_ID"
while read -r name type mnt; do
  [ -z "${mnt:-}" ] || die "$name on $DISK_ID is mounted at $mnt; unmount it first"
  case "$type" in disk|part) ;; *) die "$name on $DISK_ID is an active $type holder; close it first" ;; esac
done <<<"$tree"
case "$(map_state "$MAPPER")" in
  inactive) ;;
  active) die "mapping $MAPPER is already active; close it deliberately before formatting" ;;
  *) die "cannot determine whether mapping $MAPPER is active" ;;
esac
[ -d "$MNT" ] || die "mount point is not a directory: $MNT"
[ "$(mount_state "$MNT")" = unmounted ] || die "mount point $MNT is in use or cannot be inspected"
[ -z "$(ls -A "$MNT")" ] || die "mount point is not empty: $MNT"

log "about to ERASE $DISK_ID ($DISK, $(lsblk -ndo SIZE,MODEL "$DISK"))"
printf 'Type ERASE to wipe this disk: ' >&2
answer=""
IFS= read -r answer || true
[ "$answer" = ERASE ] || die "not confirmed; nothing was changed"

# ---- Partition and LUKS2 -----------------------------------------------------
wipefs --all "$DISK"
parted --script "$DISK" mklabel gpt mkpart brokkr-offline 1MiB 100%
udevadm settle
PART_ID="$DISK_ID-part1"
waited=0
while [ ! -e "$PART_ID" ] && [ "$waited" -lt "$SETTLE" ]; do sleep 1; waited=$((waited + 1)); done
[ -e "$PART_ID" ] || die "new partition $PART_ID did not appear"
PART="$(readlink -f "$PART_ID")" || die "cannot resolve $PART_ID"
[ "$(lsblk -ndo PKNAME "$PART")" = "$(basename "$DISK")" ] \
  || die "partition $PART does not belong to $DISK; refusing to format it"

if [ "${#KEY_ARGS[@]}" -gt 0 ]; then FORMAT_KEY=("${KEY_ARGS[@]}"); else FORMAT_KEY=(--verify-passphrase); fi
cryptsetup luksFormat --type luks2 --batch-mode "${FORMAT_KEY[@]}" "$PART"
cryptsetup isLuks --type luks2 "$PART" || die "$PART is not LUKS2 after luksFormat"
UUID="$(cryptsetup luksUUID "$PART" | tr '[:upper:]' '[:lower:]')"
[[ "$UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "unexpected LUKS UUID from $PART: $UUID"
(umask 077 && cryptsetup luksHeaderBackup "$PART" --header-backup-file "$HEADER")
chmod 0600 "$HEADER"

# ---- Open, verify the mapping, mkfs, layout ----------------------------------
OPEN_ATTEMPTED=0
MOUNT_ATTEMPTED=0
FOREIGN=0
COMPLETE=0
finish() {
  local rc=$? unmounted=1 closed=1
  set +e
  trap - EXIT
  trap '' HUP INT QUIT TERM
  if [ "$COMPLETE" = 1 ]; then release_lock; exit 0; fi
  if [ "$MOUNT_ATTEMPTED" = 1 ] && [ "$(mount_state "$MNT")" != unmounted ]; then
    sync
    umount "$MNT" || unmounted=0
  fi
  if [ "$OPEN_ATTEMPTED" = 1 ]; then
    if [ "$FOREIGN" = 1 ] || [ "$unmounted" = 0 ]; then
      closed=0
    elif [ "$(map_state "$MAPPER")" != inactive ]; then
      cryptsetup luksClose "$MAPPER" || closed=0
    fi
  fi
  if [ "$unmounted" = 0 ] || [ "$closed" = 0 ]; then
    log "format FAILED and $MAPPER may still be open — do NOT unplug; inspect with 'cryptsetup status $MAPPER'"
  else
    log "format FAILED; nothing is mounted or open (safe to unplug). Re-run the ceremony from the start."
  fi
  release_lock
  [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}
trap finish EXIT
on_signals

OPEN_ATTEMPTED=1
cryptsetup open --type luks2 ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$PART" "$MAPPER" || die "cryptsetup open failed"
backing="$(cryptsetup status "$MAPPER" | awk '$1 == "device:" { print $2; exit }')" \
  || { FOREIGN=1; die "cannot read the backing device of $MAPPER"; }
if [ -z "$backing" ] || [ "$(readlink -f "$backing")" != "$PART" ]; then
  FOREIGN=1
  die "mapping $MAPPER is backed by '${backing:-unknown}', not $PART; refusing to mkfs"
fi
backing_uuid="$(cryptsetup luksUUID "$backing" | tr '[:upper:]' '[:lower:]')" || backing_uuid=""
if [ "$backing_uuid" != "$UUID" ]; then
  FOREIGN=1
  die "mapping $MAPPER is backed by LUKS UUID '${backing_uuid:-unknown}', not $UUID; refusing to mkfs"
fi
mkfs.ext4 -q -L brokkr-offline -m 0 "/dev/mapper/$MAPPER"

MOUNT_ATTEMPTED=1
mount -o nodev,nosuid,noexec "/dev/mapper/$MAPPER" "$MNT"
[ "$(mount_state "$MNT")" = mounted ] || die "$MNT is not confirmed as a mount point after mounting"
printf 'luks_uuid=%s\n' "$UUID" >"$MNT/$MARKER"
mkdir -m 0700 "$MNT/archive" "$MNT/manifests" "$MNT/services" "$MNT/receipts"
chmod 0700 "$MNT"
sync
umount "$MNT"
cryptsetup luksClose "$MAPPER"
COMPLETE=1

log "formatted $DISK_ID; the disk is closed and safe to unplug"
echo "Record in the password manager entry and /etc/brokkr/offline-rotation.env:"
echo "OFFLINE_LUKS_UUID=$UUID"
echo "LUKS header backup (attach to the password manager entry, then shred): $HEADER"
