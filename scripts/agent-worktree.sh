#!/usr/bin/env bash
# Create a disk-backed, per-agent Git worktree without changing Git configuration.

set -euo pipefail

die() {
  printf 'agent-worktree: error: %s\n' "$*" >&2
  exit 64
}

usage() {
  cat <<'EOF'
Usage: agent-worktree.sh --repo PATH --name NAME --branch BRANCH [--ref REF]

Create a Git worktree under the disk-backed Brokkr worktree root.

Options:
  --repo PATH       Existing non-bare Git worktree or repository
  --name NAME       Simple worktree name: letters, digits, ., _, and -
  --branch BRANCH   New branch name accepted by git check-ref-format --branch
  --ref REF         Commit-ish to check out (default: HEAD)
  --help            Show this help
EOF
}

canonical_dir() {
  local path=$1
  if ! [ -d "$path" ]; then
    return 1
  fi
  (cd -P -- "$path" && pwd -P)
}

filesystem_type() {
  local path=$1
  local fs_type

  command -v stat >/dev/null 2>&1 || die 'GNU stat is required for filesystem safety checks'
  if ! fs_type=$(stat -f -c %T -- "$path" 2>/dev/null); then
    die "could not determine filesystem type for $path"
  fi
  case "$fs_type" in
    '') die "filesystem probe returned no type for $path" ;;
    *[!A-Za-z0-9_./-]*) die "filesystem probe returned an invalid type for $path" ;;
    tmpfs|ramfs|hugetlbfs) die "refusing memory-backed filesystem $fs_type at $path" ;;
  esac
  printf '%s\n' "$fs_type"
}

nearest_existing_parent() {
  local candidate=$1
  local parent

  while [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; do
    parent=$(dirname -- "$candidate")
    [ "$parent" != "$candidate" ] || die "could not find an existing parent for $candidate"
    candidate=$parent
  done
  printf '%s\n' "$candidate"
}

check_final_root() {
  local root=$1
  if [ -L "$root" ] || ! [ -d "$root" ] || ! [ -O "$root" ] || ! [ -w "$root" ]; then
    die "worktree root is not a current-user-owned, writable directory: $root"
  fi
  check_directory_permissions "$root"
}

check_directory_permissions() {
  local path=$1
  local mode
  local owner_uid
  local permissions
  local group_permissions
  local other_permissions

  if ! mode=$(stat -c %A -- "$path" 2>/dev/null); then
    die "could not determine permissions for $path"
  fi
  if ! owner_uid=$(stat -c %u -- "$path" 2>/dev/null); then
    die "could not determine owner for $path"
  fi
  case "$mode" in
    d?????????|d?????????@|d?????????+) ;;
    *) die "path is not a directory with standard permissions: $path" ;;
  esac
  permissions=${mode#?}
  group_permissions=${permissions:3:3}
  other_permissions=${permissions:6:3}
  if [[ "$group_permissions" == *w* || "$other_permissions" == *w* ]]; then
    case "$owner_uid:$other_permissions" in
      0:*t|0:*T) ;;
      *) die "path is writable by another user without a sticky root owner: $path" ;;
    esac
  fi
}

check_ancestor_permissions() {
  local path=$1
  local parent

  while :; do
    check_directory_permissions "$path"
    [ "$path" = / ] && break
    parent=$(dirname -- "$path")
    [ "$parent" != "$path" ] || break
    path=$parent
  done
}

common_dir_hash() {
  local common_dir=$1
  local digest

  if command -v sha256sum >/dev/null 2>&1; then
    if ! digest=$(printf '%s' "$common_dir" | sha256sum); then
      die 'could not hash the Git common directory'
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if ! digest=$(printf '%s' "$common_dir" | shasum -a 256); then
      die 'could not hash the Git common directory'
    fi
  else
    die 'sha256sum or shasum is required to namespace worktrees'
  fi
  digest=${digest%% *}
  case "$digest" in
    ''|*[!0-9A-Fa-f]*) die 'hashing the Git common directory returned an invalid digest' ;;
  esac
  printf '%s\n' "${digest:0:16}"
}

repo=''
name=''
branch=''
ref=HEAD

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --repo)
      [ "$#" -ge 2 ] || die '--repo requires a path'
      repo=$2
      shift 2
      ;;
    --name)
      [ "$#" -ge 2 ] || die '--name requires a value'
      name=$2
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || die '--branch requires a value'
      branch=$2
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || die '--ref requires a value'
      ref=$2
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$repo" ] || die '--repo is required'
[ -n "$name" ] || die '--name is required'
[ -n "$branch" ] || die '--branch is required'
[ -d "$repo" ] || die "repository is not a directory: $repo"

case "$name" in
  .|..|''|*[!A-Za-z0-9._-]*)
    die "invalid worktree name: $name"
    ;;
esac

if ! git -C "$repo" check-ref-format --branch "$branch" >/dev/null 2>&1; then
  die "invalid branch name: $branch"
fi

is_bare=$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null) \
  || die "could not inspect repository: $repo"
[ "$is_bare" = false ] || die "bare repositories are not supported: $repo"
repo_top=$(git -C "$repo" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) \
  || die "could not resolve repository: $repo"
common_dir=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "could not resolve Git common directory: $repo"
common_dir=$(canonical_dir "$common_dir") \
  || die "Git common directory is not a directory: $common_dir"
repo_top=$(canonical_dir "$repo_top") \
  || die "repository root is not a directory: $repo_top"
common_parent=$(canonical_dir "$(dirname -- "$common_dir")") \
  || die "Git common directory parent is not a directory: $common_dir"
repo_base=$(basename -- "$common_parent")
namespace_hash=$(common_dir_hash "$common_dir")

commit=$(git -C "$repo" rev-parse --verify --end-of-options "${ref}^{commit}" 2>/dev/null) \
  || die "ref does not resolve to a commit: $ref"
case "$commit" in
  ''|*[!0-9A-Fa-f]*) die "ref did not resolve to an exact commit: $ref" ;;
esac

if [ -n "${XDG_STATE_HOME:-}" ]; then
  default_state_home=$XDG_STATE_HOME
elif [ -n "${HOME:-}" ]; then
  default_state_home=$HOME/.local/state
else
  die 'worktree root is not configured and HOME is unavailable'
fi
worktree_root=${BROKKR_WORKTREE_ROOT:-$default_state_home/brokkr/worktrees}
case "$worktree_root" in
  /*) ;;
  *) die "worktree root must be an absolute path: $worktree_root" ;;
esac

if [ -L "$worktree_root" ]; then
  die "worktree root must not be a symlink: $worktree_root"
fi
if [ -e "$worktree_root" ]; then
  [ -d "$worktree_root" ] || die "worktree root is not a directory: $worktree_root"
  root_probe=$worktree_root
else
  root_probe=$(nearest_existing_parent "$worktree_root")
  [ -d "$root_probe" ] || die "worktree root parent is not a directory: $root_probe"
fi
root_probe=$(canonical_dir "$root_probe") \
  || die "could not resolve worktree root probe: $root_probe"
check_ancestor_permissions "$root_probe"
filesystem_type "$root_probe" >/dev/null

# shellcheck disable=SC2174
if ! mkdir -p -m 0700 -- "$worktree_root"; then
  die "could not create worktree root: $worktree_root"
fi
check_final_root "$worktree_root"
real_root=$(canonical_dir "$worktree_root") \
  || die "could not resolve created worktree root: $worktree_root"
check_ancestor_permissions "$real_root"
filesystem_type "$real_root" >/dev/null
check_final_root "$real_root"

namespace_dir="$real_root/${repo_base}-${namespace_hash}"
if [ -L "$namespace_dir" ]; then
  die "repository namespace must not be a symlink: $namespace_dir"
fi
# shellcheck disable=SC2174
if ! mkdir -p -m 0700 -- "$namespace_dir"; then
  die "could not create repository namespace: $namespace_dir"
fi
check_final_root "$namespace_dir"
real_namespace=$(canonical_dir "$namespace_dir") \
  || die "could not resolve repository namespace: $namespace_dir"
check_ancestor_permissions "$real_namespace"
filesystem_type "$real_namespace" >/dev/null
check_final_root "$real_namespace"

target="$real_namespace/$name"
if [ -e "$target" ] || [ -L "$target" ]; then
  die "worktree target already exists: $target"
fi

if ! git -C "$repo" worktree add -b "$branch" -- "$target" "$commit" >/dev/null; then
  die "could not create worktree: $target"
fi
printf '%s\n' "$target"
