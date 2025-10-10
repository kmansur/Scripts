#!/usr/bin/env bash
# install.sh - Installer/Uninstaller for exabgp-notify (v0.1.3)
set -euo pipefail
VERSION="0.1.3"
REPO="${REPO:-kmansur/Scripts}"
BRANCH="${BRANCH:-main}"
SUBDIR="${SUBDIR:-Linux/wanguard/exabgp_notify}"
WORKDIR="${WORKDIR:-/tmp}"
AUTO_YES=0
DOWNLOAD_ONLY=0
DO_UNINSTALL=0
usage(){ cat <<USAGE
Usage: $0 [options]
  -y, --yes               Non-interactive install
  -b, --branch BRANCH     Branch when downloading (default: main)
      --download-only     Only fetch/extract
      --prefix DIR        Working directory for downloads
      --repo OWNER/NAME   Override repository
      --subdir PATH       Override subdir
  -u, --uninstall         Uninstall exabgp-notify
  -h, --help              Show this help
USAGE
}
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
    *) echo "Unknown option: $1"; usage; exit 2;;
  esac
done
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need_one_of(){ for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done; echo "Missing required command. Install one of: $*"; exit 1; }
uninstall_now(){
  echo "[*] Uninstall exabgp-notify"
  local SUDO=""; if [[ "$EUID" -ne 0 ]]; then command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { echo "[-] Run as root or install sudo."; exit 1; }; fi
  $SUDO systemctl disable --now exabgp-notify.service 2>/dev/null || true
  $SUDO rm -f /etc/systemd/system/exabgp-notify.service || true
  $SUDO rm -rf /etc/exabgp-notify || true
  $SUDO rm -f /usr/local/scripts/exabgp_notify.py || true
  $SUDO systemctl daemon-reload || true
  echo "[DONE] Uninstalled."; exit 0
}
if [[ "$DO_UNINSTALL" -eq 1 ]]; then
  if [[ "$AUTO_YES" -eq 0 ]]; then read -r -p "Proceed to uninstall exabgp-notify? [y/N] " ans; case "${ans:-N}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac; fi
  uninstall_now
fi
need_cmd tar; need_one_of curl wget
fetch(){ local url="$1" out="$2"; if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$out"; else wget -qO "$out" "$url"; fi; }
ask_yes_no(){ local prompt="$1" default="${2:-N}" ans; if [[ "$AUTO_YES" -eq 1 ]]; then echo "Y"; return 0; fi; read -r -p "$prompt " ans || true; ans="${ans:-$default}"; case "$ans" in Y|y|yes|YES) echo "Y";; *) echo "N"; return 1;; esac; }
LOCAL_ROOT=""; if [[ -f "usr/local/scripts/exabgp_notify.py" && -f "etc/systemd/system/exabgp-notify.service" && -f "etc/exabgp-notify/exabgp-notify.cfg" ]]; then LOCAL_ROOT="$PWD"; fi
TMPDIR="$(mktemp -d "${WORKDIR%/}/exabgp-notify.XXXXXX")"; trap 'rm -rf "$TMPDIR"' EXIT
SRC_DIR=""
if [[ -n "$LOCAL_ROOT" ]]; then
  echo "[*] Installing from local project tree: $LOCAL_ROOT"; SRC_DIR="$LOCAL_ROOT"
else
  echo "[*] Downloading repo tarball from GitHub ..."
  TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  fetch "$TARBALL_URL" "$TMPDIR/repo.tar.gz"
  echo "[*] Extracting to $TMPDIR ..."; tar -xzf "$TMPDIR/repo.tar.gz" -C "$TMPDIR"
  TOPDIR="$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d -name '*-*' | head -n1)"
  [[ -z "$TOPDIR" ]] && { echo "[-] Could not find extracted top-level directory."; exit 1; }
  SRC="${TOPDIR%/}/${SUBDIR}"; [[ ! -d "$SRC" ]] && { echo "[-] Subdirectory not found: $SUBDIR"; echo "    Looked in: $SRC"; exit 1; }
  echo "[*] Source directory: $SRC"; cp -a "$SRC" "$TMPDIR/exabgp_notify"; SRC_DIR="$TMPDIR/exabgp_notify"
fi
if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then echo "[*] --download-only. Extracted at: $SRC_DIR"; exit 0; fi
# Detect existing install and confirm overwrite of binaries/unit (config never overwritten)
INSTALLED=0
[[ -f /usr/local/scripts/exabgp_notify.py ]] && INSTALLED=1
[[ -f /etc/systemd/system/exabgp-notify.service ]] && INSTALLED=1
[[ -f /etc/exabgp-notify/exabgp-notify.cfg ]] && INSTALLED=1
if [[ "$INSTALLED" -eq 1 ]]; then
  echo "[-] Detected existing installation."
  echo "    I will NOT overwrite /etc/exabgp-notify/exabgp-notify.cfg."
  echo "    Binaries and unit file can be overwritten if you confirm."
  [[ "$(ask_yes_no 'Overwrite binaries and unit file (config will NOT be overwritten)? [y/N]' 'N')" == "Y" ]] || { echo "[*] Aborted to preserve existing files."; exit 0; }
fi
[[ "$(ask_yes_no 'Proceed with installation to system paths? [y/N]' 'N')" == "Y" ]] || { echo "[*] Aborted."; exit 0; }
SUDO=""; if [[ "$EUID" -ne 0 ]]; then command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { echo "[-] Run as root or install sudo."; exit 1; }; fi
echo "[*] Installing files from: $SRC_DIR"
$SUDO install -d -m 0755 /usr/local/scripts
$SUDO install -m 0755 "$SRC_DIR/usr/local/scripts/exabgp_notify.py" /usr/local/scripts/
$SUDO install -d -m 0755 /etc/exabgp-notify
CFG_DST="/etc/exabgp-notify/exabgp-notify.cfg"
CFG_SRC="$SRC_DIR/etc/exabgp-notify/exabgp-notify.cfg"
if [[ -f "$CFG_DST" ]]; then
  CFG_NEW="/etc/exabgp-notify/exabgp-notify.cfg.v${VERSION}"
  $SUDO install -m 0640 "$CFG_SRC" "$CFG_NEW"
  $SUDO chgrp exabgp "$CFG_NEW" || true
  $SUDO chmod 0640 "$CFG_NEW"
  printf '\n\033[1;31m[NOTICE]\033[0m Existing config preserved: %s\n' "$CFG_DST"
  printf '\033[1;33m[NEW TEMPLATE]\033[0m A new versioned template was installed at: %s\n' "$CFG_NEW"
  printf '\033[1;33m         >>\033[0m Compare and merge changes manually to your active config.\n\n'
else
  $SUDO install -m 0640 "$CFG_SRC" "$CFG_DST"
  $SUDO chgrp exabgp "$CFG_DST" || true
  $SUDO chmod 0640 "$CFG_DST"
fi
$SUDO install -m 0644 "$SRC_DIR/etc/systemd/system/exabgp-notify.service" /etc/systemd/system/
# Ensure directory perms for traversal
$SUDO chmod 0755 /etc/exabgp-notify
# Optional: grant log read access
if [[ "$(ask_yes_no 'Grant exabgp read access to /var/log via group "adm" (Debian)? [Y/n]' 'Y')" == "Y" ]]; then
  $SUDO usermod -aG adm exabgp || true
fi
echo "[*] Reloading systemd ..."; $SUDO systemctl daemon-reload
if [[ "$(ask_yes_no 'Enable and start exabgp-notify.service now? [Y/n]' 'Y')" == "Y" ]]; then
  $SUDO systemctl enable --now exabgp-notify.service
  $SUDO systemctl status --no-pager exabgp-notify.service || true
else
  echo "[*] You can start it later with: sudo systemctl enable --now exabgp-notify.service"
fi
echo; echo "[DONE] Installation finished (v${VERSION})."; echo "Edit /etc/exabgp-notify/exabgp-notify.cfg and check: journalctl -u exabgp-notify -f"; echo
