#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
INSTALL_ROOT="$TMP/install-root"
SYSTEMCTL_LOG="$TMP/systemctl.log"
NODE_BIN="$(command -v node)"
mkdir -p "$SOURCE/docs" "$SOURCE/scripts/lib" "$SOURCE/systemd"
cp \
  "$ROOT/docs/autonomy-constitution-v2.schema.json" \
  "$ROOT/docs/autonomy-coverage-registry-v2.schema.json" \
  "$ROOT/docs/autonomy-owner-attestation-registry-v1.schema.json" \
  "$ROOT/docs/autonomy-owner-authorization-v1.schema.json" \
  "$ROOT/docs/autonomy-recovery-worker-registry-v1.schema.json" \
  "$ROOT/docs/autonomy-runtime-narrowing-v1.schema.json" \
  "$ROOT/docs/autonomous-mutation-journal-v2.schema.json" \
  "$ROOT/docs/debian-maintenance-attempt-factory-config-v1.schema.json" \
  "$ROOT/docs/debian-maintenance-window-freshness-v1.schema.json" \
  "$SOURCE/docs/"
cp \
  "$ROOT/scripts/debian-maintenance-attempt-factory.mjs" \
  "$ROOT/scripts/debian-maintenance-autonomy.mjs" \
  "$ROOT/scripts/debian-maintenance-executor.mjs" \
  "$ROOT/scripts/debian-maintenance-host-adapter.mjs" \
  "$ROOT/scripts/maintenance-controller.mjs" \
  "$SOURCE/scripts/"
cp "$ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs" \
  "$ROOT/scripts/lib/autonomy-authorization.mjs" \
  "$ROOT/scripts/lib/debian-maintenance-attempt-factory.mjs" \
  "$ROOT/scripts/lib/maintenance-policy-contract.mjs" \
  "$ROOT/scripts/lib/bounded-recovery-dispatch.mjs" "$SOURCE/scripts/lib/"
cp \
  "$ROOT/systemd/brokkr-debian-maintenance-attempt-factory.service.in" \
  "$ROOT/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
  "$ROOT/systemd/brokkr-debian-maintenance-recovery.service.in" \
  "$SOURCE/systemd/"
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
RECOVERY_UNIT="$INSTALL_ROOT/etc/systemd/system/brokkr-debian-maintenance-recovery@.service"
FACTORY_UNIT="$INSTALL_ROOT/etc/systemd/system/brokkr-debian-maintenance-attempt-factory.service"
FACTORY_TIMER="$INSTALL_ROOT/etc/systemd/system/brokkr-debian-maintenance-attempt-factory.timer"

test -x "$RELEASE_ROOT/scripts/debian-maintenance-host-adapter.mjs"
test -x "$RELEASE_ROOT/scripts/debian-maintenance-attempt-factory.mjs"
test -r "$RELEASE_ROOT/scripts/lib/fixed-debian-maintenance-host-operation.mjs"
test -r "$RELEASE_ROOT/scripts/lib/bounded-recovery-dispatch.mjs"
test -r "$RELEASE_ROOT/systemd/brokkr-debian-maintenance-recovery.service.in"
for file in \
  docs/autonomy-constitution-v2.schema.json \
  docs/autonomy-coverage-registry-v2.schema.json \
  docs/autonomy-owner-attestation-registry-v1.schema.json \
  docs/autonomy-owner-authorization-v1.schema.json \
  docs/autonomy-recovery-worker-registry-v1.schema.json \
  docs/autonomy-runtime-narrowing-v1.schema.json \
  docs/autonomous-mutation-journal-v2.schema.json \
  docs/debian-maintenance-attempt-factory-config-v1.schema.json \
  docs/debian-maintenance-window-freshness-v1.schema.json \
  scripts/debian-maintenance-attempt-factory.mjs \
  scripts/debian-maintenance-autonomy.mjs \
  scripts/debian-maintenance-executor.mjs \
  scripts/debian-maintenance-host-adapter.mjs \
  scripts/maintenance-controller.mjs \
  scripts/lib/autonomy-authorization.mjs \
  scripts/lib/debian-maintenance-attempt-factory.mjs \
  scripts/lib/fixed-debian-maintenance-host-operation.mjs \
  scripts/lib/maintenance-policy-contract.mjs \
  scripts/lib/bounded-recovery-dispatch.mjs \
  systemd/brokkr-debian-maintenance-attempt-factory.service.in \
  systemd/brokkr-debian-maintenance-attempt-factory.timer \
  systemd/brokkr-debian-maintenance-recovery.service.in; do
  git -C "$SOURCE" show "$REVISION:$file" >"$TMP/expected-commit-file"
  cmp "$TMP/expected-commit-file" "$RELEASE_ROOT/$file"
done
grep -Fqx "Environment=BROKKR_RELEASE_SHA=$REVISION" "$APPLY_UNIT"
grep -Fqx \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-host-adapter.mjs --action apply --attempt canary-fi" \
  "$APPLY_UNIT"
grep -Fqx \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-host-adapter.mjs --action recover --attempt %i" \
  "$RECOVERY_UNIT"
grep -Fqx \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-attempt-factory.mjs" \
  "$FACTORY_UNIT"
test "$(grep -c '^ProtectSystem=' "$FACTORY_UNIT")" -eq 1
grep -Fqx "ProtectSystem=false" "$FACTORY_UNIT"
! grep -Fqx "ProtectSystem=strict" "$FACTORY_UNIT"
test "$(grep -c '^ReadOnlyPaths=' "$FACTORY_UNIT")" -eq 1
grep -Fqx \
  "ReadOnlyPaths=/etc/brokkr /run/brokkr" \
  "$FACTORY_UNIT"
test "$(grep -c '^ReadWritePaths=' "$FACTORY_UNIT")" -eq 1
grep -Fqx \
  "ReadWritePaths=/var/lib/brokkr/debian-maintenance /var/lib/dpkg /var/cache/apt /var/log/apt" \
  "$FACTORY_UNIT"
for factory_line in \
  'Type=oneshot' \
  'User=root' \
  'NoNewPrivileges=yes' \
  'PrivateTmp=yes' \
  'ProtectHome=yes' \
  'ProtectKernelTunables=yes' \
  'ProtectControlGroups=yes' \
  'ProtectKernelLogs=yes' \
  'PrivateDevices=yes' \
  'RestrictSUIDSGID=yes' \
  "Environment=BROKKR_RELEASE_SHA=$REVISION" \
  "ExecStart=/usr/local/lib/brokkr/releases/$REVISION/scripts/debian-maintenance-attempt-factory.mjs" \
  'TimeoutStartSec=600'; do
  test "$(grep -Fxc "$factory_line" "$FACTORY_UNIT")" -eq 1
done
cmp \
  "$SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
  "$FACTORY_TIMER"
! grep -Eq '^(WantedBy=)' "$FACTORY_UNIT"
grep -Fqx "WantedBy=timers.target" "$FACTORY_TIMER"
sed \
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

# Different canary IDs publish shared recovery/factory paths. Their source
# revisions must serialize at one global lock; one wins and the other fails
# without a mixed release or unit set.
cat >"$TMP/race-after-source-verify" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ready="$BROKKR_RACE_READY_DIR/$(basename "$1")"
: >"$ready"
while [[ ! -e "$BROKKR_RACE_READY_DIR/source" ||
  ! -e "$BROKKR_RACE_READY_DIR/race-source-b" ]]; do
  sleep 0.01
done
SH
chmod 0755 "$TMP/race-after-source-verify"
RACE_SOURCE_B="$TMP/race-source-b"
git clone -q "$SOURCE" "$RACE_SOURCE_B"
git -C "$RACE_SOURCE_B" config user.email test@example.invalid
git -C "$RACE_SOURCE_B" config user.name "Brokkr hermetic test"
printf '\n// concurrent release winner fixture\n' \
  >>"$RACE_SOURCE_B/scripts/debian-maintenance-host-adapter.mjs"
git -C "$RACE_SOURCE_B" add scripts/debian-maintenance-host-adapter.mjs
git -C "$RACE_SOURCE_B" commit -qm "concurrent release fixture"
RACE_REVISION_B="$(git -C "$RACE_SOURCE_B" rev-parse HEAD)"
RACE_ROOT="$TMP/concurrent-install-root"
RACE_READY_DIR="$TMP/concurrent-ready"
mkdir -p "$RACE_READY_DIR"
set +e
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$RACE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_CANARY_AFTER_SOURCE_VERIFY_HOOK="$TMP/race-after-source-verify" \
  BROKKR_RACE_READY_DIR="$RACE_READY_DIR" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/concurrent-systemctl.log" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  --canary race-a >"$TMP/concurrent-a.out" 2>&1 &
RACE_A_PID=$!
env \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$RACE_ROOT" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_CANARY_AFTER_SOURCE_VERIFY_HOOK="$TMP/race-after-source-verify" \
  BROKKR_RACE_READY_DIR="$RACE_READY_DIR" \
  BROKKR_TEST_SYSTEMCTL_LOG="$TMP/concurrent-systemctl.log" \
  "$INSTALLER" install --source "$RACE_SOURCE_B" --revision "$RACE_REVISION_B" \
  --canary race-b >"$TMP/concurrent-b.out" 2>&1 &
RACE_B_PID=$!
wait "$RACE_A_PID"
RACE_A_STATUS=$?
wait "$RACE_B_PID"
RACE_B_STATUS=$?
set -e
if [[ "$RACE_A_STATUS" -eq 0 && "$RACE_B_STATUS" -ne 0 ]]; then
  RACE_WINNER_SOURCE="$SOURCE"
  RACE_WINNER_REVISION="$REVISION"
  RACE_WINNER_CANARY=race-a
  RACE_LOSER_REVISION="$RACE_REVISION_B"
  RACE_LOSER_CANARY=race-b
elif [[ "$RACE_A_STATUS" -ne 0 && "$RACE_B_STATUS" -eq 0 ]]; then
  RACE_WINNER_SOURCE="$RACE_SOURCE_B"
  RACE_WINNER_REVISION="$RACE_REVISION_B"
  RACE_WINNER_CANARY=race-b
  RACE_LOSER_REVISION="$REVISION"
  RACE_LOSER_CANARY=race-a
else
  echo "concurrent installs did not produce exactly one winner" >&2
  exit 1
fi
RACE_RELEASE="$RACE_ROOT/usr/local/lib/brokkr/releases/$RACE_WINNER_REVISION"
cmp \
  "$RACE_WINNER_SOURCE/scripts/debian-maintenance-host-adapter.mjs" \
  "$RACE_RELEASE/scripts/debian-maintenance-host-adapter.mjs"
test ! -e "$RACE_ROOT/usr/local/lib/brokkr/releases/$RACE_LOSER_REVISION"
test -e \
  "$RACE_ROOT/etc/systemd/system/brokkr-debian-maintenance-canary-$RACE_WINNER_CANARY.service"
test ! -e \
  "$RACE_ROOT/etc/systemd/system/brokkr-debian-maintenance-canary-$RACE_LOSER_CANARY.service"
for shared_unit in \
  brokkr-debian-maintenance-attempt-factory.service \
  brokkr-debian-maintenance-recovery@.service; do
  grep -Fqx "Environment=BROKKR_RELEASE_SHA=$RACE_WINNER_REVISION" \
    "$RACE_ROOT/etc/systemd/system/$shared_unit"
done
cmp \
  "$RACE_WINNER_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
  "$RACE_ROOT/etc/systemd/system/brokkr-debian-maintenance-attempt-factory.timer"

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
  >"$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-recovery@.service"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$OTHER_REVISION" \
  >"$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-attempt-factory.service"
cp "$SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
  "$UNIT_CONFLICT_DIR/brokkr-debian-maintenance-attempt-factory.timer"
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
  >"$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-recovery@.service"
printf 'Environment=BROKKR_RELEASE_SHA=%s\n' "$REVISION" \
  >"$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-attempt-factory.service"
cp "$SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
  "$UNSAFE_UNIT_DIR/brokkr-debian-maintenance-attempt-factory.timer"
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

# The package transaction may write host paths outside ReadWritePaths when
# ProtectSystem=false; the installer therefore protects the exact unit shape,
# not a false claim that apt/dpkg writes are path-allowlisted.
prepare_factory_source() {
  local factory_source="$1"
  git clone -q "$SOURCE" "$factory_source"
  git -C "$factory_source" config user.email test@example.invalid
  git -C "$factory_source" config user.name "Brokkr hermetic test"
}

commit_factory_mutation() {
  local factory_source="$1"
  local message="$2"
  git -C "$factory_source" add \
    systemd/brokkr-debian-maintenance-attempt-factory.service.in
  git -C "$factory_source" commit -qm "$message"
  git -C "$factory_source" rev-parse HEAD
}

assert_factory_mutation_rejected() {
  local label="$1"
  local factory_source="$2"
  local factory_revision="$3"
  local factory_root="$TMP/$label-root"
  local factory_output="$TMP/$label.out"
  if env \
    BROKKR_CANARY_INSTALL_TEST_ROOT="$factory_root" \
    BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
    BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
    BROKKR_CANARY_NODE="$NODE_BIN" \
    BROKKR_TEST_SYSTEMCTL_LOG="$TMP/$label-systemctl.log" \
    "$INSTALLER" install \
      --source "$factory_source" \
      --revision "$factory_revision" \
      --canary "canary-$label" \
      >"$factory_output" 2>&1; then
    echo "unsafe attempt factory unit unexpectedly installed: $label" >&2
    exit 1
  fi
  grep -Fq "attempt factory unit template sandbox invalid" \
    "$factory_output"
  test ! -e \
    "$factory_root/etc/systemd/system/brokkr-debian-maintenance-attempt-factory.service"
  test ! -e \
    "$factory_root/usr/local/lib/brokkr/releases/$factory_revision"
}

# The old strict configuration is rejected because real apt/dpkg payloads and
# maintainer scripts need host filesystem writes such as /usr, /etc, and /boot.
STRICT_FACTORY_SOURCE="$TMP/strict-factory-source"
prepare_factory_source "$STRICT_FACTORY_SOURCE"
sed \
  -e 's/^ProtectSystem=false$/ProtectSystem=strict/' \
  "$STRICT_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in" \
  >"$STRICT_FACTORY_SOURCE/systemd/.strict-factory.service.in"
mv \
  "$STRICT_FACTORY_SOURCE/systemd/.strict-factory.service.in" \
  "$STRICT_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
STRICT_FACTORY_REVISION="$(
  commit_factory_mutation "$STRICT_FACTORY_SOURCE" "strict factory sandbox"
)"
assert_factory_mutation_rejected \
  strict-factory "$STRICT_FACTORY_SOURCE" "$STRICT_FACTORY_REVISION"

# A duplicate ProtectSystem line is rejected instead of relying on systemd's
# assignment ordering to choose an effective value.
DUPLICATE_PROTECT_FACTORY_SOURCE="$TMP/duplicate-protect-factory-source"
prepare_factory_source "$DUPLICATE_PROTECT_FACTORY_SOURCE"
printf 'ProtectSystem=strict\n' \
  >>"$DUPLICATE_PROTECT_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
DUPLICATE_PROTECT_FACTORY_REVISION="$(
  commit_factory_mutation \
    "$DUPLICATE_PROTECT_FACTORY_SOURCE" "duplicate factory ProtectSystem"
)"
assert_factory_mutation_rejected \
  duplicate-protect-factory \
  "$DUPLICATE_PROTECT_FACTORY_SOURCE" \
  "$DUPLICATE_PROTECT_FACTORY_REVISION"

# Additional path-authority directives are rejected even though they could
# otherwise change the factory's mount namespace semantics.
EXTRA_PATH_FACTORY_SOURCE="$TMP/extra-path-factory-source"
prepare_factory_source "$EXTRA_PATH_FACTORY_SOURCE"
printf 'BindPaths=/usr\n' \
  >>"$EXTRA_PATH_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
EXTRA_PATH_FACTORY_REVISION="$(
  commit_factory_mutation "$EXTRA_PATH_FACTORY_SOURCE" "extra factory path authority"
)"
assert_factory_mutation_rejected \
  extra-path-factory "$EXTRA_PATH_FACTORY_SOURCE" "$EXTRA_PATH_FACTORY_REVISION"

# The write-authority change does not permit dropping the factory's remaining
# hardening contract.
NO_NEW_PRIV_FACTORY_SOURCE="$TMP/no-new-priv-factory-source"
prepare_factory_source "$NO_NEW_PRIV_FACTORY_SOURCE"
sed \
  -e '/^NoNewPrivileges=yes$/d' \
  "$NO_NEW_PRIV_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in" \
  >"$NO_NEW_PRIV_FACTORY_SOURCE/systemd/.no-new-priv-factory.service.in"
mv \
  "$NO_NEW_PRIV_FACTORY_SOURCE/systemd/.no-new-priv-factory.service.in" \
  "$NO_NEW_PRIV_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
NO_NEW_PRIV_FACTORY_REVISION="$(
  commit_factory_mutation \
    "$NO_NEW_PRIV_FACTORY_SOURCE" "remove factory no-new-privileges"
)"
assert_factory_mutation_rejected \
  no-new-priv-factory \
  "$NO_NEW_PRIV_FACTORY_SOURCE" \
  "$NO_NEW_PRIV_FACTORY_REVISION"

# The exact factory execution shape also rejects extra root command hooks.
EXTRA_EXEC_FACTORY_SOURCE="$TMP/extra-exec-factory-source"
prepare_factory_source "$EXTRA_EXEC_FACTORY_SOURCE"
printf 'ExecStartPre=/usr/bin/true\n' \
  >>"$EXTRA_EXEC_FACTORY_SOURCE/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
EXTRA_EXEC_FACTORY_REVISION="$(
  commit_factory_mutation \
    "$EXTRA_EXEC_FACTORY_SOURCE" "add factory exec hook"
)"
assert_factory_mutation_rejected \
  extra-exec-factory \
  "$EXTRA_EXEC_FACTORY_SOURCE" \
  "$EXTRA_EXEC_FACTORY_REVISION"

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
  "$BROKEN_ROOT/etc/systemd/system/brokkr-debian-maintenance-recovery@.service"
test ! -e \
  "$BROKEN_ROOT/usr/local/lib/brokkr/releases/$BROKEN_REVISION"

# Disable persists both the legacy canary marker and the revision-bound global
# factory gate before systemd. Even when shutdown fails, every disable/stop
# attempt occurs and the marker/evidence remain durable.
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
grep -Fq "disarm gates persisted but systemd shutdown failed" \
  "$TMP/stop-failure.out"
test -r \
  "$STOP_FAILURE_STATE/disarmed/canary-stop-failure.json"
test -r \
  "$STOP_FAILURE_STATE/disarmed/factory-$REVISION.json"
test -r \
  "$STOP_FAILURE_STATE/evidence/canary-stop-failure.json"
grep -Fqx \
  "disable --now brokkr-debian-maintenance-attempt-factory.timer" \
  "$STOP_FAILURE_LOG"
grep -Fqx \
  "stop brokkr-debian-maintenance-attempt-factory.service" \
  "$STOP_FAILURE_LOG"
grep -Fqx \
  "disable --now brokkr-debian-maintenance-canary-canary-stop-failure.service" \
  "$STOP_FAILURE_LOG"
grep -Fqx \
  "stop brokkr-debian-maintenance-recovery@canary-stop-failure.service" \
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
grep -Fqx \
  "disable --now brokkr-debian-maintenance-attempt-factory.timer" \
  "$SYSTEMCTL_LOG"
grep -Fqx \
  "stop brokkr-debian-maintenance-attempt-factory.service" \
  "$SYSTEMCTL_LOG"
grep -Fqx "stop brokkr-debian-maintenance-recovery@canary-fi.service" \
  "$SYSTEMCTL_LOG"
test "$(grep -c '^disable --now brokkr-debian-maintenance-attempt-factory.timer$' "$SYSTEMCTL_LOG")" -eq 1
test "$(grep -c '^stop brokkr-debian-maintenance-attempt-factory.service$' "$SYSTEMCTL_LOG")" -eq 1
test "$(grep -c '^disable --now brokkr-debian-maintenance-canary-canary-fi.service$' "$SYSTEMCTL_LOG")" -eq 1
test "$(grep -c '^stop brokkr-debian-maintenance-recovery@canary-fi.service$' "$SYSTEMCTL_LOG")" -eq 1
test -r "$STATE_ROOT/evidence/canary-fi.json"
test -r "$STATE_ROOT/disarmed/canary-fi.json"
test -r "$STATE_ROOT/disarmed/factory-$REVISION.json"
test -d "$RELEASE_ROOT"
test -r "$STATE_ROOT/headroom/journal.reserve"
test -r "$STATE_ROOT/headroom/evidence.reserve"
grep -Fq "\"release_sha\":\"$REVISION\"" \
  "$STATE_ROOT/disarmed/canary-fi.json"
grep -Fq '"evidence_preserved":true' \
  "$STATE_ROOT/disarmed/canary-fi.json"
grep -Fq "\"release_sha\":\"$REVISION\"" \
  "$STATE_ROOT/disarmed/factory-$REVISION.json"

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
test "$(grep -c '^disable --now brokkr-debian-maintenance-attempt-factory.timer$' "$SYSTEMCTL_LOG")" -eq 2
test "$(grep -c '^stop brokkr-debian-maintenance-attempt-factory.service$' "$SYSTEMCTL_LOG")" -eq 2
test "$(grep -c '^disable --now brokkr-debian-maintenance-canary-canary-fi.service$' "$SYSTEMCTL_LOG")" -eq 2
test "$(grep -c '^stop brokkr-debian-maintenance-recovery@canary-fi.service$' "$SYSTEMCTL_LOG")" -eq 2

case "$REVISION" in
  *0) WRONG_REVISION="${REVISION%?}1" ;;
  *) WRONG_REVISION="${REVISION%?}0" ;;
esac
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

# Release staging must not stream `git archive` into a reader that can stop early. bsdtar exits at
# the end-of-archive marker without draining the trailing padding, which SIGPIPEs git archive and,
# under `set -o pipefail`, aborts the installer with 141 — the macOS-only failure in issue #119.
#
# This stub reproduces that reader behaviour on EVERY platform, so the regression is caught on the
# Linux runner too. Testing with the real bsdtar would assert nothing in CI, where GNU tar drains
# and the bug cannot appear. When handed `-f`, the stub delegates to the real tar so a correctly
# staged install still completes and its blob verification is exercised.
# The dirty-source case above left $SOURCE dirty, and the installer refuses a dirty worktree.
# Commit it so this case exercises staging rather than re-testing the dirty-source refusal.
git -C "$SOURCE" add -A
git -C "$SOURCE" commit -qm "sigpipe fixture"
SIGPIPE_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

mkdir -p "$TMP/sigpipe-bin"
REAL_TAR="$(command -v tar)"
cat >"$TMP/sigpipe-bin/tar" <<EOF
#!/usr/bin/env bash
# Only a real file operand is safe: there is no writer to signal. \`-f -\` and \`--file=-\` still
# read stdin, so they must NOT be treated as file-backed or the stub would wave through a
# streaming regression.
prev=""
for arg in "\$@"; do
  operand=""
  if [[ "\$prev" == -f || "\$prev" == --file ]]; then
    operand="\$arg"
  elif [[ "\$arg" == --file=* ]]; then
    operand="\${arg#--file=}"
  fi
  if [[ -n "\$operand" && "\$operand" != - && -f "\$operand" ]]; then
    exec "$REAL_TAR" "\$@"
  fi
  prev="\$arg"
done
# Streamed: consume one block, then exit without draining, exactly as bsdtar does.
dd bs=10240 count=1 >/dev/null 2>&1
exit 0
EOF
chmod 0755 "$TMP/sigpipe-bin/tar"

if ! env \
  PATH="$TMP/sigpipe-bin:$PATH" \
  BROKKR_CANARY_INSTALL_TEST_ROOT="$TMP/sigpipe-root" \
  BROKKR_CANARY_SYSTEMCTL="$TMP/systemctl" \
  BROKKR_CANARY_FALLOCATE="$TMP/fallocate" \
  BROKKR_CANARY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install \
    --source "$SOURCE" \
    --revision "$SIGPIPE_REVISION" \
    --canary canary-sigpipe >"$TMP/sigpipe.out" 2>&1; then
  echo "installer failed against an early-exiting tar (issue #119 regression):" >&2
  tail -5 "$TMP/sigpipe.out" >&2
  exit 1
fi
test -f "$TMP/sigpipe-root/usr/local/lib/brokkr/releases/$SIGPIPE_REVISION/scripts/maintenance-controller.mjs"
# The staged archive must not survive extraction.
test -z "$(find "$TMP/sigpipe-root/usr/local/lib/brokkr/releases" -name 'release.tar' -print -quit)"

echo "debian canary installer: exact revision, disabled units, headroom, and evidence-preserving disarm OK"
