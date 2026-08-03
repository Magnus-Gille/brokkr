#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  install-maintenance-execution-result-delivery.sh install \
    --source ABSOLUTE_PATH --revision FULL_SHA

Installs an exact-revision adapter and an unconfigured, disabled systemd unit.
It never provisions credentials, enables or starts the unit, or performs
maintenance or delivery.
EOF
  exit 64
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${1:-}" == "install" ]] || usage
shift
SOURCE=""
REVISION=""
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
    *)
      usage
      ;;
  esac
done

[[ "$SOURCE" == /* ]] || die "--source must be absolute"
[[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] ||
  die "--revision must be a full lowercase Git SHA"

TEST_ROOT="${BROKKR_DELIVERY_INSTALL_TEST_ROOT:-}"
if [[ -n "$TEST_ROOT" ]]; then
  [[ "$TEST_ROOT" == /* && "$TEST_ROOT" != "/" ]] ||
    die "test root must be an absolute non-root path"
  NODE="${BROKKR_DELIVERY_NODE:?test node is required}"
  ROOT_PREFIX="${TEST_ROOT%/}"
else
  [[ "$EUID" -eq 0 ]] || die "root is required"
  [[ -z "${BROKKR_DELIVERY_NODE:-}" ]] ||
    die "command overrides are test-only"
  NODE="/usr/bin/node"
  ROOT_PREFIX=""
fi

EXPECTED_UID="$EUID"
UNIT_NAME="brokkr-maintenance-execution-result-delivery.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
RELEASE_PATH="/usr/local/lib/brokkr/maintenance-result-delivery/releases/$REVISION"
RELEASE_PARENT_PATH="/usr/local/lib/brokkr/maintenance-result-delivery/releases"
UNIT_ROOT="${ROOT_PREFIX}/etc/systemd/system"
UNIT="${ROOT_PREFIX}${UNIT_PATH}"
RELEASE_ROOT="${ROOT_PREFIX}${RELEASE_PATH}"
RELEASE_PARENT="${ROOT_PREFIX}${RELEASE_PARENT_PATH}"
RELEASE_FILES=(
  scripts/maintenance-execution-result-delivery.mjs
  scripts/maintenance-execution-result.mjs
  scripts/lib/autonomy-authorization.mjs
  systemd/brokkr-maintenance-execution-result-delivery.service.in
)
STAGE_ROOT=""
INSTALL_LOCK=""
INSTALL_LOCK_HELD=false

cleanup() {
  local status=$?
  [[ -z "$STAGE_ROOT" || ! -d "$STAGE_ROOT" ]] ||
    rm -rf "$STAGE_ROOT"
  [[ "$INSTALL_LOCK_HELD" != true || ! -d "$INSTALL_LOCK" ]] ||
    rmdir "$INSTALL_LOCK"
  exit "$status"
}
trap cleanup EXIT

verify_path() {
  local candidate="$1"
  local expected_type="$2"
  local expected_mode="${3:-}"
  "$NODE" --input-type=module - \
    "${ROOT_PREFIX:-/}" "$candidate" "$EXPECTED_UID" \
    "$expected_type" "$expected_mode" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [baseInput, candidate, uidInput, expectedType, modeInput] =
  process.argv.slice(2);
const base = path.resolve(baseInput);
const expectedUid = Number(uidInput);
const target = path.resolve(candidate);
const relative = path.relative(base, target);
if (relative.startsWith("..") || path.isAbsolute(relative)) {
  throw new Error("delivery_install_path_outside_root");
}
const components = relative === "" ? [] : relative.split(path.sep);
let current = base;
const check = (value, type, final) => {
  const stat = fs.lstatSync(value);
  if (stat.isSymbolicLink() ||
      (type === "dir" && !stat.isDirectory()) ||
      (type === "file" && !stat.isFile()) ||
      stat.uid !== expectedUid ||
      (stat.mode & 0o022) !== 0 ||
      (final && modeInput !== "" &&
        (stat.mode & 0o7777) !== Number.parseInt(modeInput, 8))) {
    throw new Error("delivery_install_path_unsafe");
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

verify_release_tree() {
  local root="$1"
  "$NODE" --input-type=module - "$root" "$EXPECTED_UID" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [root, uidInput] = process.argv.slice(2);
const expectedUid = Number(uidInput);
const visit = candidate => {
  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() ||
      (!stat.isDirectory() && !stat.isFile()) ||
      stat.uid !== expectedUid || (stat.mode & 0o022) !== 0) {
    throw new Error("delivery_install_release_unsafe");
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

verify_source() {
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
}

preflight_existing() {
  "$NODE" --input-type=module - "${ROOT_PREFIX:-}" "$UNIT_NAME" "$UNIT" <<'NODE'
import fs from "node:fs";
import path from "node:path";
const [rootPrefixInput, unitName, unitPath] = process.argv.slice(2);
const rootPrefix = rootPrefixInput === "" ? "" : path.resolve(rootPrefixInput);
const maxLinkDepth = 64;
const maxAliasClosureExpansions = 256;
const dependencyDirectoryPattern = /\.(?:wants|requires|upholds)$/;
const unitSearchRoots = [
  "/etc/systemd/system.control",
  "/run/systemd/system.control",
  "/run/systemd/transient",
  "/run/systemd/generator.early",
  "/etc/systemd/system",
  "/etc/systemd/system.attached",
  "/run/systemd/system",
  "/run/systemd/system.attached",
  "/run/systemd/generator",
  "/usr/local/lib/systemd/system",
  "/usr/lib/systemd/system",
  "/run/systemd/generator.late",
];
const mappedRoot = absoluteRoot => (
  rootPrefix === "" ? absoluteRoot : path.join(rootPrefix, absoluteRoot.slice(1))
);
const mappedSearchRoots = unitSearchRoots.map(root => path.resolve(mappedRoot(root)));
const isWithin = (base, candidate) => {
  const relative = path.relative(base, candidate);
  return relative === "" ||
    (!relative.startsWith("..") && !path.isAbsolute(relative));
};
const canonicalLeaf = candidate => {
  const normalized = path.resolve(candidate);
  let parent;
  try {
    parent = fs.realpathSync(path.dirname(normalized));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  return path.join(parent, path.basename(normalized));
};
const existingSearchRoots = mappedSearchRoots.flatMap(root => {
  if (!fs.existsSync(root)) return [];
  const canonicalRoot = canonicalLeaf(root);
  if (canonicalRoot === null) {
    throw new Error("delivery_unit_dependency_directory_unsafe");
  }
  return [{ normalized: root, canonical: canonicalRoot }];
});
if (existingSearchRoots.length === 0) process.exit(0);
const adapterTargetPaths = new Set();
for (const root of mappedSearchRoots) {
  const normalizedAdapterPath = path.join(root, unitName);
  adapterTargetPaths.add(normalizedAdapterPath);
  const canonicalAdapterPath = canonicalLeaf(normalizedAdapterPath);
  if (canonicalAdapterPath !== null) {
    adapterTargetPaths.add(canonicalAdapterPath);
  }
}
const resolveTerminalLeaf = start => {
  let current = path.resolve(start);
  let followedLinks = 0;
  const seen = new Set();
  while (true) {
    const leaf = canonicalLeaf(current);
    const identity = leaf ?? path.resolve(current);
    if (seen.has(identity)) {
      throw new Error("delivery_unit_dependency_cycle");
    }
    seen.add(identity);
    let stat;
    try {
      stat = fs.lstatSync(identity);
    } catch (error) {
      if (error?.code === "ENOENT") {
        return { leaf: identity, basename: path.basename(identity) };
      }
      throw error;
    }
    if (!stat.isSymbolicLink()) {
      return { leaf: identity, basename: path.basename(identity) };
    }
    if (followedLinks >= maxLinkDepth) {
      throw new Error("delivery_unit_dependency_depth");
    }
    followedLinks += 1;
    const linkTarget = fs.readlinkSync(identity);
    current = path.resolve(path.dirname(identity), linkTarget);
  }
};
const reverseEdges = new Map();
const addReverseEdge = (targetName, sourceName) => {
  if (!targetName || sourceName === targetName) return;
  if (!reverseEdges.has(targetName)) reverseEdges.set(targetName, new Set());
  reverseEdges.get(targetName).add(sourceName);
};
for (const { normalized: root } of existingSearchRoots) {
  const stat = fs.lstatSync(root);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error("delivery_unit_dependency_directory_unsafe");
  }
  for (const entry of fs.readdirSync(root)) {
    const child = path.join(root, entry);
    const childStat = fs.lstatSync(child);
    if (!childStat.isSymbolicLink()) continue;
    if (dependencyDirectoryPattern.test(entry)) {
      throw new Error("delivery_unit_dependency_directory_unsafe");
    }
    const immediateTarget = path.resolve(
      path.dirname(child),
      fs.readlinkSync(child),
    );
    addReverseEdge(path.basename(immediateTarget), entry);
    addReverseEdge(resolveTerminalLeaf(child).basename, entry);
  }
}
const checkDependencyLink = dependencyEntry => {
  const terminal = resolveTerminalLeaf(dependencyEntry);
  if (adapterTargetPaths.has(terminal.leaf)) {
    throw new Error("delivery_unit_already_enabled");
  }
};
const adapterNames = new Set([unitName]);
const queue = [unitName];
let aliasClosureExpansions = 0;
while (queue.length > 0) {
  const current = queue.shift();
  for (const alias of reverseEdges.get(current) ?? []) {
    if (adapterNames.has(alias)) continue;
    aliasClosureExpansions += 1;
    if (aliasClosureExpansions > maxAliasClosureExpansions) {
      throw new Error("delivery_unit_dependency_depth");
    }
    adapterNames.add(alias);
    queue.push(alias);
  }
}
const visitedDirectories = new Set();
const visit = (root, candidate) => {
  const candidateStat = fs.lstatSync(candidate);
  if (candidateStat.isSymbolicLink() || !candidateStat.isDirectory()) {
    throw new Error("delivery_unit_dependency_directory_unsafe");
  }
  const realCandidate = fs.realpathSync(candidate);
  if (!isWithin(root.canonical, realCandidate)) {
    throw new Error("delivery_unit_dependency_directory_unsafe");
  }
  if (visitedDirectories.has(realCandidate)) return;
  visitedDirectories.add(realCandidate);
  const dependencyDirectory = dependencyDirectoryPattern.test(path.basename(candidate));
  for (const entry of fs.readdirSync(candidate)) {
    const child = path.join(candidate, entry);
    if (dependencyDirectory && adapterNames.has(entry)) {
      throw new Error("delivery_unit_already_enabled");
    }
    const stat = fs.lstatSync(child);
    if (stat.isSymbolicLink()) {
      if (entry === unitName) {
        throw new Error("delivery_unit_already_enabled");
      }
      if (dependencyDirectory) {
        checkDependencyLink(child);
      }
      if (dependencyDirectoryPattern.test(entry)) {
        throw new Error("delivery_unit_dependency_directory_unsafe");
      }
    } else if (stat.isDirectory()) {
      visit(root, child);
    }
  }
};
for (const root of existingSearchRoots) {
  visit(root, root.normalized);
}
NODE
  verify_path "$UNIT_ROOT" dir
  if [[ -e "$UNIT" || -L "$UNIT" ]]; then
    verify_path "$UNIT" file 0644
    grep -Fqx "Environment=BROKKR_ADAPTER_REVISION=$REVISION" "$UNIT" ||
      die "installed delivery adapter revision does not match"
  fi
  if [[ -e "$RELEASE_ROOT" || -L "$RELEASE_ROOT" ]]; then
    verify_path "$RELEASE_ROOT" dir 0755
    verify_release_tree "$RELEASE_ROOT"
  fi
}

stage_release() {
  install -d -m 0755 "$RELEASE_PARENT"
  STAGE_ROOT="$(mktemp -d "$RELEASE_PARENT/.brokkr-delivery-$REVISION.XXXXXX")"
  chmod 0700 "$STAGE_ROOT"
  mkdir -p "$STAGE_ROOT/release"
  git -C "$SOURCE" archive --format=tar "$REVISION" -- \
    "${RELEASE_FILES[@]}" |
    tar -x -C "$STAGE_ROOT/release"
  local file
  local expected_blob
  local actual_blob
  for file in "${RELEASE_FILES[@]}"; do
    [[ -f "$STAGE_ROOT/release/$file" &&
      ! -L "$STAGE_ROOT/release/$file" ]] ||
      die "required release file is missing or unsafe"
    expected_blob="$(git -C "$SOURCE" rev-parse "$REVISION:$file")"
    actual_blob="$(git -C "$SOURCE" hash-object "$STAGE_ROOT/release/$file")"
    [[ "$expected_blob" == "$actual_blob" ]] ||
      die "archived release file does not match commit"
  done
  chmod 0755 \
    "$STAGE_ROOT/release" \
    "$STAGE_ROOT/release/scripts" \
    "$STAGE_ROOT/release/scripts/lib" \
    "$STAGE_ROOT/release/systemd" \
    "$STAGE_ROOT/release/scripts/maintenance-execution-result-delivery.mjs"
  chmod 0644 \
    "$STAGE_ROOT/release/scripts/maintenance-execution-result.mjs" \
    "$STAGE_ROOT/release/scripts/lib/autonomy-authorization.mjs" \
    "$STAGE_ROOT/release/systemd/brokkr-maintenance-execution-result-delivery.service.in"
}

adapter_digest() {
  "$NODE" --input-type=module - \
    "$STAGE_ROOT/release/scripts/maintenance-execution-result-delivery.mjs" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";
process.stdout.write(`sha256:${crypto.createHash("sha256")
  .update(fs.readFileSync(process.argv[2])).digest("hex")}`);
NODE
}

render_unit() {
  local digest="$1"
  local template="$STAGE_ROOT/release/systemd/brokkr-maintenance-execution-result-delivery.service.in"
  sed \
    -e "s/@REVISION@/$REVISION/g" \
    -e "s/@DIGEST@/$digest/g" \
    "$template" >"$STAGE_ROOT/$UNIT_NAME"
  if grep -Eq '@[A-Za-z0-9_]+@' "$STAGE_ROOT/$UNIT_NAME"; then
    die "delivery unit template has unresolved placeholders"
  fi
  chmod 0644 "$STAGE_ROOT/$UNIT_NAME"
}

publish() {
  if [[ -e "$RELEASE_ROOT" || -L "$RELEASE_ROOT" ]]; then
    diff -qr "$STAGE_ROOT/release" "$RELEASE_ROOT" >/dev/null ||
      die "existing delivery release differs from exact revision"
  fi
  if [[ -e "$UNIT" || -L "$UNIT" ]]; then
    cmp -s "$STAGE_ROOT/$UNIT_NAME" "$UNIT" ||
      die "installed delivery unit differs from exact revision"
  fi
  if [[ ! -e "$RELEASE_ROOT" && ! -L "$RELEASE_ROOT" ]]; then
    mv "$STAGE_ROOT/release" "$RELEASE_ROOT"
  fi
  if [[ ! -e "$UNIT" && ! -L "$UNIT" ]]; then
    mv "$STAGE_ROOT/$UNIT_NAME" "$UNIT"
  fi
}

verify_source
verify_path "$UNIT_ROOT" dir
verify_path "$RELEASE_PARENT" dir
preflight_existing
[[ -d "$UNIT_ROOT" ]] || install -d -m 0755 "$UNIT_ROOT"
INSTALL_LOCK="$UNIT_ROOT/.brokkr-maintenance-result-delivery.install-lock"
mkdir "$INSTALL_LOCK" || die "another delivery adapter install is in progress"
INSTALL_LOCK_HELD=true
preflight_existing
stage_release
render_unit "$(adapter_digest)"
preflight_existing
publish
printf 'installed disabled maintenance-result delivery adapter at revision %s\n' \
  "$REVISION"
