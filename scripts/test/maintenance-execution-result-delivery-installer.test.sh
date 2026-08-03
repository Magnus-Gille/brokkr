#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
INSTALL_ROOT="$TMP/install-root"
SYSTEMCTL_LOG="$TMP/systemctl.log"
NODE_BIN="$(command -v node)"
mkdir -p "$SOURCE/scripts/lib" "$SOURCE/systemd" "$TMP/bin"
cp "$ROOT/scripts/maintenance-execution-result-delivery.mjs" \
  "$ROOT/scripts/maintenance-execution-result.mjs" "$SOURCE/scripts/"
cp "$ROOT/scripts/lib/autonomy-authorization.mjs" "$SOURCE/scripts/lib/"
cp "$ROOT/systemd/brokkr-maintenance-execution-result-delivery.service.in" \
  "$SOURCE/systemd/"
cp "$ROOT/scripts/install-maintenance-execution-result-delivery.sh" \
  "$SOURCE/scripts/"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name "Brokkr hermetic test"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm "fixture"
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

cat >"$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BROKKR_TEST_SYSTEMCTL_LOG"
exit 99
MOCK
chmod 0755 "$TMP/bin/systemctl"

LSTAT_EACCES_PRELOAD="$TMP/lstat-eacces-preload.cjs"
cat >"$LSTAT_EACCES_PRELOAD" <<'NODE'
const fs = require("node:fs");

const deniedPath = process.env.BROKKR_TEST_LSTAT_EACCES_PATH;
if (!deniedPath) {
  throw new Error("BROKKR_TEST_LSTAT_EACCES_PATH is required");
}

const originalLstatSync = fs.lstatSync;
fs.lstatSync = function patchedLstatSync(candidate, ...rest) {
  if (String(candidate) === deniedPath) {
    const error = new Error(`EACCES: denied, lstat '${candidate}'`);
    error.code = "EACCES";
    throw error;
  }
  return originalLstatSync.call(this, candidate, ...rest);
};
NODE

LSTAT_EACCES_NODE_WRAPPER="$TMP/lstat-eacces-node-wrapper"
cat >"$LSTAT_EACCES_NODE_WRAPPER" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

REAL_NODE="${BROKKR_TEST_NODE_REAL:?BROKKR_TEST_NODE_REAL is required}"
PRELOAD="${BROKKR_TEST_NODE_PRELOAD:?BROKKR_TEST_NODE_PRELOAD is required}"
exec env NODE_OPTIONS="--require=$PRELOAD" "$REAL_NODE" "$@"
WRAPPER
chmod 0755 "$LSTAT_EACCES_NODE_WRAPPER"

run_installer() {
  local install_root="$1"
  shift
  env \
    PATH="$TMP/bin:$PATH" \
    BROKKR_DELIVERY_INSTALL_TEST_ROOT="$install_root" \
    BROKKR_DELIVERY_NODE="$NODE_BIN" \
    BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$@" \
    "$INSTALLER" install --source "$SOURCE" --revision "$REVISION"
}

assert_observation_only_unit() {
  local unit="$1"
  grep -Fqx 'DynamicUser=yes' "$unit"
  ! grep -Eq '^User=' "$unit"
  grep -Fqx 'NoNewPrivileges=yes' "$unit"
  grep -Fqx 'ProtectSystem=strict' "$unit"
  grep -Fqx 'CapabilityBoundingSet=' "$unit"
  grep -Fqx 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "$unit"
  grep -Fqx 'Environment=PATH=/usr/bin:/bin' "$unit"
  ! grep -Eq '^\[Install\]$' "$unit"
  ! grep -Eq \
    '^(ReadWritePaths|ReadWriteDirectories|BindPaths|StateDirectory|CacheDirectory|LogsDirectory|RuntimeDirectory|ConfigurationDirectory)=' \
    "$unit"
  ! grep -Eq '^Standard(Output|Error)=(file|append|truncate):' "$unit"
  ! grep -Eq \
    '^(ExecStartPre|ExecStartPost|ExecReload|ExecStop|ExecStopPost|Restart|SuccessAction|FailureAction)=' \
    "$unit"
}

assert_observation_only_unit \
  "$ROOT/systemd/brokkr-maintenance-execution-result-delivery.service.in"

INSTALLER="$ROOT/scripts/install-maintenance-execution-result-delivery.sh"
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/install.out"

RELEASE_ROOT="$INSTALL_ROOT/usr/local/lib/brokkr/maintenance-result-delivery/releases/$REVISION"
UNIT="$INSTALL_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
test -x "$RELEASE_ROOT/scripts/maintenance-execution-result-delivery.mjs"
test -r "$RELEASE_ROOT/scripts/maintenance-execution-result.mjs"
test -r "$RELEASE_ROOT/scripts/lib/autonomy-authorization.mjs"
for file in \
  scripts/maintenance-execution-result-delivery.mjs \
  scripts/maintenance-execution-result.mjs \
  scripts/lib/autonomy-authorization.mjs; do
  git -C "$SOURCE" show "$REVISION:$file" >"$TMP/expected"
  cmp "$TMP/expected" "$RELEASE_ROOT/$file"
done

ADAPTER_DIGEST="$("$NODE_BIN" --input-type=module - \
  "$RELEASE_ROOT/scripts/maintenance-execution-result-delivery.mjs" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
process.stdout.write(`sha256:${crypto.createHash("sha256")
  .update(fs.readFileSync(process.argv[2])).digest("hex")}`);
NODE
)"
grep -Fqx "Environment=BROKKR_ADAPTER_REVISION=$REVISION" "$UNIT"
grep -Fqx "Environment=BROKKR_ADAPTER_DIGEST=$ADAPTER_DIGEST" "$UNIT"
grep -Fqx \
  "ExecStart=/usr/bin/node /usr/local/lib/brokkr/maintenance-result-delivery/releases/$REVISION/scripts/maintenance-execution-result-delivery.mjs" \
  "$UNIT"
grep -Fqx \
  "LoadCredential=brokkr-maintenance-result-delivery-v1" "$UNIT"
grep -Fqx \
  "StandardInput=file:/var/lib/brokkr/debian-maintenance/evidence/maintenance-execution-result.json" \
  "$UNIT"
assert_observation_only_unit "$UNIT"
! grep -Eq '^(WantedBy=|RequiredBy=|Alias=)' "$UNIT"
! grep -Fq 'LoadCredential=brokkr-maintenance-result-delivery-v1:' "$UNIT"
test ! -e "$SYSTEMCTL_LOG"
test ! -e "$INSTALL_ROOT/etc/credstore"
! grep -Fq "$SOURCE" "$TMP/install.out"
printf 'ok - install artifact is exact-revision bound and remains unconfigured and disabled\n'

"$NODE_BIN" --input-type=module - "$RELEASE_ROOT" "$UNIT" \
  >"$TMP/inodes.before" <<'NODE'
import fs from "node:fs";
for (const value of process.argv.slice(2)) {
  process.stdout.write(`${fs.statSync(value).ino}\n`);
}
NODE
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$INSTALL_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/replay.out"
"$NODE_BIN" --input-type=module - "$RELEASE_ROOT" "$UNIT" \
  >"$TMP/inodes.after" <<'NODE'
import fs from "node:fs";
for (const value of process.argv.slice(2)) {
  process.stdout.write(`${fs.statSync(value).ino}\n`);
}
NODE
cmp "$TMP/inodes.before" "$TMP/inodes.after"
test ! -e "$SYSTEMCTL_LOG"
printf 'ok - exact installer replay is byte-idempotent and performs no systemd mutation\n'

printf '\n# dirty sentinel\n' >>"$SOURCE/scripts/maintenance-execution-result.mjs"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$TMP/dirty-root" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/dirty.out" 2>&1; then
  echo "dirty source unexpectedly installed" >&2
  exit 1
fi
test ! -e "$TMP/dirty-root"
git -C "$SOURCE" checkout -- scripts/maintenance-execution-result.mjs
printf 'ok - dirty source fails before installation\n'

CONFLICT_ROOT="$TMP/conflict-root"
CONFLICT_UNIT_DIR="$CONFLICT_ROOT/etc/systemd/system"
mkdir -p "$CONFLICT_UNIT_DIR"
printf 'conflict-sentinel\n' \
  >"$CONFLICT_UNIT_DIR/brokkr-maintenance-execution-result-delivery.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$CONFLICT_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/conflict.out" 2>&1; then
  echo "conflicting unit unexpectedly overwritten" >&2
  exit 1
fi
grep -Fqx "conflict-sentinel" \
  "$CONFLICT_UNIT_DIR/brokkr-maintenance-execution-result-delivery.service"
test ! -e "$CONFLICT_ROOT/usr"
printf 'ok - divergent existing install fails closed without overwrite\n'

ENABLED_ROOT="$TMP/enabled-root"
ENABLED_WANTS="$ENABLED_ROOT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$ENABLED_WANTS"
ln -s ../brokkr-maintenance-execution-result-delivery.service \
  "$ENABLED_WANTS/brokkr-maintenance-execution-result-delivery.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$ENABLED_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/enabled.out" 2>&1; then
  echo "pre-enabled unit link unexpectedly accepted" >&2
  exit 1
fi
test -L \
  "$ENABLED_WANTS/brokkr-maintenance-execution-result-delivery.service"
test ! -e "$ENABLED_ROOT/usr"
printf 'ok - installer refuses a pre-existing enablement link\n'

ALIAS_FAILURES=0
for dependency in wants requires upholds; do
  ALIAS_ROOT="$TMP/alias-$dependency-root"
  ALIAS_DIRECTORY="$ALIAS_ROOT/etc/systemd/system/multi-user.target.$dependency"
  mkdir -p "$ALIAS_DIRECTORY"
  case "$dependency" in
    wants)
      ALIAS_TARGET=../brokkr-maintenance-execution-result-delivery.service
      ;;
    requires)
      ALIAS_TARGET="$ALIAS_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
      ;;
    upholds)
      ALIAS_TARGET=.././ignored/../brokkr-maintenance-execution-result-delivery.service
      ;;
  esac
  ln -s "$ALIAS_TARGET" "$ALIAS_DIRECTORY/delivery-adapter-alias.service"
  if env \
    PATH="$TMP/bin:$PATH" \
    BROKKR_DELIVERY_INSTALL_TEST_ROOT="$ALIAS_ROOT" \
    BROKKR_DELIVERY_NODE="$NODE_BIN" \
    BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
    >"$TMP/alias-$dependency.out" 2>&1; then
    echo "alias-named $dependency dependency unexpectedly accepted" >&2
    ALIAS_FAILURES=$((ALIAS_FAILURES + 1))
  fi
done
test "$ALIAS_FAILURES" -eq 0
printf 'ok - installer resolves direct dependency aliases before accepting them\n'

BASENAME_ALIAS_ROOT="$TMP/basename-alias-root"
BASENAME_ALIAS_UNIT_ROOT="$BASENAME_ALIAS_ROOT/etc/systemd/system"
BASENAME_ALIAS_WANTS="$BASENAME_ALIAS_UNIT_ROOT/multi-user.target.wants"
mkdir -p "$BASENAME_ALIAS_WANTS"
ln -s brokkr-maintenance-execution-result-delivery.service \
  "$BASENAME_ALIAS_UNIT_ROOT/delivery-adapter-basename-alias.service"
printf '[Unit]\nDescription=Unrelated basename alias target\n' \
  >"$BASENAME_ALIAS_UNIT_ROOT/unrelated-target.service"
ln -s ../unrelated-target.service \
  "$BASENAME_ALIAS_WANTS/delivery-adapter-basename-alias.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$BASENAME_ALIAS_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/basename-alias.out" 2>&1; then
  echo "adapter-alias dependency basename unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$BASENAME_ALIAS_ROOT/usr"
printf 'ok - installer rejects an adapter-alias dependency basename even when its target is unrelated\n'

CHAIN_ROOT="$TMP/chained-alias-root"
CHAIN_UNIT_ROOT="$CHAIN_ROOT/etc/systemd/system"
CHAIN_WANTS="$CHAIN_UNIT_ROOT/multi-user.target.wants"
mkdir -p "$CHAIN_WANTS"
ln -s ../delivery-adapter-intermediate.service \
  "$CHAIN_WANTS/delivery-adapter-chained-alias.service"
ln -s brokkr-maintenance-execution-result-delivery.service \
  "$CHAIN_UNIT_ROOT/delivery-adapter-intermediate.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$CHAIN_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/chained-alias.out" 2>&1; then
  echo "chained adapter dependency alias unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CHAIN_ROOT/usr"
printf 'ok - installer resolves dependency alias chains to a missing adapter unit\n'

CYCLE_ROOT="$TMP/cyclic-alias-root"
CYCLE_UNIT_ROOT="$CYCLE_ROOT/etc/systemd/system"
CYCLE_REQUIRES="$CYCLE_UNIT_ROOT/multi-user.target.requires"
mkdir -p "$CYCLE_REQUIRES"
ln -s ../delivery-cycle-intermediate.service \
  "$CYCLE_REQUIRES/delivery-cycle-alias.service"
ln -s multi-user.target.requires/delivery-cycle-alias.service \
  "$CYCLE_UNIT_ROOT/delivery-cycle-intermediate.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$CYCLE_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/cyclic-alias.out" 2>&1; then
  echo "cyclic dependency alias unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CYCLE_ROOT/usr"
printf 'ok - installer fails closed on dependency alias cycles\n'

SAFE_CHAIN_ROOT="$TMP/unrelated-chain-root"
SAFE_CHAIN_UNIT_ROOT="$SAFE_CHAIN_ROOT/etc/systemd/system"
SAFE_CHAIN_UPHOLDS="$SAFE_CHAIN_UNIT_ROOT/multi-user.target.upholds"
mkdir -p "$SAFE_CHAIN_UPHOLDS"
ln -s ../unrelated-intermediate.service \
  "$SAFE_CHAIN_UPHOLDS/unrelated-chain-alias.service"
ln -s unrelated-target.service \
  "$SAFE_CHAIN_UNIT_ROOT/unrelated-intermediate.service"
printf '[Unit]\nDescription=Unrelated test unit\n' \
  >"$SAFE_CHAIN_UNIT_ROOT/unrelated-target.service"
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$SAFE_CHAIN_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/unrelated-chain.out"
test -L "$SAFE_CHAIN_UPHOLDS/unrelated-chain-alias.service"
test -f \
  "$SAFE_CHAIN_UNIT_ROOT/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer accepts a safe unrelated dependency alias chain\n'

SAFE_EXTERNAL_ROOT="$TMP/safe-external-root"
SAFE_EXTERNAL_UNIT_ROOT="$SAFE_EXTERNAL_ROOT/etc/systemd/system"
SAFE_EXTERNAL_WANTS="$SAFE_EXTERNAL_UNIT_ROOT/multi-user.target.wants"
SAFE_EXTERNAL_TERMINAL="$TMP/safe-external-terminal.service"
mkdir -p "$SAFE_EXTERNAL_WANTS"
printf 'external-sentinel\n' >"$SAFE_EXTERNAL_TERMINAL"
ln -s "$SAFE_EXTERNAL_TERMINAL" \
  "$SAFE_EXTERNAL_WANTS/unrelated-external-terminal.service"
ln -s /dev/null \
  "$SAFE_EXTERNAL_UNIT_ROOT/unrelated-top-level-mask.service"
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$SAFE_EXTERNAL_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/safe-external.out"
test -L "$SAFE_EXTERNAL_WANTS/unrelated-external-terminal.service"
test -L "$SAFE_EXTERNAL_UNIT_ROOT/unrelated-top-level-mask.service"
test -f \
  "$SAFE_EXTERNAL_UNIT_ROOT/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer accepts unrelated external dependency terminals and top-level masks\n'

CROSS_ROOT="$TMP/cross-root"
CROSS_WANTS="$CROSS_ROOT/etc/systemd/system/multi-user.target.wants"
CROSS_EXTERNAL_REAL="$TMP/cross-root-external-real"
CROSS_EXTERNAL_PARENT="$TMP/cross-root-external-parent"
mkdir -p "$CROSS_WANTS" "$CROSS_EXTERNAL_REAL"
ln -s "$CROSS_EXTERNAL_REAL" "$CROSS_EXTERNAL_PARENT"
ln -s \
  "$CROSS_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service" \
  "$CROSS_EXTERNAL_REAL/intermediate.service"
ln -s "$CROSS_EXTERNAL_PARENT/intermediate.service" \
  "$CROSS_WANTS/delivery-adapter-cross-root-alias.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$CROSS_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/cross-root-alias.out" 2>&1; then
  echo "cross-root adapter dependency alias unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CROSS_ROOT/usr"
printf 'ok - installer resolves cross-root dependency aliases to a missing adapter unit\n'

RUN_PATH_ROOT="$TMP/run-load-path-root"
RUN_PATH_WANTS="$RUN_PATH_ROOT/run/systemd/system/multi-user.target.wants"
mkdir -p "$RUN_PATH_WANTS"
printf '[Unit]\nDescription=Run-path unrelated unit\n' \
  >"$RUN_PATH_ROOT/run/systemd/system/unrelated-run-target.service"
ln -s ../unrelated-run-target.service \
  "$RUN_PATH_WANTS/brokkr-maintenance-execution-result-delivery.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$RUN_PATH_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/run-load-path.out" 2>&1; then
  echo "latent /run adapter dependency unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$RUN_PATH_ROOT/usr"
printf 'ok - installer scans /run for latent direct adapter dependencies before install\n'

USR_LIB_ALIAS_ROOT="$TMP/usr-lib-alias-root"
USR_LIB_UNIT_ROOT="$USR_LIB_ALIAS_ROOT/usr/lib/systemd/system"
USR_LIB_WANTS="$USR_LIB_UNIT_ROOT/multi-user.target.wants"
mkdir -p "$USR_LIB_WANTS"
ln -s brokkr-maintenance-execution-result-delivery.service \
  "$USR_LIB_UNIT_ROOT/distribution-delivery-alias.service"
printf '[Unit]\nDescription=Usr-lib unrelated target\n' \
  >"$USR_LIB_UNIT_ROOT/usr-lib-unrelated.service"
ln -s ../usr-lib-unrelated.service \
  "$USR_LIB_WANTS/distribution-delivery-alias.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$USR_LIB_ALIAS_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/usr-lib-alias.out" 2>&1; then
  echo "adapter alias under /usr/lib unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$USR_LIB_ALIAS_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer scans /usr/lib alias dependencies before install\n'

UNRELATED_ROOT="$TMP/unrelated-dependency-root"
UNRELATED_WANTS="$UNRELATED_ROOT/etc/systemd/system/multi-user.target.wants"
mkdir -p "$UNRELATED_WANTS"
ln -s ../unrelated-normal.service \
  "$UNRELATED_WANTS/unrelated-normal-alias.service"
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$UNRELATED_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/unrelated.out"
test -L "$UNRELATED_WANTS/unrelated-normal-alias.service"
test -f \
  "$UNRELATED_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer accepts an unrelated normal dependency symlink\n'

USR_LIB_SAFE_ROOT="$TMP/usr-lib-unrelated-root"
USR_LIB_SAFE_UNIT_ROOT="$USR_LIB_SAFE_ROOT/usr/lib/systemd/system"
USR_LIB_SAFE_WANTS="$USR_LIB_SAFE_UNIT_ROOT/multi-user.target.wants"
mkdir -p "$USR_LIB_SAFE_WANTS"
ln -s usr-lib-safe-target.service \
  "$USR_LIB_SAFE_UNIT_ROOT/usr-lib-safe-alias.service"
printf '[Unit]\nDescription=Usr-lib safe target\n' \
  >"$USR_LIB_SAFE_UNIT_ROOT/usr-lib-safe-target.service"
ln -s ../usr-lib-safe-alias.service \
  "$USR_LIB_SAFE_WANTS/usr-lib-safe-alias.service"
env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$USR_LIB_SAFE_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/usr-lib-safe.out"
test -L "$USR_LIB_SAFE_WANTS/usr-lib-safe-alias.service"
test -f \
  "$USR_LIB_SAFE_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer preserves unrelated normal distribution aliases while scanning /usr/lib\n'

SYMLINKED_WANTS_ROOT="$TMP/symlinked-wants-root"
SYMLINKED_WANTS_EXTERNAL="$TMP/symlinked-wants-external"
mkdir -p \
  "$SYMLINKED_WANTS_ROOT/etc/systemd/system" \
  "$SYMLINKED_WANTS_EXTERNAL"
ln -s "$SYMLINKED_WANTS_EXTERNAL" \
  "$SYMLINKED_WANTS_ROOT/etc/systemd/system/multi-user.target.wants"
ln -s \
  "$SYMLINKED_WANTS_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service" \
  "$SYMLINKED_WANTS_EXTERNAL/brokkr-maintenance-execution-result-delivery.service"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$SYMLINKED_WANTS_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/symlinked-wants.out" 2>&1; then
  echo "enablement hidden behind symlinked wants directory unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$SYMLINKED_WANTS_ROOT/usr"
printf 'ok - installer refuses a symlinked systemd dependency directory\n'

LOCKED_ROOT="$TMP/locked-root"
LOCKED_UNIT_DIR="$LOCKED_ROOT/etc/systemd/system"
LOCK_PATH="$LOCKED_UNIT_DIR/.brokkr-maintenance-result-delivery.install-lock"
mkdir -p "$LOCK_PATH"
if env \
  PATH="$TMP/bin:$PATH" \
  BROKKR_DELIVERY_INSTALL_TEST_ROOT="$LOCKED_ROOT" \
  BROKKR_DELIVERY_NODE="$NODE_BIN" \
  BROKKR_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  "$INSTALLER" install --source "$SOURCE" --revision "$REVISION" \
  >"$TMP/locked.out" 2>&1; then
  echo "concurrent installer lock unexpectedly accepted" >&2
  exit 1
fi
test -d "$LOCK_PATH"
test ! -e "$LOCKED_ROOT/usr"
printf 'ok - failed lock acquisition preserves the concurrent installer lock\n'

TRANSIENT_UNIT_ROOT="$TMP/transient-unit-root"
mkdir -p "$TRANSIENT_UNIT_ROOT/run/systemd/transient"
printf '[Unit]\nDescription=Transient conflicting canonical unit\n' \
  >"$TRANSIENT_UNIT_ROOT/run/systemd/transient/brokkr-maintenance-execution-result-delivery.service"
if run_installer "$TRANSIENT_UNIT_ROOT" >"$TMP/transient-unit.out" 2>&1; then
  echo "canonical transient unit unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$TRANSIENT_UNIT_ROOT/usr"
printf 'ok - installer rejects a canonical unit file in mapped /run/systemd/transient\n'

CANONICAL_DROPIN_ROOT="$TMP/canonical-dropin-root"
CANONICAL_DROPIN_DIR="$CANONICAL_DROPIN_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service.d"
mkdir -p "$CANONICAL_DROPIN_DIR"
printf '[Service]\nEnvironment=CANONICAL_OVERRIDE=1\n' \
  >"$CANONICAL_DROPIN_DIR/override.conf"
if run_installer "$CANONICAL_DROPIN_ROOT" >"$TMP/canonical-dropin.out" 2>&1; then
  echo "canonical unit drop-in unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$CANONICAL_DROPIN_ROOT/usr"
printf 'ok - installer rejects the canonical unit drop-in directory\n'

DASH_PREFIX_DROPIN_ROOT="$TMP/dash-prefix-dropin-root"
DASH_PREFIX_DROPIN_DIR="$DASH_PREFIX_DROPIN_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-.service.d"
mkdir -p "$DASH_PREFIX_DROPIN_DIR"
printf '[Service]\nEnvironment=DASH_PREFIX_OVERRIDE=1\n' \
  >"$DASH_PREFIX_DROPIN_DIR/override.conf"
if run_installer "$DASH_PREFIX_DROPIN_ROOT" >"$TMP/dash-prefix-dropin.out" 2>&1; then
  echo "dash-prefix drop-in unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$DASH_PREFIX_DROPIN_ROOT/usr"
printf 'ok - installer rejects dash-prefix unit drop-ins for the canonical name\n'

TYPE_WIDE_DROPIN_ROOT="$TMP/type-wide-dropin-root"
TYPE_WIDE_DROPIN_DIR="$TYPE_WIDE_DROPIN_ROOT/etc/systemd/system/service.d"
mkdir -p "$TYPE_WIDE_DROPIN_DIR"
printf '[Service]\nEnvironment=TYPE_WIDE_OVERRIDE=1\n' \
  >"$TYPE_WIDE_DROPIN_DIR/override.conf"
if run_installer "$TYPE_WIDE_DROPIN_ROOT" >"$TMP/type-wide-dropin.out" 2>&1; then
  echo "type-wide service drop-in unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$TYPE_WIDE_DROPIN_ROOT/usr"
printf 'ok - installer rejects type-wide service drop-ins\n'

ALIAS_DROPIN_ROOT="$TMP/alias-dropin-root"
ALIAS_DROPIN_ALIAS_ROOT="$ALIAS_DROPIN_ROOT/usr/lib/systemd/system"
ALIAS_DROPIN_DIR="$ALIAS_DROPIN_ROOT/run/systemd/system/delivery-adapter-alias.service.d"
mkdir -p "$ALIAS_DROPIN_ALIAS_ROOT" "$ALIAS_DROPIN_DIR"
ln -s brokkr-maintenance-execution-result-delivery.service \
  "$ALIAS_DROPIN_ALIAS_ROOT/delivery-adapter-alias.service"
printf '[Service]\nEnvironment=ALIAS_OVERRIDE=1\n' \
  >"$ALIAS_DROPIN_DIR/override.conf"
if run_installer "$ALIAS_DROPIN_ROOT" >"$TMP/alias-dropin.out" 2>&1; then
  echo "alias drop-in unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$ALIAS_DROPIN_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer rejects alias drop-ins discovered across configured roots\n'

UNRELATED_DROPIN_ROOT="$TMP/unrelated-dropin-root"
UNRELATED_DROPIN_DIR="$UNRELATED_DROPIN_ROOT/etc/systemd/system/unrelated-normal.service.d"
mkdir -p "$UNRELATED_DROPIN_DIR"
printf '[Service]\nEnvironment=UNRELATED_OVERRIDE=1\n' \
  >"$UNRELATED_DROPIN_DIR/override.conf"
run_installer "$UNRELATED_DROPIN_ROOT" >"$TMP/unrelated-dropin.out"
test -f \
  "$UNRELATED_DROPIN_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer does not overreach into unrelated unit drop-ins\n'

DANGLING_ROOT_SYMLINK_ROOT="$TMP/dangling-root-symlink-root"
mkdir -p "$DANGLING_ROOT_SYMLINK_ROOT/run/systemd"
ln -s "$TMP/nonexistent-dangling-system-root" \
  "$DANGLING_ROOT_SYMLINK_ROOT/run/systemd/system"
if run_installer "$DANGLING_ROOT_SYMLINK_ROOT" >"$TMP/dangling-root-symlink.out" 2>&1; then
  echo "dangling mapped search root symlink unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$DANGLING_ROOT_SYMLINK_ROOT/usr"
printf 'ok - installer rejects a dangling mapped systemd search root symlink\n'

FILE_MAPPED_ROOT="$TMP/file-mapped-root"
mkdir -p "$FILE_MAPPED_ROOT/run/systemd"
printf 'not-a-directory\n' >"$FILE_MAPPED_ROOT/run/systemd/system"
if run_installer "$FILE_MAPPED_ROOT" >"$TMP/file-mapped-root.out" 2>&1; then
  echo "regular-file mapped search root unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$FILE_MAPPED_ROOT/usr"
printf 'ok - installer rejects a regular-file mapped systemd search root\n'

LSTAT_EACCES_ROOT="$TMP/lstat-eacces-root"
mkdir -p "$LSTAT_EACCES_ROOT/run/systemd/system"
if run_installer \
  "$LSTAT_EACCES_ROOT" \
  "BROKKR_DELIVERY_NODE=$LSTAT_EACCES_NODE_WRAPPER" \
  "BROKKR_TEST_NODE_REAL=$NODE_BIN" \
  "BROKKR_TEST_NODE_PRELOAD=$LSTAT_EACCES_PRELOAD" \
  "BROKKR_TEST_LSTAT_EACCES_PATH=$LSTAT_EACCES_ROOT/run/systemd/system" \
  >"$TMP/lstat-eacces.out" 2>&1; then
  echo "non-ENOENT lstat failure unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$LSTAT_EACCES_ROOT/usr"
grep -Fq 'EACCES' "$TMP/lstat-eacces.out"
printf 'ok - installer propagates non-ENOENT mapped search root lstat failures\n'

ALIAS_DASH_PREFIX_DROPIN_ROOT="$TMP/alias-dash-prefix-dropin-root"
ALIAS_DASH_PREFIX_ALIAS_ROOT="$ALIAS_DASH_PREFIX_DROPIN_ROOT/usr/lib/systemd/system"
ALIAS_DASH_PREFIX_DROPIN_DIR="$ALIAS_DASH_PREFIX_DROPIN_ROOT/run/systemd/system/delivery-adapter-.service.d"
mkdir -p "$ALIAS_DASH_PREFIX_ALIAS_ROOT" "$ALIAS_DASH_PREFIX_DROPIN_DIR"
ln -s brokkr-maintenance-execution-result-delivery.service \
  "$ALIAS_DASH_PREFIX_ALIAS_ROOT/delivery-adapter-alias.service"
printf '[Service]\nEnvironment=ALIAS_DASH_PREFIX_OVERRIDE=1\n' \
  >"$ALIAS_DASH_PREFIX_DROPIN_DIR/override.conf"
if run_installer "$ALIAS_DASH_PREFIX_DROPIN_ROOT" >"$TMP/alias-dash-prefix-dropin.out" 2>&1; then
  echo "alias dash-prefix drop-in unexpectedly accepted" >&2
  exit 1
fi
test ! -e "$ALIAS_DASH_PREFIX_DROPIN_ROOT/etc/systemd/system/brokkr-maintenance-execution-result-delivery.service"
printf 'ok - installer rejects alias dash-prefix unit drop-ins discovered across configured roots\n'
