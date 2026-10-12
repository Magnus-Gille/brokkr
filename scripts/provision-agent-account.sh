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
# Fail-closed design: the account stays expired until every protection is in place and verified;
# its only SSH key is served from /run by the egress unit, so no loaded ruleset means no login;
# root never writes inside the agent's home.
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
for tool in useradd usermod loginctl systemctl nft getent id install findmnt ssh-keygen sshd; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ $APPLY -eq 1 ]]; then
  command -v sudo >/dev/null 2>&1 || missing+=(sudo)
fi
[[ ${#missing[@]} -eq 0 ]] ||
  die "required tool(s) missing: ${missing[*]} (this script needs Linux with systemd, nftables, OpenSSH and shadow-utils)"
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

valid_ipv6() { # structural check: hex groups of 1-4 digits, eight of them or at most one "::"
  local addr=$1 head tail half group count=0
  local -a groups
  [[ $addr =~ ^[0-9a-fA-F:]+$ && $addr != *:::* ]] || return 1
  if [[ $addr == *::* ]]; then
    head=${addr%%::*}
    tail=${addr#*::}
    [[ $tail != *::* ]] || return 1
  else
    head=$addr
    tail=
  fi
  for half in "$head" "$tail"; do
    [[ -n $half ]] || continue
    [[ $half != :* && $half != *: ]] || return 1
    IFS=: read -r -a groups <<<"$half"
    for group in "${groups[@]}"; do
      [[ $group =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
  done
  if [[ $addr == *::* ]]; then [[ $count -le 7 ]]; else [[ $count -eq 8 ]]; fi
}

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
    [[ $prefix -le 128 ]] && valid_ipv6 "$addr"
  fi
}

# Validates a port list and renders it as "a, b-c, d" (decimal, overlap-free) into LOCAL_TCP_RENDERED.
LOCAL_TCP_RENDERED=
render_ports() {
  local list=$1 item lo hi i out=
  local -a items los his
  los=(); his=()
  [[ $list =~ ^[0-9,-]+$ && $list != ,* && $list != *, && $list != *,,* ]] || return 1
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

to_bytes() { # 1-6 digits plus K/M/G/T; bounded so the arithmetic cannot overflow
  local value=$1 number unit
  [[ $value =~ ^[1-9][0-9]{0,5}[KMGT]$ ]] || return 1
  number=${value%?}
  unit=${value: -1}
  case $unit in
    K) echo $((number * 1024)) ;;
    M) echo $((number * 1024 * 1024)) ;;
    G) echo $((number * 1024 * 1024 * 1024)) ;;
    T) echo $((number * 1024 * 1024 * 1024 * 1024)) ;;
  esac
}

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

  # Character allowlist first: the whole string is rendered into the key file, so no newline,
  # quote or option syntax may survive validation.
  [[ $SSH_FROM =~ ^[0-9a-fA-F.:/,]+$ ]] || die '--ssh-from may contain only CIDR characters and commas'
  [[ $SSH_FROM != ,* && $SSH_FROM != *, && $SSH_FROM != *,,* ]] || die '--ssh-from has an empty entry'
  IFS=, read -r -a cidr_items <<<"$SSH_FROM"
  for cidr in "${cidr_items[@]}"; do
    valid_cidr "$cidr" || die "--ssh-from entry is not an IPv4/IPv6 CIDR with explicit prefix: $cidr"
  done

  MEM_HIGH_BYTES=$(to_bytes "$MEM_HIGH") || die '--memory-high must look like 20G (1-6 digits, K/M/G/T)'
  MEM_MAX_BYTES=$(to_bytes "$MEM_MAX") || die '--memory-max must look like 24G (1-6 digits, K/M/G/T)'
  [[ $MEM_HIGH_BYTES -le $MEM_MAX_BYTES ]] || die '--memory-high must not exceed --memory-max'
  [[ $CPU_QUOTA =~ ^[1-9][0-9]{0,4}%$ ]] || die '--cpu-quota must look like 2000% (1-99999%)'
  [[ $TASKS_MAX =~ ^[1-9][0-9]{0,6}$ ]] || die '--tasks-max must be an integer from 1 to 9999999'
  render_ports "$LOCAL_TCP" ||
    die '--allow-local-tcp must be comma-separated, non-overlapping ports or ranges within 1-65535'
  [[ -d $ROOT/etc/ssh/sshd_config.d && ! -L $ROOT/etc/ssh/sshd_config.d ]] ||
    die '/etc/ssh/sshd_config.d is missing; this script needs an sshd that includes drop-ins'
fi

if [[ $APPLY -eq 1 ]]; then
  require_brokkr_deploy_source_binding "$REPO_ROOT" || die 'deployment source binding failed; --apply refused'
fi

# --- derived names and paths ------------------------------------------------------------------
HOME_DIR=/home/$USER_NAME
HOME_PATH=$ROOT$HOME_DIR
CONF_DIR=$ROOT/etc/brokkr/agent-account
NFT_FILE=$CONF_DIR/$USER_NAME.nft
# The persistent key is root-owned and outside the agent's home. sshd reads only the copy the
# egress unit places in /run after its ruleset loaded, so root never writes where the agent can
# redirect it, the agent cannot add keys or drop the from= restriction, and no ruleset means no key.
KEYS_FILE=$CONF_DIR/$USER_NAME.keys
RUN_KEYS_DIR=/run/brokkr-agent-keys
RUN_KEY=$RUN_KEYS_DIR/$USER_NAME
SSHD_DROPIN=$ROOT/etc/ssh/sshd_config.d/70-brokkr-agent-$USER_NAME.conf
MARKER_DIR=$ROOT/var/lib/brokkr/agent-account
MARKER=$MARKER_DIR/$USER_NAME.managed
NFT_TABLE=brokkr_agent_${USER_NAME//-/_}
UNIT_NAME=brokkr-agent-egress-$USER_NAME.service
UNIT_FILE=$ROOT/etc/systemd/system/$UNIT_NAME
CRON_DENY=$ROOT/etc/cron.deny
AT_DENY=$ROOT/etc/at.deny

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
  local t=$'\t' m="meta skuid $U"
  printf '%s\n' '#!/usr/sbin/nft -f' \
    "table inet $NFT_TABLE" \
    "delete table inet $NFT_TABLE" \
    "table inet $NFT_TABLE {" \
    "${t}chain output {" \
    "${t}${t}type filter hook output priority filter; policy accept;" \
    "${t}${t}$m ct state established,related accept" \
    "${t}${t}$m fib daddr type local udp dport 53 accept" \
    "${t}${t}$m fib daddr type local tcp dport 53 accept" \
    "${t}${t}$m ip daddr 127.0.0.0/8 tcp dport { $LOCAL_TCP_RENDERED } accept" \
    "${t}${t}$m ip6 daddr ::1 tcp dport { $LOCAL_TCP_RENDERED } accept" \
    "${t}${t}$m fib daddr type local counter reject" \
    "${t}${t}$m ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } counter reject" \
    "${t}${t}$m ip6 daddr { fc00::/7, fe80::/10, ff00::/8 } counter reject" \
    "${t}}" \
    '}'
}

render_unit() {
  local install='/usr/bin/install -m 0644 -o root -g root'
  printf '%s\n' '[Unit]' \
    "Description=Brokkr egress isolation and SSH key gate for agent account $USER_NAME" \
    'DefaultDependencies=no' \
    'After=local-fs.target nftables.service' \
    "Before=user@$U.service systemd-user-sessions.service" \
    'PartOf=nftables.service' \
    'ReloadPropagatedFrom=nftables.service' \
    '' '[Service]' \
    'Type=oneshot' 'RemainAfterExit=yes' \
    "ExecStart=/usr/sbin/nft -f /etc/brokkr/agent-account/$USER_NAME.nft" \
    "ExecStartPost=/usr/bin/install -d -m 0755 -o root -g root $RUN_KEYS_DIR" \
    "ExecStartPost=$install /etc/brokkr/agent-account/$USER_NAME.keys $RUN_KEY" \
    "ExecReload=/usr/sbin/nft -f /etc/brokkr/agent-account/$USER_NAME.nft" \
    "ExecReload=$install /etc/brokkr/agent-account/$USER_NAME.keys $RUN_KEY" \
    '# Stopping keeps the table (isolation stays) and withdraws the key (no new logins).' \
    "ExecStopPost=/usr/bin/rm -f $RUN_KEY" \
    '' '[Install]' 'WantedBy=multi-user.target'
}

render_user_manager_dropin() {
  printf '%s\n' '[Unit]' "Requires=$UNIT_NAME" "After=$UNIT_NAME"
}

render_sshd_dropin() {
  printf '%s\n' "Match User $USER_NAME" \
    "    AuthorizedKeysFile $RUN_KEYS_DIR/%u" \
    '    AuthenticationMethods publickey' \
    '    PasswordAuthentication no' \
    '    KbdInteractiveAuthentication no' \
    '    PermitUserRC no' \
    '    AllowAgentForwarding no' \
    '    X11Forwarding no' \
    '    PermitTunnel no' \
    '    GatewayPorts no' \
    'Match all'
}

# Effective policy sshd must report for the account (sshd -T lowercases keywords).
SSHD_EXPECT=(
  "authorizedkeysfile $RUN_KEYS_DIR/%u"
  'authenticationmethods publickey'
  'passwordauthentication no'
  'kbdinteractiveauthentication no'
  'permituserrc no'
  'allowagentforwarding no'
  'x11forwarding no'
  'permittunnel no'
  'gatewayports no'
)

render_keys() {
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

check_subids() { # subordinate IDs would let newuidmap/rootless containers run under other uids
  local file
  for file in "$ROOT/etc/subuid" "$ROOT/etc/subgid"; do
    if [[ -f $file ]] && grep -qE "^($USER_NAME|$UID_NUM):" "$file"; then
      die "account $USER_NAME has subordinate IDs in $file; processes under those uids would bypass the per-uid egress rules (remove them with usermod --del-subuids/--del-subgids)"
    fi
  done
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
  if [[ $REVOKE -eq 0 ]]; then check_groups; check_subids; fi
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
REVOKE_FAILURES=()
attempt() { # revoke step: every step runs even if an earlier one failed
  if [[ $APPLY -eq 1 ]]; then
    if ! sudo "$@"; then REVOKE_FAILURES+=("$(shq "$@")"); fi
  else
    printf 'would run: sudo %s\n' "$(shq "$@")"
  fi
}

revoke() {
  local out
  print_mode
  step 'revoke: expire first, then withdraw keys, linger and sessions (isolation stays in force)'
  attempt usermod --lock --expiredate 1 "$USER_NAME"
  attempt install -m 0644 -o root -g root /dev/null "$KEYS_FILE"
  attempt rm -f "$ROOT$RUN_KEY"
  attempt loginctl disable-linger "$USER_NAME"
  if [[ $APPLY -eq 1 ]]; then
    if ! out=$(sudo loginctl terminate-user "$USER_NAME" 2>&1); then
      case $out in
        *'not logged in'*) echo "terminate-user: $USER_NAME has no sessions" ;;
        *) REVOKE_FAILURES+=("loginctl terminate-user $USER_NAME: $out") ;;
      esac
    fi
  else
    echo "would run: sudo loginctl terminate-user $USER_NAME (a 'not logged in' failure is ignored)"
  fi
  cat <<EOF

Not removed (isolation must stay in force while the account exists): the account, its home,
$UNIT_FILE, $NFT_FILE, $SSHD_DROPIN, the user@$U.service and user-$U.slice drop-ins and the marker.
Full removal is manual and destructive. After reviewing the home directory, run:
  sudo systemctl disable --now $UNIT_NAME
  sudo userdel -r $USER_NAME
  sudo nft delete table inet $NFT_TABLE
  sudo rm -f $UNIT_FILE $NFT_FILE $KEYS_FILE $SSHD_DROPIN $MARKER
  sudo rm -rf $ROOT/etc/systemd/system/user-$U.slice.d $ROOT/etc/systemd/system/user@$U.service.d
  sudo sed -i '/^$USER_NAME\$/d' $CRON_DENY $AT_DENY
  sudo systemctl daemon-reload
EOF
  if [[ ${#REVOKE_FAILURES[@]} -gt 0 ]]; then
    printf 'brokkr agent account: revoke step failed: %s\n' "${REVOKE_FAILURES[@]}" >&2
    exit 1
  fi
}

if [[ $REVOKE -eq 1 ]]; then
  revoke
  exit 0
fi

# --- provision --------------------------------------------------------------------------------
print_mode
echo "target: user=$USER_NAME home=$HOME_DIR ssh-from=$SSH_FROM"
echo "budget: CPUQuota=$CPU_QUOTA MemoryHigh=$MEM_HIGH MemoryMax=$MEM_MAX TasksMax=$TASKS_MAX"
echo "egress: loopback TCP allowlist { $LOCAL_TCP_RENDERED }"

step '1. account (kept expired until every protection is verified)'
if [[ $EXISTS -eq 1 ]]; then
  echo "account exists (uid $UID_NUM, managed)"
  run usermod --expiredate 1 "$USER_NAME"
else
  # No subordinate ID ranges: the per-uid egress rules must cover every process the account runs.
  run useradd --create-home --home-dir "$HOME_DIR" --shell /bin/bash --user-group --expiredate 1 \
    -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 "$USER_NAME"
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
fi
# /home is root-owned, so the agent cannot swap its home directory for a symlink.
run chmod 0700 "$HOME_PATH"

step '2. group membership and subordinate IDs'
if [[ $APPLY -eq 1 ]]; then
  check_groups
  check_subids
  echo "ok: groups '$(id -nG "$USER_NAME")', no subordinate IDs"
else
  echo "would verify: id -nG $USER_NAME is exactly '$USER_NAME' and it has no /etc/subuid or /etc/subgid range"
fi

SLICE_UNIT=user-$U.slice
SLICE_FILE=$ROOT/etc/systemd/system/$SLICE_UNIT.d/70-brokkr-agent-account.conf
CGROUP_DIR=$ROOT/sys/fs/cgroup/user.slice/$SLICE_UNIT

step "3. resource slice $SLICE_UNIT"
run install -d -m 0755 -o root -g root "$(dirname "$SLICE_FILE")"
render_slice | put_file 0644 root root "$SLICE_FILE"
run systemctl daemon-reload
SLICE_PROPS=("CPUQuota=$CPU_QUOTA" CPUWeight=20 IOWeight=20 "MemoryHigh=$MEM_HIGH" "MemoryMax=$MEM_MAX" MemorySwapMax=0 "TasksMax=$TASKS_MAX")
if [[ $APPLY -eq 1 ]]; then
  if systemctl is-active --quiet "$SLICE_UNIT"; then
    sudo systemctl set-property --runtime "$SLICE_UNIT" "${SLICE_PROPS[@]}"
  else
    sudo systemctl start "$SLICE_UNIT"
  fi
  # Read the kernel's effective limits back; systemd ignores directives it cannot apply.
  page_floor() { echo $(( $1 - $1 % 4096 )); }
  read_cg() { [[ -r $CGROUP_DIR/$1 ]] && cat "$CGROUP_DIR/$1"; }
  cg_max=$(read_cg memory.max) || fatal "cannot read $CGROUP_DIR/memory.max"
  cg_high=$(read_cg memory.high) || fatal "cannot read $CGROUP_DIR/memory.high"
  cg_swap=$(read_cg memory.swap.max) || fatal "cannot read $CGROUP_DIR/memory.swap.max"
  cg_pids=$(read_cg pids.max) || fatal "cannot read $CGROUP_DIR/pids.max"
  cg_cpu=$(read_cg cpu.max) || fatal "cannot read $CGROUP_DIR/cpu.max"
  read -r cpu_quota cpu_period <<<"$cg_cpu"
  [[ $cg_max == "$(page_floor "$MEM_MAX_BYTES")" ]] || fatal "memory.max is '$cg_max', expected $MEM_MAX ($MEM_MAX_BYTES bytes)"
  [[ $cg_high == "$(page_floor "$MEM_HIGH_BYTES")" ]] || fatal "memory.high is '$cg_high', expected $MEM_HIGH"
  [[ $cg_swap == 0 ]] || fatal "memory.swap.max is '$cg_swap', expected 0"
  [[ $cg_pids == "$TASKS_MAX" ]] || fatal "pids.max is '$cg_pids', expected $TASKS_MAX"
  [[ $cpu_quota =~ ^[0-9]+$ && $cpu_period =~ ^[0-9]+$ &&
    $((cpu_quota * 100)) -eq $((${CPU_QUOTA%\%} * cpu_period)) ]] ||
    fatal "cpu.max is '$cg_cpu', expected $CPU_QUOTA"
  echo "ok: effective limits memory.max=$cg_max memory.high=$cg_high pids.max=$cg_pids cpu.max=$cg_cpu"
else
  echo "would start or update $SLICE_UNIT (set-property --runtime ${SLICE_PROPS[*]}) and verify memory.max, memory.high, memory.swap.max, pids.max and cpu.max under $CGROUP_DIR"
fi

step "4. egress isolation ($NFT_TABLE) and SSH key gate"
run install -d -m 0755 -o root -g root "$CONF_DIR"
render_keys | put_file 0644 root root "$KEYS_FILE"
if [[ $APPLY -eq 1 ]]; then
  render_nft | put_file 0644 root root "$NFT_FILE.new"
  if ! sudo nft -c -f "$NFT_FILE.new"; then
    sudo rm -f "$NFT_FILE.new"
    fatal 'nft rejected the ruleset; nothing was enabled and the account stays expired'
  fi
  sudo mv -f "$NFT_FILE.new" "$NFT_FILE"
else
  render_nft | put_file 0644 root root "$NFT_FILE"
  echo "would stage as $NFT_FILE.new, validate with 'sudo nft -c -f', then move into place"
fi
render_unit | put_file 0644 root root "$UNIT_FILE"
USER_MANAGER_DROPIN=$ROOT/etc/systemd/system/user@$U.service.d/70-brokkr-agent-egress.conf
run install -d -m 0755 -o root -g root "$(dirname "$USER_MANAGER_DROPIN")"
render_user_manager_dropin | put_file 0644 root root "$USER_MANAGER_DROPIN"
run systemctl daemon-reload
UNIT_WAS_ACTIVE=0
if [[ $APPLY -eq 1 ]] && systemctl is-active --quiet "$UNIT_NAME"; then UNIT_WAS_ACTIVE=1; fi
run systemctl enable --now "$UNIT_NAME"
if [[ $APPLY -eq 0 ]]; then
  echo "if $UNIT_NAME was already active, would also run: sudo systemctl reload $UNIT_NAME"
elif [[ $UNIT_WAS_ACTIVE -eq 1 ]]; then
  # The ruleset file replaces the table in one nft transaction, so a reload never leaves a gap.
  sudo systemctl reload "$UNIT_NAME"
fi
if [[ $APPLY -eq 1 ]]; then
  systemctl is-active --quiet "$UNIT_NAME" || fatal "$UNIT_NAME is not active; the account stays expired"
  table_out=$(sudo nft list table inet "$NFT_TABLE") ||
    fatal "nft table $NFT_TABLE is not loaded; the account stays expired"
  [[ $table_out == *reject* ]] || fatal "nft table $NFT_TABLE has no reject rules; the account stays expired"
  sudo cmp -s "$KEYS_FILE" "$ROOT$RUN_KEY" || fatal "the egress unit did not publish $RUN_KEY; the account stays expired"
else
  echo "would verify: sudo nft list table inet $NFT_TABLE, and that $RUN_KEY matches $KEYS_FILE"
fi

step '5. cron and at (their jobs run outside the user slice, so the account may not schedule any)'
if [[ $APPLY -eq 1 ]]; then
  for allow in "$ROOT/etc/cron.allow" "$ROOT/etc/at.allow"; do
    if sudo grep -qxF -- "$USER_NAME" "$allow" 2>/dev/null; then
      fatal "$USER_NAME is listed in $allow; remove it (the account stays expired)"
    fi
  done
  if sudo test -e "$ROOT/var/spool/cron/crontabs/$USER_NAME"; then
    fatal "$USER_NAME already has a crontab; review and remove it (the account stays expired)"
  fi
  for deny in "$CRON_DENY" "$AT_DENY"; do
    if sudo grep -qxF -- "$USER_NAME" "$deny" 2>/dev/null; then
      echo "$USER_NAME is already listed in $deny"
    else
      # Never glue the name onto an unterminated last line ($(...) strips a trailing newline).
      {
        if sudo test -s "$deny" && [[ -n "$(sudo tail -c 1 "$deny")" ]]; then printf '\n'; fi
        printf '%s\n' "$USER_NAME"
      } | sudo tee -a "$deny" >/dev/null
      sudo grep -qxF -- "$USER_NAME" "$deny" ||
        fatal "could not list $USER_NAME in $deny; the account stays expired"
    fi
  done
else
  echo "would refuse if $USER_NAME is in cron.allow/at.allow or already has a crontab"
  echo "would ensure $USER_NAME is listed once in $CRON_DENY and $AT_DENY"
fi

step '6. sshd policy (Match block serving only the gated key)'
restore_sshd_dropin() { # a rejected drop-in must not stay installed (a later sshd restart would fail)
  if [[ -n ${SSHD_BACKUP:-} ]]; then sudo mv -f "$SSHD_BACKUP" "$SSHD_DROPIN"; else sudo rm -f "$SSHD_DROPIN"; fi
}
if [[ $APPLY -eq 1 ]]; then
  SSHD_BACKUP=
  if sudo test -e "$SSHD_DROPIN"; then
    SSHD_BACKUP=$SSHD_DROPIN.previous
    sudo cp -a "$SSHD_DROPIN" "$SSHD_BACKUP"
  fi
  # Stage beside the target; the .new name does not match the *.conf include pattern.
  render_sshd_dropin | put_file 0644 root root "$SSHD_DROPIN.new"
  sudo mv -f "$SSHD_DROPIN.new" "$SSHD_DROPIN"
  if ! sudo sshd -t; then
    restore_sshd_dropin
    fatal 'sshd rejected the configuration; the previous drop-in state was restored and sshd was not reloaded'
  fi
  sshd_policy=$(sudo sshd -T -C "user=$USER_NAME,host=localhost,addr=127.0.0.1") || {
    restore_sshd_dropin
    fatal 'sshd -T failed; the previous drop-in state was restored and sshd was not reloaded'
  }
  for want in "${SSHD_EXPECT[@]}"; do
    if ! grep -qxF -- "$want" <<<"$sshd_policy"; then
      restore_sshd_dropin
      fatal "sshd policy for $USER_NAME is not effective (missing '$want'; is sshd_config.d included, or does an earlier rule override it?); previous drop-in restored"
    fi
  done
  [[ -z $SSHD_BACKUP ]] || sudo rm -f "$SSHD_BACKUP"
  sudo systemctl try-reload-or-restart ssh.service
else
  render_sshd_dropin | put_file 0644 root root "$SSHD_DROPIN"
  echo "would validate with 'sudo sshd -t' and 'sudo sshd -T -C user=$USER_NAME,...' (restoring the previous drop-in on failure), then: sudo systemctl try-reload-or-restart ssh.service"
fi

step '7. enable the account and linger (only after steps 1-6 passed)'
run usermod -p '*' --expiredate '' "$USER_NAME"
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
