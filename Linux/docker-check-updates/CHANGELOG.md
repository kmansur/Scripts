# Changelog

All notable changes to this project are documented here.

The project follows Semantic Versioning.

## [4.0.0-rc.4] - 2026-09-19

### Changed

- Replaced direct remote helper container start/recreate operations with a temporary Portainer Compose stack.
- The temporary helper stack is deployed while the existing Agent is still connected, then performs the Agent Compose update locally through the host Docker socket.
- The helper runs with `network_mode: none`; the exact target `portainer/agent:<server-version>` and `docker:cli` images are pre-pulled before the Agent restart.
- Moving tags such as `sts`, `lts` and `latest` are pointed locally at the already pre-pulled exact target image and the Agent service is recreated with `--pull never`.
- Removed the runtime `apk add docker-cli-compose` path because the official `docker:cli` image already contains the Compose plugin.

### Added

- Live progress output during Docker discovery and registry checks.
- Explicit 7-step progress for each Portainer Agent update.
- Periodic Agent reconnect/version status while waiting for the update.
- Temporary Portainer stack cleanup after commit or successful rollback.

### Fixed

- Avoids the Portainer raw Docker proxy error on `POST /containers/{id}/start`.
- Avoids Portainer's generic container recreate failure on helper containers with an empty network ID.
- Keeps the update helper independent of network access once it starts.

### Safety

- The temporary helper is deployed before the managed Agent is touched.
- The exact target Agent image is pre-pulled before update.
- No commit marker means the helper restores the previous Agent image/Compose state.
- If the environment is still unreachable, the temporary stack is left in place rather than being force-removed while rollback may still be running.

## [4.0.0-rc.3] - 2026-09-19

### Fixed

- Portainer remote update helpers are now started through Portainer's native non-proxied recreate API:
  `POST /api/docker/{environmentId}/containers/{containerId}/recreate`.
- This route is present in Portainer 2.45.1 and uses Portainer's internal Docker client, avoiding the raw Docker proxy `/containers/{id}/start` body incompatibility seen with the remote Docker API.
- The helper container ID returned by Portainer recreate is captured and used for the later commit signal, logs, status checks and cleanup.
- Failed native recreate attempts still clean the original helper container when it remains present.

### Notes

- The two rc.1/rc.2 failed attempts occurred before the helper executed, so they did not run the remote Compose Agent replacement.
- Stale Created/Exited DCU helpers continue to be cleaned before each new attempt.

## [4.0.0-rc.2] - 2026-09-19

### Fixed

- Portainer remote Docker `POST /containers/{id}/start` requests now send an explicitly empty body with `Content-Length: 0`, avoiding Docker API rejection:
  `starting container with non-empty request body was deprecated since API v1.22 and removed in v1.24`.
- A helper container that cannot be started is now removed automatically.
- Before a new Agent update attempt, stale DCU helper containers in Created/Exited/Dead state are automatically removed.
- Running DCU helpers are never removed automatically because they may still be inside their safety/rollback window.
- Supported Portainer update execution failures are now counted as errors instead of being reported as skipped environments.

### Safety

- The rc.2 cleanup only targets containers whose names begin with `dcu-portainer-agent-` or `dcu-portainer-compose-agent-`.
- The failed rc.1 start attempt does not change the Agent or Compose service because the remote helper never started.

## [4.0.0-rc.1] - 2026-09-19

### Added

- Complete single-file Python implementation: `docker-check-updates.py`.
- Python 3.9+ standard-library-only runtime; no `pip` dependencies.
- Explicit execution pipeline:
  - DISCOVER
  - ANALYZE
  - PLAN
  - BACKUP
  - EXECUTE
  - VALIDATE
  - COMMIT / ROLLBACK
- Structured internal components for Docker, image/version inspection, backup, NetBox and Portainer.
- `--dry-run` for safe update planning without service recreation.
- `--verbose` for local command tracing.
- `--json` for machine-readable check output.
- Safe handling of stopped containers when `--all` is used: stopped containers are reported but not automatically started by an update.
- Native JSON backup manifest.
- Rollback compatibility with Bash v2/v3 `manifest.tsv` and `netbox-repo.state` backups.
- Portainer Agent handling directly in the Python process using `urllib`; no separate helper file.
- Support for Docker Compose-managed Portainer Agents using:
  - fixed version tags;
  - moving tags `sts`, `lts`, and `latest`.
- Portainer remote Agent two-phase commit/rollback logic.
- NetBox diagnostics capture and post-update health/version validation.

### Changed

- v4 is a rewrite rather than an incremental translation of the Bash control flow.
- Docker/Compose/Git remain external native commands invoked through `subprocess`; no Docker SDK dependency is introduced.
- NetBox repository updates continue to be restricted to the compatible support release within the current NetBox major/minor series.
- NetBox configuration permissions are normalized before Compose validation/build.
- Portainer API tokens remain central-only and are never copied to Agent hosts.

### Compatibility

- Bash **v3.0.1** remains available as the stable fallback during release-candidate validation.
- v4 uses a different executable name, so both versions can coexist:
  - `docker-check-updates.sh`
  - `docker-check-updates.py`
- Existing Bash backups remain readable by the Python rollback implementation.
- `--json` is check-only in rc.1 and cannot be combined with `--update`.

### Safety

- v4.0.0-rc.1 should initially be tested with `--all` and `--update --yes --dry-run` before applying production updates.
- NetBox upgrades still force backup creation.
- Database dump restoration remains manual.
- Unsupported Portainer Edge/Kubernetes/Swarm layouts remain report-only.

## [3.0.1] - 2026-09-18

### Fixed

- Portainer Agent rollback now recreates the previous Compose service with `--pull never`, preventing a moving tag such as `sts`, `lts`, or `latest` from being pulled again during recovery.
- This makes rollback deterministic after the previous image ID has been restored to the original moving tag.

## [3.0.0] - 2026-09-18

### Changed

- Consolidated the project into a **single executable file**: `docker-check-updates.sh`.
- Embedded the Portainer remote-Agent Python module inside the Bash script.
- Removed the runtime requirement to install `portainer-agent-manager.py` separately.
- The Portainer API token workflow remains unchanged and is required only on the central host running the script.

### Added

- Portainer Compose Agent support for moving tags:
  - `portainer/agent:sts`
  - `portainer/agent:lts`
  - `portainer/agent:latest`
- Moving-tag updates keep the Compose source unchanged and perform `pull + force-recreate`.
- The previous moving-tag image is retained under a `dcu-backup-*` tag for recovery.
- Automatic rollback reassigns the previous image to the moving tag and recreates the previous Agent if the new Agent does not reconnect at the exact Portainer Server version.
- Fixed-tag Compose Agent updates continue to back up and update Compose source files.
- CI now extracts and syntax-checks the embedded Python module in addition to validating the Bash script.

### Migration

Existing installations only need to update one file:

```bash
wget -O /usr/local/scripts/docker-check-updates.sh \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.sh
chmod 755 /usr/local/scripts/docker-check-updates.sh
```

The old standalone helper can be removed:

```bash
rm -f /usr/local/scripts/portainer-agent-manager.py
```

### Safety

- Remote Agent updates still use a two-phase confirmation model.
- The update is committed only after Portainer reports the exact target Agent version.
- Edge Agent, Kubernetes Agent and Swarm-managed deployments remain report-only.
- Unsupported Compose layouts are skipped rather than being modified heuristically.

## [2.3.0] - 2026-09-18

### Added

- Automatic update support for Portainer Agents managed by Docker Compose.
- Compose metadata validation using the container's `com.docker.compose.*` labels.
- Remote Compose source-file backup using `.dcu-backup-*` files.
- Exact fixed-tag update from the installed Agent version to the Portainer Server version.
- Compose configuration validation before recreating the Agent service.
- Automatic Compose rollback if the updated Agent does not reconnect before the safety timeout.

### Safety

- Compose auto-update requires a fixed Agent image tag matching the installed Agent version.
- Compose config files outside the reported working directory are skipped.
- Environment files outside the reported working directory are skipped.
- Swarm, Edge Agent and Kubernetes Agent deployments remain report-only.
- The Compose helper never converts a Compose-managed Agent into a standalone container.

### Requirements

- The remote Compose helper uses `docker:cli` and installs Alpine `docker-cli-compose` when needed, requiring outbound access to the Alpine package repository during that update path.

## [2.2.0] - 2026-09-18

### Added

- Optional Portainer remote-Agent integration through the Portainer HTTP API.
- Companion `portainer-agent-manager.py` helper using only the Python standard library.
- Automatic discovery of a locally published Portainer API endpoint.
- Secure Portainer API token-file support; the token is never accepted as a command-line argument.
- Reporting of environments that Portainer marks as using outdated Agents.
- Safe automatic updates for supported Docker Standalone Portainer Agent containers.
- Two-phase remote Agent replacement using a temporary `docker:cli` helper on the remote host.
- Automatic rollback to the previous Agent if the new Agent cannot remain running/reconnect before the safety timeout.
- Remote Agent inspection/configuration metadata stored under the normal backup root.
- Previous Agent container retained stopped after a successful upgrade as an additional rollback point.
- Portainer Agent counters in the final summary.
- CLI options:
  - `--no-portainer`
  - `--portainer-url`
  - `--portainer-token-file`
  - `--portainer-insecure`

### Safety

- Automatic Agent replacement is limited to plain Docker Standalone Agent containers with the standard Docker socket bind.
- Docker Compose-managed, Swarm-managed, Edge Agent, Kubernetes Agent, multi-network and unsupported mount profiles are detected and skipped instead of being recreated generically.
- The target Agent image version is matched to the running Portainer Server version.

### CI

- Added Python syntax validation for `portainer-agent-manager.py`.

## [2.1.2] - 2026-09-18

### Fixed

- Removed the global `umask 077`, which could cause files recreated by Git during a NetBox repository checkout to become unreadable by the NetBox container.
- NetBox configuration bind-mount permissions are now normalized before Compose validation/build:
  - directories: `750`
  - files: `640`
  - group: GID 0 when the script runs as root
- Backup confidentiality is preserved by setting the backup root/run directory to mode `700` instead of changing the process-wide umask.

### Impact

This fixes NetBox startup failures such as:

```text
PermissionError: [Errno 13] Permission denied: '/etc/netbox/config/configuration.py'
```

## [2.1.0] - 2026-09-18

### Added

- Automatic update of a compatible `netbox-docker` support checkout when `--update` is used.
- Exact-tag checkout for NetBox Docker support releases, such as `5.0.2`.
- Backup of the complete NetBox Compose project before a repository update.
- Backup archive of the NetBox working directory, excluding `.git`.
- Git commit/status capture for NetBox rollback and troubleshooting.
- Preservation of local tracked and untracked NetBox customizations using a safety stash.
- Automatic update of explicit custom-image version references in Dockerfiles and Compose overrides.
- NetBox health check after project recreation.
- NetBox repository restoration support in `--rollback`.

### Changed

- NetBox actions are deferred until the full container scan completes and are applied once per Compose project.
- NetBox repository upgrades always create a backup, even when `--no-backup` is used for generic container updates.
- NetBox upgrades remain limited to the currently configured major/minor series.
- A custom Dockerfile using `netboxcommunity/netbox:latest` is rejected during automated NetBox updates to prevent an unintended series jump.

### Fixed

- Removed the stale localization/summary block left behind by the v2.0.0 English-only refactor.
- Avoided recreating the first NetBox container while the scan still held IDs for the worker and housekeeping containers.

### Safety

- If local customizations conflict with the target NetBox Docker support tag, the script aborts before changing running containers and restores the previous working tree.
- Database rollback remains manual because application migrations may not be safely reversible by simply restoring a container image.

## [2.0.0] - 2026-09-18

### Changed

- The project now ships a single English-only executable.
- Brazilian Portuguese is maintained as documentation only in `README.pt-BR.md`.
- Removed the PT-BR launcher and runtime language-selection code to keep the implementation smaller and easier to maintain.

### Removed

- `docker-check-updates.pt-BR.sh`.
- `--lang` command-line option and `DCU_LANG` runtime localization.

### Compatibility

- Docker checking, Compose update, backup, rollback and NetBox handling behavior remain unchanged from v1.4.0.
- This is a major-version change because previously documented command-line/language interfaces were removed.

## [1.4.0] - 2026-09-18

### Added

- English primary interface.
- PT-BR launcher and documentation while keeping one implementation.
- Automatic pre-update backup for Docker Compose services.
- `--backup` standalone backup mode.
- `--backup-volumes` optional named-volume archives.
- `--backup-dir`.
- `--rollback <directory>`.
- `--no-backup` explicit administrative override.
- Backup manifest with container, image and Compose information.
- Previous-image archives using `docker image save`.
- Best-effort NetBox PostgreSQL `pg_dump`.
- MIT license and development/safety notices.

### Changed

- NetBox custom images are detected before generic registry handling.
- NetBox version detection first uses inherited `netbox.original-tag`, then image release metadata.
- NetBox Docker support version and NetBox application version are treated separately.
- NetBox custom rebuild is allowed only when the local `netbox-docker` checkout support version matches the target support version.
- Generic local images are reported as `LOCAL BUILD` when appropriate.

### Fixed

- Fixed v1.3.0 reporting NetBox Docker `5.0.1` as if it were the NetBox application version.
- Fixed attempts to pull `netbox-custom:*` directly from a registry.
- Fixed repeated NetBox pull errors for locally built custom images.

### Safety

- Rollback intentionally does not restore databases, named volumes or bind mounts automatically.
- Database migrations may make image-only rollback insufficient.

## [1.3.0] - 2026-09-18

### Added

- Initial special handling for NetBox custom images.
- NetBox Docker support-version change detection.
- NetBox same-series lookup.

### Known issues

- Could still classify `netbox-custom:*` as a pull error in some paths.
- Could display NetBox Docker support version as application version.

## [1.2.0] - 2026-09-18

### Added

- Local/build image detection.
- Uptime Kuma and Portainer version detection.
- Initial NetBox custom-image support.
- `--version`.

## [1.1.0] - 2026-09-18

### Added

- `--update` mode.
- Interactive confirmation.
- Docker Compose service recreation.

## [1.0.0] - 2026-09-18

### Added

- Initial update checking by Docker Image ID.
