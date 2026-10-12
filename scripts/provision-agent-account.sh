#!/usr/bin/env bash
# Provision (or revoke) a dedicated, unprivileged Linux account for coding agents on a shared
# host, resource-bounded and network-isolated from the operator and from local/private services.
# Runs ON the host as the operator, WITHOUT sudo; privileged steps escalate per command.
#
#   provision-agent-account.sh [--apply] --user NAME --pubkey FILE --ssh-from CIDR[,CIDR...]
#       [--cpu-quota 2000%] [--memory-high 20G] [--memory-max 24G] [--tasks-max 4096]
#       [--allow-local-tcp '1420,4173,5173,32768-60999']
#   provision-agent-account.sh --revoke [--apply] --user NAME
#
# Default is DRY-RUN: validate, print every planned action and every file it would write,
# mutate nothing. --apply mutates and requires BROKKR_EXPECTED_SOURCE/BROKKR_EXPECTED_COMMIT
# (see scripts/lib/deploy-source.sh). See docs/agent-account.md.
#
# Test seams (production leaves both unset):
#   BROKKR_AGENT_ROOT  prefix for every absolute host path the script reads or writes
#   BROKKR_AGENT_SBIN  extra PATH suffix for sbin tools (default /usr/local/sbin:/usr/sbin:/sbin)
set -Eeuo pipefail
trap 'echo "brokkr agent account: aborted (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=lib/deploy-source.sh
source "$HERE/lib/deploy-source.sh"

SBIN_PATH=${BROKKR_AGENT_SBIN-/usr/local/sbin:/usr/sbin:/sbin}
[[ -z $SBIN_PATH ]] || PATH="$PATH:$SBIN_PATH"
ROOT=${BROKKR_AGENT_ROOT:-}
while [[ $ROOT == */ ]]; do ROOT=${ROOT%/}; done

die() { echo "brokkr agent account: $*" >&2; exit 64; }
fatal() { echo "brokkr agent account: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  provision-agent-account.sh [--apply] --user NAME --pubkey FILE --ssh-from CIDR[,CIDR...]
      [--cpu-quota 2000%] [--memory-high 20G] [--memory-max 24G] [--tasks-max 4096]
      [--allow-local-tcp '1420,4173,5173,32768-60999']
  provision-agent-account.sh --revoke [--apply] --user NAME
Dry-run unless --apply is given.
EOF
}

APPLY=0
REVOKE=0
USER_NAME=
PUBKEY_FILE=
SSH_FROM=
CPU_QUOTA=2000%
MEM_HIGH=20G
MEM_MAX=24G
TASKS_MAX=4096
LOCAL_TCP='1420,4173,5173,32768-60999'
PROVISION_OPTS_GIVEN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --apply) APPLY=1; shift; continue ;;
    --revoke) REVOKE=1; shift; continue ;;
    --user|--pubkey|--ssh-from|--cpu-quota|--memory-high|--memory-max|--tasks-max|--allow-local-tcp)
      [[ $# -ge 2 ]] || { usage >&2; die "$1 requires a value"; } ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  case $1 in
    --user) USER_NAME=$2 ;;
    --pubkey) PUBKEY_FILE=$2; PROVISION_OPTS_GIVEN=1 ;;
    --ssh-from) SSH_FROM=$2; PROVISION_OPTS_GIVEN=1 ;;
    --cpu-quota) CPU_QUOTA=$2; PROVISION_OPTS_GIVEN=1 ;;
    --memory-high) MEM_HIGH=$2; PROVISION_OPTS_GIVEN=1 ;;
    --memory-max) MEM_MAX=$2; PROVISION_OPTS_GIVEN=1 ;;
    --tasks-max) TASKS_MAX=$2; PROVISION_OPTS_GIVEN=1 ;;
    --allow-local-tcp) LOCAL_TCP=$2; PROVISION_OPTS_GIVEN=1 ;;
  esac
  shift 2
done

# --- environment ------------------------------------------------------------------------------
missing=()
for tool in useradd usermod loginctl systemctl nft getent id install findmnt ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ $APPLY -eq 1 ]]; then
  command -v sudo >/dev/null 2>&1 || missing+=(sudo)
fi
[[ ${#missing[@]} -eq 0 ]] ||
  die "required tool(s) missing: ${missing[*]} (this script needs Linux with systemd, nftables and shadow-utils)"
[[ -z $ROOT || $ROOT == /* ]] || die 'BROKKR_AGENT_ROOT must be an absolute path'
[[ "$(id -u)" =~ ^[0-9]+$ ]] || die 'cannot determine the invoking uid'
[[ "$(id -u)" -ne 0 ]] ||
  die 'refusing to run as root; run as the operator account WITHOUT sudo (privileged steps use sudo per command)'

# --- validation -------------------------------------------------------------------------------
[[ -n $USER_NAME ]] || { usage >&2; die '--user is required'; }
[[ $USER_NAME =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die '--user must match ^[a-z][a-z0-9-]{1,30}$'
[[ $USER_NAME != root ]] || die '--user must not be root'
[[ $USER_NAME != "$(id -un)" ]] || die '--user must not be the invoking operator account'
if [[ $REVOKE -eq 1 && $PROVISION_OPTS_GIVEN -eq 1 ]]; then
  die '--revoke accepts only --user and --apply'
fi

valid_cidr() {
  local item=$1 addr prefix a b c d g
  [[ $item =~ ^[0-9a-fA-F.:]+/[0-9]{1,3}$ ]] || return 1
  addr=${item%/*}
  prefix=$((10#${item#*/}))
  if [[ $addr == *.* ]]; then
    [[ $addr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && $prefix -le 32 ]] || return 1
    IFS=. read -r a b c d <<<"$addr"
    for g in "$a" "$b" "$c" "$d"; do
      [[ $g =~ ^(0|[1-9][0-9]{0,2})$ && $g -le 255 ]] || return 1
    done
  else
    [[ $addr =~ ^[0-9a-fA-F:]+$ && $addr == *:*:* && $addr != *:::* && $prefix -le 128 ]] || return 1
    [[ ! $addr =~ [0-9a-fA-F]{5} ]] || return 1
  fi
}

# Validates a port list and renders it as "a, b-c, d" (decimal, overlap-free) into LOCAL_TCP_RENDERED.
LOCAL_TCP_RENDERED=
render_ports() {
  local list=$1 item lo hi i out=
  local -a items los his
  los=(); his=()
  [[ -n $list && $list != ,* && $list != *, && $list != *,,* ]] || return 1
  IFS=, read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    [[ $item =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ ]] || return 1
    lo=$((10#${item%%-*}))
    hi=$lo
    if [[ $item == *-* ]]; then hi=$((10#${item##*-})); fi
    [[ $lo -ge 1 && $hi -le 65535 && $lo -le $hi ]] || return 1
    i=0
    while [[ $i -lt ${#los[@]} ]]; do
      if [[ $lo -le ${his[$i]} && ${los[$i]} -le $hi ]]; then return 1; fi
      i=$((i + 1))
    done
    los+=("$lo"); his+=("$hi")
    if [[ $lo -eq $hi ]]; then item=$lo; else item="$lo-$hi"; fi
    out+="${out:+, }$item"
  done
  LOCAL_TCP_RENDERED=$out
}

nonzero() { [[ ! $1 =~ ^0+[KMGT%]?$ ]]; }

PUBKEY_B64=
if [[ $REVOKE -eq 0 ]]; then
  [[ -n $PUBKEY_FILE ]] || die '--pubkey is required'
  [[ -n $SSH_FROM ]] || die '--ssh-from is required'
  [[ -f $PUBKEY_FILE && ! -L $PUBKEY_FILE ]] || die '--pubkey must be a regular, non-symlink file'
  lines=$(grep -c '[^[:space:]]' "$PUBKEY_FILE" || true)
  [[ $lines == 1 ]] || die '--pubkey must contain exactly one non-empty line'
  key_line=$(grep '[^[:space:]]' "$PUBKEY_FILE")
  key_re='^ssh-ed25519 AAAA[A-Za-z0-9+/]+={0,2}( .*)?$'
  [[ $key_line =~ $key_re ]] || die '--pubkey must be a single "ssh-ed25519 AAAA..." public key line'
  fingerprint=$(ssh-keygen -lf "$PUBKEY_FILE" 2>/dev/null) || die '--pubkey is rejected by ssh-keygen -lf'
  [[ $fingerprint == *'(ED25519)'* ]] || die '--pubkey is not an ED25519 key'
  key_rest=${key_line#ssh-ed25519 }
  PUBKEY_B64=${key_rest%% *}

  [[ $SSH_FROM != ,* && $SSH_FROM != *, && $SSH_FROM != *,,* ]] || die '--ssh-from has an empty entry'
  IFS=, read -r -a cidr_items <<<"$SSH_FROM"
  for cidr in "${cidr_items[@]}"; do
    valid_cidr "$cidr" || die "--ssh-from entry is not an IPv4/IPv6 CIDR with explicit prefix: $cidr"
  done

  { [[ $MEM_HIGH =~ ^[0-9]+[KMGT]$ ]] && nonzero "$MEM_HIGH"; } || die '--memory-high must look like 20G (non-zero, K/M/G/T)'
  { [[ $MEM_MAX =~ ^[0-9]+[KMGT]$ ]] && nonzero "$MEM_MAX"; } || die '--memory-max must look like 24G (non-zero, K/M/G/T)'
  { [[ $CPU_QUOTA =~ ^[0-9]+%$ ]] && nonzero "$CPU_QUOTA"; } || die '--cpu-quota must look like 2000% (non-zero)'
  { [[ $TASKS_MAX =~ ^[0-9]+$ ]] && nonzero "$TASKS_MAX"; } || die '--tasks-max must be a non-zero integer'
  render_ports "$LOCAL_TCP" ||
    die '--allow-local-tcp must be comma-separated, non-overlapping ports or ranges within 1-65535'
fi

if [[ $APPLY -eq 1 ]]; then
  require_brokkr_deploy_source_binding "$REPO_ROOT" || die 'deployment source binding failed; --apply refused'
fi

# --- derived names and paths ------------------------------------------------------------------
HOME_DIR=/home/$USER_NAME
HOME_PATH=$ROOT$HOME_DIR
SSH_DIR=$HOME_PATH/.ssh
AUTH_FILE=$SSH_DIR/authorized_keys
MARKER_DIR=$ROOT/var/lib/brokkr/agent-account
MARKER=$MARKER_DIR/$USER_NAME.managed
NFT_DIR=$ROOT/etc/brokkr/agent-account
NFT_FILE=$NFT_DIR/$USER_NAME.nft
NFT_TABLE=brokkr_agent_${USER_NAME//-/_}
UNIT_NAME=brokkr-agent-egress-$USER_NAME.service
UNIT_FILE=$ROOT/etc/systemd/system/$UNIT_NAME

UID_NUM=
HOME_FIELD=
U='<uid>' # placeholder shown in a dry-run before the account exists

# --- action helpers ---------------------------------------------------------------------------
step() { printf '\n== %s ==\n' "$*"; }

shq() { # print arguments quoted for human review
  local a sep=
  for a in "$@"; do
    printf '%s' "$sep"
    sep=' '
    if [[ -n $a && $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then printf '%s' "$a"; else printf "'%s'" "$a"; fi
  done
}

run() { # privileged command: executed via sudo on --apply, printed on dry-run
  if [[ $APPLY -eq 1 ]]; then
    sudo "$@"
  else
    printf 'would run: sudo %s\n' "$(shq "$@")"
  fi
}

put_file() { # mode owner group path; content on stdin
  local mode=$1 owner=$2 group=$3 path=$4
  if [[ $APPLY -eq 1 ]]; then
    sudo install -m "$mode" -o "$owner" -g "$group" /dev/stdin "$path"
  else
    printf -- '--- would write %s (mode %s, owner %s:%s) ---\n' "$path" "$mode" "$owner" "$group"
    cat
    printf -- '--- end ---\n'
  fi
}

# --- rendered content -------------------------------------------------------------------------
render_slice() {
  printf '%s\n' '[Slice]' \
    "CPUQuota=$CPU_QUOTA" 'CPUWeight=20' 'IOWeight=20' \
    "MemoryHigh=$MEM_HIGH" "MemoryMax=$MEM_MAX" 'MemorySwapMax=0' "TasksMax=$TASKS_MAX"
}

render_nft() {
  local t=$'\t' skuid="meta skuid $U fib daddr type local"
  printf '%s\n' '#!/usr/sbin/nft -f' \
    "table inet $NFT_TABLE" \
    "delete table inet $NFT_TABLE" \
    "table inet $NFT_TABLE {" \
    "${t}chain output {" \
    "${t}${t}type filter hook output priority filter; policy accept;" \
    "${t}${t}$skuid udp dport 53 accept" \
    "${t}${t}$skuid tcp dport 53 accept" \
    "${t}${t}$skuid tcp dport { $LOCAL_TCP_RENDERED } accept" \
    "${t}${t}$skuid counter reject" \
    "${t}${t}meta skuid $U ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter reject" \
    "${t}${t}meta skuid $U ip6 daddr { fc00::/7, fe80::/10 } counter reject" \
    "${t}}" \
    '}'
}

render_unit() {
  printf '%s\n' '[Unit]' \
    "Description=Brokkr egress isolation for agent account $USER_NAME" \
    "Before=user@$U.service systemd-user-sessions.service" \
    'DefaultDependencies=no' \
    'After=local-fs.target' \
    '' '[Service]' \
    'Type=oneshot' 'RemainAfterExit=yes' \
    "ExecStart=/usr/sbin/nft -f /etc/brokkr/agent-account/$USER_NAME.nft" \
    "ExecStop=/usr/sbin/nft delete table inet $NFT_TABLE" \
    '' '[Install]' 'WantedBy=multi-user.target'
}

render_authorized_keys() {
  printf 'from="%s",no-agent-forwarding,no-X11-forwarding ssh-ed25519 %s brokkr-agent-account\n' \
    "$SSH_FROM" "$PUBKEY_B64"
}

# --- account state ----------------------------------------------------------------------------
read_account() { # sets UID_NUM and HOME_FIELD; fails if the account does not exist
  local pw
  pw=$(getent passwd "$USER_NAME") || return 1
  IFS=: read -r _ _ UID_NUM _ _ HOME_FIELD _ <<<"$pw"
  [[ $UID_NUM =~ ^[0-9]+$ ]] || fatal "getent returned a non-numeric uid for $USER_NAME"
}

require_home() {
  [[ $HOME_FIELD == "$HOME_DIR" ]] ||
    die "account $USER_NAME has home '$HOME_FIELD', expected $HOME_DIR; refusing"
}

require_marker() {
  [[ -f $MARKER && ! -L $MARKER ]] ||
    die "account $USER_NAME exists but is not managed by this script (missing marker $MARKER); refusing to adopt it"
  [[ "$(<"$MARKER")" == "$UID_NUM" ]] ||
    die "marker $MARKER does not match uid $UID_NUM of $USER_NAME; refusing"
}

require_uid_floor() {
  [[ $UID_NUM -ge 1000 ]] || die "account $USER_NAME has uid $UID_NUM (< 1000); refusing"
}

check_groups() { # fail closed on ANY supplementary group; never removes groups automatically
  local groups
  groups=$(id -nG "$USER_NAME") || fatal "cannot read group membership of $USER_NAME"
  [[ $groups == "$USER_NAME" ]] ||
    die "account $USER_NAME must belong only to its own group, found: $groups (remove the extra groups manually)"
}

EXISTS=0
if read_account; then
  EXISTS=1
  require_marker
  require_uid_floor
  require_home
  U=$UID_NUM
  if [[ $REVOKE -eq 0 ]]; then check_groups; fi
elif [[ $REVOKE -eq 1 ]]; then
  die "account $USER_NAME does not exist; nothing to revoke"
elif getent group "$USER_NAME" >/dev/null 2>&1; then
  die "group $USER_NAME already exists without a matching account; refusing"
fi

print_mode() {
  if [[ $APPLY -eq 1 ]]; then
    echo "brokkr agent account: APPLY for $USER_NAME"
  else
    echo "brokkr agent account: DRY-RUN for $USER_NAME (nothing is changed; re-run with --apply)"
  fi
}

# --- revoke -----------------------------------------------------------------------------------
revoke() {
  local out
  print_mode
  step 'revoke: remove SSH access, linger and logins (isolation stays in force)'
  run install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$SSH_DIR"
  run install -m 0600 -o "$USER_NAME" -g "$USER_NAME" /dev/null "$AUTH_FILE"
  run loginctl disable-linger "$USER_NAME"
  run usermod --lock --expiredate 1 "$USER_NAME"
  if [[ $APPLY -eq 1 ]]; then
    if ! out=$(sudo loginctl terminate-user "$USER_NAME" 2>&1); then
      case $out in
        *'not logged in'*) echo "terminate-user: $USER_NAME has no sessions" ;;
        *) fatal "loginctl terminate-user failed: $out" ;;
      esac
    fi
  else
    echo "would run: sudo loginctl terminate-user $USER_NAME (a 'not logged in' failure is ignored)"
  fi
  cat <<EOF

Not removed (isolation must stay in force while the account exists): the account, its home,
$UNIT_FILE, $NFT_FILE, the user-$U.slice drop-in and the marker.
Full removal is manual and destructive. After reviewing the home directory, run:
  sudo systemctl disable --now $UNIT_NAME
  sudo userdel -r $USER_NAME
  sudo rm -f $UNIT_FILE $NFT_FILE $MARKER
  sudo rm -rf $ROOT/etc/systemd/system/user-$U.slice.d
  sudo systemctl daemon-reload
EOF
}

if [[ $REVOKE -eq 1 ]]; then
  revoke
  exit 0
fi

# --- provision --------------------------------------------------------------------------------
print_mode
echo "target: user=$USER_NAME home=$HOME_DIR ssh-from=$SSH_FROM"
echo "budget: CPUQuota=$CPU_QUOTA MemoryHigh=$MEM_HIGH MemoryMax=$MEM_MAX TasksMax=$TASKS_MAX"
echo "egress: local TCP allowlist { $LOCAL_TCP_RENDERED }"

step '1. account'
if [[ $EXISTS -eq 1 ]]; then
  echo "account exists (uid $UID_NUM, managed); re-enabling in case it was revoked"
  run usermod -p '*' --expiredate '' "$USER_NAME"
  run chmod 0700 "$HOME_PATH"
else
  run useradd --create-home --home-dir "$HOME_DIR" --shell /bin/bash --user-group "$USER_NAME"
  if [[ $APPLY -eq 1 ]]; then
    read_account || fatal "account $USER_NAME not found after useradd"
    U=$UID_NUM
  fi
  # Marker first: a failure after useradd must not strand an unmanaged account.
  run install -d -m 0755 -o root -g root "$MARKER_DIR"
  printf '%s\n' "$U" | put_file 0644 root root "$MARKER"
  if [[ $APPLY -eq 1 ]]; then
    require_uid_floor
    require_home
  fi
  run usermod -p '*' "$USER_NAME"
  run chmod 0700 "$HOME_PATH"
fi

step '2. group membership (must be only its own group)'
if [[ $APPLY -eq 1 ]]; then
  check_groups
  echo "ok: $(id -nG "$USER_NAME")"
else
  echo "would verify: id -nG $USER_NAME is exactly '$USER_NAME'"
fi

SLICE_UNIT=user-$U.slice
SLICE_FILE=$ROOT/etc/systemd/system/$SLICE_UNIT.d/70-brokkr-agent-account.conf

step "3. resource slice $SLICE_UNIT"
run install -d -m 0755 -o root -g root "$(dirname "$SLICE_FILE")"
render_slice | put_file 0644 root root "$SLICE_FILE"
run systemctl daemon-reload
SLICE_PROPS=("CPUQuota=$CPU_QUOTA" CPUWeight=20 IOWeight=20 "MemoryHigh=$MEM_HIGH" "MemoryMax=$MEM_MAX" MemorySwapMax=0 "TasksMax=$TASKS_MAX")
if [[ $APPLY -eq 1 ]]; then
  if systemctl is-active --quiet "$SLICE_UNIT"; then
    sudo systemctl set-property --runtime "$SLICE_UNIT" "${SLICE_PROPS[@]}"
  else
    echo "$SLICE_UNIT is not active; the drop-in applies when the user manager starts"
  fi
else
  echo "if $SLICE_UNIT is active, would also run: sudo systemctl set-property --runtime $SLICE_UNIT ${SLICE_PROPS[*]}"
fi

step "4. egress isolation ($NFT_TABLE), loaded BEFORE any SSH key or linger"
run install -d -m 0755 -o root -g root "$NFT_DIR"
if [[ $APPLY -eq 1 ]]; then
  render_nft | put_file 0644 root root "$NFT_FILE.new"
  if ! sudo nft -c -f "$NFT_FILE.new"; then
    sudo rm -f "$NFT_FILE.new"
    fatal 'nft rejected the ruleset; nothing was enabled and no SSH key was written'
  fi
  sudo mv -f "$NFT_FILE.new" "$NFT_FILE"
else
  render_nft | put_file 0644 root root "$NFT_FILE"
  echo "would stage as $NFT_FILE.new, validate with 'sudo nft -c -f', then move into place"
fi
render_unit | put_file 0644 root root "$UNIT_FILE"
run systemctl daemon-reload
UNIT_WAS_ACTIVE=0
if [[ $APPLY -eq 1 ]] && systemctl is-active --quiet "$UNIT_NAME"; then UNIT_WAS_ACTIVE=1; fi
run systemctl enable --now "$UNIT_NAME"
if [[ $APPLY -eq 0 ]]; then
  echo "if $UNIT_NAME was already active, would also run: sudo systemctl restart $UNIT_NAME"
elif [[ $UNIT_WAS_ACTIVE -eq 1 ]]; then
  sudo systemctl restart "$UNIT_NAME"
fi
if [[ $APPLY -eq 1 ]]; then
  systemctl is-active --quiet "$UNIT_NAME" || fatal "$UNIT_NAME is not active; no SSH key was written"
  table_out=$(sudo nft list table inet "$NFT_TABLE") ||
    fatal "nft table $NFT_TABLE is not loaded; no SSH key was written"
  [[ $table_out == *reject* ]] || fatal "nft table $NFT_TABLE has no reject rules; no SSH key was written"
else
  echo "would verify: sudo nft list table inet $NFT_TABLE"
fi

step '5. SSH access (this script owns and overwrites authorized_keys)'
run install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$SSH_DIR"
render_authorized_keys | put_file 0600 "$USER_NAME" "$USER_NAME" "$AUTH_FILE"

step '6. linger'
run loginctl enable-linger "$USER_NAME"

step 'summary'
proc_opts=$(findmnt -no OPTIONS /proc 2>/dev/null || true)
case ",$proc_opts," in
  *,hidepid=1,*|*,hidepid=2,*|*,hidepid=invisible,*|*,hidepid=ptraceable,*)
    echo "/proc is mounted with hidepid: other users' process arguments are hidden" ;;
  *) echo "note: /proc is mounted without hidepid; process arguments of other users stay visible to the agent" ;;
esac
echo "uid=$U slice-dropin=$SLICE_FILE"
if [[ $APPLY -eq 1 ]]; then
  echo "egress unit $UNIT_NAME: $(systemctl is-active "$UNIT_NAME" || true)"
else
  echo "egress unit $UNIT_NAME: unchanged (dry-run)"
fi
echo "next steps: verify as the agent account (blocked local ports, allowed internet, slice limits); see docs/agent-account.md"
