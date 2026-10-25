# shellcheck shell=bash
# ─── Brokkr offline rotation disk: live-state probes ─────────────────────────
#
# mount_state DIR   → prints mounted | unmounted | unknown
# map_state NAME    → prints active | inactive | unknown
#
# Each probe reports a definite state only when the tool says so; any other result,
# including the probe itself failing, is "unknown" and must never be treated as safe.
# Shared by offline-rotation.sh and offline-rotation-format.sh. bash 3.2+.

# util-linux mountpoint: 0 = mount point, 32 = not a mount point, other = error.
mount_state() {
  local rc=0
  mountpoint -q "$1" || rc=$?
  case "$rc" in 0) echo mounted ;; 32) echo unmounted ;; *) echo unknown ;; esac
}

# cryptsetup status: 0 = active, 4 = no such active device, other = error.
map_state() {
  local rc=0
  cryptsetup status "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) echo active ;; 4) echo inactive ;; *) echo unknown ;; esac
}
