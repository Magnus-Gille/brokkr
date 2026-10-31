#!/usr/bin/env bash
# Hermetic coverage for scripts/provision-agent-account.sh. Every system command is a PATH shim
# that records its argv; no root, network, systemd, nftables or real account is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/bin"
STATE="$TMP/state"
ROOT_DIR="$TMP/root"
CALLS="$TMP/calls"
FIXTURE="$TMP/repo"
KEYS="$TMP/keys"
mkdir -p "$STUBS" "$KEYS"
: >"$CALLS"

# --- fixture repository bound to a commit (deploy-source binding) ------------------------------
mkdir -p "$FIXTURE/scripts/lib"
cp "$SOURCE_REPO/scripts/provision-agent-account.sh" "$SOURCE_REPO/scripts/agent-account-housekeeping.sh" "$SOURCE_REPO/scripts/agent-worktree.sh" "$FIXTURE/scripts/"
cp "$SOURCE_REPO/scripts/lib/deploy-source.sh" "$FIXTURE/scripts/lib/"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" config user.email test@example.invalid
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" add scripts
git -C "$FIXTURE" -c core.hooksPath=/dev/null commit -qm 'fixture agent account provisioner'
HEAD_SHA=$(git -C "$FIXTURE" rev-parse HEAD)

# --- keys --------------------------------------------------------------------------------------
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -C 'operator@laptop.example' -f "$KEYS/agent" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -C 'second@laptop.example' -f "$KEYS/other" >/dev/null
else
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKeyOne operator@laptop.example\n' >"$KEYS/agent.pub"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKeyTwo second@laptop.example\n' >"$KEYS/other.pub"
  cat >"$STUBS/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"$STUB_CALLS"
grep -q garbage "$2" && exit 1
printf '256 SHA256:fixture fixture (ED25519)\n'
EOF
  chmod +x "$STUBS/ssh-keygen"
fi
PUB="$KEYS/agent.pub"
B64=$(awk '{print $2}' "$PUB")
printf '%s\n%s\n' "$(cat "$PUB")" "$(cat "$KEYS/other.pub")" >"$KEYS/two.pub"
printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7fixture rsa@example.test\n' >"$KEYS/rsa.pub"
printf 'ssh-ed25519 AAAAgarbagegarbage broken@example.test\n' >"$KEYS/garbage.pub"
printf 'command="id" %s\n' "$(cat "$PUB")" >"$KEYS/options.pub"
printf '# just a comment\n' >"$KEYS/comment.pub"
: >"$KEYS/empty.pub"
ln -s "$PUB" "$KEYS/link.pub"

# --- command shims -----------------------------------------------------------------------------
stub() { cat >"$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub sudo <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUB_CALLS"
STUB_SUDO=1 exec "$@"
EOF
stub id <<'EOF'
#!/usr/bin/env bash
printf 'id %s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  -u) cat "$STUB_STATE/euid" ;;
  -un) cat "$STUB_STATE/invoker" ;;
  -nG) [[ -f "$STUB_STATE/groups/$2" ]] || exit 1; cat "$STUB_STATE/groups/$2" ;;
  *) echo "id stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
stub getent <<'EOF'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  passwd|group) grep -m1 "^$2:" "$STUB_STATE/$1" || exit 2 ;;
  *) exit 99 ;;
esac
EOF
stub useradd <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'useradd %s\n' "$*" >>"$STUB_CALLS"
[[ ${STUB_FAIL:-} != useradd ]] || exit 9
name=${!#}
uid=${STUB_NEW_UID:-1001}
printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$name" "$uid" "$uid" "$name" >>"$STUB_STATE/passwd"
printf '%s:x:%s:\n' "$name" "$uid" >>"$STUB_STATE/group"
mkdir -p "$STUB_STATE/groups" "$BROKKR_AGENT_ROOT/home/$name"
printf '%s%s\n' "$name" "${STUB_EXTRA_GROUP:+ $STUB_EXTRA_GROUP}" >"$STUB_STATE/groups/$name"
# Like useradd with SUB_UID_COUNT > 0 in login.defs: allocate subordinate ranges unless -K zeroes them.
if [[ " $* " != *' -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 '* || -n ${STUB_USERADD_SUBIDS:-} ]]; then
  mkdir -p "$BROKKR_AGENT_ROOT/etc"
  printf '%s:100000:65536\n' "$name" >>"$BROKKR_AGENT_ROOT/etc/subuid"
  printf '%s:100000:65536\n' "$name" >>"$BROKKR_AGENT_ROOT/etc/subgid"
fi
EOF
stub usermod <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'usermod %s\n' "$*" >>"$STUB_CALLS"
[[ ${STUB_FAIL:-} != usermod ]] || { echo 'usermod stub: cannot lock the account' >&2; exit 1; }
# Model the external command's password-changing arguments against synthetic data only.
if [[ -f "$STUB_STATE/fake-shadow-marker" ]]; then
  for argument in "$@"; do
    case $argument in
      -p*|--password|--password=*|-U*|--unlock)
        printf '%s\n' PASSWORD_FIELD_REPLACED >"$STUB_STATE/fake-shadow-marker"
        break ;;
    esac
  done
fi
EOF
stub passwd <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'passwd %s\n' "$*" >>"$STUB_CALLS"
[[ $1 == -S && $# == 2 ]] || { echo "passwd stub: unexpected: $*" >&2; exit 99; }
count_file="$STUB_STATE/passwd-status-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
[[ ${STUB_PASSWD_FAIL_ON:-} != "$count" ]] || { echo 'passwd stub: status unavailable' >&2; exit 1; }
if [[ $count -eq 2 && ${STUB_EXTERNAL_PASSWORD_CHANGE:-} == 1 ]]; then
  printf '%s\n' LOCKED_CHANGED_EXTERNALLY >"$STUB_STATE/fake-shadow-marker"
fi
var="STUB_PASSWD_OUTPUT_$count"
output=${!var:-${STUB_PASSWD_OUTPUT:-"$2 L 1970-01-01 0 99999 7 -1"}}
printf '%s\n' "$output"
EOF
stub loginctl <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'loginctl %s\n' "$*" >>"$STUB_CALLS"
if [[ $1 == disable-linger && ${STUB_DISABLE_LINGER_FAIL:-} == 1 ]]; then
  echo "Failed to disable linger for user $2: Access denied" >&2; exit 1
fi
if [[ $1 == enable-linger && ${STUB_ENABLE_LINGER_FAIL:-} == 1 ]]; then
  echo "Failed to enable linger for user $2: Access denied" >&2; exit 1
fi
if [[ $1 == terminate-user ]]; then
  case ${STUB_TERMINATE:-ok} in
    notloggedin) echo "Failed to terminate user $2: User ID 1001 is not logged in." >&2; exit 1 ;;
    error) echo "Failed to terminate user $2: Access denied" >&2; exit 1 ;;
  esac
fi
EOF
stub systemctl <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'systemctl %s\n' "$*" >>"$STUB_CALLS"
mark_active() { grep -qx -- "$1" "$STUB_STATE/active" || echo "$1" >>"$STUB_STATE/active"; }
load() { # simulate the egress unit: load its ruleset, then publish the SSH key under /run
  local u=${1#brokkr-agent-egress-} conf="$BROKKR_AGENT_ROOT/etc/brokkr/agent-account"
  u=${u%.service}
  cp "$conf/$u.nft" "$STUB_STATE/loaded.nft"
  if [[ ${STUB_NO_PUBLISH:-} != 1 ]]; then
    mkdir -p "$BROKKR_AGENT_ROOT/run/brokkr-agent-keys"
    cp "$conf/$u.keys" "$BROKKR_AGENT_ROOT/run/brokkr-agent-keys/$u"
  fi
}
bytes() { # 20G -> 21474836480
  local n=${1%?}
  case ${1: -1} in
    K) echo $((n * 1024)) ;;
    M) echo $((n * 1024 * 1024)) ;;
    G) echo $((n * 1024 * 1024 * 1024)) ;;
    T) echo $((n * 1024 * 1024 * 1024 * 1024)) ;;
  esac
}
cgroup() { # slice; Key=Value lines on stdin become the kernel's effective cgroup v2 files
  local dir="$BROKKR_AGENT_ROOT/sys/fs/cgroup/user.slice/$1" key val b wrong=${STUB_CG_WRONG:-}
  [[ $wrong != 1 ]] || wrong=memory.max
  mkdir -p "$dir"
  while IFS='=' read -r key val; do
    case $key in
      MemoryMax) b=$(bytes "$val"); echo $((b - b % 4096)) >"$dir/memory.max" ;;
      MemoryHigh) b=$(bytes "$val"); echo $((b - b % 4096)) >"$dir/memory.high" ;;
      MemorySwapMax) echo "$val" >"$dir/memory.swap.max" ;;
      TasksMax) echo "$val" >"$dir/pids.max" ;;
      CPUQuota) echo "$((${val%\%} * 1000)) 100000" >"$dir/cpu.max" ;;
    esac
  done
  case $wrong in
    '') ;;
    cpu.max) echo 'max 100000' >"$dir/cpu.max" ;;
    *) echo max >"$dir/$wrong" ;;
  esac
}
case "$1" in
  is-active)
    shift; quiet=0
    if [[ ${1:-} == --quiet ]]; then quiet=1; shift; fi
    if grep -qx -- "$1" "$STUB_STATE/active"; then [[ $quiet -eq 1 ]] || echo active; exit 0; fi
    [[ $quiet -eq 1 ]] || echo inactive
    exit 3 ;;
  enable) # enable --now UNIT...: starting an inactive unit runs it, an active one is left alone
    [[ ${STUB_FAIL:-} != enable ]] || exit 1
    for unit in "${@:3}"; do
      if ! grep -qx -- "$unit" "$STUB_STATE/active"; then
        mark_active "$unit"
        [[ $unit != *.timer ]] || continue
        load "$unit"
      fi
    done ;;
  disable) # disable --now UNIT
    unit=${!#}
    grep -vx -- "$unit" "$STUB_STATE/active" >"$STUB_STATE/active.new" || true
    mv "$STUB_STATE/active.new" "$STUB_STATE/active" ;;
  --user) # --user -M NAME@ set-environment K=V...: the running user manager's environment
    [[ $2 == -M && $4 == set-environment ]] || { echo "systemctl stub: unexpected: $*" >&2; exit 99; }
    [[ ${STUB_SET_ENV_FAIL:-} != 1 ]] || { echo 'Failed to connect to bus: No medium found' >&2; exit 1; }
    shift 4
    printf '%s\n' "$@" >"$STUB_STATE/user-manager.env" ;;
  show) # show UNIT -p Key...: systemd's configured slice limits, from the drop-in
    show_unit=$2
    show_conf="$BROKKR_AGENT_ROOT/etc/systemd/system/$show_unit.d/70-brokkr-agent-account.conf"
    [[ -f $show_conf ]] || exit 1
    while IFS='=' read -r key val; do
      case $key in
        MemoryMax|MemoryHigh)
          b=$(bytes "$val")
          if [[ $key == MemoryMax && ${STUB_SHOW_WRONG:-} == 1 ]]; then b=infinity; fi
          echo "$key=$b" ;;
        MemorySwapMax|TasksMax) echo "$key=$val" ;;
      esac
    done <"$show_conf" ;;
  start)
    mark_active "$2"
    case $2 in
      user@*) : ;;
      *.slice)
        if [[ ${STUB_CG_MISSING:-} != 1 ]]; then
          grep '=' "$BROKKR_AGENT_ROOT/etc/systemd/system/$2.d/70-brokkr-agent-account.conf" | cgroup "$2"
        fi ;;
      *) load "$2" ;;
    esac ;;
  set-property) # set-property --runtime SLICE Key=Value...: the kernel limits follow the arguments
    [[ $2 == --runtime ]] || { echo "systemctl stub: unexpected: $*" >&2; exit 99; }
    slice=$3
    shift 3
    if [[ ${STUB_CG_MISSING:-} != 1 ]]; then printf '%s\n' "$@" | cgroup "$slice"; fi ;;
  restart) [[ $2 == *.timer ]] || load "$2" ;;
  reload) # run sshd or the installed egress unit's ExecReload= lines in order
    if [[ $2 == ssh.service ]]; then
      [[ ${STUB_SSH_RELOAD_FAIL:-} != 1 ]] || { echo 'systemctl stub: ssh reload failed' >&2; exit 1; }
      exit 0
    fi
    reload_unit=${2#brokkr-agent-egress-}
    reload_unit=${reload_unit%.service}
    reload_conf="$BROKKR_AGENT_ROOT/etc/brokkr/agent-account"
    while IFS= read -r line; do
      cmd=${line#ExecReload=}
      case $cmd in
        '/usr/bin/rm -f '*) rm -f "$BROKKR_AGENT_ROOT${cmd#/usr/bin/rm -f }" ;;
        '/usr/sbin/nft -f '*)
          [[ ${STUB_RELOAD_NFT_FAIL:-} != 1 ]] || { echo 'systemctl stub: ExecReload nft -f failed' >&2; exit 1; }
          cp "$reload_conf/$reload_unit.nft" "$STUB_STATE/loaded.nft" ;;
        '/usr/bin/install '*)
          if [[ ${STUB_NO_PUBLISH:-} != 1 ]]; then
            mkdir -p "$BROKKR_AGENT_ROOT/run/brokkr-agent-keys"
            cp "$reload_conf/$reload_unit.keys" "$BROKKR_AGENT_ROOT/run/brokkr-agent-keys/$reload_unit"
          fi ;;
        *) echo "systemctl stub: unexpected ExecReload: $cmd" >&2; exit 99 ;;
      esac
    done < <(grep '^ExecReload=' "$BROKKR_AGENT_ROOT/etc/systemd/system/$2") ;;
  daemon-reload|try-reload-or-restart) : ;;
  *) echo "systemctl stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
stub nft <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'nft %s\n' "$*" >>"$STUB_CALLS"
case "$1 $2" in
  '-c -f')
    case $3 in
      */nftables.conf) # the host's main ruleset file, validated after the include was appended
        cp "$3" "$STUB_STATE/nftconf.checked"
        [[ ${STUB_NFTCONF_FAIL:-} != 1 ]] || { echo 'nft stub: Error: nftables.conf rejected' >&2; exit 1; }
        exit 0 ;;
    esac
    [[ ${STUB_NFT_CHECK_FAIL:-} != 1 ]] || { echo 'nft stub: Error: syntax error' >&2; exit 1; }
    grep -q '^table inet brokkr_agent_' "$3" ;;
  'list table') [[ -f "$STUB_STATE/loaded.nft" ]] || exit 1; cat "$STUB_STATE/loaded.nft" ;;
  *) exit 99 ;;
esac
EOF
stub sshd <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'sshd %s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  -t) [[ ${STUB_SSHD_T_FAIL:-} != 1 ]] || { echo 'sshd stub: bad configuration' >&2; exit 255; } ;;
  -T) # effective policy: the agent drop-in's settings, unless an earlier rule overrides it
    # STUB_SSHD_DEFAULT_ADDR=<addr>: an address-specific Match block elsewhere hands only that
    # connection address the default (ungated) policy.
    addr=${3#*addr=}
    addr=${addr%%,*}
    dropin=$(ls "$BROKKR_AGENT_ROOT"/etc/ssh/sshd_config.d/00-brokkr-agent-*.conf 2>/dev/null | head -1)
    if [[ -n $dropin && ${STUB_SSHD_OVERRIDE:-} != 1 && ${STUB_SSHD_DEFAULT_ADDR:-} != "$addr" ]]; then
      sed -n 's/^    \([A-Za-z0-9]*\) \(.*\)$/\1 \2/p' "$dropin" | awk '{ $1 = tolower($1); print }' |
        if [[ ${STUB_SSHD_NO_SETENV:-} == 1 ]]; then grep -v '^setenv ';
        elif [[ ${STUB_SSHD_SETENV_FIRST:-} == 1 ]]; then sed 's/^setenv /setenv TMPDIR=\/tmp /'; else cat; fi
    else
      printf '%s\n' 'authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2' 'passwordauthentication no'
    fi ;;
  *) exit 99 ;;
esac
EOF
stub systemd-run <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'systemd-run %s\n' "$*" >>"$STUB_CALLS"
slice=
while [[ $# -gt 0 && $1 != -- ]]; do
  case $1 in --slice=*) slice=${1#--slice=} ;; esac
  shift
done
shift
# A transient scope realizes an empty slice from its drop-in; an existing cgroup keeps its values.
if [[ -n $slice && ! -d "$BROKKR_AGENT_ROOT/sys/fs/cgroup/user.slice/$slice" ]]; then
  STUB_SUDO=1 systemctl start "$slice"
fi
exec "$@"
EOF
stub systemd-tmpfiles <<'EOF'
#!/usr/bin/env bash
# --create CONF: realise its "d PATH MODE USER GROUP AGE" lines under the root; the effective
# type:owner:group:mode of each path is kept for the stat stub.
[[ -n ${STUB_SUDO:-} ]] || printf 'systemd-tmpfiles %s\n' "$*" >>"$STUB_CALLS"
[[ $1 == --create && -f $2 ]] || { echo "systemd-tmpfiles stub: unexpected: $*" >&2; exit 99; }
[[ ${STUB_TMPFILES_FAIL:-} != 1 ]] || { echo 'systemd-tmpfiles stub: Failed to create directory' >&2; exit 73; }
while read -r type path mode owner group _; do
  [[ $type == d ]] || continue
  full=$BROKKR_AGENT_ROOT$path
  if [[ -L $full ]]; then echo "systemd-tmpfiles stub: $path is a symlink, refusing" >&2; exit 73; fi
  mkdir -p "$full"
  chmod "$mode" "$full"
  [[ -z ${STUB_TMPDIR_OWNER:-} || $owner == root ]] || owner=$STUB_TMPDIR_OWNER
  grep -v "^$full " "$STUB_STATE/stat" >"$STUB_STATE/stat.new" 2>/dev/null || true
  printf '%s directory:%s:%s:%s\n' "$full" "$owner" "$group" "${mode#0}" >>"$STUB_STATE/stat.new"
  mv "$STUB_STATE/stat.new" "$STUB_STATE/stat"
done <"$2"
EOF
stub stat <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'stat %s\n' "$*" >>"$STUB_CALLS"
[[ $1 == -c && $2 == '%F:%U:%G:%a' ]] || { echo "stat stub: unexpected: $*" >&2; exit 99; }
shift 2
for path in "$@"; do
  if [[ -L $path ]]; then echo 'symbolic link:root:root:777'; continue; fi
  line=$(grep -m1 "^$path " "$STUB_STATE/stat" 2>/dev/null) || { echo "stat: cannot stat '$path'" >&2; exit 1; }
  echo "${line#* }"
done
EOF
stub cmp <<'EOF'
#!/usr/bin/env bash
if [[ ${STUB_CMP_ERROR:-} == 1 && ( "$1" == *.timer || "$2" == *.timer || "$1" == *brokkr-agent-housekeeping* || "$2" == *brokkr-agent-housekeeping* ) ]]; then
  echo 'cmp stub: injected comparison error' >&2
  exit 2
fi
exec /usr/bin/cmp "$@"
EOF
stub timeout <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'timeout %s\n' "$*" >>"$STUB_CALLS"
shift
exec "$@"
EOF
stub findmnt <<'EOF'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$STUB_CALLS"
if [[ "$*" == *'-o FSTYPE'* ]]; then
  [[ ${STUB_TMP_FS_FAIL:-} != 1 ]] || exit 1
  printf '%s\n' "${STUB_TMP_FS-ext4}"
else
  echo "${STUB_PROC_OPTS:-rw,nosuid,nodev,noexec,relatime}"
fi
EOF
stub install <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'install %s\n' "$*" >>"$STUB_CALLS"
[[ ${STUB_FAIL:-} != install ]] || exit 1
dir=0 mode='' owner='' group=''
while [[ $# -gt 0 ]]; do
  case $1 in
    -d) dir=1; shift ;;
    -m) mode=$2; shift 2 ;;
    -o) owner=$2; shift 2 ;;
    -g) group=$2; shift 2 ;;
    *) break ;;
  esac
done
if [[ $dir -eq 1 ]]; then
  for d in "$@"; do
    mkdir -p "$d" && chmod "$mode" "$d" || exit 1
    printf '%s %s %s %s\n' "$d" "$mode" "$owner" "$group" >>"$STUB_STATE/meta"
  done
else
  # Like uutils install 0.8 (Ubuntu 26.04): a pipe source cannot replace an existing file.
  if [[ ( $1 == /dev/stdin || $1 == /proc/self/fd/0 ) && -e $2 ]]; then
    echo 'install: No such file or directory' >&2
    exit 1
  fi
  cat "$1" >"$2" && chmod "$mode" "$2" || exit 1
  printf '%s %s %s %s\n' "$2" "$mode" "$owner" "$group" >>"$STUB_STATE/meta"
fi
EOF
# find: the real binary (resolved here, before any stub dir is on PATH) except for the at spool,
# where STUB_ATJOB=1 reports a queued job for the account.
REAL_FIND=$(type -P find)
cat >"$STUBS/find" <<EOF
#!/usr/bin/env bash
if [[ \${STUB_ATJOB:-} == 1 ]]; then
  for arg in "\$@"; do
    if [[ \$arg == "\$BROKKR_AGENT_ROOT/var/spool/cron/atjobs" ]]; then
      echo "\$arg/a0000100abcdef"
      exit 0
    fi
  done
fi
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$STUBS/find"
for tool in chmod mv rm; do
  cat >"$STUBS/$tool" <<EOF
#!/usr/bin/env bash
[[ -n \${STUB_SUDO:-} ]] || printf '%s\n' "$tool \$*" >>"\$STUB_CALLS"
exec "$(command -v "$tool")" "\$@"
EOF
  chmod +x "$STUBS/$tool"
done

# --- harness -----------------------------------------------------------------------------------
PASS=0
FAIL=0
OUT=''
RC=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2
  printf '%s\n' "$OUT" | head -12 | sed 's/^/    | /' >&2
}
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

reset_host() {
  rm -rf "$ROOT_DIR" "$STATE"
  mkdir -p "$ROOT_DIR/etc/ssh/sshd_config.d" "$STATE/groups"
  : >"$STATE/passwd"; : >"$STATE/group"; : >"$STATE/active"; : >"$STATE/meta"
  echo 1000 >"$STATE/euid"
  echo operator >"$STATE/invoker"
  : >"$CALLS"
}

# run [script args...]: NOBIND=1 omits the deploy-source binding; BIND_SHA / BIND_SRC override the
# bound commit / source. Per-test STUB_* variables are set as prefix assignments on this call.
run() {
  local src=${BIND_SRC:-$FIXTURE} sha=${BIND_SHA:-$HEAD_SHA}
  if [[ -n ${NOBIND:-} ]]; then src=''; sha=''; fi
  : >"$CALLS"
  OUT=$(cd "$FIXTURE" && PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" STUB_STATE="$STATE" \
    BROKKR_AGENT_ROOT="$ROOT_DIR" BROKKR_AGENT_SBIN='' \
    BROKKR_EXPECTED_SOURCE="$src" BROKKR_EXPECTED_COMMIT="$sha" \
    bash scripts/provision-agent-account.sh "$@" 2>&1)
  RC=$?
}

out_has() { grep -qF -- "$1" <<<"$OUT"; }
has_call() { grep -qF -- "$1" "$CALLS"; }
no_call() { ! grep -qE -- "$1" "$CALLS"; }
call_line() { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
call_count() { grep -cF -- "$1" "$CALLS"; }
before() { # earlier-call later-call
  local a b
  a=$(call_line "$1"); b=$(call_line "$2")
  [[ -n $a && -n $b && $a -lt $b ]]
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
mode_is() { [[ "$(mode_of "$1")" == "$2" ]]; }
meta_has() { grep -qxF -- "$1" "$STATE/meta"; }
same_content() { printf '%s\n' "$2" | cmp -s - "$1"; }
lacks_re() { ! grep -qE -- "$2" "$1"; }
absent() { [[ ! -e $1 && ! -L $1 ]]; }
rc_is() { [[ $RC -eq $1 ]]; }
files_under_root() { find "$ROOT_DIR" -mindepth 1 | wc -l | tr -d ' '; }
snapshot() { (cd "$ROOT_DIR" && find . -type f | sort | while read -r f; do printf '%s ' "$f"; cksum <"$f"; done); }
out_line() { grep -nF -- "$1" <<<"$OUT" | head -1 | cut -d: -f1; }
out_before() { # earlier-line later-line, within the script output
  local a b
  a=$(out_line "$1"); b=$(out_line "$2")
  [[ -n $a && -n $b && $a -lt $b ]]
}
file_before() { # file earlier-line later-line (first occurrence of each)
  local a b
  a=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1)
  [[ -n $a && -n $b && $a -lt $b ]]
}
last_sudo_is() { [[ "$(grep '^sudo ' "$CALLS" | tail -1)" == "$1" ]]; }
first_sudo_is() { [[ "$(grep -m1 '^sudo ' "$CALLS")" == "$1" ]]; }
cg_is() { [[ "$(cat "$CGDIR/$1" 2>/dev/null)" == "$2" ]]; }
# Only private mktemp staging cleanup is allowed without sudo.
only_via_sudo() { ! grep -E '^(useradd|usermod|passwd|loginctl|nft|install|chmod|mv|rm|systemd-tmpfiles) ' "$CALLS" |
  # Only the provisioner's own mktemp staging cleanup is unprivileged.
  grep -vqE '^rm (-f [^ ]*/brokkr-agent-account\.[A-Za-z0-9]+|-rf [^ ]*/brokkr-agent-housekeeping\.[A-Za-z0-9]+)$' &&
  no_call '^systemctl (daemon-reload|enable|disable|start|restart|reload|try-reload-or-restart|set-property|--user)'; }
staging_cleaned() { ! ls "${TMPDIR:-/tmp}"/brokkr-agent-account.* >/dev/null 2>&1; }
nothing_mutated() {
  only_via_sudo && ! grep '^sudo ' "$CALLS" | grep -qvxF 'sudo passwd -S agent-dev'
}
stays_expired() { no_call 'usermod -p ' && no_call 'usermod --expiredate  ' && no_call 'enable-linger'; }
refused() { # pattern: rc 64, prefixed message, no mutation at all
  [[ $RC -eq 64 ]] && out_has 'brokkr agent account:' && out_has "$1" && nothing_mutated && no_call 'passwd -S'
}
expect_refusal() { # description pattern script-args...
  local desc=$1 pattern=$2
  shift 2
  run "$@"
  check "$desc" refused "$pattern"
}

KEYF="$ROOT_DIR/etc/brokkr/agent-account/agent-dev.keys"
RUNKEY="$ROOT_DIR/run/brokkr-agent-keys/agent-dev"
DROPIN="$ROOT_DIR/etc/ssh/sshd_config.d/00-brokkr-agent-agent-dev.conf"
UMDROP="$ROOT_DIR/etc/systemd/system/user@1001.service.d/70-brokkr-agent-egress.conf"
SLICE="$ROOT_DIR/etc/systemd/system/user-1001.slice.d/70-brokkr-agent-account.conf"
CGDIR="$ROOT_DIR/sys/fs/cgroup/user.slice/user-1001.slice"
NFT="$ROOT_DIR/etc/brokkr/agent-account/agent-dev.nft"
UNIT="$ROOT_DIR/etc/systemd/system/brokkr-agent-egress-agent-dev.service"
MARK="$ROOT_DIR/var/lib/brokkr/agent-account/agent-dev.managed"
HOMEDIR="$ROOT_DIR/home/agent-dev"
CRON_DENY="$ROOT_DIR/etc/cron.deny"
AT_DENY="$ROOT_DIR/etc/at.deny"
T=$'\t'
SSH_FROM='100.64.0.0/10,fd7a:115c:a1e0::/48'
BASE=(--user agent-dev --pubkey "$PUB" --ssh-from "$SSH_FROM")
UNIT_NAME=brokkr-agent-egress-agent-dev.service
SLICE_PROPS='CPUQuota=2000% CPUWeight=20 IOWeight=20 MemoryHigh=20G MemoryMax=24G MemorySwapMax=0 TasksMax=4096'

EXPECT_SLICE=$'[Slice]\nCPUQuota=2000%\nCPUWeight=20\nIOWeight=20\nMemoryHigh=20G\nMemoryMax=24G\nMemorySwapMax=0\nTasksMax=4096'
expected_nft() { # allowlist [exact gateway rule]
  local ports=$1 gateway_rule=${2:-}
  printf '%s\n' '#!/usr/sbin/nft -f' \
    'table inet brokkr_agent_agent_dev' \
    'delete table inet brokkr_agent_agent_dev' \
    'table inet brokkr_agent_agent_dev {' \
    "${T}chain output {" \
    "${T}${T}type filter hook output priority filter; policy accept;" \
    "${T}${T}meta skuid 1001 ct state established,related accept" \
    "${T}${T}meta skuid 1001 fib daddr type local udp dport 53 accept" \
    "${T}${T}meta skuid 1001 fib daddr type local tcp dport 53 accept" \
    "${T}${T}meta skuid 1001 ip daddr 127.0.0.0/8 tcp dport { $ports } accept" \
    "${T}${T}meta skuid 1001 ip6 daddr ::1 tcp dport { $ports } accept"
  if [[ -n $gateway_rule ]]; then printf '%s\n' "${T}${T}meta skuid 1001 $gateway_rule"; fi
  printf '%s\n' \
    "${T}${T}meta skuid 1001 fib daddr type local counter reject" \
    "${T}${T}meta skuid 1001 ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } counter reject" \
    "${T}${T}meta skuid 1001 ip6 daddr { fc00::/7, fe80::/10, ff00::/8 } counter reject" \
    "${T}${T}meta skuid 1001 fib daddr type broadcast counter reject" \
    "${T}}" '}'
}
EXPECT_UNIT=$(printf '%s\n' \
  '[Unit]' \
  'Description=Brokkr egress isolation and SSH key gate for agent account agent-dev' \
  'DefaultDependencies=no' \
  'After=local-fs.target nftables.service' \
  'Before=user@1001.service systemd-user-sessions.service' \
  'PartOf=nftables.service' \
  'ReloadPropagatedFrom=nftables.service' \
  '' '[Service]' \
  'Type=oneshot' \
  'RemainAfterExit=yes' \
  'ExecStart=/usr/sbin/nft -f /etc/brokkr/agent-account/agent-dev.nft' \
  'ExecStartPost=/usr/bin/install -d -m 0755 -o root -g root /run/brokkr-agent-keys' \
  'ExecStartPost=/usr/bin/install -m 0644 -o root -g root /etc/brokkr/agent-account/agent-dev.keys /run/brokkr-agent-keys/agent-dev' \
  '# Reload withdraws the key first and republishes it only after the ruleset loaded.' \
  'ExecReload=/usr/bin/rm -f /run/brokkr-agent-keys/agent-dev' \
  'ExecReload=/usr/sbin/nft -f /etc/brokkr/agent-account/agent-dev.nft' \
  'ExecReload=/usr/bin/install -m 0644 -o root -g root /etc/brokkr/agent-account/agent-dev.keys /run/brokkr-agent-keys/agent-dev' \
  '# Stopping keeps the table (isolation stays) and withdraws the key (no new logins).' \
  'ExecStopPost=/usr/bin/rm -f /run/brokkr-agent-keys/agent-dev' \
  '' '[Install]' \
  'WantedBy=multi-user.target')
AGENT_TMP=/var/lib/brokkr/agent-tmp/agent-dev
AGENT_ENV="TMPDIR=$AGENT_TMP CLAUDE_CODE_TMPDIR=$AGENT_TMP"
EXPECT_UMDROP=$'[Unit]\nRequires=brokkr-agent-egress-agent-dev.service\nAfter=brokkr-agent-egress-agent-dev.service\n\n[Service]\n'"Environment=$AGENT_ENV"
EXPECT_DROPIN=$'Match User agent-dev\n    AuthorizedKeysFile /run/brokkr-agent-keys/%u\n    AuthorizedKeysCommand none\n    AuthorizedPrincipalsFile none\n    AuthorizedPrincipalsCommand none\n    TrustedUserCAKeys none\n    HostbasedAuthentication no\n    AuthenticationMethods publickey\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    PermitUserRC no\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTunnel no\n    GatewayPorts no\n'"    SetEnv $AGENT_ENV"$'\nMatch all'
EXPECT_KEYS="from=\"$SSH_FROM\",no-agent-forwarding,no-X11-forwarding ssh-ed25519 $B64 brokkr-agent-account"

TMPFILES="$ROOT_DIR/etc/tmpfiles.d/brokkr-agent-agent-dev.conf"
HELPER="$ROOT_DIR/usr/local/libexec/brokkr-agent-housekeeping"
SWEEP_SVC="$ROOT_DIR/etc/systemd/system/brokkr-agent-tmp-sweep-agent-dev.service"
SWEEP_TMR="$ROOT_DIR/etc/systemd/system/brokkr-agent-tmp-sweep-agent-dev.timer"
REAPER_SVC="$ROOT_DIR/etc/systemd/system/brokkr-agent-session-reaper-agent-dev.service"
REAPER_TMR="$ROOT_DIR/etc/systemd/system/brokkr-agent-session-reaper-agent-dev.timer"
SET_ENV_CALL="sudo timeout 30 systemctl --user -M agent-dev@ set-environment TMPDIR=$AGENT_TMP CLAUDE_CODE_TMPDIR=$AGENT_TMP"
EXPECT_TMPFILES=$(printf '%s\n' \
  '# Disk-backed temporary directory (TMPDIR) of agent account agent-dev; entries untouched for 7d are removed.' \
  'd /var/lib/brokkr/agent-tmp 0755 root root -' \
  'd /var/lib/brokkr/agent-tmp/agent-dev 0700 agent-dev agent-dev 7d')
expected_sweep_service() { # max-age max-age-minutes
  printf '%s\n' '[Unit]' \
    "Description=Brokkr: remove files agent account agent-dev left in /tmp untouched for $1" \
    '' '[Service]' 'Type=oneshot' \
    '# As the account itself (unprivileged), in system.slice so a throttled user-1001.slice cannot stall it.' \
    'User=agent-dev' 'Group=agent-dev' \
    "ExecStart=/usr/local/libexec/brokkr-agent-housekeeping sweep-tmp --user agent-dev --dir /tmp --max-age-minutes $2" \
    'Nice=10' 'IOSchedulingClass=idle' 'NoNewPrivileges=yes' 'PrivateNetwork=yes' \
    'ProtectSystem=strict' 'ProtectHome=yes' 'ReadWritePaths=/tmp'
}
EXPECT_SWEEP_TMR=$(printf '%s\n' '[Unit]' 'Description=Hourly sweep of /tmp files left by agent account agent-dev' \
  '' '[Timer]' 'OnBootSec=15min' 'OnUnitActiveSec=1h' '' '[Install]' 'WantedBy=timers.target')
expected_reaper_service() { # grace grace-seconds
  printf '%s\n' '[Unit]' \
    "Description=Brokkr: end sessions of agent account agent-dev left closing for $1" \
    'After=systemd-logind.service' \
    '' '[Service]' 'Type=oneshot' \
    "ExecStart=/usr/local/libexec/brokkr-agent-housekeeping reap-closing --user agent-dev --uid 1001 --grace-seconds $2 --state-dir /run/brokkr-agent-sessions/agent-dev" \
    'RuntimeDirectory=brokkr-agent-sessions/agent-dev' 'RuntimeDirectoryMode=0700' 'RuntimeDirectoryPreserve=yes' \
    'NoNewPrivileges=yes' 'PrivateNetwork=yes' 'ProtectSystem=strict' 'ProtectHome=yes'
}
EXPECT_REAPER_TMR=$(printf '%s\n' '[Unit]' 'Description=Ten-minute check for closing sessions of agent account agent-dev' \
  '' '[Timer]' 'OnBootSec=10min' 'OnUnitActiveSec=10min' '' '[Install]' 'WantedBy=timers.target')

seed_user() { # name uid groups [marker-uid]
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$2" "$2" "$1" >>"$STATE/passwd"
  printf '%s\n' "$3" >"$STATE/groups/$1"
  mkdir -p "$ROOT_DIR/home/$1"
  if [[ -n ${4:-} ]]; then
    mkdir -p "$ROOT_DIR/var/lib/brokkr/agent-account"
    printf '%s\n' "$4" >"$ROOT_DIR/var/lib/brokkr/agent-account/$1.managed"
  fi
}

seed_preserve_user() {
  seed_user agent-dev 1500 agent-dev 1500
  # Synthetic non-secret sentinels: the provisioner must never inspect or alter password material.
  printf 'LOCKED_MARKER_A\nLOCKED_MARKER_B\n' >"$STATE/fake-shadow-marker"
}

preserve_marker_unchanged() { same_content "$STATE/fake-shadow-marker" $'LOCKED_MARKER_A\nLOCKED_MARKER_B'; }
preserve_usermod_only() {
  ! grep '^sudo usermod ' "$CALLS" |
    grep -vxF -e 'sudo usermod --expiredate 1 agent-dev' -e 'sudo usermod --expiredate  agent-dev' |
    grep -q .
}
status_reads() { [[ "$(call_count 'sudo passwd -S agent-dev')" == "$1" ]]; }
status_precedes_lockdown() { before 'sudo passwd -S agent-dev' 'sudo usermod --expiredate 1 agent-dev'; }
last_status_precedes_linger() {
  local status linger
  status=$(grep -nF 'sudo passwd -S agent-dev' "$CALLS" | tail -1 | cut -d: -f1)
  linger=$(call_line 'sudo loginctl enable-linger agent-dev')
  [[ -n $status && -n $linger && $status -lt $linger ]]
}
status_immediately_precedes_linger() {
  local status next
  status=$(grep -nF 'sudo passwd -S agent-dev' "$CALLS" | tail -1 | cut -d: -f1)
  next=$(sed -n "$((status + 1))p" "$CALLS")
  [[ -n $status && $next == 'sudo loginctl enable-linger agent-dev' ]]
}
preserve_dryrun_readonly() { nothing_mutated && preserve_marker_unchanged; }
fresh_refused_early() { [[ $RC -eq 64 ]] && nothing_mutated && no_call 'passwd -S'; }
uid_refused_early() { [[ $RC -eq 64 ]] && nothing_mutated && no_call 'passwd -S'; }
invalid_status_refused() { [[ $RC -eq 64 ]] && out_has 'locked password status'; }
invalid_status_stops_enable() { no_call 'loginctl enable-linger|usermod --expiredate  '; }
failed_status_refused() { [[ $RC -eq 64 ]] && out_has 'locked password status'; }
late_status_aborts_before_enable() {
  local status expired
  status=$(grep -nF 'sudo passwd -S agent-dev' "$CALLS" | tail -1 | cut -d: -f1)
  expired=$(call_line 'sudo usermod --expiredate 1 agent-dev')
  [[ -n $expired && -n $status && $expired -lt $status ]] &&
    no_call 'loginctl enable-linger|usermod --expiredate  '
}

echo provision-agent-account.test.sh

# 0. preserve an existing locked password only under an explicit, verified contract ----------------
reset_host
seed_preserve_user
run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'preserve mode accepts an existing managed account with locked password status' rc_is 0
check 'preserve mode verifies the account status before its first lockdown mutation' status_precedes_lockdown
check 'preserve mode checks locked status before linger and account enable' last_status_precedes_linger
check 'preserve mode rechecks status immediately before linger' status_immediately_precedes_linger
check 'preserve mode checks status initially and again immediately before linger' status_reads 2
check 'preserve mode clears expiry exactly once before starting the user manager' test "$(call_count 'sudo usermod --expiredate  agent-dev')" = 1
check 'preserve mode enables the account before the user manager' before 'sudo usermod --expiredate  agent-dev' 'sudo systemctl start user@1500.service'
check 'preserve mode never sets, unlocks or replaces a password' preserve_usermod_only
check 'preserve mode leaves synthetic locked markers unchanged' preserve_marker_unchanged
reset_host
seed_preserve_user
STUB_EXTERNAL_PASSWORD_CHANGE=1 run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'preserve mode succeeds without restoring a stale synthetic password preimage' rc_is 0
check 'preserve mode preserves an external synthetic password-field update' same_content "$STATE/fake-shadow-marker" LOCKED_CHANGED_EXTERNALLY
reset_host
seed_preserve_user
run --apply "${BASE[@]}"
check 'default existing-account mode still succeeds without password-status probing' rc_is 0
check 'default existing-account mode does not call passwd' no_call 'passwd -S'
check 'default existing-account mode keeps its original password-setting behavior' has_call 'sudo usermod -p * --expiredate  agent-dev'
reset_host
seed_preserve_user
run --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'preserve mode dry-run accepts locked existing account' rc_is 0
check 'preserve mode dry-run reads status once without mutation' status_reads 1
check 'preserve mode dry-run plans expiry clear without password replacement' out_has "would run: sudo usermod --expiredate '' agent-dev"
check 'preserve mode dry-run leaves the account and marker untouched' preserve_dryrun_readonly
reset_host
run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'preserve mode refuses a fresh account' rc_is 64
check 'fresh-account refusal names the existing-managed-account requirement' out_has 'requires an existing managed account'
check 'fresh-account refusal reads no password status and mutates nothing' fresh_refused_early
reset_host
seed_preserve_user
run --apply --preserve-existing-locked-password 1501 "${BASE[@]}"
check 'preserve mode refuses a mismatched expected uid' rc_is 64
check 'uid mismatch is named' out_has 'does not match'
check 'uid mismatch does not read status or mutate' uid_refused_early
for invalid_uid in 0 01500 +1500 1500x; do
  reset_host
  seed_preserve_user
  run --apply --preserve-existing-locked-password "$invalid_uid" "${BASE[@]}"
  check "preserve mode refuses non-canonical uid '$invalid_uid' before status or mutation" uid_refused_early
done
expect_refusal 'preserve mode rejects a missing uid value' 'requires a value' --preserve-existing-locked-password "${BASE[@]}"
expect_refusal 'preserve mode rejects a repeated option' 'may be specified only once' --preserve-existing-locked-password 1500 --preserve-existing-locked-password 1500 "${BASE[@]}"
expect_refusal 'revoke rejects preserve mode' '--revoke accepts only' --revoke --user agent-dev --preserve-existing-locked-password 1500
for status_output in \
  'agent-dev P 1970-01-01 0 99999 7 -1' \
  'agent-dev NP 1970-01-01 0 99999 7 -1' \
  'agent-dev X 1970-01-01 0 99999 7 -1' \
  'agent-dev L' \
  'other L 1970-01-01 0 99999 7 -1' \
  $'agent-dev L 1970-01-01 0 99999 7 -1\nagent-dev L 1970-01-01 0 99999 7 -1'; do
  reset_host
  seed_preserve_user
  STUB_PASSWD_OUTPUT="$status_output" run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
  check 'non-locked or malformed password status refuses preserve mode' invalid_status_refused
  check 'invalid status does not proceed to linger or expiry clear' invalid_status_stops_enable
done
reset_host
seed_preserve_user
STUB_PASSWD_FAIL_ON=1 run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'failed initial status refuses preserve mode' failed_status_refused
check 'failed initial status mutates nothing' nothing_mutated
reset_host
seed_preserve_user
STUB_PASSWD_OUTPUT_2='agent-dev P 1970-01-01 0 99999 7 -1' run --apply --preserve-existing-locked-password 1500 "${BASE[@]}"
check 'late password-status change aborts preserve mode' rc_is 1
check 'late status failure says account stays expired' out_has 'account stays expired'
check 'late status failure follows lockdown but precedes linger and expiry clear' late_status_aborts_before_enable
check 'late status failure leaves synthetic locked markers unchanged' preserve_marker_unchanged

# 1. dry-run -------------------------------------------------------------------------------------
reset_host
NOBIND=1 run "${BASE[@]}"
check 'dry-run succeeds without a deploy-source binding' rc_is 0
check 'dry-run says nothing is changed' out_has 'DRY-RUN'
check 'dry-run creates the account expired' out_has 'would run: sudo useradd --create-home --home-dir /home/agent-dev --shell /bin/bash --user-group --expiredate 1 -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent-dev'
check 'dry-run plans the home mode' out_has "would run: sudo chmod 0700 $HOMEDIR"
check 'dry-run renders the slice drop-in' out_has 'MemoryMax=24G'
check 'dry-run plans the cgroup readback' out_has 'via a transient root scope in the slice, memory.max, memory.high, memory.swap.max, pids.max and cpu.max'
check 'dry-run renders the nft table with a uid placeholder' out_has 'meta skuid <uid> ip daddr 127.0.0.0/8 tcp dport { 1420, 4173, 5173, 32768-60999 } accept'
check 'dry-run renders the root-owned key file path' out_has "--- would write $KEYF (mode 0644, owner root:root) ---"
check 'dry-run renders the restricted key line' out_has "$EXPECT_KEYS"
check 'dry-run renders the egress unit key publication' out_has 'ExecStartPost=/usr/bin/install -m 0644 -o root -g root /etc/brokkr/agent-account/agent-dev.keys /run/brokkr-agent-keys/agent-dev'
check 'dry-run renders the user manager drop-in' out_has 'Requires=brokkr-agent-egress-agent-dev.service'
check 'dry-run renders the sshd drop-in key location' out_has 'AuthorizedKeysFile /run/brokkr-agent-keys/%u'
check 'dry-run plans the key publication check' out_has 'and that /run/brokkr-agent-keys/agent-dev matches'
check 'dry-run plans the cron and at policy' out_has 'would refuse if agent-dev is in cron.allow/at.allow or already has a crontab or queued at jobs'
check 'dry-run plans the late account enable' out_has "would run: sudo usermod -p '*' --expiredate '' agent-dev"
check 'dry-run plans linger before the account enable' out_before 'would run: sudo loginctl enable-linger agent-dev' "would run: sudo usermod -p '*' --expiredate '' agent-dev"
check 'dry-run plans the effective sshd policy check for loopback and every range' out_has "'sudo sshd -T -C user=agent-dev,addr=...' for 127.0.0.1 and every --ssh-from range"
check 'dry-run plans the nftables.conf include' out_has "would ensure $ROOT_DIR/etc/nftables.conf (if present) contains: include \"/etc/brokkr/agent-account/*.nft\""
check 'dry-run renders the drop-in under the 00- name' out_has "--- would write $DROPIN (mode 0644, owner root:root) ---"
check 'dry-run renders the sshd drop-in key command lockout' out_has '    AuthorizedKeysCommand none'
check 'dry-run renders the reload key withdrawal' out_has 'ExecReload=/usr/bin/rm -f /run/brokkr-agent-keys/agent-dev'
check 'dry-run notes the missing hidepid mount' out_has 'without hidepid'
check 'dry-run renders the disk-backed tmp directory' out_has 'd /var/lib/brokkr/agent-tmp/agent-dev 0700 agent-dev agent-dev 7d'
check 'dry-run plans creating it with systemd-tmpfiles' out_has "would run: sudo systemd-tmpfiles --create $TMPFILES"
check 'dry-run renders the sshd SetEnv' out_has "    SetEnv $AGENT_ENV"
check 'dry-run renders the user manager environment' out_has "Environment=$AGENT_ENV"
check 'dry-run renders the tmp sweep' out_has 'sweep-tmp --user agent-dev --dir /tmp --max-age-minutes 1440'
check 'dry-run leaves closing sessions alone by default' out_has 'closing sessions of agent-dev are never ended automatically'
check 'dry-run renders no reaper unit by default' test "$(out_has 'reap-closing --user agent-dev' && echo yes)" != yes
check 'dry-run plans only the sweep timer by default' out_has 'would run: sudo systemctl enable --now brokkr-agent-tmp-sweep-agent-dev.timer'
check 'dry-run plans the running user manager environment' out_has "would run: sudo timeout 30 systemctl --user -M agent-dev@ set-environment $AGENT_ENV"
check 'dry-run writes nothing under the root' test "$(find "$ROOT_DIR" -type f | wc -l | tr -d ' ')" = 0
check 'dry-run runs no mutating command' nothing_mutated
STUB_PROC_OPTS=rw,relatime,hidepid=2 run "${BASE[@]}"
check 'dry-run recognises hidepid' out_has 'mounted with hidepid'
run --help
check '--help exits 0 with usage' out_has 'Usage:'

rm -rf "$ROOT_DIR/etc/ssh/sshd_config.d"
expect_refusal 'refuses a host without sshd_config.d before any mutation' 'sshd_config.d is missing' --apply "${BASE[@]}"
expect_refusal 'refuses a host without sshd_config.d in a dry-run too' 'sshd_config.d is missing' "${BASE[@]}"
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$ROOT_DIR/etc/ssh/sshd_config.d"
expect_refusal 'refuses a symlinked sshd_config.d' 'sshd_config.d is missing' --apply "${BASE[@]}"
rm -f "$ROOT_DIR/etc/ssh/sshd_config.d"
rm -rf "$TMP/elsewhere"
mkdir -p "$ROOT_DIR/etc/ssh/sshd_config.d"

# 2. apply on a fresh host -----------------------------------------------------------------------
reset_host
run --apply "${BASE[@]}"
check 'apply on a fresh host succeeds' rc_is 0
# account lifecycle: created expired, enabled once, at the very end
check 'useradd creates the account already expired' first_sudo_is 'sudo useradd --create-home --home-dir /home/agent-dev --shell /bin/bash --user-group --expiredate 1 -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent-dev'
check 'a fresh account needs no separate expiry call' no_call 'usermod --expiredate 1'
check 'the account is enabled exactly once' test "$(call_count 'usermod -p')" = 1
check 'the account is enabled with an unusable password and no expiry' has_call 'sudo usermod -p * --expiredate  agent-dev'
check 'the user manager gets the agent environment as the last privileged call' last_sudo_is "$SET_ENV_CALL"
check 'the user manager is started before its environment is set' before 'sudo systemctl start user@1001.service' "$SET_ENV_CALL"
check 'the user manager starts only after the account is enabled' before 'sudo usermod -p' 'sudo systemctl start user@1001.service'
check 'a fresh account has no sessions to terminate' no_call 'terminate-user'
check 'a fresh host without nftables.conf is noted' out_has "no $ROOT_DIR/etc/nftables.conf on this host"
check 'a fresh host without nftables.conf gets none created' absent "$ROOT_DIR/etc/nftables.conf"
check 'a fresh host without nftables.conf validates none' no_call 'nft -c -f .*nftables.conf'
check 'a fresh host without an at spool runs no find' no_call '^sudo find([[:space:]]|$)'
check 'home is 0700' mode_is "$HOMEDIR" 700
check 'home is chmodded 0700 through sudo' has_call "sudo chmod 0700 $HOMEDIR"
check 'the home chmod precedes the account being enabled' before "sudo chmod 0700 $HOMEDIR" 'sudo usermod -p'
check 'managed marker holds the uid' same_content "$MARK" 1001
check 'managed marker is 0644 root' meta_has "$MARK 0644 root root"
check 'useradd precedes the egress unit' before 'sudo useradd' "sudo systemctl enable --now $UNIT_NAME"
# resource slice and cgroup readback
check 'slice drop-in is exact' same_content "$SLICE" "$EXPECT_SLICE"
check 'slice drop-in is 0644 root' meta_has "$SLICE 0644 root root"
check 'the kernel limits are read through a transient scope in the slice' has_call 'sudo systemd-run --quiet --collect --scope --slice=user-1001.slice'
check 'the configured slice limits are read from systemd' has_call 'systemctl show user-1001.slice -p MemoryMax -p MemoryHigh -p MemorySwapMax -p TasksMax'
check 'the slice itself is never started directly' no_call 'systemctl start user-1001.slice'
check 'an inactive slice gets no runtime set-property' no_call 'set-property'
check 'the slice drop-in is loaded before the readback' before 'sudo systemctl daemon-reload' 'sudo systemd-run --quiet --collect --scope --slice=user-1001.slice'
check 'cgroup memory.max is read back as 24G' cg_is memory.max 25769803776
check 'cgroup memory.high is read back as 20G' cg_is memory.high 21474836480
check 'cgroup memory.swap.max is read back as 0' cg_is memory.swap.max 0
check 'cgroup pids.max is read back as 4096' cg_is pids.max 4096
check 'cgroup cpu.max is read back as 2000%' cg_is cpu.max '2000000 100000'
check 'the cgroup readback is reported as passed' out_has 'ok: effective limits'
check 'the slice limits are verified before the account is enabled' before 'sudo systemd-run --quiet --collect --scope --slice=user-1001.slice' 'sudo usermod -p'
check 'the slice limits are verified before any SSH key exists' before 'sudo systemd-run --quiet --collect --scope --slice=user-1001.slice' "sudo systemctl enable --now $UNIT_NAME"
# egress isolation
check 'nft ruleset is exact' same_content "$NFT" "$(expected_nft '1420, 4173, 5173, 32768-60999')"
check 'nft ruleset is staged then validated root-owned' meta_has "$NFT.new 0644 root root"
check 'nft ruleset is 0644' mode_is "$NFT" 644
check 'no staged ruleset is left behind' absent "$NFT.new"
check 'the loaded ruleset is the validated one' same_content "$STATE/loaded.nft" "$(expected_nft '1420, 4173, 5173, 32768-60999')"
check 'egress unit is exact' same_content "$UNIT" "$EXPECT_UNIT"
check 'egress unit is 0644 root' meta_has "$UNIT 0644 root root"
check 'the egress unit has no ExecStop, so stopping keeps the table' lacks_re "$UNIT" '^ExecStop='
check 'the egress unit never deletes the table' lacks_re "$UNIT" 'delete table'
check 'user manager drop-in is exact' same_content "$UMDROP" "$EXPECT_UMDROP"
check 'user manager drop-in is 0644 root' meta_has "$UMDROP 0644 root root"
check 'user manager drop-in directory is root-owned' meta_has "$ROOT_DIR/etc/systemd/system/user@1001.service.d 0755 root root"
check 'the user manager drop-in is in place before the unit starts' before " $UMDROP" "sudo systemctl enable --now $UNIT_NAME"
check 'the egress unit is enabled and started' has_call "sudo systemctl enable --now $UNIT_NAME"
check 'a first install does not restart or reload the egress unit' no_call "sudo systemctl (restart|reload) $UNIT_NAME"
check 'nft -c precedes enable --now' before 'sudo nft -c -f' "sudo systemctl enable --now $UNIT_NAME"
check 'enable --now precedes the table readback' before "sudo systemctl enable --now $UNIT_NAME" 'sudo nft list table inet brokkr_agent_agent_dev'
check 'nft -c precedes linger' before 'sudo nft -c -f' 'sudo loginctl enable-linger'
# SSH key gate
check 'persistent key file is exactly one restricted key line' same_content "$KEYF" "$EXPECT_KEYS"
check 'persistent key file is 0644 owned by root' meta_has "$KEYF 0644 root root"
check 'persistent key file mode on disk is 644' mode_is "$KEYF" 644
check 'the config directory is root-owned' meta_has "$ROOT_DIR/etc/brokkr/agent-account 0755 root root"
check 'the key file is written before the egress unit starts' before " $KEYF" "sudo systemctl enable --now $UNIT_NAME"
check 'the egress unit published the key under /run' same_content "$RUNKEY" "$EXPECT_KEYS"
check 'the published key is identical to the persistent key' cmp -s "$KEYF" "$RUNKEY"
check 'the script verifies the published key against the persistent key' has_call "sudo cmp -s $KEYF $RUNKEY"
check 'the key verification follows the table readback' before 'sudo nft list table inet brokkr_agent_agent_dev' 'sudo cmp -s'
check 'the key verification precedes the account being enabled' before 'sudo cmp -s' 'sudo usermod -p'
check 'nothing is written under the agent home at all' test "$(find "$HOMEDIR" -mindepth 1 | wc -l | tr -d ' ')" = 0
check 'nothing is written under the agent home .ssh' absent "$HOMEDIR/.ssh"
check 'no command touches the agent home .ssh' no_call 'home/agent-dev/\.ssh'
# sshd policy
check 'the sshd drop-in is exact' same_content "$DROPIN" "$EXPECT_DROPIN"
check 'the sshd drop-in serves the key from /run' grep -qxF '    AuthorizedKeysFile /run/brokkr-agent-keys/%u' "$DROPIN"
check 'the sshd drop-in is staged root-owned 0644' meta_has "$DROPIN.new 0644 root root"
check 'no staged sshd drop-in is left behind' absent "$DROPIN.new"
check 'sshd -t validates the configuration' has_call 'sudo sshd -t'
check 'the egress unit reloads by withdrawing the key, then the ruleset, then the key' file_before "$UNIT" 'ExecReload=/usr/bin/rm -f /run/brokkr-agent-keys/agent-dev' 'ExecReload=/usr/sbin/nft -f '
check 'the egress unit republishes only after the ruleset reload' file_before "$UNIT" 'ExecReload=/usr/sbin/nft -f ' 'ExecReload=/usr/bin/install '
check 'sshd -T checks the effective policy from loopback' has_call 'sudo sshd -T -C user=agent-dev,host=127.0.0.1,addr=127.0.0.1,lport=22'
check 'sshd -T checks the effective policy from the IPv4 --ssh-from range' has_call 'sudo sshd -T -C user=agent-dev,host=100.64.0.0,addr=100.64.0.0,lport=22'
check 'sshd -T checks the effective policy from the IPv6 --ssh-from range' has_call 'sudo sshd -T -C user=agent-dev,host=fd7a:115c:a1e0::,addr=fd7a:115c:a1e0::,lport=22'
check 'sshd -T runs exactly once per context' test "$(call_count 'sudo sshd -T')" = 3
check 'the sshd drop-in sorts first so later Match blocks cannot override it' test "$(basename "$DROPIN")" = 00-brokkr-agent-agent-dev.conf
for setting in AuthorizedKeysCommand AuthorizedPrincipalsFile AuthorizedPrincipalsCommand TrustedUserCAKeys; do
  check "the sshd drop-in sets $setting to none" grep -qxF "    $setting none" "$DROPIN"
done
check 'the sshd drop-in disables host-based authentication' grep -qxF '    HostbasedAuthentication no' "$DROPIN"
check 'sshd is reloaded only after the policy check' before 'sudo sshd -T' 'sudo systemctl reload ssh.service'
check 'the account is enabled only after the sshd reload' before 'sudo systemctl reload ssh.service' 'sudo usermod -p'
check 'linger is enabled' has_call 'sudo loginctl enable-linger agent-dev'
check 'linger precedes the account enable' before 'sudo loginctl enable-linger' 'sudo usermod -p'
check 'linger follows the sshd reload' before 'sudo systemctl reload ssh.service' 'sudo loginctl enable-linger'
# cron and at
check 'the account is denied cron' same_content "$CRON_DENY" 'agent-dev'
check 'the account is denied at' same_content "$AT_DENY" 'agent-dev'
check 'cron is denied before the account is enabled' before "sudo tee -a $CRON_DENY" 'sudo usermod -p'
check 'at is denied before the account is enabled' before "sudo tee -a $AT_DENY" 'sudo usermod -p'
check 'every mutation went through sudo' only_via_sudo
check 'put_file stages through a private file, not /dev/stdin' no_call 'install .* /dev/stdin '
check 'put_file leaves no staging file behind' staging_cleaned
check 'output points at the docs' out_has 'docs/agent-account.md'

# disk-backed TMPDIR and housekeeping
check 'tmpfiles.d entry is exact' same_content "$TMPFILES" "$EXPECT_TMPFILES"
check 'tmpfiles.d entry is 0644 root' meta_has "$TMPFILES 0644 root root"
check 'the tmp directory is created through systemd-tmpfiles' has_call "sudo systemd-tmpfiles --create $TMPFILES"
check 'the tmp directory exists on disk under the root' test -d "$ROOT_DIR$AGENT_TMP"
check 'the tmp directory ownership and mode are read back' has_call "sudo stat -c %F:%U:%G:%a $ROOT_DIR/var/lib/brokkr/agent-tmp $ROOT_DIR$AGENT_TMP"
check 'the tmp directory readback is reported' out_has "ok: $AGENT_TMP is a directory owned by agent-dev with mode 700"
check 'the tmp directory exists before sshd hands it out' before 'sudo systemd-tmpfiles --create' 'sudo systemctl reload ssh.service'
check 'the tmp directory is verified before the account is enabled' before 'sudo stat -c' 'sudo usermod -p'
check 'the housekeeping helper is the repository script' cmp -s "$HELPER" "$SOURCE_REPO/scripts/agent-account-housekeeping.sh"
WORKTREE_HELPER="$ROOT_DIR/usr/local/bin/brokkr-agent-worktree"
check 'the worktree helper is the repository script' cmp -s "$WORKTREE_HELPER" "$SOURCE_REPO/scripts/agent-worktree.sh"
check 'the worktree helper is installed with root ownership and executable mode' meta_has "$WORKTREE_HELPER 0755 root root"
check 'the housekeeping helper is 0755 root' meta_has "$HELPER 0755 root root"
check 'the tmp sweep service is exact' same_content "$SWEEP_SVC" "$(expected_sweep_service 1d 1440)"
check 'the tmp sweep timer is exact' same_content "$SWEEP_TMR" "$EXPECT_SWEEP_TMR"
check 'the tmp sweep never runs in the agent slice' lacks_re "$SWEEP_SVC" '^Slice='
check 'the tmp sweep sees the real /tmp' lacks_re "$SWEEP_SVC" '^PrivateTmp='
check 'the closing-session reaper is opt-in: none by default' absent "$REAPER_SVC"
check 'no reaper unit is touched by default' no_call 'session-reaper'
for unit_file in "$SWEEP_SVC" "$SWEEP_TMR"; do
  check "${unit_file##*/} is 0644 root" meta_has "$unit_file 0644 root root"
done
check 'the sweep timer is enabled and started' has_call 'sudo systemctl enable --now brokkr-agent-tmp-sweep-agent-dev.timer'
check 'an inactive sweep timer is not redundantly restarted' no_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'the inactive sweep timer is enabled before later provisioning' before 'sudo systemctl enable --now brokkr-agent-tmp-sweep' 'sudo systemctl reload ssh.service'
check 'an inactive tmpfiles clean timer is reported' out_has 'warning: systemd-tmpfiles-clean.timer is not active'
check 'the running user manager gets the agent environment' same_content "$STATE/user-manager.env" "$(printf '%s\n' "TMPDIR=$AGENT_TMP" "CLAUDE_CODE_TMPDIR=$AGENT_TMP")"

# 3. idempotent re-run ---------------------------------------------------------------------------
SNAP1=$(snapshot)
run --apply "${BASE[@]}"
check 're-run succeeds' rc_is 0
check 're-run creates no second account' test "$(call_count 'useradd')" = 0
check 're-run expires the account before anything else' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 're-run converges on identical files' test "$SNAP1" = "$(snapshot)"
check 're-run keeps a single key line' test "$(wc -l <"$KEYF" | tr -d ' ')" = 1
check 're-run lists the account in cron.deny once' test "$(grep -cx agent-dev "$CRON_DENY")" = 1
check 're-run lists the account in at.deny once' test "$(grep -cx agent-dev "$AT_DENY")" = 1
check 're-run chmods the home again' has_call "sudo chmod 0700 $HOMEDIR"
check 're-run re-enables the account' has_call 'sudo usermod -p * --expiredate  agent-dev'
check 're-run enables the account only after the expiry' before 'sudo usermod --expiredate 1 agent-dev' 'sudo usermod -p'
check 're-run reloads the active egress unit atomically' has_call "sudo systemctl reload $UNIT_NAME"
check 're-run never restarts the egress unit' no_call "sudo systemctl restart $UNIT_NAME"
check 're-run republishes the key' same_content "$RUNKEY" "$EXPECT_KEYS"
check 're-run applies runtime properties to the active slice' has_call "sudo systemctl set-property --runtime user-1001.slice $SLICE_PROPS"
check 're-run does not start the active slice' no_call 'sudo systemctl start user-1001.slice'
check 're-run reloads sshd after the policy check' before 'sudo sshd -T' 'sudo systemctl reload ssh.service'
check 're-run goes through sudo only' only_via_sudo
check 're-run can replace existing files (uutils install)' rc_is 0
check 're-run leaves no staging file behind' staging_cleaned
check 're-run with the egress table loaded ends no sessions' no_call 'terminate-user'
check 're-run looks for the egress table after the initial expiry' before 'sudo usermod --expiredate 1 agent-dev' 'sudo nft list table inet brokkr_agent_agent_dev'
check 're-run sets the running user manager environment as its last privileged call' last_sudo_is "$SET_ENV_CALL"
check 're-run enables the account before starting the user manager' before 'sudo usermod -p' 'sudo systemctl start user@1001.service'
check 're-run enables linger before the account' before 'sudo loginctl enable-linger' 'sudo usermod -p'
check 're-run checks the sshd policy from loopback and both ranges' test "$(call_count 'sudo sshd -T')" = 3
check 're-run keeps the reload-withdrawn key republished' same_content "$RUNKEY" "$EXPECT_KEYS"
STUB_FAIL=usermod run --apply "${BASE[@]}"
check 'a failing initial expiry aborts the re-run' rc_is 1
check 'a failing initial expiry changes nothing else' test "$(grep -c '^sudo ' "$CALLS")" = 1
run --apply "${BASE[@]}" --cpu-quota 400% --memory-high 6G --memory-max 8G --tasks-max 1024 --allow-local-tcp '3000,40000-40100'
check 'changed limits re-run succeeds' rc_is 0
check 'slice drop-in follows the new limits' same_content "$SLICE" $'[Slice]\nCPUQuota=400%\nCPUWeight=20\nIOWeight=20\nMemoryHigh=6G\nMemoryMax=8G\nMemorySwapMax=0\nTasksMax=1024'
check 'the new limits reach the kernel' has_call 'sudo systemctl set-property --runtime user-1001.slice CPUQuota=400% CPUWeight=20 IOWeight=20 MemoryHigh=6G MemoryMax=8G MemorySwapMax=0 TasksMax=1024'
check 'the new memory.max is read back' cg_is memory.max 8589934592
check 'the new memory.high is read back' cg_is memory.high 6442450944
check 'the new pids.max is read back' cg_is pids.max 1024
check 'the new cpu.max is read back' cg_is cpu.max '400000 100000'
check 'nft ruleset follows the new allowlist' same_content "$NFT" "$(expected_nft '3000, 40000-40100')"
check 'reload loaded the changed ruleset' same_content "$STATE/loaded.nft" "$(expected_nft '3000, 40000-40100')"
run --apply "${BASE[@]}" --allow-local-tcp '0080,443-443'
check 'ports are rendered as normalised decimals' same_content "$NFT" "$(expected_nft '80, 443')"

# Optional inference access is an exact per-UID endpoint and remains before generic rejects.
run --apply "${BASE[@]}" --inference-gateway-tcp '10.23.4.5:08080'
check 'an IPv4 inference gateway applies successfully' rc_is 0
check 'the IPv4 inference gateway is canonical and UID-bound' same_content "$NFT" "$(expected_nft '1420, 4173, 5173, 32768-60999' 'ip daddr 10.23.4.5 tcp dport 8080 fib daddr type != broadcast accept')"
check 'the IPv4 gateway exception precedes the generic local reject' file_before "$NFT" 'ip daddr 10.23.4.5 tcp dport 8080' 'fib daddr type local counter reject'
check 'the IPv4 gateway exception precedes the generic private reject' file_before "$NFT" 'ip daddr 10.23.4.5 tcp dport 8080' '10.0.0.0/8, 100.64.0.0/10'
check 'the IPv4 gateway exception retains the directed-broadcast guard' grep -qF 'ip daddr 10.23.4.5 tcp dport 8080 fib daddr type != broadcast accept' "$NFT"
check 'the IPv4 gateway ruleset is the one nft loaded' same_content "$STATE/loaded.nft" "$(expected_nft '1420, 4173, 5173, 32768-60999' 'ip daddr 10.23.4.5 tcp dport 8080 fib daddr type != broadcast accept')"
run --apply "${BASE[@]}" --inference-gateway-tcp '[FD00:0000:0000:0000:0000:0000:0000:0001]:00443'
check 'an IPv6 inference gateway applies successfully' rc_is 0
check 'the IPv6 inference gateway uses deterministic canonical form' same_content "$NFT" "$(expected_nft '1420, 4173, 5173, 32768-60999' 'ip6 daddr fd00::1 tcp dport 443 fib daddr type != broadcast accept')"
run --inference-gateway-tcp '[fd00:0:0::1]:443' "${BASE[@]}"
check 'dry-run accepts an equivalent IPv6 spelling' rc_is 0
check 'dry-run prints the full canonical IPv6 rule' out_has 'meta skuid 1001 ip6 daddr fd00::1 tcp dport 443 fib daddr type != broadcast accept'
check 'dry-run identifies the selected gateway endpoint' out_has 'inference gateway TCP allow: [fd00::1]:443'
run --inference-gateway-tcp '127.0.0.1:8443' "${BASE[@]}"
check 'an explicit IPv4 loopback inference gateway is accepted' rc_is 0
check 'an explicit IPv4 loopback gateway is UID-bound' out_has 'meta skuid 1001 ip daddr 127.0.0.1 tcp dport 8443 fib daddr type != broadcast accept'
run --inference-gateway-tcp '[::1]:8443' "${BASE[@]}"
check 'an explicit IPv6 loopback inference gateway is accepted' rc_is 0
check 'an explicit IPv6 loopback gateway is UID-bound' out_has 'meta skuid 1001 ip6 daddr ::1 tcp dport 8443 fib daddr type != broadcast accept'

# Removing the opt-in converges back to the default loaded policy.
run --apply "${BASE[@]}"
check 'omitting the gateway option removes the installed exception' rc_is 0
check 'the installed ruleset returns to the unchanged default' same_content "$NFT" "$(expected_nft '1420, 4173, 5173, 32768-60999')"
check 'the loaded ruleset returns to the unchanged default' same_content "$STATE/loaded.nft" "$(expected_nft '1420, 4173, 5173, 32768-60999')"

# Broadcast classification is routing-dependent: the exact exception must retain its FIB gate.
run "${BASE[@]}" --inference-gateway-tcp '192.0.2.255:443'
check 'a broadcast-shaped literal keeps the runtime broadcast guard' out_has 'meta skuid 1001 ip daddr 192.0.2.255 tcp dport 443 fib daddr type != broadcast accept'

# Gateway values are a single strict literal destination. Refusals happen before any sudo call.
for endpoint in '' 'gateway.example:443' '10.23.4.5' '10.23.4.5:0' '10.23.4.5:65536' \
  '010.23.4.5:443' '10.999.4.5:443' '10.23.4.5:443/32' '10.23.4.5:443,10.0.0.1:443' \
  '10.23.4.5:443;id' $'10.23.4.5:443\n' '0.1.2.3:443' \
  '224.0.0.1:443' '240.0.0.1:443' '255.255.255.255:443' \
  '[::]:443' '[ff02::1]:443' '[::c000:201]:443' '[::ffff:c000:201]:443' \
  'fd00::1:443' '[fd00::1]:443-444' '[fd00::1]:443 xyz' '[fd00::1%lo]:443'; do
  expect_refusal "rejects inference gateway '$endpoint'" '--inference-gateway-tcp' \
    "${BASE[@]}" --inference-gateway-tcp "$endpoint"
done
expect_refusal 'apply rejects an injection-shaped gateway before sudo' '--inference-gateway-tcp' \
  --apply "${BASE[@]}" --inference-gateway-tcp '192.0.2.10:443;id'
expect_refusal 'apply rejects an unspecified gateway before sudo' '--inference-gateway-tcp' \
  --apply "${BASE[@]}" --inference-gateway-tcp '[::]:443'
expect_refusal 'rejects a missing inference gateway value' 'requires a value' "${BASE[@]}" --inference-gateway-tcp
expect_refusal 'rejects repeated inference gateway options' 'may be specified only once' \
  "${BASE[@]}" --inference-gateway-tcp '10.0.0.1:443' --inference-gateway-tcp '10.0.0.2:443'
expect_refusal 'revoke rejects the inference gateway option' '--revoke accepts only' \
  --revoke --user agent-dev --inference-gateway-tcp '10.0.0.1:443'
expect_refusal 'rejects IPv4-compatible notation outside loopback' '--inference-gateway-tcp' \
  "${BASE[@]}" --inference-gateway-tcp '[::c000:201]:443'
expect_refusal 'rejects IPv4-mapped notation' '--inference-gateway-tcp' \
  "${BASE[@]}" --inference-gateway-tcp '[::ffff:c000:201]:443'

# 3b. dry-run against an existing managed account uses its real uid ------------------------------
run "${BASE[@]}"
check 'dry-run on a managed account succeeds' rc_is 0
check 'dry-run on a managed account renders the real uid' out_has 'meta skuid 1001 fib daddr type local counter reject'
check 'dry-run on a managed account plans the initial expiry' out_has 'would run: sudo usermod --expiredate 1 agent-dev'
check 'dry-run on a managed account targets its user manager drop-in' out_has "--- would write $UMDROP (mode 0644, owner root:root) ---"
check 'dry-run on a managed account plans ending sessions when the table is not loaded' out_has 'if table brokkr_agent_agent_dev is not loaded, would also run: sudo loginctl terminate-user agent-dev'
check 'dry-run on a managed account mutates nothing' nothing_mutated

# 3c. runtime properties for an already-active slice ---------------------------------------------
reset_host
echo user-1001.slice >"$STATE/active"
run --apply "${BASE[@]}"
check 'apply with an active slice succeeds' rc_is 0
check 'an active slice receives runtime properties' has_call "sudo systemctl set-property --runtime user-1001.slice $SLICE_PROPS"
check 'an active slice is not started' no_call 'systemctl start user-1001.slice'
check 'runtime properties reach the kernel' cg_is memory.max 25769803776

# 3d. cron.deny and at.deny keep their existing entries -------------------------------------------
reset_host
printf 'daemon\nother\n' >"$CRON_DENY"
run --apply "${BASE[@]}"
check 'apply next to an existing cron.deny succeeds' rc_is 0
check 'an existing cron.deny keeps its entries and gains the account' same_content "$CRON_DENY" $'daemon\nother\nagent-dev'
check 'a missing at.deny is created with the account' same_content "$AT_DENY" 'agent-dev'
reset_host
printf 'daemon' >"$CRON_DENY"
printf 'other' >"$AT_DENY"
run --apply "${BASE[@]}"
check 'apply next to unterminated deny files succeeds' rc_is 0
check 'an unterminated cron.deny gets the account on its own line' same_content "$CRON_DENY" $'daemon\nagent-dev'
check 'an unterminated at.deny gets the account on its own line' same_content "$AT_DENY" $'other\nagent-dev'
reset_host
printf 'agent-dev2\nxagent-dev\n' >"$ROOT_DIR/etc/cron.allow"
run --apply "${BASE[@]}"
check 'a cron.allow listing only other names does not block the apply' rc_is 0

# 3e. subordinate IDs would bypass the per-uid egress rules ----------------------------------------
reset_host
run --apply "${BASE[@]}"
check 'a fresh account gets no subuid range' test ! -s "$ROOT_DIR/etc/subuid"
check 'a fresh account gets no subgid range' test ! -s "$ROOT_DIR/etc/subgid"
reset_host
STUB_USERADD_SUBIDS=1 run --apply "${BASE[@]}"
check 'subordinate IDs allocated anyway abort the apply' rc_is 64
check 'the subordinate-ID refusal names the cause' out_has 'subordinate IDs'
check 'subordinate IDs keep the account expired' no_call 'usermod -p'
check 'subordinate IDs prevent linger' no_call 'enable-linger'
check 'subordinate IDs prevent any key publication' absent "$ROOT_DIR/run/brokkr-agent-keys/agent-dev"
reset_host
seed_user agent-dev 1500 agent-dev 1500
mkdir -p "$ROOT_DIR/etc"
printf 'agent-dev:165536:65536\n' >"$ROOT_DIR/etc/subuid"
expect_refusal 'dry-run refuses a managed account with a subuid range by name' 'subordinate IDs' "${BASE[@]}"
# --apply on an enabled legacy account with a published key: lock it down, then refuse.
mkdir -p "$ROOT_DIR/run/brokkr-agent-keys"
echo legacy-key >"$ROOT_DIR/run/brokkr-agent-keys/agent-dev"
run --apply "${BASE[@]}"
check 'apply refuses a legacy account with subordinate IDs' rc_is 64
check 'the legacy refusal names the cause' out_has 'subordinate IDs'
check 'the legacy account is expired first' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 'the legacy account loses its published key' absent "$ROOT_DIR/run/brokkr-agent-keys/agent-dev"
check 'the legacy account sessions are ended' has_call 'sudo loginctl terminate-user agent-dev'
check 'the legacy account is not re-enabled' no_call 'usermod -p'
check 'the legacy account gets no linger' no_call 'enable-linger'
check 'the subordinate ranges are kept for review' grep -qx 'agent-dev:165536:65536' "$ROOT_DIR/etc/subuid"
check 'the lockdown says what it did' out_has 'published key withdrawn'
STUB_TERMINATE=error run --apply "${BASE[@]}"
check 'a failing terminate still aborts' test "$RC" -ne 0
check 'a failing terminate never re-enables the account' no_call 'usermod -p'
check 'a failing terminate is reported' out_has 'could not end sessions'
reset_host
seed_user agent-dev 1500 agent-dev 1500
mkdir -p "$ROOT_DIR/etc"
printf '1500:165536:65536\n' >"$ROOT_DIR/etc/subgid"
expect_refusal 'refuses a managed account with a subgid range by uid' 'subordinate IDs' "${BASE[@]}"

# 3e2. another sshd drop-in sorting before ours could pre-empt its settings -----------------------
reset_host
: >"$ROOT_DIR/etc/ssh/sshd_config.d/00-aaa.conf"
expect_refusal 'refuses when another sshd drop-in sorts first' 'sorts before' "${BASE[@]}"
expect_refusal 'apply refuses when another sshd drop-in sorts first' 'sorts before' --apply "${BASE[@]}"
reset_host
: >"$ROOT_DIR/etc/ssh/sshd_config.d/10-no-password-auth.conf"
: >"$ROOT_DIR/etc/ssh/sshd_config.d/70-other.conf"
run --apply "${BASE[@]}"
check 'later-sorting sshd drop-ins are accepted' rc_is 0

# 3f. a failing reload must not leave a published key ----------------------------------------------
reset_host
run --apply "${BASE[@]}"
STUB_RELOAD_NFT_FAIL=1 run --apply "${BASE[@]}"
check 'a failing unit reload aborts the re-run non-zero' rc_is 1
check 'a failing unit reload is reported as an abort' out_has 'aborted (exit 1)'
check 'a failing unit reload was attempted' has_call "sudo systemctl reload $UNIT_NAME"
check 'a failing unit reload leaves no published key' absent "$RUNKEY"
check 'a failing unit reload re-expired the account first' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 'a failing unit reload keeps the account expired' stays_expired
check 'a failing unit reload leaves sshd alone' no_call 'try-reload-or-restart'
check 'a failing unit reload keeps the persistent key file' same_content "$KEYF" "$EXPECT_KEYS"
run --apply "${BASE[@]}"
check 'the next re-run recovers after a failing reload' rc_is 0
check 'the next re-run publishes the key again' same_content "$RUNKEY" "$EXPECT_KEYS"
check 'the next re-run enables the account again' has_call 'sudo usermod -p * --expiredate  agent-dev'

# 3f2. sshd reload-only failure must fail closed -----------------------------------------------
reset_host
run --apply "${BASE[@]}"
STUB_SSH_RELOAD_FAIL=1 run --apply "${BASE[@]}"
check 'a failing sshd reload aborts the re-run non-zero' rc_is 1
check 'a failing sshd reload is attempted directly' has_call 'sudo systemctl reload ssh.service'
check 'a failing sshd reload has no restart fallback' no_call 'sudo systemctl (try-reload-or-restart|restart|start) ssh.service'
check 'a failing sshd reload keeps the account expired' stays_expired

# 3f3. housekeeping comparison errors fail closed before replacement ----------------------------
reset_host
run --apply "${BASE[@]}"
STUB_CMP_ERROR=1 run --apply "${BASE[@]}"
check 'a housekeeping comparison error aborts before overwrite' rc_is 1
check 'a housekeeping comparison error is reported as an abort' out_has 'could not compare housekeeping helper'
check 'a housekeeping comparison error does not restart a timer' no_call 'sudo systemctl restart'

# 3g. an unloaded egress table means earlier sessions ran without isolation -------------------------
reset_host
run --apply "${BASE[@]}"
rm -f "$STATE/loaded.nft"
run --apply "${BASE[@]}"
check 're-run with the egress table not loaded succeeds' rc_is 0
check 're-run with the egress table not loaded says why it ends sessions' out_has 'egress table brokkr_agent_agent_dev is not loaded: ending sessions that ran without isolation'
check 'an unloaded egress table ends the sessions' has_call 'sudo loginctl terminate-user agent-dev'
check 'sessions end after the initial expiry' before 'sudo usermod --expiredate 1 agent-dev' 'sudo loginctl terminate-user agent-dev'
check 'sessions end after the table check' before 'sudo nft list table inet brokkr_agent_agent_dev' 'sudo loginctl terminate-user agent-dev'
check 'sessions end before anything is rewritten' before 'sudo loginctl terminate-user agent-dev' 'sudo chmod 0700'
check 'sessions end before the account is enabled again' before 'sudo loginctl terminate-user agent-dev' 'sudo usermod -p'
check 'the account is enabled again once isolation is back' has_call 'sudo usermod -p * --expiredate  agent-dev'
rm -f "$STATE/loaded.nft"
STUB_TERMINATE=notloggedin run --apply "${BASE[@]}"
check 'a not-logged-in terminate failure does not stop the re-run' rc_is 0
check 'a not-logged-in terminate failure is reported as no sessions' out_has 'terminate-user: agent-dev has no sessions'
check 'a not-logged-in terminate failure still enables the account' has_call 'sudo usermod -p * --expiredate  agent-dev'
rm -f "$STATE/loaded.nft"
STUB_TERMINATE=error run --apply "${BASE[@]}"
check 'any other terminate failure aborts non-zero' rc_is 1
check 'any other terminate failure is named' out_has 'could not end sessions of agent-dev: Failed to terminate user agent-dev: Access denied'
check 'any other terminate failure says the account stays expired' out_has 'the account stays expired'
check 'any other terminate failure expired the account first' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 'any other terminate failure keeps the account expired' stays_expired
check 'any other terminate failure changes nothing else' no_call 'sudo (systemctl|chmod|install|tee)'

# 3h. every --ssh-from range is checked, not only loopback ------------------------------------------
reset_host
run --apply --user agent-dev --pubkey "$PUB" --ssh-from '10.1.2.3/32,2001:db8::/32'
check 'apply with a /32 and an IPv6 range succeeds' rc_is 0
check 'sshd -T checks loopback' has_call 'sudo sshd -T -C user=agent-dev,host=127.0.0.1,addr=127.0.0.1,lport=22'
check 'sshd -T checks the /32 host address' has_call 'sudo sshd -T -C user=agent-dev,host=10.1.2.3,addr=10.1.2.3,lport=22'
check 'sshd -T checks the IPv6 network address' has_call 'sudo sshd -T -C user=agent-dev,host=2001:db8::,addr=2001:db8::,lport=22'
check 'sshd -T runs once per context' test "$(call_count 'sudo sshd -T')" = 3

# 4. refusals ------------------------------------------------------------------------------------
reset_host
echo 0 >"$STATE/euid"
expect_refusal 'refuses to run as root' 'refusing to run as root' "${BASE[@]}"
echo 1000 >"$STATE/euid"
expect_refusal 'refuses the invoking user' 'invoking operator' --user operator --pubkey "$PUB" --ssh-from "$SSH_FROM"
expect_refusal 'refuses root as the account' 'must not be root' --user root --pubkey "$PUB" --ssh-from "$SSH_FROM"
expect_refusal 'refuses a zero --tmp-max-age' '--tmp-max-age must look like 7d' "${BASE[@]}" --tmp-max-age 0d
expect_refusal 'refuses a --tmp-max-age in weeks' '--tmp-max-age must look like 7d' "${BASE[@]}" --tmp-max-age 2w
expect_refusal 'refuses a --tmpfs-max-age without a unit' '--tmpfs-max-age must look like 1d' "${BASE[@]}" --tmpfs-max-age 7
expect_refusal 'refuses a --closing-session-grace that is neither a span nor off' '--closing-session-grace must be off or look like 6h' "${BASE[@]}" --closing-session-grace forever
expect_refusal 'revoke accepts no housekeeping options' '--revoke accepts only' --revoke --user agent-dev --closing-session-grace off
for name in Agent a 1agent agent_x 'agent;id' 'agent dev' abcdefghijklmnopqrstuvwxyz0123456789; do
  expect_refusal "refuses invalid user name '$name'" '--user must match' --user "$name" --pubkey "$PUB" --ssh-from "$SSH_FROM"
done
expect_refusal 'requires --user' '--user is required' --pubkey "$PUB" --ssh-from "$SSH_FROM"
expect_refusal 'requires --pubkey' '--pubkey is required' --user agent-dev --ssh-from "$SSH_FROM"
expect_refusal 'requires --ssh-from' '--ssh-from is required' --user agent-dev --pubkey "$PUB"
expect_refusal 'rejects unknown arguments' 'unknown argument' "${BASE[@]}" --bogus
expect_refusal 'rejects a missing option value' 'requires a value' --user
for key in two rsa garbage options comment empty link; do
  expect_refusal "rejects pubkey fixture '$key'" '--pubkey' --user agent-dev --pubkey "$KEYS/$key.pub" --ssh-from "$SSH_FROM"
done
expect_refusal 'rejects a missing pubkey file' '--pubkey' --user agent-dev --pubkey "$KEYS/absent.pub" --ssh-from "$SSH_FROM"
expect_refusal 'rejects a pubkey directory' '--pubkey' --user agent-dev --pubkey "$KEYS" --ssh-from "$SSH_FROM"

# --ssh-from: character allowlist first (the string is rendered into the key file), then structure
expect_refusal 'rejects a newline-injected --ssh-from before any mutation' '--ssh-from may contain only' --apply --user agent-dev --pubkey "$PUB" --ssh-from $'10.0.0.0/8\nssh-rsa AAAAinjected'
expect_refusal 'rejects a trailing-newline --ssh-from' '--ssh-from may contain only' --apply --user agent-dev --pubkey "$PUB" --ssh-from $'10.0.0.0/8\n'
expect_refusal 'rejects an option-injected --ssh-from' '--ssh-from may contain only' --apply --user agent-dev --pubkey "$PUB" --ssh-from '10.0.0.0/8",command="id'
for cidr in 10.0.0.0 '10.0.0.0/8,' ',10.0.0.0/8' '10.0.0.0/8,,192.168.0.0/16' foo/8 10.0.0.0/33 300.0.0.0/8 010.0.0.0/8 ::1 fe80::/129 'fe80::/10 ' 'a"b/8' 12345::/16 \
  '10.0.0.0/8;id' '10.0.0.0/8 ssh-rsa' '10.0.0.0/8#' \
  '1::2::3/64' '1:2:3:4:5:6:7:8:9/64' '1:2:3/64' ':1::2/64' '1::2:/64' '1:::2/64' '1:2:3:4:5:6:7:8::/64' 'g::1/64' ':/64' ; do
  expect_refusal "rejects --ssh-from '$cidr'" '--ssh-from' --user agent-dev --pubkey "$PUB" --ssh-from "$cidr"
done
for cidr in 2001:db8::/32 ::1/128 1:2:3:4:5:6:7:8/128 1:2:3:4:5:6:7::/64 '10.1.2.3/32,2001:db8::/32,fd7a:115c:a1e0::/48'; do
  run --user agent-dev --pubkey "$PUB" --ssh-from "$cidr"
  check "accepts --ssh-from '$cidr'" rc_is 0
done

# resource limits
expect_refusal 'rejects a bare memory-high' '--memory-high' "${BASE[@]}" --memory-high 20
expect_refusal 'rejects a memory-max with a bad unit' '--memory-max' "${BASE[@]}" --memory-max 20GB
expect_refusal 'rejects a lowercase memory unit' '--memory-max' "${BASE[@]}" --memory-max 24g
expect_refusal 'rejects a zero memory-high' '--memory-high' "${BASE[@]}" --memory-high 0G
expect_refusal 'rejects a memory value with a leading zero' '--memory-max' "${BASE[@]}" --memory-max 024G
expect_refusal 'rejects an overflowing memory-max' '--memory-max' "${BASE[@]}" --memory-max 1234567G
expect_refusal 'rejects an overflowing memory-high' '--memory-high' "${BASE[@]}" --memory-high 1234567G
expect_refusal 'rejects a memory-high above memory-max' 'must not exceed' "${BASE[@]}" --memory-high 25G
expect_refusal 'rejects a memory-high above a lowered memory-max' 'must not exceed' "${BASE[@]}" --memory-max 10G
expect_refusal 'compares memory limits in bytes, not digits' 'must not exceed' "${BASE[@]}" --memory-high 2048M --memory-max 1G
run "${BASE[@]}" --memory-high 24G --memory-max 24G
check 'accepts memory-high equal to memory-max' rc_is 0
run "${BASE[@]}" --memory-high 1024M --memory-max 1G
check 'accepts equal limits written in different units' rc_is 0
expect_refusal 'rejects a cpu quota without percent' '--cpu-quota' "${BASE[@]}" --cpu-quota 200
expect_refusal 'rejects a zero cpu quota' '--cpu-quota' "${BASE[@]}" --cpu-quota 0%
expect_refusal 'rejects a six-digit cpu quota' '--cpu-quota' "${BASE[@]}" --cpu-quota 100000%
expect_refusal 'rejects a cpu quota with a leading zero' '--cpu-quota' "${BASE[@]}" --cpu-quota 050%
expect_refusal 'rejects a negative cpu quota' '--cpu-quota' "${BASE[@]}" --cpu-quota -5%
run "${BASE[@]}" --cpu-quota 99999%
check 'accepts the largest cpu quota' rc_is 0
expect_refusal 'rejects a non-numeric tasks-max' '--tasks-max' "${BASE[@]}" --tasks-max abc
expect_refusal 'rejects a zero tasks-max' '--tasks-max' "${BASE[@]}" --tasks-max 0
expect_refusal 'rejects a tasks-max with a leading zero' '--tasks-max' "${BASE[@]}" --tasks-max 0123
expect_refusal 'rejects an eight-digit tasks-max' '--tasks-max' "${BASE[@]}" --tasks-max 10000000
run "${BASE[@]}" --tasks-max 9999999
check 'accepts the largest tasks-max' rc_is 0
for ports in 70000 0 100-50 abc '80,' '' 1-2-3 '1000-2000,1500' '80,80' 65536-65537; do
  expect_refusal "rejects --allow-local-tcp '$ports'" '--allow-local-tcp' "${BASE[@]}" --allow-local-tcp "$ports"
done

# deploy-source binding: any identity failure refuses --apply before any mutation
NOBIND=1 run --apply "${BASE[@]}"
check 'apply without a source binding is refused before any mutation' refused 'binding'
WRONG_SHA=$(printf '0%.0s' {1..40})
BIND_SHA=$WRONG_SHA run --apply "${BASE[@]}"
check 'apply with a wrong 40-hex expected commit is refused before any mutation' refused 'binding'
check 'a wrong expected commit reports the revision mismatch' out_has 'revision does not match'
for sha in abc123 not-a-sha "${HEAD_SHA:0:12}" "${HEAD_SHA:0:39}" "${HEAD_SHA}0" "$(printf '%s' "$HEAD_SHA" | tr a-f A-F)g"; do
  BIND_SHA=$sha run --apply "${BASE[@]}"
  check "apply with the malformed commit '${sha:0:20}' is refused before any mutation" refused 'binding'
  check "the malformed commit '${sha:0:20}' reports the SHA requirement" out_has 'full commit SHA'
done
BIND_SRC=$TMP run --apply "${BASE[@]}"
check 'apply with an expected source other than the invocation directory is refused' refused 'binding'
check 'a wrong expected source reports the different directory' out_has 'different directory'
BIND_SRC=$TMP/absent run --apply "${BASE[@]}"
check 'apply with a missing expected source is refused' refused 'binding'
BIND_SHA=$WRONG_SHA run --revoke --apply --user agent-dev
check 'revoke apply with a wrong expected commit is refused before any mutation' refused 'binding'
BIND_SHA=$WRONG_SHA run "${BASE[@]}"
check 'a dry-run ignores the binding entirely' rc_is 0

reset_host
seed_user agent-dev 1500 agent-dev
expect_refusal 'refuses to adopt an existing account without a marker' 'not managed by this script' "${BASE[@]}"
expect_refusal 'refuses to adopt an existing account on apply' 'not managed by this script' --apply "${BASE[@]}"
reset_host
seed_user agent-dev 1500 agent-dev 1600
expect_refusal 'refuses a marker for a different uid' 'does not match' "${BASE[@]}"
reset_host
seed_user agent-dev 500 agent-dev 500
expect_refusal 'refuses a managed account below uid 1000' '< 1000' "${BASE[@]}"
reset_host
seed_user agent-dev 1500 'agent-dev sudo' 1500
expect_refusal 'refuses a managed account with a supplementary group' 'only to its own group' "${BASE[@]}"
run --apply "${BASE[@]}"
check 'apply refuses the supplementary group with exit 64' rc_is 64
check 'the supplementary-group refusal names the group' out_has 'sudo'
check 'the supplementary-group account is expired before refusing' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 'the supplementary-group account sessions are ended' has_call 'sudo loginctl terminate-user agent-dev'
check 'the supplementary-group account is not re-enabled' no_call 'usermod -p'
check 'no key file for the supplementary-group account' absent "$KEYF"
reset_host
printf 'agent-dev:x:1700:\n' >>"$STATE/group"
expect_refusal 'refuses a leftover group without an account' 'group agent-dev already exists' "${BASE[@]}"

reset_host
STUB_EXTRA_GROUP=sudo run --apply "${BASE[@]}"
check 'the group check fails closed with exit 64' rc_is 64
check 'the group check names the problem' out_has 'only to its own group'
check 'the account was created expired' has_call '--user-group --expiredate 1 -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 agent-dev'
check 'the key file is not written when the group check fails' absent "$KEYF"
check 'no key is published when the group check fails' absent "$RUNKEY"
check 'the account stays expired when the group check fails' stays_expired
check 'egress is not started when the group check fails' no_call "enable --now $UNIT_NAME"
check 'the managed marker survives so a re-run does not strand the account' test -f "$MARK"

# 3i. disk-backed TMPDIR, sshd environment and housekeeping ----------------------------------------
reset_host
run "${BASE[@]}" --closing-session-grace 6h
check 'a dry-run with the reaper renders it' out_has 'reap-closing --user agent-dev --uid <uid> --grace-seconds 21600'
check 'a dry-run with the reaper plans both timers' out_has 'would run: sudo systemctl enable --now brokkr-agent-tmp-sweep-agent-dev.timer brokkr-agent-session-reaper-agent-dev.timer'
run --apply "${BASE[@]}" --closing-session-grace 6h
check 'an apply with the reaper succeeds' rc_is 0
check 'the closing-session reaper service is exact' same_content "$REAPER_SVC" "$(expected_reaper_service 6h 21600)"
check 'the closing-session reaper timer is exact' same_content "$REAPER_TMR" "$EXPECT_REAPER_TMR"
for unit_file in "$REAPER_SVC" "$REAPER_TMR"; do
  check "${unit_file##*/} is 0644 root" meta_has "$unit_file 0644 root root"
done
check 'both timers are enabled and started' has_call 'sudo systemctl enable --now brokkr-agent-tmp-sweep-agent-dev.timer brokkr-agent-session-reaper-agent-dev.timer'
check 'fresh sweep and reaper timers are not redundantly restarted' no_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'fresh sweep and reaper timers are not redundantly restarted individually' no_call 'sudo systemctl restart brokkr-agent-session-reaper-agent-dev.timer'
check 'the reaper says what it does' out_has 'sessions: closing sessions of agent-dev are ended after 6h'
run --apply "${BASE[@]}" --closing-session-grace 6h
check 'unchanged active sweep and reaper timers keep their timing' no_call 'sudo systemctl restart'
run --apply "${BASE[@]}" --closing-session-grace 7h
check 'a changed reaper payload restarts the active reaper timer once' has_call 'sudo systemctl restart brokkr-agent-session-reaper-agent-dev.timer'
check 'a changed reaper payload preserves the unchanged active sweep timer' no_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'a changed reaper payload restarts no other timer' test "$(call_count 'sudo systemctl restart')" = 1
run --apply "${BASE[@]}" --tmpfs-max-age 2d --closing-session-grace 7h
check 'a changed sweep payload restarts the active sweep timer once' has_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'a changed sweep payload preserves the unchanged active reaper timer' no_call 'sudo systemctl restart brokkr-agent-session-reaper-agent-dev.timer'
check 'a changed sweep payload restarts no other timer' test "$(call_count 'sudo systemctl restart')" = 1
printf '%s\n' '# timer drift for regression' >>"$SWEEP_TMR"
run --apply "${BASE[@]}" --tmpfs-max-age 2d --closing-session-grace 7h
check 'a changed timer payload restarts the active sweep timer once' has_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'a changed timer payload preserves the unchanged active reaper timer' no_call 'sudo systemctl restart brokkr-agent-session-reaper-agent-dev.timer'
check 'a changed timer payload restarts no other timer' test "$(call_count 'sudo systemctl restart')" = 1
printf '%s\n' '# helper drift for regression' >>"$HELPER"
run --apply "${BASE[@]}" --tmpfs-max-age 2d --closing-session-grace 7h
check 'a changed helper restarts both previously active timers' test "$(call_count 'sudo systemctl restart')" = 2
check 'a changed helper restarts the sweep timer' has_call 'sudo systemctl restart brokkr-agent-tmp-sweep-agent-dev.timer'
check 'a changed helper restarts the reaper timer' has_call 'sudo systemctl restart brokkr-agent-session-reaper-agent-dev.timer'
# the longest accepted spans render arguments the installed helper accepts
reset_host
run --apply "${BASE[@]}" --tmpfs-max-age 9999d --closing-session-grace 9999d
check 'the longest spans are accepted' rc_is 0
check 'the longest sweep age renders 14398560 minutes' grep -qF -- '--max-age-minutes 14398560' "$SWEEP_SVC"
check 'the longest grace renders 863913600 seconds' grep -qF -- '--grace-seconds 863913600' "$REAPER_SVC"
mkdir -p "$TMP/reap-state" "$TMP/helper-bin"
printf '#!/usr/bin/env bash\necho "Failed to get user: User ID 1001 is not logged in or lingering" >&2; exit 1\n' >"$TMP/helper-bin/loginctl"
chmod +x "$TMP/helper-bin/loginctl"
reap_args=$(sed -n 's/^ExecStart=[^ ]* reap-closing //p' "$REAPER_SVC" | sed "s#--state-dir [^ ]*#--state-dir $TMP/reap-state#")
# shellcheck disable=SC2086 # the rendered arguments are split as systemd splits them
helper_out=$(PATH="$TMP/helper-bin:$PATH" bash "$HELPER" reap-closing $reap_args 2>&1)
check 'the installed helper accepts the longest rendered grace' test "$?" -eq 0
sweep_age=$(sed -n 's/.*--max-age-minutes \([0-9]*\)$/\1/p' "$SWEEP_SVC")
helper_out=$(bash "$HELPER" sweep-tmp --user 'no-such-user-x' --dir "$TMP" --max-age-minutes "$sweep_age" 2>&1)
check 'the installed helper accepts the longest rendered sweep age' grep -qF 'sweep-tmp must run as no-such-user-x' <<<"$helper_out"
reset_host
run --apply "${BASE[@]}"
check 'the temporary directory filesystem is verified as disk-backed' out_has 'temporary directory filesystem: ext4'
for fs in tmpfs ramfs hugetlbfs ''; do
  reset_host
  STUB_TMP_FS="$fs" run --apply "${BASE[@]}"
  check "temporary filesystem '$fs' aborts non-zero" rc_is 1
  check "temporary filesystem '$fs' keeps the account expired" stays_expired
  check "temporary filesystem '$fs' leaves sshd alone" no_call 'try-reload-or-restart'
  check "temporary filesystem '$fs' publishes no key" absent "$RUNKEY"
done
reset_host
STUB_TMP_FS_FAIL=1 run --apply "${BASE[@]}"
check 'a failed filesystem probe aborts non-zero' rc_is 1
check 'a failed filesystem probe keeps the account expired' stays_expired
reset_host
STUB_TMPDIR_OWNER=operator run --apply "${BASE[@]}"
check 'a tmp directory with the wrong owner aborts non-zero' rc_is 1
check 'a tmp directory with the wrong owner is named' out_has "$AGENT_TMP is 'directory:operator:agent-dev:700', expected directory:agent-dev:agent-dev:700"
check 'a tmp directory with the wrong owner keeps the account expired' stays_expired
check 'a tmp directory with the wrong owner leaves sshd alone' no_call 'try-reload-or-restart'
check 'a tmp directory with the wrong owner publishes no key' absent "$RUNKEY"
reset_host
mkdir -p "$ROOT_DIR/var/lib/brokkr/agent-tmp" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$ROOT_DIR$AGENT_TMP"
run --apply "${BASE[@]}"
check 'a symlinked tmp directory aborts non-zero' test "$RC" -ne 0
check 'a symlinked tmp directory keeps the account expired' stays_expired
check 'a symlinked tmp directory is left as it was' test "$(readlink "$ROOT_DIR$AGENT_TMP")" = "$TMP/elsewhere"
rm -f "$ROOT_DIR$AGENT_TMP"
rm -rf "$TMP/elsewhere"
reset_host
STUB_TMPFILES_FAIL=1 run --apply "${BASE[@]}"
check 'a failing systemd-tmpfiles aborts non-zero' test "$RC" -ne 0
check 'a failing systemd-tmpfiles keeps the account expired' stays_expired
reset_host
STUB_SSHD_NO_SETENV=1 run --apply "${BASE[@]}"
check 'an sshd without the agent environment aborts non-zero' rc_is 1
check 'an sshd without the agent environment is named' out_has "sshd does not set $AGENT_ENV for agent-dev from 127.0.0.1"
check 'an sshd without the agent environment removes the new drop-in' absent "$DROPIN"
check 'an sshd without the agent environment does not reload sshd' no_call 'try-reload-or-restart'
check 'an sshd without the agent environment keeps the account expired' stays_expired
reset_host
STUB_SSHD_SETENV_FIRST=1 run --apply "${BASE[@]}"
check 'an earlier sshd SetEnv value for TMPDIR aborts non-zero' rc_is 1
check 'an earlier sshd SetEnv value is named' out_has "sshd does not set $AGENT_ENV for agent-dev from 127.0.0.1"
check 'an earlier sshd SetEnv value keeps the account expired' stays_expired
reset_host
echo systemd-tmpfiles-clean.timer >"$STATE/active"
run --apply "${BASE[@]}"
check 'an active tmpfiles clean timer gives no warning' test "$(out_has 'systemd-tmpfiles-clean.timer is not active' && echo yes)" != yes
reset_host
STUB_SET_ENV_FAIL=1 run --apply "${BASE[@]}"
check 'a user manager that cannot take the environment does not fail the apply' rc_is 0
check 'a user manager that cannot take the environment is reported' out_has 'warning: could not set the environment of the running user manager of agent-dev'
reset_host
run --apply "${BASE[@]}" --tmp-max-age 3d --tmpfs-max-age 90m --closing-session-grace 2h
check 'custom housekeeping ages succeed' rc_is 0
check 'the tmpfiles age follows --tmp-max-age' grep -qxF 'd /var/lib/brokkr/agent-tmp/agent-dev 0700 agent-dev agent-dev 3d' "$TMPFILES"
check 'the sweep age follows --tmpfs-max-age' same_content "$SWEEP_SVC" "$(expected_sweep_service 90m 90)"
check 'the reaper grace follows --closing-session-grace' same_content "$REAPER_SVC" "$(expected_reaper_service 2h 7200)"
run --apply "${BASE[@]}" --closing-session-grace off
check 'turning the reaper off succeeds' rc_is 0
check 'turning the reaper off disables its timer' has_call 'sudo systemctl disable --now brokkr-agent-session-reaper-agent-dev.timer'
check 'turning the reaper off keeps the sweep timer' has_call 'sudo systemctl enable --now brokkr-agent-tmp-sweep-agent-dev.timer'
check 'turning the reaper off does not enable it' no_call 'enable --now brokkr-agent-tmp-sweep-agent-dev.timer brokkr-agent-session-reaper'
check 'turning the reaper off says so' out_has 'closing sessions of agent-dev are never ended automatically'
reset_host
run --apply "${BASE[@]}" --closing-session-grace off
check 'a fresh host without the reaper succeeds' rc_is 0
check 'a fresh host without the reaper installs no reaper' absent "$REAPER_SVC"
check 'a fresh host without the reaper touches no reaper unit' no_call 'session-reaper'

# 5. nft -c failure ------------------------------------------------------------------------------
reset_host
STUB_NFT_CHECK_FAIL=1 run --apply "${BASE[@]}"
check 'nft -c failure aborts non-zero' rc_is 1
check 'nft -c failure names the cause' out_has 'nft rejected the ruleset'
check 'nft -c failure publishes no key' absent "$RUNKEY"
check 'nft -c failure keeps the account expired' stays_expired
check 'nft -c failure starts no egress unit' no_call "enable --now $UNIT_NAME"
check 'nft -c failure installs no ruleset' absent "$NFT"
check 'nft -c failure removes the staged ruleset' absent "$NFT.new"
reset_host
STUB_FAIL=enable run --apply "${BASE[@]}"
check 'a failing egress start aborts' test "$RC" -ne 0
check 'a failing egress start publishes no key' absent "$RUNKEY"
check 'a failing egress start keeps the account expired' stays_expired
check 'a failing egress start leaves sshd alone' no_call 'try-reload-or-restart'

# 5-conf. the host's nftables.conf must load the agent rulesets after a flush -------------------------
NFTCONF="$ROOT_DIR/etc/nftables.conf"
INCLUDE='include "/etc/brokkr/agent-account/*.nft"'
CONF_BASE=$'#!/usr/sbin/nft -f\nflush ruleset\ninclude "/etc/nftables.d/*.nft"'
CONF_WANT="$CONF_BASE"$'\n'"$INCLUDE"
include_count() { grep -cxF -- "$INCLUDE" "$NFTCONF"; }
reset_host
printf '%s\n' "$CONF_BASE" >"$NFTCONF"
run --apply "${BASE[@]}"
check 'apply next to an existing nftables.conf succeeds' rc_is 0
check 'an existing nftables.conf keeps its content and gains the include' same_content "$NFTCONF" "$CONF_WANT"
check 'the include is appended exactly once' test "$(include_count)" = 1
check 'the nftables.conf is validated whole' has_call "sudo nft -c -f $NFTCONF"
check 'the validated nftables.conf already contained the include' same_content "$STATE/nftconf.checked" "$CONF_WANT"
check 'the nftables.conf backup is removed after validation' absent "$NFTCONF.brokkr-previous"
check 'the staged ruleset is validated before nftables.conf is touched' before "sudo nft -c -f $NFT.new" "sudo cp -a $NFTCONF"
check 'nftables.conf is backed up before the include is appended' before "sudo cp -a $NFTCONF $NFTCONF.brokkr-previous" "sudo tee -a $NFTCONF"
check 'the include is appended before the nftables.conf validation' before "sudo tee -a $NFTCONF" "sudo nft -c -f $NFTCONF"
check 'the nftables.conf validation precedes the egress unit start' before "sudo nft -c -f $NFTCONF" "sudo systemctl enable --now $UNIT_NAME"
check 'the nftables.conf validation precedes the account enable' before "sudo nft -c -f $NFTCONF" 'sudo usermod -p'
check 'the nftables.conf validation precedes linger' before "sudo nft -c -f $NFTCONF" 'sudo loginctl enable-linger'
run --apply "${BASE[@]}"
check 're-run next to nftables.conf succeeds' rc_is 0
check 're-run does not duplicate the include' test "$(include_count)" = 1
check 're-run leaves nftables.conf as it was' same_content "$NFTCONF" "$CONF_WANT"
check 're-run says the include is already there' out_has "$NFTCONF already includes the agent rulesets"
check 're-run does not write nftables.conf' no_call "tee -a $NFTCONF"
check 're-run takes no nftables.conf backup' no_call "$NFTCONF.brokkr-previous"
reset_host
printf '%s' "$CONF_BASE" >"$NFTCONF"
run --apply "${BASE[@]}"
check 'apply next to an unterminated nftables.conf succeeds' rc_is 0
check 'an unterminated nftables.conf gets the include on its own line' same_content "$NFTCONF" "$CONF_WANT"
check 'an unterminated nftables.conf is validated with the include on its own line' same_content "$STATE/nftconf.checked" "$CONF_WANT"
reset_host
: >"$NFTCONF"
run --apply "${BASE[@]}"
check 'apply next to an empty nftables.conf succeeds' rc_is 0
check 'an empty nftables.conf gets no leading blank line' same_content "$NFTCONF" "$INCLUDE"
reset_host
printf '%s' "$CONF_BASE" >"$NFTCONF"
cp "$NFTCONF" "$TMP/nftconf.orig"
STUB_NFTCONF_FAIL=1 run --apply "${BASE[@]}"
check 'a rejected nftables.conf aborts non-zero' rc_is 1
check 'a rejected nftables.conf is named and reported as restored' out_has "nft rejected $NFTCONF with the include; it was restored and the account stays expired"
check 'the validation saw the appended include' same_content "$STATE/nftconf.checked" "$CONF_WANT"
check 'a rejected nftables.conf is restored byte for byte' cmp -s "$TMP/nftconf.orig" "$NFTCONF"
check 'a rejected nftables.conf leaves no backup' absent "$NFTCONF.brokkr-previous"
check 'a rejected nftables.conf keeps the account expired' stays_expired
check 'a rejected nftables.conf starts no egress unit' no_call "enable --now $UNIT_NAME"
check 'a rejected nftables.conf publishes no key' absent "$RUNKEY"
check 'a rejected nftables.conf leaves sshd alone' no_call 'try-reload-or-restart'
run --apply "${BASE[@]}"
check 'the apply recovers once nftables.conf validates' rc_is 0
check 'the recovered nftables.conf has the include once' test "$(include_count)" = 1
reset_host
printf '%s\n' "$CONF_BASE" >"$TMP/nftconf.target"
ln -s "$TMP/nftconf.target" "$NFTCONF"
run --apply "${BASE[@]}"
check 'a symlinked nftables.conf aborts non-zero' rc_is 1
check 'a symlinked nftables.conf is named' out_has "$NFTCONF is not a regular file; the account stays expired"
check 'a symlinked nftables.conf target is untouched' same_content "$TMP/nftconf.target" "$CONF_BASE"
check 'a symlinked nftables.conf stays a symlink' test -L "$NFTCONF"
check 'a symlinked nftables.conf is never written' no_call "tee -a $NFTCONF"
check 'a symlinked nftables.conf keeps the account expired' stays_expired
check 'a symlinked nftables.conf starts no egress unit' no_call "enable --now $UNIT_NAME"
reset_host
mkdir "$NFTCONF"
run --apply "${BASE[@]}"
check 'a directory at nftables.conf aborts non-zero' rc_is 1
check 'a directory at nftables.conf is named' out_has "$NFTCONF is not a regular file"
check 'a directory at nftables.conf keeps the account expired' stays_expired
rm -rf "$NFTCONF"

# 5-last. linger first, then the account enable as the last mutating call ------------------------------
reset_host
STUB_ENABLE_LINGER_FAIL=1 run --apply "${BASE[@]}"
check 'a failing enable-linger aborts non-zero' rc_is 1
check 'a failing enable-linger is reported as an abort' out_has 'aborted (exit 1)'
check 'a failing enable-linger was attempted' has_call 'sudo loginctl enable-linger agent-dev'
check 'a failing enable-linger never enables the account' no_call 'usermod -p'
check 'a failing enable-linger leaves nothing after it' last_sudo_is 'sudo loginctl enable-linger agent-dev'
reset_host
run --apply "${BASE[@]}"
STUB_ENABLE_LINGER_FAIL=1 run --apply "${BASE[@]}"
check 'a failing enable-linger on a re-run aborts non-zero' rc_is 1
check 'a failing enable-linger on a re-run had re-expired the account' first_sudo_is 'sudo usermod --expiredate 1 agent-dev'
check 'a failing enable-linger on a re-run never enables the account' no_call 'usermod -p'

# 5a. the kernel's limits must match what was asked -----------------------------------------------
for file in memory.max memory.high memory.swap.max pids.max cpu.max; do
  reset_host
  STUB_CG_WRONG=$file run --apply "${BASE[@]}"
  check "a wrong $file aborts non-zero" rc_is 1
  check "a wrong $file is named" out_has "$file is 'max"
  check "a wrong $file keeps the account expired" stays_expired
  check "a wrong $file starts no egress unit" no_call "enable --now $UNIT_NAME"
done
reset_host
STUB_CG_WRONG=1 run --apply "${BASE[@]}"
check 'STUB_CG_WRONG=1 corrupts memory.max' out_has "memory.max is 'max', expected 24G"
reset_host
STUB_SHOW_WRONG=1 run --apply "${BASE[@]}"
check 'a wrong configured MemoryMax aborts non-zero' rc_is 1
check 'a wrong configured MemoryMax is named' out_has 'does not have MemoryMax=25769803776'
check 'a wrong configured MemoryMax keeps the account expired' stays_expired
check 'a wrong configured MemoryMax starts no egress unit' no_call "enable --now $UNIT_NAME"
reset_host
STUB_CG_MISSING=1 run --apply "${BASE[@]}"
check 'unreadable cgroup files abort non-zero' rc_is 1
check 'unreadable cgroup files are named' out_has 'cannot read'
check 'unreadable cgroup files keep the account expired' stays_expired
reset_host
echo user-1001.slice >"$STATE/active"
STUB_CG_WRONG=1 run --apply "${BASE[@]}"
check 'a wrong memory.max on an active slice aborts non-zero' rc_is 1
check 'a wrong memory.max on an active slice keeps the account expired' stays_expired

# 5a2. the SSH key must actually be published ------------------------------------------------------
reset_host
STUB_NO_PUBLISH=1 run --apply "${BASE[@]}"
check 'an unpublished key aborts non-zero' rc_is 1
check 'an unpublished key is named' out_has 'did not publish /run/brokkr-agent-keys/agent-dev'
check 'the unpublished-key check ran' has_call "sudo cmp -s $KEYF $RUNKEY"
check 'an unpublished key keeps the account expired' stays_expired
check 'an unpublished key leaves sshd alone' no_call 'try-reload-or-restart'
check 'an unpublished key leaves no run key' absent "$RUNKEY"
reset_host
run --apply "${BASE[@]}"
printf 'stale\n' >"$RUNKEY"
STUB_NO_PUBLISH=1 run --apply "${BASE[@]}"
check 'a stale published key is not mistaken for the current one' rc_is 1

# 5a3. cron and at must not be usable by the account -------------------------------------------------
for list in cron.allow at.allow; do
  reset_host
  printf 'someone\nagent-dev\n' >"$ROOT_DIR/etc/$list"
  run --apply "${BASE[@]}"
  check "$list listing the account is refused" rc_is 1
  check "$list listing the account is named" out_has "agent-dev is listed in $ROOT_DIR/etc/$list"
  check "$list listing the account keeps it expired" stays_expired
  check "$list listing the account leaves sshd alone" no_call 'try-reload-or-restart'
  check "$list listing the account records no deny entry" absent "$CRON_DENY"
done
reset_host
mkdir -p "$ROOT_DIR/var/spool/cron/crontabs"
: >"$ROOT_DIR/var/spool/cron/crontabs/agent-dev"
run --apply "${BASE[@]}"
check 'an existing crontab is refused' rc_is 1
check 'an existing crontab is named' out_has 'already has a crontab'
check 'an existing crontab keeps the account expired' stays_expired
check 'an existing crontab leaves sshd alone' no_call 'try-reload-or-restart'
rm -f "$ROOT_DIR/var/spool/cron/crontabs/agent-dev"
run --apply "${BASE[@]}"
check 'the apply succeeds once the crontab is gone' rc_is 0
check 'the account is enabled once the crontab is gone' has_call 'sudo usermod -p * --expiredate  agent-dev'
ATJOBS="$ROOT_DIR/var/spool/cron/atjobs"
reset_host
mkdir -p "$ATJOBS"
STUB_ATJOB=1 run --apply "${BASE[@]}"
check 'a queued at job is refused' rc_is 1
check 'a queued at job is named' out_has "agent-dev has queued at jobs in $ATJOBS; review and remove them (the account stays expired)"
check 'the at spool is searched for files owned by the account uid only' has_call "sudo find $ATJOBS -maxdepth 1 -type f -uid 1001 -print -quit"
check 'a queued at job keeps the account expired' stays_expired
check 'a queued at job leaves sshd alone' no_call 'try-reload-or-restart'
check 'a queued at job records no deny entry' absent "$CRON_DENY"
check 'a queued at job leaves no at deny entry' absent "$AT_DENY"
reset_host
mkdir -p "$ATJOBS"
run --apply "${BASE[@]}"
check 'an empty at spool does not block the apply' rc_is 0
check 'an empty at spool is searched' has_call "sudo find $ATJOBS -maxdepth 1 -type f -uid 1001 -print -quit"
check 'an empty at spool lets the account be enabled' has_call 'sudo usermod -p * --expiredate  agent-dev'
reset_host
STUB_ATJOB=1 run --apply "${BASE[@]}"
check 'a host without an at spool directory does not block the apply' rc_is 0
check 'a host without an at spool directory runs no find' no_call '^sudo find([[:space:]]|$)'

# 5b. sshd validation failures -------------------------------------------------------------------
reset_host
STUB_SSHD_T_FAIL=1 run --apply "${BASE[@]}"
check 'sshd -t failure aborts non-zero' rc_is 1
check 'sshd -t failure names the cause' out_has 'sshd rejected the configuration'
check 'sshd -t failure removes the new drop-in' absent "$DROPIN"
check 'sshd -t failure does not reload sshd' no_call 'try-reload-or-restart'
check 'sshd -t failure keeps the account expired' stays_expired
reset_host
STUB_SSHD_OVERRIDE=1 run --apply "${BASE[@]}"
check 'an overridden sshd policy aborts non-zero' rc_is 1
check 'an overridden sshd policy names the missing setting' out_has 'is not effective'
check 'an overridden sshd policy removes the new drop-in' absent "$DROPIN"
check 'an overridden sshd policy does not reload sshd' no_call 'try-reload-or-restart'
check 'an overridden sshd policy keeps the account expired' stays_expired
n=0
for addr in 127.0.0.1 100.64.0.0 fd7a:115c:a1e0::; do
  n=$((n + 1))
  reset_host
  STUB_SSHD_DEFAULT_ADDR=$addr run --apply "${BASE[@]}"
  check "an address-specific policy for $addr aborts non-zero" rc_is 1
  check "an address-specific policy for $addr is named" out_has "sshd policy for agent-dev is not effective from $addr"
  check "an address-specific policy for $addr was checked" has_call "sudo sshd -T -C user=agent-dev,host=$addr,addr=$addr,lport=22"
  check "the checks stop at the failing address $addr" test "$(call_count 'sudo sshd -T')" = "$n"
  check "an address-specific policy for $addr removes the new drop-in" absent "$DROPIN"
  check "an address-specific policy for $addr does not reload sshd" no_call 'try-reload-or-restart'
  check "an address-specific policy for $addr enables no linger" no_call 'enable-linger'
  check "an address-specific policy for $addr never enables the account" no_call 'usermod -p'
done
reset_host
run --apply "${BASE[@]}"
printf '# previous\n' >"$DROPIN"
STUB_SSHD_DEFAULT_ADDR=100.64.0.0 run --apply "${BASE[@]}"
check 'an address-specific failure on a re-run aborts non-zero' rc_is 1
check 'an address-specific failure on a re-run restores the previous drop-in' same_content "$DROPIN" '# previous'
check 'an address-specific failure on a re-run leaves no backup' absent "$DROPIN.previous"
check 'an address-specific failure on a re-run does not reload sshd' no_call 'try-reload-or-restart'
check 'an address-specific failure on a re-run keeps the account expired' stays_expired
reset_host
run --apply "${BASE[@]}"
printf '# previous\n' >"$DROPIN"
STUB_SSHD_T_FAIL=1 run --apply "${BASE[@]}"
check 'a failing re-run restores the previous drop-in' same_content "$DROPIN" '# previous'
check 'a failing re-run leaves no backup behind' absent "$DROPIN.previous"
check 'a failing re-run keeps the account expired' stays_expired

# 5c. a symlinked ~/.ssh cannot redirect privileged writes -----------------------------------------
reset_host
run --apply "${BASE[@]}"
mkdir -p "$TMP/protected"
chmod 755 "$TMP/protected"
ln -s "$TMP/protected" "$HOMEDIR/.ssh"
run --apply "${BASE[@]}"
check 're-run with a symlinked ~/.ssh succeeds' rc_is 0
check 're-run never touches the agent ~/.ssh' no_call 'home/agent-dev/\.ssh'
check 'the symlink target stays empty' test -z "$(ls -A "$TMP/protected")"
check 'the symlink target keeps its mode' mode_is "$TMP/protected" 755
check 're-run keeps the symlink as it was' test "$(readlink "$HOMEDIR/.ssh")" = "$TMP/protected"
check 're-run still serves the key from the root-owned location' same_content "$RUNKEY" "$EXPECT_KEYS"
run --revoke --apply --user agent-dev
check 'revoke with a symlinked ~/.ssh succeeds' rc_is 0
check 'revoke with a symlinked ~/.ssh never touches it' no_call 'home/agent-dev/\.ssh'
check 'revoke leaves the symlink target empty' test -z "$(ls -A "$TMP/protected")"
check 'revoke leaves the symlink target mode alone' mode_is "$TMP/protected" 755
rm -f "$HOMEDIR/.ssh"
rm -rf "$TMP/protected"

# 6. revoke --------------------------------------------------------------------------------------
reset_host
expect_refusal 'revoke of an unknown account is refused' 'does not exist' --revoke --user agent-dev
seed_user agent-dev 1500 agent-dev
expect_refusal 'revoke requires the marker' 'not managed by this script' --revoke --user agent-dev
expect_refusal 'revoke accepts no provisioning options' '--revoke accepts only' --revoke --user agent-dev --pubkey "$PUB"

reset_host
run --apply "${BASE[@]}"
check 'the run key exists before the revoke' test -f "$RUNKEY"
SNAP2=$(snapshot)
run --revoke --user agent-dev
check 'revoke dry-run succeeds' rc_is 0
check 'revoke dry-run plans the lock' out_has 'would run: sudo usermod --lock --expiredate 1 agent-dev'
check 'revoke dry-run plans the key withdrawal' out_has "would run: sudo install -m 0644 -o root -g root /dev/null $KEYF"
check 'revoke dry-run plans removing the run key' out_has "would run: sudo rm -f $RUNKEY"
check 'revoke dry-run prints the manual removal commands' out_has 'sudo userdel -r agent-dev'
check 'revoke dry-run names the nftables.conf include and the helper to remove by hand' out_has "(and remove the line 'include \"/etc/brokkr/agent-account/*.nft\"' from $ROOT_DIR/etc/nftables.conf and $HELPER once no agent account remains)"
check 'revoke dry-run lists the 00- sshd drop-in for removal' out_has "$DROPIN"
check 'revoke dry-run lists the housekeeping timers for removal' out_has 'sudo systemctl disable --now brokkr-agent-tmp-sweep-agent-dev.timer brokkr-agent-session-reaper-agent-dev.timer'
check 'revoke dry-run lists the tmp directory for review' out_has "$AGENT_TMP"
check 'revoke dry-run mutates nothing' nothing_mutated
check 'revoke dry-run leaves the files untouched' test "$SNAP2" = "$(snapshot)"
echo 'agent-dev sudo' >"$STATE/groups/agent-dev"
run --revoke --apply --user agent-dev
check 'revoke apply succeeds even if the account has extra groups' rc_is 0
check 'revoke locks and expires the account first' first_sudo_is 'sudo usermod --lock --expiredate 1 agent-dev'
check 'revoke truncates the key file through root' has_call "sudo install -m 0644 -o root -g root /dev/null $KEYF"
check 'revoke empties the persistent key file' test -f "$KEYF" -a ! -s "$KEYF"
check 'revoke keeps the key file 0644' mode_is "$KEYF" 644
check 'revoke withdraws the published key' absent "$RUNKEY"
check 'revoke removes the run key with rm -f' has_call "sudo rm -f $RUNKEY"
check 'revoke removes nothing but the run key' test "$(grep -cE '^(sudo )?rm ' "$CALLS")" = 1
check 'revoke disables linger' has_call 'sudo loginctl disable-linger agent-dev'
check 'revoke terminates sessions' has_call 'sudo loginctl terminate-user agent-dev'
check 'revoke locks before it truncates the key file' before 'sudo usermod --lock --expiredate 1 agent-dev' "sudo install -m 0644 -o root -g root /dev/null $KEYF"
check 'revoke truncates the key file before it removes the run key' before "/dev/null $KEYF" "sudo rm -f $RUNKEY"
check 'revoke removes the run key before it disables linger' before "sudo rm -f $RUNKEY" 'sudo loginctl disable-linger agent-dev'
check 'revoke disables linger before it terminates sessions' before 'sudo loginctl disable-linger agent-dev' 'sudo loginctl terminate-user agent-dev'
check 'revoke never deletes the user' no_call 'userdel'
check 'revoke keeps the egress unit, ruleset, slice and marker' test -f "$UNIT" -a -f "$NFT" -a -f "$SLICE" -a -f "$MARK"
check 'revoke keeps the user manager and sshd drop-ins' test -f "$UMDROP" -a -f "$DROPIN"
check 'revoke keeps the home directory' test -d "$HOMEDIR"
check 'revoke keeps the housekeeping units and the tmp directory' test -f "$SWEEP_SVC" -a -f "$TMPFILES" -a -d "$ROOT_DIR$AGENT_TMP"
check 'revoke never touches the agent home .ssh' no_call 'home/agent-dev/\.ssh'
check 'revoke leaves no .ssh in the agent home' absent "$HOMEDIR/.ssh"
check 'revoke does not stop or reload any unit' no_call '^(sudo )?systemctl '
check 'revoke goes through sudo only' only_via_sudo
STUB_TERMINATE=notloggedin run --revoke --apply --user agent-dev
check 'revoke ignores a not-logged-in terminate failure' rc_is 0
check 'revoke reports a not-logged-in terminate failure as no sessions' out_has 'terminate-user: agent-dev has no sessions'
STUB_TERMINATE=error run --revoke --apply --user agent-dev
check 'revoke surfaces any other terminate failure' rc_is 1
check 'revoke names the failed terminate step' out_has 'revoke step failed: loginctl terminate-user agent-dev: Failed to terminate user agent-dev: Access denied'
check 'revoke has already locked the account when terminate fails' has_call 'sudo usermod --lock --expiredate 1 agent-dev'
NOBIND=1 run --revoke --apply --user agent-dev
check 'revoke apply needs the source binding' refused 'binding'

# revoke: every step runs, any failure is surfaced
reprovision() { echo agent-dev >"$STATE/groups/agent-dev"; run --apply "${BASE[@]}"; }
reprovision
check 're-provisioning after a revoke succeeds' rc_is 0
check 're-provisioning enables the account again' has_call 'sudo usermod -p * --expiredate  agent-dev'
check 're-provisioning restores the key file' same_content "$KEYF" "$EXPECT_KEYS"
check 're-provisioning republishes the key' same_content "$RUNKEY" "$EXPECT_KEYS"
STUB_DISABLE_LINGER_FAIL=1 run --revoke --apply --user agent-dev
check 'a failing disable-linger exits non-zero' rc_is 1
check 'a failing disable-linger is named' out_has 'revoke step failed: loginctl disable-linger agent-dev'
check 'a failing disable-linger still terminates the sessions' has_call 'sudo loginctl terminate-user agent-dev'
check 'a failing disable-linger still locked the account' has_call 'sudo usermod --lock --expiredate 1 agent-dev'
check 'a failing disable-linger still emptied the key file' test -f "$KEYF" -a ! -s "$KEYF"
check 'a failing disable-linger still removed the run key' absent "$RUNKEY"
reprovision
STUB_FAIL=usermod run --revoke --apply --user agent-dev
check 'a failing lock exits non-zero' rc_is 1
check 'a failing lock is named' out_has 'revoke step failed: usermod --lock --expiredate 1 agent-dev'
check 'a failing lock still empties the key file' test -f "$KEYF" -a ! -s "$KEYF"
check 'a failing lock still removes the run key' absent "$RUNKEY"
check 'a failing lock still disables linger' has_call 'sudo loginctl disable-linger agent-dev'
check 'a failing lock still terminates the sessions' has_call 'sudo loginctl terminate-user agent-dev'
reprovision
STUB_FAIL=install run --revoke --apply --user agent-dev
check 'a failing key truncation exits non-zero' rc_is 1
check 'a failing key truncation is named' out_has "revoke step failed: install -m 0644 -o root -g root /dev/null $KEYF"
check 'a failing key truncation still removes the run key' absent "$RUNKEY"
check 'a failing key truncation still disables linger' has_call 'sudo loginctl disable-linger agent-dev'
check 'a failing key truncation still terminates the sessions' has_call 'sudo loginctl terminate-user agent-dev'
STUB_FAIL=usermod STUB_DISABLE_LINGER_FAIL=1 run --revoke --apply --user agent-dev
check 'several failing steps are all listed' out_has 'revoke step failed: usermod --lock --expiredate 1 agent-dev'
check 'several failing steps list the later one too' out_has 'revoke step failed: loginctl disable-linger agent-dev'

# 7. missing tools -------------------------------------------------------------------------------
MISSING="$TMP/bin-missing"
mkdir -p "$MISSING"
for f in "$STUBS"/*; do [[ ${f##*/} == nft ]] || ln -s "$f" "$MISSING/${f##*/}"; done
[[ -e "$MISSING/ssh-keygen" ]] || ln -s "$(command -v ssh-keygen)" "$MISSING/ssh-keygen"
ln -s "$(command -v dirname)" "$MISSING/dirname"
reset_host
OUT=$(cd "$FIXTURE" && PATH="$MISSING" STUB_CALLS="$CALLS" STUB_STATE="$STATE" BROKKR_AGENT_ROOT="$ROOT_DIR" \
  BROKKR_AGENT_SBIN='' "$(command -v bash)" scripts/provision-agent-account.sh "${BASE[@]}" 2>&1)
RC=$?
check 'a missing required tool fails early with exit 64' rc_is 64
check 'a missing required tool is named' out_has 'required tool(s) missing: nft'
check 'a missing tool prevents any command from running' nothing_mutated

if (( FAIL )); then
  printf '%s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf '%s passed\n' "$PASS"
