# be-upgrade.sh

**Version:** 0.3.1  
**Platform:** FreeBSD (ZFS Boot Environments)  
**License:** MIT

A POSIX `/bin/sh`-compliant, single-file script that creates/updates a **ZFS Boot Environment (BE)**, runs a **chrooted `pkg` upgrade** inside it, and **activates** the BE either **temporarily** (next boot only) or **permanently**. It also supports a **promote-after-reboot** workflow using a small **marker file** (no `rc.d` hooks required).

The script is designed for **safe upgrades**: upgrades happen in a **separate BE**, so you can reboot into the new BE and **roll back** easily if needed.

---

## Table of Contents

- [Why use this script?](#why-use-this-script)
- [What it does (short version)](#what-it-does-short-version)
- [Requirements](#requirements)
- [Install](#install)
- [Quick Start (Recommended)](#quick-start-recommended)
- [How It Works](#how-it-works)
- [Activation Modes](#activation-modes)
- [Marker File (Promote-after-reboot)](#marker-file-promote-after-reboot)
- [Full Usage & Options](#full-usage--options)
- [Sub-Commands](#sub-commands)
- [Allow/Deny Policy (Package Plan Enforcement)](#allowdeny-policy-package-plan-enforcement)
- [Workflows & Examples](#workflows--examples)
- [Safety, Rollback & Recovery](#safety-rollback--recovery)
- [Diagnostics & Troubleshooting](#diagnostics--troubleshooting)
- [Operational Caveats](#operational-caveats)
- [Exit Behavior](#exit-behavior)
- [Changelog](#changelog)
- [License](#license)

---

## Why use this script?

- **Safe upgrades** with **ZFS Boot Environments**: upgrade in a separate BE, keep the current system untouched until reboot.
- **Fast rollback**: if the new BE misbehaves, switch back to the previous BE and reboot.
- **No `rc.d` hooks**: promotion to permanent can be done explicitly after you verify the new BE.
- **POSIX `/bin/sh`**: compatible with FreeBSD’s default shell; no bashisms.

---

## What it does (short version)

1. Creates (or reuses) a **target BE**.
2. **Mounts** the BE at a mountpoint (default `/mnt`).
3. Runs **`pkg -r <MNT> upgrade`** (chroot-like) against that BE.
4. **Unmounts** the BE.
5. **Activates** the BE:
   - **Temporary (default)**: next boot only.
   - **Permanent (`-p`)**: becomes default immediately.
   - **Promote-after-reboot (`-P`)**: temporary now + writes a **marker file** so you can **finalize** later with `--finalize`.

---

## Requirements

- FreeBSD with **ZFS** and **Boot Environments** (`bectl`).
- Tools available in `PATH`: `bectl`, `pkg`, `reboot`.
- Root privileges.

---

## Install

```bash
curl -o /usr/local/scripts/be-upgrade.sh   https://raw.githubusercontent.com/kmansur/Scripts/refs/heads/main/FreeBSD/be-upgrade/be-upgrade.sh
chmod +x /usr/local/scripts/be-upgrade.sh
```

> Adjust any automation to use `/usr/local/scripts/be-upgrade.sh`.

---

## Quick Start (Recommended)

```bash
# 1) Pre-flight validations (no changes):
sudo /usr/local/scripts/be-upgrade.sh --pre-flight

# 2) Prepare a temporary activation + marker for later promotion:
sudo /usr/local/scripts/be-upgrade.sh -P

# 3) Reboot into the new BE:
sudo reboot

# 4) After verifying the system, promote to permanent (no extra reboot required):
sudo /usr/local/scripts/be-upgrade.sh --finalize
```

---

## How It Works

- **BE creation**: creates a new BE (default name `upgrade`), unless:
  - You **reuse** (`--reuse`) an existing BE, or
  - You **force recreate** (`--force-recreate`), or
  - The BE exists and you didn’t specify reuse/force, in which case the script **auto-suffixes** the name with `YYYYmmdd-HHMMSS`.

- **Mount/Upgrade**: mounts the BE at a mountpoint (default `/mnt`), runs `pkg -r /mnt upgrade` (with `-y` by default), then unmounts.

- **Activate**:
  - **Temporary** (`bectl activate -t <BE>`): next boot only.
  - **Permanent** (`bectl activate <BE>`): default for all future boots.
  - **Promote-after-reboot** (`-P`): temporary + writes a **marker file** (default: `/var/db/be_promote_after_reboot.flag`). After booting into the new BE, run `--finalize` to make it permanent.

---

## Activation Modes

- **Temporary (Default)**  
  ```bash
  bectl activate -t <BE>
  ```
  The new BE is used **only on the next boot**.

- **Permanent (`-p` / `--permanent`)**  
  ```bash
  bectl activate <BE>
  ```
  The new BE becomes the **default** for all future boots **immediately**.

- **Promote-after-reboot (`-P` / `--promote-after-reboot`)**  
  - Activates **temporarily now** and writes a **marker file** with the BE name.
  - After booting into that BE, run:
    ```bash
    be-upgrade.sh --finalize
    ```
    The script validates that the **current BE matches the marker** and then activates it **permanently**.

> If you pass both `-p` and `-P`, **`-p` wins** (permanent), and `-P` is ignored.

---

## Marker File (Promote-after-reboot)

- Default path: **`/var/db/be_promote_after_reboot.flag`**  
- Content: **BE name** to be promoted.  
- Permissions: created with **`0600`** and **validated** after write.  
- Overridable with `--marker PATH`.

**Inspect/Remove:**
```bash
sudo ls -l /var/db/be_promote_after_reboot.flag
sudo cat /var/db/be_promote_after_reboot.flag
sudo rm -f /var/db/be_promote_after_reboot.flag
```

---

## Full Usage & Options

```text
Usage:
  be-upgrade.sh [options]          # create/mount/upgrade/activate BE (temporary by default)
  be-upgrade.sh --finalize         # promote to PERMANENT (after reboot with -P)
  be-upgrade.sh --status           # show marker + current BE
  be-upgrade.sh --test-marker      # create & read marker only (no BE ops)
  be-upgrade.sh --pre-flight       # run validations only (no changes)
  be-upgrade.sh --dry-run          # print the full plan (no changes)

Options:
  -b NAME                 BE name (default: upgrade)
  -m DIR                  Mountpoint (default: /mnt)
  -y                      Reboot without prompt
  -p, --permanent         Activate BE permanently now
  -P, --promote-after-reboot
                          Activate temporary now and write marker, then after you boot into it run:
                          be-upgrade.sh --finalize
      --marker PATH       Override marker path (default: /var/db/be_promote_after_reboot.flag)

      --allow LIST        Comma-separated allowlist of packages (enforced vs plan)
      --deny LIST         Comma-separated denylist of packages (enforced vs plan)

      --finalize          Promote current BE to permanent if it matches marker
      --status            Show current BE and marker info
      --test-marker       Write+read a dummy marker to test permissions/path
      --pre-flight        Run validations only (no changes)
      --dry-run           Print the full plan (no changes)

      --reuse             Reuse existing BE (skip create)
      --force-recreate    Destroy existing BE and recreate (dangerous)

      --no-color          Disable colors
      --debug             Verbose decisions (prints flags/branches)

  -h, --help              Help
```

**Notes:**
- `PKG_YES="-y"` by default. Set `PKG_YES=""` to make `pkg` interactive.
- The script **ensures mountpoint exists** (`mkdir -p`) and is **not already mounted** before use.
- If the target BE exists and neither `--reuse` nor `--force-recreate` is set, the script will **auto-suffix** the BE name.

---

## Sub-Commands

- `--pre-flight`  
  Validations only: root, tools, mountpoint availability, BE existence, marker dir writability, zpool free space hint.

- `--dry-run`  
  Prints the **execution plan** (including how the BE name would resolve) **without changing anything**.

- `--status`  
  Shows the **current BE** and, if present, **marker info** (including whether it’s ready to finalize).

- `--test-marker`  
  Creates/validates a **dummy marker** (doesn’t touch BEs). Useful for path/permission checks.

- `--finalize`  
  If the **current BE** matches the **marker’s BE name**, it **activates permanently** and removes the marker.

---

## Allow/Deny Policy (Package Plan Enforcement)

When `--allow` or `--deny` is specified, the script will:

1. Mount the BE and run a **dry plan**:  
   ```bash
   pkg -r <MNT> upgrade -n
   ```
2. **Parse** the planned package set (best-effort parsing of package names).
3. **Enforce**:
   - `--allow "p1,p2"`: **only** packages in the allowlist may be upgraded/installed; others cause failure.
   - `--deny "p3,p4"`: If any planned package matches the denylist, the script **aborts**.
4. If the plan **violates** the policy, the script **fails before** any changes are applied.

**Tip:** Use `--dry-run` first to see the plan (policy enforcement requires a real mount, so it’s applied during normal runs).

---

## Workflows & Examples

### 1) Conservative “test-then-promote”
```bash
sudo be-upgrade.sh --pre-flight
sudo be-upgrade.sh -P --debug
sudo reboot
# validate services/logs
sudo be-upgrade.sh --finalize
```

### 2) Permanent right away (only if confident)
```bash
sudo be-upgrade.sh -p
```

### 3) Reuse an existing BE name
```bash
sudo be-upgrade.sh -P --reuse -b upgrade
```

### 4) Force recreate an existing BE (dangerous)
```bash
sudo be-upgrade.sh -P --force-recreate -b upgrade
```

### 5) Enforce policy with allow/deny
```bash
# Preview (no changes)
sudo be-upgrade.sh --dry-run -P --allow "openssl,nginx" --deny "python311"

# Enforce and proceed
sudo be-upgrade.sh -P --allow "openssl,nginx" --deny "python311"
sudo reboot
sudo be-upgrade.sh --finalize
```

### 6) Use a custom marker path
```bash
sudo be-upgrade.sh --marker /root/be_promote.flag -P
sudo reboot
sudo be-upgrade.sh --marker /root/be_promote.flag --finalize
```

---

## Safety, Rollback & Recovery

- **Rollback** any time:
  ```bash
  bectl list
  sudo bectl activate <previous-be>
  sudo reboot
  ```
- **Temporary activation fails?** Your previous default BE remains available.
- **Used `-p` and want to revert?**
  ```bash
  sudo bectl activate <previous-be>
  sudo reboot
  ```

---

## Diagnostics & Troubleshooting

- **Mountpoint is busy**  
  The script aborts if the mountpoint is already mounted. Either unmount it or use `-m` to point to another directory:
  ```bash
  umount /mnt
  sudo be-upgrade.sh -m /mnt
  ```

- **Marker not created**  
  Validate with:
  ```bash
  sudo be-upgrade.sh --test-marker
  ```
  Or override the path with:
  ```bash
  sudo be-upgrade.sh --marker /root/be_promote.flag --test-marker
  ```

- **Finalize mismatch**  
  If `--finalize` complains **current BE != marker**, reboot into the BE named in the marker and run `--finalize` again:
  ```bash
  sudo be-upgrade.sh --status
  sudo be-upgrade.sh --finalize
  ```

- **Verbose decisions**  
  Add `--debug` to see branches/flags.

---

## Operational Caveats

- **Kernel modules via packages** (e.g., graphics drivers) must **match** the running kernel. This script **does not** alter base/kernel—only packages. Plan kernel/base upgrades carefully if you rely on kmods.
- **Repository policy**: prefer **`quarterly`** for production; if using `latest`, consider pinning critical versions.
- **ZFS space**: ensure enough free space for snapshot/BE creation.
- **ZFS layout**: if you customized datasets (e.g., moved parts of `/usr` or `/var` outside the BE), confirm the layout aligns with your expectations.

---

## Exit Behavior

- On success: **exit 0**.  
- On failures: **non-zero**, with a clear error message.  
- The script uses a `run()` wrapper to enforce return-code checks, and `set -u` to catch unset variables.

---

## Changelog

- **v0.3.1**
  - **POSIX `/bin/sh` compliance**: removed process substitution, fixed function calls, standardized redirects.
  - Updated docs/paths to **`/usr/local/scripts`** and installation URL.
  - Keeps v0.3 features.

- **v0.3**
  - `--dry-run` (no changes; full plan).
  - `--pre-flight` (validations only).
  - `--allow` / `--deny` (policy enforced against the `pkg -r <MNT> upgrade -n` plan).

- **v0.2**
  - Strong marker handling, `--test-marker`, robust mount detection, cleaner output.

---

## License

**MIT** — see `LICENSE`.
