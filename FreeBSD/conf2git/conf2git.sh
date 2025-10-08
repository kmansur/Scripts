#!/bin/sh
# =============================================================================
# conf2git.sh - v1.6.3-lts3 (stable & hardened)
# -----------------------------------------------------------------------------
# English-only comments. Compatible with Git >= 2.17.1 (legacy sparse-checkout)
# and Git >= 2.25 (modern sparse-checkout).
#
# Key safety rails:
# - Strict TARGET_PATH/REPO_DIR validation.
# - Sparse-checkout restricted to TARGET_PATH (legacy or modern).
# - Rsync mirrors only into ${REPO_DIR}/<sanitized_name>.
# - Index hygiene before staging (reset + refresh).
# - Staging limited to TARGET_PATH; pre-commit NUL-safe scan; logs first offender.
# - Repo toplevel safety (git rev-parse --show-toplevel must == REPO_ROOT).
# - Per-OS locking (FreeBSD lockf / Linux flock / dir-lock fallback).
# - Optional self-update with integrity checks (quotepath-safe).
# - Optional end-of-run report and log rotation.
# =============================================================================

set -eu

# --- environment hardening ----------------------------------------------------
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

CONF2GIT_ORIG_ARGS="$*"

HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"

# Runtime flags
DRYRUN=false
FORCE_UPDATE=false
SELF_UPDATE_ONLY=false
REPORT=false

# Policies (safe defaults)
ALIGN_MODE_DEFAULT="rebase"       # rebase | reset
SELF_UPDATE_QUIET_DEFAULT="yes"   # yes | no

# --- helpers ------------------------------------------------------------------
log() {
  # (English) Print message to stdout and append to LOGFILE if set.
  MSG="$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME_SHORT][$$] $*"
  echo "$MSG"
  if [ "${LOGFILE:-}" != "" ]; then
    echo "$MSG" >> "$LOGFILE" 2>/dev/null || true
  fi
}

fatal() {
  # (English) Log fatal error and exit non-zero.
  log "FATAL: $*"
  exit 1
}

rotate_logs_if_needed() {
  # (English) Rotate LOGFILE if larger than ~100KB, keep last 12 as .gz.
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
  --dry-run            Simulate rsync (no commit/push)
  --config <path>      Use an alternative config file (default: $CFG_FILE)
  --self-update        Force a self-update from UPDATE_URL
  --self-update-only   Only perform self-update and exit
  -r, --report         Print a management report at the end
  -h, --help           Show this help and exit
USAGE
}

sha256_file() {
  # (English) Portable SHA-256: FreeBSD 'sha256 -q' or GNU 'sha256sum'.
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$1"
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

fetch_to() {
  # (English) Download helper: FreeBSD fetch, curl, or wget.
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
  # (English) Resolve absolute path to this script (handles PATH lookups).
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

# --- self-update --------------------------------------------------------------
self_update_check() {
  # (English) One-shot self-update: download new script, verify, replace, re-exec.
  [ "${CONF2GIT_UPDATED:-}" = "1" ] && return 0
  SELF_UPDATE_QUIET="${SELF_UPDATE_QUIET:-$SELF_UPDATE_QUIET_DEFAULT}"
  [ -n "${UPDATE_URL:-}" ] || return 0

  SCRIPT_PATH="$(resolve_script_path)"
  [ -r "$SCRIPT_PATH" ] || return 0

  TMP_FILE=$(mktemp -t conf2git_update.XXXXXX) || return 1
  if ! fetch_to "$UPDATE_URL" "$TMP_FILE"; then
    [ "${CONF2GIT_DEBUG:-}" = "1" ] && log "Self-update: download failed from $UPDATE_URL"
    rm -f "$TMP_FILE"
    return 1
  fi

  # (English) Normalize CRLF to LF for safety.
  tr -d '\r' < "$TMP_FILE" > "$TMP_FILE.norm" && mv "$TMP_FILE.norm" "$TMP_FILE"

  # (English) Sanity check the downloaded script.
  head -n 5 "$TMP_FILE" | grep -Eq '^#!/bin/(sh|bash)' || { rm -f "$TMP_FILE"; return 1; }
  grep -q "conf2git" "$TMP_FILE" || { rm -f "$TMP_FILE"; return 1; }

  # (English) Optional integrity check against EXPECTED_SHA256.
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

  if [ "${AUTO_UPDATE:-no}" != "yes" ] && [ "$FORCE_UPDATE" != true ]; then
    if [ "$SELF_UPDATE_QUIET" = "no" ] || [ "${CONF2GIT_DEBUG:-}" = "1" ]; then
      log "Self-update: update available but AUTO_UPDATE=no and --self-update not used"
    fi
    rm -f "$TMP_FILE"
    $SELF_UPDATE_ONLY && exit 1
    return 0
  fi

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

# --- CLI ----------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=true ;;
    --config)  [ $# -ge 2 ] || { echo "Error: --config requires a path" >&2; exit 2; }
               CFG_FILE="$2"; shift ;;
    --self-update)      FORCE_UPDATE=true ;;
    --self-update-only) FORCE_UPDATE=true; SELF_UPDATE_ONLY=true ;;
    -r|--report)        REPORT=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ "${CONF2GIT_REPORT:-}" = "1" ] && REPORT=true

# --- load config --------------------------------------------------------------
if [ -f "$CFG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CFG_FILE"
else
  echo "Error: configuration file not found: $CFG_FILE" >&2
  exit 1
fi

ALIGN_MODE="${ALIGN_MODE:-$ALIGN_MODE_DEFAULT}"
SELF_UPDATE_QUIET="${SELF_UPDATE_QUIET:-$SELF_UPDATE_QUIET_DEFAULT}"

# --- validate config (strict) -------------------------------------------------
required="CONF_DIRS BASE_DIR REPO_ROOT GIT_REPO_URL TARGET_PATH REPO_DIR LOCKFILE GIT_USER_NAME GIT_USER_EMAIL"
for v in $required; do
  eval val="\${$v:-}"
  [ -n "$val" ] || fatal "Config: required variable missing or empty: $v"
done

case "${TARGET_PATH}" in
  ""|"."|"/"|*\ * ) fatal "Safety: invalid TARGET_PATH='${TARGET_PATH}'" ;;
esac
case "${TARGET_PATH}" in
  */* ) : ;;
  *   ) fatal "Safety: TARGET_PATH must have at least two segments (e.g., 'freebsd/hostname')" ;;
esac

EXPECTED_REPO_DIR="${REPO_ROOT%/}/${TARGET_PATH}"
[ "${REPO_DIR%/}" = "${EXPECTED_REPO_DIR%/}" ] || fatal "Safety: REPO_DIR='${REPO_DIR}' must equal '${EXPECTED_REPO_DIR}'"
[ "${REPO_DIR%/}" != "${REPO_ROOT%/}" ] || fatal "Safety: REPO_DIR must not equal REPO_ROOT"

# --- rotate logs early --------------------------------------------------------
rotate_logs_if_needed

# --- concurrency control ------------------------------------------------------
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

# After becoming the only running instance, check self-update quietly.
self_update_check "$@"
$SELF_UPDATE_ONLY && exit 0

# --- git availability & version ----------------------------------------------
command -v git >/dev/null 2>&1 || fatal "Git not found"
GIT_VER_RAW=$(git version | awk '{print $3}')
GIT_VER_MAJOR=${GIT_VER_RAW%%.*}
GIT_VER_MINOR=${GIT_VER_RAW#*.}; GIT_VER_MINOR=${GIT_VER_MINOR%%.*}

GIT_LEGACY_SPARSE=false
if [ "${GIT_VER_MAJOR:-0}" -lt 2 ] || { [ "${GIT_VER_MAJOR:-0}" -eq 2 ] && [ "${GIT_VER_MINOR:-0}" -lt 25 ]; }; then
  GIT_LEGACY_SPARSE=true
fi

detect_default_branch() {
  db=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | awk -F/ '{print $2}')
  echo "${db:-main}"
}

modern_sparse_enable() { git sparse-checkout init --cone; }
modern_sparse_set()    { git sparse-checkout set "$1"; }

legacy_sparse_enable() {
  git config core.sparseCheckout true
  mkdir -p .git/info
  : > .git/info/sparse-checkout
}
legacy_sparse_set() {
  sc=".git/info/sparse-checkout"
  {
    printf "/%s/\n"  "$1"
    printf "/%s/**\n" "$1"
  } > "$sc"
  git read-tree -mu HEAD 2>/dev/null || true
}

# --- prepare repo -------------------------------------------------------------
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT" || fatal "Cannot create $REPO_ROOT"

  log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT" || fatal "git clone failed"
  cd "$REPO_ROOT" || fatal "Cannot cd into $REPO_ROOT"

  # repo toplevel safety
  REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [ "${REPO_TOP%/}" != "${REPO_ROOT%/}" ] || [ -z "$REPO_TOP" ]; then
    fatal "Safety: Git toplevel ('$REPO_TOP') != REPO_ROOT ('$REPO_ROOT')"
  fi

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

  # commit identity and path printing behavior
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
  git config core.quotepath false
else
  cd "$REPO_ROOT" || fatal "Cannot cd into $REPO_ROOT"

  # repo toplevel safety
  REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [ "${REPO_TOP%/}" != "${REPO_ROOT%/}" ] || [ -z "$REPO_TOP" ]; then
    fatal "Safety: Git toplevel ('$REPO_TOP') != REPO_ROOT ('$REPO_ROOT')"
  fi

  DEFAULT_BRANCH="$(detect_default_branch || echo main)"
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
      if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null; then
        git merge --ff-only "origin/$DEFAULT_BRANCH" || log "Warning: ff-only merge failed unexpectedly."
      else
        if git rebase --autostash "origin/$DEFAULT_BRANCH"; then :; else
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

  # commit identity and path printing behavior
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
  git config core.quotepath false
fi

# --- ensure target dir exists -------------------------------------------------
[ -d "$REPO_DIR" ] || mkdir -p "$REPO_DIR" || fatal "Unable to create $REPO_DIR"

# --- rsync setup --------------------------------------------------------------
RSYNC_AXH=""
rsync --help 2>&1 | grep -qE '\-H' && RSYNC_AXH="$RSYNC_AXH -H"
rsync --help 2>&1 | grep -qE '\-A' && RSYNC_AXH="$RSYNC_AXH -A"
rsync --help 2>&1 | grep -qE '\-X' && RSYNC_AXH="$RSYNC_AXH -X"
RSYNC_EXCLUDES="--exclude '*.pid' --exclude '*.db' --exclude '*.core' --exclude '*.sock' --exclude '*.swp' --exclude 'cache/' --exclude '.git/'"

# --- reporting init -----------------------------------------------------------
REPORT_START_EPOCH=$(date +%s)
REPORT_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_DIRS_TOTAL=0
REPORT_DIRS_SYNCED=0
REPORT_DIRS_MISSING=0
REPORT_RSYNC_LOG=""
REPORT_COMMITTED="no"
REPORT_COMMIT_SHA=""

if ${REPORT}; then
  REPORT_RSYNC_LOG=$(mktemp -t conf2git_rsync.XXXXXX)
fi

# --- sync loop ----------------------------------------------------------------
for DIR in $CONF_DIRS; do
  REPORT_DIRS_TOTAL=$((REPORT_DIRS_TOTAL + 1))
  if [ -d "$DIR" ]; then
    DEST_NAME=$(echo "$DIR" | sed 's#^/##; s#/#_#g')
    [ -n "$DEST_NAME" ] || fatal "Safety: empty DEST_NAME for source '$DIR'"
    DEST_PATH="$REPO_DIR/$DEST_NAME"

    log "Syncing $DIR -> $DEST_PATH/"
    if ${DRYRUN}; then
      if ${REPORT}; then
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/" | tee -a "$REPORT_RSYNC_LOG"
      else
        rsync -aniv --delete $RSYNC_EXCLUDES "$DIR/" "$DEST_PATH/"
      fi
    else
      if ${REPORT}; then
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

# --- stage/commit/push (strictly limited) ------------------------------------
if ! ${DRYRUN}; then
  # --- index hygiene (English) ---
  git reset -q
  git update-index -q --refresh || true
  if [ -n "$(git diff --cached --name-only)" ]; then
    log "Safety: index not clean before staging; cleaning."
    git reset -q
  fi

  log "Staging changes only under: $TARGET_PATH"
  git add -- "$TARGET_PATH"

  # --- pre-commit safety (English) ---
  # Read staged names via NUL-terminated output to handle spaces/quotes/accents.
  OFFENDER_FILE="$(mktemp -t conf2git_offender.XXXXXX)"
  git -c core.quotepath=false diff --cached --name-only -z | tr '\0' '\n' | \
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      "${TARGET_PATH%/}/"*) : ;;          # OK: path is under target
      *) printf '%s' "$path" > "$OFFENDER_FILE"; break ;;
    esac
  done

  if [ -s "$OFFENDER_FILE" ]; then
    OFFENDER="$(cat "$OFFENDER_FILE")"
    rm -f "$OFFENDER_FILE" 2>/dev/null || true
    log "Safety: staged path outside target detected: $OFFENDER"
    log "Safety: aborting and unstaging everything."
    git reset -q
    exit 1
  fi
  rm -f "$OFFENDER_FILE" 2>/dev/null || true

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

# --- final report -------------------------------------------------------------
if ${REPORT}; then
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