# Docker Check Updates

> **Development status:** this project is under active development. Use it at your own risk.
>
> **Backup warning:** always keep a tested backup of your Docker applications and their persistent data before applying updates. Container image rollback does **not** automatically reverse database migrations or application data changes.

`docker-check-updates` is a Bash utility that checks whether Docker containers have newer images available and can optionally update services managed by Docker Compose.

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
- Can safely update supported Docker Standalone Portainer Agents to the same version as the Portainer Server.
- English-only command-line interface with documentation in English and Brazilian Portuguese.

## Requirements

- Linux
- Bash 4+
- Docker Engine
- Docker Compose plugin (`docker compose`) for update operations
- Git for automatic `netbox-docker` repository updates
- Permission to access the Docker daemon
- Helper image `alpine:3.20` when `--backup-volumes` is used
- Python 3 (standard library only) for the optional Portainer remote-Agent integration

The core Docker/NetBox checker does not require `jq` or Python. Python 3 is only required when Portainer remote-Agent integration is enabled.

## Installation

With `wget`:

```bash
sudo wget -O /usr/local/sbin/docker-check-updates.sh \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.sh

sudo wget -O /usr/local/sbin/portainer-agent-manager.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/portainer-agent-manager.py

sudo chmod 755 /usr/local/sbin/docker-check-updates.sh
sudo chmod 755 /usr/local/sbin/portainer-agent-manager.py
```

## Usage

Check running containers:

```bash
docker-check-updates.sh
```

Include stopped containers:

```bash
docker-check-updates.sh --all
```

Check and interactively update Docker Compose services:

```bash
docker-check-updates.sh --update
```

Update without confirmation prompts:

```bash
docker-check-updates.sh --update --yes
```

> `--update --yes` is intended for controlled automation. A backup is still created unless `--no-backup` is specified.

## Backup

Create a backup without updating anything:

```bash
docker-check-updates.sh --all --backup
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
docker-check-updates.sh --backup --backup-dir /backup/docker
```

### Named volumes

Also archive named volumes:

```bash
docker-check-updates.sh --all --backup --backup-volumes
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
docker-check-updates.sh --rollback /var/backups/docker-check-updates/20260918-203000
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

Portainer recommends keeping the Agent version aligned with the Portainer Server version. The optional Portainer integration queries the Portainer API for environments reported as outdated and adds them to the update report.

### One-time API token setup

Create an API access token in Portainer under **My account → Access tokens** and store it on the Docker host:

```bash
sudo install -d -m 700 /etc/docker-check-updates
sudo install -m 600 /dev/null /etc/docker-check-updates/portainer-api-token
sudo sh -c 'printf "%s\n" "PASTE_PORTAINER_API_TOKEN_HERE" > /etc/docker-check-updates/portainer-api-token'
```

The token is read from:

```text
/etc/docker-check-updates/portainer-api-token
```

The token is never accepted as a command-line argument.

When Portainer is running on the same Docker host, the script automatically discovers the published HTTPS port. An explicit URL can also be provided:

```bash
docker-check-updates.sh \
  --portainer-url https://portainer.example.com:9443
```

For a self-signed certificate on an explicitly configured URL:

```bash
docker-check-updates.sh \
  --portainer-url https://portainer.example.com:9443 \
  --portainer-insecure
```

Disable Portainer checks completely with:

```bash
docker-check-updates.sh --no-portainer
```

### Agent checking

Normal check mode also reports outdated remote Agents:

```bash
docker-check-updates.sh --all
```

Example:

```text
PORTAINER REMOTE AGENTS
ENVIRONMENT                    TYPE             INSTALLED      REQUIRED       STATUS
docker-01                      Docker Agent     2.38.1         2.39.0         UPDATE
docker-02                      Docker Agent     2.38.1         2.39.0         UPDATE
```

### Agent updates

With `--update`, a supported Docker Standalone Agent can be upgraded to exactly the Portainer Server version:

```bash
docker-check-updates.sh --update
```

Or, for unattended confirmation:

```bash
docker-check-updates.sh --update --yes
```

Automatic Agent replacement is intentionally limited to a conservative profile:

- Portainer environment type: Docker Agent;
- exactly one `portainer/agent` container;
- Agent container is not Docker Compose managed;
- Agent container is not a Docker Swarm service;
- the standard `/var/run/docker.sock` bind is present;
- no unsupported multi-network or mount configuration is detected.

Edge Agents, Kubernetes Agents and Swarm-managed Agents are reported but are not generically recreated by this release.

### Remote Agent safety and rollback

Before replacement, the tool stores the remote Agent inspection/configuration under the normal backup root and pre-pulls the target image.

A temporary `docker:cli` helper container is created on the remote Docker host. This helper performs the Agent replacement locally through the Docker socket, which allows the operation to continue while the Agent connection to Portainer is temporarily unavailable.

The process uses a two-phase commit:

1. the existing Agent is stopped and renamed;
2. the new Agent is started;
3. the script waits for Portainer to confirm the new Agent version;
4. only then is the update committed.

If the new Agent fails to reconnect before the safety timeout, the helper automatically removes it, renames the previous Agent back to its original name and starts it again.

After a successful update, the old Agent is intentionally retained as a stopped container named similar to:

```text
portainer_agent-dcu-backup-YYYYMMDDHHMMSS
```

This provides an additional manual rollback point. The project does not automatically delete these stopped backup containers.

## Language

The command-line interface and source code are maintained in English only.

Documentation is available in:

- [English](README.md)
- [Português do Brasil](README.pt-BR.md)

## Safety model

- No container recreation without `--update`.
- No automatic recreation of `docker run` containers.
- Automatic backup before Compose updates by default.
- `--no-backup` must be explicitly requested to disable that protection.
- NetBox Docker repository upgrades are limited to the exact support release required by the current NetBox major/minor series and always force a backup.
- No automatic database restore during rollback.
- No automatic image pruning or backup deletion.

## Versioning

This project follows Semantic Versioning:

- **MAJOR**: incompatible behavior or command-line changes.
- **MINOR**: backward-compatible functionality.
- **PATCH**: backward-compatible fixes.

Current version: **2.2.0**.

## License

MIT License. See [LICENSE](LICENSE).

MIT was selected because it is simple, permissive, widely understood for small utilities and includes a warranty/liability disclaimer.
