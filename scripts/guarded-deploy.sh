#!/usr/bin/env bash
# Execute a Brokkr deployment entry point only from the selected immutable source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$SCRIPT_DIR/lib/deploy-source.sh"

if [[ $# -lt 4 || "$3" != "--" ]]; then
  echo "ERROR: usage: guarded-deploy.sh EXPECTED_SOURCE FULL_COMMIT_SHA -- COMMAND [ARG ...]" >&2
  exit 2
fi

expected_source=$1
expected_revision=$2
shift 3

verify_deploy_source_identity "$expected_source" "$expected_revision" "$PWD"
exec "$@"
