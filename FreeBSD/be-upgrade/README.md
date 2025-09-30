# be-upgrade.sh

**Version:** 0.2  
**Platform:** FreeBSD (ZFS Boot Environments)  
**License:** MIT

A robust, single-file shell script to create/update a **ZFS Boot Environment (BE)**, run a **chrooted `pkg` upgrade** against it, and **activate** the BE either **temporarily** (next boot) or **permanently**. It also supports a **promote-after-reboot** workflow using a small **marker file**—no `rc.d` hooks required.

## Table of Contents
- [Why this script?](#why-this-script)
- [Key Features](#key-features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Recommended Workflow](#recommended-workflow)
- [Activation Modes](#activation-modes)
- [Options](#options)
- [Sub-Commands](#sub-commands)
- [Examples](#examples)
- [Marker File (control file)](#marker-file-control-file)
- [Safety, Rollback & Recovery](#safety-rollback--recovery)
- [Diagnostics & Troubleshooting](#diagnostics--troubleshooting)
- [Exit Behavior](#exit-behavior)
- [Changelog](#changelog)
- [License](#license)

## Why this script?
Upgrading FreeBSD via `pkg` is straightforward, but doing so **safely** with **ZFS Boot Environments** makes rollbacks trivial. This script automates BE creation (or reuse), mounting, upgrading with `pkg -r`, unmounting, and flexible activation/promotion.

## Key Features
- Temporary (default) or Permanent activation
- Promote-after-reboot with a marker file (no `rc.d`)
- Auto-suffix BE name if it already exists (or `--reuse` / `--force-recreate`)
- Idempotent mount handling with robust checks
- Clean output (no raw `\n`)
- Colorized output on TTY (disable with `--no-color` or `NO_COLOR=true`)
- Diagnostics: `--status`, `--test-marker`, `--debug`
- Safe traps to unmount on errors

## Requirements
- FreeBSD with **ZFS** and **bectl**
- `pkg` available on the host
- Root privileges (`sudo` or root shell)

## Installation
```bash
curl -o /usr/local/sbin/be-upgrade.sh https://raw.githubusercontent.com/kmansur/Scripts/refs/heads/main/FreeBSD/be-upgrade/be-upgrade.sh
chmod +x /usr/local/sbin/be-upgrade.sh
```

## Recommended Workflow
**Safer two-step upgrade with verification before making it permanent:**
```bash
sudo /usr/local/sbin/be-upgrade.sh -P
sudo reboot
# after system boots into the new BE:
sudo /usr/local/sbin/be-upgrade.sh --finalize
```

## Activation Modes
- **Default (Temporary)**: `bectl activate -t <BE>` → next boot only.  
- **Permanent (`-p`)**: `bectl activate <BE>` → default for future boots.  
- **Promote-after-reboot (`-P`)**: activate temporary now, write marker; after reboot, run `--finalize` to make it permanent (no rc.d).  
  If both `-p` and `-P` are passed, `-p` wins.

## Options
```
-b NAME                 BE name (default: upgrade)
-m DIR                  Mountpoint (default: /mnt)
-y                      Reboot without prompt
-p, --permanent         Activate BE permanently now
-P, --promote-after-reboot
                        Activate temporary now and write marker;
                        after booting into it, run: be-upgrade.sh --finalize
--marker PATH           Override marker path (default: /var/db/be_promote_after_reboot.flag)
--reuse                 Reuse existing BE (skip create)
--force-recreate        Destroy existing BE and recreate (dangerous)
--no-color              Disable colors
--debug                 Verbose decisions (print branches/flags)
-h, --help              Help
```

### Defaults and Behavior
- If the target BE already exists:
  - **Default**: auto-suffix with `YYYYmmdd-HHMMSS`.
  - `--reuse`: reuse the existing BE.
  - `--force-recreate`: destroy and recreate it (dangerous).
- The script ensures the mountpoint exists and is not already mounted.
- `pkg` runs with `-y` by default (set `PKG_YES=""` to make it interactive).

## Sub-Commands
- `--status` — Show current BE and marker info.  
- `--finalize` — Promote current BE to permanent **only** if it matches the marker.  
- `--test-marker` — Test writing/reading a dummy marker only (no BE operations).

## Examples
Temporary now, promote later:
```bash
sudo be-upgrade.sh -P
sudo reboot
sudo be-upgrade.sh --finalize
```
Permanent immediately:
```bash
sudo be-upgrade.sh -p
```
Reuse an existing BE:
```bash
sudo be-upgrade.sh -P --reuse -b upgrade
```
Destroy and recreate (dangerous):
```bash
sudo be-upgrade.sh -P --force-recreate -b upgrade
```
Override marker path:
```bash
sudo be-upgrade.sh --marker /root/be_promote.flag -P
sudo reboot
sudo be-upgrade.sh --marker /root/be_promote.flag --finalize
```
Status & debug:
```bash
sudo be-upgrade.sh --status
sudo be-upgrade.sh -P --debug
```

## Marker File (control file)
- Default: `/var/db/be_promote_after_reboot.flag`
- Contains the BE name to promote after reboot.
- Created with strict permissions (`0600`) and validated immediately after write.
- Overridable with `--marker PATH`.

## Safety, Rollback & Recovery
Rollback at any time:
```bash
bectl list
sudo bectl activate <previous-be>
sudo reboot
```
If booting temporary BE fails, the previous default BE remains available.
If you used `-p` and want to revert:
```bash
sudo bectl activate <previous-be>
sudo reboot
```

## Diagnostics & Troubleshooting
Mountpoint busy:
```bash
umount /mnt  # or choose another with -m
```
Marker not created:
```bash
sudo be-upgrade.sh --test-marker
sudo be-upgrade.sh --marker /root/be_promote.flag --test-marker
```
Finalize mismatch:
```bash
sudo be-upgrade.sh --status
# boot into BE shown in marker, then:
sudo be-upgrade.sh --finalize
```
Verbose decisions:
```bash
sudo be-upgrade.sh -P --debug
```

## Exit Behavior
- Commands run via `run()`; non-zero rc aborts with a clear error.
- `set -u` catches unset variables.
- No `set -e`; `run()` controls failure handling.

## Changelog
- **v0.2**
  - Late color init; mkdir -p for mountpoint; stronger marker handling; `--test-marker`; clearer messages.
- **v0.1**
  - Initial release with temporary/permanent activation and promote-after-reboot flow.

## License
MIT — use freely.
