#!/bin/sh
# /usr/local/scripts/conf2git.sh
# v1.0 - Safely exports configuration directories to GitLab (lockfile, dry-run, logging, help)
# Git author: Karim Mansur <karim.mansur@outlook.com>
#
# Summary (comments in English):
# - One working tree per host using git sparse-checkout (only $OS/$HOSTNAME_SHORT is materialized).
# - Reads a config file for exported directories and variables.
# - Provides --help, --dry-run and --config <file> options.
# - Writes logs to LOGFILE and avoids concurrent runs with a lockfile.

set -eu

###############################################################################
# Defaults
###############################################################################
HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"  # Default config file

# Runtime flags
DRYRUN=false

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
  --config <path>      Use an alternative config file (default: \$CFG_FILE)
  -h, --help           Show this help and exit

The config file must define variables like:
  CONF_DIRS, BASE_DIR, REPO_ROOT, GIT_REPO_URL,
  TARGET_PATH, REPO_DIR, LOCKFILE, LOGFILE,
  GIT_USER_NAME, GIT_USER_EMAIL
USAGE
}

log() {
  MSG="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$MSG" | tee -a "$LOGFILE"
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
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

###############################################################################
# Load configuration file
###############################################################################
if [ -f "$CFG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CFG_FILE"
else
  echo "Error: configuration file not found: $CFG_FILE" >&2
  exit 1
fi

###############################################################################
# Concurrency control
###############################################################################
if [ -e "$LOCKFILE" ]; then
  log "Another run is in progress (lockfile $LOCKFILE exists). Aborting."
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT
: > "$LOCKFILE"

###############################################################################
# Prepare repo with sparse-checkout
###############################################################################
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT"
  log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT"
  cd "$REPO_ROOT"
  git sparse-checkout init --cone
  git sparse-checkout set "$TARGET_PATH"
  git checkout main || git checkout -b main origin/main
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
else
  cd "$REPO_ROOT"
  if git sparse-checkout list >/dev/null 2>&1; then
    log "Sparse-checkout already enabled. Setting path: $TARGET_PATH"
    git sparse-checkout set "$TARGET_PATH"
  else
    log "Enabling sparse-checkout and restricting to: $TARGET_PATH"
    git sparse-checkout init --cone
    git sparse-checkout set "$TARGET_PATH"
  fi
  log "Updating refs (pull ff-only)"
  git pull --ff-only || true
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "")
  if [ "$CURRENT_BRANCH" != "main" ]; then
    git checkout main || true
  fi
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
# Sync configuration directories
###############################################################################
for DIR in $CONF_DIRS; do
  if [ -d "$DIR" ]; then
    DEST_NAME=$(echo "$DIR" | sed 's#^/##; s#/#_#g')
    log "Syncing $DIR -> $REPO_DIR/$DEST_NAME/"
    if $DRYRUN; then
      rsync -an --delete \
        --exclude '*.pid' --exclude '*.db' --exclude '*.core' \
        "$DIR/" "$REPO_DIR/$DEST_NAME/"
    else
      rsync -a --delete \
        --exclude '*.pid' --exclude '*.db' --exclude '*.core' \
        "$DIR/" "$REPO_DIR/$DEST_NAME/"
    fi
  else
    log "Warning: directory not found: $DIR"
  fi
done

###############################################################################
# Commit and push
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
  log "Pushing to 'main'"
  git push origin main
  log "Done."
else
  log "Dry-run: nothing was committed."
fi