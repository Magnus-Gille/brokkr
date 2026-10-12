#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="${BROKKR_MEMORY_CGROUP_PREFLIGHT_MODULE:-${1:-$ROOT/scripts/memory-cgroup-preflight.py}}"
if [ "$#" -gt 0 ]; then
  shift
fi

exec "${PYTHON_BIN:-python3}" -B "$ROOT/tests/memory_cgroup_preflight_test.py" "$TARGET" "$@"
