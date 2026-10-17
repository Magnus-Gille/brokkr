#!/usr/bin/env bash
# Reusable local deployment-source identity guard.

_brokkr_git() {
  local git_bin
  local -a clean_environment=(
    "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "HOME=/dev/null"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_NO_REPLACE_OBJECTS=1"
    "GIT_ATTR_NOSYSTEM=1"
  )

  git_bin=$(command -v git) || {
    echo "ERROR: Git is required for deployment-source verification" >&2
    return 127
  }
  /usr/bin/env -i "${clean_environment[@]}" "$git_bin" "$@"
}

_brokkr_git_with_objects() {
  local object_directory=$1
  shift
  local git_bin
  local -a clean_environment=(
    "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "HOME=/dev/null"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_NO_REPLACE_OBJECTS=1"
    "GIT_ATTR_NOSYSTEM=1"
    "GIT_OBJECT_DIRECTORY=$object_directory"
  )

  git_bin=$(command -v git) || {
    echo "ERROR: Git is required for deployment-source verification" >&2
    return 127
  }
  /usr/bin/env -i "${clean_environment[@]}" "$git_bin" "$@"
}

is_full_commit_sha() {
  local revision=${1:-}
  [[ "$revision" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

reject_symlinked_deploy_entry() {
  local entry_path=${1:-} absolute_path component current_path

  [[ -n "$entry_path" ]] || {
    echo "ERROR: deployment entry point path is required" >&2
    return 1
  }
  if [[ "$entry_path" == /* ]]; then
    absolute_path=$entry_path
  else
    absolute_path="$(pwd -P)/$entry_path"
  fi

  [[ "$absolute_path" != *$'\n'* && "$absolute_path" != *$'\r'* ]] || {
    echo "ERROR: deployment entry point path must not contain line breaks" >&2
    return 1
  }

  current_path=/
  local IFS=/
  local -a components
  read -r -a components <<<"${absolute_path#/}"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) continue ;;
      ..) current_path=$(dirname "$current_path"); continue ;;
    esac
    current_path="${current_path%/}/$component"
    if [[ -L "$current_path" ]]; then
      echo "ERROR: deployment entry point path must not contain symlinks" >&2
      return 1
    fi
  done
}

verify_deploy_source_identity() {
  local requested_source=${1:-} expected_revision=${2:-}
  local invocation_source=${3:-$PWD}
  local expected_source invocation_path actual_source actual_revision

  if ! is_full_commit_sha "$expected_revision"; then
    echo "ERROR: deploy source requires an explicit full commit SHA (40 or 64 lowercase hex characters)" >&2
    return 1
  fi

  if ! expected_source=$(cd "$requested_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $requested_source @ $expected_revision"
    echo "Actual source: unresolved @ unknown"
    echo "ERROR: deployment source directory does not exist or is not accessible" >&2
    return 1
  fi

  if ! invocation_path=$(cd "$invocation_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: unresolved @ unknown"
    echo "ERROR: deployment invocation directory does not exist or is not accessible" >&2
    return 1
  fi

  if ! actual_source=$(_brokkr_git -C "$invocation_path" rev-parse --show-toplevel 2>/dev/null); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: $invocation_path @ not-a-git-worktree"
    echo "ERROR: deployment invocation source is not a git worktree" >&2
    return 1
  fi
  if ! actual_source=$(cd "$actual_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: unresolved-git-root @ unknown"
    echo "ERROR: deployment source Git root cannot be resolved" >&2
    return 1
  fi
  actual_revision=$(_brokkr_git -C "$actual_source" rev-parse --verify HEAD 2>/dev/null || echo unknown)

  echo "Expected source: $expected_source @ $expected_revision"
  echo "Actual source: $actual_source @ $actual_revision"

  if [[ "$expected_source" != "$invocation_path" ]]; then
    echo "ERROR: deployment command ran from a different directory than the expected source" >&2
    return 1
  fi
  if [[ "$invocation_path" != "$actual_source" ]]; then
    echo "ERROR: deployment invocation directory is not the resolved Git worktree root" >&2
    return 1
  fi
  if [[ "$expected_revision" != "$actual_revision" ]]; then
    echo "ERROR: deployment source revision does not match the orchestrator's expected revision" >&2
    return 1
  fi
}

verify_brokkr_deploy_source_binding() {
  local entry_source=${1:-} expected_source=${2:-} expected_revision=${3:-}
  local resolved_expected_source resolved_entry_source

  if [[ -z "$entry_source" || -z "$expected_source" || -z "$expected_revision" ]]; then
    echo "ERROR: BROKKR_EXPECTED_SOURCE and BROKKR_EXPECTED_COMMIT (a full immutable SHA) are required" >&2
    return 1
  fi

  verify_deploy_source_identity "$expected_source" "$expected_revision" "$PWD" || return 1

  resolved_expected_source=$(cd "$expected_source" 2>/dev/null && pwd -P) || return 1
  resolved_entry_source=$(cd "$entry_source" 2>/dev/null && pwd -P) || {
    echo "ERROR: deployment entry point source root cannot be resolved" >&2
    return 1
  }
  if [[ "$resolved_entry_source" != "$resolved_expected_source" ]]; then
    echo "Entry source: $resolved_entry_source"
    echo "ERROR: deployment entry point source root does not match the expected source" >&2
    return 1
  fi

  if ! _brokkr_git -C "$resolved_expected_source" diff --quiet --ignore-submodules -- \
    || ! _brokkr_git -C "$resolved_expected_source" diff --cached --quiet --ignore-submodules --; then
    echo "ERROR: deployment source has tracked changes; commit or discard them before deployment" >&2
    return 1
  fi
}

require_brokkr_deploy_source_binding() {
  verify_brokkr_deploy_source_binding \
    "${1:-}" "${BROKKR_EXPECTED_SOURCE:-}" "${BROKKR_EXPECTED_COMMIT:-}"
}

materialize_brokkr_deploy_payload() {
  local source_root=${1:-} revision=${2:-}
  local archive_file empty_template archive_git_dir source_objects
  local object_format=sha1

  is_full_commit_sha "$revision" || {
    echo "ERROR: deploy payload requires an explicit full commit SHA" >&2
    return 1
  }
  DEPLOY_PAYLOAD_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/brokkr-deploy.XXXXXX") || {
    echo "ERROR: could not create private deploy payload parent" >&2
    return 1
  }
  DEPLOY_PAYLOAD_ROOT="$DEPLOY_PAYLOAD_PARENT/payload"
  mkdir -m 0755 "$DEPLOY_PAYLOAD_ROOT" || {
    rm -rf "$DEPLOY_PAYLOAD_PARENT"
    echo "ERROR: could not create deploy payload root" >&2
    return 1
  }
  empty_template="$DEPLOY_PAYLOAD_PARENT/empty-template"
  archive_git_dir="$DEPLOY_PAYLOAD_PARENT/archive.git"
  mkdir -m 0700 "$empty_template" || {
    rm -rf "$DEPLOY_PAYLOAD_PARENT"
    echo "ERROR: could not create empty Git template directory" >&2
    return 1
  }
  if [[ "${#revision}" -eq 64 ]]; then object_format=sha256; fi
  if [[ "$object_format" == sha256 ]]; then
    if ! _brokkr_git init --quiet --bare --object-format=sha256 \
      --template="$empty_template" "$archive_git_dir"; then
      rm -rf "$DEPLOY_PAYLOAD_PARENT"
      echo "ERROR: could not create isolated SHA-256 Git archive metadata" >&2
      return 1
    fi
  elif ! _brokkr_git init --quiet --bare --template="$empty_template" "$archive_git_dir"; then
    rm -rf "$DEPLOY_PAYLOAD_PARENT"
    echo "ERROR: could not create isolated Git archive metadata" >&2
    return 1
  fi
  if ! source_objects=$(_brokkr_git -C "$source_root" rev-parse --path-format=absolute --git-path objects) \
    || ! source_objects=$(cd "$source_objects" 2>/dev/null && pwd -P); then
    rm -rf "$DEPLOY_PAYLOAD_PARENT"
    echo "ERROR: could not resolve deployment source object directory" >&2
    return 1
  fi
  # Do not pipe `git archive` directly into BSD tar. BSD tar can close the pipe
  # after the tar end markers while git is still flushing padding, which makes
  # git exit on SIGPIPE under the caller's `pipefail` despite a complete
  # extraction. Materialize the bounded committed archive first so both stages
  # have an independently verifiable exit status.
  archive_file="$DEPLOY_PAYLOAD_PARENT/payload.tar"
  if ! _brokkr_git_with_objects "$source_objects" --git-dir="$archive_git_dir" \
    archive --format=tar --output="$archive_file" "$revision" \
    || ! tar -xf "$archive_file" -C "$DEPLOY_PAYLOAD_ROOT"; then
    rm -rf "$DEPLOY_PAYLOAD_PARENT"
    echo "ERROR: could not materialize committed deploy payload" >&2
    return 1
  fi
  rm -f "$archive_file"
}
