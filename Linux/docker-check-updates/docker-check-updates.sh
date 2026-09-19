#!/usr/bin/env bash
#
# docker-check-updates.sh
#
# Docker image update checker with optional Docker Compose updates,
# backups, rollback support and special handling for NetBox Docker.
#
# Version: 2.3.0
# Date:    2026-09-18
# License: MIT
#
# This project is under development. Use at your own risk.
# Always keep a tested backup of application data before updating containers.
#

set -u

SCRIPT_NAME="docker-check-updates.sh"
SCRIPT_VERSION="2.3.0"
SCRIPT_DATE="2026-09-18"

ALL_CONTAINERS=0
UPDATE_MODE=0
AUTO_YES=0
BACKUP_ONLY=0
BACKUP_VOLUMES=0
NO_BACKUP=0
ROLLBACK_DIR=""
BACKUP_ROOT="/var/backups/docker-check-updates"
RUN_BACKUP_DIR=""

# Optional Portainer remote-agent integration.
PORTAINER_ENABLED=1
PORTAINER_URL="${PORTAINER_URL:-}"
PORTAINER_TOKEN_FILE="${PORTAINER_TOKEN_FILE:-/etc/docker-check-updates/portainer-api-token}"
PORTAINER_INSECURE="${PORTAINER_INSECURE:-auto}"

COUNT_OK=0
COUNT_UPDATE=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_ERROR=0
COUNT_LOCAL=0
COUNT_NETBOX=0
COUNT_NETBOX_REPO=0
COUNT_PORTAINER_OUTDATED=0
COUNT_PORTAINER_UPDATED=0
COUNT_PORTAINER_SKIPPED=0

declare -A PULL_STATUS
declare -A REMOTE_ID
declare -A REMOTE_VERSION
declare -A REMOTE_DATE
declare -A BACKED_UP_IMAGES
declare -A BACKED_UP_VOLUMES
declare -A BACKED_UP_PROJECTS
declare -A UPDATED_SERVICES

# NetBox actions are deferred until the scan is complete. A NetBox Compose
# project can contain multiple containers that are recreated together.
declare -A PENDING_NETBOX_CONTAINER
declare -A PENDING_NETBOX_MODE
declare -A PENDING_NETBOX_TARGET_APP
declare -A PENDING_NETBOX_TARGET_SUPPORT
declare -A PENDING_NETBOX_CURRENT_APP
declare -A PENDING_NETBOX_CURRENT_SUPPORT
declare -A PENDING_NETBOX_SERIES
declare -A PENDING_NETBOX_COUNT

msg() {
    local key="$1"

    case "$key" in
        development) echo "WARNING: this project is under development. Use at your own risk." ;;
        backup_warning) echo "WARNING: keep a tested backup of application data before updating containers." ;;
        unknown_option) echo "ERROR: unknown option" ;;
        no_docker) echo "ERROR: docker command not found." ;;
        no_access) echo "ERROR: cannot access the Docker daemon." ;;
        no_containers) echo "No containers found." ;;
        backup_created) echo "Backup created at" ;;
        rollback_done) echo "Image/configuration rollback completed." ;;
        rollback_data_warning) echo "IMPORTANT: rollback does NOT automatically restore databases or reverse database migrations." ;;
        not_compose) echo "container is not managed by Docker Compose; automatic update skipped." ;;
        update_question) echo "Apply this update? [y/N]" ;;
        backup_failed) echo "ERROR: backup failed. Update cancelled." ;;
        update_ok) echo "updated successfully." ;;
        update_failed) echo "ERROR: update failed." ;;
        netbox_repo_update) echo "Updating the netbox-docker checkout to the required support release." ;;
        netbox_git_required) echo "ERROR: git is required to update a netbox-docker checkout." ;;
        netbox_git_missing) echo "ERROR: NetBox working directory is not a Git checkout." ;;
        netbox_health_failed) echo "ERROR: NetBox did not become healthy after the update." ;;
    esac
}

usage() {
    cat <<EOF_USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  $0                         Check running containers.
  $0 --all                   Include stopped containers.
  $0 --update                Check and update Docker Compose services.
  $0 --update --yes          Update without interactive confirmation.
  $0 --backup                Back up metadata, Compose files and images.
  $0 --backup --backup-volumes
                             Also archive named Docker volumes.
  $0 --rollback DIR          Restore images/configuration from a backup.
  $0 --backup-dir DIR        Set the backup root directory.
  $0 --no-backup             Disable automatic backup for generic updates.
                             NetBox repository upgrades always create a backup.
  $0 --no-portainer           Disable Portainer remote-agent checks.
  $0 --portainer-url URL      Override the Portainer API URL.
  $0 --portainer-token-file FILE
                             Read the Portainer API token from FILE.
  $0 --portainer-insecure     Disable TLS verification for Portainer API.
  $0 --version               Show version.

Notes:
  - Checks may run docker pull and download newer images.
  - --update only recreates Docker Compose managed services.
  - NetBox custom images are handled as a Compose project.
  - A compatible netbox-docker support release can be checked out automatically.
  - NetBox updates are limited to the current major/minor series.
  - Portainer remote-agent checks use the companion Python helper and an API token.
  - With --update, supported Docker Standalone Portainer Agents can be updated.
  - Edge Agent, Kubernetes and Swarm deployments are detected but not generically recreated.
  - Bind mounts are not copied as independent backups.
  - Keep application-native database backups as well.
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) ALL_CONTAINERS=1 ;;
        --update) UPDATE_MODE=1 ;;
        --yes|-y) AUTO_YES=1 ;;
        --backup) BACKUP_ONLY=1 ;;
        --backup-volumes) BACKUP_VOLUMES=1 ;;
        --no-backup) NO_BACKUP=1 ;;
        --no-portainer) PORTAINER_ENABLED=0 ;;
        --portainer-url)
            shift
            [[ $# -gt 0 ]] || { echo "--portainer-url requires a URL" >&2; exit 2; }
            PORTAINER_URL="$1"
            ;;
        --portainer-token-file)
            shift
            [[ $# -gt 0 ]] || { echo "--portainer-token-file requires a file" >&2; exit 2; }
            PORTAINER_TOKEN_FILE="$1"
            ;;
        --portainer-insecure) PORTAINER_INSECURE=1 ;;
        --backup-dir)
            shift
            [[ $# -gt 0 ]] || { echo "--backup-dir requires a directory" >&2; exit 2; }
            BACKUP_ROOT="$1"
            ;;
        --rollback)
            shift
            [[ $# -gt 0 ]] || { echo "--rollback requires a backup directory" >&2; exit 2; }
            ROLLBACK_DIR="$1"
            ;;
        --version|-V)
            echo "${SCRIPT_NAME} v${SCRIPT_VERSION} (${SCRIPT_DATE})"
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "$(msg unknown_option): $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

command -v docker >/dev/null 2>&1 || { msg no_docker; exit 2; }
docker info >/dev/null 2>&1 || { msg no_access; exit 2; }

find_local_portainer_container() {
    local id image

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        image=$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)

        case "$image" in
            portainer/portainer-ce:*|docker.io/portainer/portainer-ce:*|\
            portainer/portainer-ee:*|docker.io/portainer/portainer-ee:*)
                echo "$id"
                return 0
                ;;
        esac
    done < <(docker ps -q)

    return 1
}

detect_portainer_url() {
    local id port

    [[ -n "$PORTAINER_URL" ]] && return 0

    id=$(find_local_portainer_container 2>/dev/null || true)
    [[ -n "$id" ]] || return 1

    port=$(docker port "$id" 9443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    if [[ -n "$port" ]]; then
        PORTAINER_URL="https://127.0.0.1:${port}"
        [[ "$PORTAINER_INSECURE" == "auto" ]] && PORTAINER_INSECURE=1
        return 0
    fi

    port=$(docker port "$id" 9000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    if [[ -n "$port" ]]; then
        PORTAINER_URL="http://127.0.0.1:${port}"
        [[ "$PORTAINER_INSECURE" == "auto" ]] && PORTAINER_INSECURE=0
        return 0
    fi

    return 1
}

portainer_helper_path() {
    local script_dir candidate
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

    for candidate in \
        "$script_dir/portainer-agent-manager.py" \
        "/usr/local/scripts/portainer-agent-manager.py" \
        "/usr/local/sbin/portainer-agent-manager.py"; do

        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

run_portainer_remote_agent_check() {
    local helper summary_file rc
    local outdated=0 updated=0 skipped=0 errors=0

    [[ $PORTAINER_ENABLED -eq 1 ]] || return 0
    detect_portainer_url || return 0

    helper=$(portainer_helper_path 2>/dev/null || true)

    if [[ -z "$helper" ]]; then
        echo
        echo "========================================================================================================================"
        echo " PORTAINER REMOTE AGENTS"
        echo "========================================================================================================================"
        echo "Portainer API : $PORTAINER_URL"
        echo "Status        : SKIPPED - portainer-agent-manager.py was not found."
        echo "Install it next to docker-check-updates.sh."
        return 0
    fi

    if [[ ! -r "$PORTAINER_TOKEN_FILE" ]]; then
        echo
        echo "========================================================================================================================"
        echo " PORTAINER REMOTE AGENTS"
        echo "========================================================================================================================"
        echo "Portainer API : $PORTAINER_URL"
        echo "Status        : NOT CONFIGURED"
        echo "Token file    : $PORTAINER_TOKEN_FILE"
        echo
        echo "Create a Portainer API access token and save it in the token file with mode 600."
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo
        echo "========================================================================================================================"
        echo " PORTAINER REMOTE AGENTS"
        echo "========================================================================================================================"
        echo "Portainer API : $PORTAINER_URL"
        echo "Status        : SKIPPED - python3 is required for Portainer remote-agent integration."
        return 0
    fi

    summary_file=$(mktemp)

    local args=(
        "$helper"
        --url "$PORTAINER_URL"
        --token-file "$PORTAINER_TOKEN_FILE"
        --backup-root "$BACKUP_ROOT"
        --summary-file "$summary_file"
    )

    [[ "$PORTAINER_INSECURE" == "1" ]] && args+=(--insecure)
    [[ $UPDATE_MODE -eq 1 ]] && args+=(--update)
    [[ $AUTO_YES -eq 1 ]] && args+=(--yes)

    python3 "${args[@]}"
    rc=$?

    if [[ -s "$summary_file" ]]; then
        read -r outdated updated skipped errors < <(
            python3 - "$summary_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(
    data.get("outdated", 0),
    data.get("updated", 0),
    data.get("skipped", 0),
    data.get("errors", 0),
)
PY
        )
    fi

    rm -f "$summary_file"

    COUNT_PORTAINER_OUTDATED=$((COUNT_PORTAINER_OUTDATED + outdated))
    COUNT_PORTAINER_UPDATED=$((COUNT_PORTAINER_UPDATED + updated))
    COUNT_PORTAINER_SKIPPED=$((COUNT_PORTAINER_SKIPPED + skipped))

    if [[ $errors -gt 0 ]]; then
        COUNT_ERROR=$((COUNT_ERROR + errors))
    elif [[ $rc -ne 0 ]]; then
        COUNT_ERROR=$((COUNT_ERROR + 1))
    fi
}

get_label() {
    docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

get_image_label() {
    docker image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

short_image_id() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null |
        sed 's/^sha256://' |
        cut -c1-12
}

image_created_date() {
    docker image inspect --format '{{.Created}}' "$1" 2>/dev/null |
        cut -dT -f1
}

compose_command() {
    local container="$1"
    shift

    local project workdir config_files file
    project=$(get_label "$container" "com.docker.compose.project")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")
    config_files=$(get_label "$container" "com.docker.compose.project.config_files")

    [[ -n "$project" && "$project" != "<no value>" ]] || return 10
    [[ -n "$workdir" && "$workdir" != "<no value>" && -d "$workdir" ]] || return 11

    local cmd=(docker compose --project-directory "$workdir" -p "$project")

    if [[ -n "$config_files" && "$config_files" != "<no value>" ]]; then
        IFS=',' read -r -a files <<< "$config_files"
        for file in "${files[@]}"; do
            [[ -f "$file" ]] && cmd+=( -f "$file" )
        done
    fi

    "${cmd[@]}" "$@"
}

is_compose_managed() {
    local project service
    project=$(get_label "$1" "com.docker.compose.project")
    service=$(get_label "$1" "com.docker.compose.service")

    [[ -n "$project" && "$project" != "<no value>" &&
       -n "$service" && "$service" != "<no value>" ]]
}

is_netbox_custom() {
    case "$1" in
        netbox-custom:*|*/netbox-custom:*) return 0 ;;
        *) return 1 ;;
    esac
}

parse_netbox_tag() {
    local tag="$1"
    tag="${tag#v}"

    if [[ "$tag" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

netbox_versions_from_image() {
    local image="$1"
    local original app dockerver rel

    original=$(get_image_label "$image" "netbox.original-tag")

    if [[ -n "$original" && "$original" != "<no value>" ]]; then
        if rel=$(parse_netbox_tag "${original##*:}" 2>/dev/null); then
            printf '%s\n' "$rel"
            return 0
        fi
    fi

    app=$(docker run --rm --entrypoint sh "$image" -c '
        f=/opt/netbox/netbox/netbox/release.yaml
        [ -f "$f" ] || exit 0
        awk -F: '\''/^[[:space:]]*version:[[:space:]]*/ {
            gsub(/["[:space:]]/,"",$2)
            print $2
            exit
        }'\'' "$f"
    ' 2>/dev/null || true)

    dockerver=$(docker run --rm --entrypoint sh "$image" -c '
        [ -f /opt/netbox/VERSION ] &&
        tr -d "[:space:]" </opt/netbox/VERSION
    ' 2>/dev/null || true)

    if [[ -n "$app" || -n "$dockerver" ]]; then
        printf '%s\t%s\n' "${app:-unknown}" "${dockerver:-unknown}"
    fi
}

netbox_series_from_custom_ref() {
    local tag="${1##*:}"

    if [[ "$tag" =~ ^v([0-9]+\.[0-9]+)(\.[0-9]+)?-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

netbox_checkout_version() {
    local workdir
    workdir=$(get_label "$1" "com.docker.compose.project.working_dir")

    [[ -n "$workdir" && "$workdir" != "<no value>" &&
       -f "$workdir/VERSION" ]] || return 1

    tr -d '[:space:]' < "$workdir/VERSION"
}

image_version() {
    local image="$1"
    local ref="$2"
    local version=""

    version=$(get_image_label "$image" "org.opencontainers.image.version")
    [[ "$version" == "<no value>" ]] && version=""

    if [[ -z "$version" && "$ref" == louislam/uptime-kuma:* ]]; then
        version=$(docker run --rm --entrypoint node "$image"             -e 'try{console.log(require("/app/package.json").version)}catch(e){process.exit(1)}'             2>/dev/null || true)
    fi

    if [[ -z "$version" && "$ref" == portainer/portainer-ce:* ]]; then
        version=$(docker run --rm --entrypoint /portainer "$image" --version 2>/dev/null |
            grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' |
            head -1 || true)
    fi

    [[ -n "$version" ]] || version="id:$(short_image_id "$image")"
    echo "$version"
}

ensure_backup_dir() {
    if [[ -z "$RUN_BACKUP_DIR" ]]; then
        RUN_BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_ROOT"
        chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
        mkdir -p "$RUN_BACKUP_DIR"/{containers,images,compose,volumes,database}
        chmod 700 "$RUN_BACKUP_DIR" 2>/dev/null || true

        printf 'script_version=%s\ncreated=%s\nhost=%s\n'             "$SCRIPT_VERSION"             "$(date -Is)"             "$(hostname -f 2>/dev/null || hostname)"             > "$RUN_BACKUP_DIR/backup.info"

        printf 'container_name\tcontainer_id\timage_ref\timage_id\tproject\tservice\tworkdir\n'             > "$RUN_BACKUP_DIR/manifest.tsv"
    fi
}

backup_compose_project() {
    local container="$1"
    local project workdir config_files key file

    project=$(get_label "$container" "com.docker.compose.project")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")
    config_files=$(get_label "$container" "com.docker.compose.project.config_files")
    key="${project}:${workdir}"

    [[ -n "${BACKED_UP_PROJECTS[$key]+x}" ]] && return 0
    BACKED_UP_PROJECTS[$key]=1

    [[ -d "$workdir" ]] || return 0
    mkdir -p "$RUN_BACKUP_DIR/compose/$project"

    if [[ -n "$config_files" && "$config_files" != "<no value>" ]]; then
        IFS=',' read -r -a files <<< "$config_files"
        for file in "${files[@]}"; do
            [[ -f "$file" ]] && cp -a "$file" "$RUN_BACKUP_DIR/compose/$project/"
        done
    fi

    [[ -f "$workdir/.env" ]] && cp -a "$workdir/.env" "$RUN_BACKUP_DIR/compose/$project/"
    [[ -f "$workdir/VERSION" ]] && cp -a "$workdir/VERSION" "$RUN_BACKUP_DIR/compose/$project/"
}

backup_image() {
    local image_id="$1"
    local short

    [[ -n "${BACKED_UP_IMAGES[$image_id]+x}" ]] && return 0

    short="${image_id#sha256:}"
    short="${short:0:12}"

    echo "Saving image ${short} ..."
    docker image save -o "$RUN_BACKUP_DIR/images/${short}.tar" "$image_id" || return 1

    BACKED_UP_IMAGES[$image_id]=1
}

backup_named_volumes() {
    local container="$1"
    local volume

    [[ $BACKUP_VOLUMES -eq 1 ]] || return 0

    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        [[ -n "${BACKED_UP_VOLUMES[$volume]+x}" ]] && continue

        BACKED_UP_VOLUMES[$volume]=1
        echo "Backing up volume ${volume} ..."

        docker run --rm             -v "${volume}:/source:ro"             -v "${RUN_BACKUP_DIR}/volumes:/backup"             alpine:3.20             tar -C /source -czf "/backup/${volume}.tar.gz" . || return 1
    done < <(
        docker inspect "$container"             --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}'             2>/dev/null
    )
}

backup_netbox_database() {
    local container="$1"
    local project pg dumpfile

    project=$(get_label "$container" "com.docker.compose.project")
    [[ -n "$project" && "$project" != "<no value>" ]] || return 0

    dumpfile="$RUN_BACKUP_DIR/database/${project}-postgres.dump"
    [[ -f "$dumpfile" ]] && return 0

    pg=$(docker ps -q         --filter "label=com.docker.compose.project=${project}"         --filter "label=com.docker.compose.service=postgres" |
        head -1)

    [[ -n "$pg" ]] || {
        echo "WARNING: PostgreSQL container not found for NetBox project ${project}." >&2
        return 1
    }

    echo "Creating NetBox PostgreSQL dump ..."

    if ! docker exec "$pg" sh -c         'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'         > "$dumpfile"; then
        rm -f "$dumpfile"
        return 1
    fi
}

backup_container() {
    local container="$1"
    local name image_ref image_id project service workdir

    ensure_backup_dir

    name=$(docker inspect --format '{{.Name}}' "$container" | sed 's#^/##')
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$container")
    image_id=$(docker inspect --format '{{.Image}}' "$container")
    project=$(get_label "$container" "com.docker.compose.project")
    service=$(get_label "$container" "com.docker.compose.service")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")

    docker inspect "$container"         > "$RUN_BACKUP_DIR/containers/${name}.inspect.json" || return 1

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n'         "$name" "$container" "$image_ref" "$image_id"         "$project" "$service" "$workdir"         >> "$RUN_BACKUP_DIR/manifest.tsv"

    backup_image "$image_id" || return 1

    if is_compose_managed "$container"; then
        backup_compose_project "$container"
    fi

    backup_named_volumes "$container" || return 1

    if is_netbox_custom "$image_ref"; then
        backup_netbox_database "$container" || return 1
    fi
}

backup_netbox_workdir() {
    local container="$1"
    local project workdir commit ref dir archive

    command -v git >/dev/null 2>&1 || { msg netbox_git_required; return 1; }

    project=$(get_label "$container" "com.docker.compose.project")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")

    [[ -n "$project" && "$project" != "<no value>" ]] || return 1
    [[ -d "$workdir/.git" ]] || { msg netbox_git_missing; return 1; }

    ensure_backup_dir

    dir="$RUN_BACKUP_DIR/compose/$project"
    archive="$dir/workdir-before-update.tar.gz"
    mkdir -p "$dir"

    commit=$(git -C "$workdir" rev-parse HEAD 2>/dev/null) || return 1
    ref=$(git -C "$workdir" symbolic-ref --short -q HEAD 2>/dev/null ||
          git -C "$workdir" describe --tags --exact-match 2>/dev/null ||
          echo "detached")

    printf '%s\t%s\t%s\t%s\n'         "$project" "$workdir" "$commit" "$ref"         > "$dir/netbox-repo.state"

    git -C "$workdir" status --porcelain=v1         > "$dir/git-status-before-update.txt" 2>/dev/null || true

    git -C "$workdir" diff --binary HEAD         > "$dir/local-changes.patch" 2>/dev/null || true

    echo "Backing up NetBox working directory ..."
    tar --exclude='./.git' -C "$workdir" -czf "$archive" . || return 1
}

backup_netbox_project() {
    local container="$1"
    local project id

    project=$(get_label "$container" "com.docker.compose.project")
    [[ -n "$project" && "$project" != "<no value>" ]] || return 1

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        backup_container "$id" || return 1
    done < <(
        docker ps -aq             --filter "label=com.docker.compose.project=${project}"
    )

    backup_netbox_workdir "$container" || return 1
}

restore_netbox_workdir_snapshot() {
    local project="$1"
    local workdir="$2"
    local commit="$3"
    local archive="$4"

    [[ -d "$workdir/.git" ]] || return 1

    echo "Restoring previous NetBox working directory ..."

    git -C "$workdir" reset --hard >/dev/null 2>&1 || true
    git -C "$workdir" checkout --detach "$commit" >/dev/null 2>&1 || return 1

    [[ -f "$archive" ]] &&
        tar -C "$workdir" -xzf "$archive" || true

    return 0
}

ensure_netbox_configuration_permissions() {
    local workdir="$1"
    local config_dir="$workdir/configuration"

    [[ -d "$config_dir" ]] || return 0

    # NetBox Docker runs the application as user "netbox" with group "root".
    # When running as root, keep configuration private from other users while
    # allowing the container's root group to traverse/read the bind mount.
    if [[ $(id -u) -eq 0 ]]; then
        chgrp -R 0 "$config_dir" || return 1
        find "$config_dir" -type d -exec chmod 750 {} + || return 1
        find "$config_dir" -type f -exec chmod 640 {} + || return 1
    else
        # Non-root users cannot reliably change the group to GID 0. Fall back
        # to read/traverse permissions required by the bind-mounted container.
        find "$config_dir" -type d -exec chmod a+rx {} + || return 1
        find "$config_dir" -type f -exec chmod a+r {} + || return 1
    fi
}

prepare_netbox_custom_files() {
    local workdir="$1"
    local series="$2"
    local current_app="$3"
    local target_app="$4"
    local current_support="$5"
    local target_support="$6"
    local file

    # A custom Dockerfile using "latest" could silently jump to another
    # NetBox major/minor series. Refuse that unsafe build.
    while IFS= read -r -d '' file; do
        if grep -Eq             '^[[:space:]]*FROM[[:space:]]+([^[:space:]]*/)?netboxcommunity/netbox:latest([[:space:]]|$)'             "$file"; then
            echo "ERROR: $file uses netboxcommunity/netbox:latest." >&2
            echo "Pin the custom image to the current NetBox series before updating." >&2
            return 1
        fi
    done < <(
        find "$workdir" -maxdepth 2 -type f -name 'Dockerfile*' -print0 2>/dev/null
    )

    # Update only explicit version strings that match the currently installed
    # NetBox series/support release. All files are already included in backup.
    while IFS= read -r -d '' file; do
        sed -i             -e "s|v${series}-${current_support}|v${series}-${target_support}|g"             -e "s|v${current_app}-${current_support}|v${target_app}-${target_support}|g"             "$file"
    done < <(
        find "$workdir" -maxdepth 2 -type f             \( -name 'Dockerfile*' -o                -name 'docker-compose*.yml' -o                -name 'docker-compose*.yaml' \)             -print0 2>/dev/null
    )
}

capture_netbox_diagnostics() {
    local project="$1"
    local container_hint="$2"
    local dir id name

    ensure_backup_dir
    dir="$RUN_BACKUP_DIR/diagnostics/$project"
    mkdir -p "$dir"

    echo "Capturing NetBox diagnostics in $dir ..."

    {
        echo "timestamp=$(date -Is)"
        echo "project=$project"
        echo "host=$(hostname -f 2>/dev/null || hostname)"
        docker version 2>&1 || true
        docker compose version 2>&1 || true
    } > "$dir/environment.txt"

    if [[ -n "$container_hint" ]]; then
        compose_command "$container_hint" ps -a \
            > "$dir/compose-ps.txt" 2>&1 || true

        compose_command "$container_hint" config \
            > "$dir/compose-config.yml" 2>&1 || true
    fi

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue

        name=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
        [[ -n "$name" ]] || name="$id"

        docker inspect "$id" \
            > "$dir/${name}.inspect.json" 2>&1 || true

        docker logs --timestamps --tail 500 "$id" \
            > "$dir/${name}.log" 2>&1 || true

        docker inspect "$id" --format \
            '{{range .State.Health.Log}}{{println .Start "\t" .End "\t" .ExitCode "\t" .Output}}{{end}}' \
            > "$dir/${name}.health.log" 2>&1 || true
    done < <(
        docker ps -aq \
            --filter "label=com.docker.compose.project=${project}"
    )

    echo "Diagnostics saved to: $dir"
}

wait_netbox_healthy() {
    local project="$1"
    local cid health state attempt

    for attempt in $(seq 1 180); do
        cid=$(docker ps -q             --filter "label=com.docker.compose.project=${project}"             --filter "label=com.docker.compose.service=netbox" |
            head -1)

        if [[ -n "$cid" ]]; then
            health=$(docker inspect                 --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}'                 "$cid" 2>/dev/null || true)

            state=$(docker inspect                 --format '{{.State.Status}}'                 "$cid" 2>/dev/null || true)

            if [[ "$health" == "healthy" ]]; then
                return 0
            fi

            if [[ -z "$health" && "$state" == "running" ]]; then
                return 0
            fi
        fi

        sleep 2
    done

    return 1
}

netbox_repo_update() {
    local container="$1"
    local current_app="$2"
    local target_app="$3"
    local current_support="$4"
    local target_support="$5"
    local series="$6"

    local project workdir original_commit original_ref target_commit
    local dirty stash_ref="" backup_dir archive target_tag
    local new_cid new_image new_pair new_app

    project=$(get_label "$container" "com.docker.compose.project")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")

    command -v git >/dev/null 2>&1 || { msg netbox_git_required; return 1; }
    [[ -d "$workdir/.git" ]] || { msg netbox_git_missing; return 1; }

    echo
    echo "NetBox project      : $project"
    echo "NetBox              : $current_app -> $target_app"
    echo "netbox-docker       : $current_support -> $target_support"
    echo "Working directory   : $workdir"

    # NetBox repository upgrades always force a backup even when --no-backup
    # was requested for generic container updates.
    if ! backup_netbox_project "$container"; then
        msg backup_failed
        return 1
    fi

    backup_dir="$RUN_BACKUP_DIR/compose/$project"
    archive="$backup_dir/workdir-before-update.tar.gz"

    original_commit=$(git -C "$workdir" rev-parse HEAD) || return 1
    original_ref=$(git -C "$workdir" symbolic-ref --short -q HEAD 2>/dev/null ||
                   git -C "$workdir" describe --tags --exact-match 2>/dev/null ||
                   echo "detached")

    echo "$(msg netbox_repo_update)"
    echo "Fetching Git tags ..."

    git -C "$workdir" fetch --tags origin || return 1

    target_commit=$(git -C "$workdir" rev-parse "refs/tags/${target_support}^{commit}" 2>/dev/null) || {
        echo "ERROR: netbox-docker tag ${target_support} was not found." >&2
        return 1
    }

    dirty=$(git -C "$workdir" status --porcelain=v1)

    if [[ -n "$dirty" ]]; then
        echo "Saving local NetBox customizations in a Git stash ..."
        git -C "$workdir" stash push --include-untracked             -m "docker-check-updates v${SCRIPT_VERSION} before ${target_support}"             >/dev/null || return 1

        stash_ref=$(git -C "$workdir" rev-parse refs/stash 2>/dev/null || true)
    fi

    if ! git -C "$workdir" checkout --detach "$target_support"; then
        restore_netbox_workdir_snapshot             "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    if [[ -n "$stash_ref" ]]; then
        echo "Reapplying local NetBox customizations ..."

        if ! git -C "$workdir" stash apply "$stash_ref"; then
            echo "ERROR: local customizations conflict with netbox-docker ${target_support}." >&2
            echo "The running containers were not changed." >&2

            restore_netbox_workdir_snapshot                 "$project" "$workdir" "$original_commit" "$archive"

            echo "A safety stash was preserved at: $stash_ref" >&2
            return 1
        fi
    fi

    if [[ "$(tr -d '[:space:]' < "$workdir/VERSION" 2>/dev/null)" != "$target_support" ]]; then
        echo "ERROR: checkout VERSION does not match ${target_support}." >&2
        restore_netbox_workdir_snapshot             "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    if ! prepare_netbox_custom_files         "$workdir" "$series" "$current_app" "$target_app"         "$current_support" "$target_support"; then

        restore_netbox_workdir_snapshot             "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    if ! ensure_netbox_configuration_permissions "$workdir"; then
        echo "ERROR: unable to set readable permissions on NetBox configuration." >&2
        restore_netbox_workdir_snapshot \
            "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    target_tag="v${series}-${target_support}"

    echo "Validating Docker Compose configuration ..."
    if ! VERSION="$target_tag" compose_command "$container" config >/dev/null; then
        echo "ERROR: Docker Compose configuration is invalid after the repository update." >&2
        restore_netbox_workdir_snapshot             "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    echo "Building NetBox custom image ..."
    if ! VERSION="$target_tag" compose_command "$container" build --pull; then
        echo "ERROR: NetBox custom image build failed. Running containers were not changed." >&2
        restore_netbox_workdir_snapshot             "$project" "$workdir" "$original_commit" "$archive"
        return 1
    fi

    echo "Applying NetBox Compose project update ..."
    if ! VERSION="$target_tag" compose_command "$container" up -d; then
        echo "ERROR: Docker Compose failed while applying the NetBox update." >&2
        capture_netbox_diagnostics "$project" "$container"
        echo "Backup directory: $RUN_BACKUP_DIR" >&2
        return 1
    fi

    if ! wait_netbox_healthy "$project"; then
        msg netbox_health_failed
        capture_netbox_diagnostics "$project" "$container"
        echo "Backup directory: $RUN_BACKUP_DIR" >&2
        return 1
    fi

    new_cid=$(docker ps -q         --filter "label=com.docker.compose.project=${project}"         --filter "label=com.docker.compose.service=netbox" |
        head -1)

    if [[ -n "$new_cid" ]]; then
        new_image=$(docker inspect --format '{{.Image}}' "$new_cid" 2>/dev/null || true)
        new_pair=$(netbox_versions_from_image "$new_image" 2>/dev/null || true)
        new_app=$(printf '%s' "$new_pair" | cut -f1)

        if [[ -n "$new_app" && "$new_app" != "unknown" ]]; then
            echo "NetBox running version: $new_app"

            if [[ "$new_app" == "$current_app" ]]; then
                echo "ERROR: custom image was rebuilt but NetBox did not advance from $current_app." >&2
                echo "Check the custom Dockerfile base image." >&2
                return 1
            fi
        fi
    fi

    echo "NetBox project updated successfully."
    echo "Previous Git ref: $original_ref ($original_commit)"
    echo "Current Git ref : $target_support ($target_commit)"
    echo "Backup          : $RUN_BACKUP_DIR"

    # The stash is intentionally retained as an additional recovery point.
    if [[ -n "$stash_ref" ]]; then
        echo "Safety Git stash : $stash_ref"
    fi

    return 0
}

netbox_rebuild() {
    local container="$1"
    local current_app="$2"
    local target_app="$3"
    local support="$4"
    local series="$5"

    local project workdir target_tag new_cid new_image new_pair new_app

    project=$(get_label "$container" "com.docker.compose.project")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")

    echo
    echo "NetBox project      : $project"
    echo "NetBox              : $current_app -> $target_app"
    echo "netbox-docker       : $support"
    echo "Working directory   : $workdir"

    if ! backup_netbox_project "$container"; then
        msg backup_failed
        return 1
    fi

    if ! prepare_netbox_custom_files         "$workdir" "$series" "$current_app" "$target_app"         "$support" "$support"; then
        return 1
    fi

    ensure_netbox_configuration_permissions "$workdir" || return 1

    target_tag="v${series}-${support}"

    echo "Building NetBox custom image ..."
    VERSION="$target_tag" compose_command "$container" build --pull || return 1

    echo "Applying NetBox Compose project update ..."
    VERSION="$target_tag" compose_command "$container" up -d || return 1

    wait_netbox_healthy "$project" || {
        msg netbox_health_failed
        capture_netbox_diagnostics "$project" "$container"
        return 1
    }

    new_cid=$(docker ps -q         --filter "label=com.docker.compose.project=${project}"         --filter "label=com.docker.compose.service=netbox" |
        head -1)

    if [[ -n "$new_cid" ]]; then
        new_image=$(docker inspect --format '{{.Image}}' "$new_cid" 2>/dev/null || true)
        new_pair=$(netbox_versions_from_image "$new_image" 2>/dev/null || true)
        new_app=$(printf '%s' "$new_pair" | cut -f1)

        [[ -n "$new_app" ]] && echo "NetBox running version: $new_app"
    fi

    echo "NetBox project updated successfully."
    echo "Backup: $RUN_BACKUP_DIR"

    return 0
}

restore_netbox_repositories_from_backup() {
    local dir="$1"
    local state project workdir commit ref archive

    while IFS= read -r -d '' state; do
        IFS=$'\t' read -r project workdir commit ref < "$state"

        [[ -n "$workdir" && -d "$workdir/.git" && -n "$commit" ]] || continue

        archive="$(dirname "$state")/workdir-before-update.tar.gz"

        echo "Restoring NetBox repository for project $project ..."
        git -C "$workdir" reset --hard >/dev/null 2>&1 || true
        git -C "$workdir" checkout --detach "$commit" >/dev/null 2>&1 || {
            echo "WARNING: unable to restore Git commit $commit for $project." >&2
            continue
        }

        [[ -f "$archive" ]] &&
            tar -C "$workdir" -xzf "$archive" || true
    done < <(
        find "$dir/compose" -type f -name netbox-repo.state -print0 2>/dev/null
    )
}

rollback_from_backup() {
    local dir="$1"
    local name cid image_ref image_id project service workdir tarfile

    [[ -f "$dir/manifest.tsv" ]] || {
        echo "Invalid backup: $dir" >&2
        return 1
    }

    restore_netbox_repositories_from_backup "$dir"

    echo "Loading saved images ..."

    for tarfile in "$dir"/images/*.tar; do
        [[ -f "$tarfile" ]] || continue
        docker image load -i "$tarfile" >/dev/null || return 1
    done

    while IFS=$'\t' read -r name cid image_ref image_id project service workdir; do
        [[ "$name" == "container_name" ]] && continue
        [[ -n "$image_id" && -n "$image_ref" ]] || continue

        docker image inspect "$image_id" >/dev/null 2>&1 || {
            echo "Missing image $image_id for $name" >&2
            continue
        }

        docker tag "$image_id" "$image_ref" || continue

        [[ -n "$project" && -n "$service" && -d "$workdir" ]] || continue

        (
            cd "$workdir" || exit 1
            docker compose -p "$project" up -d --no-deps "$service"
        ) || true
    done < "$dir/manifest.tsv"

    msg rollback_done
    msg rollback_data_warning

    if compgen -G "$dir/database/*.dump" >/dev/null 2>&1; then
        echo "Database dump(s) are available under: $dir/database"
        echo "Database restoration is intentionally manual."
    fi
}

confirm_update() {
    [[ $AUTO_YES -eq 1 ]] && return 0

    local answer
    printf '%s ' "$(msg update_question)"
    read -r answer

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

queue_netbox_action() {
    local container="$1"
    local mode="$2"
    local current_app="$3"
    local target_app="$4"
    local current_support="$5"
    local target_support="$6"
    local series="$7"

    local project
    project=$(get_label "$container" "com.docker.compose.project")

    [[ -n "$project" && "$project" != "<no value>" ]] || return 1

    PENDING_NETBOX_CONTAINER[$project]="$container"
    PENDING_NETBOX_MODE[$project]="$mode"
    PENDING_NETBOX_TARGET_APP[$project]="$target_app"
    PENDING_NETBOX_TARGET_SUPPORT[$project]="$target_support"
    PENDING_NETBOX_CURRENT_APP[$project]="$current_app"
    PENDING_NETBOX_CURRENT_SUPPORT[$project]="$current_support"
    PENDING_NETBOX_SERIES[$project]="$series"

    PENDING_NETBOX_COUNT[$project]=$(( ${PENDING_NETBOX_COUNT[$project]:-0} + 1 ))
}

process_netbox_actions() {
    local project container mode target_app target_support
    local current_app current_support series count

    [[ $UPDATE_MODE -eq 1 ]] || return 0

    for project in "${!PENDING_NETBOX_MODE[@]}"; do
        container="${PENDING_NETBOX_CONTAINER[$project]}"
        mode="${PENDING_NETBOX_MODE[$project]}"
        target_app="${PENDING_NETBOX_TARGET_APP[$project]}"
        target_support="${PENDING_NETBOX_TARGET_SUPPORT[$project]}"
        current_app="${PENDING_NETBOX_CURRENT_APP[$project]}"
        current_support="${PENDING_NETBOX_CURRENT_SUPPORT[$project]}"
        series="${PENDING_NETBOX_SERIES[$project]}"
        count="${PENDING_NETBOX_COUNT[$project]}"

        echo
        echo "------------------------------------------------------------------------------------------------------------------------"
        echo "Pending NetBox project update: $project"
        echo "------------------------------------------------------------------------------------------------------------------------"

        if ! confirm_update; then
            COUNT_SKIPPED=$(( COUNT_SKIPPED + count ))
            continue
        fi

        if [[ "$mode" == "repo" ]]; then
            if netbox_repo_update                 "$container" "$current_app" "$target_app"                 "$current_support" "$target_support" "$series"; then

                COUNT_UPDATED=$(( COUNT_UPDATED + count ))
            else
                COUNT_ERROR=$(( COUNT_ERROR + 1 ))
                COUNT_SKIPPED=$(( COUNT_SKIPPED + count ))
            fi
        else
            if netbox_rebuild                 "$container" "$current_app" "$target_app"                 "$current_support" "$series"; then

                COUNT_UPDATED=$(( COUNT_UPDATED + count ))
            else
                COUNT_ERROR=$(( COUNT_ERROR + 1 ))
                COUNT_SKIPPED=$(( COUNT_SKIPPED + count ))
            fi
        fi
    done
}

if [[ -n "$ROLLBACK_DIR" ]]; then
    rollback_from_backup "$ROLLBACK_DIR"
    exit $?
fi

mapfile -t CONTAINERS < <(
    if [[ $ALL_CONTAINERS -eq 1 ]]; then
        docker ps -aq
    else
        docker ps -q
    fi
)

[[ ${#CONTAINERS[@]} -gt 0 ]] || {
    msg no_containers
    exit 0
}

if [[ $BACKUP_ONLY -eq 1 && $UPDATE_MODE -eq 0 ]]; then
    for container in "${CONTAINERS[@]}"; do
        backup_container "$container" || exit 1
    done

    echo "$(msg backup_created): $RUN_BACKUP_DIR"
    exit 0
fi

msg development
msg backup_warning

echo
printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'     "CONTAINER" "IMAGE" "INSTALLED" "AVAILABLE" "DATE" "STATUS"

printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'     "--------------------------------------"     "----------------------------------"     "------------------"     "------------------"     "------------"     "------------------"

for container in "${CONTAINERS[@]}"; do
    name=$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null | sed 's#^/##')
    [[ -n "$name" ]] || continue

    image_ref=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null)
    current_id=$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null)

    if is_netbox_custom "$image_ref"; then
        ((COUNT_NETBOX++)) || true

        current_pair=$(netbox_versions_from_image "$current_id" || true)
        current_app=$(printf '%s' "$current_pair" | cut -f1)
        current_support=$(printf '%s' "$current_pair" | cut -f2)

        [[ -n "$current_app" ]] || current_app="unknown"

        checkout_support=$(netbox_checkout_version "$container" 2>/dev/null || true)

        if [[ -z "$current_support" || "$current_support" == "unknown" ]]; then
            current_support="$checkout_support"
        fi

        series=$(netbox_series_from_custom_ref "$image_ref" 2>/dev/null || true)

        if [[ -z "$series" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_app" "-" "-" "LOCAL BUILD"

            ((COUNT_LOCAL++)) || true
            continue
        fi

        base_ref="docker.io/netboxcommunity/netbox:v${series}"

        if ! docker pull "$base_ref" >/dev/null 2>&1; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_app" "-" "-" "BASE PULL ERROR"

            ((COUNT_ERROR++)) || true
            continue
        fi

        base_id=$(docker image inspect --format '{{.Id}}' "$base_ref")
        available_pair=$(netbox_versions_from_image "$base_id" || true)
        available_app=$(printf '%s' "$available_pair" | cut -f1)
        available_support=$(printf '%s' "$available_pair" | cut -f2)
        date=$(image_created_date "$base_id")

        if [[ -n "$available_support" &&
              -n "$checkout_support" &&
              "$available_support" != "$checkout_support" ]]; then

            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_app" "${available_app:-?}"                 "$date" "REPO ${available_support}"

            ((COUNT_UPDATE++)) || true
            ((COUNT_NETBOX_REPO++)) || true

            if [[ $UPDATE_MODE -eq 1 ]]; then
                queue_netbox_action                     "$container" "repo" "$current_app" "${available_app:-unknown}"                     "${checkout_support:-$current_support}" "$available_support" "$series"
            fi

            continue
        fi

        if [[ -n "$available_app" && "$current_app" == "$available_app" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_app" "$available_app"                 "$date" "LOCAL OK"

            ((COUNT_OK++)) || true
            continue
        fi

        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'             "$name" "$image_ref" "$current_app" "${available_app:-?}"             "$date" "REBUILD"

        ((COUNT_UPDATE++)) || true

        if [[ $UPDATE_MODE -eq 1 ]]; then
            queue_netbox_action                 "$container" "rebuild" "$current_app" "${available_app:-unknown}"                 "${checkout_support:-$current_support}"                 "${checkout_support:-$current_support}" "$series"
        fi

        continue
    fi

    current_version=$(image_version "$current_id" "$image_ref")

    if [[ "$image_ref" == *@sha256:* || "$image_ref" == sha256:* ]]; then
        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'             "$name" "$image_ref" "$current_version" "-" "-" "PINNED"

        ((COUNT_OK++)) || true
        continue
    fi

    if [[ -z "${PULL_STATUS[$image_ref]+x}" ]]; then
        if docker pull "$image_ref" >/dev/null 2>&1; then
            PULL_STATUS[$image_ref]="OK"
            REMOTE_ID[$image_ref]=$(docker image inspect --format '{{.Id}}' "$image_ref")
            REMOTE_VERSION[$image_ref]=$(image_version "$image_ref" "$image_ref")
            REMOTE_DATE[$image_ref]=$(image_created_date "$image_ref")
        else
            PULL_STATUS[$image_ref]="ERROR"
        fi
    fi

    if [[ "${PULL_STATUS[$image_ref]}" == "ERROR" ]]; then
        digests=$(docker image inspect             --format '{{join .RepoDigests ","}}'             "$current_id" 2>/dev/null || true)

        if [[ -z "$digests" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_version" "-" "-" "LOCAL BUILD"

            ((COUNT_LOCAL++)) || true
        else
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'                 "$name" "$image_ref" "$current_version" "-" "-" "PULL ERROR"

            ((COUNT_ERROR++)) || true
        fi

        continue
    fi

    new_id="${REMOTE_ID[$image_ref]}"
    new_version="${REMOTE_VERSION[$image_ref]}"
    date="${REMOTE_DATE[$image_ref]}"

    if [[ "$current_id" == "$new_id" ]]; then
        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'             "$name" "$image_ref" "$current_version" "$new_version"             "$date" "UP TO DATE"

        ((COUNT_OK++)) || true
        continue
    fi

    printf '%-38s %-34s %-18s %-18s %-12s %-18s\n'         "$name" "$image_ref" "$current_version" "$new_version"         "$date" "UPDATE"

    ((COUNT_UPDATE++)) || true

    [[ $UPDATE_MODE -eq 1 ]] || continue

    if ! is_compose_managed "$container"; then
        echo "  -> $name: $(msg not_compose)"
        ((COUNT_SKIPPED++)) || true
        continue
    fi

    service=$(get_label "$container" "com.docker.compose.service")
    project=$(get_label "$container" "com.docker.compose.project")
    key="${project}:${service}"

    [[ -n "${UPDATED_SERVICES[$key]+x}" ]] && continue

    if ! confirm_update; then
        ((COUNT_SKIPPED++)) || true
        continue
    fi

    if [[ $NO_BACKUP -eq 0 ]]; then
        if ! backup_container "$container"; then
            msg backup_failed
            ((COUNT_ERROR++)) || true
            continue
        fi
    fi

    if compose_command "$container" pull "$service" &&
       compose_command "$container" up -d --no-deps "$service"; then

        UPDATED_SERVICES[$key]=1
        ((COUNT_UPDATED++)) || true
        echo "  -> $name $(msg update_ok)"
    else
        ((COUNT_ERROR++)) || true
        msg update_failed
    fi
done

# NetBox project actions run only after every original container has been
# inspected. This avoids invalidating container IDs halfway through the scan.
process_netbox_actions

run_portainer_remote_agent_check

echo
echo "========================================================================================================================"
echo " SUMMARY"
echo "========================================================================================================================"
echo "Up to date                  : $COUNT_OK"
echo "Updates found               : $COUNT_UPDATE"
echo "Updates applied             : $COUNT_UPDATED"
echo "Updates skipped             : $COUNT_SKIPPED"
echo "Local/build images          : $COUNT_LOCAL"
echo "NetBox custom containers    : $COUNT_NETBOX"
echo "NetBox repo updates needed  : $COUNT_NETBOX_REPO"
echo "Portainer outdated Agents   : $COUNT_PORTAINER_OUTDATED"
echo "Portainer Agents updated    : $COUNT_PORTAINER_UPDATED"
echo "Portainer Agents skipped    : $COUNT_PORTAINER_SKIPPED"
echo "Errors                      : $COUNT_ERROR"

[[ -n "$RUN_BACKUP_DIR" ]] &&
    echo "$(msg backup_created): $RUN_BACKUP_DIR"
