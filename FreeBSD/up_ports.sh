#!/bin/sh
# up_ports.sh - v1.0
# Script to update the FreeBSD ports tree, check for security vulnerabilities,
# and compare installed packages against the ports tree for available updates.
# Author: Karim (adapted version by ChatGPT)

set -eu

# === Configuration ===
PORTSDIR="/usr/ports"
GIT="/usr/local/bin/git"
PKG="/usr/sbin/pkg"
DATE=$(date +%F_%T)

# === Logging function ===
log() {
  echo "[$DATE] $1"
}

log "Starting ports update and security check..."

# === Step 1: Ensure the ports tree is a Git repo ===
if [ ! -d "$PORTSDIR/.git" ]; then
  log "❌ Error: ${PORTSDIR} is not a valid Git repository."
  exit 1
fi

# === Step 2: Update the ports tree ===
cd "$PORTSDIR"
log "📦 Updating ports tree via git..."
$GIT pull --ff-only || {
  log "❌ Git pull failed."
  exit 1
}

# === Step 3: Update the INDEX file (optional for compatibility with some tools) ===
log "📑 Fetching up-to-date INDEX file..."
make fetchindex || {
  log "⚠️ Failed to fetch INDEX. Continuing anyway."
}

# === Step 4: Run pkg audit to detect known vulnerabilities ===
log "🔎 Running pkg audit..."
if ! $PKG audit -F > /tmp/audit_result.txt 2>&1; then
  log "⚠️ Vulnerabilities found:"
  cat /tmp/audit_result.txt

  # === Step 5: Parse vulnerable packages and compare with ports ===
  log "📊 Checking if updated versions are available in the ports tree..."
  grep -Eo '^[a-zA-Z0-9_\.\-]+-[0-9][^ ]*' /tmp/audit_result.txt | sort -u | while read -r pkg; do
    origin=$(pkg info -o "$pkg" 2>/dev/null | awk '{print $2}' || true)

    echo
    echo "🧩 $pkg:"
    if [ -n "$origin" ] && [ -f "$PORTSDIR/$origin/Makefile" ]; then
      # Get versions
      port_version=$(make -C "$PORTSDIR/$origin" -V PKGNAME 2>/dev/null || echo "unknown")
      installed_version=$($PKG info "$pkg" 2>/dev/null | awk 'NR==1 {print $1}' || echo "unknown")

      # Compare
      echo "   ➤ Installed: $installed_version"
      echo "   ➤ In ports:  $port_version"

      if [ "$port_version" = "unknown" ]; then
        echo "   ⚠️  Failed to extract version from ports."
      elif [ "$installed_version" = "$port_version" ]; then
        echo "   ✅ Package is up to date."
      else
        echo "   ⚠️  Update available in ports."
      fi
    else
      echo "   ⚠️  Could not determine origin or port is missing."
    fi
  done
else
  log "✅ No vulnerabilities found."
fi

log "✅ Ports update and vulnerability check completed."