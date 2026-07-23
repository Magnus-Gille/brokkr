#!/usr/bin/env bash
# Brokkr · install the bounded persistent-journal policy (brokkr#3).
#
# Usage:
#   sudo ./scripts/setup-persistent-journal.sh --apply [--restart]
#   ./scripts/setup-persistent-journal.sh --dry-run
#
# `--apply` is intentionally explicit. `--restart` is separately explicit:
# without it, the installed policy takes effect on the next boot and no service
# is restarted. The script is local-only; it never SSHes to another host.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="${JOURNALD_CONFIG_SOURCE:-$ROOT/journald/60-brokkr-persistent.conf}"
DROPIN_DIR="${JOURNALD_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DIR="${JOURNALD_LOG_DIR:-/var/log/journal}"
DEST="$DROPIN_DIR/60-brokkr-persistent.conf"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 64; }

apply=false
restart=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=true ;;
    --restart) restart=true ;;
    --dry-run) ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ "$SOURCE" = /* && "$DROPIN_DIR" = /* && "$JOURNAL_DIR" = /* ]] || die "journal paths must be absolute"
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || die "policy source must be a regular non-symlink file"

if ! $apply; then
  $restart && die "--restart requires --apply"
  echo "DRY RUN: would create $JOURNAL_DIR and install bounded persistent journald policy at $DEST"
  echo "DRY RUN: no journald restart requested"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "--apply must be run as root (for example: sudo $0 --apply)"
if [[ -L "$DEST" ]]; then
  die "refusing to replace symlinked destination $DEST"
fi
if [[ -e "$DEST" && ! -f "$DEST" ]]; then
  die "destination exists but is not a regular file: $DEST"
fi

install -d -m 0755 "$DROPIN_DIR"
install -d -m 2755 "$JOURNAL_DIR"
install -m 0644 "$SOURCE" "$DEST"

if $restart; then
  systemctl restart systemd-journald.service
  systemctl is-active --quiet systemd-journald.service
  echo "installed: persistent journal policy active after explicit journald restart"
else
  echo "installed: persistent journal policy will be active after the next boot (or rerun with --restart)"
fi
