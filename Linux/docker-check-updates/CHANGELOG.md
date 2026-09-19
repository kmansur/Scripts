# Changelog

All notable changes to this project are documented here.

The project follows Semantic Versioning.

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
