# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.0] - 2025-10-29
### Highlights
- **Self-update is now CLI-only.** The script will **not** access `UPDATE_URL` on normal runs anymore. Updates occur only when invoked with `--self-update` or `--self-update-only`.
- **Unified locking behavior** via `LOCK_BLOCKING` (yes|no) across FreeBSD (`lockf`) and Linux (`flock`).
- **Resilient Git operations** with retry logic, configurable by `GIT_RETRY_MAX`.
- **Optional push control** with `PUSH_ENABLED` (commit-only mode).
- Cleaner logs: removed the noisy “Self-update: UPDATE_URL not set” lines unless an update is explicitly requested.

### Added
- `LOCK_BLOCKING` (default: `no`), `GIT_RETRY_MAX` (default: `3`), `PUSH_ENABLED` (default: `yes`), `GIT_MARK_SAFE` (default: `no`).

### Changed
- `self_update_check` is only executed when `--self-update` or `--self-update-only` is passed.

### Fixed
- Inconsistent behavior/logs between FreeBSD and Linux regarding self-update when `UPDATE_URL` was unset.

### Upgrade Notes
- If you previously relied on `AUTO_UPDATE="yes"`, you must now run the script with `--self-update` (or `--self-update-only`) to perform an update check/apply.
- `UPDATE_URL` and `EXPECTED_SHA256` are still honored **only** during a CLI-triggered update.


## [1.6.3] - 2025-10-06
### Highlights
- **Smart remote sync policy (`ALIGN_MODE`)** with robust divergence handling.
- Defaults to `ALIGN_MODE="rebase"`; opt‑in `ALIGN_MODE="reset"` for dump‑style repos.
- Keeps portable self‑lock and self‑update improvements from 1.6.2.

### Added
- `ALIGN_MODE` config with two strategies:
  - `rebase` (default): try fast‑forward; on divergence run `git rebase --autostash`.
    If there are **no local commits**, fall back to `git reset --hard origin/<branch>`.
  - `reset`: always `git fetch --prune` + `git reset --hard origin/<branch>`.
- Detailed logging for remote alignment decisions (ahead/behind counts).

### Changed
- Replaced `git pull --ff-only` with an explicit handler for FF/merge‑base/rebase/reset.
- README.md expanded with full usage, config, and troubleshooting guidance.

### Fixed
- Eliminates recurring “Not possible to fast-forward” aborts in automated runs by
  proactively reconciling histories according to the chosen policy.

### Deprecated
- None.

### Removed
- None.

### Security
- No security‑relevant changes in this release.

### Upgrade Notes
- No breaking changes. Existing configs work as‑is.
- To avoid divergence warnings permanently on backup‑only repos, set `ALIGN_MODE="reset"`.
- If you pinned the script hash with `EXPECTED_SHA256`, update it after upgrading the script.

---

## [1.6.2] - 2025-10-06
### Highlights
- Self‑update flow hardened and made testable with `--self-update-only`.

### Added
- `--self-update-only` CLI flag to check/apply updates and **exit early**.
- Extra diagnostics for permission/hash/validation failures during self‑update.

### Changed
- **Capture original argv before parsing** so flags (e.g., `--config`) are preserved
  during re‑exec after updating.
- Atomic replacement of the script with `.new` + backup file.

### Fixed
- Apparent “update not applied” behavior caused by lost argv on re‑exec.

### Deprecated / Removed / Security
- None.

### Upgrade Notes
- Ensure the executing user (typically `root`) has write permission on the script path.

---

## [1.6.1] - 2025-10-06
### Highlights
- **Portable internal locking** moved into the script; no external cron locking required.

### Added
- Locking strategies:
  - FreeBSD: re‑exec under `lockf -k <LOCKFILE>`.
  - Linux (or when available): re‑exec under `flock -n <LOCKFILE>`.
  - Fallback: atomic directory lock (`mkdir <LOCKFILE>.d`) with `trap` cleanup.

### Changed
- Cron examples simplified to call the script directly.

### Fixed
- Avoid stale file locks and recursion via `__CONF2GIT_LOCKED` guard.

### Deprecated / Removed / Security
- None.

### Upgrade Notes
- None; existing `LOCKFILE` is still honored.

---

## [1.6.0] - 2025-10-06
### Highlights
- Introduced **self‑update**, **reporting**, **log rotation**, and **sparse‑checkout hardening**.

### Added
- Self‑update from `UPDATE_URL` with optional `EXPECTED_SHA256` pin.
- `--report` / `CONF2GIT_REPORT=1` to print end‑of‑run management report.
- Log rotation: 100 KB threshold, keep last 12 archives (`.gz`).
- More robust script path resolution (PATH lookup, `realpath`/`readlink`).
- Rsync diagnostics (`-n -i -v` on dry‑run) and capability detection (`-H -A -X`).

### Changed
- Git sparse‑checkout initialization and restriction to `TARGET_PATH` enforced on each run.

### Fixed
- Logging works even when `LOGFILE` is unset (falls back to stdout).

### Deprecated / Removed / Security
- None.

### Upgrade Notes
- Ensure `git >= 2.25` for sparse‑checkout cone mode.

---

## [Unreleased]
- (Place your upcoming changes here.)

[1.6.3]: https://github.com/<org>/<repo>/releases/tag/v1.6.3
[1.6.2]: https://github.com/<org>/<repo>/releases/tag/v1.6.2
[1.6.1]: https://github.com/<org>/<repo>/releases/tag/v1.6.1
[1.6.0]: https://github.com/<org>/<repo>/releases/tag/v1.6.0
