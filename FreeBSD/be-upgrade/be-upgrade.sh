#!/bin/sh
# be-upgrade.sh — v0.2
#
# Purpose:
#   Create/update a ZFS Boot Environment (BE), run a chrooted pkg upgrade (-r),
#   unmount, and activate the BE (temporary by default).
#
# Activation modes:
#   - default (temporary)              : use BE only on the next boot.
#   - -p | --permanent                 : activate BE as the default permanently, now.
#   - -P | --promote-after-reboot      : activate temporary now and write a marker file
#                                        with BE name. After you boot into it, run:
#                                        ./be-upgrade.sh --finalize  (to make it permanent)
#
# Sub-commands:
#   --finalize    : promote current BE to permanent if it matches the marker.
#   --status      : show current BE and marker info (if any).
#   --test-marker : create/read a marker without performing BE ops (diagnostics).
#
# Safeguards & quality:
#   - Reuse existing BE (--reuse), force recreate (--force-recreate),
#     or auto-suffix name if the target BE already exists.
#   - Clean, line-by-line printf output (no raw '\n').
#   - Colorized output on TTY (disable with --no-color or NO_COLOR=true).
#   - Robust mountpoint check (mount -p exact match) and mkdir -p for $MNT.
#   - Marker writer ensures parent dir exists, tight perms, and validates content.
#   - Trap-based unmount only after successful mount.
#
# Requirements:
#   - FreeBSD with ZFS Boot Environments (bectl)
#   - pkg on the host (we use 'pkg -r <mount>' to operate inside the BE root)
#
# License: MIT-like (use freely)

set -u  # treat unset vars as errors; avoid 'set -e' because run() handles RC

# -------------------- Defaults / Settings --------------------
BE_NAME="${BE_NAME:-upgrade}"
MNT="${MNT:-/mnt}"
AUTO_REBOOT="false"
PERMANENT="false"
PROMOTE_AFTER="false"
REUSE_EXISTING="false"
FORCE_RECREATE="false"
PKG_YES="-y"
NO_COLOR="${NO_COLOR:-false}"
PROMOTE_MARKER="${PROMOTE_MARKER:-/var/db/be_promote_after_reboot.flag}"  # contains BE name
DO_FINALIZE="false"
DO_STATUS="false"
DO_TEST_MARKER="false"
DEBUG="false"                     # --debug
# -------------------------------------------------------------

# -------------------- Colors (late-initialized) --------------------
# We (re)set colors *after* parsing args to honor --no-color
C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
set_colors() {
  if [ -t 1 ] && [ "${NO_COLOR}" != "true" ]; then
    ESC="$(printf '\033')"
    C_RED="${ESC}[31m"; C_GRN="${ESC}[32m"; C_YEL="${ESC}[33m"; C_CYN="${ESC}[36m"; C_RST="${ESC}[0m"
  else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
  fi
}
# -------------------------------------------------------------------

# -------------------- Helpers --------------------
usage() {
  printf "Usage:\n"
  printf "  %s [options]          # create/mount/upgrade/activate BE (temporary by default)\n" "$0"
  printf "  %s --finalize         # promote to PERMANENT (after reboot with -P)\n" "$0"
  printf "  %s --status           # show marker + current BE\n" "$0"
  printf "  %s --test-marker      # create & read marker only (no BE ops)\n\n" "$0"
  printf "Options:\n"
  printf "  -b NAME               BE name (default: %s)\n" "${BE_NAME}"
  printf "  -m DIR                mountpoint (default: %s)\n" "${MNT}"
  printf "  -y                    reboot without prompt\n"
  printf "  -p, --permanent       activate BE permanently now\n"
  printf "  -P, --promote-after-reboot\n"
  printf "                        activate temporary now and write marker,\n"
  printf "                        then after you boot into it run: %s --finalize\n" "$0"
  printf "      --marker PATH     override marker path (default: %s)\n" "${PROMOTE_MARKER}"
  printf "      --finalize        promote current BE to permanent if it matches marker\n"
  printf "      --status          show current BE and marker\n"
  printf "      --test-marker     write+read a dummy marker to test permissions/path\n"
  printf "      --reuse           reuse existing BE (skip create)\n"
  printf "      --force-recreate  destroy existing BE and recreate (dangerous)\n"
  printf "      --no-color        disable colors\n"
  printf "      --debug           verbose decisions (prints flags/branches)\n"
  printf "  -h, --help            help\n"
  exit 1
}

die()  { printf "%s %s%s\n" "${C_RED}ERROR:${C_RST}" "$*" ""; exit 1; }
ok()   { printf "%s %s%s\n" "${C_GRN}OK:${C_RST}"    "$*" ""; }
warn() { printf "%s %s%s\n" "${C_YEL}WARN:${C_RST}"  "$*" ""; }
info() { printf "%s%s%s\n" "${C_CYN}" "$*" "${C_RST}"; }
dbg()  { [ "${DEBUG}" = "true" ] && printf "%s%s%s\n" "${C_YEL}[debug]${C_RST} " "$*" ""; }

run() {
  printf "+ %s\n" "$*"
  "$@"; rc=$?
  [ $rc -eq 0 ] || die "Command failed (rc=$rc): $*"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

current_be() {
  bectl list -H 2>/dev/null | awk '$2 ~ /N/ {print $1; exit}'
}

mountpoint_in_use() {
  mount -p | awk -v m="${MNT%/}" '($2==m) {found=1} END{exit (found?0:1)}'
}

marker_write() {
  # Robust marker writer with immediate verification.
  be_target="$1"
  parent="$(dirname "${PROMOTE_MARKER}")"
  if [ ! -d "${parent}" ]; then
    run mkdir -p "${parent}"
  fi
  umask_old="$(umask)"; umask 077
  if ! printf "%s\n" "${be_target}" > "${PROMOTE_MARKER}"; then
    umask "${umask_old}"
    id -u >/dev/null 2>&1 && uid="$(id -u)" || uid="?"
    die "Failed to write marker ${PROMOTE_MARKER} (uid=${uid})."
  fi
  umask "${umask_old}"

  # Verify existence and content
  if [ ! -f "${PROMOTE_MARKER}" ]; then
    die "Marker not found right after write: ${PROMOTE_MARKER}"
  fi
  content="$(head -n1 "${PROMOTE_MARKER}" 2>/dev/null | tr -d ' \t\r\n')"
  if [ "${content}" != "${be_target}" ]; then
    die "Marker content mismatch. Got '${content}', expected '${be_target}'."
  fi

  ok "Promotion marker created: ${PROMOTE_MARKER}"
  printf "  target BE: %s\n" "${be_target}"
  printf "  ls -l: "
  ls -l "${PROMOTE_MARKER}" 2>/dev/null || true
}

marker_read() {
  [ -f "${PROMOTE_MARKER}" ] || return 1
  head -n1 "${PROMOTE_MARKER}" | tr -d ' \t\r\n'
}

marker_clear() { rm -f "${PROMOTE_MARKER}" 2>/dev/null || true; }

show_status() {
  CUR="$(current_be)"; [ -n "${CUR:-}" ] || CUR="(unknown)"
  printf "Current BE : %s\n" "${CUR}"
  if TARGET="$(marker_read)"; then
    printf "Marker     : %s\n" "${PROMOTE_MARKER}"
    printf "Marker BE  : %s\n" "${TARGET}"
    if [ "${CUR}" = "${TARGET}" ]; then
      printf "State      : READY to finalize (run: %s --finalize)\n" "$0"
    else
      printf "State      : Current BE != marker; boot into '%s' and then run --finalize\n" "${TARGET}"
    fi
  else
    printf "Marker     : (absent)\n"
  fi
}

finalize_now() {
  need_cmd bectl
  CUR="$(current_be)"; [ -n "${CUR:-}" ] || die "Could not detect current BE."
  TARGET="$(marker_read || true)"; [ -n "${TARGET:-}" ] || die "No marker (${PROMOTE_MARKER}). Nothing to finalize."
  [ "${CUR}" = "${TARGET}" ] || die "Current BE '${CUR}' != marker '${TARGET}'. Boot into '${TARGET}' then run --finalize."
  run bectl activate "${CUR}"
  ok "Promoted to PERMANENT: ${CUR}"
  marker_clear
}

print_guides() {
  be="$1"; cur="$2"
  printf "%s\n" "${C_CYN}➡  To MAKE IT PERMANENT manually (if you chose temporary):${C_RST}"
  printf "    bectl activate %s\n" "$be"
  printf "    reboot     # optional; you can reboot later\n"
  printf "\n"
  printf "%s\n" "${C_CYN}➡  To ROLL BACK:${C_RST}"
  printf "    bectl list\n"
  printf "    bectl activate %s\n" "$cur"
  printf "    reboot     # optional; you can reboot later\n"
}
# -------------------------------------------------------------

# -------------------- Arg parsing --------------------
while [ $# -gt 0 ]; do
  case "${1:-}" in
    -b) BE_NAME="${2:-}"; shift 2 ;;
    -m) MNT="${2:-}"; shift 2 ;;
    -y) AUTO_REBOOT="true"; shift ;;
    -p|--permanent) PERMANENT="true"; shift ;;
    -P|--promote-after-reboot) PROMOTE_AFTER="true"; shift ;;
    --marker) PROMOTE_MARKER="${2:-}"; shift 2 ;;
    --reuse) REUSE_EXISTING="true"; shift ;;
    --force-recreate) FORCE_RECREATE="true"; shift ;;
    --no-color) NO_COLOR="true"; shift ;;
    --finalize) DO_FINALIZE="true"; shift ;;
    --status) DO_STATUS="true"; shift ;;
    --test-marker) DO_TEST_MARKER="true"; shift ;;
    --debug) DEBUG="true"; shift ;;
    -h|--help) usage ;;
    *) printf "ERROR: unknown option: %s\n" "$1"; usage ;;
  esac
done

# Apply color choice *after* parsing (so --no-color works)
set_colors
# ----------------------------------------------------

# -------------------- Sub-commands --------------------
if [ "${DO_TEST_MARKER}" = "true" ]; then
  info "Testing marker path by writing a dummy BE name..."
  marker_write "TEST-BE-NAME"
  printf "Marker content: "
  cat "${PROMOTE_MARKER}" 2>/dev/null || printf "(unreadable)\n"
  exit 0
fi

if [ "${DO_STATUS}" = "true" ]; then
  show_status
  exit 0
fi

if [ "${DO_FINALIZE}" = "true" ]; then
  finalize_now
  exit 0
fi
# ------------------------------------------------------

# -------------------- Main flow --------------------
# Priority: permanent beats promote-after
if [ "${PERMANENT}" = "true" ] && [ "${PROMOTE_AFTER}" = "true" ]; then
  warn "You passed -p and -P together. Proceeding with PERMANENT activation (-p) and ignoring -P."
  PROMOTE_AFTER="false"
fi

# Always echo the chosen flags for visibility
printf "Mode: permanent=%s, promote-after=%s, reuse=%s, force-recreate=%s\n" \
  "${PERMANENT}" "${PROMOTE_AFTER}" "${REUSE_EXISTING}" "${FORCE_RECREATE}"

# Pre-flight checks
[ "$(id -u)" -eq 0 ] || die "Run as root."
need_cmd bectl
need_cmd pkg
need_cmd reboot

CURRENT_BE="$(current_be)"; [ -n "${CURRENT_BE:-}" ] || CURRENT_BE="(unknown)"
printf "Current BE: %s\n" "${CURRENT_BE}"

# Ensure mountpoint exists and is free
if [ ! -d "${MNT}" ]; then
  run mkdir -p "${MNT}"
fi
if mountpoint_in_use; then
  die "Mountpoint '${MNT}' is already mounted. Unmount it (umount '${MNT}') or choose another with -m."
fi

# Handle existing BE name
BE_EXISTS="false"
if bectl list -H | awk '{print $1}' | grep -qx "${BE_NAME}"; then
  BE_EXISTS="true"
fi

if [ "${BE_EXISTS}" = "true" ]; then
  if [ "${FORCE_RECREATE}" = "true" ]; then
    warn "Destroying existing BE '${BE_NAME}' (--force-recreate)."
    bectl umount "${BE_NAME}" >/dev/null 2>&1 || true
    run bectl destroy "${BE_NAME}"
  elif [ "${REUSE_EXISTING}" = "true" ]; then
    warn "Reusing existing BE '${BE_NAME}' (--reuse)."
  else
    NEW_NAME="${BE_NAME}-$(date +%Y%m%d-%H%M%S)"
    warn "BE '${BE_NAME}' exists. Using '${NEW_NAME}' instead. (Use --reuse / --force-recreate to override.)"
    BE_NAME="${NEW_NAME}"
  fi
fi

printf "== Starting upgrade in BE '%s' mounted at '%s' ==\n" "${BE_NAME}" "${MNT}"

# Ensure umount happens on failure after mount
CLEANUP_DONE="false"
cleanup_mount() {
  if [ "${CLEANUP_DONE}" != "true" ]; then
    bectl umount "${BE_NAME}" >/dev/null 2>&1 || true
    CLEANUP_DONE="true"
  fi
}

# Create BE only when not reusing it
if [ ! "${REUSE_EXISTING}" = "true" ] || ! bectl list -H | awk '{print $1}' | grep -qx "${BE_NAME}"; then
  run bectl create "${BE_NAME}"
  ok "bectl create ${BE_NAME}"
else
  ok "Reusing BE ${BE_NAME} (skipping create)."
fi

run bectl mount "${BE_NAME}" "${MNT}"
trap cleanup_mount EXIT INT TERM
ok "bectl mount ${BE_NAME} ${MNT}"

# Run pkg upgrade inside the BE root
if [ -n "${PKG_YES}" ]; then
  run pkg -r "${MNT}" upgrade ${PKG_YES}
else
  run pkg -r "${MNT}" upgrade
fi
ok "pkg -r ${MNT} upgrade completed"

run bectl umount "${BE_NAME}"
CLEANUP_DONE="true"
trap - EXIT INT TERM
ok "bectl umount ${BE_NAME}"

# Activate according to the chosen mode
if [ "${PERMANENT}" = "true" ]; then
  run bectl activate "${BE_NAME}"
  ok "bectl activate ${BE_NAME} (PERMANENT)"
  info "This BE will be default for all future boots."
else
  run bectl activate -t "${BE_NAME}"
  ok "bectl activate -t ${BE_NAME} (TEMPORARY — next boot only)"
  info "This BE will be used ONLY on the next boot."
  if [ "${PROMOTE_AFTER}" = "true" ]; then
    printf "%s\n" "${C_CYN}Promotion-after-reboot path engaged (-P). Writing marker...${C_RST}"
    marker_write "${BE_NAME}"
    info "After booting into this BE, run:"
    printf "  %s --finalize  # make it PERMANENT (no extra reboot required)\n" "$0"
  fi
fi

printf "\n"
print_guides "${BE_NAME}" "${CURRENT_BE}"
printf "\n"

# Ask to reboot (unless -y)
if [ "${AUTO_REBOOT}" = "true" ]; then
  printf "Rebooting now due to -y...\n"
  run /sbin/reboot
else
  printf "Reboot now? [y/N]: "
  read ans
  case "${ans:-N}" in
    y|Y) printf "Rebooting...\n"; run /sbin/reboot ;;
    *)   printf "Reboot cancelled. You can reboot later with: /sbin/reboot\n" ;;
  esac
fi
# -------------------- End of main flow --------------------