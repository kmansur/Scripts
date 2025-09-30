# be-upgrade.sh

**Version:** 0.3.1  
**Platform:** FreeBSD (ZFS Boot Environments)  
**License:** MIT

A POSIX `/bin/sh`-compliant, single-file script that creates/updates a **ZFS Boot Environment (BE)**, runs a **chrooted `pkg` upgrade** inside it, and **activates** the BE either **temporarily** (next boot only) or **permanently**. It also supports a **promote-after-reboot** workflow using a small **marker file** (no `rc.d` hooks required).

The script is designed for **safe upgrades**: upgrades happen in a **separate BE**, so you can reboot into the new BE and **roll back** easily if needed.

[...truncated in this placeholder build...]
