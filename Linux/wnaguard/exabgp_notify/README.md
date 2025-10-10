# exabgp-notify (v0.1.1)

**Tail ExaBGP logs and push notifications to Telegram / Email**  
*Tested on Debian 12 (bookworm)*

## What it does

`exabgp-notify` is a tiny, decoupled companion for ExaBGP. It **does not** touch your BGP sessions.  
Instead, it **reads ExaBGP log lines** (via `tail -F`) and, whenever it finds a
`route added` or `route removed`, it sends a concise notification to **Telegram** and/or **Email (SMTP)**.

Highlights:

- Zero changes to your ExaBGP config or BGP processes
- Lightweight (Python 3 stdlib only – no extra packages)
- Handles log rotation (`tail -F`)
- De-duplication and throttling knobs to control noise
- Systemd unit with security hardening options
- Uses an **INI-like environment file** in `/etc/exabgp-notify/exabgp-notify.cfg`

> The parser is tuned for human-readable lines like:
>
> `Thu, 09 Oct 2025 17:21:33 ... api route added to neighbor 172.31.192.1 : 100.100.100.0/24 next-hop 10.0.0.1 local-preference 210 community 66666:615`

---

## Tested environment

- **OS**: Debian 12 (bookworm)
- **ExaBGP**: using standard file logging (e.g. `/var/log/exabgp/exabgp.log`), loglevel DEBUG/INFO
- **Systemd**: present by default on Debian 12

> It should work on other systemd-based distributions with minimal changes.

---

## Files layout (this repository)

```
usr/local/scripts/exabgp_notify.py           # main script (read from STDIN; send Telegram/Email)
etc/exabgp-notify/exabgp-notify.cfg          # config file (KEY=VALUE; also works as systemd EnvironmentFile)
etc/systemd/system/exabgp-notify.service     # systemd unit
CHANGELOG.md
README.md
```

---

## Installation

**1) Copy files to the target paths**

```bash
sudo install -d -m 0755 /usr/local/scripts
sudo install -m 0755 usr/local/scripts/exabgp_notify.py /usr/local/scripts/

sudo install -d -m 0755 /etc/exabgp-notify
sudo install -m 0640 etc/exabgp-notify/exabgp-notify.cfg /etc/exabgp-notify/

sudo install -m 0644 etc/systemd/system/exabgp-notify.service /etc/systemd/system/
```

**2) Permissions**

- The service is configured to run as user `exabgp`.  
  Ensure this user can **read** the ExaBGP log file (default: `/var/log/exabgp/exabgp.log`). Options:
  - Make `exabgp` a member of the group owning the log (often `adm` on Debian):  
    `sudo usermod -aG adm exabgp` (you may need to re-login the service user)
  - Or grant ACL read permission:  
    `sudo setfacl -m u:exabgp:r /var/log/exabgp/exabgp.log`
  - Or run the service as `root` (last resort): edit `User=`/`Group=` in the unit.

**Config ownership & directory access**

Ensure the service can read the config file and traverse the directory:

```bash
sudo chgrp exabgp /etc/exabgp-notify/exabgp-notify.cfg
sudo chmod 0640 /etc/exabgp-notify/exabgp-notify.cfg
sudo chmod 0755 /etc/exabgp-notify
```

Quick verification:

```bash
sudo -u exabgp head -n1 /etc/exabgp-notify/exabgp-notify.cfg
sudo -u exabgp tail -n1 /var/log/exabgp/exabgp.log
```

**3) Configure `/etc/exabgp-notify/exabgp-notify.cfg`**

Edit and set at least one delivery channel:

```ini
# Path to ExaBGP log (used by systemd tail -F)
LOG_FILE="/var/log/exabgp/exabgp.log"

# Telegram (optional)
TELEGRAM_BOT_TOKEN="123456:abcdef..."
TELEGRAM_CHAT_ID="987654321"

# SMTP (optional)
SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="user@example.com"
SMTP_PASS="super-secret"
MAIL_FROM="ExaBGP <noreply@example.com>"
MAIL_TO="you@example.com,other@example.com"

# Notify on which actions
ONLY_ACTIONS="added,removed"

# Noise control
THROTTLE_WINDOW_SEC="60"
THROTTLE_MAX="30"
DEDUP_TTL_SEC="60"

# TLS behavior
SMTP_SSL=""           # set to "1" for implicit TLS (port 465)
SMTP_STARTTLS="1"     # try STARTTLS on plain SMTP (typ. port 587)

# Verbose logs (matched events / decisions) to journal
VERBOSE="0"
```

**4) Enable and start**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now exabgp-notify.service
sudo systemctl status exabgp-notify.service
```

**5) Quick test**

Append one test line **directly** to the ExaBGP log file (this is the file the service tails):

```bash
sudo tee -a /var/log/exabgp/exabgp.log >/dev/null <<'EOF'
Thu, 09 Oct 2025 17:21:33 000 api           route added to neighbor 172.31.192.1 local-ip 172.31.192.2 local-as 66666 peer-as 66666 router-id 172.31.192.2 family-allowed in-open : 100.100.100.0/24 next-hop 10.0.0.1 local-preference 210 community 66666:615
EOF
```

Watch the service logs (set `VERBOSE="1"` temporarily if you want more details):

```bash
journalctl -u exabgp-notify -f
```

---

### Email TLS settings

- **587 + STARTTLS** (recommended):
  ```ini
  SMTP_HOST="smtp.example.com"
  SMTP_PORT="587"
  SMTP_STARTTLS="1"
  SMTP_SSL="0"
  ```

- **465 (SMTPS)**:
  ```ini
  SMTP_HOST="smtp.example.com"
  SMTP_PORT="465"
  SMTP_SSL="1"
  SMTP_STARTTLS="0"
  ```

Some providers require the `MAIL_FROM` domain to match `SMTP_USER`.
Check your provider’s docs and make sure SPF/DMARC are aligned, otherwise mail may be dropped or land in spam.

---

## Troubleshooting

- **No notifications**:
  - Check the unit logs: `journalctl -u exabgp-notify -f`
  - Verify the log path (`LOG_FILE`) and that `tail -F` prints lines.
  - Ensure the service user can read the log file (permissions/ACL/group).
  - Set `VERBOSE="1"` and/or `DRY_RUN="1"` to see parser decisions.

- **Email not sent**:
  - Confirm SMTP host/port and credentials.
  - For port **587**, keep `SMTP_STARTTLS="1"` and `SMTP_SSL="0"`.
  - For port **465**, set `SMTP_SSL="1"` and `SMTP_STARTTLS="0"`.
  - Some providers require `MAIL_FROM` to match `SMTP_USER`.
  - Check `journalctl` for `[exabgp_notify] smtp error:` messages.

- **Telegram not sent**:
  - Verify bot token and chat ID (ensure the bot has been started by the user/group).

- **Too many alerts**:
  - Increase `DEDUP_TTL_SEC` and/or tighten `THROTTLE_*` values.
  - Restrict `ONLY_ACTIONS` to `added` or `removed` only.

---

## Uninstall

```bash
sudo systemctl disable --now exabgp-notify.service
sudo rm -f /etc/systemd/system/exabgp-notify.service
sudo rm -rf /etc/exabgp-notify
sudo rm -f /usr/local/scripts/exabgp_notify.py
sudo systemctl daemon-reload
```

---

## Versioning

- **v0.1.1** – SMTP SSL/STARTTLS toggles, verbose logging; doc updates.
- **v0.1**   – Initial release.

---

## Quick install (using bundled `install.sh`)

From the project root (this folder):

```bash
chmod +x install.sh
./install.sh
```

**Options**:
- `-y` / `--yes` : non-interactive install (auto-confirm).
- `-b main`      : choose branch when downloading from GitHub.
- `--download-only` : only fetch/extract; do not install.
- `--prefix DIR` : working directory for downloads.
- `--uninstall`  : uninstall exabgp-notify (disable service and remove files).

You can also run the installer anywhere; it will download the repo and extract the
`Linux/wnaguard/exabgp_notify` subdirectory automatically.

### Uninstall

```bash
./install.sh --uninstall
# or non-interactive
./install.sh --uninstall -y
```
