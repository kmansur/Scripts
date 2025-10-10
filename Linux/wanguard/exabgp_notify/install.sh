#!/usr/bin/env bash
# install.sh - Installer/Uninstaller for exabgp-notify (v0.1.1)
# - If run from the project root (contains usr/local/scripts/exabgp_notify.py),
#   installs from local files.
# - Can also download the GitHub tarball and extract the subdir automatically.
# - Supports uninstallation: --uninstall
#
# Requirements: bash, tar, and either curl or wget. systemd for the service.

set -euo pipefail

VERSION="0.1.1"

REPO="${REPO:-kmansur/Scripts}"
BRANCH="${BRANCH:-main}"
SUBDIR="${SUBDIR:-Linux/wnaguard/exabgp_notify}"
WORKDIR="${WORKDIR:-/tmp}"
AUTO_YES=0
DOWNLOAD_ONLY=0
DO_UNINSTALL=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Install from local project tree (default when run in repo root), or fetch from GitHub:
  -b, --branch BRANCH     Use a different branch when downloading (default: main)
  -y, --yes               Auto-confirm installation (non-interactive)
      --download-only     Only download/extract; do not install
      --prefix DIR        Working directory for downloads (default: /tmp)
      --repo  OWNER/NAME  Override repository (default: kmansur/Scripts)
      --subdir PATH       Override subdir (default: Linux/wnaguard/exabgp_notify)
  -u, --uninstall         Uninstall exabgp-notify (disable service and remove files)
  -h, --help              Show this help
USAGE
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch) BRANCH="$2"; shift 2;;
    -y|--yes) AUTO_YES=1; shift;;
    --download-only) DOWNLOAD_ONLY=1; shift;;
    --prefix) WORKDIR="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --subdir) SUBDIR="$2"; shift 2;;
    -u|--uninstall) DO_UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need_one_of() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done
  echo "Missing required command. Install one of: $*" >&2; exit 1
}

# Uninstall path
uninstall_now() {
  echo "[*] Uninstall exabgp-notify (service, config, script)"
  local SUDO=""
  if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { echo "[-] Run as root or install sudo."; exit 1; }
  fi
  $SUDO systemctl disable --now exabgp-notify.service 2>/dev/null || true
  $SUDO rm -f /etc/systemd/system/exabgp-notify.service || true
  $SUDO rm -rf /etc/exabgp-notify || true
  $SUDO rm -f /usr/local/scripts/exabgp_notify.py || true
  $SUDO systemctl daemon-reload || true
  echo "[DONE] Uninstalled."
  exit 0
}

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
  # Confirm unless -y
  if [[ "$AUTO_YES" -eq 0 ]]; then
    read -r -p "Proceed to uninstall exabgp-notify? [y/N] " ans
    case "${ans:-N}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
  fi
  uninstall_now
fi

need_cmd tar
need_one_of curl wget

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$out"; else wget -qO "$out" "$url"; fi
}

ask_yes_no() {
  local prompt="$1" default="${2:-N}" ans
  if [[ "$AUTO_YES" -eq 1 ]]; then echo "Y"; return 0; fi
  read -r -p "$prompt " ans || true
  ans="${ans:-$default}"
  case "$ans" in Y|y|yes|YES) echo "Y";; *) echo "N"; return 1;; esac
}

# Detect local project root
LOCAL_ROOT=""
if [[ -f "usr/local/scripts/exabgp_notify.py" && -f "etc/systemd/system/exabgp-notify.service" && -f "etc/exabgp-notify/exabgp-notify.cfg" ]]; then
  LOCAL_ROOT="$PWD"
fi

TMPDIR="$(mktemp -d "${WORKDIR%/}/exabgp-notify.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

SRC_DIR=""
if [[ -n "$LOCAL_ROOT" ]]; then
  echo "[*] Installing from local project tree: $LOCAL_ROOT"
  SRC_DIR="$LOCAL_ROOT"
else
  echo "[*] Downloading repo tarball from GitHub ..."
  TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  fetch "$TARBALL_URL" "$TMPDIR/repo.tar.gz"
  echo "[*] Extracting to $TMPDIR ..."
  tar -xzf "$TMPDIR/repo.tar.gz" -C "$TMPDIR"
  TOPDIR="$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d -name '*-*' | head -n1)"
  if [[ -z "$TOPDIR" ]]; then echo "[-] Could not find extracted top-level directory." >&2; exit 1; fi

  SRC="${TOPDIR%/}/${SUBDIR}"
  if [[ ! -d "$SRC" ]]; then echo "[-] Subdirectory not found: $SUBDIR" >&2; echo "    Looked in: $SRC" >&2; exit 1; fi
  echo "[*] Source directory: $SRC"
  cp -a "$SRC" "$TMPDIR/exabgp_notify"
  SRC_DIR="$TMPDIR/exabgp_notify"
fi

if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then
  echo "[*] --download-only specified. Extracted/copy available at: $SRC_DIR"
  exit 0
fi

if [[ "$(ask_yes_no 'Proceed with installation to system paths? [y/N]' 'N')" != "Y" ]]; then
  echo "[*] Installation aborted by user."; exit 0
fi

SUDO=""; if [[ "$EUID" -ne 0 ]]; then command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { echo "[-] Run as root or install sudo."; exit 1; }; fi

# Install
echo "[*] Installing files from: $SRC_DIR"
$SUDO install -d -m 0755 /usr/local/scripts
$SUDO install -m 0755 "$SRC_DIR/usr/local/scripts/exabgp_notify.py" /usr/local/scripts/

$SUDO install -d -m 0755 /etc/exabgp-notify
$SUDO install -m 0640 "$SRC_DIR/etc/exabgp-notify/exabgp-notify.cfg" /etc/exabgp-notify/

$SUDO install -m 0644 "$SRC_DIR/etc/systemd/system/exabgp-notify.service" /etc/systemd/system/

# Ensure service user
if ! id -u exabgp >/dev/null 2>&1; then
  if [[ "$(ask_yes_no 'User \"exabgp\" not found. Create a system user? [Y/n]' 'Y')" == "Y" ]]; then
    if command -v adduser >/dev/null 2>&1; then $SUDO adduser --system --home /nonexistent --no-create-home --group exabgp >/dev/null; else $SUDO useradd -r -M -s /usr/sbin/nologin -U exabgp >/dev/null; fi
    echo "[*] Created system user 'exabgp'."
  else
    echo "[!] Service will run as 'exabgp' per unit file. Adjust the unit if needed."
  fi
fi

# Grant config access to group exabgp and ensure dir traversal
$SUDO chgrp exabgp /etc/exabgp-notify/exabgp-notify.cfg || true
$SUDO chmod 0640 /etc/exabgp-notify/exabgp-notify.cfg
$SUDO chmod 0755 /etc/exabgp-notify

# Optional: grant log read access
if [[ "$(ask_yes_no 'Grant exabgp read access to /var/log via group \"adm\" (Debian)? [Y/n]' 'Y')" == "Y" ]]; then
  $SUDO usermod -aG adm exabgp || true
fi

echo "[*] Reloading systemd ..."
$SUDO systemctl daemon-reload

if [[ "$(ask_yes_no 'Enable and start exabgp-notify.service now? [Y/n]' 'Y')" == "Y" ]]; then
  $SUDO systemctl enable --now exabgp-notify.service
  $SUDO systemctl status --no-pager exabgp-notify.service || true
else
  echo "[*] You can start it later with:"
  echo "    sudo systemctl enable --now exabgp-notify.service"
fi

echo
echo "[DONE] Installation finished (v${VERSION})."
echo "      Edit /etc/exabgp-notify/exabgp-notify.cfg with your SMTP/Telegram settings,"
echo "      then check logs: journalctl -u exabgp-notify -f"
echo
