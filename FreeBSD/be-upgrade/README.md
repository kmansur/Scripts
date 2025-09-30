# be-upgrade.sh

**Version:** 0.3  
**Platform:** FreeBSD (ZFS Boot Environments)  
**License:** MIT

A robust, single-file shell script to create/update a **ZFS Boot Environment (BE)**, run a **chrooted `pkg` upgrade** against it, and **activate** the BE either **temporarily** (next boot) or **permanently**. It also supports a **promote-after-reboot** workflow using a small **marker file**—no `rc.d` hooks required.

## What's new in v0.3
- `--dry-run` to print the full plan without changing anything.
- `--pre-flight` to run validations only (root, tools, mountpoint, BE name, marker path, zpool free hint).
- `--allow` / `--deny` lists to enforce policy against the `pkg -r <MNT> upgrade -n` plan.

## Installation
```bash
curl -o /usr/local/sbin/be-upgrade.sh https://raw.githubusercontent.com/<you>/<repo>/main/be-upgrade.sh
chmod +x /usr/local/sbin/be-upgrade.sh
```

## Recommended workflow
```bash
sudo /usr/local/sbin/be-upgrade.sh --pre-flight
sudo /usr/local/sbin/be-upgrade.sh -P --debug
sudo reboot
# After the system boots into the new BE:
sudo /usr/local/sbin/be-upgrade.sh --finalize
```

## Policy examples
```bash
# Preview the plan and policy (no changes):
sudo be-upgrade.sh --dry-run -P --allow "openssl,nginx" --deny "python311"

# Enforce allow/deny and proceed:
sudo be-upgrade.sh -P --allow "openssl,nginx" --deny "python311"
sudo reboot
sudo be-upgrade.sh --finalize
```

## Full usage
Run `be-upgrade.sh --help` for all options. Highlights:
- Temporary default, `-p` permanent, `-P` promote-after-reboot
- `--status`, `--finalize`, `--test-marker`, `--pre-flight`, `--dry-run`
- `--allow` / `--deny` package policy (best-effort parsing of `pkg -r ... upgrade -n`)
- `--reuse` / `--force-recreate` / auto-suffix BE name if already exists
- Colorized output (disable with `--no-color`), robust mount handling, safe unmount traps
