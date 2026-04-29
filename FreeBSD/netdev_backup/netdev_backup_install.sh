#!/bin/sh
#
# netdev_backup_install.sh
#
# Standalone installer/updater for netdev_backup.py on FreeBSD.
# It fetches the current files from GitHub, installs missing files, updates
# managed files only after confirmation, creates local snapshots before any
# overwrite, and can roll back from those snapshots.

set -u

REPO_URL="${REPO_URL:-https://github.com/kmansur/Scripts.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_SUBDIR="${REPO_SUBDIR:-FreeBSD/netdev_backup}"

SCRIPT_DIR="${SCRIPT_DIR:-/usr/local/scripts}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/netdev_backup}"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-${CONFIG_DIR}/backups}"

SCRIPT_NAME="netdev_backup.py"
INSTALLER_NAME="netdev_backup_install.sh"
ENV_EXAMPLE_NAME="netdev_backup.env.example"
DEVICES_EXAMPLE_NAME="devices.json.example"
README_NAME="README.md"

SCRIPT_TARGET="${SCRIPT_DIR}/${SCRIPT_NAME}"
INSTALLER_TARGET="${SCRIPT_DIR}/${INSTALLER_NAME}"
ENV_TARGET="${CONFIG_DIR}/netdev_backup.env"
DEVICES_TARGET="${CONFIG_DIR}/devices.json"
ENV_EXAMPLE_TARGET="${CONFIG_DIR}/${ENV_EXAMPLE_NAME}"
DEVICES_EXAMPLE_TARGET="${CONFIG_DIR}/${DEVICES_EXAMPLE_NAME}"
README_TARGET="${CONFIG_DIR}/${README_NAME}"

DEFAULT_BACKUP_DIR="/var/backups/netdev"
DEFAULT_GIT_REPO_DIR="/var/git/netdev_backups"
DEFAULT_LOG_FILE="/var/log/netdev_backup.log"

SNAPSHOT_DIR=""

say() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  install     Install or update netdev_backup files (default)
  update      Same as install
  rollback    Restore files from a previous local snapshot
  status      Show installed files and available snapshots
  help        Show this help

Environment overrides:
  REPO_URL       Git repository URL (default: ${REPO_URL})
  REPO_BRANCH    Git branch to fetch (default: ${REPO_BRANCH})
  SCRIPT_DIR     Install directory for executables (default: ${SCRIPT_DIR})
  CONFIG_DIR     Configuration directory (default: ${CONFIG_DIR})
  SNAPSHOT_ROOT  Snapshot directory (default: ${SNAPSHOT_ROOT})
EOF
}

ask_yes_no() {
    question="$1"
    default="${2:-no}"

    while :; do
        if [ "$default" = "yes" ]; then
            printf '%s [Y/n] ' "$question"
        else
            printf '%s [y/N] ' "$question"
        fi

        IFS= read -r answer || return 1
        answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')

        case "$answer" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            "")
                [ "$default" = "yes" ] && return 0
                return 1
                ;;
            *)
                say "Please answer yes or no."
                ;;
        esac
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_runtime_user() {
    user_id=$(id -u 2>/dev/null || echo "")
    if [ "$user_id" != "0" ]; then
        warn "You are not running as root. Creating files under /usr/local or /var may fail."
    fi
}

get_env_value() {
    file="$1"
    key="$2"

    [ -f "$file" ] || return 1

    value=$(awk -F= -v key="$key" '
        $0 !~ /^[[:space:]]*#/ && $1 == key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$file")

    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

current_backup_dir() {
    get_env_value "$ENV_TARGET" "BACKUP_DIR" 2>/dev/null || printf '%s\n' "$DEFAULT_BACKUP_DIR"
}

current_git_repo_dir() {
    get_env_value "$ENV_TARGET" "GIT_REPO_DIR" 2>/dev/null || printf '%s\n' "$DEFAULT_GIT_REPO_DIR"
}

current_log_file() {
    get_env_value "$ENV_TARGET" "LOG_FILE" 2>/dev/null || printf '%s\n' "$DEFAULT_LOG_FILE"
}

ensure_dir() {
    dir="$1"
    label="$2"

    [ -d "$dir" ] && return 0

    if ask_yes_no "Create ${label} directory ${dir}?" "yes"; then
        mkdir -p "$dir" || die "Could not create directory: $dir"
    else
        die "Required directory missing: $dir"
    fi
}

ensure_log_file() {
    log_file="$1"
    log_dir=$(dirname "$log_file")

    ensure_dir "$log_dir" "log"

    if [ ! -e "$log_file" ]; then
        if ask_yes_no "Create log file ${log_file}?" "yes"; then
            : > "$log_file" || die "Could not create log file: $log_file"
            chmod 0644 "$log_file" 2>/dev/null || true
        else
            warn "Log file was not created. The Python script may log only to stdout if it cannot open it."
        fi
    fi
}

ensure_directories() {
    ensure_dir "$SCRIPT_DIR" "script"
    ensure_dir "$CONFIG_DIR" "configuration"
    ensure_dir "$SNAPSHOT_ROOT" "snapshot"
    ensure_dir "$(current_backup_dir)" "backup output"
    ensure_dir "$(current_git_repo_dir)" "backup Git repository"
    ensure_log_file "$(current_log_file)"

    git_repo_dir=$(current_git_repo_dir)
    if [ -d "$git_repo_dir" ] && [ ! -d "${git_repo_dir}/.git" ]; then
        warn "${git_repo_dir} exists but is not a Git repository."
        warn "Configure it with git init and an origin remote before production runs."
    fi
}

make_temp_dir() {
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/netdev_backup_install.XXXXXX") || die "Could not create temporary directory"
    printf '%s\n' "$tmp"
}

fetch_repo() {
    tmp="$1"
    target="${tmp}/repo"

    say "Fetching ${REPO_URL} (${REPO_BRANCH})..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$target" >/dev/null 2>&1 \
        || die "Could not clone repository: ${REPO_URL}"

    [ -d "${target}/${REPO_SUBDIR}" ] || die "Repository path not found: ${REPO_SUBDIR}"
    printf '%s\n' "${target}/${REPO_SUBDIR}"
}

hash_file() {
    file="$1"

    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$file"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        cksum "$file" | awk '{print $1 ":" $2}'
    fi
}

files_differ() {
    src="$1"
    dst="$2"

    [ -f "$dst" ] || return 0
    [ "$(hash_file "$src")" = "$(hash_file "$dst")" ] && return 1
    return 0
}

ensure_snapshot() {
    [ -n "$SNAPSHOT_DIR" ] && return 0

    stamp=$(date '+%Y%m%d-%H%M%S')
    SNAPSHOT_DIR="${SNAPSHOT_ROOT}/${stamp}"
    mkdir -p "$SNAPSHOT_DIR" || die "Could not create snapshot directory: $SNAPSHOT_DIR"

    {
        echo "created_at=${stamp}"
        echo "repo_url=${REPO_URL}"
        echo "repo_branch=${REPO_BRANCH}"
    } > "${SNAPSHOT_DIR}/manifest.txt"

    say "Created local snapshot: ${SNAPSHOT_DIR}"
}

snapshot_file() {
    target="$1"
    label="$2"

    [ -e "$target" ] || return 0

    ensure_snapshot
    base=$(basename "$target")
    cp -p "$target" "${SNAPSHOT_DIR}/${base}" || die "Could not snapshot ${target}"
    printf '%s|%s\n' "$base" "$target" >> "${SNAPSHOT_DIR}/manifest.txt"
    say "Backed up ${label}: ${target}"
}

snapshot_runtime_state() {
    snapshot_file "$SCRIPT_TARGET" "current Python script"
    snapshot_file "$INSTALLER_TARGET" "current installer"
    snapshot_file "$ENV_TARGET" "current environment configuration"
    snapshot_file "$DEVICES_TARGET" "current devices inventory"
}

copy_file() {
    src="$1"
    dst="$2"
    mode="$3"

    cp "$src" "$dst" || die "Could not copy ${src} to ${dst}"
    chmod "$mode" "$dst" 2>/dev/null || true
}

install_or_update_managed_file() {
    src="$1"
    dst="$2"
    mode="$3"
    label="$4"

    [ -f "$src" ] || die "Source file missing: $src"

    if [ ! -e "$dst" ]; then
        if ask_yes_no "Install ${label} to ${dst}?" "yes"; then
            copy_file "$src" "$dst" "$mode"
            say "Installed ${label}: ${dst}"
        else
            warn "Skipped missing ${label}: ${dst}"
        fi
        return 0
    fi

    if ! files_differ "$src" "$dst"; then
        say "${label} is already current: ${dst}"
        return 0
    fi

    say "A newer/different ${label} is available for ${dst}."
    if ask_yes_no "Back up and update ${label}?" "no"; then
        snapshot_runtime_state
        snapshot_file "$dst" "$label"
        copy_file "$src" "$dst" "$mode"
        say "Updated ${label}: ${dst}"
    else
        say "Kept existing ${label}: ${dst}"
    fi
}

create_initial_config_file() {
    src="$1"
    dst="$2"
    label="$3"

    if [ -e "$dst" ]; then
        say "Existing ${label} preserved: ${dst}"
        return 0
    fi

    if [ ! -f "$src" ]; then
        warn "Cannot create ${label}; example file is missing: ${src}"
        return 0
    fi

    if ask_yes_no "Create initial ${label} from example at ${dst}?" "yes"; then
        copy_file "$src" "$dst" "0600"
        say "Created ${label}: ${dst}"
        say "Edit this file before production use."
    else
        warn "Skipped initial ${label}: ${dst}"
    fi
}

install_from_source() {
    source_dir="$1"

    install_or_update_managed_file "${source_dir}/${SCRIPT_NAME}" "$SCRIPT_TARGET" "0755" "Python script"
    install_or_update_managed_file "${source_dir}/${INSTALLER_NAME}" "$INSTALLER_TARGET" "0755" "installer"
    install_or_update_managed_file "${source_dir}/${ENV_EXAMPLE_NAME}" "$ENV_EXAMPLE_TARGET" "0644" "environment example"
    install_or_update_managed_file "${source_dir}/${DEVICES_EXAMPLE_NAME}" "$DEVICES_EXAMPLE_TARGET" "0644" "devices example"
    install_or_update_managed_file "${source_dir}/${README_NAME}" "$README_TARGET" "0644" "README"

    create_initial_config_file "$ENV_EXAMPLE_TARGET" "$ENV_TARGET" "environment configuration"
    create_initial_config_file "$DEVICES_EXAMPLE_TARGET" "$DEVICES_TARGET" "devices inventory"
}

check_python_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 was not found. Install Python before running netdev_backup.py."
        return 0
    fi

    python3 - <<'PY' >/dev/null 2>&1
import importlib
for module in ("paramiko", "dotenv", "git", "mysql.connector"):
    importlib.import_module(module)
PY
    if [ $? -ne 0 ]; then
        warn "Some Python dependencies appear to be missing."
        warn "Install them with: python3 -m pip install paramiko python-dotenv GitPython mysql-connector-python"
    fi
}

show_status() {
    say "Install paths:"
    for file in \
        "$SCRIPT_TARGET" \
        "$INSTALLER_TARGET" \
        "$ENV_TARGET" \
        "$DEVICES_TARGET" \
        "$ENV_EXAMPLE_TARGET" \
        "$DEVICES_EXAMPLE_TARGET" \
        "$README_TARGET"
    do
        if [ -e "$file" ]; then
            say "  OK      $file"
        else
            say "  MISSING $file"
        fi
    done

    say ""
    say "Directories:"
    for dir in \
        "$SCRIPT_DIR" \
        "$CONFIG_DIR" \
        "$SNAPSHOT_ROOT" \
        "$(current_backup_dir)" \
        "$(current_git_repo_dir)" \
        "$(dirname "$(current_log_file)")"
    do
        if [ -d "$dir" ]; then
            say "  OK      $dir"
        else
            say "  MISSING $dir"
        fi
    done

    say ""
    say "Available snapshots:"
    if [ -d "$SNAPSHOT_ROOT" ]; then
        snapshots=$(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if [ -n "$snapshots" ]; then
            printf '%s\n' "$snapshots" | sed 's/^/  /'
        else
            say "  none"
        fi
    else
        say "  none"
    fi
}

select_snapshot() {
    [ -d "$SNAPSHOT_ROOT" ] || die "Snapshot directory not found: $SNAPSHOT_ROOT"

    list_file=$(mktemp "${TMPDIR:-/tmp}/netdev_backup_snapshots.XXXXXX") || die "Could not create temporary file"
    find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort > "$list_file"

    if [ ! -s "$list_file" ]; then
        rm -f "$list_file"
        die "No snapshots available under $SNAPSHOT_ROOT"
    fi

    say "Available snapshots:"
    awk '{ printf "  %d) %s\n", NR, $0 }' "$list_file"
    printf 'Select snapshot number to restore: '
    IFS= read -r choice || {
        rm -f "$list_file"
        die "No snapshot selected"
    }

    case "$choice" in
        ''|*[!0-9]*)
            rm -f "$list_file"
            die "Invalid snapshot selection"
            ;;
    esac

    selected=$(sed -n "${choice}p" "$list_file" 2>/dev/null)
    rm -f "$list_file"

    [ -n "$selected" ] || die "Invalid snapshot selection"
    printf '%s\n' "$selected"
}

restore_file() {
    snapshot="$1"
    name="$2"
    target="$3"
    mode="$4"

    src="${snapshot}/${name}"
    [ -e "$src" ] || return 0

    snapshot_file "$target" "current $(basename "$target") before rollback"
    copy_file "$src" "$target" "$mode"
    say "Restored ${target}"
}

rollback() {
    check_runtime_user
    ensure_dir "$SCRIPT_DIR" "script"
    ensure_dir "$CONFIG_DIR" "configuration"
    ensure_dir "$SNAPSHOT_ROOT" "snapshot"

    snapshot=$(select_snapshot)
    say "Selected snapshot: $snapshot"

    if ! ask_yes_no "Restore files from this snapshot? Current files will be backed up first." "no"; then
        say "Rollback cancelled."
        return 0
    fi

    SNAPSHOT_DIR=""
    restore_file "$snapshot" "$SCRIPT_NAME" "$SCRIPT_TARGET" "0755"
    restore_file "$snapshot" "$INSTALLER_NAME" "$INSTALLER_TARGET" "0755"
    restore_file "$snapshot" "netdev_backup.env" "$ENV_TARGET" "0600"
    restore_file "$snapshot" "devices.json" "$DEVICES_TARGET" "0600"
    restore_file "$snapshot" "$ENV_EXAMPLE_NAME" "$ENV_EXAMPLE_TARGET" "0644"
    restore_file "$snapshot" "$DEVICES_EXAMPLE_NAME" "$DEVICES_EXAMPLE_TARGET" "0644"
    restore_file "$snapshot" "$README_NAME" "$README_TARGET" "0644"

    say "Rollback completed."
}

install_or_update() {
    check_runtime_user
    require_command git
    require_command awk
    require_command sed
    require_command find

    ensure_directories

    tmp=$(make_temp_dir)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    source_dir=$(fetch_repo "$tmp")
    install_from_source "$source_dir"
    check_python_dependencies

    say "Done."
}

case "${1:-install}" in
    install|update)
        install_or_update
        ;;
    rollback|--rollback)
        rollback
        ;;
    status|--status)
        show_status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac
