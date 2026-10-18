#!/usr/bin/env bash
# Hermetic regression tests for the Heimdall watchdog deploy entry point.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="$(cd "$TMP_BASE" 2>/dev/null && pwd -P)" || {
  echo 'test temporary directory does not exist or is inaccessible' >&2
  exit 1
}
TMP="$(mktemp -d "${TMP_BASE%/}/brokkr-watchdog-deploy.XXXXXX")" || {
  echo 'failed to create watchdog deploy test directory' >&2
  exit 1
}
if [[ -z "$TMP" || ! -d "$TMP" ]]; then
  echo 'mktemp did not create watchdog deploy test directory' >&2
  exit 1
fi
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"
MOCK_BIN="$TMP/bin"
REMOTE_HOME="$TMP/remote-home"
CALLS="$TMP/calls.log"
PAYLOAD_TMP="$TMP/payload-tmp"
mkdir -p "$SOURCE/scripts/lib" "$SOURCE/systemd" "$MOCK_BIN" "$REMOTE_HOME" "$PAYLOAD_TMP"
mkdir -p "$TMP/home"
cp "$REPO/scripts/deploy-agent-watchdog.sh" "$SOURCE/scripts/"
cp "$REPO/scripts/lib/deploy-source.sh" "$SOURCE/scripts/lib/"
cp "$REPO/README.md" "$SOURCE/"
cp "$REPO/systemd/heimdall-agent-watchdog.service" "$SOURCE/systemd/"
cp "$REPO/systemd/heimdall-agent-watchdog.timer" "$SOURCE/systemd/"
printf 'global-hidden export-ignore\n' >"$TMP/global-attributes"
printf '[core]\n\tattributesFile = %s\n' "$TMP/global-attributes" >"$TMP/home/.gitconfig"
printf 'tree-hidden export-ignore\n' >"$SOURCE/.gitattributes"
printf 'global attribute fixture\n' >"$SOURCE/global-hidden"
printf 'info attribute fixture\n' >"$SOURCE/info-hidden"
printf 'tree attribute fixture\n' >"$SOURCE/tree-hidden"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name 'Brokkr test'
git -C "$SOURCE" config user.email 'brokkr-test@example.invalid'
git -C "$SOURCE" add README.md scripts systemd
git -C "$SOURCE" add .gitattributes global-hidden info-hidden tree-hidden
git -C "$SOURCE" commit -qm 'test fixture'
SOURCE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
printf 'info-hidden export-ignore\n' >"$SOURCE/.git/info/attributes"

cat >"$MOCK_BIN/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
[[ "${MOCK_RSYNC_RC:-0}" == 0 ]] || exit "$MOCK_RSYNC_RC"
[[ "$*" == *"--delete"* && "$*" == *"--exclude .env*"* && "$*" == *"--exclude secrets/"* ]] || {
  echo 'mock rsync: required delete and private-path exclusions missing' >&2
  exit 90
}
source_path="${@: -2:1}"
destination="${@: -1}"
[[ "$destination" == *:~/repos/brokkr/ ]] || { echo 'mock rsync: unexpected destination' >&2; exit 91; }
destination_path="$MOCK_REMOTE_HOME/repos/brokkr"
mkdir -p "$destination_path"
if [[ -n "${MOCK_MUTATE_SOURCE:-}" ]]; then
  printf '\npost-materialization mutation\n' >>"$MOCK_MUTATE_SOURCE/README.md"
fi
# Model --delete while rsync excludes protect matching receiver paths.
find "$destination_path" -mindepth 1 -maxdepth 1 \
  ! -name '.git' ! -name '.local' ! -name '.env*' ! -name 'secrets' \
  -exec rm -rf -- {} +
cp -a "$source_path/." "$destination_path/"
EOF
cat >"$MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"$MOCK_CALLS"
exit "${MOCK_SSH_RC:-0}"
EOF
chmod +x "$MOCK_BIN/rsync" "$MOCK_BIN/ssh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
reset_remote() {
  rm -rf "$REMOTE_HOME/repos"
  mkdir -p "$REMOTE_HOME/repos/brokkr/secrets" "$REMOTE_HOME/repos/brokkr/.local"
  printf 'private root env\n' >"$REMOTE_HOME/repos/brokkr/.env"
  printf 'private nested env\n' >"$REMOTE_HOME/repos/brokkr/.env.runtime"
  printf 'private secret\n' >"$REMOTE_HOME/repos/brokkr/secrets/host.env"
  printf 'local state\n' >"$REMOTE_HOME/repos/brokkr/.local/state"
  printf 'obsolete tracked byte\n' >"$REMOTE_HOME/repos/brokkr/obsolete"
}
# shellcheck disable=SC2034 # eval-based assertions consume OUT and RC.
run() {
  local cwd=${1:-$SOURCE}
  shift || true
  local run_env=(env -i
    "PATH=$MOCK_BIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "HOME=$TMP/home"
    "TMPDIR=$PAYLOAD_TMP"
    "MOCK_CALLS=$CALLS"
    "MOCK_REMOTE_HOME=$REMOTE_HOME"
    "BROKKR_EXPECTED_SOURCE=${BIND_SOURCE-$SOURCE}"
    "BROKKR_EXPECTED_COMMIT=${BIND_COMMIT-$SOURCE_SHA}"
    "BROKKR_FLEET_TARGETS=${FLEET_TARGETS:-brokkr@control-node brokkr@nas-host brokkr@inference-host brokkr@edge-host}")
  [[ -z "${USER_REMOTE_DIR+x}" ]] || run_env+=("BROKKR_USER_REMOTE_DIR=$USER_REMOTE_DIR")
  [[ -z "${MOCK_RSYNC_RC+x}" ]] || run_env+=("MOCK_RSYNC_RC=$MOCK_RSYNC_RC")
  [[ -z "${MOCK_SSH_RC+x}" ]] || run_env+=("MOCK_SSH_RC=$MOCK_SSH_RC")
  [[ -z "${MOCK_MUTATE_SOURCE+x}" ]] || run_env+=("MOCK_MUTATE_SOURCE=$MOCK_MUTATE_SOURCE")
  OUT="$(cd "$cwd" && "${run_env[@]}" bash "$SOURCE/scripts/${ENTRY_PATH_OVERRIDE:-deploy-agent-watchdog.sh}" "$@" 2>&1)"
  RC=$?
}

echo 'deploy-agent-watchdog.test.sh'

# Binding failures must stop before either remote client.
: >"$CALLS"
BIND_COMMIT=
run
check 'missing accepted SHA refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT"* && ! -s "$CALLS" ]]'
unset BIND_COMMIT

: >"$CALLS"
BIND_COMMIT=0000000000000000000000000000000000000000
run
check 'stale source revision refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"revision does not match"* && ! -s "$CALLS" ]]'
unset BIND_COMMIT

: >"$CALLS"
BIND_SOURCE="$TMP/wrong-source"
mkdir -p "$BIND_SOURCE"
run
check 'wrong selected source refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"different directory"* && ! -s "$CALLS" ]]'
unset BIND_SOURCE

: >"$CALLS"
run "$TMP"
check 'wrong caller working directory refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"not a git worktree"* && ! -s "$CALLS" ]]'

: >"$CALLS"
printf 'tracked dirty byte\n' >>"$SOURCE/scripts/deploy-agent-watchdog.sh"
run
check 'tracked worktree modification refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"tracked changes"* && ! -s "$CALLS" ]]'
git -C "$SOURCE" checkout -- scripts/deploy-agent-watchdog.sh

: >"$CALLS"
printf 'staged dirty byte\n' >>"$SOURCE/scripts/deploy-agent-watchdog.sh"
git -C "$SOURCE" add scripts/deploy-agent-watchdog.sh
run
check 'staged worktree modification refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"tracked changes"* && ! -s "$CALLS" ]]'
git -C "$SOURCE" reset -q HEAD -- scripts/deploy-agent-watchdog.sh
git -C "$SOURCE" checkout -- scripts/deploy-agent-watchdog.sh

: >"$CALLS"
ln -s deploy-agent-watchdog.sh "$SOURCE/scripts/deploy-via-link.sh"
ENTRY_PATH_OVERRIDE=deploy-via-link.sh
run "$SOURCE" brokkr@test-host
check 'symlinked entry point refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"path must not contain symlinks"* && ! -s "$CALLS" ]]'
unset ENTRY_PATH_OVERRIDE
rm "$SOURCE/scripts/deploy-via-link.sh"

: >"$CALLS"
NEWLINE_PATH=$'line\nbreak/link/deploy-agent-watchdog.sh'
mkdir -p "$SOURCE/scripts/line
break"
ln -s "$SOURCE/scripts" "$SOURCE/scripts/line
break/link"
ENTRY_PATH_OVERRIDE="$NEWLINE_PATH"
run "$SOURCE" brokkr@test-host
check 'newline in entry path refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"path must not contain line breaks"* && ! -s "$CALLS" ]]'
unset ENTRY_PATH_OVERRIDE
rm -rf "$SOURCE/scripts/line
break"

: >"$CALLS"
USER_REMOTE_DIR=$'\x7e/repos/elsewhere'
run "$SOURCE" brokkr@test-host
check 'incoherent remote destination refuses before remote calls' '[[ $RC -ne 0 && "$OUT" == *"BROKKR_USER_REMOTE_DIR must be ~/repos/brokkr"* && ! -s "$CALLS" ]]'
unset USER_REMOTE_DIR

# Ignored and untracked private source material must not enter the committed archive.
printf 'source private env\n' >"$SOURCE/.env.local"
mkdir -p "$SOURCE/secrets"
printf 'source private secret\n' >"$SOURCE/secrets/local.env"
reset_remote
mkdir -p "$REMOTE_HOME/.config/brokkr"
printf 'preexisting unit config\n' >"$REMOTE_HOME/.config/brokkr/env"
: >"$CALLS"
MOCK_MUTATE_SOURCE="$SOURCE"
run "$SOURCE" brokkr@single-host
check 'explicit host deploy succeeds from bound archive' '[[ $RC -eq 0 && "$OUT" == *"All hosts done."* ]]'
check 'deploy syncs committed files while excluding local env and secrets' '[[ -f "$REMOTE_HOME/repos/brokkr/README.md" && ! -e "$REMOTE_HOME/repos/brokkr/.env.local" && ! -e "$REMOTE_HOME/repos/brokkr/secrets/local.env" ]]'
check 'global and repository info attributes cannot omit committed runtime files' '[[ -f "$REMOTE_HOME/repos/brokkr/global-hidden" && -f "$REMOTE_HOME/repos/brokkr/info-hidden" ]]'
check 'committed tree attributes retain their export-ignore behavior' '[[ ! -e "$REMOTE_HOME/repos/brokkr/tree-hidden" ]]'
check 'rsync keeps delete behavior and excludes private receiver paths' 'grep -Fq -- "--delete" "$CALLS" && grep -Fq -- "--exclude .env*" "$CALLS" && grep -Fq -- "--exclude secrets/" "$CALLS"'
check 'preexisting remote private env and secret paths survive deletion' '[[ "$(cat "$REMOTE_HOME/repos/brokkr/.env")" == "private root env" && "$(cat "$REMOTE_HOME/repos/brokkr/.env.runtime")" == "private nested env" && "$(cat "$REMOTE_HOME/repos/brokkr/secrets/host.env")" == "private secret" ]]'
check 'ordinary stale receiver content is still deleted' '[[ ! -e "$REMOTE_HOME/repos/brokkr/obsolete" ]]'
check 'payload bytes resist changes after archive materialization' '! grep -q "post-materialization mutation" "$REMOTE_HOME/repos/brokkr/README.md"'
check 'user unit install and timer enable behavior remains present' 'grep -Fq "install -m 0644 ~/repos/brokkr/systemd/heimdall-agent-watchdog.service" "$CALLS" && grep -Fq "systemctl --user enable --now heimdall-agent-watchdog.timer" "$CALLS"'
check 'external user configuration survives deployment' '[[ "$(cat "$REMOTE_HOME/.config/brokkr/env")" == "preexisting unit config" ]]'
check 'payload temp parent is cleaned after successful deployment' '[[ -z "$(find "$PAYLOAD_TMP" -mindepth 1 -maxdepth 1 -print -quit)" ]]'
unset MOCK_MUTATE_SOURCE
git -C "$SOURCE" checkout -- README.md

# Replacement refs and source-local/global attributes must not rewrite the accepted object.
# shellcheck disable=SC2034 # eval-based assertions consume this value.
ORIGINAL_README="$(cat "$SOURCE/README.md")"
printf 'replacement commit content\n' >>"$SOURCE/README.md"
git -C "$SOURCE" add README.md
git -C "$SOURCE" commit -qm 'replacement-only commit'
REPLACEMENT_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
git -C "$SOURCE" checkout --detach -q "$SOURCE_SHA"
git -C "$SOURCE" replace "$SOURCE_SHA" "$REPLACEMENT_SHA"
: >"$CALLS"
reset_remote
run "$SOURCE" brokkr@replace-host
check 'replacement ref cannot alter the accepted source tree' '[[ $RC -eq 0 && "$(cat "$REMOTE_HOME/repos/brokkr/README.md")" == "$ORIGINAL_README" ]]'
check 'replacement ref does not prevent a clean accepted source from deploying' '[[ $RC -eq 0 && "$OUT" == *"All hosts done."* ]]'
git -C "$SOURCE" replace -d "$SOURCE_SHA" >/dev/null

# Configured defaults are honored; explicit arguments replace them.
: >"$CALLS"
reset_remote
FLEET_TARGETS='operator@one operator@two'
run
check 'configured target list is used when no positional host is passed' '[[ $RC -eq 0 && $(grep -c "^rsync " "$CALLS") -eq 2 && $(grep -c "^ssh " "$CALLS") -eq 2 ]] && grep -Fq "operator@one" "$CALLS" && grep -Fq "operator@two" "$CALLS"'
unset FLEET_TARGETS

# A later remote failure still runs the local payload cleanup trap.
: >"$CALLS"
MOCK_RSYNC_RC=19
run "$SOURCE" brokkr@failure-host
check 'rsync failure returns failure and removes the materialized payload' '[[ $RC -ne 0 && -z "$(find "$PAYLOAD_TMP" -mindepth 1 -maxdepth 1 -print -quit)" ]]'
unset MOCK_RSYNC_RC

echo '----'
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
