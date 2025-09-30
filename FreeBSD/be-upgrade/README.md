# be-upgrade.sh

**Version:** 0.3.1  
**Platform:** FreeBSD (ZFS Boot Environments)  
**License:** MIT

POSIX `/bin/sh`-compliant script to create/update a **ZFS Boot Environment (BE)**, run a **chrooted `pkg` upgrade** against it, and activate the BE either **temporarily** (next boot) or **permanently**. Includes a **promote-after-reboot** flow via a marker file — no `rc.d`.

## Install
```bash
curl -o /usr/local/scripts/be-upgrade.sh https://raw.githubusercontent.com/kmansur/Scripts/refs/heads/main/FreeBSD/be-upgrade/be-upgrade.sh
chmod +x /usr/local/scripts/be-upgrade.sh
```

> Replace paths in your automation accordingly (`/usr/local/scripts`).

## Quick start
```bash
sudo /usr/local/scripts/be-upgrade.sh --pre-flight
sudo /usr/local/scripts/be-upgrade.sh -P --debug
sudo reboot
# After booting into the new BE:
sudo /usr/local/scripts/be-upgrade.sh --finalize
```

## Highlights (since v0.2)
- `--dry-run`: show full plan; no changes
- `--pre-flight`: validations only (root/tools/mountpoint/BE/marker; zpool free hint)
- `--allow` / `--deny`: enforce package policy vs `pkg -r <MNT> upgrade -n` plan
- Fully POSIX `/bin/sh` (no process substitution; temp files for set ops)
