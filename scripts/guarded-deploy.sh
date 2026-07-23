#!/usr/bin/env bash
# Execute a Brokkr deployment entry point only from the selected immutable source.

set -euo pipefail

ENTRY_SCRIPT=$0
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "ERROR: deployment entry point path must not contain symlinks" >&2; exit 2; }
done
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$SCRIPT_DIR/lib/deploy-source.sh"

if [[ $# -lt 4 || "$3" != "--" ]]; then
  echo "ERROR: usage: guarded-deploy.sh EXPECTED_SOURCE FULL_COMMIT_SHA -- COMMAND [ARG ...]" >&2
  exit 2
fi

expected_source=$1
expected_revision=$2
shift 3

verify_brokkr_deploy_source_binding \
  "$(cd "$SCRIPT_DIR/.." && pwd -P)" "$expected_source" "$expected_revision"
exec "$@"
