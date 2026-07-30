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
