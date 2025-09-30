#!/bin/sh
# be-upgrade.sh — v0.3
#
# Purpose:
#   Create/update a ZFS Boot Environment (BE), run a chrooted pkg upgrade (-r),
#   unmount, and activate the BE (temporary by default).
#
# New in v0.3:
#   - --dry-run       : prints the full plan and commands without changing anything
#   - --pre-flight    : runs validations only (root, tools, mountpoint, BE name, marker path, pool space)
#   - --allow/--deny  : package allowlist/denylist enforced against `pkg -r <MNT> upgrade -n` plan
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
DO_PRE_FLIGHT="false"
DO_DRY_RUN="false"
ALLOW_LIST=""
DENY_LIST=""
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
  printf "  %s --test-marker      # create & read marker only (no BE ops)\n" "$0"
  printf "  %s --pre-flight       # run validations only (no changes)\n" "$0"
  printf "  %s --dry-run          # print the full plan (no changes)\n\n" "$0"
  printf "Options:\n"
  printf "  -b NAME               BE name (default: %s)\n" "${BE_NAME}"
  printf "  -m DIR                mountpoint (default: %s)\n" "${MNT}"
  printf "  -y                    reboot without prompt\n"
  printf "  -p, --permanent       activate BE permanently now\n"
  printf "  -P, --promote-after-reboot\n"
  printf "                        activate temporary now and write marker,\n"
  printf "                        then after you boot into it run: %s --finalize\n" "$0"
  printf "      --marker PATH     override marker path (default: %s)\n" "${PROMOTE_MARKER}"
  printf "      --allow LIST      comma-separated allowlist of packages (enforced vs plan)\n"
  printf "      --deny LIST       comma-separated denylist of packages (enforced vs plan)\n"
  printf "      --finalize        promote current BE to permanent if it matches marker\n"
  printf "      --status          show current BE and marker\n"
  printf "      --test-marker     write+read a dummy marker to test permissions/path\n"
  printf "      --pre-flight      run validations only (no changes)\n"
  printf "      --dry-run         print the full plan (no changes)\n"
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

# Simple zpool free-space hint (non-fatal)
zpool_free_hint() {
  if command -v zpool >/dev/null 2>&1; then
    zpool list -H -o name,free 2>/dev/null | awk '{printf("  pool %-15s free: %s\n", $1, $2)}'
  fi
}

# ------------- Marker helpers -------------
marker_write() {
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

marker_read() { [ -f "${PROMOTE_MARKER}" ] || return 1; head -n1 "${PROMOTE_MARKER}" | tr -d ' \t\r\n'; }
marker_clear(){ rm -f "${PROMOTE_MARKER}" 2>/dev/null || true; }

# ------------- Package plan helpers -------------
parse_pkg_plan() {
  awk '
    /^[[:space:]]+[A-Za-z0-9_.+-]+/ {
      pkg=$1
      sub(/:$/, "", pkg)
      split(pkg, a, /-[0-9]/)
      base=a[1]
      if (base != "") print base
      next
    }
  ' | sort -u
}

enforce_allow_deny() {
  if [ -z "${ALLOW_LIST}" ] && [ -z "${DENY_LIST}" ]; then
    dbg "No allow/deny lists provided; skipping plan enforcement."
    return 0
  fi
  printf "Computing pkg plan (-n) to enforce allow/deny...\n"
  plan_raw="$(pkg -r "${MNT}" upgrade -n 2>/dev/null || true)"
  if [ -z "${plan_raw}" ]; then
    die "Could not obtain pkg plan; cannot enforce allow/deny."
  fi
  plan_pkgs="$(printf "%s\n" "${plan_raw}" | parse_pkg_plan)"
  printf "Planned package set (%s):\n" "$(printf "%s" "${plan_pkgs}" | wc -l | awk '{print $1}')"
  printf "%s\n" "${plan_pkgs}"

  allow_ok="true"; deny_ok="true"
  if [ -n "${ALLOW_LIST}" ]; then
    printf "Allowlist: %s\n" "${ALLOW_LIST}"
    allowed="$(printf "%s" "${ALLOW_LIST}" | tr ',' '\n' | awk 'NF')"
    disallowed="$(comm -23 <(printf "%s\n" "${plan_pkgs}" | sort) <(printf "%s\n" "${allowed}" | sort) 2>/dev/null)"
    if [ -n "${disallowed}" ]; then
      allow_ok="false"
      printf "%s Disallowed (not in allowlist):%s\n" "${C_RED}" "${C_RST}"
      printf "%s\n" "${disallowed}"
    fi
  fi
  if [ -n "${DENY_LIST}" ]; then
    printf "Denylist: %s\n" "${DENY_LIST}"
    denied_set="$(printf "%s" "${DENY_LIST}" | tr ',' '\n' | awk 'NF')"
    denied_hit="$(comm -12 <(printf "%s\n" "${plan_pkgs}" | sort) <(printf "%s\n" "${denied_set}" | sort) 2>/dev/null)"
    if [ -n "${denied_hit}" ]; then
      deny_ok="false"
      printf "%s Blocked by denylist:%s\n" "${C_RED}" "${C_RST}"
      printf "%s\n" "${denied_hit}"
    fi
  fi
  if [ "${allow_ok}" != "true" ] || [ "${deny_ok}" != "true" ]; then
    die "Allow/Deny policy rejected the upgrade plan."
  fi
  ok "Allow/Deny policy passed."
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
    --allow) ALLOW_LIST="${2:-}"; shift 2 ;;
    --deny)  DENY_LIST="${2:-}"; shift 2 ;;
    --reuse) REUSE_EXISTING="true"; shift ;;
    --force-recreate) FORCE_RECREATE="true"; shift ;;
    --no-color) NO_COLOR="true"; shift ;;
    --finalize) DO_FINALIZE="true"; shift ;;
    --status) DO_STATUS="true"; shift ;;
    --test-marker) DO_TEST_MARKER="true"; shift ;;
    --pre-flight) DO_PRE_FLIGHT="true"; shift ;;
    --dry-run) DO_DRY_RUN="true"; shift ;;
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

preflight_checks() {
  printf "Pre-flight checks:\n"
  if [ "$(id -u)" -ne 0 ]; then die "Run as root."; fi
  need_cmd bectl; need_cmd pkg; need_cmd reboot
  ok "Required tools present: bectl, pkg, reboot"
  CUR="$(current_be)"; [ -n "${CUR:-}" ] || CUR="(unknown)"
  printf "Current BE : %s\n" "${CUR}"
  if [ ! -d "${MNT}" ]; then
    printf "Mountpoint : %s (will create)\n" "${MNT}"
  else
    printf "Mountpoint : %s (exists)\n" "${MNT}"
  fi
  if mountpoint_in_use; then
    warn "Mountpoint is currently mounted: ${MNT}"
  else
    ok "Mountpoint is free: ${MNT}"
  fi
  if bectl list -H | awk '{print $1}' | grep -qx "${BE_NAME}"; then
    printf "Target BE  : %s (exists)\n" "${BE_NAME}"
  else
    printf "Target BE  : %s (will be created)\n" "${BE_NAME}"
  fi
  parent="$(dirname "${PROMOTE_MARKER}")"
  if [ -d "${parent}" ] && [ -w "${parent}" ]; then
    ok "Marker dir writable: ${parent}"
  else
    printf "Marker dir : %s (will create)\n" "${parent}"
  fi
  if command -v zpool >/dev/null 2>&1; then
    printf "Zpool free :\n"
    zpool list -H -o name,free 2>/dev/null | awk '{printf("  pool %-15s free: %s\n", $1, $2)}'
  fi
}

if [ "${DO_PRE_FLIGHT}" = "true" ]; then
  preflight_checks
  exit 0
fi

if [ "${DO_STATUS}" = "true" ]; then
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
  exit 0
fi

if [ "${DO_FINALIZE}" = "true" ]; then
  need_cmd bectl
  CUR="$(current_be)"; [ -n "${CUR:-}" ] || die "Could not detect current BE."
  TARGET="$(marker_read || true)"; [ -n "${TARGET:-}" ] || die "No marker (${PROMOTE_MARKER}). Nothing to finalize."
  [ "${CUR}" = "${TARGET}" ] || die "Current BE '${CUR}' != marker '${TARGET}'. Boot into '${TARGET}' then run --finalize."
  run bectl activate "${CUR}"
  ok "Promoted to PERMANENT: ${CUR}"
  marker_clear
  exit 0
fi
# ------------------------------------------------------

# -------------------- Dry-run (no changes) --------------------
if [ "${DO_DRY_RUN}" = "true" ]; then
  printf "=== DRY-RUN: No changes will be made ===\n"
  preflight_checks
  FINAL_BE="${BE_NAME}"
  if bectl list -H | awk '{print $1}' | grep -qx "${FINAL_BE}"; then
    if [ "${FORCE_RECREATE}" = "true" ]; then
      printf "Plan: destroy and recreate BE '%s'\n" "${FINAL_BE}"
    elif [ "${REUSE_EXISTING}" = "true" ]; then
      printf "Plan: reuse existing BE '%s'\n" "${FINAL_BE}"
    else
      NEW_NAME="${FINAL_BE}-$(date +%Y%m%d-%H%M%S)"
      printf "Plan: BE '%s' exists; would use '%s'\n" "${FINAL_BE}" "${NEW_NAME}"
      FINAL_BE="${NEW_NAME}"
    fi
  else
    printf "Plan: create new BE '%s'\n" "${FINAL_BE}"
  fi
  printf "Would run (sequence):\n"
  printf "  bectl create %s   # if not reusing\n" "${FINAL_BE}"
  printf "  bectl mount %s %s\n" "${FINAL_BE}" "${MNT}"
  printf "  pkg -r %s upgrade %s\n" "${MNT}" "${PKG_YES}"
  printf "  bectl umount %s\n" "${FINAL_BE}"
  if [ "${PERMANENT}" = "true" ]; then
    printf "  bectl activate %s  # PERMANENT\n" "${FINAL_BE}"
  else
    printf "  bectl activate -t %s  # TEMPORARY\n" "${FINAL_BE}"
    if [ "${PROMOTE_AFTER}" = "true" ]; then
      printf "  (write marker at %s with '%s')\n" "${PROMOTE_MARKER}" "${FINAL_BE}"
    fi
  fi
  printf "  reboot? (prompt or -y)\n"
  if [ -n "${ALLOW_LIST}" ] || [ -n "${DENY_LIST}" ]; then
    printf "\nPolicy note: allow/deny enforcement requires a real plan from 'pkg -r %s upgrade -n' which\n" "${MNT}"
    printf "needs the BE mounted. In DRY-RUN we do not mount. Run without --dry-run to enforce policy safely.\n"
  fi
  exit 0
fi
# --------------------------------------------------------------

# -------------------- Main flow (changes happen) --------------------
if [ "${PERMANENT}" = "true" ] && [ "${PROMOTE_AFTER}" = "true" ]; then
  warn "You passed -p and -P together. Proceeding with PERMANENT activation (-p) and ignoring -P."
  PROMOTE_AFTER="false"
fi

printf "Mode: permanent=%s, promote-after=%s, reuse=%s, force-recreate=%s\n" \
  "${PERMANENT}" "${PROMOTE_AFTER}" "${REUSE_EXISTING}" "${FORCE_RECREATE}"

[ "$(id -u)" -eq 0 ] || die "Run as root."
need_cmd bectl; need_cmd pkg; need_cmd reboot

CURRENT_BE="$(current_be)"; [ -n "${CURRENT_BE:-}" ] || CURRENT_BE="(unknown)"
printf "Current BE: %s\n" "${CURRENT_BE}"

if [ ! -d "${MNT}" ]; then run mkdir -p "${MNT}"; fi
if mountpoint_in_use; then
  die "Mountpoint '${MNT}' is already mounted. Unmount it (umount '${MNT}') or choose another with -m."
fi

FINAL_BE="${BE_NAME}"
if bectl list -H | awk '{print $1}' | grep -qx "${FINAL_BE}"; then
  if [ "${FORCE_RECREATE}" = "true" ]; then
    warn "Destroying existing BE '${FINAL_BE}' (--force-recreate)."
    bectl umount "${FINAL_BE}" >/dev/null 2>&1 || true
    run bectl destroy "${FINAL_BE}"
  elif [ "${REUSE_EXISTING}" = "true" ]; then
    warn "Reusing existing BE '${FINAL_BE}' (--reuse)."
  else
    NEW_NAME="${FINAL_BE}-$(date +%Y%m%d-%H%M%S)"
    warn "BE '${FINAL_BE}' exists. Using '${NEW_NAME}' instead. (Use --reuse / --force-recreate to override.)"
    FINAL_BE="${NEW_NAME}"
  fi
fi

printf "== Starting upgrade in BE '%s' mounted at '%s' ==\n" "${FINAL_BE}" "${MNT}"

CLEANUP_DONE="false"
cleanup_mount() {
  if [ "${CLEANUP_DONE}" != "true" ]; then
    bectl umount "${FINAL_BE}" >/dev/null 2>&1 || true
    CLEANUP_DONE="true"
  fi
}

if [ ! "${REUSE_EXISTING}" = "true" ] || ! bectl list -H | awk '{print $1}' | grep -qx "${FINAL_BE}"; then
  run bectl create "${FINAL_BE}"
  ok "bectl create ${FINAL_BE}"
else
  ok "Reusing BE ${FINAL_BE} (skipping create)."
fi

run bectl mount "${FINAL_BE}" "${MNT}"
trap cleanup_mount EXIT INT TERM
ok "bectl mount ${FINAL_BE} ${MNT}"

enforce_allow_deny()

if [ -n "${PKG_YES}" ]; then
  run pkg -r "${MNT}" upgrade ${PKG_YES}
else
  run pkg -r "${MNT}" upgrade
fi
ok "pkg -r ${MNT} upgrade completed"

run bectl umount "${FINAL_BE}"
CLEANUP_DONE="true"
trap - EXIT INT TERM
ok "bectl umount ${FINAL_BE}"

if [ "${PERMANENT}" = "true" ]; then
  run bectl activate "${FINAL_BE}"
  ok "bectl activate ${FINAL_BE} (PERMANENT)"
  info "This BE will be default for all future boots."
else
  run bectl activate -t "${FINAL_BE}"
  ok "bectl activate -t ${FINAL_BE} (TEMPORARY — next boot only)"
  info "This BE will be used ONLY on the next boot."
  if [ "${PROMOTE_AFTER}" = "true" ]; then
    printf "%s\n" "${C_CYN}Promotion-after-reboot path engaged (-P). Writing marker...${C_RST}"
    marker_write "${FINAL_BE}"
    info "After booting into this BE, run:"
    printf "  %s --finalize  # make it PERMANENT (no extra reboot required)\n" "$0"
  fi
fi

printf "\n"
print_guides "${FINAL_BE}" "${CURRENT_BE}"
printf "\n"

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
