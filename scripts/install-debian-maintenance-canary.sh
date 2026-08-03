#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  install-debian-maintenance-canary.sh install --source ABSOLUTE_PATH --revision FULL_SHA --canary ID
  install-debian-maintenance-canary.sh disable --source ABSOLUTE_PATH --revision FULL_SHA --canary ID

The install action lays down disabled, revision-bound units only. It never
enables, starts, arms, or dispatches a canary. The disable action stops and
disables the exact canary, writes a durable disarm marker, and preserves all
state, releases, journals, receipts, and evidence.
EOF
  exit 64
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
ACTION="$1"
shift
[[ "$ACTION" == "install" || "$ACTION" == "disable" ]] || usage

SOURCE=""
REVISION=""
CANARY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || usage
      SOURCE="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || usage
      REVISION="$2"
      shift 2
      ;;
    --canary)
      [[ $# -ge 2 ]] || usage
      CANARY="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$SOURCE" == /* ]] || die "--source must be absolute"
[[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] || die "--revision must be a full lowercase Git SHA"
[[ "$CANARY" =~ ^[a-z][a-z0-9-]{2,62}$ ]] || die "--canary must be a canonical identifier"

TEST_ROOT="${BROKKR_CANARY_INSTALL_TEST_ROOT:-}"
if [[ -n "$TEST_ROOT" ]]; then
  [[ "$TEST_ROOT" == /* && "$TEST_ROOT" != "/" ]] ||
    die "test root must be an absolute non-root path"
  SYSTEMCTL="${BROKKR_CANARY_SYSTEMCTL:?test systemctl is required}"
  FALLOCATE="${BROKKR_CANARY_FALLOCATE:?test fallocate is required}"
  NODE="${BROKKR_CANARY_NODE:?test node is required}"
  AFTER_VERIFY_HOOK="${BROKKR_CANARY_AFTER_SOURCE_VERIFY_HOOK:-}"
  ROOT_PREFIX="${TEST_ROOT%/}"
else
  [[ "$EUID" -eq 0 ]] || die "root is required"
  [[ -z "${BROKKR_CANARY_SYSTEMCTL:-}" &&
    -z "${BROKKR_CANARY_FALLOCATE:-}" &&
    -z "${BROKKR_CANARY_NODE:-}" &&
    -z "${BROKKR_CANARY_AFTER_SOURCE_VERIFY_HOOK:-}" ]] ||
    die "command overrides are test-only"
  SYSTEMCTL="/usr/bin/systemctl"
  FALLOCATE="/usr/bin/fallocate"
  NODE="/usr/bin/node"
  AFTER_VERIFY_HOOK=""
  ROOT_PREFIX=""
fi

root_path() {
  printf '%s%s\n' "$ROOT_PREFIX" "$1"
}

EXPECTED_UID="$EUID"
RELEASE_PATH="/usr/local/lib/brokkr/releases/$REVISION"
RELEASE_PARENT_PATH="/usr/local/lib/brokkr/releases"
STATE_PATH="/var/lib/brokkr/debian-maintenance"
UNIT_PATH="/etc/systemd/system"
RELEASE_ROOT="$(root_path "$RELEASE_PATH")"
RELEASE_PARENT="$(root_path "$RELEASE_PARENT_PATH")"
STATE_ROOT="$(root_path "$STATE_PATH")"
UNIT_ROOT="$(root_path "$UNIT_PATH")"
APPLY_UNIT="brokkr-debian-maintenance-canary-$CANARY.service"
RECOVERY_UNIT="brokkr-debian-maintenance-recovery@.service"
FACTORY_UNIT="brokkr-debian-maintenance-attempt-factory.service"
FACTORY_TIMER="brokkr-debian-maintenance-attempt-factory.timer"
RELEASE_FILES=(
  docs/autonomy-constitution-v2.schema.json
  docs/autonomy-coverage-registry-v2.schema.json
  docs/autonomy-owner-attestation-registry-v1.schema.json
  docs/autonomy-owner-authorization-v1.schema.json
  docs/autonomy-recovery-worker-registry-v1.schema.json
  docs/autonomy-runtime-narrowing-v1.schema.json
  docs/autonomous-mutation-journal-v2.schema.json
  docs/debian-maintenance-attempt-factory-config-v1.schema.json
  docs/debian-maintenance-window-freshness-v1.schema.json
  scripts/debian-maintenance-attempt-factory.mjs
  scripts/debian-maintenance-autonomy.mjs
  scripts/debian-maintenance-executor.mjs
  scripts/debian-maintenance-host-adapter.mjs
  scripts/maintenance-controller.mjs
  scripts/lib/autonomy-authorization.mjs
  scripts/lib/debian-maintenance-attempt-factory.mjs
  scripts/lib/fixed-debian-maintenance-host-operation.mjs
  scripts/lib/maintenance-policy-contract.mjs
  scripts/lib/bounded-recovery-dispatch.mjs
  systemd/brokkr-debian-maintenance-attempt-factory.service.in
  systemd/brokkr-debian-maintenance-attempt-factory.timer
  systemd/brokkr-debian-maintenance-recovery.service.in
)
STAGE_ROOT=""
INSTALL_LOCK=""
PUBLISHED_APPLY=0
PUBLISHED_RECOVERY=0
PUBLISHED_FACTORY=0
PUBLISHED_FACTORY_TIMER=0
HEADROOM_TEMP=""

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    [[ "$PUBLISHED_APPLY" -eq 0 ]] ||
      rm -f "$UNIT_ROOT/$APPLY_UNIT"
    [[ "$PUBLISHED_RECOVERY" -eq 0 ]] ||
      rm -f "$UNIT_ROOT/$RECOVERY_UNIT"
    [[ "$PUBLISHED_FACTORY" -eq 0 ]] ||
      rm -f "$UNIT_ROOT/$FACTORY_UNIT"
    [[ "$PUBLISHED_FACTORY_TIMER" -eq 0 ]] ||
      rm -f "$UNIT_ROOT/$FACTORY_TIMER"
  fi
  [[ -z "$STAGE_ROOT" || ! -d "$STAGE_ROOT" ]] ||
    rm -rf "$STAGE_ROOT"
  [[ -z "$HEADROOM_TEMP" || ! -e "$HEADROOM_TEMP" ]] ||
    rm -f "$HEADROOM_TEMP"
  [[ -z "$INSTALL_LOCK" || ! -d "$INSTALL_LOCK" ]] ||
    rmdir "$INSTALL_LOCK"
  exit "$status"
}
trap cleanup EXIT

verify_secure_path() {
  local target="$1"
  local expected_type="$2"
  local private_final="${3:-0}"
  local expected_mode="${4:-}"
  "$NODE" --input-type=module - \
    "${ROOT_PREFIX:-/}" "$EXPECTED_UID" "$target" \
    "$expected_type" "$private_final" "$expected_mode" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [baseInput, uidInput, target, expectedType, privateFinal, modeInput] =
  process.argv.slice(2);
const base = path.resolve(baseInput);
const expectedUid = Number(uidInput);
const resolvedTarget = path.resolve(target);
const relative = path.relative(base, resolvedTarget);
if (relative.startsWith("..") || path.isAbsolute(relative)) {
  throw new Error("install_path_outside_root");
}
const components = relative === "" ? [] : relative.split(path.sep);
let current = base;
const check = (candidate, type, isFinal) => {
  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() ||
      (type === "dir" && !stat.isDirectory()) ||
      (type === "file" && !stat.isFile()) ||
      stat.uid !== expectedUid ||
      (stat.mode & 0o022) !== 0 ||
      (isFinal && privateFinal === "1" && (stat.mode & 0o077) !== 0) ||
      (isFinal && modeInput !== "" &&
        (stat.mode & 0o7777) !== Number.parseInt(modeInput, 8))) {
    throw new Error(`install_path_unsafe:${candidate}`);
  }
};
try {
  fs.lstatSync(base);
} catch (error) {
  if (error?.code === "ENOENT") process.exit(0);
  throw error;
}
check(base, "dir", components.length === 0);
for (let index = 0; index < components.length; index += 1) {
  current = path.join(current, components[index]);
  try {
    fs.lstatSync(current);
  } catch (error) {
    if (error?.code === "ENOENT") process.exit(0);
    throw error;
  }
  const final = index === components.length - 1;
  check(current, final ? expectedType : "dir", final);
}
NODE
}

verify_secure_release_tree() {
  local release="$1"
  "$NODE" --input-type=module - "$release" "$EXPECTED_UID" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [root, uidInput] = process.argv.slice(2);
const expectedUid = Number(uidInput);
const visit = candidate => {
  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() ||
      (!stat.isDirectory() && !stat.isFile()) ||
      stat.uid !== expectedUid ||
      (stat.mode & 0o022) !== 0) {
    throw new Error(`install_release_metadata_unsafe:${candidate}`);
  }
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(candidate)) {
      visit(path.join(candidate, entry));
    }
  }
};
visit(root);
NODE
}

verify_release_metadata_matches() {
  local staged="$1"
  local installed="$2"
  "$NODE" --input-type=module - "$staged" "$installed" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [stagedRoot, installedRoot] = process.argv.slice(2);
const walk = (root, relative = ".") => {
  const candidate = path.join(root, relative);
  const stat = fs.lstatSync(candidate);
  const entries = stat.isDirectory() ?
    fs.readdirSync(candidate).sort() : [];
  return [{
    relative,
    type: stat.isDirectory() ? "dir" :
      stat.isFile() ? "file" : "other",
    mode: stat.mode & 0o7777,
  }, ...entries.flatMap(entry =>
    walk(root, relative === "." ? entry : path.join(relative, entry)))];
};
if (JSON.stringify(walk(stagedRoot)) !==
    JSON.stringify(walk(installedRoot))) {
  throw new Error("install_release_metadata_mismatch");
}
NODE
}

verify_existing_reserve() {
  local reserve="$1"
  "$NODE" --input-type=module - "$reserve" "$EXPECTED_UID" <<'NODE'
import fs from "node:fs";
const [file, uidInput] = process.argv.slice(2);
const expectedUid = Number(uidInput);
const stat = fs.lstatSync(file);
if (!stat.isFile() || stat.isSymbolicLink() ||
    stat.uid !== expectedUid || (stat.mode & 0o7777) !== 0o600 ||
    stat.size !== 8 * 1024 * 1024 ||
    stat.blocks * 512 < stat.size) {
  throw new Error(`install_headroom_reserve_unsafe:${file}`);
}
NODE
}

preflight_install_paths() {
  verify_secure_path "$UNIT_ROOT" dir
  verify_secure_path "$RELEASE_PARENT" dir
  verify_secure_path "$RELEASE_ROOT" dir
  local directory
  for directory in \
    "$STATE_ROOT" \
    "$STATE_ROOT/requests" \
    "$STATE_ROOT/registrations" \
    "$STATE_ROOT/fences" \
    "$STATE_ROOT/journals" \
    "$STATE_ROOT/terminals" \
    "$STATE_ROOT/recovery-activations" \
    "$STATE_ROOT/recovery-authorizations" \
    "$STATE_ROOT/disarmed" \
    "$STATE_ROOT/evidence" \
    "$STATE_ROOT/headroom"; do
    verify_secure_path "$directory" dir 1 0700
  done
  local reserve
  for reserve in journal.reserve evidence.reserve; do
    if [[ -e "$STATE_ROOT/headroom/$reserve" ||
      -L "$STATE_ROOT/headroom/$reserve" ]]; then
      verify_existing_reserve "$STATE_ROOT/headroom/$reserve"
    fi
  done
}

verify_install_source() {
  [[ -d "$SOURCE/.git" || -f "$SOURCE/.git" ]] ||
    die "source is not a Git worktree"
  local actual
  actual="$(git -C "$SOURCE" rev-parse HEAD)" ||
    die "cannot resolve source revision"
  [[ "$actual" == "$REVISION" ]] ||
    die "source revision does not match requested revision"
  [[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ]] ||
    die "source worktree is dirty"
  git -C "$SOURCE" cat-file -e "$REVISION^{commit}" ||
    die "requested revision is not a commit"
  if [[ -n "$AFTER_VERIFY_HOOK" ]]; then
    [[ "$AFTER_VERIFY_HOOK" == /* && -x "$AFTER_VERIFY_HOOK" ]] ||
      die "test source-verification hook is unsafe"
    "$AFTER_VERIFY_HOOK" "$SOURCE"
  fi
}

preflight_installed_units() {
  local apply="$UNIT_ROOT/$APPLY_UNIT"
  local recovery="$UNIT_ROOT/$RECOVERY_UNIT"
  local factory="$UNIT_ROOT/$FACTORY_UNIT"
  local factory_timer="$UNIT_ROOT/$FACTORY_TIMER"
  local apply_exists=0
  local recovery_exists=0
  local factory_exists=0
  local factory_timer_exists=0
  [[ ! -e "$apply" && ! -L "$apply" ]] || apply_exists=1
  [[ ! -e "$recovery" && ! -L "$recovery" ]] || recovery_exists=1
  [[ ! -e "$factory" && ! -L "$factory" ]] || factory_exists=1
  [[ ! -e "$factory_timer" && ! -L "$factory_timer" ]] ||
    factory_timer_exists=1
  [[ "$apply_exists" -eq "$recovery_exists" &&
    "$apply_exists" -eq "$factory_exists" &&
    "$apply_exists" -eq "$factory_timer_exists" ]] ||
    die "installed canary unit set is incomplete"
  if [[ "$apply_exists" -eq 1 ]]; then
    verify_secure_path "$apply" file 0 0644
    verify_secure_path "$recovery" file 0 0644
    verify_secure_path "$factory" file 0 0644
    verify_secure_path "$factory_timer" file 0 0644
    grep -Fqx "Environment=BROKKR_RELEASE_SHA=$REVISION" "$apply" &&
      grep -Fqx "Environment=BROKKR_RELEASE_SHA=$REVISION" "$recovery" &&
      grep -Fqx "Environment=BROKKR_RELEASE_SHA=$REVISION" "$factory" ||
      die "installed canary revision does not match"
  fi
}

stage_exact_release() {
  install -d -m 0755 "$RELEASE_PARENT"
  STAGE_ROOT="$(mktemp -d "$RELEASE_PARENT/.brokkr-$REVISION.XXXXXX")"
  chmod 0700 "$STAGE_ROOT"
  local staged_release="$STAGE_ROOT/release"
  mkdir -p "$staged_release"
  git -C "$SOURCE" archive --format=tar "$REVISION" -- \
    "${RELEASE_FILES[@]}" |
    tar -x -C "$staged_release"
  local file
  local expected_blob
  local actual_blob
  for file in "${RELEASE_FILES[@]}"; do
    [[ -f "$staged_release/$file" && ! -L "$staged_release/$file" ]] ||
      die "required release file is missing or unsafe: $file"
    expected_blob="$(git -C "$SOURCE" rev-parse "$REVISION:$file")"
    actual_blob="$(git -C "$SOURCE" hash-object "$staged_release/$file")"
    [[ "$actual_blob" == "$expected_blob" ]] ||
      die "archived release file does not match commit: $file"
  done
  chmod 0755 \
    "$staged_release" \
    "$staged_release/docs" \
    "$staged_release/scripts" \
    "$staged_release/scripts/lib" \
    "$staged_release/systemd"
  chmod 0755 \
    "$staged_release/scripts/debian-maintenance-attempt-factory.mjs" \
    "$staged_release/scripts/debian-maintenance-host-adapter.mjs"
  chmod 0644 \
    "$staged_release/docs/autonomy-constitution-v2.schema.json" \
    "$staged_release/docs/autonomy-coverage-registry-v2.schema.json" \
    "$staged_release/docs/autonomy-owner-attestation-registry-v1.schema.json" \
    "$staged_release/docs/autonomy-owner-authorization-v1.schema.json" \
    "$staged_release/docs/autonomy-recovery-worker-registry-v1.schema.json" \
    "$staged_release/docs/autonomy-runtime-narrowing-v1.schema.json" \
    "$staged_release/docs/autonomous-mutation-journal-v2.schema.json" \
    "$staged_release/docs/debian-maintenance-attempt-factory-config-v1.schema.json" \
    "$staged_release/docs/debian-maintenance-window-freshness-v1.schema.json" \
    "$staged_release/scripts/debian-maintenance-autonomy.mjs" \
    "$staged_release/scripts/debian-maintenance-executor.mjs" \
    "$staged_release/scripts/maintenance-controller.mjs" \
    "$staged_release/scripts/lib/autonomy-authorization.mjs" \
    "$staged_release/scripts/lib/debian-maintenance-attempt-factory.mjs" \
    "$staged_release/scripts/lib/fixed-debian-maintenance-host-operation.mjs" \
    "$staged_release/scripts/lib/maintenance-policy-contract.mjs" \
    "$staged_release/scripts/lib/bounded-recovery-dispatch.mjs" \
    "$staged_release/systemd/brokkr-debian-maintenance-attempt-factory.service.in" \
    "$staged_release/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
    "$staged_release/systemd/brokkr-debian-maintenance-recovery.service.in"
}

install_directories() {
  [[ -d "$UNIT_ROOT" ]] || install -d -m 0755 "$UNIT_ROOT"
  install -d -m 0700 \
    "$STATE_ROOT" \
    "$STATE_ROOT/requests" \
    "$STATE_ROOT/registrations" \
    "$STATE_ROOT/fences" \
    "$STATE_ROOT/journals" \
    "$STATE_ROOT/terminals" \
    "$STATE_ROOT/recovery-activations" \
    "$STATE_ROOT/recovery-authorizations" \
    "$STATE_ROOT/disarmed" \
    "$STATE_ROOT/evidence" \
    "$STATE_ROOT/headroom"
}

preallocate_headroom() {
  local reserve
  local destination
  local temporary
  for reserve in journal.reserve evidence.reserve; do
    destination="$STATE_ROOT/headroom/$reserve"
    if [[ -e "$destination" || -L "$destination" ]]; then
      verify_existing_reserve "$destination"
      continue
    fi
    temporary="$STATE_ROOT/headroom/.$reserve.$$"
    HEADROOM_TEMP="$temporary"
    "$FALLOCATE" -l 8M "$temporary"
    chmod 0600 "$temporary"
    verify_existing_reserve "$temporary"
    mv "$temporary" "$destination"
    HEADROOM_TEMP=""
  done
}

render_apply_unit() {
  local destination="$1"
  {
    printf '%s\n' \
      '[Unit]' \
      "Description=Brokkr supervised Debian maintenance canary $CANARY" \
      'Documentation=https://github.com/Magnus-Gille/brokkr/blob/main/docs/supervised-debian-maintenance.md' \
      'After=network-online.target local-fs.target' \
      'Wants=network-online.target' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      'User=root' \
      'NoNewPrivileges=yes' \
      'PrivateTmp=yes' \
      'ProtectHome=yes' \
      'ProtectSystem=false' \
      'ProtectKernelTunables=yes' \
      'ProtectControlGroups=yes' \
      'ProtectKernelLogs=yes' \
      'PrivateDevices=yes' \
      'RestrictSUIDSGID=yes' \
      "ReadWritePaths=$STATE_PATH /var/lib/dpkg /var/cache/apt /var/log/apt" \
      "Environment=BROKKR_RELEASE_SHA=$REVISION" \
      "ExecCondition=/usr/bin/test ! -e $STATE_PATH/disarmed/$CANARY.json" \
      "ExecStart=$RELEASE_PATH/scripts/debian-maintenance-host-adapter.mjs --action apply --attempt $CANARY" \
      'TimeoutStartSec=300'
  } >"$destination"
  chmod 0644 "$destination"
}

render_recovery_unit() {
  local destination="$1"
  local template="$2"
  grep -Fq '@RELEASE_SHA@' "$template" ||
    die "recovery unit template lacks release placeholder"
  sed \
    -e "s/@RELEASE_SHA@/$REVISION/g" \
    "$template" >"$destination"
  if grep -Eq '@[A-Za-z0-9_]+@' "$destination"; then
    die "recovery unit template has unresolved placeholders"
  fi
  chmod 0644 "$destination"
}

render_factory_unit() {
  local destination="$1"
  local template="$2"
  grep -Fq '@RELEASE_SHA@' "$template" ||
    die "attempt factory unit template lacks release placeholder"
  sed -e "s/@RELEASE_SHA@/$REVISION/g" "$template" >"$destination"
  if grep -Eq '@[A-Za-z0-9_]+@' "$destination"; then
    die "attempt factory unit template has unresolved placeholders"
  fi
  chmod 0644 "$destination"
}

verify_or_publish_release() {
  local staged="$STAGE_ROOT/release"
  if [[ -e "$RELEASE_ROOT" || -L "$RELEASE_ROOT" ]]; then
    verify_secure_path "$RELEASE_ROOT" dir
    verify_secure_release_tree "$RELEASE_ROOT"
    verify_release_metadata_matches "$staged" "$RELEASE_ROOT"
    diff -qr "$staged" "$RELEASE_ROOT" >/dev/null ||
      die "existing release differs from exact revision"
    return
  fi
  mv "$staged" "$RELEASE_ROOT"
}

verify_or_publish_units() {
  local staged_apply="$STAGE_ROOT/$APPLY_UNIT"
  local staged_recovery="$STAGE_ROOT/$RECOVERY_UNIT"
  local apply="$UNIT_ROOT/$APPLY_UNIT"
  local recovery="$UNIT_ROOT/$RECOVERY_UNIT"
  local staged_factory="$STAGE_ROOT/$FACTORY_UNIT"
  local staged_factory_timer="$STAGE_ROOT/$FACTORY_TIMER"
  local factory="$UNIT_ROOT/$FACTORY_UNIT"
  local factory_timer="$UNIT_ROOT/$FACTORY_TIMER"
  if [[ -e "$apply" || -L "$apply" ]]; then
    preflight_installed_units
    cmp -s "$staged_apply" "$apply" &&
      cmp -s "$staged_recovery" "$recovery" &&
      cmp -s "$staged_factory" "$factory" &&
      cmp -s "$staged_factory_timer" "$factory_timer" ||
      die "installed canary units differ from exact revision"
    return
  fi
  mv "$staged_factory_timer" "$factory_timer"
  PUBLISHED_FACTORY_TIMER=1
  mv "$staged_factory" "$factory"
  PUBLISHED_FACTORY=1
  mv "$staged_recovery" "$recovery"
  PUBLISHED_RECOVERY=1
  mv "$staged_apply" "$apply"
  PUBLISHED_APPLY=1
  PUBLISHED_RECOVERY=0
  PUBLISHED_FACTORY=0
  PUBLISHED_FACTORY_TIMER=0
  PUBLISHED_APPLY=0
}

write_disarm_marker() {
  local destination="$STATE_ROOT/disarmed/$CANARY.json"
  local recorded_at
  recorded_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  "$NODE" --input-type=module - \
    "$destination" "$CANARY" "$REVISION" "$recorded_at" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const [destination, canary, release, recordedAt] = process.argv.slice(2);
const directory = path.dirname(destination);
fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
fs.chmodSync(directory, 0o700);
const temporary =
  `${destination}.${process.pid}.${crypto.randomUUID()}.tmp`;
const value = {
  canary_id: canary,
  evidence_preserved: true,
  kind: "brokkr-debian-maintenance-canary-disarm",
  recorded_at: recordedAt,
  release_sha: release,
  schema_version: "v1",
  state_preserved: true,
};
let descriptor;
try {
  descriptor = fs.openSync(temporary, "wx", 0o600);
  fs.writeFileSync(descriptor, `${JSON.stringify(value)}\n`);
  fs.fsyncSync(descriptor);
  fs.closeSync(descriptor);
  descriptor = undefined;
  fs.renameSync(temporary, destination);
  const directoryDescriptor = fs.openSync(directory, "r");
  try {
    fs.fsyncSync(directoryDescriptor);
  } finally {
    fs.closeSync(directoryDescriptor);
  }
} finally {
  if (descriptor !== undefined) fs.closeSync(descriptor);
  try {
    fs.unlinkSync(temporary);
  } catch {
    // Only the unique unpublished temporary is eligible for cleanup.
  }
}
NODE
}

case "$ACTION" in
  install)
    verify_install_source
    preflight_install_paths
    preflight_installed_units
    [[ -d "$UNIT_ROOT" ]] || install -d -m 0755 "$UNIT_ROOT"
    install_lock_candidate="$UNIT_ROOT/.brokkr-canary-$CANARY.install-lock"
    mkdir "$install_lock_candidate" ||
      die "another canary install is in progress"
    INSTALL_LOCK="$install_lock_candidate"
    preflight_install_paths
    preflight_installed_units
    stage_exact_release
    render_apply_unit "$STAGE_ROOT/$APPLY_UNIT"
    render_recovery_unit \
      "$STAGE_ROOT/$RECOVERY_UNIT" \
      "$STAGE_ROOT/release/systemd/brokkr-debian-maintenance-recovery.service.in"
    render_factory_unit \
      "$STAGE_ROOT/$FACTORY_UNIT" \
      "$STAGE_ROOT/release/systemd/brokkr-debian-maintenance-attempt-factory.service.in"
    cp \
      "$STAGE_ROOT/release/systemd/brokkr-debian-maintenance-attempt-factory.timer" \
      "$STAGE_ROOT/$FACTORY_TIMER"
    chmod 0644 "$STAGE_ROOT/$FACTORY_TIMER"
    if [[ -e "$RELEASE_ROOT" || -L "$RELEASE_ROOT" ]]; then
      verify_secure_path "$RELEASE_ROOT" dir
      verify_secure_release_tree "$RELEASE_ROOT"
      verify_release_metadata_matches \
        "$STAGE_ROOT/release" "$RELEASE_ROOT"
      diff -qr "$STAGE_ROOT/release" "$RELEASE_ROOT" >/dev/null ||
        die "existing release differs from exact revision"
    fi
    if [[ -e "$UNIT_ROOT/$APPLY_UNIT" ||
      -L "$UNIT_ROOT/$APPLY_UNIT" ]]; then
      preflight_installed_units
      cmp -s "$STAGE_ROOT/$APPLY_UNIT" "$UNIT_ROOT/$APPLY_UNIT" &&
        cmp -s "$STAGE_ROOT/$RECOVERY_UNIT" "$UNIT_ROOT/$RECOVERY_UNIT" &&
        cmp -s "$STAGE_ROOT/$FACTORY_UNIT" "$UNIT_ROOT/$FACTORY_UNIT" &&
        cmp -s "$STAGE_ROOT/$FACTORY_TIMER" "$UNIT_ROOT/$FACTORY_TIMER" ||
        die "installed canary units differ from exact revision"
    fi
    install_directories
    preallocate_headroom
    verify_or_publish_release
    verify_or_publish_units
    printf 'installed disabled canary %s at release %s\n' "$CANARY" "$REVISION"
    ;;
  disable)
    preflight_install_paths
    preflight_installed_units
    [[ -f "$UNIT_ROOT/$APPLY_UNIT" ]] ||
      die "revision-bound canary unit is not installed"
    write_disarm_marker
    set +e
    "$SYSTEMCTL" disable --now "$APPLY_UNIT"
    apply_status=$?
    "$SYSTEMCTL" stop "brokkr-debian-maintenance-recovery@$CANARY.service"
    recovery_status=$?
    set -e
    [[ "$apply_status" -eq 0 && "$recovery_status" -eq 0 ]] ||
      die "canary disarm marker persisted but systemd stop failed"
    printf 'disabled and disarmed canary %s; evidence preserved\n' "$CANARY"
    ;;
esac
