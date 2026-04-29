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
  configure   Run the production environment configuration wizard
  wizard      Same as configure
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
            printf '%s [Y/n] ' "$question" >&2
        else
            printf '%s [y/N] ' "$question" >&2
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
                printf '%s\n' "Please answer yes or no." >&2
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

    case "$value" in
        \"*\")
            value=${value#\"}
            value=${value%\"}
            ;;
        \'*\')
            value=${value#\'}
            value=${value%\'}
            ;;
    esac

    value=$(printf '%s' "$value" | sed \
        -e 's/\\"/"/g' \
        -e 's/\\\\/\\/g' \
        -e 's/\\\$/$/g' \
        -e 's/\\`/`/g')

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

prompt_value() {
    label="$1"
    default="$2"
    required="$3"

    while :; do
        if [ -n "$default" ]; then
            if [ "$required" = "yes" ]; then
                printf '%s [%s]: ' "$label" "$default" >&2
            else
                printf '%s [%s, type - to clear]: ' "$label" "$default" >&2
            fi
        else
            printf '%s: ' "$label" >&2
        fi

        IFS= read -r value || return 1
        clear_value="no"
        if [ "$required" = "no" ] && [ "$value" = "-" ]; then
            value=""
            clear_value="yes"
        fi
        [ "$clear_value" = "no" ] && [ -z "$value" ] && value="$default"

        if [ "$required" = "yes" ] && [ -z "$value" ]; then
            warn "A value is required."
            continue
        fi

        printf '%s\n' "$value"
        return 0
    done
}

prompt_secret() {
    label="$1"
    default="$2"
    required="$3"

    while :; do
        if [ -n "$default" ]; then
            printf '%s [press Enter to keep existing value]: ' "$label" >&2
        else
            printf '%s: ' "$label" >&2
        fi

        if [ -t 0 ]; then
            stty -echo 2>/dev/null || true
            IFS= read -r value
            status=$?
            stty echo 2>/dev/null || true
            printf '\n' >&2
            [ "$status" -ne 0 ] && return 1
        else
            IFS= read -r value || return 1
        fi

        [ -z "$value" ] && value="$default"

        if [ "$required" = "yes" ] && [ -z "$value" ]; then
            warn "A value is required."
            continue
        fi

        printf '%s\n' "$value"
        return 0
    done
}

prompt_number() {
    label="$1"
    default="$2"
    required="$3"

    while :; do
        value=$(prompt_value "$label" "$default" "$required") || return 1
        case "$value" in
            ''|*[!0-9]*)
                warn "Use digits only."
                ;;
            *)
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done
}

prompt_absolute_path() {
    label="$1"
    default="$2"
    required="$3"

    while :; do
        value=$(prompt_value "$label" "$default" "$required") || return 1
        case "$value" in
            /*)
                printf '%s\n' "$value"
                return 0
                ;;
            *)
                warn "Use an absolute path beginning with /."
                ;;
        esac
    done
}

bool_default() {
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|true|yes|on)
            printf '%s\n' "yes"
            ;;
        *)
            printf '%s\n' "no"
            ;;
    esac
}

production_default() {
    value="$1"

    case "$value" in
        db.yourdomain.com|network_inventory|change_this_password|smtp.example.com|user@example.com|password|backup@example.com|admin@example.com,support@example.com)
            printf '%s\n' ""
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

prompt_bool_value() {
    label="$1"
    default_value="$2"

    if ask_yes_no "$label" "$(bool_default "$default_value")"; then
        printf '%s\n' "true"
    else
        printf '%s\n' "false"
    fi
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

escape_env_value() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\$/\\$/g' \
        -e 's/`/\\`/g'
}

write_env_var() {
    key="$1"
    value="$2"
    printf '%s="%s"\n' "$key" "$(escape_env_value "$value")"
}

write_env_file() {
    target="$1"

    {
        echo "# ====================================================================="
        echo "# NETDEV BACKUP CONFIGURATION"
        echo "# Generated by netdev_backup_install.sh on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ====================================================================="
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 1: DATABASE CONFIGURATION"
        echo "# ====================================================================="
        echo "# Used to load MikroTik devices from MySQL."
        write_env_var "DB_HOST" "$CFG_DB_HOST"
        write_env_var "DB_PORT" "$CFG_DB_PORT"
        write_env_var "DB_NAME" "$CFG_DB_NAME"
        write_env_var "DB_USER" "$CFG_DB_USER"
        write_env_var "DB_PASS" "$CFG_DB_PASS"
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 2: DEVICE INVENTORY CONFIGURATION"
        echo "# ====================================================================="
        echo "# JSON file containing non-MikroTik devices."
        write_env_var "DEVICES_FILE" "$CFG_DEVICES_FILE"
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 3: DIRECTORIES, LOGGING, AND GIT REPOSITORY"
        echo "# ====================================================================="
        write_env_var "BACKUP_DIR" "$CFG_BACKUP_DIR"
        write_env_var "GIT_REPO_DIR" "$CFG_GIT_REPO_DIR"
        write_env_var "LOG_FILE" "$CFG_LOG_FILE"
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 4: SSH CONNECTIVITY AND SECURITY"
        echo "# ====================================================================="
        write_env_var "SSH_TIMEOUT" "$CFG_SSH_TIMEOUT"
        write_env_var "STRICT_HOST_KEY_CHECKING" "$CFG_STRICT_HOST_KEY_CHECKING"
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 5: PERFORMANCE AND RETRIES"
        echo "# ====================================================================="
        write_env_var "MAX_WORKERS" "$CFG_MAX_WORKERS"
        write_env_var "RETRY_COUNT" "$CFG_RETRY_COUNT"
        echo ""
        echo "# ====================================================================="
        echo "# SECTION 6: EMAIL NOTIFICATION CONFIGURATION"
        echo "# ====================================================================="
        write_env_var "SMTP_HOST" "$CFG_SMTP_HOST"
        write_env_var "SMTP_PORT" "$CFG_SMTP_PORT"
        write_env_var "SMTP_STARTTLS" "$CFG_SMTP_STARTTLS"
        write_env_var "SMTP_USER" "$CFG_SMTP_USER"
        write_env_var "SMTP_PASS" "$CFG_SMTP_PASS"
        write_env_var "EMAIL_FROM" "$CFG_EMAIL_FROM"
        write_env_var "EMAIL_TO" "$CFG_EMAIL_TO"
    } > "$target" || die "Could not write generated environment file: $target"
}

maybe_create_devices_file() {
    devices_file="$1"
    devices_dir=$(dirname "$devices_file")

    ensure_dir "$devices_dir" "devices inventory"

    if [ -e "$devices_file" ]; then
        say "Existing devices inventory preserved: $devices_file"
        return 0
    fi

    if [ -f "$DEVICES_EXAMPLE_TARGET" ]; then
        if ask_yes_no "Create initial devices inventory from example at ${devices_file}?" "yes"; then
            copy_file "$DEVICES_EXAMPLE_TARGET" "$devices_file" "0600"
            say "Created devices inventory: $devices_file"
            say "Edit this file with Juniper, Extreme, HP/3Com, and Ubiquiti devices before production use."
        else
            warn "Devices inventory was not created: $devices_file"
        fi
    else
        warn "Devices example not found: $DEVICES_EXAMPLE_TARGET"
        warn "Create ${devices_file} manually before production use."
    fi
}

configure_environment() {
    check_runtime_user
    require_command awk
    require_command mktemp
    require_command sed
    ensure_dir "$CONFIG_DIR" "configuration"
    ensure_dir "$SNAPSHOT_ROOT" "snapshot"

    say "This wizard will generate a production-ready netdev_backup.env."
    say "Existing values are shown as defaults when available."
    say ""

    db_host_default=$(get_env_value "$ENV_TARGET" "DB_HOST" 2>/dev/null || printf '%s' "")
    db_port_default=$(get_env_value "$ENV_TARGET" "DB_PORT" 2>/dev/null || printf '%s' "3306")
    db_name_default=$(get_env_value "$ENV_TARGET" "DB_NAME" 2>/dev/null || printf '%s' "")
    db_user_default=$(get_env_value "$ENV_TARGET" "DB_USER" 2>/dev/null || printf '%s' "")
    db_pass_default=$(get_env_value "$ENV_TARGET" "DB_PASS" 2>/dev/null || printf '%s' "")
    db_host_default=$(production_default "$db_host_default")
    db_name_default=$(production_default "$db_name_default")
    db_pass_default=$(production_default "$db_pass_default")

    devices_file_default=$(get_env_value "$ENV_TARGET" "DEVICES_FILE" 2>/dev/null || printf '%s' "$DEVICES_TARGET")
    backup_dir_default=$(get_env_value "$ENV_TARGET" "BACKUP_DIR" 2>/dev/null || printf '%s' "$DEFAULT_BACKUP_DIR")
    git_repo_dir_default=$(get_env_value "$ENV_TARGET" "GIT_REPO_DIR" 2>/dev/null || printf '%s' "$DEFAULT_GIT_REPO_DIR")
    log_file_default=$(get_env_value "$ENV_TARGET" "LOG_FILE" 2>/dev/null || printf '%s' "$DEFAULT_LOG_FILE")

    ssh_timeout_default=$(get_env_value "$ENV_TARGET" "SSH_TIMEOUT" 2>/dev/null || printf '%s' "15")
    strict_host_key_default=$(get_env_value "$ENV_TARGET" "STRICT_HOST_KEY_CHECKING" 2>/dev/null || printf '%s' "false")
    max_workers_default=$(get_env_value "$ENV_TARGET" "MAX_WORKERS" 2>/dev/null || printf '%s' "4")
    retry_count_default=$(get_env_value "$ENV_TARGET" "RETRY_COUNT" 2>/dev/null || printf '%s' "2")

    smtp_host_default=$(get_env_value "$ENV_TARGET" "SMTP_HOST" 2>/dev/null || printf '%s' "")
    smtp_port_default=$(get_env_value "$ENV_TARGET" "SMTP_PORT" 2>/dev/null || printf '%s' "587")
    smtp_starttls_default=$(get_env_value "$ENV_TARGET" "SMTP_STARTTLS" 2>/dev/null || printf '%s' "true")
    smtp_user_default=$(get_env_value "$ENV_TARGET" "SMTP_USER" 2>/dev/null || printf '%s' "")
    smtp_pass_default=$(get_env_value "$ENV_TARGET" "SMTP_PASS" 2>/dev/null || printf '%s' "")
    email_from_default=$(get_env_value "$ENV_TARGET" "EMAIL_FROM" 2>/dev/null || printf '%s' "")
    email_to_default=$(get_env_value "$ENV_TARGET" "EMAIL_TO" 2>/dev/null || printf '%s' "")
    smtp_host_default=$(production_default "$smtp_host_default")
    smtp_user_default=$(production_default "$smtp_user_default")
    smtp_pass_default=$(production_default "$smtp_pass_default")
    email_from_default=$(production_default "$email_from_default")
    email_to_default=$(production_default "$email_to_default")

    say "Database settings for MikroTik inventory"
    CFG_DB_HOST=$(prompt_value "DB host" "$db_host_default" "yes") || return 1
    CFG_DB_PORT=$(prompt_number "DB port" "$db_port_default" "yes") || return 1
    CFG_DB_NAME=$(prompt_value "DB name" "$db_name_default" "yes") || return 1
    CFG_DB_USER=$(prompt_value "DB user" "$db_user_default" "yes") || return 1
    CFG_DB_PASS=$(prompt_secret "DB password" "$db_pass_default" "yes") || return 1

    say ""
    say "Inventory and storage paths"
    CFG_DEVICES_FILE=$(prompt_absolute_path "Devices JSON file" "$devices_file_default" "yes") || return 1
    CFG_BACKUP_DIR=$(prompt_absolute_path "Backup output directory" "$backup_dir_default" "yes") || return 1
    CFG_GIT_REPO_DIR=$(prompt_absolute_path "Backup Git repository directory" "$git_repo_dir_default" "yes") || return 1
    CFG_LOG_FILE=$(prompt_absolute_path "Log file" "$log_file_default" "yes") || return 1

    say ""
    say "SSH, host key, performance, and retry settings"
    CFG_SSH_TIMEOUT=$(prompt_number "SSH/Telnet timeout in seconds" "$ssh_timeout_default" "yes") || return 1
    CFG_STRICT_HOST_KEY_CHECKING=$(prompt_bool_value "Require pre-populated SSH known_hosts?" "$strict_host_key_default") || return 1
    CFG_MAX_WORKERS=$(prompt_number "Maximum parallel workers" "$max_workers_default" "yes") || return 1
    CFG_RETRY_COUNT=$(prompt_number "Retry attempts after the first try" "$retry_count_default" "yes") || return 1

    say ""
    if [ -n "$smtp_host_default" ]; then
        email_default="yes"
    else
        email_default="no"
    fi

    if ask_yes_no "Configure email notifications for failures?" "$email_default"; then
        CFG_SMTP_HOST=$(prompt_value "SMTP host" "$smtp_host_default" "yes") || return 1
        CFG_SMTP_PORT=$(prompt_number "SMTP port" "$smtp_port_default" "yes") || return 1
        CFG_SMTP_STARTTLS=$(prompt_bool_value "Use STARTTLS?" "$smtp_starttls_default") || return 1
        CFG_SMTP_USER=$(prompt_value "SMTP user (leave blank if not required)" "$smtp_user_default" "no") || return 1
        if [ -n "$CFG_SMTP_USER" ]; then
            CFG_SMTP_PASS=$(prompt_secret "SMTP password" "$smtp_pass_default" "yes") || return 1
        else
            CFG_SMTP_PASS=""
        fi
        CFG_EMAIL_FROM=$(prompt_value "Email From address" "$email_from_default" "yes") || return 1
        CFG_EMAIL_TO=$(prompt_value "Email recipients, comma-separated" "$email_to_default" "yes") || return 1
    else
        CFG_SMTP_HOST=""
        CFG_SMTP_PORT="$smtp_port_default"
        CFG_SMTP_STARTTLS="$smtp_starttls_default"
        CFG_SMTP_USER=""
        CFG_SMTP_PASS=""
        CFG_EMAIL_FROM=""
        CFG_EMAIL_TO=""
    fi

    say ""
    say "Directory checks based on wizard answers"
    ensure_dir "$CFG_BACKUP_DIR" "backup output"
    ensure_dir "$CFG_GIT_REPO_DIR" "backup Git repository"
    ensure_log_file "$CFG_LOG_FILE"
    maybe_create_devices_file "$CFG_DEVICES_FILE"

    if [ -d "$CFG_GIT_REPO_DIR" ] && [ ! -d "${CFG_GIT_REPO_DIR}/.git" ]; then
        warn "${CFG_GIT_REPO_DIR} exists but is not a Git repository."
        warn "Initialize it and configure an origin remote before production runs."
    fi

    tmp_env=$(mktemp "${TMPDIR:-/tmp}/netdev_backup.env.XXXXXX") || die "Could not create temporary env file"
    write_env_file "$tmp_env"
    chmod 0600 "$tmp_env" 2>/dev/null || true

    say ""
    say "Generated environment file preview:"
    sed 's/^\(DB_PASS=\).*/\1"********"/; s/^\(SMTP_PASS=\).*/\1"********"/' "$tmp_env"
    say ""

    if [ -e "$ENV_TARGET" ]; then
        if ask_yes_no "Write this configuration to ${ENV_TARGET}? Existing file will be backed up first." "yes"; then
            snapshot_file "$ENV_TARGET" "current environment configuration"
            copy_file "$tmp_env" "$ENV_TARGET" "0600"
            say "Environment configuration updated: $ENV_TARGET"
        else
            generated="${CONFIG_DIR}/netdev_backup.env.generated.$(date '+%Y%m%d-%H%M%S')"
            if ask_yes_no "Save generated configuration separately at ${generated}?" "yes"; then
                copy_file "$tmp_env" "$generated" "0600"
                say "Generated configuration saved: $generated"
            else
                say "Configuration was not written."
            fi
        fi
    else
        if ask_yes_no "Create ${ENV_TARGET} with this configuration?" "yes"; then
            copy_file "$tmp_env" "$ENV_TARGET" "0600"
            say "Environment configuration created: $ENV_TARGET"
        else
            say "Configuration was not written."
        fi
    fi

    rm -f "$tmp_env"
    say "Wizard completed."
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

    had_env_before="no"
    [ -e "$ENV_TARGET" ] && had_env_before="yes"

    ensure_directories

    tmp=$(make_temp_dir)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    source_dir=$(fetch_repo "$tmp")
    install_from_source "$source_dir"
    check_python_dependencies

    if [ "$had_env_before" = "yes" ]; then
        wizard_default="no"
    else
        wizard_default="yes"
    fi

    if ask_yes_no "Run the production environment wizard now?" "$wizard_default"; then
        configure_environment || die "Environment wizard failed."
    else
        say "You can run the wizard later with: $0 configure"
    fi

    say "Done."
}

case "${1:-install}" in
    install|update)
        install_or_update
        ;;
    configure|wizard|--configure|--wizard)
        configure_environment
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
