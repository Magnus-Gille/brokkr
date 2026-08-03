#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
node "$ROOT/scripts/test/maintenance-owner-ceremony-transition.test.mjs"
