#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

REVISION=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision)
      [[ $# -ge 2 ]] || exit 64
      REVISION="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || exit 64
      OUTPUT="$2"
      shift 2
      ;;
    *)
      exit 64
      ;;
  esac
done

[[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] || {
  echo "ERROR: --revision must be a full lowercase Git SHA" >&2
  exit 64
}
[[ "$OUTPUT" == /* ]] || {
  echo "ERROR: --output must be absolute" >&2
  exit 64
}
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$REVISION" ]] || {
  echo "ERROR: supplied revision is not the source HEAD" >&2
  exit 1
}
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || {
  echo "ERROR: source worktree is dirty" >&2
  exit 1
}

CONTROLLER_RECEIPT="$TMP/controller.json"
HOST_RECEIPT="$TMP/host.json"
env BROKKR_FI_CONTROLLER_RECEIPT="$CONTROLLER_RECEIPT" \
  bash "$ROOT/scripts/test/maintenance-attempt-journal.test.sh"
env BROKKR_FI_HOST_RECEIPT="$HOST_RECEIPT" \
  bash "$ROOT/scripts/test/debian-maintenance-host-adapter.test.sh"
node "$ROOT/scripts/supervised-debian-maintenance-fi.mjs" \
  --revision "$REVISION" \
  --controller "$CONTROLLER_RECEIPT" \
  --host "$HOST_RECEIPT" \
  --output "$OUTPUT"
