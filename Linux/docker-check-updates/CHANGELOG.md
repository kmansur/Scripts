# Changelog

All notable changes to this project are documented here.

The project follows Semantic Versioning.

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
