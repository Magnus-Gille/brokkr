#!/bin/bash
set -euo pipefail

# Brokkr offsite backup — encrypted push of the personal Photos ORIGINALS to cloud
# (OneDrive / Google Drive) through an rclone *crypt* remote. Runs on the LAPTOP
# (that's where the library lives) via a launchd agent (daily) — NOT the Pi/systemd.
#
# ┌─ COPY-ADAPTED from the Grimnir offsite-backup REFERENCE (mimir#9/#10) ───────┐
# │ Same safety contract as mimir/scripts/offsite-backup.sh — kept intact:      │
# │   • Encrypted: rclone crypt — file CONTENTS and NAMES never leave in clear,  │
# │     and the script fails closed if the remote is not a verified crypt.       │
# │   • Preflight delete-count gate + --max-delete: abort an implausible wipe.   │
# │   • Heartbeat stamp + Heimdall status panel so a silent failure is visible.  │
# │   • Fail-loud: every failure exits ≠0, logs, and (when Heimdall is wired via  │
# │     HEIMDALL_HUB_URL/FLEET_TOKEN) pushes a `fail` panel. The panel push is     │
# │     best-effort — like brokkr's health-snapshot — so it never masks the exit.  │
# └──────────────────────────────────────────────────────────────────────────────┘
#
# Photos-specific adaptations (brokkr#1):
#   • Source is the Photos ORIGINALS/masters (raw .heic/.jpeg/.mov files), NOT the
#     `.photoslibrary` package — so restore isn't tied to Photos' internal format.
#     PREREQUISITE: Photos → Settings → "Download Originals to this Mac";
#     otherwise only an optimized cached slice may be present. See
#     docs/offsite-photos-backup.md.
#   • Runs on macOS (BSD date/stat) under launchd, not Linux/systemd.
#   • Uses brokkr's OWN crypt remote + OWN key — never mimir's / munin's.
#   • Photos are append-only, so version history is largely wasted; we KEEP a small
#     `--backup-dir` archive anyway as cheap accidental-delete protection (moved, not
#     destroyed; tiny for append-only media). Drop MIMIR_OFFSITE_KEEP_HISTORY=0 for a
#     plain mirror. (Ticket recommended keeping it — noted here per its ask.)
#
# Usage:
#   ./offsite-photos-backup.sh              run the backup
#   ./offsite-photos-backup.sh --dry-run    show what would change, touch nothing

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- Source the optional env file FIRST, so it can override every default below ----
# Holds HEIMDALL_HUB_URL / HEIMDALL_FLEET_TOKEN (the panel push credentials) and any
# MIMIR_OFFSITE_* overrides — launchd plists can't carry an EnvironmentFile, and secrets
# must not live in the repo or the plist. No-op if the file is absent. This runs before
# the ERR trap is installed, so a malformed file exits LOUD (non-zero + stderr) rather
# than silently under `set -e`; launchd captures stderr.
ENV_FILE="${BROKKR_OFFSITE_ENV_FILE:-$HOME/.config/brokkr/offsite-photos.env}"
if [ -e "$ENV_FILE" ] || [ -L "$ENV_FILE" ]; then
  # This file is sourced as shell code, so treat it like a private executable:
  # it must be a regular, non-symlink file owned by the invoking account and
  # inaccessible to group/other. The checks happen before parsing or sourcing.
  [ ! -L "$ENV_FILE" ] || { echo "$(ts) ERROR: env file must not be a symlink: $ENV_FILE" >&2; exit 1; }
  [ -f "$ENV_FILE" ] || { echo "$(ts) ERROR: env file is not a regular file: $ENV_FILE" >&2; exit 1; }

  if owner_uid=$(stat -c '%u' "$ENV_FILE" 2>/dev/null); then
    mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null)
  else
    owner_uid=$(stat -f '%u' "$ENV_FILE" 2>/dev/null) \
      || { echo "$(ts) ERROR: cannot inspect env file owner: $ENV_FILE" >&2; exit 1; }
    mode=$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null) \
      || { echo "$(ts) ERROR: cannot inspect env file mode: $ENV_FILE" >&2; exit 1; }
  fi
  current_uid=$(id -u)
  [ "$owner_uid" = "$current_uid" ] \
    || { echo "$(ts) ERROR: env file owner uid $owner_uid does not match current uid $current_uid: $ENV_FILE" >&2; exit 1; }
  # Owner permissions may vary (0400, 0600, 0700); group/other must have none.
  case "$mode" in
    *00) ;;
    *) echo "$(ts) ERROR: env file mode $mode is unsafe; group/other permissions must be 00: $ENV_FILE" >&2; exit 1 ;;
  esac

  # Validate syntax first: a parse error in a sourced file aborts the shell BEFORE any
  # `|| handler` can run, so `bash -n` is what turns it into an attributable, loud exit.
  bash -n "$ENV_FILE" 2>/dev/null || { echo "$(ts) ERROR: env file has a syntax error: $ENV_FILE" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" || { echo "$(ts) ERROR: cannot source env file: $ENV_FILE" >&2; exit 1; }
  set +a
fi

# ---- Config (override via environment / the env file above; defaults shown) ----
# The reuse contract keeps the MIMIR_OFFSITE_* env-var names (see mimir docs "Reuse").
SERVICE="${MIMIR_OFFSITE_SERVICE:-brokkr}"                # Heimdall service id
PANEL="${MIMIR_OFFSITE_PANEL:-photos}"                    # Heimdall panel id
SOURCE="${MIMIR_OFFSITE_ROOT:-$HOME/Pictures/Photos Library.photoslibrary/originals}"  # dir to back up
REMOTE="${MIMIR_OFFSITE_REMOTE:-brokkr-photos-crypt}"     # rclone crypt remote NAME (no ':' / path)
KEEP_HISTORY="${MIMIR_OFFSITE_KEEP_HISTORY:-1}"           # 1 = --backup-dir archive; 0 = plain mirror
RETENTION_DAYS="${MIMIR_OFFSITE_RETENTION_DAYS:-30}"      # archive prune horizon (days)
MAX_DELETE="${MIMIR_OFFSITE_MAX_DELETE:-1000}"            # abort if a run would remove ≥ this many files
MAX_DELETE_PCT="${MIMIR_OFFSITE_MAX_DELETE_PCT:-25}"      # ...or more than this % of current/
STAMP="${MIMIR_OFFSITE_STAMP:-$HOME/.local/state/brokkr/offsite-photos.stamp}"
LOG="${MIMIR_OFFSITE_LOG:-$HOME/Library/Logs/brokkr/offsite-photos-backup.log}"
RCLONE="${RCLONE_BIN:-rclone}"

DRY_RUN=""
if [ "${1:-}" = "--dry-run" ] || [ "${MIMIR_OFFSITE_DRYRUN:-}" = "1" ]; then
  DRY_RUN="--dry-run"
fi

# Best-effort log: a write failure (e.g. unwritable LOG dir) must not abort a die()
# before it can push the fail panel.
log() { echo "$(ts) $*" | tee -a "$LOG" 2>/dev/null >&2 || true; }

# Push a Heimdall status panel. Best-effort: a no-op if the hub env vars are unset, and
# a push failure never aborts the run (matches brokkr's health-snapshot convention, and
# Heimdall wiring is still TODO). Same POST shape as heimdall/push.sh. Never logs the token.
push_panel() {
  local state="$1" message="$2"
  [ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ] || return 0
  curl -fsS --max-time 5 -X POST "$HEIMDALL_HUB_URL" \
    -H "Authorization: Bearer ${HEIMDALL_FLEET_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"service\":\"${SERVICE}\",\"panel\":\"${PANEL}\",\"kind\":\"status\",\"label\":\"Offsite Photos backup\",\"state\":\"${state}\",\"message\":\"${message}\"}" \
    >/dev/null 2>&1 || true
}

# Expected failure: log, push a fail panel, exit. (ERR trap disabled to avoid a
# double report.) Used for every preflight/validation failure so a silent dashboard
# is impossible.
die() {
  trap - ERR
  log "ERROR: $*"
  push_panel fail "$* — see ${LOG}"
  exit 1
}

# Unexpected command failure after preflight (e.g. rclone sync aborts).
on_err() {
  local rc=$?
  trap - ERR
  log "ERROR: offsite photos backup failed (exit ${rc})"
  push_panel fail "backup failed (exit ${rc}) — see ${LOG}"
  exit "${rc}"
}
trap on_err ERR

mkdir -p "$(dirname "$LOG")" "$(dirname "$STAMP")"

# ---- Preflight ----
command -v "$RCLONE" >/dev/null 2>&1 || die "rclone not found (RCLONE_BIN=$RCLONE)"
[ -d "$SOURCE" ] || die "source dir missing: $SOURCE"
case "$REMOTE" in *:*|*/*) die "MIMIR_OFFSITE_REMOTE must be a remote NAME only, got '$REMOTE'";; esac

# Warn (don't fail) if the rclone config is group/world-readable — it holds secrets.
CONF="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
if [ -f "$CONF" ]; then
  PERM=$(stat -f '%Lp' "$CONF" 2>/dev/null || stat -c '%a' "$CONF" 2>/dev/null || echo "")
  case "$PERM" in ""|600|400) ;; *) log "WARN: $CONF is mode $PERM — should be 600 (holds OAuth token + crypt password)";; esac
fi

# Fail CLOSED unless the remote is provably a crypt remote with filename encryption.
# Prevents a misconfigured MIMIR_OFFSITE_REMOTE from uploading plaintext photos.
# Read only the type/encryption fields; never log the config (it contains the key).
CONF_SHOW=$("$RCLONE" config show "$REMOTE" 2>/dev/null || true)
RTYPE=$(printf '%s\n' "$CONF_SHOW" | awk -F' = ' '/^type =/{print $2; exit}')
FENC=$(printf '%s\n' "$CONF_SHOW" | awk -F' = ' '/^filename_encryption =/{print $2; exit}')
DENC=$(printf '%s\n' "$CONF_SHOW" | awk -F' = ' '/^directory_name_encryption =/{print $2; exit}')
[ "$RTYPE" = "crypt" ] || die "remote '$REMOTE' is type '${RTYPE:-unknown}', not crypt — refusing to upload plaintext"
# Names must be genuinely encrypted, not merely obfuscated (obfuscate is reversible
# without the key). An ABSENT field means the rclone crypt default (standard / true),
# which is the strong setting — so only an explicit weak value is rejected.
case "$FENC" in
  ""|standard) ;;
  *) die "remote '$REMOTE' has filename_encryption='${FENC}' — refusing (need 'standard'; names would leak)";;
esac
case "$DENC" in
  ""|true) ;;
  *) die "remote '$REMOTE' has directory_name_encryption='${DENC}' — refusing (need 'true'; dir names would leak)";;
esac

DEST="${REMOTE}:current"
ARCHIVE="${REMOTE}:archive/$(date -u +%Y-%m-%dT%H%M%SZ)"   # per-run dir, pruned by NAME

# Human label for the disposition of files removed from source (used in log lines).
if [ "$KEEP_HISTORY" = "1" ]; then DISPOSITION="move to archive"; else DISPOSITION="be removed"; fi

# Connectivity + ensure destination exists (mkdir is idempotent and proves auth/write).
if [ -z "$DRY_RUN" ]; then
  "$RCLONE" mkdir "$DEST" 2>>"$LOG" || die "cannot reach/create ${DEST} — check rclone config / network"
else
  "$RCLONE" lsd "${REMOTE}:" >/dev/null 2>>"$LOG" || log "WARN: dry-run remote check failed (remote may be new/empty)"
fi

# ---- Preflight delete-count gate ----
# Files present in current/ but absent from the source would be MOVED to the archive (or,
# with KEEP_HISTORY=0, deleted). An implausibly large change set (e.g. the library was
# unmounted or the download-originals slice regressed to an optimized cache) should STOP
# and alert, not silently mirror a shrunken current/ and report success. Skipped on
# dry-run and on the first run (empty dest).
if [ -z "$DRY_RUN" ]; then
  # Fail CLOSED on a listing error: a transient lsf failure must NOT yield an empty list
  # that silently skips the gate. `set -o pipefail` propagates lsf's exit through `| sort`.
  # A genuinely-empty dest (first run — DEST was just mkdir'd) lists cleanly with exit 0.
  DEST_LIST=$("$RCLONE" lsf -R --files-only "$DEST" 2>>"$LOG" | sort) \
    || die "cannot list ${DEST} for the delete-count preflight — refusing to sync blind"
  SRC_LIST=$("$RCLONE" lsf -R --files-only "$SOURCE" 2>>"$LOG" | sort) \
    || die "cannot list ${SOURCE} for the delete-count preflight — refusing to sync blind"
  DEST_N=$(printf '%s\n' "$DEST_LIST" | grep -c . || true)
  DELETES=$(comm -23 <(printf '%s\n' "$DEST_LIST") <(printf '%s\n' "$SRC_LIST") | grep -c . || true)
  if [ "$DEST_N" -gt 0 ] && [ "$DELETES" -gt 0 ]; then
    PCT=$(( DELETES * 100 / DEST_N ))
    if [ "$DELETES" -ge "$MAX_DELETE" ] || [ "$PCT" -gt "$MAX_DELETE_PCT" ]; then
      die "aborting: sync would remove ${DELETES}/${DEST_N} files (${PCT}%) from current/ — over threshold (max ${MAX_DELETE} or ${MAX_DELETE_PCT}%)"
    fi
    log "delete-count gate ok: ${DELETES}/${DEST_N} files (${PCT}%) would ${DISPOSITION}"
  fi
fi

if [ "$KEEP_HISTORY" = "1" ]; then ARCHIVE_NOTE=" (archive: ${ARCHIVE})"; else ARCHIVE_NOTE=""; fi
log "starting offsite photos backup ${DRY_RUN:+(dry-run) }${SOURCE} → ${DEST}${ARCHIVE_NOTE}"

# Mirror the current state. With KEEP_HISTORY=1, overwritten/deleted files are MOVED into
# the per-run archive dir (never destroyed); --max-delete is a second-line guard behind the
# preflight gate above. With KEEP_HISTORY=0 it's a plain mirror.
BACKUP_ARGS=()
if [ "$KEEP_HISTORY" = "1" ]; then
  BACKUP_ARGS=(--backup-dir "$ARCHIVE")
fi
# The "${arr[@]+...}" guard avoids an "unbound variable" under `set -u` when the array
# is empty (KEEP_HISTORY=0) — a macOS bash 3.2 quirk.
# shellcheck disable=SC2086
"$RCLONE" sync "${SOURCE}/" "$DEST" \
  ${BACKUP_ARGS[@]+"${BACKUP_ARGS[@]}"} \
  --max-delete "$MAX_DELETE" \
  --transfers 4 --checkers 8 \
  --log-file "$LOG" --log-level INFO \
  --stats 0 $DRY_RUN

if [ -n "$DRY_RUN" ]; then
  log "dry-run complete — no changes made, stamp/prune/panel skipped"
  exit 0
fi

# Prune whole archive run-dirs older than the retention horizon, BY NAME (the dir's UTC
# timestamp), not by object mtime — sync preserves source mtimes, so an old file just
# moved into the archive must NOT be judged old by its own mtime. Best-effort: a prune
# failure must not fail the backup (the mirror already succeeded). No-op if history off.
prune_archive() {
  [ "$KEEP_HISTORY" = "1" ] || return 0
  local cutoff d
  # GNU date first (Linux), then BSD date (macOS, where this actually runs).
  cutoff=$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%dT%H%M%SZ 2>/dev/null \
    || date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%dT%H%M%SZ 2>/dev/null || true)
  if [ -z "$cutoff" ]; then
    log "WARN: cannot compute retention cutoff — skipping prune"
    return 0
  fi
  while IFS= read -r d; do
    d="${d%/}"; [ -n "$d" ] || continue
    if [[ "$d" < "$cutoff" ]]; then
      if "$RCLONE" purge "${REMOTE}:archive/${d}" 2>>"$LOG"; then
        log "pruned archive/${d} (older than ${RETENTION_DAYS}d)"
      else
        log "WARN: purge archive/${d} failed — will retry next run"
      fi
    fi
  done < <("$RCLONE" lsf --dirs-only "${REMOTE}:archive" 2>/dev/null || true)
}
prune_archive

# Heartbeat + success panel.
date +%s > "$STAMP"
COUNT=$(find "$SOURCE" -type f | wc -l | tr -d ' ')
log "offsite photos backup complete: ${COUNT} files mirrored to ${DEST}"
push_panel pass "${COUNT} files, $(ts)"
