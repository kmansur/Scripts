#!/usr/bin/env bash
#
# docker-check-updates.sh
#
# Docker image update checker with optional Docker Compose updates,
# backups, rollback support and special handling for NetBox Docker.
#
# Version: 1.4.0
# Date:    2026-09-18
# License: MIT
#
# This project is under development. Use at your own risk.
# Always keep a tested backup of application data before updating containers.
#

set -u

SCRIPT_NAME="docker-check-updates.sh"
SCRIPT_VERSION="1.4.0"
SCRIPT_DATE="2026-09-18"
LANGUAGE="${DCU_LANG:-en}"

ALL_CONTAINERS=0
UPDATE_MODE=0
AUTO_YES=0
BACKUP_ONLY=0
BACKUP_VOLUMES=0
NO_BACKUP=0
ROLLBACK_DIR=""
BACKUP_ROOT="/var/backups/docker-check-updates"
RUN_BACKUP_DIR=""

COUNT_OK=0
COUNT_UPDATE=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_ERROR=0
COUNT_LOCAL=0
COUNT_NETBOX=0
COUNT_NETBOX_REPO=0

declare -A PULL_STATUS
declare -A REMOTE_ID
declare -A REMOTE_VERSION
declare -A REMOTE_DATE
declare -A BACKED_UP_IMAGES
declare -A BACKED_UP_VOLUMES
declare -A BACKED_UP_PROJECTS
declare -A UPDATED_SERVICES

msg() {
    local key="$1"
    case "${LANGUAGE}:${key}" in
        pt_BR:development) echo "AVISO: este projeto está em desenvolvimento. O uso é por conta e risco do usuário." ;;
        pt_BR:backup_warning) echo "ATENÇÃO: mantenha backup testado dos dados das aplicações antes de atualizar containers." ;;
        pt_BR:unknown_option) echo "ERRO: opção desconhecida" ;;
        pt_BR:no_docker) echo "ERRO: comando docker não encontrado." ;;
        pt_BR:no_access) echo "ERRO: não foi possível acessar o Docker daemon." ;;
        pt_BR:no_containers) echo "Nenhum container encontrado." ;;
        pt_BR:backup_created) echo "Backup criado em" ;;
        pt_BR:rollback_done) echo "Rollback de imagens/configuração concluído." ;;
        pt_BR:rollback_data_warning) echo "IMPORTANTE: o rollback NÃO desfaz migrações de banco de dados nem alterações em bind mounts." ;;
        pt_BR:netbox_repo) echo "NetBox requer atualização compatível do checkout netbox-docker antes do rebuild." ;;
        pt_BR:not_compose) echo "container não é gerenciado pelo Docker Compose; atualização automática ignorada." ;;
        pt_BR:update_question) echo "Deseja atualizar este serviço? [s/N]" ;;
        pt_BR:backup_failed) echo "ERRO: falha ao criar backup. Atualização cancelada." ;;
        pt_BR:update_ok) echo "atualizado com sucesso." ;;
        pt_BR:update_failed) echo "ERRO: falha na atualização." ;;
        en:development|*:development) echo "WARNING: this project is under development. Use at your own risk." ;;
        en:backup_warning|*:backup_warning) echo "WARNING: keep a tested backup of application data before updating containers." ;;
        en:unknown_option|*:unknown_option) echo "ERROR: unknown option" ;;
        en:no_docker|*:no_docker) echo "ERROR: docker command not found." ;;
        en:no_access|*:no_access) echo "ERROR: cannot access the Docker daemon." ;;
        en:no_containers|*:no_containers) echo "No containers found." ;;
        en:backup_created|*:backup_created) echo "Backup created at" ;;
        en:rollback_done|*:rollback_done) echo "Image/configuration rollback completed." ;;
        en:rollback_data_warning|*:rollback_data_warning) echo "IMPORTANT: rollback does NOT reverse database migrations or changes in bind mounts." ;;
        en:netbox_repo|*:netbox_repo) echo "NetBox requires a compatible netbox-docker checkout update before rebuild." ;;
        en:not_compose|*:not_compose) echo "container is not managed by Docker Compose; automatic update skipped." ;;
        en:update_question|*:update_question) echo "Update this service? [y/N]" ;;
        en:backup_failed|*:backup_failed) echo "ERROR: backup failed. Update cancelled." ;;
        en:update_ok|*:update_ok) echo "updated successfully." ;;
        en:update_failed|*:update_failed) echo "ERROR: update failed." ;;
    esac
}

usage() {
    if [[ "$LANGUAGE" == "pt_BR" ]]; then
        cat <<EOF_USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}

Uso:
  $0                         Verifica containers em execução.
  $0 --all                   Inclui containers parados.
  $0 --update                Verifica e atualiza serviços Docker Compose.
  $0 --update --yes          Atualiza sem confirmação interativa.
  $0 --backup                Cria backup de metadados, Compose e imagens.
  $0 --backup --backup-volumes
                             Também arquiva volumes Docker nomeados.
  $0 --rollback DIR          Restaura imagens/configuração a partir de um backup.
  $0 --backup-dir DIR        Define o diretório raiz dos backups.
  $0 --no-backup             Desativa o backup automático antes de --update (não recomendado).
  $0 --version               Exibe a versão.

Observações:
  - A verificação pode executar docker pull e baixar novas imagens.
  - --update só recria serviços gerenciados pelo Docker Compose.
  - O backup padrão salva metadados, arquivos Compose e imagens antigas.
  - --backup-volumes adiciona cópia dos volumes Docker nomeados.
  - Bind mounts não são copiados automaticamente.
  - Para bancos de dados, mantenha também backup nativo da aplicação.
EOF_USAGE
    else
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
  $0 --no-backup             Disable automatic backup before --update (not recommended).
  $0 --version               Show version.

Notes:
  - Checks may run docker pull and download newer images.
  - --update only recreates Docker Compose managed services.
  - Default backup stores metadata, Compose files and previous images.
  - --backup-volumes additionally archives named Docker volumes.
  - Bind mounts are not copied automatically.
  - Keep application-native database backups as well.
EOF_USAGE
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) ALL_CONTAINERS=1 ;;
        --update) UPDATE_MODE=1 ;;
        --yes|-y) AUTO_YES=1 ;;
        --backup) BACKUP_ONLY=1 ;;
        --backup-volumes) BACKUP_VOLUMES=1 ;;
        --no-backup) NO_BACKUP=1 ;;
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
        --lang)
            shift
            [[ $# -gt 0 ]] || { echo "--lang requires en or pt-BR" >&2; exit 2; }
            case "$1" in en) LANGUAGE="en" ;; pt-BR|pt_BR) LANGUAGE="pt_BR" ;; *) echo "Unsupported language: $1" >&2; exit 2 ;; esac
            ;;
        --version|-V) echo "${SCRIPT_NAME} v${SCRIPT_VERSION} (${SCRIPT_DATE})"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "$(msg unknown_option): $1" >&2; usage; exit 2 ;;
    esac
    shift
done

command -v docker >/dev/null 2>&1 || { msg no_docker; exit 2; }
docker info >/dev/null 2>&1 || { msg no_access; exit 2; }

get_label() {
    docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

get_image_label() {
    docker image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

short_image_id() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null | sed 's/^sha256://' | cut -c1-12
}

image_created_date() {
    docker image inspect --format '{{.Created}}' "$1" 2>/dev/null | cut -dT -f1
}

compose_command() {
    local container="$1"; shift
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
    local p s
    p=$(get_label "$1" "com.docker.compose.project")
    s=$(get_label "$1" "com.docker.compose.service")
    [[ -n "$p" && "$p" != "<no value>" && -n "$s" && "$s" != "<no value>" ]]
}

is_netbox_custom() {
    case "$1" in netbox-custom:*|*/netbox-custom:*) return 0 ;; *) return 1 ;; esac
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
    local image="$1" original app dockerver rel

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
        awk -F: '\''/^[[:space:]]*version:[[:space:]]*/ {gsub(/["[:space:]]/,"",$2); print $2; exit}'\'' "$f"
    ' 2>/dev/null || true)

    dockerver=$(docker run --rm --entrypoint sh "$image" -c '[ -f /opt/netbox/VERSION ] && tr -d "[:space:]" </opt/netbox/VERSION' 2>/dev/null || true)

    [[ -n "$app" || -n "$dockerver" ]] && printf '%s\t%s\n' "${app:-unknown}" "${dockerver:-unknown}"
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
    [[ -n "$workdir" && "$workdir" != "<no value>" && -f "$workdir/VERSION" ]] || return 1
    tr -d '[:space:]' < "$workdir/VERSION"
}

image_version() {
    local image="$1" ref="$2" v=""
    v=$(get_image_label "$image" "org.opencontainers.image.version")
    [[ "$v" == "<no value>" ]] && v=""

    if [[ -z "$v" && "$ref" == louislam/uptime-kuma:* ]]; then
        v=$(docker run --rm --entrypoint node "$image" -e 'try{console.log(require("/app/package.json").version)}catch(e){process.exit(1)}' 2>/dev/null || true)
    fi
    if [[ -z "$v" && "$ref" == portainer/portainer-ce:* ]]; then
        v=$(docker run --rm --entrypoint /portainer "$image" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
    [[ -n "$v" ]] || v="id:$(short_image_id "$image")"
    echo "$v"
}

ensure_backup_dir() {
    if [[ -z "$RUN_BACKUP_DIR" ]]; then
        RUN_BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$RUN_BACKUP_DIR"/{containers,images,compose,volumes,database}
        printf 'script_version=%s\ncreated=%s\nhost=%s\n' "$SCRIPT_VERSION" "$(date -Is)" "$(hostname -f 2>/dev/null || hostname)" > "$RUN_BACKUP_DIR/backup.info"
        printf 'container_name\tcontainer_id\timage_ref\timage_id\tproject\tservice\tworkdir\n' > "$RUN_BACKUP_DIR/manifest.tsv"
    fi
}

backup_compose_project() {
    local container="$1" project workdir config_files key file
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
    local image_id="$1" short
    [[ -n "${BACKED_UP_IMAGES[$image_id]+x}" ]] && return 0
    short="${image_id#sha256:}"
    short="${short:0:12}"
    echo "Saving image ${short} ..."
    docker image save -o "$RUN_BACKUP_DIR/images/${short}.tar" "$image_id" || return 1
    BACKED_UP_IMAGES[$image_id]=1
}

backup_named_volumes() {
    local container="$1" volume
    [[ $BACKUP_VOLUMES -eq 1 ]] || return 0

    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        [[ -n "${BACKED_UP_VOLUMES[$volume]+x}" ]] && continue
        BACKED_UP_VOLUMES[$volume]=1
        echo "Backing up volume ${volume} ..."
        docker run --rm -v "${volume}:/source:ro" -v "${RUN_BACKUP_DIR}/volumes:/backup" alpine:3.20 \
            tar -C /source -czf "/backup/${volume}.tar.gz" . || return 1
    done < <(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
}

backup_netbox_database() {
    local container="$1" project pg name
    project=$(get_label "$container" "com.docker.compose.project")
    [[ -n "$project" && "$project" != "<no value>" ]] || return 0

    name="$RUN_BACKUP_DIR/database/${project}-postgres.dump"
    [[ -f "$name" ]] && return 0

    pg=$(docker ps -q --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=postgres" | head -1)
    [[ -n "$pg" ]] || return 0

    echo "Creating NetBox PostgreSQL dump ..."
    docker exec "$pg" sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$name" || {
        rm -f "$name"
        return 1
    }
}

backup_container() {
    local container="$1" name image_ref image_id project service workdir
    ensure_backup_dir

    name=$(docker inspect --format '{{.Name}}' "$container" | sed 's#^/##')
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$container")
    image_id=$(docker inspect --format '{{.Image}}' "$container")
    project=$(get_label "$container" "com.docker.compose.project")
    service=$(get_label "$container" "com.docker.compose.service")
    workdir=$(get_label "$container" "com.docker.compose.project.working_dir")

    docker inspect "$container" > "$RUN_BACKUP_DIR/containers/${name}.inspect.json" || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$container" "$image_ref" "$image_id" "$project" "$service" "$workdir" >> "$RUN_BACKUP_DIR/manifest.tsv"

    backup_image "$image_id" || return 1
    is_compose_managed "$container" && backup_compose_project "$container"
    backup_named_volumes "$container" || return 1
    is_netbox_custom "$image_ref" && backup_netbox_database "$container" || true
}

rollback_from_backup() {
    local dir="$1" name cid image_ref image_id project service workdir tarfile
    [[ -f "$dir/manifest.tsv" ]] || { echo "Invalid backup: $dir" >&2; return 1; }

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
        (cd "$workdir" && docker compose -p "$project" up -d --no-deps "$service") || true
    done < "$dir/manifest.tsv"

    msg rollback_done
    msg rollback_data_warning
    [[ -d "$dir/database" ]] && echo "Database dumps, when available, are stored under: $dir/database"
}

confirm_update() {
    [[ $AUTO_YES -eq 1 ]] && return 0
    local answer
    printf '%s ' "$(msg update_question)"
    read -r answer
    case "$answer" in y|Y|yes|YES|s|S|sim|SIM) return 0 ;; *) return 1 ;; esac
}

if [[ -n "$ROLLBACK_DIR" ]]; then
    rollback_from_backup "$ROLLBACK_DIR"
    exit $?
fi

mapfile -t CONTAINERS < <(if [[ $ALL_CONTAINERS -eq 1 ]]; then docker ps -aq; else docker ps -q; fi)
[[ ${#CONTAINERS[@]} -gt 0 ]] || { msg no_containers; exit 0; }

if [[ $BACKUP_ONLY -eq 1 && $UPDATE_MODE -eq 0 ]]; then
    for c in "${CONTAINERS[@]}"; do
        backup_container "$c" || exit 1
    done
    echo "$(msg backup_created): $RUN_BACKUP_DIR"
    exit 0
fi

msg development
msg backup_warning

echo
printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "CONTAINER" "IMAGE" "INSTALLED" "AVAILABLE" "DATE" "STATUS"
printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "--------------------------------------" "----------------------------------" "------------------" "------------------" "------------" "------------------"

for c in "${CONTAINERS[@]}"; do
    name=$(docker inspect --format '{{.Name}}' "$c" | sed 's#^/##')
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$c")
    current_id=$(docker inspect --format '{{.Image}}' "$c")

    if is_netbox_custom "$image_ref"; then
        ((COUNT_NETBOX++)) || true

        current_pair=$(netbox_versions_from_image "$current_id" || true)
        current_app=$(printf '%s' "$current_pair" | cut -f1)
        current_support=$(printf '%s' "$current_pair" | cut -f2)
        [[ -n "$current_app" ]] || current_app="unknown"
        [[ -n "$current_support" ]] || current_support=$(netbox_checkout_version "$c" 2>/dev/null || true)

        series=$(netbox_series_from_custom_ref "$image_ref" 2>/dev/null || true)
        if [[ -z "$series" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_app" "-" "-" "LOCAL BUILD"
            ((COUNT_LOCAL++)) || true
            continue
        fi

        base_ref="docker.io/netboxcommunity/netbox:v${series}"
        if ! docker pull "$base_ref" >/dev/null 2>&1; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_app" "-" "-" "BASE PULL ERROR"
            ((COUNT_ERROR++)) || true
            continue
        fi

        base_id=$(docker image inspect --format '{{.Id}}' "$base_ref")
        available_pair=$(netbox_versions_from_image "$base_id" || true)
        available_app=$(printf '%s' "$available_pair" | cut -f1)
        available_support=$(printf '%s' "$available_pair" | cut -f2)
        date=$(image_created_date "$base_id")
        checkout_support=$(netbox_checkout_version "$c" 2>/dev/null || true)

        if [[ -n "$available_support" && -n "$checkout_support" && "$available_support" != "$checkout_support" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_app" "${available_app:-?}" "$date" "REPO ${available_support}"
            ((COUNT_UPDATE++)) || true
            ((COUNT_NETBOX_REPO++)) || true

            if [[ $UPDATE_MODE -eq 1 ]]; then
                echo "  -> $(msg netbox_repo)"
                echo "     current checkout: ${checkout_support}; required: ${available_support}"
                ((COUNT_SKIPPED++)) || true
            fi
            continue
        fi

        if [[ -n "$available_app" && "$current_app" == "$available_app" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_app" "$available_app" "$date" "LOCAL OK"
            ((COUNT_OK++)) || true
            continue
        fi

        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_app" "${available_app:-?}" "$date" "REBUILD"
        ((COUNT_UPDATE++)) || true

        if [[ $UPDATE_MODE -eq 1 ]]; then
            is_compose_managed "$c" || {
                echo "  -> $name: $(msg not_compose)"
                ((COUNT_SKIPPED++)) || true
                continue
            }

            service=$(get_label "$c" "com.docker.compose.service")
            project=$(get_label "$c" "com.docker.compose.project")
            key="${project}:${service}"
            [[ -n "${UPDATED_SERVICES[$key]+x}" ]] && continue

            confirm_update || { ((COUNT_SKIPPED++)) || true; continue; }

            if [[ $NO_BACKUP -eq 0 ]]; then
                backup_container "$c" || {
                    msg backup_failed
                    ((COUNT_ERROR++)) || true
                    continue
                }
            fi

            if compose_command "$c" build --pull "$service" && compose_command "$c" up -d --no-deps "$service"; then
                UPDATED_SERVICES[$key]=1
                ((COUNT_UPDATED++)) || true
                echo "  -> $name $(msg update_ok)"
            else
                ((COUNT_ERROR++)) || true
                msg update_failed
            fi
        fi
        continue
    fi

    current_version=$(image_version "$current_id" "$image_ref")

    if [[ "$image_ref" == *@sha256:* || "$image_ref" == sha256:* ]]; then
        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_version" "-" "-" "PINNED"
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
        digests=$(docker image inspect --format '{{join .RepoDigests ","}}' "$current_id" 2>/dev/null || true)

        if [[ -z "$digests" ]]; then
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_version" "-" "-" "LOCAL BUILD"
            ((COUNT_LOCAL++)) || true
        else
            printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_version" "-" "-" "PULL ERROR"
            ((COUNT_ERROR++)) || true
        fi
        continue
    fi

    new_id="${REMOTE_ID[$image_ref]}"
    new_version="${REMOTE_VERSION[$image_ref]}"
    date="${REMOTE_DATE[$image_ref]}"

    if [[ "$current_id" == "$new_id" ]]; then
        printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_version" "$new_version" "$date" "UP TO DATE"
        ((COUNT_OK++)) || true
        continue
    fi

    printf '%-38s %-34s %-18s %-18s %-12s %-18s\n' "$name" "$image_ref" "$current_version" "$new_version" "$date" "UPDATE"
    ((COUNT_UPDATE++)) || true

    [[ $UPDATE_MODE -eq 1 ]] || continue

    is_compose_managed "$c" || {
        echo "  -> $name: $(msg not_compose)"
        ((COUNT_SKIPPED++)) || true
        continue
    }

    service=$(get_label "$c" "com.docker.compose.service")
    project=$(get_label "$c" "com.docker.compose.project")
    key="${project}:${service}"
    [[ -n "${UPDATED_SERVICES[$key]+x}" ]] && continue

    confirm_update || { ((COUNT_SKIPPED++)) || true; continue; }

    if [[ $NO_BACKUP -eq 0 ]]; then
        backup_container "$c" || {
            msg backup_failed
            ((COUNT_ERROR++)) || true
            continue
        }
    fi

    if compose_command "$c" pull "$service" && compose_command "$c" up -d --no-deps "$service"; then
        UPDATED_SERVICES[$key]=1
        ((COUNT_UPDATED++)) || true
        echo "  -> $name $(msg update_ok)"
    else
        ((COUNT_ERROR++)) || true
        msg update_failed
    fi
done

echo
echo "========================================================================================================================"
if [[ "$LANGUAGE" == "pt_BR" ]]; then
    echo " RESUMO"
    echo "========================================================================================================================"
    echo "Atualizados                 : $COUNT_OK"
    echo "Atualizações encontradas    : $COUNT_UPDATE"
    echo "Atualizações realizadas     : $COUNT_UPDATED"
    echo "Atualizações ignoradas      : $COUNT_SKIPPED"
    echo "Imagens locais/build        : $COUNT_LOCAL"
    echo "Containers NetBox custom    : $COUNT_NETBOX"
    echo "NetBox requer update repo   : $COUNT_NETBOX_REPO"
    echo "Erros                       : $COUNT_ERROR"
else
    echo " SUMMARY"
    echo "========================================================================================================================"
    echo "Up to date                  : $COUNT_OK"
    echo "Updates found               : $COUNT_UPDATE"
    echo "Updates applied             : $COUNT_UPDATED"
    echo "Updates skipped             : $COUNT_SKIPPED"
    echo "Local/build images          : $COUNT_LOCAL"
    echo "NetBox custom containers    : $COUNT_NETBOX"
    echo "NetBox repo updates needed  : $COUNT_NETBOX_REPO"
    echo "Errors                      : $COUNT_ERROR"
fi

[[ -n "$RUN_BACKUP_DIR" ]] && echo "$(msg backup_created): $RUN_BACKUP_DIR"
