#!/usr/bin/env bash
#
# docker-check-updates.sh
#
# Docker image update checker with optional Docker Compose updates,
# backups, rollback support and special handling for NetBox Docker.
#
# Version: 3.0.1
# Date:    2026-09-18
# License: MIT
#
# This project is under development. Use at your own risk.
# Always keep a tested backup of application data before updating containers.
#

set -u

SCRIPT_NAME="docker-check-updates.sh"
SCRIPT_VERSION="3.0.1"
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
  - Portainer remote-agent support is embedded in this single script and uses Python 3 plus an API token.
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


run_embedded_portainer_helper() {
    python3 - "$@" <<'PY_PORTAINER_HELPER'
#!/usr/bin/env python3
"""
Portainer remote Agent checker/updater for docker-check-updates.

This module uses only the Python standard library. It talks to the Portainer
HTTP API using an access token and uses Portainer as a gateway to the remote
Docker API.

Automatic updates are intentionally limited to conservative profiles:
- Portainer Agent on Docker environments (environment Type 2);
- one portainer/agent container;
- Docker Standalone containers with the standard Docker socket bind; or
- Docker Compose-managed Agents with a fixed version tag and readable Compose
  project metadata;
- never a Docker Swarm service.

For an update, a temporary docker:cli helper container is created on the remote
host. The helper performs the Agent replacement locally through the Docker
socket, so the operation can continue while the Portainer Agent connection is
temporarily unavailable. The previous Agent container is retained, stopped and
renamed, as a rollback point.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import ssl
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


VERSION = "1.2.0"

TYPE_DOCKER_AGENT = 2
TYPE_DOCKER_EDGE = 4
TYPE_K8S_AGENT = 6
TYPE_K8S_EDGE = 7
STATUS_UP = 1


class PortainerError(RuntimeError):
    pass


@dataclass
class Summary:
    outdated: int = 0
    updated: int = 0
    skipped: int = 0
    errors: int = 0


class PortainerClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        insecure: bool = False,
        timeout: int = 180,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token.strip()
        self.timeout = timeout
        self.context = ssl._create_unverified_context() if insecure else ssl.create_default_context()

    def request(
        self,
        method: str,
        path: str,
        payload: Any | None = None,
        raw: bool = False,
        timeout: int | None = None,
    ) -> Any:
        url = f"{self.base_url}/api{path}"
        data = None
        headers = {"X-API-Key": self.token}

        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(
            url,
            data=data,
            headers=headers,
            method=method,
        )

        try:
            with urllib.request.urlopen(
                request,
                context=self.context,
                timeout=timeout or self.timeout,
            ) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise PortainerError(
                f"{method} {path} returned HTTP {exc.code}: {body[:500]}"
            ) from exc
        except urllib.error.URLError as exc:
            raise PortainerError(f"{method} {path} failed: {exc}") from exc

        if raw:
            return body

        if not body:
            return None

        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise PortainerError(
                f"{method} {path} returned invalid JSON: "
                f"{body[:500].decode('utf-8', errors='replace')}"
            ) from exc

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def post(self, path: str, payload: Any | None = None, raw: bool = False) -> Any:
        return self.request("POST", path, payload=payload, raw=raw)

    def delete(self, path: str, raw: bool = False) -> Any:
        return self.request("DELETE", path, raw=raw)


def read_token(path: Path) -> str:
    if not path.is_file():
        raise PortainerError(f"Portainer token file not found: {path}")

    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        print(
            f"WARNING: token file mode is {mode:o}; 600 or 400 is recommended.",
            file=sys.stderr,
        )

    token = path.read_text(encoding="utf-8").strip()
    if not token:
        raise PortainerError(f"Portainer token file is empty: {path}")

    return token


def safe_name(value: str) -> str:
    result = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    return result or "environment"


def type_name(environment_type: int) -> str:
    return {
        TYPE_DOCKER_AGENT: "Docker Agent",
        TYPE_DOCKER_EDGE: "Docker Edge",
        TYPE_K8S_AGENT: "K8s Agent",
        TYPE_K8S_EDGE: "K8s Edge",
    }.get(environment_type, f"Type {environment_type}")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True),
        encoding="utf-8",
    )


def write_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value)


def docker_path(endpoint_id: int, suffix: str) -> str:
    return f"/endpoints/{endpoint_id}/docker{suffix}"


def pull_remote_image(
    client: PortainerClient,
    endpoint_id: int,
    repository: str,
    tag: str,
    output_path: Path,
) -> None:
    repository_encoded = urllib.parse.quote(repository, safe="")
    tag_encoded = urllib.parse.quote(tag, safe="")
    body = client.post(
        docker_path(
            endpoint_id,
            f"/images/create?fromImage={repository_encoded}&tag={tag_encoded}",
        ),
        raw=True,
    )
    write_bytes(output_path, body or b"")

    for line in (body or b"").decode("utf-8", errors="replace").splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if item.get("error") or item.get("errorDetail"):
            raise PortainerError(
                f"remote image pull failed for {repository}:{tag}: "
                f"{item.get('error') or item.get('errorDetail')}"
            )


def find_agent_container(containers: list[dict[str, Any]]) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []

    for container in containers:
        image = str(container.get("Image") or "")
        names = container.get("Names") or []
        image_match = image.startswith("portainer/agent:") or image.startswith(
            "docker.io/portainer/agent:"
        )
        name_match = any(
            "portainer_agent" in str(name) or "portainer-agent" in str(name)
            for name in names
        )
        if image_match or name_match:
            matches.append(container)

    if len(matches) != 1:
        raise PortainerError(
            f"expected exactly one Portainer Agent container; found {len(matches)}"
        )

    return matches[0]


def _path_is_within(path: str, root: str) -> bool:
    path = os.path.normpath(path)
    root = os.path.normpath(root)
    return path == root or path.startswith(root.rstrip("/") + "/")



def compose_agent_metadata(
    inspect: dict[str, Any],
    old_version: str,
) -> dict[str, Any]:
    config = inspect.get("Config") or {}
    labels = config.get("Labels") or {}

    project = str(labels.get("com.docker.compose.project") or "")
    service = str(labels.get("com.docker.compose.service") or "")
    workdir = str(labels.get("com.docker.compose.project.working_dir") or "")
    config_label = str(labels.get("com.docker.compose.project.config_files") or "")
    environment_file = str(
        labels.get("com.docker.compose.project.environment_file") or ""
    )
    current_ref = str(config.get("Image") or "")

    if not project:
        raise PortainerError("Compose project label is missing")
    if not service:
        raise PortainerError("Compose service label is missing")
    if not workdir or not workdir.startswith("/"):
        raise PortainerError("Compose working_dir label is missing or not absolute")
    if not config_label:
        raise PortainerError(
            "Compose config_files label is missing; automatic source update is unsafe"
        )

    config_files = [
        item.strip()
        for item in config_label.split(",")
        if item.strip()
    ]

    if not config_files:
        raise PortainerError("Compose config_files label is empty")

    for item in config_files:
        if not item.startswith("/") or not _path_is_within(item, workdir):
            raise PortainerError(
                "Compose configuration outside the project working directory "
                "is not auto-updated"
            )

    if environment_file:
        for item in environment_file.split(","):
            item = item.strip()
            if item and (
                not item.startswith("/")
                or not _path_is_within(item, workdir)
            ):
                raise PortainerError(
                    "Compose environment file outside the project working "
                    "directory is not auto-updated"
                )

    valid_prefixes = (
        "portainer/agent:",
        "docker.io/portainer/agent:",
    )
    if not current_ref.startswith(valid_prefixes):
        raise PortainerError(
            f"unexpected Portainer Agent image reference: {current_ref or 'unknown'}"
        )

    tag = current_ref.rsplit(":", 1)[-1]
    moving_tags = {"sts", "lts", "latest"}

    if tag in moving_tags:
        mode = "channel"
    else:
        mode = "fixed"
        allowed_refs = {
            f"portainer/agent:{old_version}",
            f"docker.io/portainer/agent:{old_version}",
        }
        if current_ref not in allowed_refs:
            raise PortainerError(
                "Compose Agent must use the installed fixed version tag or one "
                f"of sts/lts/latest; installed={old_version}, found={current_ref}"
            )

    return {
        "project": project,
        "service": service,
        "workdir": workdir,
        "config_files": config_files,
        "current_ref": current_ref,
        "tag": tag,
        "mode": mode,
    }



def build_compose_update_helper_script(
    metadata: dict[str, Any],
    old_image_id: str,
    old_version: str,
    target_version: str,
) -> str:
    project = str(metadata["project"])
    service = str(metadata["service"])
    workdir = str(metadata["workdir"])
    config_files = [str(item) for item in metadata["config_files"]]
    old_ref = str(metadata["current_ref"])
    mode = str(metadata["mode"])

    prefix = "docker.io/" if old_ref.startswith("docker.io/") else ""
    target_ref = (
        old_ref
        if mode == "channel"
        else f"{prefix}portainer/agent:{target_version}"
    )

    timestamp = time.strftime("%Y%m%d%H%M%S")
    backup_suffix = f".dcu-backup-{timestamp}"
    backup_tag = f"portainer/agent:dcu-backup-{old_version}-{timestamp}"

    compose_args = [
        "docker",
        "compose",
        "--project-directory",
        workdir,
        "-p",
        project,
    ]
    for config_file in config_files:
        compose_args.extend(["-f", config_file])

    compose_command = " ".join(shlex.quote(arg) for arg in compose_args)
    source_file_args = " ".join(shlex.quote(item) for item in config_files)

    q = shlex.quote

    if mode == "fixed":
        prepare = r'''
FOUND=0
for file in "$@"; do
    if grep -Fq "$OLD_REF" "$file"; then
        FOUND=1
    fi
done

if [ "$FOUND" -ne 1 ]; then
    echo "ERROR: exact Agent image reference was not found in Compose source files." >&2
    exit 30
fi

for file in "$@"; do
    cp -a "$file" "$file$BACKUP_SUFFIX"
    sed -i "s|$OLD_REF|$TARGET_REF|g" "$file"
done
CHANGED=1
'''
        restore = r'''
    if [ "$CHANGED" -eq 1 ]; then
        for file in "$@"; do
            if [ -f "$file$BACKUP_SUFFIX" ]; then
                cp -a "$file$BACKUP_SUFFIX" "$file"
            fi
        done
    fi
'''
    else:
        # sts/lts/latest are moving tags. Keep the Compose source unchanged.
        # Preserve the old image by ID and restore the moving tag on rollback.
        prepare = r'''
docker tag "$OLD_IMAGE_ID" "$BACKUP_TAG"
'''
        restore = r'''
    docker tag "$OLD_IMAGE_ID" "$OLD_REF" >/dev/null 2>&1 || true
'''

    return f"""set -eu
PROJECT={q(project)}
SERVICE={q(service)}
WORKDIR={q(workdir)}
OLD_REF={q(old_ref)}
TARGET_REF={q(target_ref)}
OLD_IMAGE_ID={q(old_image_id)}
BACKUP_TAG={q(backup_tag)}
BACKUP_SUFFIX={q(backup_suffix)}
COMPOSE={q(compose_command)}
CHANGED=0

set -- {source_file_args}

rollback() {{
{restore}
    cd "$WORKDIR"
    sh -c "$COMPOSE up -d --no-deps --force-recreate --pull never $SERVICE" >/dev/null 2>&1 || true
}}

trap 'rollback; exit 90' INT TERM HUP

if ! docker compose version >/dev/null 2>&1; then
    apk add --no-cache docker-cli-compose >/tmp/dcu-compose-install.log 2>&1
fi

cd "$WORKDIR"

{prepare}

if ! sh -c "$COMPOSE config --images" | grep -Fx "$TARGET_REF" >/dev/null; then
    echo "ERROR: Compose config does not resolve to $TARGET_REF." >&2
    rollback
    exit 31
fi

sh -c "$COMPOSE pull $SERVICE"
sh -c "$COMPOSE up -d --no-deps --force-recreate --pull never $SERVICE"

for i in $(seq 1 60); do
    if [ -f /tmp/dcu-commit ]; then
        exit 0
    fi

    CID=$(docker ps -q \
        --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.service=$SERVICE" | head -1)

    if [ -z "$CID" ] || \
       ! docker inspect -f '{{{{.State.Running}}}}' "$CID" 2>/dev/null | grep -qx true; then
        rollback
        exit 32
    fi

    sleep 3
done

rollback
exit 33
"""



def update_compose_agent(
    client: PortainerClient,
    endpoint: dict[str, Any],
    inspect: dict[str, Any],
    env_dir: Path,
    target_version: str,
) -> bool:
    endpoint_id = int(endpoint["Id"])
    env_name = str(endpoint.get("Name") or f"environment-{endpoint_id}")
    old_version = str((endpoint.get("Agent") or {}).get("Version") or "unknown")

    metadata = compose_agent_metadata(inspect, old_version)
    old_image_id = str(inspect.get("Image") or "")

    helper_script = build_compose_update_helper_script(
        metadata,
        old_image_id,
        old_version,
        target_version,
    )

    print("Management            : Docker Compose")
    print(f"Compose project       : {metadata['project']}")
    print(f"Compose service       : {metadata['service']}")
    print(
        f"Compose image         : {metadata['current_ref']} "
        f"({metadata['mode']})"
    )
    print(f"Compose working dir   : {metadata['workdir']}")

    write_json(
        env_dir / "compose-update.json",
        {
            "endpoint_id": endpoint_id,
            "environment": env_name,
            "old_version": old_version,
            "target_version": target_version,
            **metadata,
        },
    )

    (env_dir / "helper-compose-update.sh").write_text(
        helper_script,
        encoding="utf-8",
    )
    os.chmod(env_dir / "helper-compose-update.sh", 0o600)

    # Pull the exact server-matched Agent first as an availability check.
    print(f"Pre-pulling portainer/agent:{target_version} ...")
    pull_remote_image(
        client,
        endpoint_id,
        "portainer/agent",
        target_version,
        env_dir / "agent-pull.jsonl",
    )

    print("Pre-pulling docker:cli update helper ...")
    pull_remote_image(
        client,
        endpoint_id,
        "docker",
        "cli",
        env_dir / "helper-pull.jsonl",
    )

    helper_name = f"dcu-portainer-compose-agent-{endpoint_id}-{int(time.time())}"
    helper_id = create_remote_helper(
        client,
        endpoint_id,
        helper_name,
        helper_script,
        extra_binds=[
            f"{metadata['workdir']}:{metadata['workdir']}:rw",
        ],
    )

    print("Starting remote Docker Compose Agent update helper ...")
    start_remote_container(client, endpoint_id, helper_id)

    print(f"Waiting for {env_name} to reconnect with Agent {target_version} ...")

    deadline = time.time() + 165
    reconnected = False

    while time.time() < deadline:
        time.sleep(3)

        try:
            status, version = get_endpoint_agent_version(client, endpoint_id)
        except PortainerError:
            continue

        if status == STATUS_UP and version == target_version:
            reconnected = True
            break

    if not reconnected:
        print(
            "ERROR: target Compose Agent did not reconnect before the safety timeout.",
            file=sys.stderr,
        )
        print(
            "The remote helper automatically restores the previous Compose/image "
            "state when no commit is received.",
            file=sys.stderr,
        )

        time.sleep(25)
        try:
            status, version = get_endpoint_agent_version(client, endpoint_id)
            if status == STATUS_UP and version == old_version:
                print(
                    f"Rollback confirmed: {env_name} is back on Agent {old_version}."
                )
        except PortainerError:
            pass

        return False

    exec_in_remote_container(
        client,
        endpoint_id,
        helper_id,
        ["sh", "-c", "touch /tmp/dcu-commit"],
    )

    helper_running = True
    for _ in range(15):
        time.sleep(1)
        try:
            helper_inspect = client.get(
                docker_path(endpoint_id, f"/containers/{helper_id}/json")
            ) or {}
        except PortainerError:
            break

        helper_running = bool(
            (helper_inspect.get("State") or {}).get("Running")
        )
        if not helper_running:
            break

    try:
        logs = client.request(
            "GET",
            docker_path(
                endpoint_id,
                f"/containers/{helper_id}/logs?"
                "stdout=true&stderr=true&timestamps=true",
            ),
            raw=True,
        )
        write_bytes(env_dir / "helper-compose.log", logs or b"")
    except PortainerError:
        pass

    if not helper_running:
        try:
            client.delete(
                docker_path(endpoint_id, f"/containers/{helper_id}?force=false"),
                raw=True,
            )
        except PortainerError:
            pass
    else:
        print(
            f"WARNING: Compose update helper {helper_id[:12]} is still running; "
            "it was left in place for safety.",
            file=sys.stderr,
        )

    print(f"OK: {env_name} Compose Agent is now {target_version}.")

    if metadata["mode"] == "fixed":
        print(
            "Compose source backup(s) were retained on the remote host "
            "with a .dcu-backup-* suffix."
        )
    else:
        print(
            "The moving Compose tag was preserved and the previous Agent image "
            "was retained with a dcu-backup-* image tag."
        )

    print(f"Backup metadata: {env_dir}")
    return True


def confirm_update(name: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True

    answer = input(f"Update Portainer Agent on {name}? [y/N]: ").strip().lower()
    return answer in {"y", "yes"}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check and optionally update Portainer remote Agents."
    )
    parser.add_argument("--url", required=True, help="Portainer base URL")
    parser.add_argument("--token-file", required=True, help="Portainer API token file")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification")
    parser.add_argument("--update", action="store_true", help="Update supported Agents")
    parser.add_argument("--yes", action="store_true", help="Do not ask for confirmation")
    parser.add_argument(
        "--backup-root",
        default="/var/backups/docker-check-updates",
        help="Root directory for Agent update metadata",
    )
    parser.add_argument("--summary-file", help="Write machine-readable summary JSON")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = parser.parse_args()

    summary = Summary()

    try:
        token = read_token(Path(args.token_file))
        client = PortainerClient(
            args.url,
            token,
            insecure=args.insecure,
        )

        status = client.get("/system/status") or {}
        server_version = str(status.get("Version") or "").lstrip("v")

        if not server_version:
            raise PortainerError("Portainer Server version is unavailable")

        endpoints = client.get("/endpoints?outdated=true") or []

        print()
        print("=" * 120)
        print(" PORTAINER REMOTE AGENTS")
        print("=" * 120)
        print(f"Portainer API : {args.url}")
        print(f"Server        : {server_version}")
        print()
        print(
            f"{'ENVIRONMENT':30} {'TYPE':16} {'INSTALLED':14} "
            f"{'REQUIRED':14} {'STATUS':18}"
        )
        print(
            f"{'-' * 30} {'-' * 16} {'-' * 14} "
            f"{'-' * 14} {'-' * 18}"
        )

        for endpoint in endpoints:
            endpoint_id = int(endpoint.get("Id") or 0)
            name = str(endpoint.get("Name") or f"environment-{endpoint_id}")
            environment_type = int(endpoint.get("Type") or 0)
            environment_status = int(endpoint.get("Status") or 0)
            agent_version = str((endpoint.get("Agent") or {}).get("Version") or "")

            summary.outdated += 1

            if environment_type == TYPE_DOCKER_AGENT:
                if environment_status == STATUS_UP:
                    result = "UPDATE"
                else:
                    result = "DOWN"
                    summary.skipped += 1
            elif environment_type == TYPE_DOCKER_EDGE:
                result = "EDGE MANUAL"
                summary.skipped += 1
            elif environment_type in (TYPE_K8S_AGENT, TYPE_K8S_EDGE):
                result = "K8S MANUAL"
                summary.skipped += 1
            else:
                result = "UNSUPPORTED"
                summary.skipped += 1

            print(
                f"{name[:30]:30} "
                f"{type_name(environment_type)[:16]:16} "
                f"{(agent_version or 'unknown')[:14]:14} "
                f"{server_version[:14]:14} "
                f"{result[:18]:18}"
            )

            if not args.update:
                continue

            if environment_type != TYPE_DOCKER_AGENT or environment_status != STATUS_UP:
                continue

            if not confirm_update(name, args.yes):
                summary.skipped += 1
                continue

            try:
                if update_standard_agent(
                    client,
                    endpoint,
                    server_version,
                    Path(args.backup_root),
                ):
                    summary.updated += 1
                else:
                    summary.errors += 1
            except PortainerError as exc:
                print(f"SKIPPED: {name}: {exc}", file=sys.stderr)
                summary.skipped += 1
            except Exception as exc:  # defensive: never hide a failed update
                print(f"ERROR: {name}: {exc}", file=sys.stderr)
                summary.errors += 1

        if not endpoints:
            print("No outdated Portainer Agents reported.")

    except PortainerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        summary.errors += 1

    if args.summary_file:
        write_json(
            Path(args.summary_file),
            {
                "outdated": summary.outdated,
                "updated": summary.updated,
                "skipped": summary.skipped,
                "errors": summary.errors,
            },
        )

    return 1 if summary.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

PY_PORTAINER_HELPER
}

run_portainer_remote_agent_check() {
    local summary_file rc
    local outdated=0 updated=0 skipped=0 errors=0

    [[ $PORTAINER_ENABLED -eq 1 ]] || return 0
    detect_portainer_url || return 0

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
        --url "$PORTAINER_URL"
        --token-file "$PORTAINER_TOKEN_FILE"
        --backup-root "$BACKUP_ROOT"
        --summary-file "$summary_file"
    )

    [[ "$PORTAINER_INSECURE" == "1" ]] && args+=(--insecure)
    [[ $UPDATE_MODE -eq 1 ]] && args+=(--update)
    [[ $AUTO_YES -eq 1 ]] && args+=(--yes)

    run_embedded_portainer_helper "${args[@]}"
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
