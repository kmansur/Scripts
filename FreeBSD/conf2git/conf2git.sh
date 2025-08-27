#!/bin/sh
# /usr/local/scripts/conf2git.sh
# v1.3 - Safely exports configuration directories to Git (lockfile, dry-run, logging, help, self-update)
# Author: Karim Mansur <karim.mansur@outlook.com>
#
# Changelog v1.3:
# - Add pre-execution update check: if a newer script is available and
#   AUTO_UPDATE="yes" (or --self-update), replace and re-exec; otherwise warn.
# - Hardened download (fetch/curl/wget), CRLF normalization, hash compare.
# - Log function tolerates unset LOGFILE (prints to stdout).

set -eu

###############################################################################
# Defaults (local only; everything else comes from the config file)
###############################################################################
HOSTNAME_SHORT=$(hostname -s)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
CFG_FILE="/usr/local/scripts/conf2git.cfg"   # can be overridden with --config

# Runtime flags
DRYRUN=false
FORCE_UPDATE=false

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
  -h, --help           Show this help and exit

The config file must define (at minimum):
  CONF_DIRS, BASE_DIR, REPO_ROOT, GIT_REPO_URL,
  TARGET_PATH, REPO_DIR, LOCKFILE, LOGFILE,
  GIT_USER_NAME, GIT_USER_EMAIL, AUTO_UPDATE, UPDATE_URL

Example template: /usr/local/scripts/conf2git.cfg.example
USAGE
}

log() {
  # Print to stdout always; append to $LOGFILE if it exists/is set
  MSG="$(date '+%Y-%m-%d %H:%M:%S') $*"
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

# Enhanced self-update check: always checks availability; updates only if allowed
self_update_check() {
  [ -n "${UPDATE_URL:-}" ] || { log "Self-update: UPDATE_URL is not set; skipping"; return 0; }

  # Resolve absolute script path
  SCRIPT_PATH="$0"
  case "$SCRIPT_PATH" in
    /*) : ;;
    *) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
  esac
  [ -r "$SCRIPT_PATH" ] || { log "Self-update: cannot read current script; skipping"; return 0; }

  TMP_FILE=$(mktemp -t conf2git_update.XXXXXX)
  if ! fetch_to "$UPDATE_URL" "$TMP_FILE"; then
    log "Self-update: unable to download from $UPDATE_URL (continuing without update)"
    rm -f "$TMP_FILE"
    return 0
  fi

  # Normalize CRLF -> LF just in case
  tr -d '\r' < "$TMP_FILE" > "$TMP_FILE.norm" && mv "$TMP_FILE.norm" "$TMP_FILE"

  # Basic sanity check
  if ! head -n 5 "$TMP_FILE" | grep -Eq "^#!/bin/sh|^#!/bin/bash" || ! grep -q "conf2git" "$TMP_FILE"; then
    log "Self-update: downloaded file is not a valid conf2git script (continuing)"
    rm -f "$TMP_FILE"
    return 0
  fi

  OLD_SUM=$(sha256_file "$SCRIPT_PATH" 2>/dev/null || echo "none")
  NEW_SUM=$(sha256_file "$TMP_FILE" 2>/dev/null || echo "none")
  if [ "$OLD_SUM" = "$NEW_SUM" ]; then
    log "Self-update: local script is up to date"
    rm -f "$TMP_FILE"
    return 0
  fi

  # Update available
  if [ "${AUTO_UPDATE:-no}" = "yes" ] || [ "$FORCE_UPDATE" = true ]; then
    if [ -w "$SCRIPT_PATH" ]; then
      TS=$(date +%Y%m%d%H%M%S)
      BACKUP="${SCRIPT_PATH}.bak.$TS"
      cp -p "$SCRIPT_PATH" "$BACKUP" || { log "Self-update: cannot create backup; aborting update"; rm -f "$TMP_FILE"; return 0; }
      chmod 0755 "$TMP_FILE" && mv "$TMP_FILE" "$SCRIPT_PATH.new" && mv "$SCRIPT_PATH.new" "$SCRIPT_PATH"
      rm -f "$TMP_FILE"
      log "Self-update: update applied (backup: $BACKUP). Re-executing new version..."
      export CONF2GIT_UPDATED=1
      exec "$SCRIPT_PATH" "$@"
    else
      log "Self-update: update available but script is not writable; continuing without updating"
      rm -f "$TMP_FILE"
      return 0
    fi
  else
    log "Self-update: update available. AUTO_UPDATE=no; run with --self-update or set AUTO_UPDATE=\"yes\" to auto-apply"
    rm -f "$TMP_FILE"
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
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

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

###############################################################################
# Optional self-update (prior to locking)
###############################################################################
self_update_check "$@"

###############################################################################
# Concurrency control (lockfile)
###############################################################################
if [ -e "$LOCKFILE" ]; then
  log "Another run is in progress (lockfile $LOCKFILE exists). Aborting."
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT
: > "$LOCKFILE"

###############################################################################
# Prepare repo with sparse-checkout limited to this host
###############################################################################
if [ ! -d "$REPO_ROOT/.git" ]; then
  mkdir -p "$REPO_ROOT"
  log "Cloning repository (no-checkout): $GIT_REPO_URL"
  git clone --no-checkout "$GIT_REPO_URL" "$REPO_ROOT"
  cd "$REPO_ROOT"
  git sparse-checkout init --cone
  git sparse-checkout set "$TARGET_PATH"
  git checkout main || git checkout -b main origin/main
  # Enforce committer identity for this local repo
  git config user.name "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
else
  cd "$REPO_ROOT"
  # Ensure sparse-checkout is enabled and restricted
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
  [ "$CURRENT_BRANCH" = "main" ] || git checkout main || true
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
  log "Pushing to 'main'"
  git push origin main
  log "Done."
else
  log "Dry-run: nothing was committed."
fi