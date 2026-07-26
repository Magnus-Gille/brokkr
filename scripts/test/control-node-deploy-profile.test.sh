#!/usr/bin/env bash
# Hermetic owner-overlay deployment profile tests (brokkr#44).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SOURCE="$(cd "$HERE/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
SOURCE="$TMP/bound-source"
trap 'rm -rf "$TMP"' EXIT
git clone -q "$REPO_SOURCE" "$SOURCE"
cp "$REPO_SOURCE/profiles/deploy-control-node.py" "$SOURCE/profiles/deploy-control-node.py"
cp "$REPO_SOURCE/profiles/control-node-deploy.overlay.schema.json" "$SOURCE/profiles/control-node-deploy.overlay.schema.json"
git -C "$SOURCE" add profiles/deploy-control-node.py profiles/control-node-deploy.overlay.schema.json
git -C "$SOURCE" -c user.name=test -c user.email=test@example.invalid commit -qm 'fixture deploy profile'
RUNNER="$SOURCE/profiles/deploy-control-node.py"
COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
OVERLAY="$TMP/overlay.json"
CALLS="$TMP/calls"; : >"$CALLS"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/payload"

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$1" >>"$MOCK_CALLS"
printf 'ssh-body %s\n' "$2" >>"$MOCK_CALLS"
HOME="$MOCK_HOME" PATH="$MOCK_BIN:$PATH" bash -c "$2"
EOF
cat >"$TMP/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >>"$MOCK_CALLS"
source="${@: -2:1}"; source="${source%/}"; target="${!#}"; release="${target#*:}"
mkdir -p "$release"; cp -R "$source/." "$release"
EOF
cat >"$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  test) case "${2:-}" in -L) exit 1;; esac; exit 0 ;;
  -u) exit 0 ;;
  install) exit 0 ;;
  stat) if [[ "${!#}" == *"/release" ]]; then printf '750\n'; else printf '600\n'; fi ;;
  chmod) exit 0 ;;
  grep) printf '1\n' ;;
  systemctl) exit 0 ;;
  *) if [[ "$1" == */verify-heimdall-delivery.sh ]]; then exit 0; fi; exit 0 ;;
esac
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

cat >"$OVERLAY" <<EOF
{"schema_version":1,"ssh_target":"operator@example-control-node","deploy_target":"$TMP/release","runtime_user":"operator","runtime_home":"/home/operator","registry_path":"/srv/example/grimnir/services.json","heimdall_url":"https://heimdall.example.invalid/api/panels","heimdall_token_source":"/etc/brokkr/heimdall-fleet-token.env"}
EOF
chmod 600 "$OVERLAY"
export PATH="$TMP/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_BIN="$TMP/bin" MOCK_HOME="$TMP/home" TMPDIR="$TMP/payload"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# shellcheck disable=SC2034 # `check` evaluates assertions against these values.
run() { OUT="$(cd "$SOURCE" && python3 "$RUNNER" "$@" 2>&1)"; RC=$?; }

echo "control-node-deploy-profile.test.sh"
run --overlay "$OVERLAY" --commit deadbeef
check "short commit refuses before remote commands" '[[ "$RC" -ne 0 && "$OUT" == *"full SHA"* && ! -s "$CALLS" ]]'

chmod 644 "$OVERLAY"; run --overlay "$OVERLAY" --commit "$COMMIT"
check "group-readable overlay refuses before remote commands" '[[ "$RC" -ne 0 && "$OUT" == *"mode 600"* && ! -s "$CALLS" ]]'
chmod 600 "$OVERLAY"

python3 - "$OVERLAY" <<'EOF'
import json, sys
p=sys.argv[1]; value=json.load(open(p)); value["unexpected"]="x"; open(p,"w").write(json.dumps(value))
EOF
run --overlay "$OVERLAY" --commit "$COMMIT"
check "unknown overlay field refuses before remote commands" '[[ "$RC" -ne 0 && "$OUT" == *"unsupported field"* && ! -s "$CALLS" ]]'
python3 - "$OVERLAY" <<EOF
import json, sys
p=sys.argv[1]; value=json.load(open(p)); del value["unexpected"]; open(p,"w").write(json.dumps(value))
EOF
chmod 600 "$OVERLAY"

set_overlay_field() {
  python3 - "$OVERLAY" "$1" "$2" <<'EOF'
import json, sys
p, key, value = sys.argv[1:]; record=json.load(open(p)); record[key]=value; open(p,"w").write(json.dumps(record))
EOF
  chmod 600 "$OVERLAY"
}
expect_reject() {
  local label="$1" field="$2" value="$3"
  : >"$CALLS"; set_overlay_field "$field" "$value"; run --overlay "$OVERLAY" --commit "$COMMIT"
  check "$label" '[[ "$RC" -ne 0 && ! -s "$CALLS" ]]'
}

expect_reject "leading/trailing SSH metacharacters refuse before remote commands" ssh_target 'operator@example-control-node;id'
expect_reject "runtime-user metacharacters refuse before remote commands" runtime_user 'operator;id'
expect_reject "path traversal refuses before remote commands" deploy_target "$TMP/release/../escape"
expect_reject "duplicate path separators refuse before remote commands" registry_path '/srv//example/grimnir/services.json'
expect_reject "token-source traversal refuses before remote commands" heimdall_token_source '/etc/brokkr/../token.env'
expect_reject "endpoint credentials refuse before remote commands" heimdall_url 'https://user:pass@heimdall.example.invalid/api/panels'
expect_reject "malformed endpoint host and port refuse before remote commands" heimdall_url 'https://:bad/api/panels'
expect_reject "endpoint query text refuses before remote commands" heimdall_url 'https://heimdall.example.invalid/api/panels?debug=1'
expect_reject "endpoint duplicate separators refuse before remote commands" heimdall_url 'https://heimdall.example.invalid/api//panels'

set_overlay_field ssh_target 'operator@example-control-node'
set_overlay_field runtime_user operator
set_overlay_field deploy_target "$TMP/release"
set_overlay_field registry_path /srv/example/grimnir/services.json
set_overlay_field heimdall_token_source /etc/brokkr/heimdall-fleet-token.env
set_overlay_field heimdall_url https://heimdall.example.invalid/api/panels

run --overlay "$OVERLAY" --commit "$COMMIT"
check "valid overlay forwards the declared SSH target" '[[ "$RC" -eq 0 && $(grep -Fc "ssh operator@example-control-node" "$CALLS") -ge 2 ]]'
check "valid overlay produces the same deployment environment bindings" 'grep -Eq "BROKKR_RUNTIME_USER=.operator" "$CALLS" && grep -Eq "BROKKR_REGISTRY_PATH=.*/srv/example/grimnir/services.json" "$CALLS"'
check "private locator values are not printed by the wrapper" '[[ "$OUT" != *"heimdall.example.invalid"* && "$OUT" != *"heimdall-fleet-token.env"* ]]'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
