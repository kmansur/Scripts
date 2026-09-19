# Docker Check Updates v4.0.0

Released: 2026-09-19

## Highlights

v4.0.0 promotes the Python implementation to the stable release.

The project remains a single-file deployment with no third-party Python runtime dependencies and now provides a more structured execution model:

```text
DISCOVER
  -> ANALYZE
  -> PLAN
  -> BACKUP
  -> EXECUTE
  -> VALIDATE
  -> COMMIT / ROLLBACK
```

## Major capabilities

- Live Docker update discovery in a streaming column table.
- Docker Compose service updates.
- Image/config backup and rollback.
- Optional named-volume backup.
- Backward-compatible reading of Bash v2/v3 backup manifests.
- Custom NetBox Docker update workflow.
- Portainer outdated-Agent discovery.
- Transactional update for supported Compose-managed Standard Docker Agents.
- Runtime Agent image-ID validation.
- Forced Portainer snapshot refresh after Agent replacement.
- Automatic no-commit rollback.
- JSON check output.
- Python standard library only.

## Portainer Agent validation

The Portainer remote-Agent workflow was exercised in production with Portainer Server 2.45.1:

1. Agent 2.45.0 -> 2.45.1 successful.
2. A second Agent failed validation and rolled back automatically to 2.45.0.
3. Runtime image-ID validation and forced Portainer snapshot refresh were added.
4. The second Agent then completed 2.45.0 -> 2.45.1 successfully.
5. Final result: both tested Agents reported 2.45.1.

## Safety hardening

Before the stable release:

- fixed-tag Compose rewriting now requires exactly one literal image reference;
- file write-back avoids `sed -i` and preserves the original file metadata/inode;
- Compose identifiers are validated before helper-shell construction;
- helper timeout is six minutes;
- rollback uses `--pull never`;
- TAR restore rejects traversal/out-of-tree links;
- Portainer Agent commit validation uses the exact pre-pulled image ID;
- the Portainer API token remains central-only.

## Portainer scope

Automatic update supports Standard Docker Agents managed by Docker Compose.

Report-only in v4.0.0:

- Standard Agents created with plain `docker run`;
- Edge Agents;
- Kubernetes Agents;
- Swarm-managed Agents.

## Upgrade from v3

Install v4 alongside v3:

```bash
wget -O /usr/local/scripts/docker-check-updates.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.py

chmod 755 /usr/local/scripts/docker-check-updates.py

/usr/local/scripts/docker-check-updates.py --version
```

Expected:

```text
docker-check-updates.py v4.0.0 (2026-09-19)
```

Bash v3.0.1 can remain installed as a legacy fallback.

## Documentation

- README.md
- README.pt-BR.md
- CHANGELOG.md
- ROADMAP.md
- ROADMAP.pt-BR.md
