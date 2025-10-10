# exabgp-notify (v0.1)

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
> `Thu, 09 Oct 2025 17:21:33 ... api route added to neighbor 172.31.192.1 : 187.120.203.0/24 next-hop 10.0.0.1 local-preference 210 community 53140:615`

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

- Script permissions: `0755` (executable).
- Config permissions: `0640` (contains secrets like SMTP password and Telegram token).

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
```

**4) Enable and start**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now exabgp-notify.service
sudo systemctl status exabgp-notify.service
```

**5) Quick test**

Inject a fake log line (format matters):

```bash
logger -t exabgp "Thu, 09 Oct 2025 17:21:33 000 api route added to neighbor 172.31.192.1 : 187.120.203.0/24 next-hop 10.0.0.1 local-preference 210 community 53140:615"
# or echo it directly into the log (if permitted)
```

Watch the service logs:

```bash
journalctl -u exabgp-notify -f
```

---

## How it works (under the hood)

- The systemd unit runs:  
  `tail -F "$LOG_FILE" | /usr/local/scripts/exabgp_notify.py --config /etc/exabgp-notify/exabgp-notify.cfg`

- The script:
  - Parses each line with a regex that extracts: timestamp, action (added/removed), neighbor, prefix, next-hop, local-pref, community.
  - Drops lines that don't match or whose action is not in `ONLY_ACTIONS`.
  - Applies **de-duplication** (suppresses identical events for `DEDUP_TTL_SEC` seconds).
  - Applies **throttling** (max `THROTTLE_MAX` messages per `THROTTLE_WINDOW_SEC` seconds).
  - Sends the message to Telegram and/or Email (whichever is configured).

- No external Python packages, no ExaBGP API coupling.

---

## Troubleshooting

- **No notifications**:
  - Check the unit logs: `journalctl -u exabgp-notify -f`
  - Verify the log path (`LOG_FILE`) and that `tail -F` prints lines.
  - Ensure the service user can read the log file (permissions/ACL/group).
  - Temporary set `DRY_RUN="1"` in the config to verify parsing (messages are printed to stderr).

- **Email not sent**:
  - Confirm SMTP host/port and credentials.
  - Some providers require an app-specific password or enforced TLS/STARTTLS.
  - Check for SMTP errors in the journal logs.

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

- **v0.1** – Initial release.

See `CHANGELOG.md` for details.

---

## Security notes

- Keep `/etc/exabgp-notify/exabgp-notify.cfg` with `0640` permissions (or stricter).
- Run the service as a low-privilege user whenever possible.
- Consider network egress filtering for the host if you need to restrict where notifications can go.

---

## License

This sample is provided "as is". Add your preferred license if publishing publicly.
