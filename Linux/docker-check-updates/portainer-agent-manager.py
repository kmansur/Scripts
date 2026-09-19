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


VERSION = "1.1.0"

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
            if item and (not item.startswith("/") or not _path_is_within(item, workdir)):
                raise PortainerError(
                    "Compose environment file outside the project working "
                    "directory is not auto-updated"
                )

    allowed_refs = {
        f"portainer/agent:{old_version}",
        f"docker.io/portainer/agent:{old_version}",
    }

    if current_ref not in allowed_refs:
        raise PortainerError(
            "Compose Agent must use a fixed version tag matching the installed "
            f"Agent version ({old_version}); found {current_ref or 'unknown'}"
        )

    return {
        "project": project,
        "service": service,
        "workdir": workdir,
        "config_files": config_files,
        "current_ref": current_ref,
    }


def build_compose_update_helper_script(
    metadata: dict[str, Any],
    old_version: str,
    target_version: str,
) -> str:
    project = str(metadata["project"])
    service = str(metadata["service"])
    workdir = str(metadata["workdir"])
    config_files = [str(item) for item in metadata["config_files"]]
    old_ref = str(metadata["current_ref"])

    prefix = "docker.io/" if old_ref.startswith("docker.io/") else ""
    target_ref = f"{prefix}portainer/agent:{target_version}"
    backup_suffix = f".dcu-backup-{time.strftime('%Y%m%d%H%M%S')}"

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
    source_files = " ".join(shlex.quote(item) for item in config_files)

    q = shlex.quote

    return f"""set -eu
PROJECT={q(project)}
SERVICE={q(service)}
WORKDIR={q(workdir)}
OLD_REF={q(old_ref)}
TARGET_REF={q(target_ref)}
BACKUP_SUFFIX={q(backup_suffix)}
SOURCE_FILES={q(source_files)}
COMPOSE={q(compose_command)}
CHANGED=0

restore_sources() {{
    for file in $SOURCE_FILES; do
        if [ -f "$file$BACKUP_SUFFIX" ]; then
            cp -a "$file$BACKUP_SUFFIX" "$file"
        fi
    done
}}

rollback() {{
    if [ "$CHANGED" -eq 1 ]; then
        restore_sources
        cd "$WORKDIR"
        sh -c "$COMPOSE up -d --no-deps --force-recreate $SERVICE" >/dev/null 2>&1 || true
    fi
}}

trap 'rollback; exit 90' INT TERM HUP

if ! docker compose version >/dev/null 2>&1; then
    apk add --no-cache docker-cli-compose >/tmp/dcu-compose-install.log 2>&1
fi

cd "$WORKDIR"

FOUND=0
for file in $SOURCE_FILES; do
    if grep -Fq "$OLD_REF" "$file"; then
        FOUND=1
    fi
done

if [ "$FOUND" -ne 1 ]; then
    echo "ERROR: exact Agent image reference was not found in Compose source files." >&2
    exit 30
fi

for file in $SOURCE_FILES; do
    cp -a "$file" "$file$BACKUP_SUFFIX"
    sed -i "s|$OLD_REF|$TARGET_REF|g" "$file"
done
CHANGED=1

if ! sh -c "$COMPOSE config --images" | grep -Fx "$TARGET_REF" >/dev/null; then
    echo "ERROR: Compose config does not resolve to $TARGET_REF after source update." >&2
    rollback
    exit 31
fi

sh -c "$COMPOSE pull $SERVICE"
sh -c "$COMPOSE up -d --no-deps --force-recreate $SERVICE"

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
    helper_script = build_compose_update_helper_script(
        metadata,
        old_version,
        target_version,
    )

    print("Management            : Docker Compose")
    print(f"Compose project       : {metadata['project']}")
    print(f"Compose service       : {metadata['service']}")
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
            "The remote helper automatically restores the Compose source files "
            "and recreates the previous Agent if no commit is received.",
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
    print(
        "Compose source backup(s) were retained on the remote host with "
        "a .dcu-backup-* suffix."
    )
    print(f"Backup metadata: {env_dir}")

    return True


def validate_standalone_agent(inspect: dict[str, Any]) -> None:
    config = inspect.get("Config") or {}
    host = inspect.get("HostConfig") or {}
    labels = config.get("Labels") or {}

    if labels.get("com.docker.compose.project"):
        raise PortainerError(
            "Agent is Docker Compose managed; update the Compose source instead"
        )

    if labels.get("com.docker.swarm.service.name"):
        raise PortainerError(
            "Agent is Docker Swarm managed; generic container recreation is unsafe"
        )

    binds = host.get("Binds") or []
    if not any(
        isinstance(bind, str)
        and bind.split(":", 1)[0] == "/var/run/docker.sock"
        for bind in binds
    ):
        raise PortainerError(
            "Agent does not use the standard /var/run/docker.sock bind"
        )

    if host.get("Mounts"):
        raise PortainerError(
            "Agent uses HostConfig.Mounts; this profile is not auto-updated"
        )

    network_mode = str(host.get("NetworkMode") or "default")
    if network_mode.startswith("container:"):
        raise PortainerError(
            "Agent uses container network mode; this profile is not auto-updated"
        )

    networks = ((inspect.get("NetworkSettings") or {}).get("Networks") or {})
    if len(networks) > 1:
        raise PortainerError(
            "Agent is attached to multiple Docker networks; automatic recreation is skipped"
        )


def build_docker_run_command(
    inspect: dict[str, Any],
    target_version: str,
) -> str:
    config = inspect.get("Config") or {}
    host = inspect.get("HostConfig") or {}
    name = str(inspect.get("Name") or "").lstrip("/")

    if not name:
        raise PortainerError("remote Agent container has no name")

    target_image = f"portainer/agent:{target_version}"
    args: list[str] = ["docker", "run", "-d", "--name", name]

    restart = host.get("RestartPolicy") or {}
    restart_name = str(restart.get("Name") or "")
    max_retry = int(restart.get("MaximumRetryCount") or 0)
    if restart_name:
        restart_value = restart_name
        if restart_name == "on-failure" and max_retry:
            restart_value = f"{restart_name}:{max_retry}"
        args.extend(["--restart", restart_value])

    if host.get("Privileged"):
        args.append("--privileged")
    if host.get("ReadonlyRootfs"):
        args.append("--read-only")

    user = str(config.get("User") or "")
    if user:
        args.extend(["--user", user])

    for bind in host.get("Binds") or []:
        args.extend(["-v", str(bind)])

    for env in config.get("Env") or []:
        args.extend(["-e", str(env)])

    for key, value in sorted((config.get("Labels") or {}).items()):
        args.extend(["--label", f"{key}={value}"])

    port_bindings = host.get("PortBindings") or {}
    for container_port, mappings in port_bindings.items():
        for mapping in mappings or []:
            mapping = mapping or {}
            host_ip = str(mapping.get("HostIp") or "")
            host_port = str(mapping.get("HostPort") or "")
            if not host_port:
                continue

            published = f"{host_port}:{container_port}"
            if host_ip and host_ip not in ("0.0.0.0", "::"):
                published = f"{host_ip}:{published}"

            args.extend(["-p", published])

    network_mode = str(host.get("NetworkMode") or "")
    if network_mode not in ("", "default", "bridge"):
        args.extend(["--network", network_mode])

    option_lists = (
        ("ExtraHosts", "--add-host"),
        ("CapAdd", "--cap-add"),
        ("CapDrop", "--cap-drop"),
        ("SecurityOpt", "--security-opt"),
        ("GroupAdd", "--group-add"),
        ("Dns", "--dns"),
        ("DnsSearch", "--dns-search"),
    )

    for key, flag in option_lists:
        for item in host.get(key) or []:
            args.extend([flag, str(item)])

    log_config = host.get("LogConfig") or {}
    log_type = str(log_config.get("Type") or "")
    if log_type and log_type != "json-file":
        args.extend(["--log-driver", log_type])

    for key, value in (log_config.get("Config") or {}).items():
        args.extend(["--log-opt", f"{key}={value}"])

    args.append(target_image)
    return " ".join(shlex.quote(part) for part in args)


def build_update_helper_script(
    inspect: dict[str, Any],
    target_version: str,
    backup_name: str,
) -> str:
    name = str(inspect.get("Name") or "").lstrip("/")
    run_command = build_docker_run_command(inspect, target_version)
    target_image = f"portainer/agent:{target_version}"

    q = shlex.quote

    return f"""set -eu
OLD_NAME={q(name)}
BACKUP_NAME={q(backup_name)}
TARGET_IMAGE={q(target_image)}

rollback() {{
    docker rm -f "$OLD_NAME" >/dev/null 2>&1 || true
    if docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
        docker rename "$BACKUP_NAME" "$OLD_NAME" >/dev/null 2>&1 || true
        docker start "$OLD_NAME" >/dev/null 2>&1 || true
    fi
}}

trap 'rollback; exit 90' INT TERM HUP

sleep 3

docker stop -t 30 "$OLD_NAME"
docker rename "$OLD_NAME" "$BACKUP_NAME"

if ! {run_command}; then
    rollback
    exit 20
fi

for i in $(seq 1 60); do
    if [ -f /tmp/dcu-commit ]; then
        exit 0
    fi

    if ! docker inspect -f '{{{{.State.Running}}}}' "$OLD_NAME" 2>/dev/null | grep -qx true; then
        rollback
        exit 21
    fi

    sleep 3
done

rollback
exit 22
"""


def create_remote_helper(
    client: PortainerClient,
    endpoint_id: int,
    helper_name: str,
    script: str,
    extra_binds: list[str] | None = None,
) -> str:
    binds = ["/var/run/docker.sock:/var/run/docker.sock"]
    binds.extend(extra_binds or [])

    payload = {
        "Image": "docker:cli",
        "Entrypoint": ["/bin/sh", "-c"],
        "Cmd": [script],
        "HostConfig": {
            "Binds": binds,
            "RestartPolicy": {"Name": "no"},
        },
    }

    response = client.post(
        docker_path(
            endpoint_id,
            f"/containers/create?name={urllib.parse.quote(helper_name, safe='')}",
        ),
        payload=payload,
    )

    helper_id = str((response or {}).get("Id") or "")
    if not helper_id:
        raise PortainerError("Docker API did not return the helper container ID")

    return helper_id


def start_remote_container(
    client: PortainerClient,
    endpoint_id: int,
    container_id: str,
) -> None:
    client.post(
        docker_path(endpoint_id, f"/containers/{container_id}/start"),
        raw=True,
    )


def exec_in_remote_container(
    client: PortainerClient,
    endpoint_id: int,
    container_id: str,
    command: list[str],
) -> None:
    response = client.post(
        docker_path(endpoint_id, f"/containers/{container_id}/exec"),
        payload={
            "AttachStdout": False,
            "AttachStderr": False,
            "Cmd": command,
        },
    )

    exec_id = str((response or {}).get("Id") or "")
    if not exec_id:
        raise PortainerError("Docker API did not return an exec ID")

    client.post(
        docker_path(endpoint_id, f"/exec/{exec_id}/start"),
        payload={"Detach": True, "Tty": False},
        raw=True,
    )


def get_endpoint_agent_version(
    client: PortainerClient,
    endpoint_id: int,
) -> tuple[int, str]:
    endpoint = client.get(f"/endpoints/{endpoint_id}") or {}
    status = int(endpoint.get("Status") or 0)
    agent = endpoint.get("Agent") or {}
    version = str(agent.get("Version") or "")
    return status, version


def update_standard_agent(
    client: PortainerClient,
    endpoint: dict[str, Any],
    target_version: str,
    backup_root: Path,
) -> bool:
    endpoint_id = int(endpoint["Id"])
    env_name = str(endpoint.get("Name") or f"environment-{endpoint_id}")
    endpoint_url = str(endpoint.get("URL") or "")
    old_version = str((endpoint.get("Agent") or {}).get("Version") or "unknown")

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    env_dir = backup_root / timestamp / "portainer" / f"{endpoint_id}-{safe_name(env_name)}"
    env_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(env_dir, 0o700)

    print()
    print(f"Portainer environment : {env_name}")
    print(f"Agent                 : {old_version} -> {target_version}")
    print(f"Environment URL       : {endpoint_url}")

    containers = client.get(
        docker_path(endpoint_id, "/containers/json?all=true")
    ) or []
    write_json(env_dir / "containers.json", containers)

    candidate = find_agent_container(containers)
    container_id = str(candidate.get("Id") or "")
    container_name = str((candidate.get("Names") or [""])[0]).lstrip("/")

    inspect = client.get(
        docker_path(endpoint_id, f"/containers/{container_id}/json")
    ) or {}
    write_json(env_dir / f"{safe_name(container_name)}.inspect.json", inspect)

    labels = (inspect.get("Config") or {}).get("Labels") or {}
    if labels.get("com.docker.compose.project"):
        return update_compose_agent(
            client,
            endpoint,
            inspect,
            env_dir,
            target_version,
        )

    validate_standalone_agent(inspect)

    backup_name = f"{container_name}-dcu-backup-{time.strftime('%Y%m%d%H%M%S')}"
    helper_script = build_update_helper_script(
        inspect,
        target_version,
        backup_name,
    )
    (env_dir / "helper-update.sh").write_text(
        helper_script,
        encoding="utf-8",
    )
    os.chmod(env_dir / "helper-update.sh", 0o600)

    metadata = {
        "endpoint_id": endpoint_id,
        "environment": env_name,
        "environment_url": endpoint_url,
        "container": container_name,
        "old_image": candidate.get("Image"),
        "old_version": old_version,
        "target_version": target_version,
        "backup_container": backup_name,
    }
    write_json(env_dir / "update.json", metadata)

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

    helper_name = f"dcu-portainer-agent-{endpoint_id}-{int(time.time())}"
    helper_id = create_remote_helper(
        client,
        endpoint_id,
        helper_name,
        helper_script,
    )

    print("Starting remote Agent update helper ...")
    start_remote_container(
        client,
        endpoint_id,
        helper_id,
    )

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
            "ERROR: target Agent did not reconnect before the safety timeout.",
            file=sys.stderr,
        )
        print(
            "The remote helper automatically rolls back if it does not receive "
            "a commit signal.",
            file=sys.stderr,
        )

        # Give the helper enough time to finish its automatic rollback.
        time.sleep(25)
        try:
            status, version = get_endpoint_agent_version(client, endpoint_id)
            if status == STATUS_UP and version == old_version:
                print(f"Rollback confirmed: {env_name} is back on Agent {old_version}.")
        except PortainerError:
            pass

        return False

    # Commit the replacement only after Portainer confirms the new Agent
    # version. If this exec fails, the helper times out and rolls back.
    exec_in_remote_container(
        client,
        endpoint_id,
        helper_id,
        ["sh", "-c", "touch /tmp/dcu-commit"],
    )

    # Give the helper time to observe the commit marker and exit normally.
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
        write_bytes(env_dir / "helper.log", logs or b"")
    except PortainerError:
        pass

    # Never force-remove a running helper: its TERM trap is intentionally a
    # rollback path. Only clean it up after it has exited normally.
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
            f"WARNING: update helper {helper_id[:12]} is still running; "
            "it was left in place for safety.",
            file=sys.stderr,
        )

    print(f"OK: {env_name} Agent is now {target_version}.")
    print(f"Previous Agent retained as stopped container: {backup_name}")
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
