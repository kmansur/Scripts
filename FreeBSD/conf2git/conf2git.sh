#!/bin/sh
# /usr/local/scripts/conf2git.sh
# v1.6.3 - Safely exports configuration directories to Git (portable self-lock + smart remote sync policy + fixed self-update argv + diagnostics)
# Author: Karim Mansur <karim.mansur@outlook.com>
#
# Changelog v1.6.3
# - Add smart remote sync handler with configurable policy via ALIGN_MODE:
#     * ALIGN_MODE="reset"  -> always fetch + hard reset to origin/<branch>
#     * ALIGN_MODE="rebase" -> (default) try FF; rebase --autostash on divergence; safe reset only if no local commits
# - Replace previous 'pull --ff-only' with robust divergence handling.
#
# Changelog v1.6.2
# - Fix self-update argv capture (capture BEFORE parsing).
# - Add --self-update-only to test/apply updates without running the main flow.
# - Improve diagnostics and permission checks in self-update routine.
# - Keep portable self-lock (FreeBSD lockf, Linux flock, mkdir fallback).
#
# Changelog v1.6.1
# - Portability lock rework: prefer lockf(FreeBSD) or flock(Linux), fallback to mkdir dir-lock.
# - Self-lock re-exec strategy avoids stale file locks and recursion via __CONF2GIT_LOCKED guard.
#
# Changelog v1.6.0
# - Add pre-execution update check: if a newer script is available and
#   AUTO_UPDATE="yes" (or --self-update), replace and re-exec; otherwise warn.
# - Hardened download (fetch/curl/wget), CRLF normalization, hash compare.
# - Log function tolerates unset LOGFILE (prints to stdout).
# - Add optional end-of-run management report (--report) printed to stdout.
# - Also accept -r and CONF2GIT_REPORT=1 to enable report.
# - More robust script path resolution (handles PATH lookup when $0 has no '/').
# - Add LOGFILE rotation (max 100KB), keep last 12 as .gz, before any logging.

set -eu

# Harden environment (portable)
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

# Keep a snapshot of original argv BEFORE we shift anything (for safe re-exec after self-update)
CONF2GIT_ORIG_ARGS="$*"

###############################################################################
# Defaults (local only; everything else comes from the config file)
###############################################################################
HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"   # can be overridden with --config

# Runtime flags
DRYRUN=false
FORCE_UPDATE=false
SELF_UPDATE_ONLY=false
REPORT=false

# Default alignment policy if not set in config: "rebase" | "reset"
ALIGN_MODE_DEFAULT="rebase"

###############################################################################
# Functions
###############################################################################
usage() {
  cat <<USAGE
Usage: conf2git.sh [OPTIONS]

Safely snapshot configuration folders into a Git monorepo, restricting the
working tree to this host only via git sparse-checkout.

Options:
  --dry-run            Simulate rsync (no changes committed/pushed)
  --config <path>      Use an alternative config file (default: $CFG_FILE)
  --self-update        Force an immediate self-update from UPDATE_URL
  --self-update-only   Only perform self-update check/apply and exit
  -r, --report         Print a management report at the end of execution
  -h, --help           Show this help and exit

Config keys (minimal):
  CONF_DIRS, BASE_DIR, REPO_ROOT, GIT_REPO_URL,
  TARGET_PATH, REPO_DIR, LOCKFILE, LOGFILE,
  GIT_USER_NAME, GIT_USER_EMAIL, AUTO_UPDATE, UPDATE_URL

Optional config:
  ALIGN_MODE           rebase (default) | reset

Example template: /usr/local/scripts/conf2git.cfg.example
USAGE
}

###############################################################################
# Log rotation (max 100KB, keep last 12 gzipped)
###############################################################################
rotate_logs_if_needed() {
  [ -n "${LOGFILE:-}" ] || return 0
  [ -f "$LOGFILE" ] || return 0
  # Size check: 100 * 1024 bytes
  LOG_SIZE=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "${LOG_SIZE:-0}" -lt 102400 ]; then
    return 0
  fi
  # Ensure directory exists and is writable
  LOGDIR=$(dirname "$LOGFILE")
  [ -w "$LOGDIR" ] || return 0

  # Rotate: shift 11..1 -> 12..2, then move current to .1.gz
  i=12
  while [ $i -ge 2 ]; do
    prev=$((i-1))
    [ -f "$LOGFILE.$prev.gz" ] && mv -f "$LOGFILE.$prev.gz" "$LOGFILE.$i.gz" 2>/dev/null || true
    i=$((i-1))
  done

  # Compress current to .1.gz
  if command -v gzip >/dev/null 2>&1; then
    gzip -c "$LOGFILE" > "$LOGFILE.1.gz" 2>/dev/null || true
  else
    # Fallback: no gzip; just copy (larger files)
    cp -f "$LOGFILE" "$LOGFILE.1.gz" 2>/dev/null || true
  fi
  # Truncate current
  : > "$LOGFILE"
}

###############################################################################
# Report helpers
###############################################################################
REPORT_START_EPOCH=$(date +%s)
REPORT_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_DIRS_TOTAL=0
REPORT_DIRS_SYNCED=0
REPORT_DIRS_MISSING=0
REPORT_RSYNC_LOG=""
REPORT_COMMITTED="no"
REPORT_COMMIT_SHA=""

init_report() {
  if $REPORT; then
    REPORT_RSYNC_LOG=$(mktemp -t conf2git_rsync.XXXXXX)
  fi
}

finalize_report() {
  $REPORT || return 0
  END_EPOCH=$(date +%s)
  END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
  DURATION=$((END_EPOCH - REPORT_START_EPOCH))

  CHANGES=0
  if [ -n "$REPORT_RSYNC_LOG" ] && [ -f "$REPORT_RSYNC_LOG" ]; then
    # Count itemized changes lines (best effort)
    CHANGES=$(grep -E '^[<>ch\*].' "$REPORT_RSYNC_LOG" 2>/dev/null | wc -l | awk '{print $1}')
  fi

  echo ""
  echo "================ Management Report ================"
  echo "Start:      $REPORT_START_HUMAN"
  echo "End:        $END_HUMAN"
  echo "Duration:   ${DURATION}s"
  echo "Host/OS:    $HOSTNAME_SHORT / $OS"
  echo "Repo root:  $REPO_ROOT"
  echo "Target:     $TARGET_PATH (branch: ${DEFAULT_BRANCH:-unknown})"
  echo "Dirs:       total=$REPORT_DIRS_TOTAL synced=$REPORT_DIRS_SYNCED missing=$REPORT_DIRS_MISSING"
  echo "Changes:    rsync_itemized=$CHANGES"
  echo "Committed:  $REPORT_COMMITTED ${REPORT_COMMIT_SHA:+(sha $REPORT_COMMIT_SHA)}"
  echo "=================================================="

  # Cleanup temp log
  [ -n "$REPORT_RSYNC_LOG" ] && rm -f "$REPORT_RSYNC_LOG" 2>/dev/null || true
}

log() {
  # Print to stdout always; append to $LOGFILE if it exists/is set
  MSG="$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME_SHORT][$$] $*"
  echo "$MSG"
  if [ "${LOGFILE:-}" != "" ]; then
    # shellcheck disable=SC2129
    echo "$MSG" >> "$LOGFILE" 2>/dev/null || true
  fi
}

# Portable SHA-256 (FreeBSD 'sha256' or GNU 'sha256sum')
sha256_file() {
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$1"
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Download helper: FreeBSD fetch, or curl, or wget
fetch_to() {
  # args: URL DEST
  if command -v fetch >/dev/null 2>&1; then
    fetch -q -o "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 127
  fi
}

###############################################################################
# Portable script path resolver
###############################################################################
resolve_script_path() {
  sp="$0"
  # If invoked without '/', locate via PATH
  case "$sp" in
    */*) : ;;
    *) sp=$(command -v -- "$0" 2>/dev/null || echo "$0") ;;
  esac
  # Try realpath
  if command -v realpath >/dev/null 2>&1; then
    rp=$(realpath "$sp" 2>/dev/null || true)
    [ -n "$rp" ] && { echo "$rp"; return; }
  fi
  # Try readlink -f
  if command -v readlink >/dev/null 2>&1; then
    rp=$(readlink -f "$sp" 2>/dev/null || true)
    [ -n "$rp" ] && { echo "$rp"; return; }
  fi
  # Fallback: relative -> absolute
  case "$sp" in
    /*) echo "$sp" ;;
    *)  echo "$(pwd)/$sp" ;;
  esac
}

###############################################################################
# Enhanced self-update check (v1.6.2+)
###############################################################################
self_update_check() {
  # Avoid loops after a successful self-update
  if [ "${CONF2GIT_UPDATED:-}" = "1" ]; then
    log "Self-update: already updated in this run; skipping check"
    return 0
  fi

  [ -n "${UPDATE_URL:-}" ] || { log "Self-update: UPDATE_URL not set; skipping"; return 0; }

  SCRIPT_PATH="$(resolve_script_path)"
  if [ ! -r "$SCRIPT_PATH" ]; then
    log "Self-update: cannot read current script at $SCRIPT_PATH; skipping"
    return 0
  fi

  [ "${CONF2GIT_DEBUG:-}" = "1" ] && log "Self-update: check URL=$UPDATE_URL script=$SCRIPT_PATH"

  TMP_FILE=$(mktemp -t conf2git_update.XXXXXX)
  if ! fetch_to "$UPDATE_URL" "$TMP_FILE"; then
    log "Self-update: download failed from $UPDATE_URL"
    rm -f "$TMP_FILE"
    return 1
  fi

  # Normalize CRLF to LF
  tr -d '\r' < "$TMP_FILE" > "$TMP_FILE.norm" && mv "$TMP_FILE.norm" "$TMP_FILE"

  # Basic validation
  if ! head -n 5 "$TMP_FILE" | grep -Eq '^#!/bin/(sh|bash)'; then
    log "Self-update: downloaded file is not a shell script"
    rm -f "$TMP_FILE"
    return 1
  fi
  if ! grep -q "conf2git" "$TMP_FILE"; then
    log "Self-update: downloaded file doesn't look like conf2git"
    rm -f "$TMP_FILE"
    return 1
  fi

  # Optional hash pinning
  if [ -n "${EXPECTED_SHA256:-}" ]; then
    NEW_SUM_CHECK=$(sha256_file "$TMP_FILE" 2>/dev/null || echo "none")
    if [ "$NEW_SUM_CHECK" != "$EXPECTED_SHA256" ]; then
      log "Self-update: hash mismatch (expected=$EXPECTED_SHA256 got=$NEW_SUM_CHECK)"
      rm -f "$TMP_FILE"
      return 1
    fi
  fi

  OLD_SUM=$(sha256_file "$SCRIPT_PATH" 2>/dev/null || echo "none")
  NEW_SUM=$(sha256_file "$TMP_FILE" 2>/dev/null || echo "none")
  [ "${CONF2GIT_DEBUG:-}" = "1" ] && log "Self-update: local=$OLD_SUM new=$NEW_SUM"

  if [ "$OLD_SUM" = "$NEW_SUM" ]; then
    log "Self-update: already up to date"
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 0
    return 0
  fi

  # Permission check
  if [ ! -w "$SCRIPT_PATH" ]; then
    log "Self-update: script is not writable ($SCRIPT_PATH); cannot update"
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 1
    return 1
  fi

  # Apply update only if allowed
  if [ "${AUTO_UPDATE:-no}" = "yes" ] || [ "$FORCE_UPDATE" = true ]; then
    TS=$(date +%Y%m%d%H%M%S)
    BACKUP="${SCRIPT_PATH}.bak.$TS"
    if ! cp -p "$SCRIPT_PATH" "$BACKUP"; then
      log "Self-update: failed to create backup at $BACKUP"
      rm -f "$TMP_FILE"
      $SELF_UPDATE_ONLY && exit 1
      return 1
    fi

    chmod 0755 "$TMP_FILE" 2>/dev/null || true
    # Atomic replace via .new then mv over original (same filesystem)
    if ! mv "$TMP_FILE" "$SCRIPT_PATH.new"; then
      log "Self-update: failed to stage .new file"
      rm -f "$TMP_FILE"
      $SELF_UPDATE_ONLY && exit 1
      return 1
    fi
    if ! mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"; then
      log "Self-update: failed to replace script; backup kept at $BACKUP"
      $SELF_UPDATE_ONLY && exit 1
      return 1
    fi

    log "Self-update: updated successfully (backup: $BACKUP). Re-exec new version..."
    export CONF2GIT_UPDATED=1

    # Re-exec preserving original argv snapshot (may be empty)
    if [ -n "${CONF2GIT_ORIG_ARGS:-}" ]; then
      # shellcheck disable=SC2086
      exec "$SCRIPT_PATH" $CONF2GIT_ORIG_ARGS
    else
      exec "$SCRIPT_PATH"
    fi
  else
    log "Self-update: update available but AUTO_UPDATE=no and --self-update not used"
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 1
    return 0
  fi
}

###############################################################################
# Parse CLI arguments
###############################################################################
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=true ;;
    --config)
      [ $# -ge 2 ] || { echo "Error: --config requires a path" >&2; exit 2; }
      CFG_FILE="$2"; shift ;;
    --self-update) FORCE_UPDATE=true ;;
    --self-update-only) FORCE_UPDATE=true; SELF_UPDATE_ONLY=true ;;
    -r|--report) REPORT=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# Environment override to enable report
if [ "${CONF2GIT_REPORT:-}" = "1" ]; then
  REPORT=true
fi

###############################################################################
# Load configuration file (required)
###############################################################################
if [ -f "$CFG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CFG_FILE"
else
  echo "Error: configuration file not found: $CFG_FILE" >&2
  exit 1
fi

# Default ALIGN_MODE if unset/empty
ALIGN_MODE="${ALIGN_MODE:-$ALIGN_MODE_DEFAULT}"

###############################################################################
# Validate required configuration variables
###############################################################################
require_vars() {
  missing=0
  for v in CONF_DIRS BASE_DIR REPO_ROOT GIT_REPO_URL TARGET_PATH REPO_DIR LOCKFILE GIT_USER_NAME GIT_USER_EMAIL; do
    eval val="\${$v:-}"
    if [ -z "$val" ]; then
      log "Config: required variable missing or empty: $v"
      missing=1
    fi
  done
  [ $missing -eq 0 ] || { log "Invalid config. Aborting."; exit 1; }
}
require_vars

###############################################################################
# Optional self-update (prior to locking)
###############################################################################
# Rotate logs before any further logging
rotate_logs_if_needed

self_update_check "$@"

# If user only requested the self-update, exit now (status already reflects result)
$SELF_UPDATE_ONLY && exit 0

# Initialize reporting
init_report

###############################################################################
# Concurrency control (portable self-lock)
###############################################################################
# Requires: LOCKFILE from config. Prefer kernel-assisted locking when available,
# otherwise fall back to an atomic directory lock that auto-cleans on exit.
#
# Strategy:
#   - If not locked yet (__CONF2GIT_LOCKED!=1):
#       FreeBSD + lockf  -> re-exec under lockf -k
#       flock available  -> re-exec under flock -n
#       else             -> mkdir-based lock dir with trap (no re-exec)
#   - If __CONF2GIT_LOCKED=1 -> already inside the lock context, continue.

if [ "${__CONF2GIT_LOCKED:-}" != "1" ]; then
  # Ensure LOCKFILE directory exists
  LOCKDIRNAME="$(dirname -- "${LOCKFILE}")"
  [ -d "${LOCKDIRNAME}" ] || mkdir -p "${LOCKDIRNAME}" 2>/dev/null || true

  if [ "${OS}" = "freebsd" ] && command -v /usr/bin/lockf >/dev/null 2>&1; then
    export __CONF2GIT_LOCKED=1
    exec /usr/bin/lockf -k "${LOCKFILE}" "$0" "$@"
  elif command -v /usr/bin/flock >/dev/null 2>&1 || command -v flock >/dev/null 2>&1; then
    FLOCK_BIN="$(command -v /usr/bin/flock || command -v flock)"
    export __CONF2GIT_LOCKED=1
    exec "${FLOCK_BIN}" -n "${LOCKFILE}" "$0" "$@"
  else
    # Fallback: directory-based lock (atomic mkdir). No re-exec; we hold the lock in-process.
    LOCKDIR="${LOCKFILE}.d"
    if ! mkdir "${LOCKDIR}" 2>/dev/null; then
      log "Another process is running (dir-lock: ${LOCKDIR}). Aborting."
      exit 1
    fi
    # Ensure cleanup on exit/signals
    trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT INT TERM
    export __CONF2GIT_LOCKED=1
  fi
fi

###############################################################################
# Check Git version and detect default branch
###############################################################################
git_version_ok=true
if command -v git >/dev/null 2>&1; then
  v=$(git version | awk '{print $3}')
  major=${v%%.*}; rest=${v#*.}; minor=${rest%%.*}
  if [ "${major:-0}" -lt 2 ] || { [ "$major" -eq 2 ] && [ "${minor:-0}" -lt 25 ]; }; then
    git_version_ok=false
  fi
else
  git_version_ok=false
fi
$git_version_ok || { log "Git >= 2.25 is required for sparse-checkout. Aborting."; exit 1; }

detect_default_branch() {
  db=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | awk -F/ '{print $2}')
  echo "${db:-main}"
}

###############################################################################
# Prepare repo with sparse-checkout limited to this host
###############################################################################
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT"
  log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT"
  cd "$REPO_ROOT"
  DEFAULT_BRANCH="$(detect_default_branch || echo main)"
  git sparse-checkout init --cone
  git sparse-checkout set "$TARGET_PATH"
  git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || true
  # Enforce committer identity for this local repo
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
else
  cd "$REPO_ROOT"
  DEFAULT_BRANCH="$(detect_default_branch || echo main)"
  # Ensure sparse-checkout is enabled and restricted
  if git sparse-checkout list >/dev/null 2>&1; then
    log "Sparse-checkout already enabled. Setting path: $TARGET_PATH"
    git sparse-checkout set "$TARGET_PATH"
  else
    log "Enabling sparse-checkout and restricting to: $TARGET_PATH"
    git sparse-checkout init --cone
    git sparse-checkout set "$TARGET_PATH"
  fi

  #############################################################################
  # Smart remote sync (ALIGN_MODE policy)
  #############################################################################
  log "Updating refs (ALIGN_MODE=${ALIGN_MODE})"
  git fetch --prune || log "Warning: git fetch failed; continuing with local refs."

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -n "$CURRENT_BRANCH" ] || CURRENT_BRANCH="$DEFAULT_BRANCH"
  [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ] || git checkout "$DEFAULT_BRANCH" || true

  case "$ALIGN_MODE" in
    reset)
      # Always align to remote (best for pure dump repos without local-only commits)
      if ! git reset --hard "origin/$DEFAULT_BRANCH"; then
        log "Error: hard reset to origin/$DEFAULT_BRANCH failed; aborting."
        exit 1
      fi
      ;;
    rebase|*)
      # Compute ahead/behind/divergence
      set +e
      AHEAD_BEHIND="$(git rev-list --left-right --count "origin/$DEFAULT_BRANCH...HEAD" 2>/dev/null)"
      set -e
      REMOTE_AHEAD=$(echo "${AHEAD_BEHIND:-0 0}" | awk '{print $1}')
      LOCAL_AHEAD=$(echo "${AHEAD_BEHIND:-0 0}" | awk '{print $2}')
      log "Remote ahead=${REMOTE_AHEAD:-0} / Local ahead=${LOCAL_AHEAD:-0}"

      if [ "${REMOTE_AHEAD:-0}" = "0" ] && [ "${LOCAL_AHEAD:-0}" = "0" ]; then
        :
      else
        # Try fast-forward first
        if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          git merge --ff-only "origin/$DEFAULT_BRANCH" || log "Warning: ff-only merge failed unexpectedly."
        else
          log "Non-FF situation detected. Attempting rebase..."
          if git rebase --autostash "origin/$DEFAULT_BRANCH"; then
            log "Rebase succeeded."
          else
            if [ "${LOCAL_AHEAD:-0}" = "0" ]; then
              log "Rebase failed but no local commits exist; aligning via hard reset."
              git reset --hard "origin/$DEFAULT_BRANCH" || {
                log "Error: hard reset failed; aborting to avoid corruption."; exit 1; }
            else
              log "Error: rebase failed and local commits exist; manual intervention required."
              log "Tip: resolve conflicts or push a rescue branch, then align main to origin."
              exit 1
            fi
          fi
        fi
      fi
      ;;
  esac

  # Refresh committer identity
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
fi

###############################################################################
# Ensure target directory exists
###############################################################################
if [ ! -d "$REPO_DIR" ]; then
  mkdir -p "$REPO_DIR" || { log "Error: unable to create $REPO_DIR"; exit 1; }
fi

###############################################################################
# rsync capabilities and excludes
###############################################################################
RSYNC_AXH=""
if rsync --help 2>&1 | grep -qE '\-H'; then RSYNC_AXH="$RSYNC_AXH -H"; fi
if rsync --help 2>&1 | grep -qE '\-A'; then RSYNC_AXH="$RSYNC_AXH -A"; fi
if rsync --help 2>&1 | grep -qE '\-X'; then RSYNC_AXH="$RSYNC_AXH -X"; fi

RSYNC_EXCLUDES="
  --exclude '*.pid' --exclude '*.db' --exclude '*.core'
  --exclude '*.sock' --exclude '*.swp' --exclude 'cache/' --exclude '.git/'
"

###############################################################################
# Sync configuration directories
###############################################################################
for DIR in $CONF_DIRS; do
  REPORT_DIRS_TOTAL=$((REPORT_DIRS_TOTAL + 1))
  if [ -d "$DIR" ]; then
    DEST_NAME=$(echo "$DIR" | sed 's#^/##; s#/#_#g')
    log "Syncing $DIR -> $REPO_DIR/$DEST_NAME/"
    if $DRYRUN; then
      # -n (dry-run), -i (itemized), -v for easier diagnostics
      # shellcheck disable=SC2086
      if $REPORT; then
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$REPO_DIR/$DEST_NAME/" | tee -a "$REPORT_RSYNC_LOG"
      else
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$REPO_DIR/$DEST_NAME/"
      fi
    else
      # shellcheck disable=SC2086
      if $REPORT; then
        rsync -aiv $RSYNC_AXH --delete $RSYNC_EXCLUDES "$DIR/" "$REPO_DIR/$DEST_NAME/" | tee -a "$REPORT_RSYNC_LOG"
      else
        rsync -a $RSYNC_AXH --delete $RSYNC_EXCLUDES "$DIR/" "$REPO_DIR/$DEST_NAME/"
      fi
    fi
    REPORT_DIRS_SYNCED=$((REPORT_DIRS_SYNCED + 1))
  else
    log "Warning: directory not found: $DIR"
    REPORT_DIRS_MISSING=$((REPORT_DIRS_MISSING + 1))
  fi
done

###############################################################################
# Commit and push restricted to this host's path
###############################################################################
if ! $DRYRUN; then
  log "Staging changes only under: $TARGET_PATH"
  git add -- "$TARGET_PATH"
  if git diff --cached --quiet -- "$TARGET_PATH"; then
    log "No changes to commit. Exiting."
    exit 0
  fi
  COMMIT_MSG="[$OS/$HOSTNAME_SHORT] Automated config backup at $(date '+%Y-%m-%d %H:%M:%S')"
  log "Commit: $COMMIT_MSG"
  git commit -m "$COMMIT_MSG"
  log "Pushing to '$DEFAULT_BRANCH'"
  git push origin "$DEFAULT_BRANCH"
  log "Done."
  REPORT_COMMITTED="yes"
  REPORT_COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
else
  log "Dry-run: nothing was committed."
fi

# Print final report if requested
finalize_report