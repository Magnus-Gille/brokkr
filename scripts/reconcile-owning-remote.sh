#!/usr/bin/env bash
# Reconcile a Brokkr operational checkout with its owning public repository.
# This intentionally never changes repository visibility or removes history.
set -euo pipefail

OWNING_REMOTE_URL='https://github.com/Magnus-Gille/brokkr.git'

usage() {
  cat >&2 <<'EOF'
Usage: reconcile-owning-remote.sh --check | --apply --yes

--check validates that a checkout is clean and has no local commits outside
origin/main.  --apply updates only origin's URL, fetches origin/main, and
prints its full commit SHA.  It restores the prior URL if that fetch fails.
EOF
  exit 64
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mode=''
case "${1:-}" in
  --check) [[ $# -eq 1 ]] || usage; mode='check' ;;
  --apply) [[ ${2:-} == '--yes' && $# -eq 2 ]] || usage; mode='apply' ;;
  *) usage ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail 'must run inside a Git worktree'
previous_url="$(git remote get-url origin 2>/dev/null)" || fail 'origin remote is required'
[[ -n "$previous_url" ]] || fail 'origin remote URL is empty'

if [[ -n "$(git status --porcelain)" ]]; then
  fail 'worktree is dirty; reconcile only a clean operational checkout'
fi

# A local commit not reachable from the currently tracked main could be archive-only
# work.  Refuse rather than silently retargeting its upstream authority.
if [[ -n "$(git rev-list --branches --not origin/main 2>/dev/null)" ]]; then
  fail 'local branch contains commits outside origin/main; inspect or preserve them before reconciliation'
fi

if [[ "$mode" == 'check' ]]; then
  if [[ "$previous_url" == "$OWNING_REMOTE_URL" ]]; then
    printf 'origin already uses the owning public Brokkr remote\n'
  else
    printf 'origin does not use the owning public Brokkr remote; --apply --yes is required after review\n'
  fi
  exit 0
fi

if [[ "$previous_url" == "$OWNING_REMOTE_URL" ]]; then
  printf 'origin already uses the owning public Brokkr remote\n'
else
  git remote set-url origin "$OWNING_REMOTE_URL"
fi

if ! git fetch --prune origin; then
  git remote set-url origin "$previous_url" || true
  fail 'fetch from owning remote failed; restored the previous origin URL'
fi

main_sha="$(git rev-parse --verify 'origin/main^{commit}' 2>/dev/null)" || {
  git remote set-url origin "$previous_url" || true
  fail 'origin/main did not resolve to a commit; restored the previous origin URL'
}

printf 'owning remote reconciled; origin/main=%s\n' "$main_sha"
