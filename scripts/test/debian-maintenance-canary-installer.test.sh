#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
INSTALL_ROOT="$TMP/install-root"
SYSTEMCTL_LOG="$TMP/systemctl.log"
NODE_BIN="$(command -v node)"
mkdir -p "$SOURCE/scripts/lib" "$SOURCE/systemd"
cp "$ROOT/scripts/debian-maintenance-host-adapter.mjs" "$SOURCE/scripts/"
cp "$ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs" \
  "$ROOT/scripts/lib/bounded-recovery-dispatch.mjs" "$SOURCE/scripts/lib/"
cp "$ROOT/systemd/brokkr-debian-maintenance-recovery.service.in" "$SOURCE/systemd/"
cp "$ROOT/scripts/install-debian-maintenance-canary.sh" "$SOURCE/scripts/"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name "Brokkr hermetic test"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm "fixture"
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

wrong_revision() {
  local revision="$1" alternate=0
  if [[ "$revision" == *0 ]]; then
    alternate=1
  fi
  printf '%s%s\n' "${revision%?}" "$alternate"
}

# A wrong revision must remain distinct when the valid revision ends in 0.
COLLISION_REVISION=0000000000000000000000000000000000000000
COLLISION_WRONG_REVISION="$(wrong_revision "$COLLISION_REVISION")"
if [[ ! "$COLLISION_WRONG_REVISION" =~ ^[a-f0-9]{40}$ ]]; then
  echo "wrong revision fixture is not a lowercase hexadecimal SHA" >&2
  exit 1
fi
if [[ "$COLLISION_WRONG_REVISION" == "$COLLISION_REVISION" ]]; then
  echo "wrong revision fixture collided with valid revision" >&2
  exit 1
fi
if [[ "$COLLISION_WRONG_REVISION" != "${COLLISION_REVISION%?}1" ]]; then
  echo "wrong revision fixture did not map a 0-ending SHA to suffix 1" >&2
  exit 1
fi

# A non-zero-ending SHA must take the zero-suffix branch deterministically.
NONZERO_ENDING_REVISION=000000000000000000000000000000000000000f
NONZERO_ENDING_WRONG_REVISION="$(wrong_revision "$NONZERO_ENDING_REVISION")"
if [[ ! "$NONZERO_ENDING_WRONG_REVISION" =~ ^[a-f0-9]{40}$ ]]; then
  echo "wrong revision fixture is not a lowercase hexadecimal SHA for a non-zero-ending input" >&2
  exit 1
fi
if [[ "$NONZERO_ENDING_WRONG_REVISION" == "$NONZERO_ENDING_REVISION" ]]; then
  echo "wrong revision fixture collided for a non-zero-ending input" >&2
  exit 1
fi
if [[ "$NONZERO_ENDING_WRONG_REVISION" != "${NONZERO_ENDING_REVISION%?}0" ]]; then
  echo "wrong revision fixture did not map a non-zero-ending SHA to suffix 0" >&2
  exit 1
fi

WRONG_REVISION="$(wrong_revision "$REVISION")"
if [[ ! "$WRONG_REVISION" =~ ^[a-f0-9]{40}$ ]]; then
  echo "wrong revision for generated revision is not a lowercase hexadecimal SHA" >&2
  exit 1
fi
if [[ "$WRONG_REVISION" == "$REVISION" ]]; then
  echo "wrong revision for generated revision collided with valid revision" >&2
  exit 1
fi

cat >"$TMP/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BROKKR_TEST_SYSTEMCTL_LOG"
if [[ "${BROKKR_TEST_SYSTEMCTL_FAIL:-0}" == "1" &&
  "${1:-}" == "disable" ]]; then
  exit 23
fi
SH
chmod 0755 "$TMP/systemctl"

cat >"$TMP/fallocate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-l" ]]
case "$2" in
  8M) bytes=$((8 * 1024 * 1024)) ;;
  *) exit 64 ;;
esac
dd if=/dev/zero of="$3" bs=1048576 count=$((bytes / 1048576)) status=none
SH
chmod 0755 "$TMP/fallocate"

INSTALLER="$ROOT/scripts/install-debian-maintenance-canary.sh"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi

RELEASE_ROOT="$INSTALL_ROOT/usr/local/lib/brokkr/releases/$REVISION"
STATE_ROOT="$INSTALL_ROOT/var/lib/brokkr/debian-maintenance"
APPLY_UNIT="$INSTALL_ROOT/etc/systemd/system/brokkr-debian-maintenance-canary-canary-fi.service"
RECOVERY_UNIT="$INSTALL_ROOT/etc/systemd/system/brokkr-debian-maintenance-recovery-canary-fi.service"

test -x "$RELEASE_ROOT/scripts/debian-maintenance-host-adapter.mjs"
test -r "$RELEASE_ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs"
test -r "$RELEASE_ROOT/scripts/lib/bounded-recovery-dispatch.mjs"
test -r "$RELEASE_ROOT/systemd/brokkr-debian-maintenance-recovery.service.in"
for file in \
  scripts/debian-maintenance-host-adapter.mjs \
  scripts/lib/fixed-debian-maintenance-host-operation.mjs \
  scripts/lib/bounded-recovery-dispatch.mjs \
  systemd/brokkr-debian-maintenance-recovery.service.in; do
  git -C "$SOURCE" show "$REVISION:$file" >"$TMP/expected-commit-file"
  cmp "$TMP/expected-commit-file" "$RELEASE_ROOT/$file"
done
grep -Fqx "Environment=BROKKR_RELEASE_SHA=$REVISION" "$APPLY_UNIT"
grep -Fqx \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-host-adapter.mjs --action apply --attempt canary-fi" \
  "$APPLY_UNIT"
grep -Fqx \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-host-adapter.mjs --action recover --attempt canary-fi" \
  "$RECOVERY_UNIT"
sed \
  -e 's/@CANARY_ID@/canary-fi/g' \
  -e "s/@RELEASE_SHA@/$REVISION/g" \
  "$SOURCE/systemd/brokkr-debian-maintenance-recovery.service.in" \
  >"$TMP/expected-recovery.service"
cmp "$TMP/expected-recovery.service" "$RECOVERY_UNIT"
grep -Fqx "NoNewPrivileges=yes" "$APPLY_UNIT"
grep -Fqx "ProtectKernelTunables=yes" "$APPLY_UNIT"
grep -Fqx "ProtectControlGroups=yes" "$APPLY_UNIT"
grep -Fqx "RestrictSUIDSGID=yes" "$APPLY_UNIT"
grep -Fqx \
  "ExecCondition=/usr/bin/test ! -e /var/lib/brokkr/debian-maintenance/disarmed/canary-fi.json" \
  "$APPLY_UNIT"
! grep -Eq '^(WantedBy=|OnFailure=)' "$APPLY_UNIT"
test ! -e "$SYSTEMCTL_LOG"

# Exact replay is byte-idempotent: neither immutable release nor concrete units
# are overwritten.
node --input-type=module - \
  "$RELEASE_ROOT/scripts/debian-maintenance-host-adapter.mjs" \
  "$APPLY_UNIT" "$RECOVERY_UNIT" >"$TMP/install-inodes.before" <<'NODE'
import fs from "node:fs";
for (const file of process.argv.slice(2)) {
  process.stdout.write(`${fs.statSync(file).ino}\n`);
}
NODE
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi
node --input-type=module - \
  "$RELEASE_ROOT/scripts/debian-maintenance-host-adapter.mjs" \
  "$APPLY_UNIT" "$RECOVERY_UNIT" >"$TMP/install-inodes.after" <<'NODE'
import fs from "node:fs";
for (const file of process.argv.slice(2)) {
  process.stdout.write(`${fs.statSync(file).ino}\n`);
}
NODE
cmp "$TMP/install-inodes.before" "$TMP/install-inodes.after"

node --input-type=module - "$STATE_ROOT" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
const root = process.argv[2];
for (const directory of [
  root, "requests", "registrations", "fences", "journals", "terminals",
  "recovery-activations", "recovery-authorizations", "disarmed", "evidence",
].map(value => value === root ? value : path.join(root, value))) {
  assert.equal(fs.statSync(directory).mode & 0o777, 0o700, directory);
}
for (const reserve of ["journal.reserve", "evidence.reserve"]) {
  const file = path.join(root, "headroom", reserve);
  assert.equal(fs.statSync(file).size, 8 * 1024 * 1024, reserve);
  assert.equal(fs.statSync(file).blocks * 512 >= 8 * 1024 * 1024, true,
    `${reserve} must be physically allocated, not sparse`);
}
NODE

# A test-only hook mutates the checked-out file after source verification. The
# installed bytes still come from the named commit object, never the worktree.
cat >"$TMP/mutate-after-verify" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '\n// post-verification worktree mutation\n' \
  >>"$1/scripts/debian-maintenance-host-adapter.mjs"
SH
chmod 0755 "$TMP/mutate-after-verify"
TOCTOU_ROOT="$TMP/toctou-root"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$TOCTOU_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_CANARY_AFTER_SOURCE_VERIFY_HOOK="$TMP/mutate-after-verify" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/toctou-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-race
git -C "$SOURCE" show \
  "$REVISION:scripts/debian-maintenance-host-adapter.mjs" \
  >"$TMP/expected-race-adapter"
RACE_RELEASE="$TOCTOU_ROOT/usr/local/lib/brokkr/releases/$REVISION"
cmp "$TMP/expected-race-adapter" \
  "$RACE_RELEASE/scripts/debian-maintenance-host-adapter.mjs"
! cmp -s "$SOURCE/scripts/debian-maintenance-host-adapter.mjs" \
  "$RACE_RELEASE/scripts/debian-maintenance-host-adapter.mjs"
git -C "$SOURCE" checkout -- scripts/debian-maintenance-host-adapter.mjs

# A divergent existing release is immutable: reinstall fails without repairing
# or overwriting the conflicting bytes.
printf '\n// retained-release-conflict\n' \
  >>"$RACE_RELEASE/scripts/debian-maintenance-host-adapter.mjs"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$TOCTOU_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/toctou-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-race >"$TMP/release-conflict.out" 2>&1; then
  echo "divergent existing release unexpectedly overwritten" >&2
  exit 1
fi
grep -Fq "existing release differs from exact revision" \
  "$TMP/release-conflict.out"
grep -Fq "retained-release-conflict" \
  "$RACE_RELEASE/scripts/debian-maintenance-host-adapter.mjs"

# A same-canary unit already bound to another revision refuses before creating
# release/state paths or changing either installed unit.
UNIT_CONFLICT_ROOT="$TMP/unit-conflict-root"
UNIT_CONFLICT_DIR="$UNIT_CONFLICT_ROOT/etc/systemd/system"
mkdir -p "$UNIT_CONFLICT_DIR"
OTHER_REVISION="ffffffffffffffffffffffffffffffffffffffff"
[[ "$OTHER_REVISION" != "$REVISION" ]] ||
  OTHER_REVISION="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$OTHER_REVISION" \
  >"$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-canary-canary-fi.service"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$OTHER_REVISION" \
  >"$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-recovery-canary-fi.service"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$UNIT_CONFLICT_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/unit-conflict-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi >"$TMP/unit-conflict.out" 2>&1; then
  echo "different-revision canary units unexpectedly overwritten" >&2
  exit 1
fi
grep -Fq "installed canary revision does not match" \
  "$TMP/unit-conflict.out"
test ! -e "$UNIT_CONFLICT_ROOT/usr"
test ! -e "$UNIT_CONFLICT_ROOT/var"
grep -Fqx "Environment=BROKKR_RELEASE_SHA=$OTHER_REVISION" \
  "$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-canary-canary-fi.service"

# Same-revision content does not excuse unsafe unit metadata.
UNSAFE_UNIT_ROOT="$TMP/unsafe-unit-root"
UNSAFE_UNIT_DIR="$UNSAFE_UNIT_ROOT/etc/systemd/system"
mkdir -p "$UNSAFE_UNIT_DIR"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$REVISION" \
  >"$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-canary-canary-fi.service"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$REVISION" \
  >"$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-recovery-canary-fi.service"
chmod 0666 \
  "$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-canary-canary-fi.service"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$UNSAFE_UNIT_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/unsafe-unit-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi >"$TMP/unsafe-unit.out" 2>&1; then
  echo "world-writable existing unit unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "install_path_unsafe" "$TMP/unsafe-unit.out"
test ! -e "$UNSAFE_UNIT_ROOT/usr"
test ! -e "$UNSAFE_UNIT_ROOT/var"
node --input-type=module - \
  "$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-canary-canary-fi.service" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
assert.equal(fs.statSync(process.argv[2]).mode & 0o777, 0o666);
NODE

# A release-path symlink is refused rather than followed or replaced.
SYMLINK_ROOT="$TMP/symlink-root"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$SYMLINK_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/symlink-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-symlink
SYMLINK_RELEASE_PARENT="$SYMLINK_ROOT/usr/local/lib/brokkr/releases"
mv "$SYMLINK_RELEASE_PARENT/$REVISION" \
  "$SYMLINK_RELEASE_PARENT/retained-release"
ln -s retained-release "$SYMLINK_RELEASE_PARENT/$REVISION"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$SYMLINK_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/symlink-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-symlink >"$TMP/symlink.out" 2>&1; then
  echo "symlinked release unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "install_path_unsafe" "$TMP/symlink.out"
test -L "$SYMLINK_RELEASE_PARENT/$REVISION"
cmp "$TMP/expected-race-adapter" \
  "$SYMLINK_RELEASE_PARENT/retained-release/scripts/debian-maintenance-host-adapter.mjs"

# Same-content release bytes with a non-executable adapter are not an
# operationally identical replay.
MODE_ROOT="$TMP/mode-root"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$MODE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/mode-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-mode
MODE_ADAPTER="$MODE_ROOT/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-host-adapter.mjs"
chmod 0600 "$MODE_ADAPTER"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$MODE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/mode-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-mode >"$TMP/mode.out" 2>&1; then
  echo "non-executable exact-content adapter unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "install_release_metadata_mismatch" "$TMP/mode.out"
node --input-type=module - "$MODE_ADAPTER" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
assert.equal(fs.statSync(process.argv[2]).mode & 0o7777, 0o600);
NODE

# A logically sized but sparse existing reserve is not accepted as emergency
# journal/evidence capacity.
SPARSE_ROOT="$TMP/sparse-root"
SPARSE_HEADROOM="$SPARSE_ROOT/var/lib/brokkr/debian-maintenance/headroom"
mkdir -p "$SPARSE_HEADROOM"
chmod 0700 \
  "$SPARSE_ROOT/var/lib/brokkr/debian-maintenance" \
  "$SPARSE_HEADROOM"
dd if=/dev/null of="$SPARSE_HEADROOM/journal.reserve" \
  bs=1 seek=8388608 status=none
chmod 0600 "$SPARSE_HEADROOM/journal.reserve"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$SPARSE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/sparse-systemctl.log" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-sparse >"$TMP/sparse.out" 2>&1; then
  echo "sparse existing headroom unexpectedly accepted" >&2
  exit 1
fi
grep -Fq "install_headroom_reserve_unsafe" "$TMP/sparse.out"
test ! -e "$SPARSE_ROOT/etc"
test ! -e "$SPARSE_ROOT/usr"

# Invalid tracked template content fails during staging, before either concrete
# unit or immutable release is published.
BROKEN_SOURCE="$TMP/broken-source"
git clone -q "$SOURCE" "$BROKEN_SOURCE"
git -C "$BROKEN_SOURCE" config user.email test@example.invalid
git -C "$BROKEN_SOURCE" config user.name "Brokkr hermetic test"
printf '\nEnvironment=BROKKR_UNRESOLVED=@unresolved_value@\n' \
  >>"$BROKEN_SOURCE/systemd/brokkr-debian-maintenance-recovery.service.in"
git -C "$BROKEN_SOURCE" add \
  systemd/brokkr-debian-maintenance-recovery.service.in
git -C "$BROKEN_SOURCE" commit -qm "broken template"
BROKEN_REVISION="$(git -C "$BROKEN_SOURCE" rev-parse HEAD)"
BROKEN_ROOT="$TMP/broken-root"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$BROKEN_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/broken-systemctl.log" \
  "$INSTALLER" install \
    --source "$BROKEN_SOURCE" \
    --revision "$BROKEN_REVISION" \
    --canary canary-broken >"$TMP/broken.out" 2>&1; then
  echo "unresolved unit template unexpectedly installed" >&2
  exit 1
fi
grep -Fq "recovery unit template has unresolved placeholders" \
  "$TMP/broken.out"
test ! -e \
  "$BROKEN_ROOT/etc/systemd/system/brokkr-debian-maintenance-canary-canary-broken.service"
test ! -e \
  "$BROKEN_ROOT/etc/systemd/system/brokkr-debian-maintenance-recovery-canary-broken.service"
test ! -e \
  "$BROKEN_ROOT/usr/local/lib/brokkr/releases/$BROKEN_REVISION"

# Disable persists the fail-closed marker before systemd. Even when disable
# fails, both stop attempts occur and the marker/evidence remain durable.
STOP_FAILURE_ROOT="$TMP/stop-failure-root"
STOP_FAILURE_LOG="$TMP/stop-failure-systemctl.log"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$STOP_FAILURE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$STOP_FAILURE_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-stop-failure
STOP_FAILURE_STATE="$STOP_FAILURE_ROOT/var/lib/brokkr/debian-maintenance"
printf '%s\n' '{"redacted":"retained-on-stop-failure"}' \
  >"$STOP_FAILURE_STATE/evidence/canary-stop-failure.json"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$STOP_FAILURE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$STOP_FAILURE_LOG" \
  BROKKR_TEST_SYSTEMCTL_FAIL=1 \
  "$INSTALLER" disable \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-stop-failure >"$TMP/stop-failure.out" 2>&1; then
  echo "systemd disable failure unexpectedly reported success" >&2
  exit 1
fi
grep -Fq "disarm marker persisted but systemd stop failed" \
  "$TMP/stop-failure.out"
test -r \
  "$STOP_FAILURE_STATE/disarmed/canary-stop-failure.json"
test -r \
  "$STOP_FAILURE_STATE/evidence/canary-stop-failure.json"
grep -Fqx \
  "disable --now brokkr-debian-maintenance-canary-canary-stop-failure.service" \
  "$STOP_FAILURE_LOG"
grep -Fqx \
  "stop brokkr-debian-maintenance-recovery-canary-stop-failure.service" \
  "$STOP_FAILURE_LOG"

printf '%s\n' '{"redacted":"evidence-preserved"}' \
  >"$STATE_ROOT/evidence/canary-fi.json"
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" disable \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi

grep -Fqx "disable --now brokkr-debian-maintenance-canary-canary-fi.service" \
  "$SYSTEMCTL_LOG"
grep -Fqx "stop brokkr-debian-maintenance-recovery-canary-fi.service" \
  "$SYSTEMCTL_LOG"
test -r "$STATE_ROOT/evidence/canary-fi.json"
test -r "$STATE_ROOT/disarmed/canary-fi.json"
test -d "$RELEASE_ROOT"
test -r "$STATE_ROOT/headroom/journal.reserve"
test -r "$STATE_ROOT/headroom/evidence.reserve"
grep -Fq "\"release_sha\":\"$REVISION\"" \
  "$STATE_ROOT/disarmed/canary-fi.json"
grep -Fq '"evidence_preserved":true' \
  "$STATE_ROOT/disarmed/canary-fi.json"

# Exact replay remains disable-only and preserves all evidence.
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" disable \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi
test -r "$STATE_ROOT/evidence/canary-fi.json"

WRONG_REVISION="${REVISION%?}0"
if [[ "$WRONG_REVISION" == "$REVISION" ]]; then
  WRONG_REVISION="${REVISION%?}1"
fi
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$TMP/wrong-revision-root" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$WRONG_REVISION" \
    --canary canary-fi >"$TMP/wrong.out" 2>&1; then
  echo "wrong revision unexpectedly installed" >&2
  exit 1
fi
grep -Fq "source revision does not match" "$TMP/wrong.out"
test ! -e "$TMP/wrong-revision-root/etc"

printf '\n# dirty\n' >>"$SOURCE/scripts/debian-maintenance-host-adapter.mjs"
if env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$TMP/dirty-root" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$REVISION" \
    --canary canary-fi >"$TMP/dirty.out" 2>&1; then
  echo "dirty source unexpectedly installed" >&2
  exit 1
fi
grep -Fq "source worktree is dirty" "$TMP/dirty.out"
test ! -e "$TMP/dirty-root/etc"

echo "debian canary installer: exact revision, disabled units, headroom, and evidence-preserving disarm OK"
