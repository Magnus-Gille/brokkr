#!/usr/bin/env bash
# Regression coverage for portable storage-probe fixture allocation.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_PARENT="$(mktemp -d)"
TMP_LINK="${TMP_PARENT}.link"
trap 'rm -f "$TMP_LINK"; rm -rf "$TMP_PARENT"' EXIT

ln -s "$TMP_PARENT" "$TMP_LINK"

# Models macOS: TMPDIR has a trailing slash and can be reached through a
# symlinked component such as /tmp -> /private/tmp.
TMPDIR="$TMP_LINK/" bash "$HERE/heimdall-storage-probe.test.sh"

# Models Linux: a physical temp parent remains fully hermetic.
TMPDIR="$TMP_PARENT" bash "$HERE/heimdall-storage-probe.test.sh"
