# exabgp-notify (v0.1.3)

Tail ExaBGP logs and push notifications to Telegram / Email.  
Tested on Debian 12 (bookworm).

- No changes to ExaBGP config: we just read the log file (`tail -F`).
- Stdlib-only Python 3. Handles log rotation, dedup, throttling.
- TLS support: `SMTP_STARTTLS` (587) or `SMTP_SSL` (465).
- Verbose debug: `VERBOSE="1"` prints matches/decisions to journal.
- **Robust multiple recipients** in `MAIL_TO` (comma or semicolon; names allowed).
- Installer **never overwrites** an existing config; writes a versioned template instead.

## Files
```
usr/local/scripts/exabgp_notify.py
etc/exabgp-notify/exabgp-notify.cfg
etc/systemd/system/exabgp-notify.service
install.sh
CHANGELOG.md
README.md
```

---

## Quick install (using bundled `install.sh`)
```bash
chmod +x install.sh
./install.sh
```
Options:
- `-y` / `--yes` : non-interactive
- `-b main`      : choose branch when downloading from GitHub
- `--download-only` : only fetch/extract
- `--prefix DIR` : working directory for downloads
- `--uninstall`  : uninstall exabgp-notify

### Installer behavior regarding config
- The installer **never overwrites** your active config: `/etc/exabgp-notify/exabgp-notify.cfg`.
- If a config already exists, it installs a versioned template, e.g.:  
  `/etc/exabgp-notify/exabgp-notify.cfg.v0.1.3` and prints a **highlighted notice** to merge changes.

---

## Download (wget)
You can download from the repository using `wget`:
```bash
wget https://github.com/kmansur/Scripts/tree/main/Linux/wnaguard/exabgp_notify
```
> Note: this URL is a GitHub HTML page (“tree”). For automation, prefer release assets or raw links.

---

## Installation (manual)
```bash
sudo install -d -m 0755 /usr/local/scripts
sudo install -m 0755 usr/local/scripts/exabgp_notify.py /usr/local/scripts/

sudo install -d -m 0755 /etc/exabgp-notify
sudo install -m 0640 etc/exabgp-notify/exabgp-notify.cfg /etc/exabgp-notify/

sudo install -m 0644 etc/systemd/system/exabgp-notify.service /etc/systemd/system/
```

### Permissions
Ensure the service (user `exabgp`) can read the config and traverse directory:
```bash
sudo chgrp exabgp /etc/exabgp-notify/exabgp-notify.cfg
sudo chmod 0640 /etc/exabgp-notify/exabgp-notify.cfg
sudo chmod 0755 /etc/exabgp-notify
```
Grant log read (Debian tip):
```bash
sudo usermod -aG adm exabgp
# or: sudo setfacl -m u:exabgp:r /var/log/exabgp/exabgp.log
```
Quick verification:
```bash
sudo -u exabgp head -n1 /etc/exabgp-notify/exabgp-notify.cfg
sudo -u exabgp tail -n1 /var/log/exabgp/exabgp.log
```

---

## Configure `/etc/exabgp-notify/exabgp-notify.cfg`
```ini
LOG_FILE="/var/log/exabgp/exabgp.log"

# SMTP (example for 587 + STARTTLS)
SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_STARTTLS="1"
SMTP_SSL="0"
SMTP_USER="user@example.com"
SMTP_PASS="super-secret"
MAIL_FROM="user@example.com"

# Multiple recipients: comma or semicolon separated; names allowed
MAIL_TO="alice@example.com, bob@example.com; "Ops Team" <ops@example.com>"

# Telegram (optional)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

ONLY_ACTIONS="added,removed"
THROTTLE_WINDOW_SEC="60"
THROTTLE_MAX="30"
DEDUP_TTL_SEC="60"
VERBOSE="0"
DRY_RUN="0"
```

---

## Enable and start
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now exabgp-notify.service
sudo systemctl status exabgp-notify.service
```

## Test
Append a test line directly to the ExaBGP log:
```bash
sudo tee -a /var/log/exabgp/exabgp.log >/dev/null <<'EOF'
Thu, 09 Oct 2025 17:21:33 000 api           route added to neighbor 172.31.192.1 local-ip 172.31.192.2 local-as 53140 peer-as 53140 router-id 172.31.192.2 family-allowed in-open : 187.120.203.0/24 next-hop 10.0.0.1 local-preference 210 community 53140:615
EOF
```
Then:
```bash
journalctl -u exabgp-notify -f
```

---

## Email TLS matrix
- **587 + STARTTLS**:
  ```ini
  SMTP_PORT="587"
  SMTP_STARTTLS="1"
  SMTP_SSL="0"
  ```
- **465 (SMTPS)**:
  ```ini
  SMTP_PORT="465"
  SMTP_SSL="1"
  SMTP_STARTTLS="0"
  ```

---

## Troubleshooting
- If some recipients don’t receive mail, check the journal for:
  ```
  [exabgp_notify] smtp refused recipients: {...}
  ```
  This contains the per-recipient SMTP reply code/reason.
- Ensure `MAIL_FROM` domain aligns with provider policy (SPF/DMARC).
- Try `VERBOSE="1"` to log match and send decisions.

---

## Uninstall
```bash
./install.sh --uninstall
# or:
sudo systemctl disable --now exabgp-notify.service
sudo rm -f /etc/systemd/system/exabgp-notify.service
sudo rm -rf /etc/exabgp-notify
sudo rm -f /usr/local/scripts/exabgp_notify.py
sudo systemctl daemon-reload
```
