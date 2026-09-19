# Docker Check Updates — Project Status and Roadmap

**Current stable version:** 4.0.0  
**Date:** 2026-09-19  
**Primary implementation:** `docker-check-updates.py`  
**Legacy fallback:** `docker-check-updates.sh` v3.0.1

## Current position

Docker Check Updates is an operator-oriented, single-file CLI focused on controlled Docker maintenance with minimal host dependencies.

Its current strengths are not a web dashboard or continuous daemon mode. The project is intentionally strongest in workflows that require explicit inspection, backup, validation, and rollback:

- local Docker image/update discovery;
- Docker Compose service updates;
- image/config backup and rollback;
- custom NetBox Docker update handling;
- transactional Portainer Standard Agent updates for Compose-managed Agents;
- live CLI progress and machine-readable JSON check output;
- Python standard library only; no pip packages.

## Production-validated paths

The following paths have been exercised against real environments:

- Docker image checks for running containers;
- Docker Compose metadata discovery;
- custom NetBox image/version detection;
- NetBox Docker support repository handling;
- Portainer Server 2.45.1 Agent discovery;
- Portainer Standard Docker Agent 2.45.0 → 2.45.1 through Compose;
- moving Agent tag `portainer/agent:sts`;
- temporary Portainer helper stack;
- exact runtime Agent image-ID validation;
- forced Portainer environment snapshot to refresh `Agent.Version`;
- failed Agent validation followed by automatic rollback;
- retry followed by successful commit.

## Comparison with similar tools

This table describes architectural focus, not a "winner" ranking.

| Project | Primary model | Automatic updates | Compose aware | Remote hosts | Rollback / backup focus | UI / notifications | Where Docker Check Updates differs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Docker Check Updates** | Operator CLI | Yes, selected safe paths | Yes | Portainer Agent workflow | Strong image/config + transactional Agent rollback | CLI; JSON | NetBox-specific workflow and transactional Portainer Agent maintenance |
| **WUD (What's Up Docker?)** | Long-running service | Yes | Yes | Yes | Not its main documented focus | Web UI, REST API, many triggers | Much broader continuous monitoring, semver policies, registries and notifications |
| **Dockcheck** | Interactive shell CLI | Yes | Yes | Primarily Docker hosts available to script | Image backup support | CLI, notifications, Prometheus addon | Closest operational model; Docker Check Updates adds NetBox and Portainer Agent transactions |
| **Diun** | Long-running notifier | No container replacement by design | Discovery only | Docker providers | No update rollback because it does not perform updates | Many notifications | Better reference for notification/registry detection than for update execution |
| **Drydock** | Long-running controller/UI | Yes | Yes | Distributed agents | Image backup and automatic rollback | Dashboard, REST, notifications, metrics | Broader update platform; Docker Check Updates remains a lightweight host utility |
| **Watchtower** | Long-running updater | Yes | Limited Compose semantics | Docker daemon | Limited rollback model | Notifications/hooks | Historically influential but the original repository was archived in Dec 2025 |

Reference documentation:

- WUD: https://getwud.app/docs/
- WUD Docker trigger: https://getwud.app/docs/configuration/triggers/docker/
- Dockcheck: https://github.com/mag37/dockcheck
- Diun: https://crazymax.dev/diun/
- Drydock: https://github.com/CodeSWhat/drydock
- Watchtower archive: https://github.com/containrrr/watchtower

## Current limitations

### Update detection

The current generic image check uses `docker pull` as part of update discovery. This is reliable but heavier than registry-manifest/digest-only checks and can consume registry bandwidth/rate limits.

Generic version reporting is best when the image exposes a useful OCI/version label. Otherwise the program intentionally falls back to an image-ID representation.

### Generic Docker updates

Automatic generic updates are limited to Compose-managed services.

Plain `docker run` containers are checked but are not generically recreated. This is deliberate: faithfully cloning every Docker container option is more complex than it appears and should not be enabled until the recreation specification is comprehensive and tested.

### Portainer

v4.0.0 automatically updates only Standard Docker Agents managed by Compose.

Plain-`docker run` Standard Agents, Edge Agents, Kubernetes Agents and Swarm-managed Agents are report-only.

A temporary helper stack requires Docker-socket access on the remote host. That access is powerful and should remain narrowly scoped and short-lived.

Abnormally interrupted runs can theoretically leave a `dcu-agent-helper-*` stack behind. Normal commit/rollback paths remove it.

### Backup and rollback

Image/config rollback does not automatically reverse application database migrations or restore named volumes.

Named-volume backup is opt-in.

NetBox receives stronger application-specific protection, including PostgreSQL dump and repository/workdir backup.

### Registry/authentication policy

There is no first-class registry configuration model yet for multiple private registries, credential helpers, rate-limit awareness, semver update policy, tag maturity windows, or allow/deny rules.

### Observability

There is JSON output, but no built-in Prometheus exporter, Zabbix sender mode, notification system, audit database, or persistent update history.

### Testing

CI currently covers syntax, CLI loading and targeted smoke tests. It does not yet run a full nested Docker integration lab with real Compose updates and rollback.

## Recommended roadmap

### v4.0.x — stabilization

Keep behavior conservative and avoid large new features.

Priorities:

- add tests for fixed-tag Compose rewriting;
- add tests for safe TAR extraction and malicious archive rejection;
- detect and report orphaned `dcu-agent-helper-*` stacks;
- add optional cleanup/retention for `dcu-backup-*` image tags;
- improve error categorization (unsupported vs failed vs skipped);
- add a `--portainer-only` mode for faster Agent maintenance;
- add a `--local-only` mode.

### v4.1 — policy and operator controls

Recommended additions:

- include/exclude container filters;
- label-based opt-in/opt-out;
- per-container update policy;
- update age/maturity window;
- semantic-version policy where registry tag data is available;
- configurable timeouts;
- configuration file under `/etc/docker-check-updates/`;
- maintenance windows;
- explicit `--container NAME` and `--project NAME` targeting.

### v4.2 — observability and integrations

Recommended additions:

- stable JSON schema version;
- Zabbix-friendly discovery/status output;
- optional Prometheus textfile metrics;
- notifications through webhook/email or a small extensible notifier interface;
- persistent audit log of checks, plans, updates, commits and rollbacks;
- release/changelog URL hints for known images.

### v4.3 — registry-efficient discovery

Replace unnecessary pulls during check-only operations when possible:

- OCI/Docker Registry HTTP API manifest inspection;
- digest comparison without pulling layers;
- Docker Hub/GHCR/private-registry authentication;
- rate-limit handling;
- platform-aware manifest selection;
- optional semver tag discovery.

This should remain standard-library-only if practical.

### v5 — optional modularization

The single-file distribution is useful operationally, but the source is now large enough that development would benefit from modules and tests.

A future structure could use:

```text
src/docker_check_updates/
  cli.py
  docker.py
  compose.py
  backup.py
  netbox.py
  portainer.py
  registry.py
  reporting.py
```

A build/release step could still publish one self-contained executable script if single-file deployment remains a requirement.

## Features not recommended for immediate implementation

These features are useful in other products but would move this project away from its current purpose if implemented too early:

- full web dashboard;
- user/RBAC system;
- always-running daemon as the only operating mode;
- Kubernetes workload updater;
- broad vulnerability/SBOM platform;
- replacing Portainer as a Docker management UI.

For those requirements, WUD, Drydock, Portainer, Renovate/Dependabot, Trivy/Grype and similar dedicated tools should be integrated rather than reimplemented.

## Release criteria used for v4.0.0

The stable v4.0.0 baseline requires:

- Python syntax/CLI CI passing;
- no third-party Python runtime packages;
- live Docker check output;
- backward-compatible reading of v2/v3 backup manifests;
- tested local Docker/Compose discovery;
- tested NetBox custom handling;
- tested Portainer Agent successful update;
- tested Portainer Agent rollback;
- exact runtime Agent image validation;
- documentation synchronized with actual supported behavior.

