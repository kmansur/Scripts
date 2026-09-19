#!/usr/bin/env python3
"""
docker-check-updates.py

Docker/Compose update checker with backup, rollback, NetBox Docker support,
and Portainer remote Agent management.

Version: 4.0.0
Date:    2026-09-19
License: MIT

This project is under development. Use at your own risk.
Always keep tested application/data backups before applying updates.

Design:
    discover -> analyze -> plan -> backup -> execute -> validate

Runtime dependencies:
    - Python 3.9+ (standard library only)
    - Docker Engine CLI
    - Docker Compose plugin for Compose update operations
    - Git only for automatic netbox-docker repository updates
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shlex
import shutil
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


SCRIPT_NAME = "docker-check-updates.py"
SCRIPT_VERSION = "4.0.0"
SCRIPT_DATE = "2026-09-19"

DEFAULT_BACKUP_ROOT = Path("/var/backups/docker-check-updates")
DEFAULT_PORTAINER_TOKEN = Path("/etc/docker-check-updates/portainer-api-token")

PORTAINER_TYPE_DOCKER_AGENT = 2
PORTAINER_TYPE_DOCKER_EDGE = 4
PORTAINER_TYPE_K8S_AGENT = 6
PORTAINER_TYPE_K8S_EDGE = 7
PORTAINER_STATUS_UP = 1

MOVING_AGENT_TAGS = {"sts", "lts", "latest"}


class AppError(RuntimeError):
    """Base application error."""


class CommandError(AppError):
    """A local command failed."""


class PortainerError(AppError):
    """A Portainer API operation failed."""


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def safe_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    return cleaned or "item"


def short_image_id(image_id: str) -> str:
    value = image_id.replace("sha256:", "")
    return value[:12]


def human_bool(value: bool) -> str:
    return "yes" if value else "no"


def decode_docker_stream(data: bytes) -> str:
    """Decode Docker's multiplexed stdout/stderr stream when present."""
    if not data:
        return ""

    chunks: List[bytes] = []
    offset = 0
    framed = False

    while offset + 8 <= len(data):
        header = data[offset : offset + 8]

        if header[1:4] != b"\x00\x00\x00":
            break

        size = int.from_bytes(header[4:8], byteorder="big")
        end = offset + 8 + size

        if end > len(data):
            break

        framed = True
        chunks.append(data[offset + 8 : end])
        offset = end

    if framed and offset == len(data):
        payload = b"".join(chunks)
    else:
        payload = data

    return payload.decode("utf-8", errors="replace")


def safe_extract_tar(tar: tarfile.TarFile, destination: Path) -> None:
    """Extract a trusted backup only when every member stays inside destination."""
    root = destination.resolve()

    for member in tar.getmembers():
        member_path = (root / member.name).resolve()

        if member_path != root and root not in member_path.parents:
            raise AppError(
                f"unsafe path in backup archive: {member.name}"
            )

        if member.issym() or member.islnk():
            link_name = Path(member.linkname)
            if link_name.is_absolute():
                link_target = link_name.resolve()
            else:
                link_target = (member_path.parent / link_name).resolve()

            if link_target != root and root not in link_target.parents:
                raise AppError(
                    f"unsafe link in backup archive: {member.name} -> "
                    f"{member.linkname}"
                )

    tar.extractall(root)


@dataclass
class Config:
    all_containers: bool = False
    update: bool = False
    assume_yes: bool = False
    backup_only: bool = False
    backup_volumes: bool = False
    no_backup: bool = False
    rollback_dir: Optional[Path] = None
    backup_root: Path = DEFAULT_BACKUP_ROOT
    portainer_enabled: bool = True
    portainer_url: str = ""
    portainer_token_file: Path = DEFAULT_PORTAINER_TOKEN
    portainer_insecure: Optional[bool] = None
    dry_run: bool = False
    verbose: bool = False
    json_output: bool = False


@dataclass
class Summary:
    up_to_date: int = 0
    updates_found: int = 0
    updates_applied: int = 0
    updates_skipped: int = 0
    local_builds: int = 0
    netbox_custom: int = 0
    netbox_repo_updates: int = 0
    portainer_outdated: int = 0
    portainer_updated: int = 0
    portainer_skipped: int = 0
    errors: int = 0


@dataclass
class ComposeProject:
    project: str
    service: str
    workdir: Path
    config_files: List[Path] = field(default_factory=list)

    @classmethod
    def from_inspect(cls, inspect: Dict[str, Any]) -> Optional["ComposeProject"]:
        labels = ((inspect.get("Config") or {}).get("Labels") or {})
        project = str(labels.get("com.docker.compose.project") or "")
        service = str(labels.get("com.docker.compose.service") or "")
        workdir_text = str(labels.get("com.docker.compose.project.working_dir") or "")
        config_text = str(labels.get("com.docker.compose.project.config_files") or "")

        if not project or not service or not workdir_text:
            return None

        workdir = Path(workdir_text)
        config_files = [
            Path(item.strip())
            for item in config_text.split(",")
            if item.strip()
        ]

        return cls(
            project=project,
            service=service,
            workdir=workdir,
            config_files=config_files,
        )

    def command(self, *args: str) -> List[str]:
        cmd = [
            "docker",
            "compose",
            "--project-directory",
            str(self.workdir),
            "-p",
            self.project,
        ]
        for config_file in self.config_files:
            if config_file.is_file():
                cmd.extend(["-f", str(config_file)])
        cmd.extend(args)
        return cmd


@dataclass
class ContainerRecord:
    container_id: str
    name: str
    running: bool
    image_ref: str
    current_image_id: str
    installed: str
    available: str = "-"
    date: str = "-"
    status: str = ""
    compose: Optional[ComposeProject] = None
    details: Dict[str, Any] = field(default_factory=dict)


@dataclass
class UpdatePlan:
    kind: str
    key: str
    description: str
    container_id: str
    project: Optional[ComposeProject] = None
    data: Dict[str, Any] = field(default_factory=dict)
    count: int = 1


@dataclass
class RemoteImage:
    image_id: str
    version: str
    created: str


class Runner:
    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose

    def _show(self, args: Sequence[str], cwd: Optional[Path]) -> None:
        if not self.verbose:
            return
        prefix = f"[{cwd}] " if cwd else ""
        print(f"+ {prefix}{shlex.join([str(x) for x in args])}", file=sys.stderr)

    def run(
        self,
        args: Sequence[str],
        *,
        cwd: Optional[Path] = None,
        env: Optional[Dict[str, str]] = None,
        check: bool = True,
        capture: bool = True,
        text: bool = True,
        stdout: Any = None,
        stderr: Any = None,
        timeout: Optional[int] = None,
    ) -> subprocess.CompletedProcess:
        cmd = [str(x) for x in args]
        self._show(cmd, cwd)

        if capture and stdout is None:
            stdout = subprocess.PIPE
        if capture and stderr is None:
            stderr = subprocess.PIPE

        result = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            env=env,
            check=False,
            stdout=stdout,
            stderr=stderr,
            text=text,
            timeout=timeout,
        )

        if check and result.returncode != 0:
            err = ""
            if isinstance(result.stderr, str):
                err = result.stderr.strip()
            raise CommandError(
                f"command failed ({result.returncode}): {shlex.join(cmd)}"
                + (f"\n{err}" if err else "")
            )

        return result

    def output(
        self,
        args: Sequence[str],
        *,
        cwd: Optional[Path] = None,
        env: Optional[Dict[str, str]] = None,
        check: bool = True,
        timeout: Optional[int] = None,
    ) -> str:
        result = self.run(
            args,
            cwd=cwd,
            env=env,
            check=check,
            capture=True,
            text=True,
            timeout=timeout,
        )
        return (result.stdout or "").strip()


class DockerClient:
    def __init__(self, runner: Runner) -> None:
        self.runner = runner
        self._inspect_cache: Dict[str, Dict[str, Any]] = {}
        self._image_cache: Dict[str, Dict[str, Any]] = {}

    def validate(self) -> None:
        if shutil.which("docker") is None:
            raise AppError("docker command not found")
        self.runner.run(["docker", "info"], check=True)

    def ps(self, include_stopped: bool = False) -> List[str]:
        args = ["docker", "ps", "-q"]
        if include_stopped:
            args = ["docker", "ps", "-aq"]
        output = self.runner.output(args)
        return [line.strip() for line in output.splitlines() if line.strip()]

    def inspect(self, target: str, refresh: bool = False) -> Dict[str, Any]:
        if not refresh and target in self._inspect_cache:
            return self._inspect_cache[target]
        output = self.runner.output(["docker", "inspect", target])
        data = json.loads(output)
        if not data:
            raise AppError(f"docker inspect returned no data for {target}")
        value = data[0]
        self._inspect_cache[target] = value
        return value

    def image_inspect(self, image: str, refresh: bool = False) -> Dict[str, Any]:
        if not refresh and image in self._image_cache:
            return self._image_cache[image]
        output = self.runner.output(["docker", "image", "inspect", image])
        data = json.loads(output)
        if not data:
            raise AppError(f"docker image inspect returned no data for {image}")
        value = data[0]
        self._image_cache[image] = value
        return value

    def invalidate(self) -> None:
        self._inspect_cache.clear()
        self._image_cache.clear()

    def pull(self, image: str) -> Tuple[bool, str]:
        result = self.runner.run(
            ["docker", "pull", image],
            check=False,
            capture=True,
            text=True,
        )
        output = "\n".join(
            part for part in ((result.stdout or ""), (result.stderr or "")) if part
        ).strip()
        self._image_cache.pop(image, None)
        return result.returncode == 0, output

    def image_save(self, image_id: str, output: Path) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        self.runner.run(
            ["docker", "image", "save", "-o", str(output), image_id],
            check=True,
        )

    def image_load(self, source: Path) -> None:
        self.runner.run(["docker", "image", "load", "-i", str(source)], check=True)

    def tag(self, image_id: str, image_ref: str) -> None:
        self.runner.run(["docker", "tag", image_id, image_ref], check=True)

    def port(self, container_id: str, port: str) -> str:
        return self.runner.output(
            ["docker", "port", container_id, port],
            check=False,
        )

    def logs(self, container_id: str, tail: int = 500) -> str:
        return self.runner.output(
            ["docker", "logs", "--timestamps", "--tail", str(tail), container_id],
            check=False,
        )

    def exec_bytes(self, container_id: str, args: Sequence[str]) -> bytes:
        result = self.runner.run(
            ["docker", "exec", container_id, *args],
            check=False,
            capture=False,
            text=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            err = (result.stderr or b"").decode("utf-8", errors="replace")
            raise CommandError(f"docker exec failed: {err.strip()}")
        return result.stdout or b""

    def run_ephemeral(self, image: str, args: Sequence[str]) -> str:
        return self.runner.output(
            ["docker", "run", "--rm", *args, image],
            check=False,
        )


class VersionInspector:
    def __init__(self, docker: DockerClient, runner: Runner) -> None:
        self.docker = docker
        self.runner = runner
        self.cache: Dict[Tuple[str, str], str] = {}
        self.netbox_cache: Dict[str, Tuple[str, str]] = {}

    @staticmethod
    def labels(image_data: Dict[str, Any]) -> Dict[str, str]:
        return ((image_data.get("Config") or {}).get("Labels") or {})

    def image_version(self, image: str, image_ref: str) -> str:
        key = (image, image_ref)
        if key in self.cache:
            return self.cache[key]

        try:
            data = self.docker.image_inspect(image)
        except AppError:
            value = "unknown"
            self.cache[key] = value
            return value

        labels = self.labels(data)
        for label in (
            "org.opencontainers.image.version",
            "version",
            "org.label-schema.version",
            "build_version",
        ):
            value = str(labels.get(label) or "").strip()
            if value and value != "<no value>":
                self.cache[key] = value
                return value

        value = ""

        if image_ref.startswith("louislam/uptime-kuma:") or image_ref.startswith(
            "docker.io/louislam/uptime-kuma:"
        ):
            value = self.runner.output(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--entrypoint",
                    "node",
                    image,
                    "-e",
                    'try{console.log(require("/app/package.json").version)}catch(e){process.exit(1)}',
                ],
                check=False,
            ).strip()

        elif image_ref.startswith("portainer/portainer-ce:") or image_ref.startswith(
            "docker.io/portainer/portainer-ce:"
        ):
            output = self.runner.output(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--entrypoint",
                    "/portainer",
                    image,
                    "--version",
                ],
                check=False,
            )
            match = re.search(r"\d+\.\d+\.\d+", output)
            if match:
                value = match.group(0)

        if not value:
            image_id = str(data.get("Id") or image)
            value = f"id:{short_image_id(image_id)}"

        self.cache[key] = value
        return value

    def image_created(self, image: str) -> str:
        try:
            created = str(self.docker.image_inspect(image).get("Created") or "")
        except AppError:
            return "-"
        return created.split("T", 1)[0] if created else "-"

    @staticmethod
    def parse_netbox_tag(tag: str) -> Optional[Tuple[str, str]]:
        value = tag.lstrip("v")
        match = re.match(
            r"^(\d+\.\d+(?:\.\d+)?)-(\d+\.\d+\.\d+)$",
            value,
        )
        if not match:
            return None
        return match.group(1), match.group(2)

    def netbox_versions(self, image: str) -> Tuple[str, str]:
        if image in self.netbox_cache:
            return self.netbox_cache[image]

        app = ""
        support = ""

        try:
            data = self.docker.image_inspect(image)
            labels = self.labels(data)
            original_tag = str(labels.get("netbox.original-tag") or "")
            if original_tag:
                parsed = self.parse_netbox_tag(original_tag.rsplit(":", 1)[-1])
                if parsed:
                    app, support = parsed
        except AppError:
            pass

        if not app:
            app = self.runner.output(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--entrypoint",
                    "sh",
                    image,
                    "-c",
                    (
                        "f=/opt/netbox/netbox/netbox/release.yaml; "
                        "[ -f \"$f\" ] || exit 0; "
                        "awk -F: '/^[[:space:]]*version:[[:space:]]*/ "
                        "{gsub(/[\"[:space:]]/,\"\",$2); print $2; exit}' \"$f\""
                    ),
                ],
                check=False,
            ).strip()

        if not support:
            support = self.runner.output(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--entrypoint",
                    "sh",
                    image,
                    "-c",
                    '[ -f /opt/netbox/VERSION ] && tr -d "[:space:]" </opt/netbox/VERSION',
                ],
                check=False,
            ).strip()

        result = (app or "unknown", support or "unknown")
        self.netbox_cache[image] = result
        return result


class BackupManager:
    def __init__(
        self,
        config: Config,
        docker: DockerClient,
        runner: Runner,
    ) -> None:
        self.config = config
        self.docker = docker
        self.runner = runner
        self.run_dir: Optional[Path] = None
        self.saved_images: Set[str] = set()
        self.saved_projects: Set[str] = set()
        self.saved_volumes: Set[str] = set()
        self.manifest: List[Dict[str, Any]] = []

    def ensure(self) -> Path:
        if self.run_dir is not None:
            return self.run_dir

        root = self.config.backup_root
        root.mkdir(parents=True, exist_ok=True)
        try:
            root.chmod(0o700)
        except PermissionError:
            pass

        run_dir = root / timestamp()
        for name in (
            "containers",
            "images",
            "compose",
            "volumes",
            "database",
            "diagnostics",
            "portainer",
        ):
            (run_dir / name).mkdir(parents=True, exist_ok=True)

        try:
            run_dir.chmod(0o700)
        except PermissionError:
            pass

        info = {
            "script": SCRIPT_NAME,
            "version": SCRIPT_VERSION,
            "created": now_iso(),
            "host": os.uname().nodename,
        }
        (run_dir / "backup.json").write_text(
            json.dumps(info, indent=2),
            encoding="utf-8",
        )

        self.run_dir = run_dir
        return run_dir

    def finalize(self) -> None:
        if self.run_dir is None:
            return
        (self.run_dir / "manifest.json").write_text(
            json.dumps(self.manifest, indent=2, sort_keys=True),
            encoding="utf-8",
        )

    def backup_image(self, image_id: str) -> None:
        if image_id in self.saved_images:
            return
        directory = self.ensure() / "images"
        output = directory / f"{short_image_id(image_id)}.tar"
        print(f"Saving image {short_image_id(image_id)} ...")
        self.docker.image_save(image_id, output)
        self.saved_images.add(image_id)

    def backup_compose_project(self, compose: ComposeProject) -> None:
        key = f"{compose.project}:{compose.workdir}"
        if key in self.saved_projects:
            return
        self.saved_projects.add(key)

        destination = self.ensure() / "compose" / safe_name(compose.project)
        destination.mkdir(parents=True, exist_ok=True)

        metadata = {
            "project": compose.project,
            "workdir": str(compose.workdir),
            "config_files": [str(x) for x in compose.config_files],
        }
        (destination / "compose.json").write_text(
            json.dumps(metadata, indent=2),
            encoding="utf-8",
        )

        candidates: List[Path] = list(compose.config_files)
        candidates.extend([compose.workdir / ".env", compose.workdir / "VERSION"])

        for source in candidates:
            if not source.is_file():
                continue

            if source.is_relative_to(compose.workdir):
                relative = source.relative_to(compose.workdir)
            else:
                relative = Path(source.name)

            target = destination / "files" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    def backup_named_volumes(self, inspect: Dict[str, Any]) -> None:
        if not self.config.backup_volumes:
            return

        for mount in inspect.get("Mounts") or []:
            if mount.get("Type") != "volume":
                continue
            volume = str(mount.get("Name") or "")
            if not volume or volume in self.saved_volumes:
                continue

            self.saved_volumes.add(volume)
            destination = self.ensure() / "volumes"
            print(f"Backing up volume {volume} ...")
            self.runner.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{volume}:/source:ro",
                    "-v",
                    f"{destination}:/backup",
                    "alpine:3.20",
                    "tar",
                    "-C",
                    "/source",
                    "-czf",
                    f"/backup/{safe_name(volume)}.tar.gz",
                    ".",
                ],
                check=True,
            )

    def backup_netbox_database(self, project: str) -> None:
        dump = self.ensure() / "database" / f"{safe_name(project)}-postgres.dump"
        if dump.exists():
            return

        pg_id = self.runner.output(
            [
                "docker",
                "ps",
                "-q",
                "--filter",
                f"label=com.docker.compose.project={project}",
                "--filter",
                "label=com.docker.compose.service=postgres",
            ],
            check=False,
        ).splitlines()

        if not pg_id:
            raise AppError(
                f"PostgreSQL container not found for NetBox project {project}"
            )

        container_id = pg_id[0].strip()
        print("Creating NetBox PostgreSQL dump ...")

        with dump.open("wb") as handle:
            result = self.runner.run(
                [
                    "docker",
                    "exec",
                    container_id,
                    "sh",
                    "-c",
                    'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc',
                ],
                check=False,
                capture=False,
                text=False,
                stdout=handle,
                stderr=subprocess.PIPE,
            )

        if result.returncode != 0:
            dump.unlink(missing_ok=True)
            err = (result.stderr or b"").decode("utf-8", errors="replace")
            raise AppError(f"NetBox PostgreSQL dump failed: {err.strip()}")

    def backup_container(
        self,
        inspect: Dict[str, Any],
        *,
        netbox_custom: bool = False,
    ) -> None:
        run_dir = self.ensure()
        name = str(inspect.get("Name") or "").lstrip("/")
        container_id = str(inspect.get("Id") or "")
        image_id = str(inspect.get("Image") or "")
        image_ref = str((inspect.get("Config") or {}).get("Image") or "")
        compose = ComposeProject.from_inspect(inspect)

        (run_dir / "containers" / f"{safe_name(name)}.json").write_text(
            json.dumps(inspect, indent=2),
            encoding="utf-8",
        )

        entry = {
            "name": name,
            "container_id": container_id,
            "image_ref": image_ref,
            "image_id": image_id,
            "compose": None,
        }

        if compose:
            entry["compose"] = {
                "project": compose.project,
                "service": compose.service,
                "workdir": str(compose.workdir),
                "config_files": [str(x) for x in compose.config_files],
            }
            self.backup_compose_project(compose)

        self.manifest.append(entry)
        self.backup_image(image_id)
        self.backup_named_volumes(inspect)

        if netbox_custom and compose:
            self.backup_netbox_database(compose.project)

    def backup_netbox_workdir(self, compose: ComposeProject) -> None:
        if shutil.which("git") is None:
            raise AppError("git is required for NetBox repository updates")
        if not (compose.workdir / ".git").is_dir():
            raise AppError(
                f"NetBox working directory is not a Git checkout: {compose.workdir}"
            )

        directory = self.ensure() / "compose" / safe_name(compose.project)
        directory.mkdir(parents=True, exist_ok=True)

        commit = self.runner.output(
            ["git", "-C", str(compose.workdir), "rev-parse", "HEAD"]
        )
        ref = self.runner.output(
            ["git", "-C", str(compose.workdir), "symbolic-ref", "--short", "-q", "HEAD"],
            check=False,
        )
        if not ref:
            ref = self.runner.output(
                [
                    "git",
                    "-C",
                    str(compose.workdir),
                    "describe",
                    "--tags",
                    "--exact-match",
                ],
                check=False,
            ) or "detached"

        state = {
            "project": compose.project,
            "workdir": str(compose.workdir),
            "commit": commit,
            "ref": ref,
        }
        (directory / "netbox-repo.json").write_text(
            json.dumps(state, indent=2),
            encoding="utf-8",
        )

        status_text = self.runner.output(
            ["git", "-C", str(compose.workdir), "status", "--porcelain=v1"],
            check=False,
        )
        (directory / "git-status-before-update.txt").write_text(
            status_text + ("\n" if status_text else ""),
            encoding="utf-8",
        )

        diff_text = self.runner.output(
            ["git", "-C", str(compose.workdir), "diff", "--binary", "HEAD"],
            check=False,
        )
        (directory / "local-changes.patch").write_text(
            diff_text,
            encoding="utf-8",
        )

        archive = directory / "workdir-before-update.tar.gz"
        print("Backing up NetBox working directory ...")
        with tarfile.open(archive, "w:gz") as tar:
            for item in compose.workdir.iterdir():
                if item.name == ".git":
                    continue
                tar.add(item, arcname=item.name, recursive=True)


class PortainerClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        *,
        insecure: bool = False,
        timeout: int = 180,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token.strip()
        self.timeout = timeout
        self.context = (
            ssl._create_unverified_context()
            if insecure
            else ssl.create_default_context()
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        payload: Optional[Any] = None,
        raw: bool = False,
        timeout: Optional[int] = None,
    ) -> Any:
        url = f"{self.base_url}/api{path}"
        data: Optional[bytes] = None
        headers = {"X-API-Key": self.token}

        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif method.upper() == "POST":
            # Docker API endpoints such as /containers/{id}/start require an
            # explicitly empty request body. Some proxy/client combinations
            # otherwise forward a body that Docker rejects as non-empty.
            data = b""
            headers["Content-Length"] = "0"

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
                f"{method} {path} returned invalid JSON"
            ) from exc

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def post(
        self,
        path: str,
        *,
        payload: Optional[Any] = None,
        raw: bool = False,
    ) -> Any:
        return self.request("POST", path, payload=payload, raw=raw)

    def put(
        self,
        path: str,
        *,
        payload: Optional[Any] = None,
        raw: bool = False,
    ) -> Any:
        return self.request("PUT", path, payload=payload, raw=raw)

    def delete(self, path: str, *, raw: bool = False) -> Any:
        return self.request("DELETE", path, raw=raw)


class PortainerManager:
    def __init__(
        self,
        config: Config,
        docker: DockerClient,
        runner: Runner,
        backups: BackupManager,
        summary: Summary,
    ) -> None:
        self.config = config
        self.docker = docker
        self.runner = runner
        self.backups = backups
        self.summary = summary
        self.client: Optional[PortainerClient] = None
        self.server_version = ""

    def detect_local_url(self) -> Optional[Tuple[str, bool]]:
        for container_id in self.docker.ps(False):
            inspect = self.docker.inspect(container_id)
            image = str((inspect.get("Config") or {}).get("Image") or "")
            if not (
                image.startswith("portainer/portainer-ce:")
                or image.startswith("docker.io/portainer/portainer-ce:")
                or image.startswith("portainer/portainer-ee:")
                or image.startswith("docker.io/portainer/portainer-ee:")
            ):
                continue

            value = self.docker.port(container_id, "9443/tcp")
            if value:
                port = value.splitlines()[0].rsplit(":", 1)[-1]
                return f"https://127.0.0.1:{port}", True

            value = self.docker.port(container_id, "9000/tcp")
            if value:
                port = value.splitlines()[0].rsplit(":", 1)[-1]
                return f"http://127.0.0.1:{port}", False

        return None

    def connect(self) -> bool:
        if not self.config.portainer_enabled:
            return False

        url = self.config.portainer_url
        insecure = self.config.portainer_insecure

        if not url:
            detected = self.detect_local_url()
            if not detected:
                return False
            url, detected_insecure = detected
            if insecure is None:
                insecure = detected_insecure

        if not self.config.portainer_token_file.is_file():
            if not self.config.json_output:
                print()
                print("=" * 120)
                print(" PORTAINER REMOTE AGENTS")
                print("=" * 120)
                print(f"Portainer API : {url}")
                print("Status        : NOT CONFIGURED")
                print(f"Token file    : {self.config.portainer_token_file}")
            return False

        mode = stat.S_IMODE(self.config.portainer_token_file.stat().st_mode)
        if mode & 0o077:
            print(
                f"WARNING: Portainer token file mode is {mode:o}; "
                "600 or 400 is recommended.",
                file=sys.stderr,
            )

        token = self.config.portainer_token_file.read_text(
            encoding="utf-8"
        ).strip()
        if not token:
            raise PortainerError("Portainer token file is empty")

        self.client = PortainerClient(
            url,
            token,
            insecure=bool(insecure),
        )

        status = self.client.get("/system/status") or {}
        self.server_version = str(status.get("Version") or "").lstrip("v")
        if not self.server_version:
            raise PortainerError("Portainer Server version is unavailable")

        self.config.portainer_url = url
        return True

    @staticmethod
    def endpoint_type_name(value: int) -> str:
        return {
            PORTAINER_TYPE_DOCKER_AGENT: "Docker Agent",
            PORTAINER_TYPE_DOCKER_EDGE: "Docker Edge",
            PORTAINER_TYPE_K8S_AGENT: "K8s Agent",
            PORTAINER_TYPE_K8S_EDGE: "K8s Edge",
        }.get(value, f"Type {value}")

    def docker_path(self, endpoint_id: int, suffix: str) -> str:
        return f"/endpoints/{endpoint_id}/docker{suffix}"

    def write_json(self, path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")

    def pull_remote_image(
        self,
        endpoint_id: int,
        repository: str,
        tag: str,
        output_path: Path,
    ) -> None:
        assert self.client is not None
        repo_encoded = urllib.parse.quote(repository, safe="")
        tag_encoded = urllib.parse.quote(tag, safe="")
        body = self.client.post(
            self.docker_path(
                endpoint_id,
                f"/images/create?fromImage={repo_encoded}&tag={tag_encoded}",
            ),
            raw=True,
        ) or b""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(body)

        for line in body.decode("utf-8", errors="replace").splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if item.get("error") or item.get("errorDetail"):
                raise PortainerError(
                    f"remote pull failed for {repository}:{tag}: "
                    f"{item.get('error') or item.get('errorDetail')}"
                )

    def cleanup_stale_helpers(
        self,
        endpoint_id: int,
        containers: List[Dict[str, Any]],
    ) -> None:
        """
        Remove stale DCU helper containers left in Created/Exited/Dead state.

        Running helpers are never removed automatically because a running helper
        may still be inside its safety/rollback window.
        """
        assert self.client is not None

        prefixes = (
            "/dcu-portainer-agent-",
            "/dcu-portainer-compose-agent-",
        )

        for container in containers:
            names = [str(name) for name in (container.get("Names") or [])]
            if not any(
                any(name.startswith(prefix) for prefix in prefixes)
                for name in names
            ):
                continue

            state = str(container.get("State") or "").lower()
            status = str(container.get("Status") or "").lower()

            if state == "running" or status.startswith("up "):
                print(
                    "WARNING: running DCU helper found and left untouched: "
                    + ", ".join(name.lstrip("/") for name in names),
                    file=sys.stderr,
                )
                continue

            container_id = str(container.get("Id") or "")
            if not container_id:
                continue

            try:
                self.remove_remote_container(
                    endpoint_id,
                    container_id,
                    force=True,
                )
                print(
                    "Removed stale Portainer update helper: "
                    + ", ".join(name.lstrip("/") for name in names)
                )
            except PortainerError as exc:
                print(
                    f"WARNING: unable to remove stale DCU helper "
                    f"{container_id[:12]}: {exc}",
                    file=sys.stderr,
                )

    @staticmethod
    def find_agent_container(
        containers: List[Dict[str, Any]]
    ) -> Dict[str, Any]:
        matches: List[Dict[str, Any]] = []
        for container in containers:
            image = str(container.get("Image") or "")
            names = [str(x) for x in (container.get("Names") or [])]
            if (
                image.startswith("portainer/agent:")
                or image.startswith("docker.io/portainer/agent:")
                or any(
                    "portainer_agent" in name or "portainer-agent" in name
                    for name in names
                )
            ):
                matches.append(container)

        if len(matches) != 1:
            raise PortainerError(
                f"expected exactly one Portainer Agent container; "
                f"found {len(matches)}"
            )
        return matches[0]

    @staticmethod
    def path_is_within(path: str, root: str) -> bool:
        normalized = os.path.normpath(path)
        base = os.path.normpath(root)
        return normalized == base or normalized.startswith(base.rstrip("/") + "/")

    def compose_agent_metadata(
        self,
        inspect: Dict[str, Any],
        old_version: str,
    ) -> Dict[str, Any]:
        config = inspect.get("Config") or {}
        labels = config.get("Labels") or {}
        project = str(labels.get("com.docker.compose.project") or "")
        service = str(labels.get("com.docker.compose.service") or "")
        workdir = str(labels.get("com.docker.compose.project.working_dir") or "")
        config_label = str(
            labels.get("com.docker.compose.project.config_files") or ""
        )
        env_file = str(
            labels.get("com.docker.compose.project.environment_file") or ""
        )
        current_ref = str(config.get("Image") or "")

        if not project or not service or not workdir or not config_label:
            raise PortainerError(
                "Compose project/service/working_dir/config_files metadata is incomplete"
            )

        compose_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
        if not compose_name_re.fullmatch(project):
            raise PortainerError(
                f"unsupported Compose project name: {project}"
            )
        if not compose_name_re.fullmatch(service):
            raise PortainerError(
                f"unsupported Compose service name: {service}"
            )

        if not workdir.startswith("/"):
            raise PortainerError("Compose working directory is not absolute")

        config_files = [
            item.strip() for item in config_label.split(",") if item.strip()
        ]
        if not config_files:
            raise PortainerError("Compose config_files is empty")

        for item in config_files:
            if not item.startswith("/") or not self.path_is_within(item, workdir):
                raise PortainerError(
                    "Compose file outside the project working directory is unsupported"
                )

        if env_file:
            for item in env_file.split(","):
                item = item.strip()
                if item and (
                    not item.startswith("/")
                    or not self.path_is_within(item, workdir)
                ):
                    raise PortainerError(
                        "Compose environment file outside working directory is unsupported"
                    )

        prefixes = ("portainer/agent:", "docker.io/portainer/agent:")
        if not current_ref.startswith(prefixes):
            raise PortainerError(
                f"unexpected Portainer Agent image reference: {current_ref}"
            )

        tag = current_ref.rsplit(":", 1)[-1]
        if tag in MOVING_AGENT_TAGS:
            mode = "channel"
        else:
            mode = "fixed"
            allowed = {
                f"portainer/agent:{old_version}",
                f"docker.io/portainer/agent:{old_version}",
            }
            if current_ref not in allowed:
                raise PortainerError(
                    "Compose Agent must use installed fixed version or "
                    "sts/lts/latest; "
                    f"installed={old_version}, found={current_ref}"
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

    @staticmethod
    def validate_standalone_agent(inspect: Dict[str, Any]) -> None:
        config = inspect.get("Config") or {}
        host = inspect.get("HostConfig") or {}
        labels = config.get("Labels") or {}

        if labels.get("com.docker.swarm.service.name"):
            raise PortainerError("Agent is Docker Swarm managed")

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
                "Agent uses unsupported HostConfig.Mounts"
            )

        network_mode = str(host.get("NetworkMode") or "default")
        if network_mode.startswith("container:"):
            raise PortainerError("container network mode is unsupported")

        networks = ((inspect.get("NetworkSettings") or {}).get("Networks") or {})
        if len(networks) > 1:
            raise PortainerError(
                "Agent attached to multiple networks is not auto-updated"
            )

    def build_standalone_run_command(
        self,
        inspect: Dict[str, Any],
        target_version: str,
    ) -> str:
        config = inspect.get("Config") or {}
        host = inspect.get("HostConfig") or {}
        name = str(inspect.get("Name") or "").lstrip("/")
        if not name:
            raise PortainerError("remote Agent has no container name")

        args: List[str] = ["docker", "run", "-d", "--name", name]

        restart = host.get("RestartPolicy") or {}
        restart_name = str(restart.get("Name") or "")
        retry = int(restart.get("MaximumRetryCount") or 0)
        if restart_name:
            value = restart_name
            if restart_name == "on-failure" and retry:
                value = f"{restart_name}:{retry}"
            args.extend(["--restart", value])

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

        for container_port, mappings in (host.get("PortBindings") or {}).items():
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

        args.append(f"portainer/agent:{target_version}")
        return shlex.join(args)

    @staticmethod
    def quote_list(values: Iterable[str]) -> str:
        return " ".join(shlex.quote(str(x)) for x in values)

    def build_standalone_helper(
        self,
        inspect: Dict[str, Any],
        target_version: str,
        backup_name: str,
    ) -> str:
        name = str(inspect.get("Name") or "").lstrip("/")
        run_command = self.build_standalone_run_command(inspect, target_version)
        return f"""set -eu
OLD_NAME={shlex.quote(name)}
BACKUP_NAME={shlex.quote(backup_name)}

rollback() {{
    docker rm -f "$OLD_NAME" >/dev/null 2>&1 || true
    if docker inspect "$BACKUP_NAME" >/dev/null 2>&1; then
        docker rename "$BACKUP_NAME" "$OLD_NAME" >/dev/null 2>&1 || true
        docker start "$OLD_NAME" >/dev/null 2>&1 || true
    fi
}}

trap 'rollback; exit 90' INT TERM HUP

sleep 3

if ! docker stop -t 30 "$OLD_NAME"; then
    exit 18
fi

if ! docker rename "$OLD_NAME" "$BACKUP_NAME"; then
    docker start "$OLD_NAME" >/dev/null 2>&1 || true
    exit 19
fi

if ! {run_command}; then
    rollback
    exit 20
fi

for i in $(seq 1 120); do
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

    def build_compose_helper(
        self,
        metadata: Dict[str, Any],
        old_image_id: str,
        old_version: str,
        target_version: str,
    ) -> str:
        project = metadata["project"]
        service = metadata["service"]
        workdir = metadata["workdir"]
        config_files = metadata["config_files"]
        old_ref = metadata["current_ref"]
        mode = metadata["mode"]

        prefix = "docker.io/" if old_ref.startswith("docker.io/") else ""
        exact_target_ref = f"{prefix}portainer/agent:{target_version}"
        target_ref = old_ref if mode == "channel" else exact_target_ref

        stamp = datetime.now().strftime("%Y%m%d%H%M%S")
        backup_suffix = f".dcu-backup-{stamp}"
        backup_tag = f"portainer/agent:dcu-backup-{old_version}-{stamp}"

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
        compose_command = shlex.join(compose_args)
        files = self.quote_list(config_files)

        if mode == "fixed":
            prepare = f'''
MATCHES=0
for file in {files}; do
    COUNT=$(grep -F -o "$OLD_REF" "$file" 2>/dev/null | wc -l | tr -d ' ')
    MATCHES=$((MATCHES + COUNT))
done

if [ "$MATCHES" -ne 1 ]; then
    echo "ERROR: expected exactly one literal Agent image reference in Compose files; found $MATCHES." >&2
    exit 30
fi

for file in {files}; do
    cp -a "$file" "$file$BACKUP_SUFFIX"

    if grep -Fq "$OLD_REF" "$file"; then
        TMP_FILE="$file.dcu-tmp-$"
        awk -v old="$OLD_REF" -v new="$TARGET_REF" '
            {{
                pos = index($0, old)
                if (pos > 0) {{
                    print substr($0, 1, pos - 1) new substr($0, pos + length(old))
                }} else {{
                    print
                }}
            }}
        ' "$file" > "$TMP_FILE"

        # Write back through the existing file so owner/mode/inode are preserved.
        cat "$TMP_FILE" > "$file"
        rm -f "$TMP_FILE"
    fi
done
CHANGED=1
'''
            restore = f'''
    if [ "$CHANGED" -eq 1 ]; then
        for file in {files}; do
            if [ -f "$file$BACKUP_SUFFIX" ]; then
                cp -a "$file$BACKUP_SUFFIX" "$file"
            fi
        done
    fi
'''
        else:
            prepare = r'''
TARGET_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$EXACT_TARGET_REF") || exit 29
docker tag "$OLD_IMAGE_ID" "$BACKUP_TAG"
docker tag "$TARGET_IMAGE_ID" "$OLD_REF"
'''
            restore = r'''
    docker tag "$OLD_IMAGE_ID" "$OLD_REF" >/dev/null 2>&1 || true
'''

        return f"""set -eu
PROJECT={shlex.quote(project)}
SERVICE={shlex.quote(service)}
WORKDIR={shlex.quote(workdir)}
OLD_REF={shlex.quote(old_ref)}
TARGET_REF={shlex.quote(target_ref)}
EXACT_TARGET_REF={shlex.quote(exact_target_ref)}
OLD_IMAGE_ID={shlex.quote(old_image_id)}
BACKUP_TAG={shlex.quote(backup_tag)}
BACKUP_SUFFIX={shlex.quote(backup_suffix)}
COMPOSE={shlex.quote(compose_command)}
CHANGED=0

rollback() {{
{restore}
    cd "$WORKDIR"
    sh -c "$COMPOSE up -d --no-deps --force-recreate --pull never $SERVICE" >/dev/null 2>&1 || true
}}

trap 'rollback; exit 90' INT TERM HUP

# Give Portainer enough time to finish deploying this temporary helper stack
# and return control to docker-check-updates before the Agent is restarted.
sleep 15

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker:cli image does not provide Docker Compose." >&2
    exit 36
fi

if ! docker image inspect "$EXACT_TARGET_REF" >/dev/null 2>&1; then
    echo "ERROR: pre-pulled target image $EXACT_TARGET_REF is not available." >&2
    exit 37
fi

cd "$WORKDIR"

{prepare}

if ! sh -c "$COMPOSE config --images" | grep -Fx "$TARGET_REF" >/dev/null; then
    echo "ERROR: Compose config does not resolve to $TARGET_REF." >&2
    rollback
    exit 31
fi

if ! sh -c "$COMPOSE up -d --no-deps --force-recreate --pull never $SERVICE"; then
    rollback
    exit 35
fi

for i in $(seq 1 120); do
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

    def create_temp_helper_stack(
        self,
        endpoint_id: int,
        stack_name: str,
        script: str,
        extra_binds: Optional[List[str]] = None,
    ) -> Tuple[int, str]:
        """
        Deploy the update helper as a temporary Portainer Compose stack.

        This avoids direct Docker container start/recreate calls. Portainer
        deploys and starts the helper while the Agent is still connected.
        """
        assert self.client is not None

        encoded_script = base64.b64encode(
            script.encode("utf-8")
        ).decode("ascii")

        volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
        volumes.extend(extra_binds or [])

        volume_lines = "\n".join(
            f"      - {json.dumps(volume)}"
            for volume in volumes
        )

        command = (
            "printf '%s' "
            + shlex.quote(encoded_script)
            + " | base64 -d > /tmp/dcu-update.sh "
            + "&& exec sh /tmp/dcu-update.sh"
        )

        stack_file = (
            "services:\n"
            "  helper:\n"
            "    image: docker:cli\n"
            "    network_mode: \"none\"\n"
            "    restart: \"no\"\n"
            "    entrypoint: [\"/bin/sh\", \"-c\"]\n"
            f"    command: [{json.dumps(command)}]\n"
            "    volumes:\n"
            f"{volume_lines}\n"
        )

        response = self.client.post(
            f"/stacks/create/standalone/string?endpointId={endpoint_id}",
            payload={
                "Name": stack_name,
                "StackFileContent": stack_file,
                "Env": [],
                "FromAppTemplate": False,
            },
        ) or {}

        stack_id = int(response.get("Id") or 0)
        if not stack_id:
            raise PortainerError(
                "Portainer did not return the temporary helper stack ID"
            )

        helper_id = ""
        deadline = time.time() + 30

        while time.time() < deadline:
            containers = self.client.get(
                self.docker_path(
                    endpoint_id,
                    "/containers/json?all=true",
                )
            ) or []

            for container in containers:
                labels = container.get("Labels") or {}
                if (
                    labels.get("com.docker.compose.project") == stack_name
                    and labels.get("com.docker.compose.service") == "helper"
                ):
                    helper_id = str(container.get("Id") or "")
                    if helper_id:
                        break

            if helper_id:
                break

            time.sleep(1)

        if not helper_id:
            try:
                self.delete_temp_helper_stack(
                    endpoint_id,
                    stack_id,
                )
            except Exception:
                pass
            raise PortainerError(
                "temporary Portainer helper stack was created, "
                "but its helper container was not found"
            )

        return stack_id, helper_id

    def delete_temp_helper_stack(
        self,
        endpoint_id: int,
        stack_id: int,
    ) -> None:
        assert self.client is not None
        self.client.delete(
            f"/stacks/{stack_id}?endpointId={endpoint_id}",
            raw=True,
        )

    def create_remote_helper(
        self,
        endpoint_id: int,
        helper_name: str,
        script: str,
        extra_binds: Optional[List[str]] = None,
    ) -> str:
        assert self.client is not None
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

        response = self.client.post(
            self.docker_path(
                endpoint_id,
                f"/containers/create?name={urllib.parse.quote(helper_name, safe='')}",
            ),
            payload=payload,
        ) or {}

        helper_id = str(response.get("Id") or "")
        if not helper_id:
            raise PortainerError("Docker API did not return helper container ID")
        return helper_id

    def start_remote_container_via_portainer(
        self,
        endpoint_id: int,
        container_id: str,
    ) -> str:
        """
        Start a newly created helper through Portainer's non-proxied recreate
        endpoint.

        Portainer 2.45.1 exposes:
          POST /api/docker/{environmentId}/containers/{containerId}/recreate

        That handler uses Portainer's internal Docker client and calls
        ContainerStart directly, avoiding the raw Docker proxy start endpoint
        that can forward an incompatible request body.
        """
        assert self.client is not None

        response = self.client.post(
            f"/docker/{endpoint_id}/containers/{container_id}/recreate",
            payload={"PullImage": False},
        ) or {}

        new_id = str(response.get("Id") or response.get("ID") or "")
        if not new_id:
            raise PortainerError(
                "Portainer recreate did not return the new helper container ID"
            )

        return new_id

    def remove_remote_container(
        self,
        endpoint_id: int,
        container_id: str,
        *,
        force: bool = True,
    ) -> None:
        assert self.client is not None
        value = "true" if force else "false"
        self.client.delete(
            self.docker_path(
                endpoint_id,
                f"/containers/{container_id}?force={value}",
            ),
            raw=True,
        )

    def exec_remote_container(
        self,
        endpoint_id: int,
        container_id: str,
        command: List[str],
    ) -> None:
        assert self.client is not None
        response = self.client.post(
            self.docker_path(endpoint_id, f"/containers/{container_id}/exec"),
            payload={
                "AttachStdout": False,
                "AttachStderr": False,
                "Cmd": command,
            },
        ) or {}
        exec_id = str(response.get("Id") or "")
        if not exec_id:
            raise PortainerError("Docker API did not return exec ID")

        self.client.post(
            self.docker_path(endpoint_id, f"/exec/{exec_id}/start"),
            payload={"Detach": True, "Tty": False},
            raw=True,
        )

    def get_agent_version(self, endpoint_id: int) -> Tuple[int, str]:
        assert self.client is not None
        endpoint = self.client.get(f"/endpoints/{endpoint_id}") or {}
        status = int(endpoint.get("Status") or 0)
        version = str((endpoint.get("Agent") or {}).get("Version") or "")
        return status, version

    def refresh_endpoint_snapshot(self, endpoint_id: int) -> None:
        """
        Force Portainer to refresh the environment snapshot.

        For standard Agent environments, Portainer 2.45.1 queries the Agent
        directly during a snapshot and updates endpoint.Agent.Version.
        """
        assert self.client is not None
        self.client.post(
            f"/endpoints/{endpoint_id}/snapshot",
            raw=True,
        )

    def remote_image_id(
        self,
        endpoint_id: int,
        image_ref: str,
    ) -> str:
        assert self.client is not None

        filters = urllib.parse.quote(
            json.dumps(
                {"reference": [image_ref]},
                separators=(",", ":"),
            ),
            safe="",
        )

        images = self.client.get(
            self.docker_path(
                endpoint_id,
                f"/images/json?all=false&filters={filters}",
            )
        ) or []

        if not images:
            return ""

        return str(images[0].get("Id") or "")

    def running_agent_image_id(
        self,
        endpoint_id: int,
    ) -> Tuple[str, str]:
        assert self.client is not None

        containers = self.client.get(
            self.docker_path(
                endpoint_id,
                "/containers/json?all=false",
            )
        ) or []

        candidate = self.find_agent_container(containers)
        container_id = str(candidate.get("Id") or "")

        if not container_id:
            return "", ""

        inspect = self.client.get(
            self.docker_path(
                endpoint_id,
                f"/containers/{container_id}/json",
            )
        ) or {}

        image_id = str(inspect.get("Image") or "")
        return container_id, image_id

    def helper_state(
        self,
        endpoint_id: int,
        helper_id: str,
    ) -> Tuple[bool, int, str]:
        assert self.client is not None

        inspect = self.client.get(
            self.docker_path(
                endpoint_id,
                f"/containers/{helper_id}/json",
            )
        ) or {}

        state = inspect.get("State") or {}
        return (
            bool(state.get("Running")),
            int(state.get("ExitCode") or 0),
            str(state.get("Status") or ""),
        )

    def capture_helper_logs(
        self,
        endpoint_id: int,
        helper_id: str,
        directory: Path,
        *,
        show_tail: bool = False,
        tail_lines: int = 40,
    ) -> str:
        assert self.client is not None

        try:
            raw = self.client.request(
                "GET",
                self.docker_path(
                    endpoint_id,
                    f"/containers/{helper_id}/logs?"
                    "stdout=true&stderr=true&timestamps=true",
                ),
                raw=True,
            ) or b""
        except PortainerError as exc:
            print(
                f"WARNING: unable to retrieve helper logs: {exc}",
                file=sys.stderr,
                flush=True,
            )
            return ""

        directory.mkdir(parents=True, exist_ok=True)
        (directory / "helper-compose.log").write_bytes(raw)

        text = decode_docker_stream(raw)

        if show_tail and text.strip():
            lines = text.rstrip().splitlines()
            visible = lines[-tail_lines:]
            print("---- remote helper log (tail) ----", flush=True)
            for line in visible:
                print(f"  {line}", flush=True)
            print("----------------------------------", flush=True)

        return text

    def wait_helper_exit(
        self,
        endpoint_id: int,
        helper_id: str,
        directory: Path,
        *,
        compose: bool,
    ) -> None:
        assert self.client is not None
        running = True
        for _ in range(15):
            time.sleep(1)
            try:
                inspect = self.client.get(
                    self.docker_path(
                        endpoint_id,
                        f"/containers/{helper_id}/json",
                    )
                ) or {}
            except PortainerError:
                running = False
                break

            running = bool((inspect.get("State") or {}).get("Running"))
            if not running:
                break

        try:
            raw = self.client.request(
                "GET",
                self.docker_path(
                    endpoint_id,
                    f"/containers/{helper_id}/logs?"
                    "stdout=true&stderr=true&timestamps=true",
                ),
                raw=True,
            ) or b""
            log_name = "helper-compose.log" if compose else "helper.log"
            (directory / log_name).write_bytes(raw)
        except PortainerError:
            pass

        if not running:
            try:
                self.client.delete(
                    self.docker_path(
                        endpoint_id,
                        f"/containers/{helper_id}?force=false",
                    ),
                    raw=True,
                )
            except PortainerError:
                pass
        else:
            print(
                f"WARNING: remote update helper {helper_id[:12]} is still running; "
                "left in place for safety.",
                file=sys.stderr,
            )

    def update_remote_agent(
        self,
        endpoint: Dict[str, Any],
    ) -> bool:
        assert self.client is not None
        endpoint_id = int(endpoint["Id"])
        env_name = str(endpoint.get("Name") or f"environment-{endpoint_id}")
        endpoint_url = str(endpoint.get("URL") or "")
        old_version = str((endpoint.get("Agent") or {}).get("Version") or "unknown")
        target_version = self.server_version

        run_dir = self.backups.ensure()
        directory = (
            run_dir
            / "portainer"
            / f"{endpoint_id}-{safe_name(env_name)}"
        )
        directory.mkdir(parents=True, exist_ok=True)
        try:
            directory.chmod(0o700)
        except PermissionError:
            pass

        print()
        print(f"Portainer environment : {env_name}", flush=True)
        print(f"Agent                 : {old_version} -> {target_version}", flush=True)
        print(f"Environment URL       : {endpoint_url}", flush=True)
        print("Step 1/7              : Inspecting remote Agent container ...", flush=True)

        containers = self.client.get(
            self.docker_path(endpoint_id, "/containers/json?all=true")
        ) or []

        self.cleanup_stale_helpers(endpoint_id, containers)

        containers = self.client.get(
            self.docker_path(endpoint_id, "/containers/json?all=true")
        ) or []
        self.write_json(directory / "containers.json", containers)

        candidate = self.find_agent_container(containers)
        container_id = str(candidate.get("Id") or "")
        container_name = str((candidate.get("Names") or [""])[0]).lstrip("/")

        inspect = self.client.get(
            self.docker_path(
                endpoint_id,
                f"/containers/{container_id}/json",
            )
        ) or {}
        self.write_json(
            directory / f"{safe_name(container_name)}.inspect.json",
            inspect,
        )

        labels = ((inspect.get("Config") or {}).get("Labels") or {})
        compose_managed = bool(labels.get("com.docker.compose.project"))

        if not compose_managed:
            raise PortainerError(
                "v4.0.0-rc.4 automatically updates remote Agents only "
                "when they are managed by Docker Compose"
            )

        metadata = self.compose_agent_metadata(inspect, old_version)
        old_image_id = str(inspect.get("Image") or "")
        helper_script = self.build_compose_helper(
            metadata,
            old_image_id,
            old_version,
            target_version,
        )

        self.write_json(
            directory / "compose-update.json",
            {
                "endpoint_id": endpoint_id,
                "environment": env_name,
                "old_version": old_version,
                "target_version": target_version,
                **metadata,
            },
        )
        (directory / "helper-compose-update.sh").write_text(
            helper_script,
            encoding="utf-8",
        )

        print("Management            : Docker Compose", flush=True)
        print(f"Compose project       : {metadata['project']}", flush=True)
        print(f"Compose service       : {metadata['service']}", flush=True)
        print(
            f"Compose image         : {metadata['current_ref']} "
            f"({metadata['mode']})",
            flush=True,
        )
        print(f"Compose working dir   : {metadata['workdir']}", flush=True)

        print(
            f"Step 2/7              : Pre-pulling portainer/agent:{target_version} ...",
            flush=True,
        )
        self.pull_remote_image(
            endpoint_id,
            "portainer/agent",
            target_version,
            directory / "agent-pull.jsonl",
        )

        target_image_ref = f"portainer/agent:{target_version}"
        target_image_id = self.remote_image_id(
            endpoint_id,
            target_image_ref,
        )

        if not target_image_id:
            raise PortainerError(
                f"unable to resolve remote image ID for {target_image_ref}"
            )

        print(
            f"Target image ID       : {short_image_id(target_image_id)}",
            flush=True,
        )

        print(
            "Step 3/7              : Pre-pulling docker:cli helper image ...",
            flush=True,
        )
        self.pull_remote_image(
            endpoint_id,
            "docker",
            "cli",
            directory / "helper-pull.jsonl",
        )

        stack_name = (
            f"dcu-agent-helper-{endpoint_id}-"
            f"{datetime.now().strftime('%Y%m%d%H%M%S')}"
        )

        print(
            "Step 4/7              : Deploying temporary helper stack through Portainer ...",
            flush=True,
        )
        stack_id = 0
        helper_id = ""

        try:
            stack_id, helper_id = self.create_temp_helper_stack(
                endpoint_id,
                stack_name,
                helper_script,
                extra_binds=[
                    f"{metadata['workdir']}:{metadata['workdir']}:rw"
                ],
            )

            print(
                f"Helper stack          : {stack_name} (ID {stack_id})",
                flush=True,
            )
            print(
                f"Helper container      : {helper_id[:12]}",
                flush=True,
            )
            print(
                f"Step 5/7              : Waiting for {env_name} "
                f"to reconnect with Agent {target_version} ...",
                flush=True,
            )

            deadline = time.time() + 210
            reconnected = False
            last_version = old_version
            last_report = 0.0

            helper_failed = False
            helper_exit_code = 0
            helper_status = ""
            runtime_confirmed = False
            snapshot_requested = False
            last_runtime_image = ""
            last_snapshot_at = 0.0

            while time.time() < deadline:
                time.sleep(3)

                try:
                    status, version = self.get_agent_version(endpoint_id)
                    last_version = version or last_version
                except PortainerError:
                    status, version = 0, ""

                # Primary validation: verify the running Agent container is
                # using the exact image we pre-pulled for the target version.
                try:
                    _agent_container_id, runtime_image_id = (
                        self.running_agent_image_id(endpoint_id)
                    )
                    last_runtime_image = runtime_image_id or last_runtime_image
                except PortainerError:
                    runtime_image_id = ""

                if (
                    status == PORTAINER_STATUS_UP
                    and runtime_image_id == target_image_id
                ):
                    runtime_confirmed = True

                    # Ask Portainer to refresh Agent.Version immediately instead
                    # of waiting for its periodic snapshot cycle.
                    now = time.time()
                    if (
                        not snapshot_requested
                        or now - last_snapshot_at >= 20
                    ):
                        print(
                            "  ... target Agent image is running; "
                            "refreshing Portainer snapshot ...",
                            flush=True,
                        )
                        try:
                            self.refresh_endpoint_snapshot(endpoint_id)
                            snapshot_requested = True
                            last_snapshot_at = now
                            status, version = self.get_agent_version(endpoint_id)
                            last_version = version or last_version
                        except PortainerError as exc:
                            print(
                                f"  ... snapshot refresh warning: {exc}",
                                file=sys.stderr,
                                flush=True,
                            )

                    if version == target_version:
                        reconnected = True
                        break

                    # Runtime image + environment UP is already sufficient to
                    # prove that the target Agent is running. Agent.Version is
                    # Portainer metadata and can lag behind the runtime state.
                    if runtime_confirmed:
                        print(
                            f"  ... runtime validation OK: Agent container "
                            f"is running image {short_image_id(target_image_id)}; "
                            f"Portainer metadata still reports "
                            f"{version or 'unknown'}.",
                            flush=True,
                        )
                        reconnected = True
                        break

                try:
                    helper_running, helper_exit_code, helper_status = (
                        self.helper_state(endpoint_id, helper_id)
                    )
                except PortainerError:
                    helper_running = True

                if not helper_running:
                    helper_failed = True
                    print(
                        f"  !! Helper exited before Agent confirmation "
                        f"(status={helper_status or 'unknown'}, "
                        f"exit={helper_exit_code}).",
                        file=sys.stderr,
                        flush=True,
                    )
                    self.capture_helper_logs(
                        endpoint_id,
                        helper_id,
                        directory,
                        show_tail=True,
                    )
                    break

                now = time.time()
                if now - last_report >= 15:
                    remaining = max(0, int(deadline - now))
                    runtime_short = (
                        short_image_id(runtime_image_id)
                        if runtime_image_id
                        else "unavailable"
                    )
                    print(
                        f"  ... Agent status={status}, version="
                        f"{version or 'unavailable'}, "
                        f"image={runtime_short}, helper=running, "
                        f"timeout in {remaining}s",
                        flush=True,
                    )
                    last_report = now

            if not reconnected:
                print(
                    "ERROR: target Agent did not reconnect at the expected "
                    f"version {target_version}. Last observed version: "
                    f"{last_version}.",
                    file=sys.stderr,
                    flush=True,
                )

                if not helper_failed:
                    self.capture_helper_logs(
                        endpoint_id,
                        helper_id,
                        directory,
                        show_tail=True,
                    )

                print(
                    "The helper will roll back automatically because no "
                    "commit signal was sent.",
                    file=sys.stderr,
                    flush=True,
                )

                rollback_deadline = time.time() + 60
                while time.time() < rollback_deadline:
                    time.sleep(3)
                    try:
                        status, version = self.get_agent_version(endpoint_id)
                    except PortainerError:
                        continue

                    if (
                        status == PORTAINER_STATUS_UP
                        and version == old_version
                    ):
                        print(
                            f"Rollback confirmed: {env_name} is back on "
                            f"Agent {old_version}.",
                            flush=True,
                        )
                        break

                return False

            if last_version == target_version:
                validation_text = (
                    f"Portainer reports Agent {target_version}"
                )
            else:
                validation_text = (
                    f"runtime image {short_image_id(target_image_id)} "
                    f"confirmed; Portainer metadata refresh pending"
                )

            print(
                f"Step 6/7              : Target Agent confirmed "
                f"({validation_text}); committing update ...",
                flush=True,
            )
            self.exec_remote_container(
                endpoint_id,
                helper_id,
                ["sh", "-c", "touch /tmp/dcu-commit"],
            )

            self.wait_helper_exit(
                endpoint_id,
                helper_id,
                directory,
                compose=True,
            )

            try:
                self.refresh_endpoint_snapshot(endpoint_id)
                _final_status, final_version = self.get_agent_version(endpoint_id)
                if final_version:
                    print(
                        f"Portainer Agent       : {final_version}",
                        flush=True,
                    )
            except PortainerError as exc:
                print(
                    f"WARNING: final Portainer snapshot refresh failed: {exc}",
                    file=sys.stderr,
                    flush=True,
                )

            print(
                "Step 7/7              : Removing temporary helper stack ...",
                flush=True,
            )
            self.delete_temp_helper_stack(
                endpoint_id,
                stack_id,
            )
            stack_id = 0

            print(
                f"OK: {env_name} Agent is now {target_version}.",
                flush=True,
            )
            print(f"Backup metadata: {directory}", flush=True)
            return True

        finally:
            # Remove the temporary stack only when the Agent is reachable.
            # If connectivity is still lost, leaving the helper stack in place
            # is safer because its timeout/rollback logic may still be active.
            if stack_id:
                try:
                    status, _version = self.get_agent_version(endpoint_id)
                except PortainerError:
                    status = 0

                if status == PORTAINER_STATUS_UP:
                    try:
                        self.delete_temp_helper_stack(
                            endpoint_id,
                            stack_id,
                        )
                    except Exception as exc:
                        print(
                            f"WARNING: unable to remove temporary helper "
                            f"stack {stack_id}: {exc}",
                            file=sys.stderr,
                            flush=True,
                        )

    def check_and_update(self, confirm: Any) -> None:
        if not self.connect():
            return
        assert self.client is not None

        endpoints = self.client.get("/endpoints?outdated=true") or []

        if not self.config.json_output:
            print()
            print("=" * 120)
            print(" PORTAINER REMOTE AGENTS")
            print("=" * 120)
            print(f"Portainer API : {self.config.portainer_url}")
            print(f"Server        : {self.server_version}")
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
            endpoint_type = int(endpoint.get("Type") or 0)
            status = int(endpoint.get("Status") or 0)
            agent_version = str((endpoint.get("Agent") or {}).get("Version") or "")
            self.summary.portainer_outdated += 1

            if endpoint_type == PORTAINER_TYPE_DOCKER_AGENT:
                if status == PORTAINER_STATUS_UP:
                    action = "UPDATE"
                else:
                    action = "DOWN"
                    self.summary.portainer_skipped += 1
            elif endpoint_type == PORTAINER_TYPE_DOCKER_EDGE:
                action = "EDGE MANUAL"
                self.summary.portainer_skipped += 1
            elif endpoint_type in (
                PORTAINER_TYPE_K8S_AGENT,
                PORTAINER_TYPE_K8S_EDGE,
            ):
                action = "K8S MANUAL"
                self.summary.portainer_skipped += 1
            else:
                action = "UNSUPPORTED"
                self.summary.portainer_skipped += 1

            if not self.config.json_output:
                print(
                    f"{name[:30]:30} "
                    f"{self.endpoint_type_name(endpoint_type)[:16]:16} "
                    f"{(agent_version or 'unknown')[:14]:14} "
                    f"{self.server_version[:14]:14} "
                    f"{action[:18]:18}"
                )

            if not self.config.update:
                continue
            if endpoint_type != PORTAINER_TYPE_DOCKER_AGENT:
                continue
            if status != PORTAINER_STATUS_UP:
                continue

            if self.config.dry_run:
                print(f"DRY-RUN: would update Portainer Agent on {name}.")
                continue

            if not confirm(f"Update Portainer Agent on {name}?"):
                self.summary.portainer_skipped += 1
                continue

            try:
                if self.update_remote_agent(endpoint):
                    self.summary.portainer_updated += 1
                else:
                    self.summary.errors += 1
            except PortainerError as exc:
                print(f"ERROR: {name}: {exc}", file=sys.stderr)
                self.summary.errors += 1
            except Exception as exc:
                print(f"ERROR: {name}: {exc}", file=sys.stderr)
                self.summary.errors += 1


class Application:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.runner = Runner(verbose=config.verbose)
        self.docker = DockerClient(self.runner)
        self.versions = VersionInspector(self.docker, self.runner)
        self.summary = Summary()
        self.backups = BackupManager(config, self.docker, self.runner)

        self.pull_cache: Dict[str, Optional[RemoteImage]] = {}
        self.pull_errors: Dict[str, str] = {}
        self.records: List[ContainerRecord] = []
        self.plans: Dict[str, UpdatePlan] = {}

    def progress(self, message: str) -> None:
        if not self.config.json_output:
            print(message, flush=True)

    def phase(self, title: str) -> None:
        if not self.config.json_output:
            print()
            print(f"==> {title}", flush=True)

    def confirm(self, prompt: str) -> bool:
        if self.config.assume_yes:
            return True
        answer = input(f"{prompt} [y/N]: ").strip().lower()
        return answer in {"y", "yes"}

    def compose_run(
        self,
        compose: ComposeProject,
        *args: str,
        env_overrides: Optional[Dict[str, str]] = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        if env_overrides:
            env.update(env_overrides)
        return self.runner.run(
            compose.command(*args),
            cwd=compose.workdir,
            env=env,
            check=check,
            capture=False,
        )

    @staticmethod
    def is_netbox_custom(image_ref: str) -> bool:
        value = image_ref.split("/")[-1]
        return value.startswith("netbox-custom:")

    @staticmethod
    def netbox_series(image_ref: str) -> Optional[str]:
        tag = image_ref.rsplit(":", 1)[-1]
        match = re.match(
            r"^v(\d+\.\d+)(?:\.\d+)?-\d+\.\d+\.\d+$",
            tag,
        )
        return match.group(1) if match else None

    @staticmethod
    def is_pinned(image_ref: str) -> bool:
        return "@sha256:" in image_ref or image_ref.startswith("sha256:")

    def netbox_checkout_version(self, compose: ComposeProject) -> str:
        version_file = compose.workdir / "VERSION"
        if not version_file.is_file():
            return ""
        return version_file.read_text(encoding="utf-8").strip()

    def pull_remote(self, image_ref: str) -> Optional[RemoteImage]:
        if image_ref in self.pull_cache:
            return self.pull_cache[image_ref]

        if not self.config.json_output:
            print(
                f"       registry: {image_ref} ... ",
                end="",
                flush=True,
            )

        ok, output = self.docker.pull(image_ref)
        if not ok:
            if not self.config.json_output:
                print("FAILED", flush=True)
            self.pull_cache[image_ref] = None
            self.pull_errors[image_ref] = output
            return None

        if not self.config.json_output:
            print("OK", flush=True)
        data = self.docker.image_inspect(image_ref, refresh=True)
        image_id = str(data.get("Id") or "")
        remote = RemoteImage(
            image_id=image_id,
            version=self.versions.image_version(image_ref, image_ref),
            created=self.versions.image_created(image_ref),
        )
        self.pull_cache[image_ref] = remote
        return remote

    def discover_record(self, container_id: str) -> ContainerRecord:
        inspect = self.docker.inspect(container_id)
        name = str(inspect.get("Name") or "").lstrip("/")
        state = inspect.get("State") or {}
        running = bool(state.get("Running"))
        image_ref = str((inspect.get("Config") or {}).get("Image") or "")
        image_id = str(inspect.get("Image") or "")
        compose = ComposeProject.from_inspect(inspect)

        if self.is_netbox_custom(image_ref):
            app, _support = self.versions.netbox_versions(image_id)
            installed = app
        else:
            installed = self.versions.image_version(image_id, image_ref)

        return ContainerRecord(
            container_id=container_id,
            name=name,
            running=running,
            image_ref=image_ref,
            current_image_id=image_id,
            installed=installed,
            compose=compose,
        )

    def analyze_generic(self, record: ContainerRecord) -> None:
        if self.is_pinned(record.image_ref):
            record.status = "PINNED"
            self.summary.up_to_date += 1
            return

        remote = self.pull_remote(record.image_ref)

        if remote is None:
            try:
                data = self.docker.image_inspect(record.current_image_id)
                repo_digests = data.get("RepoDigests") or []
            except AppError:
                repo_digests = []

            if not repo_digests:
                record.status = "LOCAL BUILD"
                self.summary.local_builds += 1
            else:
                record.status = "PULL ERROR"
                record.details["error"] = self.pull_errors.get(record.image_ref, "")
                self.summary.errors += 1
            return

        record.available = remote.version
        record.date = remote.created

        if record.current_image_id == remote.image_id:
            record.status = "UP TO DATE"
            self.summary.up_to_date += 1
            return

        record.status = "UPDATE"
        self.summary.updates_found += 1

        if not record.running:
            record.status = "UPDATE (STOPPED)"
            self.summary.updates_skipped += 1
            return

        if not record.compose:
            record.details["reason"] = "not managed by Docker Compose"
            self.summary.updates_skipped += 1
            return

        key = f"compose:{record.compose.project}:{record.compose.service}"
        if key not in self.plans:
            self.plans[key] = UpdatePlan(
                kind="compose",
                key=key,
                description=(
                    f"{record.name}: {record.installed} -> {record.available}"
                ),
                container_id=record.container_id,
                project=record.compose,
                data={
                    "image_ref": record.image_ref,
                    "old_image_id": record.current_image_id,
                },
            )

    def analyze_netbox(self, record: ContainerRecord) -> None:
        self.summary.netbox_custom += 1
        compose = record.compose

        if not compose:
            record.status = "LOCAL BUILD"
            self.summary.local_builds += 1
            return

        current_app, current_support_image = self.versions.netbox_versions(
            record.current_image_id
        )
        checkout_support = self.netbox_checkout_version(compose)
        current_support = (
            checkout_support
            or (
                current_support_image
                if current_support_image != "unknown"
                else ""
            )
        )

        series = self.netbox_series(record.image_ref)
        if not series:
            record.status = "LOCAL BUILD"
            self.summary.local_builds += 1
            return

        base_ref = f"docker.io/netboxcommunity/netbox:v{series}"
        remote = self.pull_remote(base_ref)
        if remote is None:
            record.status = "BASE PULL ERROR"
            self.summary.errors += 1
            return

        base_id = remote.image_id
        available_app, available_support = self.versions.netbox_versions(base_id)
        record.installed = current_app
        record.available = available_app
        record.date = remote.created

        key = f"netbox:{compose.project}"

        if (
            available_support != "unknown"
            and checkout_support
            and available_support != checkout_support
        ):
            record.status = f"REPO {available_support}"
            self.summary.updates_found += 1
            self.summary.netbox_repo_updates += 1

            if key in self.plans:
                self.plans[key].count += 1
            else:
                self.plans[key] = UpdatePlan(
                    kind="netbox_repo",
                    key=key,
                    description=(
                        f"NetBox {current_app} -> {available_app}, "
                        f"netbox-docker {checkout_support} -> {available_support}"
                    ),
                    container_id=record.container_id,
                    project=compose,
                    data={
                        "current_app": current_app,
                        "target_app": available_app,
                        "current_support": checkout_support or current_support,
                        "target_support": available_support,
                        "series": series,
                    },
                )
            return

        if available_app == current_app:
            record.status = "LOCAL OK"
            self.summary.up_to_date += 1
            return

        record.status = "REBUILD"
        self.summary.updates_found += 1

        if key in self.plans:
            self.plans[key].count += 1
        else:
            self.plans[key] = UpdatePlan(
                kind="netbox_rebuild",
                key=key,
                description=f"NetBox {current_app} -> {available_app}",
                container_id=record.container_id,
                project=compose,
                data={
                    "current_app": current_app,
                    "target_app": available_app,
                    "current_support": current_support,
                    "target_support": current_support,
                    "series": series,
                },
            )

    def print_live_table_header(self) -> None:
        if self.config.json_output:
            return

        print(
            f"{'#':5} {'CONTAINER':36} {'IMAGE':32} {'INSTALLED':16} "
            f"{'AVAILABLE':16} {'DATE':12} {'STATUS':18}",
            flush=True,
        )
        print(
            f"{'-' * 5} {'-' * 36} {'-' * 32} {'-' * 16} "
            f"{'-' * 16} {'-' * 12} {'-' * 18}",
            flush=True,
        )

    def print_live_record(
        self,
        record: ContainerRecord,
        index: int,
        total: int,
    ) -> None:
        if self.config.json_output:
            return

        item = f"{index:02d}/{total:02d}"
        print(
            f"{item:5} "
            f"{record.name[:36]:36} "
            f"{record.image_ref[:32]:32} "
            f"{record.installed[:16]:16} "
            f"{record.available[:16]:16} "
            f"{record.date[:12]:12} "
            f"{record.status[:18]:18}",
            flush=True,
        )

    def discover_and_analyze(self) -> None:
        ids = self.docker.ps(self.config.all_containers)
        if not ids:
            return

        self.phase(f"Checking {len(ids)} Docker containers")
        self.print_live_table_header()

        for index, container_id in enumerate(ids, start=1):
            try:
                record = self.discover_record(container_id)

                if self.is_netbox_custom(record.image_ref):
                    self.analyze_netbox(record)
                else:
                    self.analyze_generic(record)

                self.records.append(record)
                self.print_live_record(record, index, len(ids))
            except Exception as exc:
                name = container_id[:12]
                try:
                    inspect = self.docker.inspect(container_id)
                    name = str(inspect.get("Name") or "").lstrip("/") or name
                except Exception:
                    pass
                error_record = ContainerRecord(
                    container_id=container_id,
                    name=name,
                    running=False,
                    image_ref="-",
                    current_image_id="-",
                    installed="-",
                    status="ERROR",
                    details={"error": str(exc)},
                )
                self.records.append(error_record)
                self.print_live_record(error_record, index, len(ids))
                self.summary.errors += 1

    def print_records(self) -> None:
        if self.config.json_output:
            return

        print()
        print(
            f"{'CONTAINER':38} {'IMAGE':34} {'INSTALLED':18} "
            f"{'AVAILABLE':18} {'DATE':12} {'STATUS':18}"
        )
        print(
            f"{'-' * 38} {'-' * 34} {'-' * 18} "
            f"{'-' * 18} {'-' * 12} {'-' * 18}"
        )

        for record in self.records:
            print(
                f"{record.name[:38]:38} "
                f"{record.image_ref[:34]:34} "
                f"{record.installed[:18]:18} "
                f"{record.available[:18]:18} "
                f"{record.date[:12]:12} "
                f"{record.status[:18]:18}"
            )

            if record.details.get("reason"):
                print(f"  -> {record.details['reason']}")
            if (
                self.config.verbose
                and record.details.get("error")
            ):
                print(
                    f"  -> {record.details['error']}",
                    file=sys.stderr,
                )

    def backup_all(self) -> None:
        for record in self.records:
            try:
                inspect = self.docker.inspect(record.container_id)
                self.backups.backup_container(
                    inspect,
                    netbox_custom=self.is_netbox_custom(record.image_ref),
                )
            except Exception as exc:
                print(
                    f"ERROR: backup failed for {record.name}: {exc}",
                    file=sys.stderr,
                )
                self.summary.errors += 1
        self.backups.finalize()

    def wait_compose_service(
        self,
        compose: ComposeProject,
        timeout: int = 120,
    ) -> bool:
        deadline = time.time() + timeout

        while time.time() < deadline:
            ids = self.runner.output(
                [
                    "docker",
                    "ps",
                    "-aq",
                    "--filter",
                    f"label=com.docker.compose.project={compose.project}",
                    "--filter",
                    f"label=com.docker.compose.service={compose.service}",
                ],
                check=False,
            ).splitlines()

            if not ids:
                time.sleep(2)
                continue

            all_good = True
            for container_id in ids:
                inspect = self.docker.inspect(container_id, refresh=True)
                state = inspect.get("State") or {}
                if not state.get("Running"):
                    all_good = False
                    break

                health = (state.get("Health") or {}).get("Status")
                if health and health != "healthy":
                    all_good = False
                    break

            if all_good:
                return True

            time.sleep(2)

        return False

    def execute_compose_plan(self, plan: UpdatePlan) -> bool:
        assert plan.project is not None
        compose = plan.project
        inspect = self.docker.inspect(plan.container_id)

        if not self.config.no_backup:
            self.backups.backup_container(inspect)

        print()
        print(f"Updating Compose service: {compose.project}/{compose.service}")

        if self.config.dry_run:
            print(
                "DRY-RUN:",
                shlex.join(compose.command("pull", compose.service)),
            )
            print(
                "DRY-RUN:",
                shlex.join(
                    compose.command(
                        "up",
                        "-d",
                        "--no-deps",
                        compose.service,
                    )
                ),
            )
            return True

        self.compose_run(compose, "pull", compose.service)
        self.compose_run(
            compose,
            "up",
            "-d",
            "--no-deps",
            compose.service,
        )
        self.docker.invalidate()

        if not self.wait_compose_service(compose):
            raise AppError(
                f"Compose service did not become healthy/running: "
                f"{compose.project}/{compose.service}"
            )

        return True

    def backup_netbox_project(self, compose: ComposeProject) -> None:
        ids = self.runner.output(
            [
                "docker",
                "ps",
                "-aq",
                "--filter",
                f"label=com.docker.compose.project={compose.project}",
            ],
            check=False,
        ).splitlines()

        for container_id in ids:
            inspect = self.docker.inspect(container_id)
            self.backups.backup_container(
                inspect,
                netbox_custom=self.is_netbox_custom(
                    str((inspect.get("Config") or {}).get("Image") or "")
                ),
            )

        self.backups.backup_netbox_database(compose.project)
        self.backups.backup_netbox_workdir(compose)

    def restore_netbox_workdir(
        self,
        compose: ComposeProject,
    ) -> None:
        if self.backups.run_dir is None:
            return
        directory = (
            self.backups.run_dir
            / "compose"
            / safe_name(compose.project)
        )
        state_file = directory / "netbox-repo.json"
        archive = directory / "workdir-before-update.tar.gz"

        if not state_file.is_file():
            return

        state = json.loads(state_file.read_text(encoding="utf-8"))
        commit = str(state.get("commit") or "")
        if not commit:
            return

        print("Restoring previous NetBox working directory ...")
        self.runner.run(
            ["git", "-C", str(compose.workdir), "reset", "--hard"],
            check=False,
        )
        self.runner.run(
            [
                "git",
                "-C",
                str(compose.workdir),
                "checkout",
                "--detach",
                commit,
            ],
            check=True,
        )

        if archive.is_file():
            with tarfile.open(archive, "r:gz") as tar:
                safe_extract_tar(tar, compose.workdir)

    @staticmethod
    def ensure_netbox_configuration_permissions(workdir: Path) -> None:
        config_dir = workdir / "configuration"
        if not config_dir.is_dir():
            return

        if os.geteuid() == 0:
            for root, dirs, files in os.walk(config_dir):
                os.chown(root, -1, 0)
                os.chmod(root, 0o750)
                for name in dirs:
                    path = os.path.join(root, name)
                    os.chown(path, -1, 0)
                    os.chmod(path, 0o750)
                for name in files:
                    path = os.path.join(root, name)
                    os.chown(path, -1, 0)
                    os.chmod(path, 0o640)
        else:
            for root, dirs, files in os.walk(config_dir):
                os.chmod(root, os.stat(root).st_mode | 0o055)
                for name in dirs:
                    path = os.path.join(root, name)
                    os.chmod(path, os.stat(path).st_mode | 0o055)
                for name in files:
                    path = os.path.join(root, name)
                    os.chmod(path, os.stat(path).st_mode | 0o044)

    def prepare_netbox_custom_files(
        self,
        workdir: Path,
        *,
        series: str,
        current_app: str,
        target_app: str,
        current_support: str,
        target_support: str,
    ) -> None:
        candidates: List[Path] = []
        for pattern in (
            "Dockerfile*",
            "docker-compose*.yml",
            "docker-compose*.yaml",
        ):
            candidates.extend(workdir.glob(pattern))
            candidates.extend(workdir.glob(f"*/{pattern}"))

        unique = sorted({path for path in candidates if path.is_file()})

        latest_pattern = re.compile(
            r"^\s*FROM\s+(?:[^/\s]+/)?netboxcommunity/netbox:latest(?:\s|$)",
            re.MULTILINE,
        )

        for path in unique:
            text = path.read_text(encoding="utf-8")
            if latest_pattern.search(text):
                raise AppError(
                    f"{path} uses netboxcommunity/netbox:latest; "
                    "automatic NetBox series upgrade is refused"
                )

        replacements = (
            (
                f"v{series}-{current_support}",
                f"v{series}-{target_support}",
            ),
            (
                f"v{current_app}-{current_support}",
                f"v{target_app}-{target_support}",
            ),
        )

        for path in unique:
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in replacements:
                new_text = new_text.replace(old, new)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")

    def wait_netbox_healthy(
        self,
        project: str,
        timeout: int = 360,
    ) -> bool:
        deadline = time.time() + timeout

        while time.time() < deadline:
            ids = self.runner.output(
                [
                    "docker",
                    "ps",
                    "-q",
                    "--filter",
                    f"label=com.docker.compose.project={project}",
                    "--filter",
                    "label=com.docker.compose.service=netbox",
                ],
                check=False,
            ).splitlines()

            if ids:
                inspect = self.docker.inspect(ids[0], refresh=True)
                state = inspect.get("State") or {}
                health = (state.get("Health") or {}).get("Status")
                if health == "healthy":
                    return True
                if not health and state.get("Running"):
                    return True

            time.sleep(2)

        return False

    def capture_netbox_diagnostics(
        self,
        compose: ComposeProject,
    ) -> None:
        directory = (
            self.backups.ensure()
            / "diagnostics"
            / safe_name(compose.project)
        )
        directory.mkdir(parents=True, exist_ok=True)

        (directory / "environment.json").write_text(
            json.dumps(
                {
                    "timestamp": now_iso(),
                    "project": compose.project,
                    "host": os.uname().nodename,
                    "script_version": SCRIPT_VERSION,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        try:
            result = self.runner.run(
                compose.command("ps", "-a"),
                cwd=compose.workdir,
                check=False,
            )
            (directory / "compose-ps.txt").write_text(
                (result.stdout or "") + (result.stderr or ""),
                encoding="utf-8",
            )
        except Exception:
            pass

        try:
            result = self.runner.run(
                compose.command("config"),
                cwd=compose.workdir,
                check=False,
            )
            (directory / "compose-config.yml").write_text(
                (result.stdout or "") + (result.stderr or ""),
                encoding="utf-8",
            )
        except Exception:
            pass

        ids = self.runner.output(
            [
                "docker",
                "ps",
                "-aq",
                "--filter",
                f"label=com.docker.compose.project={compose.project}",
            ],
            check=False,
        ).splitlines()

        for container_id in ids:
            try:
                inspect = self.docker.inspect(container_id, refresh=True)
                name = str(inspect.get("Name") or "").lstrip("/") or container_id[:12]
                (directory / f"{safe_name(name)}.inspect.json").write_text(
                    json.dumps(inspect, indent=2),
                    encoding="utf-8",
                )
                (directory / f"{safe_name(name)}.log").write_text(
                    self.docker.logs(container_id, 500),
                    encoding="utf-8",
                )
            except Exception:
                continue

        print(f"Diagnostics saved to: {directory}")

    def execute_netbox_plan(self, plan: UpdatePlan) -> bool:
        assert plan.project is not None
        compose = plan.project
        data = plan.data

        print()
        print(f"NetBox project      : {compose.project}")
        print(
            f"NetBox              : "
            f"{data['current_app']} -> {data['target_app']}"
        )
        print(
            f"netbox-docker       : "
            f"{data['current_support']} -> {data['target_support']}"
        )
        print(f"Working directory   : {compose.workdir}")

        if self.config.dry_run:
            print(f"DRY-RUN: would execute {plan.kind}: {plan.description}")
            return True

        self.backup_netbox_project(compose)

        target_tag = (
            f"v{data['series']}-{data['target_support']}"
        )
        env_override = {"VERSION": target_tag}

        if plan.kind == "netbox_repo":
            if shutil.which("git") is None:
                raise AppError("git is required for NetBox repository updates")
            if not (compose.workdir / ".git").is_dir():
                raise AppError(
                    f"NetBox directory is not a Git checkout: {compose.workdir}"
                )

            original_commit = self.runner.output(
                [
                    "git",
                    "-C",
                    str(compose.workdir),
                    "rev-parse",
                    "HEAD",
                ]
            )

            print("Fetching NetBox Docker tags ...")
            self.runner.run(
                [
                    "git",
                    "-C",
                    str(compose.workdir),
                    "fetch",
                    "--tags",
                    "origin",
                ]
            )

            target_commit = self.runner.output(
                [
                    "git",
                    "-C",
                    str(compose.workdir),
                    "rev-parse",
                    f"refs/tags/{data['target_support']}^{{commit}}",
                ],
                check=False,
            )
            if not target_commit:
                raise AppError(
                    f"netbox-docker tag {data['target_support']} not found"
                )

            dirty = self.runner.output(
                [
                    "git",
                    "-C",
                    str(compose.workdir),
                    "status",
                    "--porcelain=v1",
                ],
                check=False,
            )

            stash_ref = ""
            if dirty:
                print("Saving local NetBox customizations in Git stash ...")
                self.runner.run(
                    [
                        "git",
                        "-C",
                        str(compose.workdir),
                        "stash",
                        "push",
                        "--include-untracked",
                        "-m",
                        (
                            f"docker-check-updates {SCRIPT_VERSION} "
                            f"before {data['target_support']}"
                        ),
                    ]
                )
                stash_ref = self.runner.output(
                    [
                        "git",
                        "-C",
                        str(compose.workdir),
                        "rev-parse",
                        "refs/stash",
                    ],
                    check=False,
                )

            try:
                self.runner.run(
                    [
                        "git",
                        "-C",
                        str(compose.workdir),
                        "checkout",
                        "--detach",
                        data["target_support"],
                    ]
                )

                if stash_ref:
                    print("Reapplying local NetBox customizations ...")
                    apply_result = self.runner.run(
                        [
                            "git",
                            "-C",
                            str(compose.workdir),
                            "stash",
                            "apply",
                            stash_ref,
                        ],
                        check=False,
                    )
                    if apply_result.returncode != 0:
                        raise AppError(
                            "local customizations conflict with target "
                            "netbox-docker release"
                        )

                version_file = compose.workdir / "VERSION"
                if (
                    not version_file.is_file()
                    or version_file.read_text(encoding="utf-8").strip()
                    != data["target_support"]
                ):
                    raise AppError(
                        "NetBox checkout VERSION does not match target support"
                    )

                self.prepare_netbox_custom_files(
                    compose.workdir,
                    series=data["series"],
                    current_app=data["current_app"],
                    target_app=data["target_app"],
                    current_support=data["current_support"],
                    target_support=data["target_support"],
                )
                self.ensure_netbox_configuration_permissions(compose.workdir)

                self.compose_run(
                    compose,
                    "config",
                    env_overrides=env_override,
                )
                print("Building NetBox custom image ...")
                self.compose_run(
                    compose,
                    "build",
                    "--pull",
                    env_overrides=env_override,
                )
            except Exception:
                self.restore_netbox_workdir(compose)
                raise

        else:
            self.prepare_netbox_custom_files(
                compose.workdir,
                series=data["series"],
                current_app=data["current_app"],
                target_app=data["target_app"],
                current_support=data["current_support"],
                target_support=data["target_support"],
            )
            self.ensure_netbox_configuration_permissions(compose.workdir)

            self.compose_run(
                compose,
                "config",
                env_overrides=env_override,
            )
            print("Building NetBox custom image ...")
            self.compose_run(
                compose,
                "build",
                "--pull",
                env_overrides=env_override,
            )

        print("Applying NetBox Compose project update ...")
        result = self.compose_run(
            compose,
            "up",
            "-d",
            env_overrides=env_override,
            check=False,
        )

        self.docker.invalidate()

        if result.returncode != 0:
            self.capture_netbox_diagnostics(compose)
            raise AppError("Docker Compose failed while applying NetBox update")

        if not self.wait_netbox_healthy(compose.project):
            self.capture_netbox_diagnostics(compose)
            raise AppError("NetBox did not become healthy after update")

        ids = self.runner.output(
            [
                "docker",
                "ps",
                "-q",
                "--filter",
                f"label=com.docker.compose.project={compose.project}",
                "--filter",
                "label=com.docker.compose.service=netbox",
            ],
            check=False,
        ).splitlines()

        if ids:
            inspect = self.docker.inspect(ids[0], refresh=True)
            new_image_id = str(inspect.get("Image") or "")
            new_app, _support = self.versions.netbox_versions(new_image_id)
            print(f"NetBox running version: {new_app}")
            if (
                data["target_app"] not in ("", "unknown")
                and new_app not in ("unknown", data["target_app"])
            ):
                raise AppError(
                    f"NetBox version validation failed: "
                    f"expected {data['target_app']}, found {new_app}"
                )

        print("NetBox project updated successfully.")
        if self.backups.run_dir:
            print(f"Backup: {self.backups.run_dir}")
        return True

    def execute_plans(self) -> None:
        if not self.config.update:
            return

        if self.plans:
            self.phase(f"Applying {len(self.plans)} local update plan(s)")
        else:
            self.progress("\n==> No local Docker/Compose updates to apply")

        for plan in list(self.plans.values()):
            if not self.confirm(f"Apply update: {plan.description}?"):
                self.summary.updates_skipped += plan.count
                continue

            try:
                if plan.kind == "compose":
                    ok = self.execute_compose_plan(plan)
                elif plan.kind in ("netbox_repo", "netbox_rebuild"):
                    ok = self.execute_netbox_plan(plan)
                else:
                    raise AppError(f"unknown update plan kind: {plan.kind}")

                if ok:
                    self.summary.updates_applied += plan.count
            except Exception as exc:
                print(
                    f"ERROR: update failed: {plan.description}: {exc}",
                    file=sys.stderr,
                )
                self.summary.errors += 1
                self.summary.updates_skipped += plan.count

    def restore_netbox_repositories(self, backup_dir: Path) -> None:
        compose_root = backup_dir / "compose"
        if not compose_root.is_dir():
            return

        states: List[Tuple[Path, Dict[str, str]]] = []

        for state_file in compose_root.glob("*/netbox-repo.json"):
            try:
                state_raw = json.loads(state_file.read_text(encoding="utf-8"))
                state = {
                    "project": str(state_raw.get("project") or ""),
                    "workdir": str(state_raw.get("workdir") or ""),
                    "commit": str(state_raw.get("commit") or ""),
                    "ref": str(state_raw.get("ref") or ""),
                }
                states.append((state_file, state))
            except Exception:
                continue

        # Compatibility with backups created by the v2/v3 Bash implementation.
        for state_file in compose_root.glob("*/netbox-repo.state"):
            try:
                line = state_file.read_text(encoding="utf-8").splitlines()[0]
                project, workdir, commit, ref = (line.split("\t") + ["", "", "", ""])[:4]
                states.append(
                    (
                        state_file,
                        {
                            "project": project,
                            "workdir": workdir,
                            "commit": commit,
                            "ref": ref,
                        },
                    )
                )
            except Exception:
                continue

        for state_file, state in states:
            workdir = Path(state["workdir"])
            commit = state["commit"]
            if not workdir.is_dir() or not (workdir / ".git").is_dir() or not commit:
                continue

            print(
                f"Restoring NetBox repository for project "
                f"{state.get('project') or workdir.name} ..."
            )
            self.runner.run(
                ["git", "-C", str(workdir), "reset", "--hard"],
                check=False,
            )
            self.runner.run(
                [
                    "git",
                    "-C",
                    str(workdir),
                    "checkout",
                    "--detach",
                    commit,
                ],
                check=False,
            )

            archive = state_file.parent / "workdir-before-update.tar.gz"
            if archive.is_file():
                with tarfile.open(archive, "r:gz") as tar:
                    safe_extract_tar(tar, workdir)

    def load_backup_manifest(self, backup_dir: Path) -> List[Dict[str, Any]]:
        manifest_json = backup_dir / "manifest.json"
        if manifest_json.is_file():
            value = json.loads(manifest_json.read_text(encoding="utf-8"))
            if not isinstance(value, list):
                raise AppError(f"invalid JSON manifest: {manifest_json}")
            return value

        # Compatibility with v2/v3 Bash backups.
        manifest_tsv = backup_dir / "manifest.tsv"
        if not manifest_tsv.is_file():
            raise AppError(f"invalid backup: {backup_dir}")

        lines = manifest_tsv.read_text(encoding="utf-8").splitlines()
        if not lines:
            raise AppError(f"empty backup manifest: {manifest_tsv}")

        header = lines[0].split("\t")
        rows: List[Dict[str, Any]] = []

        for line in lines[1:]:
            if not line.strip():
                continue
            values = line.split("\t")
            values.extend([""] * (len(header) - len(values)))
            raw = dict(zip(header, values))

            project = raw.get("project", "")
            service = raw.get("service", "")
            workdir = raw.get("workdir", "")

            compose: Optional[Dict[str, Any]] = None
            if project and service and workdir:
                compose = {
                    "project": project,
                    "service": service,
                    "workdir": workdir,
                    "config_files": [],
                }

            rows.append(
                {
                    "name": raw.get("container_name", ""),
                    "container_id": raw.get("container_id", ""),
                    "image_ref": raw.get("image_ref", ""),
                    "image_id": raw.get("image_id", ""),
                    "compose": compose,
                }
            )

        return rows

    def rollback(self, backup_dir: Path) -> None:
        manifest = self.load_backup_manifest(backup_dir)

        self.restore_netbox_repositories(backup_dir)

        for image_tar in sorted((backup_dir / "images").glob("*.tar")):
            print(f"Loading image backup: {image_tar.name}")
            self.docker.image_load(image_tar)

        recreated: Set[str] = set()

        for entry in manifest:
            image_id = str(entry.get("image_id") or "")
            image_ref = str(entry.get("image_ref") or "")
            if not image_id or not image_ref:
                continue

            try:
                self.docker.image_inspect(image_id, refresh=True)
            except Exception:
                print(
                    f"WARNING: missing saved image {image_id} "
                    f"for {entry.get('name')}",
                    file=sys.stderr,
                )
                continue

            self.docker.tag(image_id, image_ref)

            compose_data = entry.get("compose")
            if not compose_data:
                continue

            key = (
                f"{compose_data['project']}:{compose_data['service']}"
            )
            if key in recreated:
                continue
            recreated.add(key)

            compose = ComposeProject(
                project=str(compose_data["project"]),
                service=str(compose_data["service"]),
                workdir=Path(str(compose_data["workdir"])),
                config_files=[
                    Path(str(x))
                    for x in compose_data.get("config_files") or []
                ],
            )

            if not compose.workdir.is_dir():
                print(
                    f"WARNING: Compose workdir missing: {compose.workdir}",
                    file=sys.stderr,
                )
                continue

            self.compose_run(
                compose,
                "up",
                "-d",
                "--no-deps",
                "--force-recreate",
                "--pull",
                "never",
                compose.service,
                check=False,
            )

        print("Image/configuration rollback completed.")
        print(
            "IMPORTANT: database migrations, named volumes and bind-mount "
            "data are not automatically restored."
        )

        database_dir = backup_dir / "database"
        if database_dir.is_dir() and any(database_dir.glob("*.dump")):
            print(f"Database dump(s) available under: {database_dir}")

    def run_portainer(self) -> None:
        if self.config.portainer_enabled:
            self.phase("Checking Portainer remote Agents")

        manager = PortainerManager(
            self.config,
            self.docker,
            self.runner,
            self.backups,
            self.summary,
        )
        try:
            manager.check_and_update(self.confirm)
        except PortainerError as exc:
            print(f"ERROR: Portainer integration failed: {exc}", file=sys.stderr)
            self.summary.errors += 1

    def print_summary(self) -> None:
        if self.config.json_output:
            payload = {
                "version": SCRIPT_VERSION,
                "containers": [asdict(record) for record in self.records],
                "summary": asdict(self.summary),
                "plans": [
                    {
                        "kind": plan.kind,
                        "key": plan.key,
                        "description": plan.description,
                        "count": plan.count,
                    }
                    for plan in self.plans.values()
                ],
                "backup_dir": (
                    str(self.backups.run_dir)
                    if self.backups.run_dir
                    else None
                ),
            }

            for record in payload["containers"]:
                compose = record.get("compose")
                if compose:
                    compose["workdir"] = str(compose["workdir"])
                    compose["config_files"] = [
                        str(x) for x in compose["config_files"]
                    ]

            print(json.dumps(payload, indent=2, default=str))
            return

        print()
        print("=" * 120)
        print(" SUMMARY")
        print("=" * 120)
        print(f"Up to date                  : {self.summary.up_to_date}")
        print(f"Updates found               : {self.summary.updates_found}")
        print(f"Updates applied             : {self.summary.updates_applied}")
        print(f"Updates skipped             : {self.summary.updates_skipped}")
        print(f"Local/build images          : {self.summary.local_builds}")
        print(f"NetBox custom containers    : {self.summary.netbox_custom}")
        print(f"NetBox repo updates needed  : {self.summary.netbox_repo_updates}")
        print(f"Portainer outdated Agents   : {self.summary.portainer_outdated}")
        print(f"Portainer Agents updated    : {self.summary.portainer_updated}")
        print(f"Portainer Agents skipped    : {self.summary.portainer_skipped}")
        print(f"Errors                      : {self.summary.errors}")

        if self.backups.run_dir:
            print(f"Backup created at           : {self.backups.run_dir}")

    def run(self) -> int:
        self.docker.validate()

        if self.config.rollback_dir:
            self.rollback(self.config.rollback_dir)
            return 0

        if not self.config.json_output:
            print(
                "WARNING: keep a tested backup of application data "
                "before updating containers."
            )

        self.progress("\n==> Starting Docker update check")
        self.discover_and_analyze()

        if self.config.backup_only and not self.config.update:
            self.backup_all()
            self.print_summary()
            return 0 if self.summary.errors == 0 else 1

        self.execute_plans()
        self.run_portainer()
        self.backups.finalize()
        self.print_summary()

        return 0 if self.summary.errors == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description=(
            "Check/update Docker containers, Docker Compose services, "
            "NetBox Docker, and supported Portainer Agents."
        ),
    )

    parser.add_argument("--all", action="store_true", help="include stopped containers")
    parser.add_argument("--update", action="store_true", help="apply supported updates")
    parser.add_argument(
        "--yes",
        "-y",
        action="store_true",
        help="do not ask for update confirmation",
    )
    parser.add_argument(
        "--backup",
        action="store_true",
        help="create backup without updating",
    )
    parser.add_argument(
        "--backup-volumes",
        action="store_true",
        help="also archive named Docker volumes",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="disable generic pre-update backup (NetBox still forces backup)",
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        default=DEFAULT_BACKUP_ROOT,
        help=f"backup root (default: {DEFAULT_BACKUP_ROOT})",
    )
    parser.add_argument(
        "--rollback",
        type=Path,
        metavar="DIR",
        help="restore images/configuration from a backup directory",
    )

    parser.add_argument(
        "--no-portainer",
        action="store_true",
        help="disable Portainer remote-Agent checks",
    )
    parser.add_argument(
        "--portainer-url",
        default=os.environ.get("PORTAINER_URL", ""),
        help="override Portainer base URL",
    )
    parser.add_argument(
        "--portainer-token-file",
        type=Path,
        default=Path(
            os.environ.get(
                "PORTAINER_TOKEN_FILE",
                str(DEFAULT_PORTAINER_TOKEN),
            )
        ),
        help=f"Portainer API token file (default: {DEFAULT_PORTAINER_TOKEN})",
    )
    parser.add_argument(
        "--portainer-insecure",
        action="store_true",
        help="disable TLS certificate verification for Portainer API",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show planned update actions without executing them",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print machine-readable JSON summary",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="show local commands as they are executed",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"{SCRIPT_NAME} v{SCRIPT_VERSION} ({SCRIPT_DATE})",
    )

    return parser


def config_from_args(args: argparse.Namespace) -> Config:
    insecure: Optional[bool] = True if args.portainer_insecure else None

    return Config(
        all_containers=args.all,
        update=args.update,
        assume_yes=args.yes,
        backup_only=args.backup,
        backup_volumes=args.backup_volumes,
        no_backup=args.no_backup,
        rollback_dir=args.rollback,
        backup_root=args.backup_dir,
        portainer_enabled=not args.no_portainer,
        portainer_url=args.portainer_url,
        portainer_token_file=args.portainer_token_file,
        portainer_insecure=insecure,
        dry_run=args.dry_run,
        verbose=args.verbose,
        json_output=args.json,
    )


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.json and args.update:
        parser.error("--json cannot be combined with --update")

    config = config_from_args(args)

    try:
        app = Application(config)
        return app.run()
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130
    except AppError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"UNEXPECTED ERROR: {exc}", file=sys.stderr)
        if config.verbose:
            import traceback

            traceback.print_exc()
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
