# conf2git



`conf2git` is a lightweight shell script that exports system configuration directories into a Git repository.  

It is designed for environments with multiple servers (Linux, FreeBSD, etc.) where you want to keep track of changes in `/etc`, `/usr/local/etc`, or any other critical configuration files — with per-host isolation.



---



## Features



**Sparse-checkout**

Each host only sees its own subtree (`$OS/$HOSTNAME\_SHORT`) inside the repository.



**Self-update**  

On every run the script checks for updates.  

If `AUTO\_UPDATE="yes"`, it replaces itself with the latest version from the configured `UPDATE\_URL`.  

If `AUTO\_UPDATE="no"`, it warns when an update is available.



**Lockfile**  

Prevents concurrent executions (`/var/run/conf2git.lock` by default).



**Dry-run mode**  

Simulate synchronization and commits without touching the repository.



**Configurable Git identity**  

Each commit can use a dedicated Git user (e.g. `Backup Bot`).



**Logging**  

Appends all actions to a configurable log file.



---



## Installation



1\. Clone or download the script into `/usr/local/scripts/`:



```bash

curl -o /usr/local/scripts/conf2git.sh https://raw.githubusercontent.com/kmansur/Scripts/main/FreeBSD/conf2git/conf2git.sh
curl -o /usr/local/scripts/conf2git.cfg https://raw.githubusercontent.com/kmansur/Scripts/main/FreeBSD/conf2git/conf2git.cfg.sample

chmod +x /usr/local/scripts/conf2git.sh

```
