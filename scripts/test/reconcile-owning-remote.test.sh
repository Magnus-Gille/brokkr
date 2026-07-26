#!/usr/bin/env bash
# Hermetic tests for scripts/reconcile-owning-remote.sh (#60).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/reconcile-owning-remote.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CALLS="$TMP/calls"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_CALLS"
case "$*" in
  'rev-parse --is-inside-work-tree') echo true ;;
  'remote get-url origin') printf '%s\n' "$MOCK_REMOTE" ;;
  'status --porcelain') printf '%s' "${MOCK_DIRTY:-}" ;;
  'rev-list --branches --not origin/main') printf '%s' "${MOCK_DIVERGED:-}" ;;
  'remote set-url origin '*) ;;
  'fetch --prune origin') [[ "${MOCK_FETCH_FAIL:-0}" != 1 ]] ;;
  "rev-parse --verify origin/main^{commit}") printf '%s\n' '0123456789012345678901234567890123456789' ;;
  *) printf 'unexpected git invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/git"

run() {
  : >"$CALLS"
  PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_REMOTE='https://archive.example.invalid/brokkr.git' "$SCRIPT" "$@" >"$TMP/out" 2>&1
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check() { "$@" || fail "$1"; }

export MOCK_DIRTY=' M README.md'
if run --check; then fail 'dirty checkout passed'; fi
unset MOCK_DIRTY
check grep -Fq 'worktree is dirty' "$TMP/out"
check grep -Fq 'status --porcelain' "$CALLS"

export MOCK_DIVERGED='abc123'
if run --apply --yes; then fail 'diverged branch passed'; fi
unset MOCK_DIVERGED
check grep -Fq 'commits outside origin/main' "$TMP/out"
if grep -Fq 'remote set-url' "$CALLS"; then fail 'diverged branch changed origin'; fi

run --check
check grep -Fq 'does not use the owning public Brokkr remote' "$TMP/out"
if grep -Fq 'fetch --prune' "$CALLS"; then fail 'check fetched'; fi

run --apply --yes
check grep -Fq 'owning remote reconciled; origin/main=0123456789012345678901234567890123456789' "$TMP/out"
check grep -Fq 'remote set-url origin https://github.com/Magnus-Gille/brokkr.git' "$CALLS"
check grep -Fq 'fetch --prune origin' "$CALLS"

export MOCK_FETCH_FAIL=1
if run --apply --yes; then fail 'failed fetch passed'; fi
unset MOCK_FETCH_FAIL
check grep -Fq 'fetch from owning remote failed; restored the previous origin URL' "$TMP/out"
check grep -Fq 'remote set-url origin https://archive.example.invalid/brokkr.git' "$CALLS"

printf 'PASS: remote authority reconciliation guard\n'
