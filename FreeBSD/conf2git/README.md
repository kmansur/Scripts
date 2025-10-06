# conf2git.sh — README (v1.6.3)

> Safely snapshot configuration directories to a Git monorepo, per-host, with portable locking, smart remote sync, self-update, reporting, and log rotation.

---

## 1) What this does (and why)

`conf2git.sh` automates periodic exports of system configuration (e.g., `/etc`, `/usr/local/etc`, custom scripts) into a **single Git repository** while isolating each host under its own path using **git sparse-checkout**.  
It prevents concurrent runs, stays aligned with the remote branch even when histories diverge, and can update itself.

**Core goals**
- Per-host backups in a **shared repo** (e.g., `Servers/freebsd/hostname/...`)
- Safe, automated runs (portable lock on FreeBSD/Linux)
- Robust **remote sync** (rebase/FF or hard reset, configurable)
- Optional **self-update** from a trusted URL
- Clear **logging**, optional **report**, lightweight **log rotation**

---

## 2) Features

- **Portable self-lock**  
  - FreeBSD: `lockf -k` (base system)  
  - Linux (or when available): `flock -n`  
  - Fallback: atomic **directory lock** via `mkdir` + `trap` cleanup

- **Smart remote sync (ALIGN_MODE)**  
  - `rebase` (default): tries fast-forward; on divergence rebases with `--autostash`. If there are no local commits, it falls back to a safe hard reset.  
  - `reset`: always `fetch` + `reset --hard origin/<branch>` (best for “dump-only” repos)

- **Self-update**  
  - Checks a remote `UPDATE_URL`, compares hashes, and if newer, replaces itself atomically with a backup.  
  - `--self-update-only` for CI/ops validation.

- **Sparse-checkout** per host  
  - Limits working tree to `TARGET_PATH` only (e.g., `freebsd/arcos`).

- **Rsync-based export** with sensible excludes

- **Optional end-of-run report** to stdout

- **Light log rotation** (100 KB threshold; keep last 12 `.gz`)

---

## 3) Requirements

- **Git ≥ 2.25** (for sparse-checkout cone mode)
- `rsync`
- One of: `lockf` (FreeBSD base) or `flock` (Linux / optional)
- For self-update: one of `fetch` (FreeBSD) or `curl` or `wget`
- Optional: `gzip` (for rotating/compressing logs)

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

3. First run (manual):
   ```sh
   /usr/local/scripts/conf2git.sh --dry-run
   /usr/local/scripts/conf2git.sh
   ```

4. Cron (no external locks needed):
   - **FreeBSD** `/etc/crontab`
     ```cron
     SHELL=/bin/sh
     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
     HOME=/root

     # minute hour dom mon dow user  command
     5 * * * * root /usr/local/scripts/conf2git.sh >> /var/log/conf2git.log 2>&1
     ```
   - **Linux** (root’s crontab):
     ```sh
     crontab -e
     # Add:
     5 * * * * /usr/local/scripts/conf2git.sh >> /var/log/conf2git.log 2>&1
     ```

---

## 5) Command-line options

```text
conf2git.sh [OPTIONS]

  --dry-run            Simulate rsync (no changes committed/pushed)
  --config <path>      Use an alternative config file (default: /usr/local/scripts/conf2git.cfg)
  --self-update        Force an immediate self-update from UPDATE_URL
  --self-update-only   Only perform self-update check/apply and exit (good for CI/ops)
  -r, --report         Print a management report at the end of execution (to stdout)
  -h, --help           Show help and exit
```

**Examples**
- Dry run with report:
  ```sh
  conf2git.sh --dry-run -r
  ```
- Use a different cfg:
  ```sh
  conf2git.sh --config /root/conf2git.custom.cfg
  ```
- Self-update now (and exit after update check/apply):
  ```sh
  conf2git.sh --self-update-only
  ```
- Force self-update in a normal run:
  ```sh
  conf2git.sh --self-update
  ```

> Tip: set `CONF2GIT_REPORT=1` in the environment to enable the report without `-r`.

---

## 6) Configuration (`conf2git.cfg`)

**Minimal required keys** (must be **non-empty**):
- `CONF_DIRS` — Space-separated list of source directories to export.
  - Example:  
    ```sh
    CONF_DIRS="/etc /usr/local/etc /usr/local/scripts"
    ```
- `BASE_DIR` — Logical top-level (purely informational for your layout).
  - Example: `BASE_DIR="Servers"`
- `REPO_ROOT` — Filesystem path to the local working copy.
  - Example: `REPO_ROOT="/var/git-export/Servers"`
- `GIT_REPO_URL` — Remote repo URL (SSH or HTTPS).
  - Example (SSH): `GIT_REPO_URL="git@vesta.mpc.com.br:mpc/servers.git"`
- `TARGET_PATH` — Subpath for this host inside the repo (used by sparse-checkout).
  - Example (FreeBSD): `TARGET_PATH="freebsd/arcos"`
- `REPO_DIR` — Destination directory inside the working tree where exports go.
  - Usually `${REPO_ROOT}/${TARGET_PATH}`  
  - Example: `REPO_DIR="/var/git-export/Servers/freebsd/arcos"`
- `LOCKFILE` — Path to the lock file (or base for dir-lock).
  - Example: `LOCKFILE="/var/run/conf2git.lock"`
- `GIT_USER_NAME` — Commit author name for this machine.
  - Example: `GIT_USER_NAME="Conf2Git Automation"`
- `GIT_USER_EMAIL` — Commit author email for this machine.
  - Example: `GIT_USER_EMAIL="ops@example.com"`

**Common optional keys**
- `LOGFILE` — Where to log (the script always prints to stdout as well).
  - Example: `LOGFILE="/var/log/conf2git.log"`
- `AUTO_UPDATE` — `"yes"` to apply updates automatically when available; `"no"` otherwise.  
  - Default: `"no"`; the script still *checks* availability and logs status.
- `UPDATE_URL` — URL to fetch the latest script from (for self-update).
  - Example (raw GitHub):  
    `UPDATE_URL="https://raw.githubusercontent.com/ORG/REPO/BRANCH/FreeBSD/conf2git.sh"`
- `EXPECTED_SHA256` — Optional hash pinning for the downloaded script. If set and mismatch occurs, update is aborted.
  - Example: `EXPECTED_SHA256="3b4e2b9..."`
- `ALIGN_MODE` — `rebase` (default) or `reset`.  
  - `rebase`: tries FF; on divergence, `rebase --autostash`; if **no local commits**, falls back to `reset --hard origin/<branch>`.  
  - `reset`: always `fetch` + `reset --hard origin/<branch>`. Best when this repo is a one-way dump and local commits must never diverge.
- (Advanced) `CONF2GIT_DEBUG` — Set `1` to print extra self-update diagnostics.

**Example `conf2git.cfg`**
```sh
# Host inventory
BASE_DIR="Servers"
TARGET_PATH="freebsd/arcos"

# Local working copy root (git clone path)
REPO_ROOT="/var/git-export/Servers"
REPO_DIR="${REPO_ROOT}/${TARGET_PATH}"

# Git remote
GIT_REPO_URL="git@vesta.mpc.com.br:mpc/servers.git"

# What to export
CONF_DIRS="/etc /usr/local/etc /usr/local/scripts"

# Identity (per-host committer)
GIT_USER_NAME="Conf2Git Automation"
GIT_USER_EMAIL="ops@example.com"

# Lock & logging
LOCKFILE="/var/run/conf2git.lock"
LOGFILE="/var/log/conf2git.log"

# Self-update
AUTO_UPDATE="yes"
UPDATE_URL="https://raw.githubusercontent.com/ORG/REPO/BRANCH/conf2git.sh"
# EXPECTED_SHA256=""

# Remote sync policy: rebase (default) or reset
ALIGN_MODE="rebase"
```

---

## 7) How it works (flow)

1. **Pre-flight**
   - Sanitize env (`umask`, `PATH`)
   - Load config; validate required keys
   - Rotate `LOGFILE` if > 100 KB (keep 12 gzipped)
   - **Self-update** check (and re-exec if applied; `--self-update-only` exits here)

2. **Locking** (portable)
   - If on FreeBSD and `lockf` exists: re-exec under `lockf -k LOCKFILE`.
   - Else if `flock` exists: re-exec under `flock -n LOCKFILE`.
   - Else: create a **dir-lock** `LOCKFILE.d` with `mkdir`; `trap` to clean.

3. **Repo prep (sparse-checkout)**
   - Clone if missing; enable cone mode; set path to `TARGET_PATH`.
   - Enforce Git identity.
   - If repo exists: ensure sparse-checkout is set to `TARGET_PATH`.

4. **Smart remote sync** (ALIGN_MODE)
   - `reset`: `fetch --prune` + `reset --hard origin/<branch>`.
   - `rebase`: `fetch --prune`; compute ahead/behind; try FF; on divergence `rebase --autostash`; if **no local commits**, `reset --hard`; otherwise abort with a clear message.

5. **Export via rsync**
   - Excludes: `*.pid *.db *.core *.sock *.swp cache/ .git/`
   - Capabilities auto-add: `-H -A -X` if supported
   - Dry-run: `-aniv --delete` (and tee to report if enabled)
   - Real run: `-a[v] --delete` (+ AXH if supported; and tee if report)

6. **Commit & push**
   - `git add -- TARGET_PATH`  
   - If staged changes exist: commit with `[$OS/$HOST] Automated config backup @ timestamp` and `git push origin <branch>`.

7. **Optional report** (if `-r` or `CONF2GIT_REPORT=1`)
   - Prints duration, dirs processed, rsync itemized change count, commit SHA.

---

## 8) Logging & rotation

- **Always prints to stdout**; if `LOGFILE` is set, **duplicates** messages there.
- Rotation: when `LOGFILE` exceeds 100 KB, it is gzipped to `.1.gz`, older archives are shifted up to `.12.gz`, and the current file is truncated.
- To watch progress live:
  ```sh
  tail -f /var/log/conf2git.log
  ```

---

## 9) Practical examples

**Force a one-time alignment to remote (dump style)**
```sh
# In the repo working dir
git fetch --prune
git reset --hard origin/main
```
Then set in `conf2git.cfg`:
```sh
ALIGN_MODE="reset"
```

**Rebase mode (default) but skip when locked**
- Already handled internally. If you want a skip-on-busy behavior always, use Linux with flock (non-blocking) or change the FreeBSD lock to `-t 0` in the code (advanced).

**Run with report for human review**
```sh
conf2git.sh -r --dry-run
conf2git.sh -r
```

**Exercise the self-update without full run**
```sh
CONF2GIT_DEBUG=1 conf2git.sh --self-update-only
echo $?   # 0 if up to date or successfully updated; 1 on failure
```

---

## 10) Troubleshooting

**“Not possible to fast-forward, aborting.”**  
You had divergent histories. In v1.6.3 this is handled by the smart sync block.  
- If you want a guaranteed fix for backup repos: set `ALIGN_MODE="reset"`.

**Script says updated but nothing changed**  
- Check `UPDATE_URL` content really differs (`sha256` locally vs remote).  
- Verify permissions on `/usr/local/scripts/conf2git.sh` (must be writable by the user running it, typically `root`).  
- If using `EXPECTED_SHA256`, ensure the hash matches.

**No changes to commit**  
- Rsync found no differences under `TARGET_PATH`. This is normal if nothing changed since last run.

**Lock issues**  
- On FreeBSD, `lockf` is preferred; on Linux, `flock`; fallback is dir-lock.
- If you find a stale dir-lock (rare), remove `LOCKFILE.d` manually (only if you’re sure the job isn’t running).

**Sparse-checkout complains**  
- Ensure Git ≥ 2.25.  
- Re-initialize:
  ```sh
  cd "$REPO_ROOT"
  git sparse-checkout init --cone
  git sparse-checkout set "$TARGET_PATH"
  ```

---

## 11) Security & operational notes

- Use **SSH** remotes with restricted deploy keys if the repo is sensitive.
- The script commits only under `TARGET_PATH`, but **review your `CONF_DIRS`**: don’t include secrets you don’t want in Git.
- Cron runs as root by default for convenience; if you lower privileges, ensure read access to all `CONF_DIRS` and write access to `REPO_ROOT`, `LOGFILE`, and `LOCKFILE` paths.

---

## 12) Versioning quicklog

- **v1.6.3** — Smart remote sync (`ALIGN_MODE=rebase|reset`), robust divergence handling.  
- **v1.6.2** — Fix self-update argv capture; `--self-update-only`; better diagnostics.  
- **v1.6.1** — Portable self-lock (lockf/flock/mkdir).  
- **v1.6.0** — Self-update framework, report, log rotation, sparse-checkout hardening.

---

## 13) Quick checklist

- [ ] `Git ≥ 2.25`, `rsync` installed  
- [ ] `conf2git.sh` at `/usr/local/scripts/conf2git.sh` (0755)  
- [ ] `conf2git.cfg` filled with **required keys**  
- [ ] First run `--dry-run` then a real run  
- [ ] Cron installed with output to `/var/log/conf2git.log`  
- [ ] Choose `ALIGN_MODE` that matches your policy (`rebase` vs `reset`)  
- [ ] (Optional) `AUTO_UPDATE="yes"`, set `UPDATE_URL`, and pin `EXPECTED_SHA256` if desired

---

**Happy backups!**
