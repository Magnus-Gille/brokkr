#!/usr/bin/env bash
# Source-identity regressions for the owning-repository deployment boundary.
# The guarded command is a fake remote deployment: its marker proves whether a
# rejected request reached any deploy side effect.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
RELEASE="$TMP/release"
WRONG="$TMP/wrong"
CURRENT="$TMP/current"
MARKER="$TMP/deploy-ran"
COMMAND="$TMP/fake-deploy"

git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
mkdir -p "$REPO/scripts/lib"
cp "$SOURCE_ROOT/scripts/guarded-deploy.sh" "$REPO/scripts/guarded-deploy.sh"
cp "$SOURCE_ROOT/scripts/lib/deploy-source.sh" "$REPO/scripts/lib/deploy-source.sh"
chmod +x "$REPO/scripts/guarded-deploy.sh"
printf 'first\n' >"$REPO/revision"
git -C "$REPO" add revision scripts
git -C "$REPO" commit -qm first
STALE_SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'current\n' >"$REPO/revision"
git -C "$REPO" commit -qam current
CURRENT_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" worktree add --detach -q "$RELEASE" "$STALE_SHA"
git -C "$REPO" worktree add --detach -q "$WRONG" "$CURRENT_SHA"
git -C "$REPO" worktree add --detach -q "$CURRENT" "$CURRENT_SHA"
GUARD="$CURRENT/scripts/guarded-deploy.sh"
STALE_GUARD="$RELEASE/scripts/guarded-deploy.sh"

cat >"$COMMAND" <<'EOF'
#!/usr/bin/env bash
printf 'deploy command ran\n' >>"$DEPLOY_MARKER"
EOF
chmod +x "$COMMAND"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() {
  local cwd=$1
  shift
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT=""
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  RC=0
  # shellcheck disable=SC2034 # assertions consume these through check/eval
  OUT="$(cd "$cwd" && DEPLOY_MARKER="$MARKER" "$@" 2>&1)" || RC=$?
}

echo "guarded-deploy.test.sh"

# An omitted SHA must fail before the guarded command can run.
rm -f "$MARKER"
run "$CURRENT" "$GUARD" "$CURRENT" -- "$COMMAND"
check "missing revision is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"usage:"* ]]'
check "missing revision never reaches deploy command" '[[ ! -e "$MARKER" ]]'

# A valid source/SHA is insufficient if the caller is in another worktree.
rm -f "$MARKER"
run "$WRONG" "$GUARD" "$CURRENT" "$CURRENT_SHA" -- "$COMMAND"
check "wrong physical cwd is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"Expected source:"* && "$OUT" == *"different directory"* ]]'
check "wrong cwd never reaches deploy command" '[[ ! -e "$MARKER" ]]'

# A clean worktree at an old commit must not be mistaken for the selected source.
rm -f "$MARKER"
run "$RELEASE" "$GUARD" "$RELEASE" "$CURRENT_SHA" -- "$COMMAND"
check "stale clean checkout is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"revision does not match"* ]]'
check "stale checkout never reaches deploy command" '[[ ! -e "$MARKER" ]]'

# A wrapper from a different checkout cannot authorize a command from the
# selected worktree, even when the caller cwd and revision are otherwise valid.
rm -f "$MARKER"
run "$CURRENT" "$STALE_GUARD" "$CURRENT" "$CURRENT_SHA" -- "$COMMAND"
check "wrong-checkout wrapper is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"entry point source root does not match"* ]]'
check "wrong-checkout wrapper never reaches deploy command" '[[ ! -e "$MARKER" ]]'

rm -f "$MARKER"
ln -s "$STALE_GUARD" "$CURRENT/scripts/guarded-via-link.sh"
run "$CURRENT" "$CURRENT/scripts/guarded-via-link.sh" "$CURRENT" "$CURRENT_SHA" -- "$COMMAND"
check "symlinked wrapper is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"path must not contain symlinks"* ]]'
check "symlinked wrapper never reaches deploy command" '[[ ! -e "$MARKER" ]]'
rm -f "$CURRENT/scripts/guarded-via-link.sh"

rm -f "$MARKER"
printf 'dirty\n' >>"$CURRENT/revision"
run "$CURRENT" "$GUARD" "$CURRENT" "$CURRENT_SHA" -- "$COMMAND"
check "dirty tracked wrapper source is rejected" '[[ "$RC" -ne 0 && "$OUT" == *"tracked changes"* ]]'
check "dirty tracked wrapper source never reaches deploy command" '[[ ! -e "$MARKER" ]]'
git -C "$CURRENT" checkout -- revision

# Detached release worktrees are legitimate when their root and immutable SHA bind.
rm -f "$MARKER"
run "$CURRENT" "$GUARD" "$CURRENT" "$CURRENT_SHA" -- "$COMMAND"
check "correct detached worktree is accepted" '[[ "$RC" -eq 0 && "$OUT" == *"Expected source:"* && "$OUT" == *"Actual source:"* ]]'
check "accepted request reaches deploy command" '[[ "$(cat "$MARKER")" == "deploy command ran" ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
