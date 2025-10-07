#!/bin/sh
# =============================================================================
# conf2git.sh - v1.6.3-lts (stable & safe)
# -----------------------------------------------------------------------------
# Purpose:
#   Safely export configuration directories into a Git monorepo under a
#   host-specific subpath (TARGET_PATH), with strong safety rails to ensure
#   no changes happen outside that path. Compatible with Git >=2.17.1 via
#   legacy sparse-checkout; uses modern sparse-checkout when available (>=2.25).
#
# Major properties:
#   - Portable locking (FreeBSD lockf / Linux flock / mkdir fallback)
#   - Log rotation (lightweight)
#   - Optional end-of-run report
#   - Self-update (optional, quiet when AUTO_UPDATE=no)
#   - Strict safety checks to prevent repository-wide deletions/changes
#
# Safety highlights (VERY IMPORTANT):
#   1) Validates TARGET_PATH is sane, non-empty, no spaces, not "/" or ".",
#      and has at least two segments (e.g., "freebsd/hostname").
#   2) Validates REPO_DIR == REPO_ROOT/TARGET_PATH (exact match).
#   3) rsync operates only under REPO_DIR/$DEST_NAME (strict scope).
#   4) Stage with `git add -- "$TARGET_PATH"` only.
#   5) Pre-commit guard: if any staged path is outside TARGET_PATH, abort.
#   6) Legacy sparse-checkout writes explicit rooted patterns for TARGET_PATH.
#
# Platform notes:
#   - /bin/sh POSIX; avoid non-portable bashisms (no pipefail).
#   - Works on FreeBSD and Linux.
#
# Author: (comments written in English as requested)
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Environment hardening
# -----------------------------------------------------------------------------
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

# Preserve original argv (useful for self-update re-exec)
CONF2GIT_ORIG_ARGS="$*"

# -----------------------------------------------------------------------------
# Defaults (configurable via conf2git.cfg)
# -----------------------------------------------------------------------------
HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"   # overridden by --config

# Runtime flags
DRYRUN=false
FORCE_UPDATE=false
SELF_UPDATE_ONLY=false
REPORT=false

# Policies (safe defaults)
ALIGN_MODE_DEFAULT="rebase"       # rebase | reset
SELF_UPDATE_QUIET_DEFAULT="yes"   # yes | no (hide "update available" noise)

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------
log() {
  # (English) Log to stdout and optionally to LOGFILE.
  MSG="$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME_SHORT][$$] $*"
  echo "$MSG"
  if [ "${LOGFILE:-}" != "" ]; then
    echo "$MSG" >> "$LOGFILE" 2>/dev/null || true
  fi
}

fatal() {
  # (English) Log error and exit 1.
  log "FATAL: $*"
  exit 1
}

rotate_logs_if_needed() {
  # (English) Lightweight log rotation: at 100 KiB, rotate and keep last 12 (.gz).
  [ -n "${LOGFILE:-}" ] || return 0
  [ -f "$LOGFILE" ] || return 0
  LOG_SIZE=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
  [ "${LOG_SIZE:-0}" -lt 102400 ] && return 0
  LOGDIR=$(dirname "$LOGFILE")
  [ -w "$LOGDIR" ] || return 0
  i=12
  while [ $i -ge 2 ]; do
    prev=$((i-1))
    [ -f "$LOGFILE.$prev.gz" ] && mv -f "$LOGFILE.$prev.gz" "$LOGFILE.$i.gz" 2>/dev/null || true
    i=$((i-1))
  done
  if command -v gzip >/dev/null 2>&1; then
    gzip -c "$LOGFILE" > "$LOGFILE.1.gz" 2>/dev/null || true
  else
    cp -f "$LOGFILE" "$LOGFILE.1.gz" 2>/dev/null || true
  fi
  : > "$LOGFILE"
}

usage() {
  cat <<USAGE
Usage: conf2git.sh [OPTIONS]

Safely snapshot configuration folders into a Git monorepo, restricting the
working tree to this host via sparse-checkout (modern or legacy).

Options:
  --dry-run            Simulate rsync (no commit/push)
  --config <path>      Use an alternative config file (default: $CFG_FILE)
  --self-update        Force a self-update from UPDATE_URL
  --self-update-only   Only perform self-update and exit
  -r, --report         Print a management report at the end
  -h, --help           Show this help and exit
USAGE
}

sha256_file() {
  # (English) Portable sha256 helper (FreeBSD sha256 or GNU sha256sum).
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$1"
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

fetch_to() {
  # (English) Download helper (FreeBSD fetch, curl, or wget).
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

resolve_script_path() {
  # (English) Resolve absolute path to this script (works for PATH invocation).
  sp="$0"
  case "$sp" in
    */*) : ;;
    *) sp=$(command -v -- "$0" 2>/dev/null || echo "$0") ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    rp=$(realpath "$sp" 2>/dev/null || true)
    [ -n "$rp" ] && { echo "$rp"; return; }
  fi
  if command -v readlink >/dev/null 2>&1; then
    rp=$(readlink -f "$sp" 2>/dev/null || true)
    [ -n "$rp" ] && { echo "$rp"; return; }
  fi
  case "$sp" in
    /*) echo "$sp" ;;
    *)  echo "$(pwd)/$sp" ;;
  esac
}

# -----------------------------------------------------------------------------
# Self-update (quiet when AUTO_UPDATE=no unless forced)
# -----------------------------------------------------------------------------
self_update_check() {
  # (English) Perform a one-shot self-update check. If AUTO_UPDATE=yes or
  # --self-update is passed, download and replace atomically; otherwise be quiet.
  [ "${CONF2GIT_UPDATED:-}" = "1" ] && return 0
  SELF_UPDATE_QUIET="${SELF_UPDATE_QUIET:-$SELF_UPDATE_QUIET_DEFAULT}"
  [ -n "${UPDATE_URL:-}" ] || return 0

  SCRIPT_PATH="$(resolve_script_path)"
  [ -r "$SCRIPT_PATH" ] || return 0

  TMP_FILE=$(mktemp -t conf2git_update.XXXXXX) || return 1
  if ! fetch_to "$UPDATE_URL" "$TMP_FILE"; then
    # Only chatty if debug:
    [ "${CONF2GIT_DEBUG:-}" = "1" ] && log "Self-update: download failed from $UPDATE_URL"
    rm -f "$TMP_FILE"
    return 1
  fi

  # Normalize CRLF -> LF
  tr -d '\r' < "$TMP_FILE" > "$TMP_FILE.norm" && mv "$TMP_FILE.norm" "$TMP_FILE"

  # Basic sanity
  head -n 5 "$TMP_FILE" | grep -Eq '^#!/bin/(sh|bash)' || { rm -f "$TMP_FILE"; return 1; }
  grep -q "conf2git" "$TMP_FILE" || { rm -f "$TMP_FILE"; return 1; }

  # Optional integrity pin
  if [ -n "${EXPECTED_SHA256:-}" ]; then
    NEW_SUM_CHECK=$(sha256_file "$TMP_FILE" 2>/dev/null || echo "none")
    [ "$NEW_SUM_CHECK" = "$EXPECTED_SHA256" ] || { rm -f "$TMP_FILE"; return 1; }
  fi

  OLD_SUM=$(sha256_file "$SCRIPT_PATH" 2>/dev/null || echo "none")
  NEW_SUM=$(sha256_file "$TMP_FILE" 2>/dev/null || echo "none")

  if [ "$OLD_SUM" = "$NEW_SUM" ]; then
    [ "${CONF2GIT_DEBUG:-}" = "1" ] && log "Self-update: already up to date"
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 0
    return 0
  fi

  # Not applying? (AUTO_UPDATE=no and no --self-update)
  if [ "${AUTO_UPDATE:-no}" != "yes" ] && [ "$FORCE_UPDATE" != true ]; then
    if [ "$SELF_UPDATE_QUIET" = "no" ] || [ "${CONF2GIT_DEBUG:-}" = "1" ]; then
      log "Self-update: update available but AUTO_UPDATE=no and --self-update not used"
    fi
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 1
    return 0
  fi

  # Apply update
  [ -w "$SCRIPT_PATH" ] || { rm -f "$TMP_FILE"; $SELF_UPDATE_ONLY && exit 1; return 1; }
  TS=$(date +%Y%m%d%H%M%S)
  BACKUP="${SCRIPT_PATH}.bak.$TS"
  cp -p "$SCRIPT_PATH" "$BACKUP" 2>/dev/null || { rm -f "$TMP_FILE"; $SELF_UPDATE_ONLY && exit 1; return 1; }
  chmod 0755 "$TMP_FILE" 2>/dev/null || true
  mv "$TMP_FILE" "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH" || { $SELF_UPDATE_ONLY && exit 1; return 1; }

  log "Self-update: updated (backup: $BACKUP). Re-exec new version..."
  export CONF2GIT_UPDATED=1
  if [ -n "${CONF2GIT_ORIG_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    exec "$SCRIPT_PATH" $CONF2GIT_ORIG_ARGS
  else
    exec "$SCRIPT_PATH"
  fi
}

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=true ;;
    --config)  [ $# -ge 2 ] || { echo "Error: --config requires a path" >&2; exit 2; }
               CFG_FILE="$2"; shift ;;
    --self-update)      FORCE_UPDATE=true ;;
    --self-update-only) FORCE_UPDATE=true; SELF_UPDATE_ONLY=true ;;
    -r|--report)        REPORT=true ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ "${CONF2GIT_REPORT:-}" = "1" ] && REPORT=true

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------
if [ -f "$CFG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CFG_FILE"
else
  echo "Error: configuration file not found: $CFG_FILE" >&2
  exit 1
fi

# Defaults based on cfg or fallbacks
ALIGN_MODE="${ALIGN_MODE:-$ALIGN_MODE_DEFAULT}"
SELF_UPDATE_QUIET="${SELF_UPDATE_QUIET:-$SELF_UPDATE_QUIET_DEFAULT}"

# -----------------------------------------------------------------------------
# Validate required configuration (BEFORE touching Git or rsync)
# -----------------------------------------------------------------------------
# (English) A missing or wrong variable here is the #1 cause of accidental scope issues.
required="CONF_DIRS BASE_DIR REPO_ROOT GIT_REPO_URL TARGET_PATH REPO_DIR LOCKFILE GIT_USER_NAME GIT_USER_EMAIL"
for v in $required; do
  eval val="\${$v:-}"
  [ -n "$val" ] || fatal "Config: required variable missing or empty: $v"
done

# (English) Safety: TARGET_PATH must be a relative subdir with at least two segments.
case "${TARGET_PATH}" in
  ""|"."|"/"|*\ * ) fatal "Safety: invalid TARGET_PATH='${TARGET_PATH}' (empty, dot, slash, or spaces)";;
esac
# require at least two path segments (e.g., "freebsd/hostname")
case "${TARGET_PATH}" in
  */* ) : ;;  # ok
  *   ) fatal "Safety: TARGET_PATH must have at least two segments (e.g., 'freebsd/hostname')" ;;
esac

# (English) Safety: REPO_DIR must be exactly REPO_ROOT/TARGET_PATH
EXPECTED_REPO_DIR="${REPO_ROOT%/}/${TARGET_PATH}"
if [ "${REPO_DIR%/}" != "${EXPECTED_REPO_DIR%/}" ]; then
  fatal "Safety: REPO_DIR='${REPO_DIR}' must equal '${EXPECTED_REPO_DIR}'"
fi
# (English) Extra: forbid REPO_DIR being the same as REPO_ROOT (too wide)
[ "${REPO_DIR%/}" != "${REPO_ROOT%/}" ] || fatal "Safety: REPO_DIR must not be equal to REPO_ROOT"

# -----------------------------------------------------------------------------
# Rotate logs (early) and Self-update check (afterwards only once)
# -----------------------------------------------------------------------------
rotate_logs_if_needed

# Concurrency control (portable)
if [ "${__CONF2GIT_LOCKED:-}" != "1" ]; then
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
    LOCKDIR="${LOCKFILE}.d"
    mkdir "${LOCKDIR}" 2>/dev/null || fatal "Another process is running (dir-lock: ${LOCKDIR})."
    trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT INT TERM
    export __CONF2GIT_LOCKED=1
  fi
fi

# Now that we are the only running instance, we can check for self-update quietly.
self_update_check "$@"
$SELF_UPDATE_ONLY && exit 0

# -----------------------------------------------------------------------------
# Git availability and version detection
# -----------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || fatal "Git not found"
GIT_VER_RAW=$(git version | awk '{print $3}')
GIT_VER_MAJOR=${GIT_VER_RAW%%.*}
GIT_VER_MINOR=${GIT_VER_RAW#*.}; GIT_VER_MINOR=${GIT_VER_MINOR%%.*}

GIT_LEGACY_SPARSE=false
if [ "${GIT_VER_MAJOR:-0}" -lt 2 ] || { [ "${GIT_VER_MAJOR:-0}" -eq 2 ] && [ "${GIT_VER_MINOR:-0}" -lt 25 ]; }; then
  GIT_LEGACY_SPARSE=true
fi

detect_default_branch() {
  # (English) Try to read origin/HEAD; fallback to 'main' if not available.
  db=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | awk -F/ '{print $2}')
  echo "${db:-main}"
}

modern_sparse_enable() { git sparse-checkout init --cone; }
modern_sparse_set()    { git sparse-checkout set "$1"; }

legacy_sparse_enable() {
  # (English) Legacy sparse-checkout for Git <2.25
  git config core.sparseCheckout true
  mkdir -p .git/info
  : > .git/info/sparse-checkout
}
legacy_sparse_set() {
  # (English) Write rooted patterns to include ONLY TARGET_PATH and its subtree.
  sc=".git/info/sparse-checkout"
  {
    printf "/%s/\n"  "$1"
    printf "/%s/**\n" "$1"
  } > "$sc"
  # (English) Apply to working tree
  git read-tree -mu HEAD 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Prepare repository (clone/init sparse) strictly limited to TARGET_PATH
# -----------------------------------------------------------------------------
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT" || fatal "Cannot create $REPO_ROOT"

  log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT" || fatal "git clone failed"
  cd "$REPO_ROOT" || fatal "Cannot cd into $REPO_ROOT"

  DEFAULT_BRANCH="$(detect_default_branch || echo main)"

  if $GIT_LEGACY_SPARSE; then
    log "Using legacy sparse-checkout (Git $GIT_VER_RAW)"
    legacy_sparse_enable
    legacy_sparse_set "$TARGET_PATH"
    git checkout "$DEFAULT_BRANCH" 2>/dev/null || \
    git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || true
  else
    log "Using modern sparse-checkout (Git $GIT_VER_RAW)"
    modern_sparse_enable
    modern_sparse_set "$TARGET_PATH"
    git checkout "$DEFAULT_BRANCH" 2>/dev/null || \
    git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || true
  fi

  # Set identity for automation
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
else
  cd "$REPO_ROOT" || fatal "Cannot cd into $REPO_ROOT"
  DEFAULT_BRANCH="$(detect_default_branch || echo main)"

  # Ensure sparse-checkout restricted to TARGET_PATH
  if $GIT_LEGACY_SPARSE; then
    log "Ensuring legacy sparse-checkout for $TARGET_PATH"
    git config core.sparseCheckout true
    legacy_sparse_set "$TARGET_PATH"
  else
    if git sparse-checkout list >/dev/null 2>&1; then
      log "Sparse-checkout already enabled. Setting path: $TARGET_PATH"
      modern_sparse_set "$TARGET_PATH"
    else
      log "Enabling sparse-checkout and restricting to: $TARGET_PATH"
      modern_sparse_enable
      modern_sparse_set "$TARGET_PATH"
    fi
  fi

  # Remote alignment (safe policy)
  log "Updating refs (ALIGN_MODE=${ALIGN_MODE})"
  git fetch --prune || log "Warning: git fetch failed; continuing with local refs."

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -n "$CURRENT_BRANCH" ] || CURRENT_BRANCH="$DEFAULT_BRANCH"
  [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ] || git checkout "$DEFAULT_BRANCH" || true

  case "$ALIGN_MODE" in
    reset)
      git reset --hard "origin/$DEFAULT_BRANCH" || fatal "Hard reset to origin/$DEFAULT_BRANCH failed"
      ;;
    rebase|*)
      # (English) Try FF merge if possible; otherwise rebase. If rebase fails and
      # there are no local commits, fall back to hard reset to align safely.
      if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null; then
        git merge --ff-only "origin/$DEFAULT_BRANCH" || log "Warning: ff-only merge failed unexpectedly."
      else
        if git rebase --autostash "origin/$DEFAULT_BRANCH"; then
          :
        else
          # Check if we have local commits ahead
          set +e
          AHEAD_BEHIND="$(git rev-list --left-right --count "origin/$DEFAULT_BRANCH...HEAD" 2>/dev/null)"
          set -e
          LOCAL_AHEAD=$(echo "${AHEAD_BEHIND:-0 0}" | awk '{print $2}')
          if [ "${LOCAL_AHEAD:-0}" = "0" ]; then
            log "Rebase failed with no local commits; aligning via hard reset."
            git reset --hard "origin/$DEFAULT_BRANCH" || fatal "Hard reset failed"
          else
            fatal "Rebase failed and local commits exist; manual resolution required"
          fi
        fi
      fi
      ;;
  esac

  # Refresh identity
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
fi

# -----------------------------------------------------------------------------
# Ensure target directory exists (strict scope)
# -----------------------------------------------------------------------------
[ -d "$REPO_DIR" ] || mkdir -p "$REPO_DIR" || fatal "Unable to create $REPO_DIR"

# -----------------------------------------------------------------------------
# rsync capabilities and excludes
# -----------------------------------------------------------------------------
RSYNC_AXH=""
rsync --help 2>&1 | grep -qE '\-H' && RSYNC_AXH="$RSYNC_AXH -H"
rsync --help 2>&1 | grep -qE '\-A' && RSYNC_AXH="$RSYNC_AXH -A"
rsync --help 2>&1 | grep -qE '\-X' && RSYNC_AXH="$RSYNC_AXH -X"

# (English) Sensible excludes to avoid trash/temp and Git internals
RSYNC_EXCLUDES="--exclude '*.pid' --exclude '*.db' --exclude '*.core' --exclude '*.sock' --exclude '*.swp' --exclude 'cache/' --exclude '.git/'"

# -----------------------------------------------------------------------------
# Reporting init (optional)
# -----------------------------------------------------------------------------
REPORT_START_EPOCH=$(date +%s)
REPORT_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_DIRS_TOTAL=0
REPORT_DIRS_SYNCED=0
REPORT_DIRS_MISSING=0
REPORT_RSYNC_LOG=""
REPORT_COMMITTED="no"
REPORT_COMMIT_SHA=""

if $REPORT; then
  REPORT_RSYNC_LOG=$(mktemp -t conf2git_rsync.XXXXXX)
fi

# -----------------------------------------------------------------------------
# Sync configuration directories (strictly under REPO_DIR)
# -----------------------------------------------------------------------------
for DIR in $CONF_DIRS; do
  REPORT_DIRS_TOTAL=$((REPORT_DIRS_TOTAL + 1))
  if [ -d "$DIR" ]; then
    # (English) Create a sanitized destination name from absolute path
    DEST_NAME=$(echo "$DIR" | sed 's#^/##; s#/#_#g')
    [ -n "$DEST_NAME" ] || fatal "Safety: empty DEST_NAME for source '$DIR'"

    DEST_PATH="$REPO_DIR/$DEST_NAME"

    log "Syncing $DIR -> $DEST_PATH/"
    if $DRYRUN; then
      if $REPORT; then
        # shellcheck disable=SC2086
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/" | tee -a "$REPORT_RSYNC_LOG"
      else
        # shellcheck disable=SC2086
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/"
      fi
    else
      # shellcheck disable=SC2086
      if $REPORT; then
        rsync -aiv $RSYNC_AXH --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/" | tee -a "$REPORT_RSYNC_LOG"
      else
        rsync -a   $RSYNC_AXH --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/"
      fi
    fi

    REPORT_DIRS_SYNCED=$((REPORT_DIRS_SYNCED + 1))
  else
    log "Warning: directory not found: $DIR"
    REPORT_DIRS_MISSING=$((REPORT_DIRS_MISSING + 1))
  fi
done

# -----------------------------------------------------------------------------
# Stage/commit/push limited strictly to TARGET_PATH (with pre-commit safety)
# -----------------------------------------------------------------------------
if ! $DRYRUN; then
  log "Staging changes only under: $TARGET_PATH"
  git add -- "$TARGET_PATH"

  # (English) Pre-commit SAFETY: abort if anything staged lies outside TARGET_PATH.
  if ! git diff --cached --name-only | awk -v p="${TARGET_PATH%/}/" 'NF{ if (index($0, p)!=1) { exit 1 } }'; then
    log "Safety: staged changes detected outside '${TARGET_PATH}/'. Aborting."
    git reset -q    # unstage everything
    exit 1
  fi

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

# -----------------------------------------------------------------------------
# Final report (optional)
# -----------------------------------------------------------------------------
if $REPORT; then
  END_EPOCH=$(date +%s)
  END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
  DURATION=$((END_EPOCH - REPORT_START_EPOCH))

  CHANGES=0
  if [ -n "$REPORT_RSYNC_LOG" ] && [ -f "$REPORT_RSYNC_LOG" ]; then
    CHANGES=$(grep -E '^[<>ch\*].' "$REPORT_RSYNC_LOG" 2>/dev/null | wc -l | awk '{print $1}')
    rm -f "$REPORT_RSYNC_LOG" 2>/dev/null || true
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
fi