# netdev_backup

Python script for automated backup of network device configurations (routers and switches) via SSH or Telnet.

## Features

- **Multi-vendor support**: MikroTik, Juniper MX, Extreme Networks, HP/Aruba ProCurve, HP/3Com/H3C Comware, and Ubiquiti.
- **Hybrid inventory**: Loads MikroTik devices from MySQL and non-MikroTik devices from JSON.
- **Multiple transports**: Supports SSH and explicit Telnet for legacy JSON-managed devices.
- **Vendor-specific collection**: Uses appropriate commands for each manufacturer.
- **Local backup**: Saves configuration files to local vendor subdirectories with stable device filenames.
- **Git integration**: Commits and pushes backups to internal Git repository.
- **Email notifications**: Sends HTML alerts only in case of failures.
- **Flexible authentication**: Support for password or SSH key authentication.
- **Parallel processing**: Uses threads for simultaneous backups.
- **Retries and logging**: Automatic retry attempts and detailed logs.

## Requirements

- Python 3.6+
- Libraries: `paramiko`, `python-dotenv`, `GitPython`, `mysql-connector-python`
- SSH or Telnet access to devices, depending on each JSON inventory entry
- Configured Git repository

## Installation

### Standalone installer

Download only `netdev_backup_install.sh`, make it executable, and run it as root:

```bash
fetch -o netdev_backup_install.sh https://raw.githubusercontent.com/kmansur/Scripts/main/FreeBSD/netdev_backup/netdev_backup_install.sh
chmod +x netdev_backup_install.sh
./netdev_backup_install.sh
```

The installer:

- checks required directories and asks before creating missing paths;
- fetches the current project files from GitHub with `git`;
- installs missing files interactively;
- compares installed files with the current GitHub version;
- can run a production configuration wizard for `netdev_backup.env`;
- creates local snapshots before any overwrite;
- preserves existing `netdev_backup.env` and `devices.json`;
- supports rollback from local snapshots.

Useful installer commands:

```bash
./netdev_backup_install.sh status
./netdev_backup_install.sh configure
./netdev_backup_install.sh update
./netdev_backup_install.sh rollback
```

The `configure` command asks for the database, inventory file, backup paths, Git repository path, log file, SSH/security settings, retry/performance settings, and optional SMTP alerts. It previews the generated environment file with passwords masked, creates required directories after confirmation, creates an initial JSON inventory if needed, and backs up any existing environment file before replacing it.

### Manual installation

1. Clone or copy the script to `/usr/local/scripts/netdev_backup.py`
2. Install dependencies: `pip install paramiko python-dotenv GitPython mysql-connector-python`
3. Create configuration directory: `mkdir -p /usr/local/etc/netdev_backup`
4. Configure `.env` file (see example below)
5. Configure MySQL access for MikroTik devices and the JSON devices file for non-MikroTik devices
6. Setup logging: `touch /var/log/netdev_backup.log && chmod 644 /var/log/netdev_backup.log`

## Configuration

### Environment file (`.env` at `/usr/local/etc/netdev_backup/netdev_backup.env`)

```bash
# Database used to load MikroTik inventory
DB_HOST=db.yourdomain.com
DB_PORT=3306
DB_NAME=network_inventory
DB_USER=netdev_backup
DB_PASS=change_this_password

# JSON inventory used for non-MikroTik devices
DEVICES_FILE=/usr/local/etc/netdev_backup/devices.json

# Directories
BACKUP_DIR=/var/backups/netdev
GIT_REPO_DIR=/var/git/netdev_backups
LOG_FILE=/var/log/netdev_backup.log

# Email (optional)
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_STARTTLS=true
SMTP_USER=user@example.com
SMTP_PASS=password
EMAIL_FROM=backup@example.com
EMAIL_TO=admin@example.com,support@example.com

# SSH
SSH_TIMEOUT=15
MAX_WORKERS=4
RETRY_COUNT=2
STRICT_HOST_KEY_CHECKING=false
```

### Devices file (`/usr/local/etc/netdev_backup/devices.json`)

This JSON file is intended for non-MikroTik devices. MikroTik devices are loaded from MySQL using the same `gateway` inventory pattern used by `mikrotik_backup.py`.

Supported JSON vendors and aliases:

- `juniper`
- `extreme`
- `hp_procurve`, `hp`, `aruba`, `arubaos_switch`
- `hp_comware`, `h3c`, `3com`, `3com_comware`
- `ubiquiti_edgeswitch`, `edgeswitch`, `ubiquiti`
- `ubiquiti_edgeos`, `edgeos`
- `ubiquiti_unifi`, `unifi`

For UniFi-managed devices, controller-level backups are still preferred. The `ubiquiti_unifi` collector attempts a direct `mca-ctrl -t dump-cfg` only when shell access is available.

Supported transports:

- `ssh` for modern devices and devices with SSH enabled.
- `telnet` for legacy devices only. Use it only on isolated management networks with ACLs and read-only users.

```json
[
  {
    "ip": "192.168.1.1",
    "vendor": "juniper",
    "transport": "ssh",
    "port": 22,
    "user": "backup",
    "password": "password123",
    "ssh_key": null,
    "ssh_passphrase": null,
    "enable_password": null,
    "enable_command": null,
    "prompt": null
  },
  {
    "ip": "192.168.1.2",
    "vendor": "extreme",
    "transport": "ssh",
    "port": 22,
    "user": "admin",
    "password": null,
    "ssh_key": "/home/backup/.ssh/id_rsa",
    "ssh_passphrase": null,
    "enable_password": null,
    "enable_command": null,
    "prompt": null
  },
  {
    "ip": "192.168.1.3",
    "vendor": "3com",
    "transport": "telnet",
    "port": 23,
    "user": "admin",
    "password": "password123",
    "ssh_key": null,
    "ssh_passphrase": null,
    "enable_password": null,
    "enable_command": "enable",
    "prompt": null
  }
]
```

## Usage

### Full backup
```bash
python3 netdev_backup.py
```

### Backup with options
```bash
# Backup only a specific IP
python3 netdev_backup.py --ip 192.168.1.1

# Backup only a vendor
python3 netdev_backup.py --vendor juniper

# Backup only legacy 3Com/Comware devices from JSON
python3 netdev_backup.py --vendor 3com

# Backup only MikroTik devices from MySQL
python3 netdev_backup.py --vendor mikrotik

# Validate inventory sources without connecting
python3 netdev_backup.py --check

# With email on failure
python3 netdev_backup.py --email

# Attempting to collect secrets (if supported)
python3 netdev_backup.py --with-secrets

# Using alternative devices file
python3 netdev_backup.py --devices-file /alternative/path/devices.json
```

## Logging

Logs are written to `/var/log/netdev_backup.log`. Default log level is INFO.

## Security

- Use dedicated users with minimal privileges (e.g., `read-only` on Juniper).
- Prefer SSH key authentication over password authentication.
- Use Telnet only when a device has no SSH support, and restrict it to protected management networks.
- Restrict access to configuration files and backups.

## Expansion

To add support for new vendors:
1. Add `collect_<vendor>()` function in `export_config()`.
2. Update `get_hostname()` if necessary.
3. Test with real device.

## Cron example

```bash
# Daily backup at 2 AM
0 2 * * * /usr/bin/python3 /usr/local/scripts/netdev_backup.py --email
```

## Troubleshooting

- **SSH/Telnet connection error**: Check credentials, firewall, and port access.
- **Command not found**: Confirm if the device supports the commands used.
- **Git push fails**: Verify if the repository is configured and accessible.
- **Email not sent**: Confirm SMTP settings and whether there are backup failures.

## License

This script is provided "as is", without warranties. Use at your own risk.
