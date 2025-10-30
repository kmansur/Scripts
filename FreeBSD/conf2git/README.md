# conf2git.sh — README (v1.7.0)

> Safely snapshot configuration directories to a Git monorepo, per-host sparse-checkout, portable locking, smart remote sync, **CLI-only self-update**, reporting, log rotation, and resilient Git retries.

---

## 1) What this does (and why)

`conf2git.sh` automates periodic exports of system configuration into a single Git repository, placing each host under its own path using **git sparse-checkout**.  
It prevents concurrent runs, keeps the local copy aligned with the remote branch even on divergence, and (when *explicitly* requested) can update itself from a trusted URL.

**Core goals**
- Per-host backups in a **shared repo** (e.g., `Servers/freebsd/hostname/...`)
- Safe, automated runs (portable lock on FreeBSD/Linux)
- Robust **remote alignment** (rebase/FF or hard reset, configurable)
- **Self-update only when invoked via CLI flags** (no background network access)
- **Rsync-based export** with sensible excludes
- **Optional end-of-run report** to stdout
- **Light log rotation** (100 KB threshold; last 12 `.gz`)
- **Resilient Git operations** with retries
- **Optional push control** (commit-only mode)
- **Optional safe.directory** mark to silence “dubious ownership” warnings

> Since **v1.7.0**, self-update does **not** run automatically. It only happens when you call the script with `--self-update` or `--self-update-only`.

---

## 2) Features at a glance

- **Portable locking**  
  FreeBSD: `lockf`; Linux: `flock`; fallback to dir-lock. Behavior controlled by `LOCK_BLOCKING=yes|no`.

- **Sparse-checkout per host**  
  Keeps the working tree focused on `TARGET_PATH` for minimal IO and safer commits.

- **Smart remote sync (`ALIGN_MODE`)**  
  - `rebase` (default): `fetch --prune`, try FF; if diverged, `git rebase --autostash`.  
    If there are **no local commits**, falls back to `git reset --hard origin/<branch>`.  
  - `reset`: always `fetch --prune` + `reset --hard origin/<branch>`.

- **Rsync export with excludes**  
  Auto-adds `-H -A -X` when supported; dry-run and verbose report modes available.

- **CLI-only self-update**  
  No network access on normal runs. Update only with `--self-update` / `--self-update-only`.  
  Honors `UPDATE_URL` (and optional `EXPECTED_SHA256`) **only** during CLI-triggered update.

- **Retries for flaky Git**  
  `git fetch`/`push` use retry wrapper (`GIT_RETRY_MAX`, default `3`).

- **Optional push**  
  `PUSH_ENABLED=no` keeps commits local (e.g., during maintenance windows).

- **Log rotation**  
  Rotate at ~100 KB; keep 12 compressed generations (`.gz`).

---

## 3) Requirements

- **Git ≥ 2.25** (for sparse-checkout cone mode)
- `rsync`
- One of: `lockf` (FreeBSD base) or `flock` (Linux)
- For **self-update (only when invoked)**: one of `fetch` (FreeBSD), `curl`, or `wget`
- Optional: `gzip` (for log rotation)

---

## 4) Installation

1. Place the script:
   ```sh
   install -m 0755 conf2git.sh /usr/local/scripts/conf2git.sh
   ```

2. Create a config file:
   ```sh
   cp conf2git.cfg.example /usr/local/scripts/conf2git.cfg
   vi /usr/local/scripts/conf2git.cfg
   ```

3. First run as a dry-run:
   ```sh
   /usr/local/scripts/conf2git.sh --dry-run -r
   ```

4. Real run:
   ```sh
   /usr/local/scripts/conf2git.sh -r
   ```

5. Cron (hourly example):
   ```cron
   # conf2git hourly with log
   12 * * * * /usr/local/scripts/conf2git.sh -r >>/var/log/conf2git.log 2>&1
   ```
   > Adjust minute to spread load across many hosts.

---

## 5) Usage (CLI)

- Show help:
  ```sh
  conf2git.sh -h
  ```

- Dry-run with report:
  ```sh
  conf2git.sh --dry-run -r
  ```

- Normal run with report:
  ```sh
  conf2git.sh -r
  ```

- **Self-update only (no export)**:
  ```sh
  conf2git.sh --self-update-only
  ```

- **Run + force a self-update at start**:
  ```sh
  conf2git.sh --self-update
  ```

- Load a custom config:
  ```sh
  conf2git.sh --config /path/to/conf2git.cfg
  ```

---

## 6) Configuration (`conf2git.cfg`)

**Required keys**:

- `CONF_DIRS` — Space-separated list of source directories to export.  
  Example:
  ```sh
  CONF_DIRS="/etc /usr/local/etc /usr/local/scripts"
  ```

- `BASE_DIR` — Logical top-level (for your layout/documentation).  
  Example: `BASE_DIR="Servers"`

- `REPO_ROOT` — Filesystem path to the **local** working copy.  
  Example: `REPO_ROOT="/var/git-export/Servers"`

- `GIT_REPO_URL` — Remote repo URL (SSH or HTTPS).  
  Example (SSH):  
  `GIT_REPO_URL="git@your.git.host:group/servers.git"`

- `TARGET_PATH` — Subpath for this host in the repo (used by sparse-checkout).  
  Example (FreeBSD): `TARGET_PATH="freebsd/arcos"`  
  Example (Linux):   `TARGET_PATH="linux/wh01"`

- `REPO_DIR` — Destination directory inside the working tree.  
  Usually `${REPO_ROOT}/${TARGET_PATH}`

- `LOCKFILE` — Path to a lock file.  
  Example: `LOCKFILE="/var/run/conf2git.lock"`

- `GIT_USER_NAME` / `GIT_USER_EMAIL` — Identity for commits.

**Optional keys**:

- `ALIGN_MODE="rebase"` or `"reset"` (default: `rebase`)
- `LOCK_BLOCKING="no"` — `"yes"` blocks; `"no"` fails fast if locked
- `GIT_RETRY_MAX="3"` — Retry count for `git fetch`/`push`
- `PUSH_ENABLED="yes"` — Use `"no"` to commit locally without pushing
- `GIT_MARK_SAFE="no"` — `"yes"` adds `REPO_ROOT` to `safe.directory`
- `LOGFILE="/var/log/conf2git.log"` — If set, logs also go to this file
- **Self-update knobs (honored only with CLI flags)**:
  - `UPDATE_URL="https://…/conf2git.sh"` — Where to fetch a newer script
  - `EXPECTED_SHA256=""` — Optional integrity pin

> **Deprecation note**: legacy `AUTO_UPDATE` is ignored on normal runs since **v1.7.0**. Self-update only triggers via `--self-update` or `--self-update-only`.

---

## 7) Run flow

1. Log rotation
2. Optional self-update (CLI-only)
3. Portable lock (lockf/flock/dir-lock)
4. Repo prep (sparse-checkout on `TARGET_PATH`)
5. Remote alignment (per `ALIGN_MODE`)
6. Rsync export (with excludes and AXH when supported)
7. Commit & optional push
8. Optional report

---

## 8) Troubleshooting

- **“No changes to commit”**  
  Nothing new under `TARGET_PATH`. Confirm rsync source paths and excludes.

- **Sparse-checkout path looks wrong**  
  Check `TARGET_PATH` and the repo default branch (`origin/HEAD`). Fallback is `main`.

- **“Dubious ownership” / safe.directory**  
  Set `GIT_MARK_SAFE="yes"` to whitelist `REPO_ROOT`.

- **Lock already active**  
  Set `LOCK_BLOCKING="yes"` to wait instead of failing fast.

- **Self-update messages**  
  On normal runs there is no self-update network access (since v1.7.0). Use `--self-update-only` to fetch/replace from `UPDATE_URL`.

---

## 9) Upgrade notes (≤1.6.x → 1.7.0)

- Self-update changed to **CLI-only**.  
  Remove `AUTO_UPDATE="yes"` from cron-driven configs.  
  To update the script itself:
  ```sh
  conf2git.sh --self-update-only
  ```
- New cfg keys: `LOCK_BLOCKING`, `GIT_RETRY_MAX`, `PUSH_ENABLED`, `GIT_MARK_SAFE`.
- Cleaner logs: no more “UPDATE_URL not set” noise on normal runs.

---

## 10) License

See the `LICENSE` file at the repository root.
