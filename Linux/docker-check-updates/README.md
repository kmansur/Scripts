# Docker Check Updates

> **Current stable release:** **v4.0.0 (Python)**.
>
> **Legacy fallback:** **v3.0.1 (Bash)** remains in the repository for rollback/migration purposes, but the Python implementation is now the primary version.
>
> **Backup warning:** always keep a tested backup of your Docker applications and their persistent data before applying updates. Container image rollback does **not** automatically reverse database migrations or application data changes.

`docker-check-updates` is a single-file Python utility for Docker image checks, Docker Compose updates, backup/rollback, custom NetBox Docker handling, and supported Portainer remote Agent updates. It uses only the Python standard library plus the native `docker`, `docker compose`, and `git` commands.

The project is intentionally conservative: checking is the default action, updates require `--update`, containers created directly with `docker run` are never recreated automatically, and NetBox custom images receive special handling.

## Features

- Checks running containers or all containers.
- Compares the image used by a container with the latest image available for the configured tag.
- Shows installed and available versions when useful image metadata is available.
- Special version detection for Uptime Kuma and Portainer.
- Detects local/build-only images instead of reporting them as registry failures.
- Updates Docker Compose services only when explicitly requested.
- Automatically backs up the previous image and Compose metadata before an update, unless `--no-backup` is explicitly used.
- Optional named-volume archives with `--backup-volumes`.
- Rollback support for previous container images.
- Special support for custom NetBox Docker images (`netbox-custom:*`).
- Automatic, backup-first update of a compatible `netbox-docker` support checkout when a newer support release is required within the same NetBox major/minor series.
- Checks Portainer-managed remote Agents when API access is configured.
- Can transactionally update supported **Docker Compose-managed Standard Portainer Agents** to the exact Portainer Server version, with runtime image validation and rollback.
- Supports Portainer Agent moving tags such as `sts`, `lts`, and `latest` with rollback protection.
- English-only command-line interface with documentation in English and Brazilian Portuguese.

## Requirements

For **v4 Python**:

- Linux
- Python 3.9+ (standard library only)
- Docker Engine CLI
- Docker Compose plugin (`docker compose`) for Compose update operations
- Git only for automatic `netbox-docker` repository updates
- Permission to access the Docker daemon
- Helper image `alpine:3.20` only when `--backup-volumes` is used

No `pip install`, `requests`, Docker SDK, `jq`, or other Python package is required.

The Portainer API integration is implemented with Python's standard `urllib` library. The API token remains stored only on the central host running the program.

## Installation

### v4.0.0 Python

Install the stable Python implementation:

```bash
sudo wget -O /usr/local/scripts/docker-check-updates.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.py

sudo chmod 755 /usr/local/scripts/docker-check-updates.py
```

Verify:

```bash
/usr/local/scripts/docker-check-updates.py --version
```

Expected:

```text
docker-check-updates.py v4.0.0 (2026-09-19)
```

The legacy Bash v3.0.1 can coexist at:

```text
/usr/local/scripts/docker-check-updates.sh
```

New deployments should use the Python implementation.

## Usage

Check running containers:

```bash
docker-check-updates.py
```

Include stopped containers:

```bash
docker-check-updates.py --all
```

Check and interactively update Docker Compose services:

```bash
docker-check-updates.py --update
```

Update without confirmation prompts:

```bash
docker-check-updates.py --update --yes
```

> `--update --yes` is intended for controlled automation. A backup is still created unless `--no-backup` is specified.

## v4 architecture

The Python implementation separates state discovery from changes:

```text
DISCOVER
   ↓
ANALYZE
   ↓
PLAN
   ↓
BACKUP
   ↓
EXECUTE
   ↓
VALIDATE
   ↓
COMMIT / ROLLBACK
```

The main internal responsibilities are separated into:

- `DockerClient`
- `VersionInspector`
- `BackupManager`
- `PortainerClient`
- `PortainerManager`
- NetBox planning/execution inside the application orchestration layer

This remains a **single Python file** for simple installation while keeping the code organized and testable.

### Live progress output

The Python version now reports work as it happens. Docker container results are emitted directly as a live column table while discovery proceeds; the duplicated final Docker table was removed. Registry checks remain visible inline. Portainer Agent steps, helper state, reconnect status and rollback/commit progress are also streamed live.

### Portainer temporary helper stack

Compose-managed Portainer Agents are updated through a temporary Compose stack deployed by Portainer itself. This avoids direct Docker `container start/recreate` calls for the helper.

The update flow is:

1. inspect the remote Agent and Compose metadata;
2. pre-pull the exact target Agent image and `docker:cli`;
3. deploy a temporary `dcu-agent-helper-*` stack while the old Agent is still connected;
4. the helper uses the host Docker socket and the original Compose files to recreate only the Agent service;
5. wait for Portainer to report the exact target Agent version;
6. send the commit marker;
7. remove the temporary helper stack.

The helper runs with `network_mode: none`. All required images are pre-pulled before the Agent restart. The official `docker:cli` image includes the Docker Compose plugin, so the helper does not need to install packages at runtime.

If the helper exits before the Agent reaches the target version, v4.0.0 stops waiting immediately, records the helper log in the backup directory, and prints the last log lines plus the helper exit code. This avoids waiting for the full Agent timeout when the remote Compose operation has already failed.

Agent validation no longer relies only on Portainer's stored `Agent.Version`. The controller resolves the exact target image ID before the update and then verifies the running Agent container against that runtime Image ID. When the target image is running through the Agent connection, the controller also forces `POST /endpoints/{id}/snapshot` so Portainer refreshes `Agent.Version` immediately instead of waiting for the periodic snapshot cycle.

### New v4 operational options

```bash
docker-check-updates.py --dry-run --update --yes
docker-check-updates.py --verbose
docker-check-updates.py --json
```

`--dry-run --update --yes` performs discovery/planning (including image checks) but does not recreate services.

`--json` is currently check-only and cannot be combined with `--update`.

### Rollback compatibility

The Python implementation can read its native JSON backup manifests and also the `manifest.tsv` / `netbox-repo.state` format created by the v2/v3 Bash versions. This preserves access to existing recovery points during migration.

## Backup

Create a backup without updating anything:

```bash
docker-check-updates.py --all --backup
```

The default backup stores:

- `docker inspect` output;
- container name, image reference and previous Image ID;
- Docker Compose project/service metadata;
- detected Compose files, `.env` and `VERSION` when available;
- a `docker image save` archive of the previous image;
- a PostgreSQL dump for NetBox when a Compose `postgres` service is identified.

Default location:

```text
/var/backups/docker-check-updates/YYYYMMDD-HHMMSS/
```

Change the root directory:

```bash
docker-check-updates.py --backup --backup-dir /backup/docker
```

### Named volumes

Also archive named volumes:

```bash
docker-check-updates.py --all --backup --backup-volumes
```

This uses a temporary `alpine:3.20` container to create `tar.gz` archives.

**Important limitations**

- Bind mounts are not copied automatically.
- A filesystem-level volume archive may not be application-consistent for a running database.
- Keep native PostgreSQL/MySQL/MariaDB/etc. backups where applicable.
- Test restoration procedures before relying on any backup.

## Rollback

Rollback to images saved by a previous backup:

```bash
docker-check-updates.py --rollback /var/backups/docker-check-updates/20260918-203000
```

Rollback:

1. loads saved image archives;
2. re-tags the previous Image ID with the original image reference;
3. recreates the associated Docker Compose service.

Rollback does **not** automatically restore databases, named volumes or bind mounts. Restoring persistent data is an explicit administrative action because overwriting newer data can be destructive.

## NetBox Docker support

Custom images such as:

```text
netbox-custom:v4.6-5.0.1
```

are local builds and must not be handled with `docker pull netbox-custom:...`.

The script:

1. detects `netbox-custom:*` before generic registry processing;
2. reads NetBox version information from the inherited `netbox.original-tag` label when available;
3. falls back to NetBox release metadata inside the image;
4. reads the NetBox Docker support version from `/opt/netbox/VERSION` or the project's `VERSION` file;
5. checks the latest official image in the same NetBox major/minor series, for example `v4.6`;
6. rebuilds a custom image only when the local `netbox-docker` checkout is compatible with the target support version.

NetBox Docker tags such as `vX.Y.Z-a.b.c` and `vX.Y-a.b.c` combine the NetBox application version with the NetBox Docker support-file version. Those versions are intentionally treated separately.

If a newer NetBox Docker support version is required, the script reports for example:

```text
REPO 5.0.2
```

and, when `--update` is used, the script can update the local `netbox-docker` checkout to the exact required support tag (for example `5.0.2`) before rebuilding the custom image.

The NetBox repository update workflow is intentionally strict:

1. backs up every container in the NetBox Compose project;
2. saves the current images;
3. creates a PostgreSQL dump;
4. archives the NetBox working directory (excluding `.git`);
5. records the current Git commit and local changes;
6. fetches Git tags and checks out the exact required support release;
7. temporarily stashes and reapplies local tracked/untracked customizations;
8. adjusts explicit custom image references from the old support release to the new support release;
9. validates the Compose configuration;
10. rebuilds the custom NetBox image with `--pull`;
11. runs `docker compose up -d` for the project and waits for NetBox to become healthy.

If local customizations conflict with the target support release, the script aborts before changing the running containers and restores the previous working tree from the backup snapshot.

The script will not automatically jump to a different NetBox major/minor series.

### NetBox backup

Before a supported NetBox rebuild/update, the script attempts to save:

- the current custom image;
- Compose metadata/configuration;
- a PostgreSQL `pg_dump` when the Compose `postgres` service is identifiable.

A production NetBox upgrade should still have an independently tested database backup.


## Portainer remote Agent integration

The optional Portainer integration queries the Portainer API for environments that the server reports as having outdated Agents. The API token is stored only on the central host running `docker-check-updates.py`; it is never copied to remote Agent hosts.

### API token setup

Create an API access token in Portainer and store it with restricted permissions:

```bash
sudo install -d -m 700 /etc/docker-check-updates
sudo install -m 600 /dev/null /etc/docker-check-updates/portainer-api-token
sudo sh -c 'printf "%s\n" "PASTE_PORTAINER_API_TOKEN_HERE" > /etc/docker-check-updates/portainer-api-token'
```

Default token file:

```text
/etc/docker-check-updates/portainer-api-token
```

When Portainer is on the same Docker host, the script auto-detects a published 9443/9000 port. You can override the URL:

```bash
docker-check-updates.py --portainer-url https://portainer.example.com:9443
```

Use `--portainer-insecure` only when TLS verification must explicitly be disabled.

Disable Portainer integration with:

```bash
docker-check-updates.py --no-portainer
```

### Automatic Agent update support in v4.0.0

Automatic remote updates are intentionally limited to **Standard Docker Agents managed by Docker Compose** when the required Compose labels and paths can be validated safely.

Supported Compose image references:

- fixed tag matching the currently installed Agent version, such as `portainer/agent:2.45.0`;
- moving tags `portainer/agent:sts`, `portainer/agent:lts`, and `portainer/agent:latest`;
- the same forms with the `docker.io/` prefix.

The following are report-only in v4.0.0 and are **not** automatically recreated:

- Standard Docker Agents created with plain `docker run`;
- Edge Agents;
- Kubernetes Agents;
- Swarm-managed Agents.

### Transactional Compose Agent update

For a supported outdated Agent, the script:

1. inspects the remote Agent and validates the Compose project, service, working directory, and config-file paths;
2. pre-pulls the exact target `portainer/agent:<Portainer-Server-version>` image and records its image ID;
3. pre-pulls `docker:cli`;
4. asks Portainer to deploy a temporary `dcu-agent-helper-*` Compose stack while the old Agent is still connected;
5. the helper runs with `network_mode: none`, mounts only the Docker socket plus the Agent Compose working directory, and performs the change locally on the remote host;
6. for moving tags, the Compose source remains unchanged; the pre-pulled target image is assigned to the moving tag locally and the Agent service is recreated with `--pull never`;
7. for fixed tags, exactly one literal image reference must exist in the Compose files; the files are backed up and rewritten without replacing their inode/mode/ownership;
8. the controller validates the **running Agent container image ID** against the exact target image ID;
9. the controller forces a Portainer environment snapshot so `Agent.Version` is refreshed immediately;
10. only after runtime validation does it send the commit marker and remove the temporary helper stack.

If validation fails or no commit marker arrives, the helper restores the previous image/source state and recreates the previous Agent. Remote helper logs and inspection data are written beneath the normal backup tree.

This path was validated in production against Portainer Server **2.45.1**, including both a successful 2.45.0 → 2.45.1 update and an automatic rollback before the final successful retry.

### Security notes

The temporary helper has direct access to the remote Docker socket, which is equivalent to root-level Docker control on that host. It exists only for the update window and is removed after commit/rollback when the environment is reachable.

The Agent API token remains central-only. The remote helper receives no Portainer token.

Old moving-tag images are retained under `dcu-backup-*` tags as rollback points. Automatic retention/pruning of these tags is not implemented yet.

## Language

The command-line interface and source code are maintained in English only.

Documentation is available in:

- [English](README.md)
- [Português do Brasil](README.pt-BR.md)

## Safety model

- No container recreation without `--update`.
- Generic `docker run` containers are not recreated automatically. Portainer Standard Agents created with plain `docker run` are report-only in v4.0.0.
- Automatic backup before Compose updates by default.
- `--no-backup` must be explicitly requested to disable that protection.
- NetBox Docker repository upgrades are limited to the exact support release required by the current NetBox major/minor series and always force a backup.
- No automatic database restore during rollback.
- No automatic image pruning or backup deletion.

## Project status and roadmap

See [ROADMAP.md](ROADMAP.md) for the current technical status, comparison with similar Docker update tools, known limitations, and planned improvements. The production review is available in Portuguese at [REVIEW_v4.0.0.pt-BR.md](REVIEW_v4.0.0.pt-BR.md).

## Versioning

This project follows Semantic Versioning:

- **MAJOR**: incompatible behavior or command-line changes.
- **MINOR**: backward-compatible functionality.
- **PATCH**: backward-compatible fixes.

Current stable version: **4.0.0**.

Legacy Bash fallback: **3.0.1**.

## License

MIT License. See [LICENSE](LICENSE).

MIT was selected because it is simple, permissive, widely understood for small utilities and includes a warranty/liability disclaimer.
