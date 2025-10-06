#!/bin/sh
# /usr/local/scripts/conf2git.sh
# v1.6.3 (condensed) — Portable self-lock + smart remote sync + self-update + report + log rotation
# Author: Karim Mansur <karim.mansur@outlook.com>
set -eu
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

# Preserve argv before parsing (for self-update re-exec)
CONF2GIT_ORIG_ARGS="$*"

HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"

DRYRUN=false; FORCE_UPDATE=false; SELF_UPDATE_ONLY=false; REPORT=false
ALIGN_MODE_DEFAULT="rebase"

usage(){ cat <<USAGE
Usage: conf2git.sh [--dry-run] [--config <path>] [--self-update] [--self-update-only] [-r|--report] [-h|--help]
USAGE
}

log(){ msg="$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME_SHORT][$$] $*"; echo "$msg"; [ -n "${LOGFILE:-}" ] && echo "$msg" >>"$LOGFILE" 2>/dev/null || true; }

rotate_logs_if_needed(){
  [ -n "${LOGFILE:-}" ] && [ -f "$LOGFILE" ] || return 0
  sz=$(wc -c <"$LOGFILE" 2>/dev/null || echo 0)
  [ "${sz:-0}" -lt 102400 ] && return 0
  dir=$(dirname "$LOGFILE"); [ -w "$dir" ] || return 0
  i=12; while [ $i -ge 2 ]; do p=$((i-1)); [ -f "$LOGFILE.$p.gz" ] && mv -f "$LOGFILE.$p.gz" "$LOGFILE.$i.gz" || true; i=$((i-1)); done
  if command -v gzip >/dev/null 2>&1; then gzip -c "$LOGFILE" >"$LOGFILE.1.gz" || true; else cp -f "$LOGFILE" "$LOGFILE.1.gz" || true; fi
  : >"$LOGFILE"
}

sha256_file(){ if command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"; else sha256sum "$1" | awk '{print $1}'; fi; }
fetch_to(){ if command -v fetch >/dev/null 2>&1; then fetch -q -o "$2" "$1"; elif command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"; elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"; else return 127; fi; }
resolve_script_path(){ sp="$0"; case "$sp" in */*) :;; *) sp=$(command -v -- "$0" 2>/dev/null || echo "$0");; esac
  if command -v realpath >/dev/null 2>&1; then rp=$(realpath "$sp" 2>/dev/null || true); [ -n "$rp" ] && { echo "$rp"; return; }; fi
  if command -v readlink >/dev/null 2>&1; then rp=$(readlink -f "$sp" 2>/dev/null || true); [ -n "$rp" ] && { echo "$rp"; return; }; fi
  case "$sp" in /*) echo "$sp";; *) echo "$(pwd)/$sp";; esac; }

self_update_check(){
  [ "${CONF2GIT_UPDATED:-}" = "1" ] && { log "Self-update: already updated"; return 0; }
  [ -n "${UPDATE_URL:-}" ] || { log "Self-update: UPDATE_URL not set"; return 0; }
  SCRIPT_PATH="$(resolve_script_path)"; [ -r "$SCRIPT_PATH" ] || { log "Self-update: unreadable script"; return 0; }
  tmp=$(mktemp -t conf2git_update.XXXXXX) || exit 1
  if ! fetch_to "$UPDATE_URL" "$tmp"; then log "Self-update: download failed"; rm -f "$tmp"; return 1; fi
  tr -d '\r' <"$tmp" >"$tmp.norm" && mv "$tmp.norm" "$tmp"
  head -n 5 "$tmp" | grep -Eq '^#!/bin/(sh|bash)' || { log "Self-update: invalid file"; rm -f "$tmp"; return 1; }
  grep -q "conf2git" "$tmp" || { log "Self-update: not conf2git"; rm -f "$tmp"; return 1; }
  if [ -n "${EXPECTED_SHA256:-}" ]; then [ "$(sha256_file "$tmp")" = "$EXPECTED_SHA256" ] || { log "Self-update: hash mismatch"; rm -f "$tmp"; return 1; }; fi
  old="$(sha256_file "$SCRIPT_PATH" 2>/dev/null || echo none)"; new="$(sha256_file "$tmp" 2>/dev/null || echo none)"
  [ "$old" = "$new" ] && { log "Self-update: up to date"; rm -f "$tmp"; $SELF_UPDATE_ONLY && exit 0; return 0; }
  [ -w "$SCRIPT_PATH" ] || { log "Self-update: not writable"; rm -f "$tmp"; $SELF_UPDATE_ONLY && exit 1; return 1; }
  ts=$(date +%Y%m%d%H%M%S); bak="${SCRIPT_PATH}.bak.$ts"; cp -p "$SCRIPT_PATH" "$bak" || { log "Self-update: backup failed"; rm -f "$tmp"; $SELF_UPDATE_ONLY && exit 1; return 1; }
  if [ "${AUTO_UPDATE:-no}" = "yes" ] || [ "$FORCE_UPDATE" = true ]; then
    chmod 0755 "$tmp" 2>/dev/null || true
    mv "$tmp" "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH" || { log "Self-update: replace failed"; $SELF_UPDATE_ONLY && exit 1; return 1; }
    log "Self-update: updated (backup: $bak). Re-exec..."; export CONF2GIT_UPDATED=1
    if [ -n "${CONF2GIT_ORIG_ARGS:-}" ]; then exec "$SCRIPT_PATH" $CONF2GIT_ORIG_ARGS; else exec "$SCRIPT_PATH"; fi
  else
    log "Self-update: update available but AUTO_UPDATE=no and no --self-update flag"
    rm -f "$tmp"; $SELF_UPDATE_ONLY && exit 1; return 0
  fi
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=true;;
    --config) [ $# -ge 2 ] || { echo "Error: --config needs path" >&2; exit 2; }; CFG_FILE="$2"; shift;;
    --self-update) FORCE_UPDATE=true;;
    --self-update-only) FORCE_UPDATE=true; SELF_UPDATE_ONLY=true;;
    -r|--report) REPORT=true;;
    -h|--help) usage; exit 0;;
    *) echo "Error: unknown option $1" >&2; usage; exit 2;;
  esac
  shift
done

# Load config
if [ -f "$CFG_FILE" ]; then . "$CFG_FILE"; else echo "Error: config not found: $CFG_FILE" >&2; exit 1; fi
ALIGN_MODE="${ALIGN_MODE:-$ALIGN_MODE_DEFAULT}"

# Rotate logs, then self-update
rotate_logs_if_needed
self_update_check "$@"
$SELF_UPDATE_ONLY && exit 0

# Report init
REPORT_START_EPOCH=$(date +%s); REPORT_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_DIRS_TOTAL=0; REPORT_DIRS_SYNCED=0; REPORT_DIRS_MISSING=0; REPORT_RSYNC_LOG=""; REPORT_COMMITTED="no"; REPORT_COMMIT_SHA=""
if $REPORT; then REPORT_RSYNC_LOG=$(mktemp -t conf2git_rsync.XXXXXX); fi

# Required variables check
req="CONF_DIRS BASE_DIR REPO_ROOT GIT_REPO_URL TARGET_PATH REPO_DIR LOCKFILE GIT_USER_NAME GIT_USER_EMAIL"
for v in $req; do eval vv="\${$v:-}"; [ -n "$vv" ] || { log "Config: missing $v"; miss=1; }; done
[ "${miss:-0}" = "1" ] && { log "Invalid config. Aborting."; exit 1; }

# Portable self-lock
if [ "${__CONF2GIT_LOCKED:-}" != "1" ]; then
  d="$(dirname -- "${LOCKFILE}")"; [ -d "$d" ] || mkdir -p "$d" || true
  if [ "$OS" = "freebsd" ] && command -v /usr/bin/lockf >/dev/null 2>&1; then
    export __CONF2GIT_LOCKED=1; exec /usr/bin/lockf -k "${LOCKFILE}" "$0" "$@"
  elif command -v /usr/bin/flock >/dev/null 2>&1 || command -v flock >/dev/null 2>&1; then
    FLOCK_BIN="$(command -v /usr/bin/flock || command -v flock)"; export __CONF2GIT_LOCKED=1; exec "$FLOCK_BIN" -n "${LOCKFILE}" "$0" "$@"
  else
    LOCKDIR="${LOCKFILE}.d"; mkdir "$LOCKDIR" 2>/dev/null || { log "Another run is active."; exit 1; }
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
    export __CONF2GIT_LOCKED=1
  fi
fi

# Git version check
if ! command -v git >/dev/null 2>&1; then log "Git not found"; exit 1; fi
v=$(git version | awk '{print $3}'); M=${v%%.*}; m=${v#*.}; m=${m%%.*}
if [ "${M:-0}" -lt 2 ] || { [ "$M" -eq 2 ] && [ "${m:-0}" -lt 25 ]; }; then log "Git >= 2.25 required"; exit 1; fi

detect_default_branch(){ db=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | awk -F/ '{print $2}'); echo "${db:-main}"; }

# Clone or open repo
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT"; log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT"
  cd "$REPO_ROOT"; DEFAULT_BRANCH="$(detect_default_branch || echo main)"
  git sparse-checkout init --cone
  git sparse-checkout set "$TARGET_PATH"
  git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || true
  git config user.name "$GIT_USER_NAME"; git config user.email "$GIT_USER_EMAIL"
else
  cd "$REPO_ROOT"; DEFAULT_BRANCH="$(detect_default_branch || echo main)"
  if git sparse-checkout list >/dev/null 2>&1; then log "Sparse-checkout already enabled. Setting path: $TARGET_PATH"; git sparse-checkout set "$TARGET_PATH"; else log "Enabling sparse-checkout and restricting to: $TARGET_PATH"; git sparse-checkout init --cone; git sparse-checkout set "$TARGET_PATH"; fi
  log "Updating refs (ALIGN_MODE=${ALIGN_MODE})"; git fetch --prune || log "Warning: fetch failed"
  CUR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""); [ -n "$CUR" ] || CUR="$DEFAULT_BRANCH"; [ "$CUR" = "$DEFAULT_BRANCH" ] || git checkout "$DEFAULT_BRANCH" || true
  case "$ALIGN_MODE" in
    reset)
      git reset --hard "origin/$DEFAULT_BRANCH" || { log "Error: hard reset failed"; exit 1; }
    ;;
    rebase|*)
      ab=$(git rev-list --left-right --count "origin/$DEFAULT_BRANCH...HEAD" 2>/dev/null || echo "0 0")
      REMOTE_AHEAD=$(echo "$ab" | awk '{print $1}'); LOCAL_AHEAD=$(echo "$ab" | awk '{print $2}')
      log "Remote ahead=${REMOTE_AHEAD:-0} / Local ahead=${LOCAL_AHEAD:-0}"
      if git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null; then
        git merge --ff-only "origin/$DEFAULT_BRANCH" || log "Warning: ff-only merge failed"
      else
        log "Non-FF detected. Attempting rebase..."
        if ! git rebase --autostash "origin/$DEFAULT_BRANCH"; then
          if [ "${LOCAL_AHEAD:-0}" = "0" ]; then
            log "Rebase failed but no local commits; aligning via hard reset"; git reset --hard "origin/$DEFAULT_BRANCH" || { log "Error: hard reset failed"; exit 1; }
          else
            log "Error: rebase failed and local commits exist; manual intervention required"; exit 1
          fi
        fi
      fi
    ;;
  esac
  git config user.name "$GIT_USER_NAME"; git config user.email "$GIT_USER_EMAIL"
fi

# Ensure target dir
[ -d "$REPO_DIR" ] || mkdir -p "$REPO_DIR" || { log "Error: cannot create $REPO_DIR"; exit 1; }

# Rsync excludes/capabilities
RSYNC_AXH=""
rsync --help 2>&1 | grep -qE '\-H' && RSYNC_AXH="$RSYNC_AXH -H"
rsync --help 2>&1 | grep -qE '\-A' && RSYNC_AXH="$RSYNC_AXH -A"
rsync --help 2>&1 | grep -qE '\-X' && RSYNC_AXH="$RSYNC_AXH -X"
RSYNC_EX="--exclude '*.pid' --exclude '*.db' --exclude '*.core' --exclude '*.sock' --exclude '*.swp' --exclude 'cache/' --exclude '.git/'"

# Sync
for DIR in $CONF_DIRS; do
  REPORT_DIRS_TOTAL=$(( ${REPORT_DIRS_TOTAL:-0} + 1 ))
  if [ -d "$DIR" ]; then
    dest=$(echo "$DIR" | sed 's#^/##; s#/#_#g')
    log "Syncing $DIR -> $REPO_DIR/$dest/"
    if $DRYRUN; then
      if $REPORT; then eval rsync -aniv --delete $RSYNC_EX \"$DIR/\" \"$REPO_DIR/$dest/\" | tee -a \"$REPORT_RSYNC_LOG\"; else eval rsync -aniv --delete $RSYNC_EX \"$DIR/\" \"$REPO_DIR/$dest/\"; fi
    else
      if $REPORT; then eval rsync -aiv $RSYNC_AXH --delete $RSYNC_EX \"$DIR/\" \"$REPO_DIR/$dest/\" | tee -a \"$REPORT_RSYNC_LOG\"; else eval rsync -a $RSYNC_AXH --delete $RSYNC_EX \"$DIR/\" \"$REPO_DIR/$dest/\"; fi
    fi
    REPORT_DIRS_SYNCED=$(( ${REPORT_DIRS_SYNCED:-0} + 1 ))
  else
    log "Warning: directory not found: $DIR"; REPORT_DIRS_MISSING=$(( ${REPORT_DIRS_MISSING:-0} + 1 ))
  fi
done

# Commit & push
if ! $DRYRUN; then
  log "Staging changes only under: $TARGET_PATH"
  git add -- "$TARGET_PATH"
  if git diff --cached --quiet -- "$TARGET_PATH"; then
    log "No changes to commit. Exiting."; exit 0
  fi
  msg="[$OS/$HOSTNAME_SHORT] Automated config backup at $(date '+%Y-%m-%d %H:%M:%S')"
  log "Commit: $msg"; git commit -m "$msg"; log "Pushing to '$DEFAULT_BRANCH'"; git push origin "$DEFAULT_BRANCH"; log "Done."
  REPORT_COMMITTED="yes"; REPORT_COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
else
  log "Dry-run: nothing was committed."
fi

# Report
if $REPORT; then
  END_EPOCH=$(date +%s); END_HUMAN=$(date '+%Y-%m-%d %H:%M:%S'); DUR=$((END_EPOCH-REPORT_START_EPOCH))
  CH=0; [ -n "${REPORT_RSYNC_LOG:-}" ] && [ -f "$REPORT_RSYNC_LOG" ] && CH=$(grep -E '^[<>ch\*].' "$REPORT_RSYNC_LOG" 2>/dev/null | wc -l | awk '{print $1}')
  echo ""; echo "================ Management Report ================"
  echo "Start: $REPORT_START_HUMAN"; echo "End:   $END_HUMAN"; echo "Duration: ${DUR}s"
  echo "Host/OS: $HOSTNAME_SHORT / $OS"; echo "Target: $TARGET_PATH (branch: ${DEFAULT_BRANCH:-unknown})"
  echo "Dirs: total=${REPORT_DIRS_TOTAL:-0} synced=${REPORT_DIRS_SYNCED:-0} missing=${REPORT_DIRS_MISSING:-0}"
  echo "Changes: rsync_itemized=$CH"; echo "Committed: ${REPORT_COMMITTED:-no} ${REPORT_COMMIT_SHA:+(sha $REPORT_COMMIT_SHA)}"
  echo "=================================================="
  [ -n "${REPORT_RSYNC_LOG:-}" ] && rm -f "$REPORT_RSYNC_LOG" || true
fi
