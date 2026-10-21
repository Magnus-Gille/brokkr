#!/usr/bin/env bash
# Hermetic acceptance tests for the disk-backed agent worktree helper.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HELPER="${BROKKR_TEST_HELPER:-$ROOT/scripts/agent-worktree.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/brokkr-agent-worktree.XXXXXX")
BIN="$TMP/bin"
mkdir -p "$BIN"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'agent-worktree.test.sh: FAIL: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  if "$@" >"$TMP/expected-fail.out" 2>"$TMP/expected-fail.err"; then
    fail "expected command to fail: $*"
  fi
}

cat >"$BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then
  path=$4
  if [ "$path" = "${BROKKR_TEST_OTHER_OWNER_PATH:-}" ]; then
    case "$2" in
      %A) printf 'drwxr-xr-x\n' ;;
      %u) printf '424242\n' ;;
      *) exit 1 ;;
    esac
    exit $?
  fi
  if [ "$path" = "${BROKKR_TEST_MALFORMED_UID_PATH:-}" ] && [ "$2" = %u ]; then
    printf 'not-a-uid\n'
    exit 0
  fi
  case "$2" in
    %A) ls -ldn "$path" | awk 'NR == 1 { print $1 }' ;;
    %u) ls -ldn "$path" | awk 'NR == 1 { print $3 }' ;;
    *) exit 1 ;;
  esac
  exit $?
fi
case "${BROKKR_TEST_STAT_MODE:-disk}" in
  disk) printf 'ext2/ext3\n' ;;
  tmpfs) printf 'tmpfs\n' ;;
  ramfs) printf 'ramfs\n' ;;
  hugetlbfs) printf 'hugetlbfs\n' ;;
  fail) exit 1 ;;
  *) printf 'unknown\n' ;;
esac
EOF
chmod 755 "$BIN/stat"

make_repo() {
  local repo=$1
  mkdir -p "$(dirname "$repo")"
  git init -q "$repo"
  git -C "$repo" config user.name 'Brokkr Test'
  git -C "$repo" config user.email 'brokkr-test@example.invalid'
  printf 'seed\n' >"$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm seed
}

run_helper() {
  PATH="$BIN:$PATH" BROKKR_WORKTREE_ROOT="$TEST_ROOT" "$HELPER" "$@"
}

run_helper_at_home() {
  PATH="$BIN:$PATH" HOME="$TEST_HOME" BROKKR_WORKTREE_ROOT="$TEST_ROOT" "$HELPER" "$@"
}

run_helper_default() {
  env -u BROKKR_WORKTREE_ROOT -u XDG_STATE_HOME \
    PATH="$BIN:$PATH" HOME="$TEST_HOME" "$HELPER" "$@"
}

make_repo "$TMP/repos/space parent/repo one"
make_repo "$TMP/other parent/repo one"
REPO="$TMP/repos/space parent/repo one"
REPO_OTHER="$TMP/other parent/repo one"
mkdir -p "$REPO/nested/path"
git init -q --bare "$TMP/bare.git"

TEST_ROOT="$TMP/state root/worktrees"
export TEST_ROOT

HELP=$(PATH="$BIN:$PATH" "$HELPER" --help 2>&1) || fail '--help failed'
printf '%s\n' "$HELP" | grep -F -- '--repo PATH' >/dev/null || fail '--help omitted --repo'

BROKKR_TEST_STAT_MODE=disk
export BROKKR_TEST_STAT_MODE
TARGET_ONE=$(run_helper --repo "$REPO" --name 'leaf.one' --branch 'leaf/one')
test -d "$TARGET_ONE" || fail 'disk-backed worktree was not created'
test -f "$TARGET_ONE/README" || fail 'worktree contents missing'

UNSAFE_ROOT="$TMP/unsafe-root"
mkdir -p "$UNSAFE_ROOT"
chmod 0777 "$UNSAFE_ROOT"
TEST_ROOT="$UNSAFE_ROOT"
export TEST_ROOT
expect_fail run_helper --repo "$REPO" --name unsafe-root --branch reject/unsafe-root
test ! -e "$UNSAFE_ROOT/unsafe-root" || fail '0777 root was accepted'

UNSAFE_ANCESTOR="$TMP/unsafe-ancestor"
mkdir -p "$UNSAFE_ANCESTOR"
chmod 0777 "$UNSAFE_ANCESTOR"
TEST_ROOT="$UNSAFE_ANCESTOR/new-root"
export TEST_ROOT
expect_fail run_helper --repo "$REPO" --name unsafe-ancestor --branch reject/unsafe-ancestor
test ! -e "$TEST_ROOT" || fail '0777 ancestor was accepted'

OTHER_OWNER_PATH="$TMP/other-owner-ancestor"
mkdir -p "$OTHER_OWNER_PATH"
chmod 0755 "$OTHER_OWNER_PATH"
OTHER_OWNER_PATH=$(cd -P "$OTHER_OWNER_PATH" && pwd -P)
TEST_ROOT="$OTHER_OWNER_PATH/new-root"
BROKKR_TEST_OTHER_OWNER_PATH="$OTHER_OWNER_PATH"
export TEST_ROOT BROKKR_TEST_OTHER_OWNER_PATH
before_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
expect_fail run_helper --repo "$REPO" --name other-owner --branch reject/other-owner
test ! -e "$TEST_ROOT" || fail 'other-owner ancestor was accepted'
after_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
test "$before_worktrees" -eq "$after_worktrees" || fail 'other-owner rejection mutated git worktrees'
unset BROKKR_TEST_OTHER_OWNER_PATH

MALFORMED_UID_PATH="$TMP/malformed-owner-ancestor"
mkdir -p "$MALFORMED_UID_PATH"
MALFORMED_UID_PATH=$(cd -P "$MALFORMED_UID_PATH" && pwd -P)
TEST_ROOT="$MALFORMED_UID_PATH/new-root"
BROKKR_TEST_MALFORMED_UID_PATH="$MALFORMED_UID_PATH"
export TEST_ROOT BROKKR_TEST_MALFORMED_UID_PATH
before_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
expect_fail run_helper --repo "$REPO" --name malformed-owner --branch reject/malformed-owner
test ! -e "$TEST_ROOT" || fail 'malformed owner ancestor was accepted'
after_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
test "$before_worktrees" -eq "$after_worktrees" || fail 'malformed-owner rejection mutated git worktrees'
unset BROKKR_TEST_MALFORMED_UID_PATH

PRIVATE_HOME="$TMP/private-home"
mkdir -p "$PRIVATE_HOME/.local/state/brokkr"
chmod 0700 "$PRIVATE_HOME"
chmod 0775 "$PRIVATE_HOME/.local" "$PRIVATE_HOME/.local/state" "$PRIVATE_HOME/.local/state/brokkr"
TEST_HOME="$PRIVATE_HOME"
TEST_ROOT="$PRIVATE_HOME/.local/state/brokkr/worktrees"
export TEST_HOME TEST_ROOT
TARGET_PRIVATE=$(run_helper_at_home --repo "$REPO" --name private-home --branch leaf/private-home)
test -d "$TARGET_PRIVATE" || fail 'private HOME with writable state parents was rejected'

PRIVATE_UNSAFE_ROOT="$PRIVATE_HOME/.local/state/brokkr/unsafe-root"
mkdir -p "$PRIVATE_UNSAFE_ROOT"
chmod 0777 "$PRIVATE_UNSAFE_ROOT"
TEST_ROOT="$PRIVATE_UNSAFE_ROOT"
export TEST_ROOT
expect_fail run_helper_at_home --repo "$REPO" --name private-unsafe --branch reject/private-unsafe
test ! -e "$PRIVATE_UNSAFE_ROOT/private-unsafe" || fail '0777 root inside private HOME was accepted'

PUBLIC_HOME="$TMP/public-home"
mkdir -p "$PUBLIC_HOME/.local/state/brokkr"
chmod 0755 "$PUBLIC_HOME"
chmod 0775 "$PUBLIC_HOME/.local" "$PUBLIC_HOME/.local/state" "$PUBLIC_HOME/.local/state/brokkr"
TEST_HOME="$PUBLIC_HOME"
TEST_ROOT="$PUBLIC_HOME/.local/state/brokkr/rejected-root"
export TEST_HOME TEST_ROOT
expect_fail run_helper_at_home --repo "$REPO" --name public-home --branch reject/public-home
test ! -e "$TEST_ROOT" || fail 'writable state parent under non-private HOME was accepted'

DEFAULT_HOME="$TMP/default-home"
mkdir -p "$DEFAULT_HOME"
chmod 0700 "$DEFAULT_HOME"
DEFAULT_HOME=$(cd -P "$DEFAULT_HOME" && pwd -P)
TEST_HOME="$DEFAULT_HOME"
export TEST_HOME
DEFAULT_TARGET=$(umask 0002; run_helper_default --repo "$REPO" --name default-umask --branch leaf/default-umask)
test -d "$DEFAULT_TARGET" || fail 'default HOME worktree was not created'
for private_dir in \
  "$DEFAULT_HOME/.local" \
  "$DEFAULT_HOME/.local/state" \
  "$DEFAULT_HOME/.local/state/brokkr" \
  "$DEFAULT_HOME/.local/state/brokkr/worktrees"; do
  private_mode=$(ls -ldn "$private_dir" | awk 'NR == 1 { print $1 }')
  case "$private_mode" in
    drwx------|drwx------@|drwx------+) ;;
    *) fail "default-created directory is not private: $private_dir ($private_mode)" ;;
  esac
done

TEST_ROOT="$TMP/state root/worktrees"
export TEST_ROOT

TARGET_NESTED=$(run_helper --repo "$REPO/nested/path" --name nested-leaf --branch leaf/nested)
test "$(dirname "$TARGET_ONE")" = "$(dirname "$TARGET_NESTED")" \
  || fail 'nested repository invocation changed namespace'

LINKED_REPO="$TMP/linked source"
git -C "$REPO" worktree add -q -b linked-source "$LINKED_REPO" HEAD
TARGET_LINKED=$(run_helper --repo "$LINKED_REPO" --name linked-leaf --branch leaf/linked)
test "$(dirname "$TARGET_ONE")" = "$(dirname "$TARGET_LINKED")" \
  || fail 'linked worktree invocation changed namespace'

before_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
expect_fail run_helper --repo "$REPO" --name 'leaf.one' --branch 'leaf/one-again'
after_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
test "$before_worktrees" -eq "$after_worktrees" || fail 'existing target changed worktree count'

NAMESPACE_DIR=$(dirname "$TARGET_ONE")
chmod 0777 "$NAMESPACE_DIR"
TEST_ROOT="$TMP/state root/worktrees"
export TEST_ROOT
expect_fail run_helper --repo "$REPO" --name unsafe-namespace --branch reject/unsafe-namespace
chmod 0700 "$NAMESPACE_DIR"

TARGET_SYMLINK_DIR=$(dirname "$TARGET_ONE")
ln -s "$REPO" "$TARGET_SYMLINK_DIR/symlink-target"
expect_fail run_helper --repo "$REPO" --name symlink-target --branch leaf/symlink

expect_fail run_helper --repo "$REPO" --name . --branch leaf/dot
expect_fail run_helper --repo "$REPO" --name .. --branch leaf/dotdot
expect_fail run_helper --repo "$REPO" --name 'bad/name' --branch leaf/slash
expect_fail run_helper --repo "$REPO" --name 'bad name' --branch leaf/space

expect_fail run_helper --repo "$REPO" --name invalid-branch-space --branch 'bad branch'
expect_fail run_helper --repo "$REPO" --name invalid-branch-dots --branch 'bad..branch'
expect_fail run_helper --repo "$REPO" --name invalid-branch-dash --branch '-bad'

expect_fail run_helper --repo "$REPO" --name invalid-ref-missing --branch ref/missing --ref missing-ref
expect_fail run_helper --repo "$REPO" --name invalid-ref-option --branch ref/option --ref --missing-ref
expect_fail run_helper --repo "$TMP/bare.git" --name bare-leaf --branch bare/branch

for fs_type in tmpfs ramfs hugetlbfs; do
  TEST_ROOT="$TMP/reject-$fs_type/root"
  export TEST_ROOT
  BROKKR_TEST_STAT_MODE="$fs_type"
  export BROKKR_TEST_STAT_MODE
  before_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
  expect_fail run_helper --repo "$REPO" --name "reject-$fs_type" --branch "reject/$fs_type"
  test ! -e "$TEST_ROOT" || fail "$fs_type root was created before rejection"
  after_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
  test "$before_worktrees" -eq "$after_worktrees" || fail "$fs_type rejection mutated git worktrees"
done

TEST_ROOT="$TMP/reject-stat/root"
BROKKR_TEST_STAT_MODE=fail
export TEST_ROOT BROKKR_TEST_STAT_MODE
before_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
expect_fail run_helper --repo "$REPO" --name reject-stat --branch reject/stat
test ! -e "$TEST_ROOT" || fail 'stat failure created the root'
after_worktrees=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')
test "$before_worktrees" -eq "$after_worktrees" || fail 'stat failure mutated git worktrees'

BROKKR_TEST_STAT_MODE=disk
export BROKKR_TEST_STAT_MODE
REAL_ROOT="$TMP/real-root"
mkdir -p "$REAL_ROOT"
TEST_ROOT="$TMP/symlink-root"
ln -s "$REAL_ROOT" "$TEST_ROOT"
export TEST_ROOT
expect_fail run_helper --repo "$REPO" --name reject-root-link --branch reject/root-link
test ! -e "$REAL_ROOT/reject-root-link" || fail 'symlink root was followed'

BROKKR_TEST_STAT_MODE=tmpfs
export BROKKR_TEST_STAT_MODE
SYMLINK_TARGET="$TMP/symlink-target"
SYMLINK_PARENT="$TMP/symlink-parent"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_PARENT"
TEST_ROOT="$SYMLINK_PARENT/new-root"
export TEST_ROOT
expect_fail run_helper --repo "$REPO" --name reject-ancestor --branch reject/ancestor
test ! -e "$SYMLINK_TARGET/new-root" || fail 'tmpfs ancestor root was created'

BROKKR_TEST_STAT_MODE=disk
export BROKKR_TEST_STAT_MODE
TEST_ROOT="$TMP/state root/worktrees"
export TEST_ROOT
TARGET_OTHER=$(run_helper --repo "$REPO_OTHER" --name 'leaf.one' --branch leaf/other)
test -d "$TARGET_OTHER" || fail 'second disk-backed worktree was not created'
test "$TARGET_ONE" != "$TARGET_OTHER" || fail 'same-basename repositories collided'
test "$(basename "$(dirname "$TARGET_ONE")")" != "$(basename "$(dirname "$TARGET_OTHER")")" \
  || fail 'repository namespace directories collided'

printf 'agent-worktree.test.sh: PASS\n'
