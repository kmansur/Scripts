# netdev_backup

Python script for automated backup of network device configurations (routers and switches) via SSH.

## Features

- **Multi-vendor support**: Juniper MX, Extreme Networks (and expandable for others).
- **Vendor-specific collection**: Uses appropriate commands for each manufacturer.
- **Local backup**: Saves configuration files to local directory with timestamp.
- **Git integration**: Commits and pushes backups to internal Git repository.
- **Email notifications**: Sends HTML alerts only in case of failures.
- **Flexible authentication**: Support for password or SSH key authentication.
- **Parallel processing**: Uses threads for simultaneous backups.
- **Retries and logging**: Automatic retry attempts and detailed logs.

## Requirements

- Python 3.6+
- Libraries: `paramiko`, `python-dotenv`, `GitPython`, `mysql-connector-python` (optional for DB)
- SSH access to devices
- Configured Git repository

## Installation

1. Clone or copy the script to `/usr/local/scripts/netdev_backup.py`
2. Install dependencies: `pip install paramiko python-dotenv GitPython`
3. Create configuration directory: `mkdir -p /usr/local/etc/netdev_backup`
4. Configure `.env` file (see example below)
5. Configure JSON devices file (see example below)
6. Setup logging: `touch /var/log/netdev_backup.log && chmod 644 /var/log/netdev_backup.log`

## Configuration

### Environment file (`.env` at `/usr/local/etc/netdev_backup/netdev_backup.env`)

```bash
# Directories
BACKUP_DIR=/var/backups/netdev
GIT_REPO_DIR=/var/git/netdev_backups

# Devices
DEVICES_FILE=/usr/local/etc/netdev_backup/devices.json

# Email (optional)
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=user@example.com
SMTP_PASS=password
EMAIL_FROM=backup@example.com
EMAIL_TO=admin@example.com,support@example.com

# SSH
SSH_TIMEOUT=15
MAX_WORKERS=4
RETRY_COUNT=2
```

### Devices file (`/usr/local/etc/netdev_backup/devices.json`)

```json
[
  {
    "ip": "192.168.1.1",
    "vendor": "juniper",
    "user": "backup",
    "password": "password123",
    "ssh_key": null,
    "ssh_passphrase": null
  },
  {
    "ip": "192.168.1.2",
    "vendor": "extreme",
    "user": "admin",
    "password": null,
    "ssh_key": "/home/backup/.ssh/id_rsa",
    "ssh_passphrase": null
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

- **SSH connection error**: Check credentials, firewall, and port 22 access.
- **Command not found**: Confirm if the device supports the commands used.
- **Git push fails**: Verify if the repository is configured and accessible.
- **Email not sent**: Confirm SMTP settings and whether there are backup failures.

## License

This script is provided "as is", without warranties. Use at your own risk.