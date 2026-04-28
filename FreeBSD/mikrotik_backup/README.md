# MikroTik Backup Script

**Version:** 1.11.3  
**Author:** Karim Mansur - NetTech  
**Tested on:** FreeBSD  
**Language:** Python 3

## Overview

A robust automated backup solution for MikroTik RouterOS devices. This script connects to multiple MikroTik devices via SSH, exports their configurations, stores backups in a Git repository for version control, and sends email notifications when failures occur.

The script is designed to be run periodically (via cron) to maintain a complete backup history of all MikroTik device configurations.

## Key Features

- **Automated SSH Backup**: Connects to MikroTik devices and exports configurations using SSH
- **Version Control**: Automatically commits backup files to a Git repository
- **Database Integration**: Retrieves device information from a MySQL/MariaDB database
- **Parallel Processing**: Uses thread pooling to backup multiple devices simultaneously
- **Retry Logic**: Automatically retries failed backup attempts
- **Email Notifications**: Sends HTML email alerts when backup failures occur (only on failure)
- **Sensitive Data Handling**: Optional flag to include or exclude sensitive data (passwords) in exports
- **Comprehensive Logging**: All operations logged to file and console
- **Per-Device Filtering**: Ability to backup a single device for testing or manual execution

## Requirements

### System Requirements
- **Operating System**: FreeBSD (tested and verified)
- **Python**: Version 3.7 or higher
- **SSH Access**: To target MikroTik devices
- **Network**: Connectivity to MikroTik devices and database server

### Python Dependencies
```bash
pip install mysql-connector-python paramiko python-dotenv gitpython
```

Or install from requirements file:
```bash
pip install -r requirements.txt
```

### System Dependencies
- `git` command-line tool
- SSH client (usually included in FreeBSD base system)

### Database
- MySQL or MariaDB server with a database containing gateway information
- Database must have a `gateway` table with columns: `ip`, `login`, `senha` (password), `descricao` (description)

## Installation

### 1. Copy Files
```bash
# Create configuration directory
mkdir -p /usr/local/etc/mikrotik_backup

# Copy script
cp mikrotik_backup.py /usr/local/backups/scripts/

# Copy environment file
cp mikrotik_backup.env /usr/local/etc/mikrotik_backup/
chmod 600 /usr/local/etc/mikrotik_backup/mikrotik_backup.env
```

### 2. Create Required Directories
```bash
mkdir -p /usr/local/backups/mikrotik-config
mkdir -p /var/log

# Set appropriate permissions
chmod 755 /usr/local/backups/mikrotik-config
```

### 3. Initialize Git Repository
```bash
cd /usr/local/backups/mikrotik-config
git init
git remote add origin <your-git-repo-url>  # Optional, if using remote repository
git config user.name "MikroTik Backup"
git config user.email "backup@yourdomain.com"
```

### 4. Install Python Dependencies
```bash
pip install mysql-connector-python paramiko python-dotenv gitpython
```

## Configuration

### Environment File: `mikrotik_backup.env`

The script reads all configuration from `/usr/local/etc/mikrotik_backup/mikrotik_backup.env`. 

Key configuration sections:

#### Database Configuration
```env
DB_HOST=db.example.com
DB_NAME=network_db
DB_USER=backup_user
DB_PASS=secure_password
```

#### SSH Settings
```env
SSH_TEST_IP=172.17.30.2          # Network connectivity test IP
SSH_TIMEOUT=10                    # Seconds to wait for SSH connections
```

#### Backup Storage
```env
BACKUP_DIR=/usr/local/backups/mikrotik-config
GIT_REPO_DIR=/usr/local/backups/mikrotik-config
GIT_BRANCH=main
```

#### Performance Settings
```env
MAX_WORKERS=10                    # Parallel backup threads
RETRY_COUNT=2                     # Retry attempts on failure (adds 2 more attempts)
```

#### Email Notifications
```env
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=backup@example.com
SMTP_PASS=email_password
EMAIL_FROM=backup@example.com
EMAIL_TO=admin@example.com,tech@example.com
```

See `mikrotik_backup.env` for detailed comments on each configuration option.

## Database Schema

The script expects a MySQL/MariaDB table named `gateway` with the following structure:

```sql
CREATE TABLE gateway (
    id INT PRIMARY KEY AUTO_INCREMENT,
    ip VARCHAR(15) NOT NULL UNIQUE,
    login VARCHAR(50) NOT NULL,
    senha VARCHAR(100) NOT NULL,          -- Password (preferably encrypted at rest)
    descricao VARCHAR(100) NOT NULL       -- Device description (e.g., "PE-MAIN", "CE-BRANCH1")
) ENGINE=InnoDB;
```

### Filtering Logic

The script automatically filters devices to backup those matching the pattern:
```sql
WHERE descricao REGEXP '^(PE|CE)-'
```

This filters for devices whose description starts with "PE-" or "CE-" (e.g., Provider Edge, Customer Edge).

To modify this filtering, edit the `get_devices()` function in the script.

## Usage

### Basic Usage

Backup all configured devices:
```bash
python3 mikrotik_backup.py
```

### Command Line Options

```bash
# Backup a specific device by IP
python3 mikrotik_backup.py --ip 192.168.1.1

# Backup all devices with sensitive data (includes passwords)
python3 mikrotik_backup.py --with-secrets

# Send email notification if failures occur
python3 mikrotik_backup.py --email

# Verify configuration and database connectivity
python3 mikrotik_backup.py --check
```

### Usage Examples

```bash
# Standard backup run with email on failure
python3 mikrotik_backup.py --email

# Backup specific device with secrets for local archival
python3 mikrotik_backup.py --ip 10.1.1.1 --with-secrets

# Verify everything is working
python3 mikrotik_backup.py --check
```

## Cron Setup

To run backups automatically every day at 2 AM, add to FreeBSD crontab:

```bash
# As root or appropriate user
crontab -e

# Add line:
0 2 * * * /usr/bin/python3 /usr/local/backups/scripts/mikrotik_backup.py --email
```

For weekly backups with secrets:
```bash
0 3 * * 0 /usr/bin/python3 /usr/local/backups/scripts/mikrotik_backup.py --with-secrets --email
```

## Output and Logging

### Console Output
```
Total: 15 | Sucesso: 14 | Falha: 1
```

### Log File
Location: `/var/log/mikrotik_backup.log`

Log entries include timestamps, log levels (INFO, ERROR, WARNING), and detailed messages.

```
2024-04-28 02:15:30,123 [INFO] Processing device: PE-MAIN (10.1.1.1)
2024-04-28 02:15:45,456 [INFO] Backup saved: PE_MAIN_10_1_1_1.rsc
2024-04-28 02:16:00,789 [INFO] Git push completed
2024-04-28 02:16:15,012 [INFO] Email enviado
```

### Git Repository

Each backup creates a commit with timestamp:
```
Backup 2024-04-28 02:16:00.123456
```

View backup history:
```bash
cd /usr/local/backups/mikrotik-config
git log --oneline
git show <commit-hash>
```

## Email Notifications

Email alerts are sent **only when backup failures occur**.

### Email Features
- **HTML Format**: Well-formatted table with summary and details
- **Summary Table**: Shows total devices, successful backups, and failures
- **Failure Details**: Lists each failed device with its IP and error reason
- **Multiple Recipients**: Supports comma-separated email addresses

### Email Trigger
```bash
# Email sent only if failures exist
python3 mikrotik_backup.py --email
```

## Backup Files

Backup files are named following this convention:
```
<hostname>_<ip>.rsc
```

Example:
```
PE_MAIN_10_1_1_1.rsc
CE_BRANCH1_10_2_2_1.rsc
```

### File Locations
- **Default directory**: `/usr/local/backups/mikrotik-config/`
- **Temporary storage**: `/tmp/` (automatically cleaned up)

## Error Handling

The script handles various SSH connection errors:

| Error Code | Meaning | Action |
|-----------|---------|--------|
| `AUTH` | Authentication failed (wrong credentials) | Verify login/password in database |
| `TIMEOUT` | SSH connection timeout | Check network connectivity and SSH_TIMEOUT setting |
| `SSH` | SSH protocol error | Verify SSH access and MikroTik SSH configuration |
| `EXPORT` | Export command failed on device | Check device resources and available space |

## Troubleshooting

### Database Connection Errors
```
Error: Unknown database 'db_name'
```
- Verify DB_HOST, DB_NAME, DB_USER, and DB_PASS in mikrotik_backup.env
- Test connectivity: `mysql -h DB_HOST -u DB_USER -p DB_NAME`

### SSH Connection Failures
```
[ERROR] (10.1.1.1) SSH
```
- Verify device IP and credentials in database
- Test manually: `ssh user@10.1.1.1`
- Check SSH_TIMEOUT setting (increase if network is slow)

### No Devices Found
```
Total: 0 | Sucesso: 0 | Falha: 0
```
- Verify database table has records matching the filter pattern (`^(PE|CE)-`)
- Check database connectivity
- Review query in `get_devices()` function

### Email Not Sending
```
[ERROR] Erro email: ...
```
- Verify SMTP credentials in mikrotik_backup.env
- Check SMTP_PORT matches your email provider (typically 587 for TLS)
- Ensure SMTP_USER/SMTP_PASS are correct
- Check firewall allows outbound SMTP traffic

### Permission Denied Errors
```
Permission denied: /var/log/mikrotik_backup.log
```
- Ensure script user has write access to directories:
  ```bash
  chmod 755 /usr/local/backups/mikrotik-config
  chmod 755 /var/log
  ```

### Git Push Failures
```
[ERROR] Git push failed
```
- Verify Git repository is initialized: `cd /usr/local/backups/mikrotik-config && git status`
- Check git remote configured: `git remote -v`
- Verify git credentials if using remote repository

## Security Considerations

1. **Environment File Permissions**
   ```bash
   chmod 600 /usr/local/etc/mikrotik_backup/mikrotik_backup.env
   chown root:wheel /usr/local/etc/mikrotik_backup/mikrotik_backup.env
   ```

2. **Database Credentials**
   - Use dedicated user with minimal privileges
   - Change passwords regularly
   - Never store production credentials in version control

3. **SSH Keys vs Passwords**
   - Consider using SSH key authentication instead of passwords
   - Store keys securely with appropriate permissions (600)

4. **Sensitive Data Flag**
   - Use `--with-secrets` flag carefully
   - Store secret backups separately from version control
   - Rotate sensitive data regularly

5. **Log Files**
   - Log file may contain error messages with sensitive data
   - Rotate logs regularly with appropriate retention policy

## Performance Notes

### Tuning MAX_WORKERS
- Default: 10 workers
- **Low network bandwidth**: Reduce to 4-5
- **High-latency connections**: Reduce to 5-8  
- **Many devices (100+)**: Can increase to 16-20
- **Limited server resources**: Keep at 5-8

### Recommended Backup Schedule
- **Daily full backups**: Off-peak hours (2-4 AM)
- **Weekly backups with secrets**: For archival purposes
- **Storage**: Plan for ~10-50KB per device config

## Support and Issues

For bug reports, feature requests, or issues:
1. Check the log file: `/var/log/mikrotik_backup.log`
2. Run with `--check` flag to verify configuration
3. Test SSH connectivity manually: `ssh user@device-ip`
4. Verify database connectivity: `mysql -h host -u user -p database`

## License

See LICENSE file in this repository.

## Changelog

### Version 1.11.3
- Email sent only on backup failures
- Support for multiple email recipients
- HTML formatted email reports
- Enhanced error reporting in email notifications

### Earlier Versions
See CHANGELOG.md for detailed version history.

## Testing Information

✅ **This script has been tested and verified on FreeBSD**

Testing environment:
- **OS**: FreeBSD 12.x / 13.x
- **Python**: Python 3.9+
- **Database**: MariaDB 10.5+
- **MikroTik**: RouterOS 6.x and 7.x

## Author

**Karim Mansur** - NetTech  
Created for enterprise MikroTik backup automation
