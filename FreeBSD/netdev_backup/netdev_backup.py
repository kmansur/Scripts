#!/usr/bin/env python3
"""
Script: netdev_backup.py
Version: 1.1.0
Author: Karim Mansur - NetTech

Purpose:
- connects to Juniper routers and Extreme Networks switches over SSH
- collects configuration using vendor-specific commands
- saves backups to a local directory
- commits and pushes changes to a Git repository
- optionally sends email when failures occur
"""

import argparse
import html
import json
import logging
import os
import re
import smtplib
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from email.mime.text import MIMEText
from pathlib import Path

import paramiko
from dotenv import load_dotenv
from git import Repo

# =========================
# ENV
# =========================

ENV_PATH = "/usr/local/etc/netdev_backup/netdev_backup.env"

if not os.path.exists(ENV_PATH):
    print(f"ENV file not found: {ENV_PATH}")
    sys.exit(1)

load_dotenv(ENV_PATH)

BACKUP_DIR = os.getenv("BACKUP_DIR")
GIT_REPO_DIR = os.getenv("GIT_REPO_DIR")
DEVICES_FILE = os.getenv("DEVICES_FILE") or os.getenv("STATIC_DEVICES_FILE")

SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_PORT = int(os.getenv("SMTP_PORT", 587))
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")
EMAIL_FROM = os.getenv("EMAIL_FROM")
EMAIL_TO = os.getenv("EMAIL_TO")
SMTP_STARTTLS = os.getenv("SMTP_STARTTLS", "true").lower() in ("1", "true", "yes", "on")

SSH_TIMEOUT = int(os.getenv("SSH_TIMEOUT", 15))
MAX_WORKERS = int(os.getenv("MAX_WORKERS", 4))
RETRY_COUNT = int(os.getenv("RETRY_COUNT", 2))
STRICT_HOST_KEY_CHECKING = os.getenv("STRICT_HOST_KEY_CHECKING", "false").lower() in (
    "1",
    "true",
    "yes",
    "on",
)

# =========================
# LOG
# =========================

logging.getLogger("paramiko").setLevel(logging.WARNING)

LOG_FILE = os.getenv("LOG_FILE", "/var/log/netdev_backup.log")
log_handlers = [logging.StreamHandler(sys.stdout)]

try:
    log_handlers.insert(0, logging.FileHandler(LOG_FILE))
except OSError as exc:
    print(f"WARNING: could not open log file {LOG_FILE}: {exc}")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=log_handlers,
)

# =========================
# ARGS
# =========================


def parse_args():
    parser = argparse.ArgumentParser(
        description="Back up Juniper and Extreme Networks configurations to an internal Git repository"
    )
    parser.add_argument("--ip", help="Filter by device IP address")
    parser.add_argument("--vendor", choices=["juniper", "extreme"], help="Filter by vendor")
    parser.add_argument("--email", action="store_true", help="Send email only when failures occur")
    parser.add_argument("--with-secrets", action="store_true", help="Do not apply local secret redaction")
    parser.add_argument("--devices-file", help="JSON device file overriding DEVICES_FILE")
    parser.add_argument("--check", action="store_true", help="Validate configuration and list devices without connecting")
    parser.add_argument("--no-git-push", action="store_true", help="Save backups without committing/pushing to Git")
    return parser.parse_args()


# =========================
# VALIDATION
# =========================


def require_env(name, value):
    if not value:
        raise RuntimeError(f"Required environment variable is missing: {name}")


def validate_runtime_config(devices_file):
    require_env("BACKUP_DIR", BACKUP_DIR)
    require_env("GIT_REPO_DIR", GIT_REPO_DIR)
    require_env("DEVICES_FILE", devices_file)

    if not os.path.exists(devices_file):
        raise RuntimeError(f"Device file not found: {devices_file}")

    if not os.path.isdir(GIT_REPO_DIR):
        raise RuntimeError(f"GIT_REPO_DIR is not a directory: {GIT_REPO_DIR}")


# =========================
# EMAIL
# =========================


def send_email(summary, failures):
    if not all([SMTP_HOST, EMAIL_FROM, EMAIL_TO]):
        logging.warning("Email not sent: SMTP_HOST, EMAIL_FROM, or EMAIL_TO is missing")
        return

    try:
        recipients = [x.strip() for x in EMAIL_TO.split(",") if x.strip()]
        if not recipients:
            logging.warning("Email not sent: EMAIL_TO has no valid recipients")
            return

        rows = []
        for ip, vendor, err in failures:
            rows.append(
                "<tr>"
                f"<td>{html.escape(ip)}</td>"
                f"<td>{html.escape(vendor)}</td>"
                f"<td style='color:red;'>{html.escape(err)}</td>"
                "</tr>"
            )

        body = f"""
        <html>
        <body style="font-family: Arial;">
        <h2>Juniper/Extreme Backup - ALERT</h2>

        <h3>Summary</h3>
        <table border="1" cellpadding="5">
            <tr><td><b>Total</b></td><td>{summary['total']}</td></tr>
            <tr><td><b>Success</b></td><td style="color:green;">{summary['success']}</td></tr>
            <tr><td><b>Failure</b></td><td style="color:red;">{summary['fail']}</td></tr>
        </table>

        <h3>Failures</h3>
        <table border="1" cellpadding="5">
        <tr><th>IP</th><th>Vendor</th><th>Error</th></tr>
        {''.join(rows)}
        </table>
        </body>
        </html>
        """

        msg = MIMEText(body, "html")
        msg["Subject"] = f"[ALERT] Juniper/Extreme Backup - {summary['fail']} failures"
        msg["From"] = EMAIL_FROM
        msg["To"] = ", ".join(recipients)

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as server:
            if SMTP_STARTTLS:
                server.starttls()
            if SMTP_USER and SMTP_PASS:
                server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(EMAIL_FROM, recipients, msg.as_string())

        logging.info("Email sent")

    except Exception as exc:
        logging.error(f"Email error: {exc}")


# =========================
# SSH
# =========================


def ssh_connect(ip, user, password=None, ssh_key=None, passphrase=None):
    client = paramiko.SSHClient()
    client.load_system_host_keys()

    if STRICT_HOST_KEY_CHECKING:
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
    else:
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    kwargs = {
        "hostname": ip,
        "username": user,
        "timeout": SSH_TIMEOUT,
        "banner_timeout": SSH_TIMEOUT,
        "auth_timeout": SSH_TIMEOUT,
        "look_for_keys": False,
        "allow_agent": False,
    }

    if ssh_key:
        kwargs["key_filename"] = ssh_key
        if passphrase:
            kwargs["passphrase"] = passphrase
    elif password:
        kwargs["password"] = password
    else:
        raise Exception("AUTH_CONFIG")

    try:
        client.connect(**kwargs)
        return client

    except paramiko.AuthenticationException:
        raise Exception("AUTH")
    except paramiko.SSHException as exc:
        message = str(exc).lower()
        if "banner" in message or "timeout" in message or "timed out" in message:
            raise Exception("TIMEOUT")
        raise Exception(f"SSH: {exc}")
    except Exception as exc:
        message = str(exc).lower()
        if "timed out" in message or "timeout" in message:
            raise Exception("TIMEOUT")
        raise Exception(f"CONNECT: {exc}")


def execute_command(client, command, timeout=None):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout or SSH_TIMEOUT)
    stdout_text = stdout.read().decode(errors="ignore")
    stderr_text = stderr.read().decode(errors="ignore")
    exit_status = stdout.channel.recv_exit_status()

    if stderr_text.strip():
        logging.debug(f"SSH stderr: {stderr_text.strip()}")

    if exit_status != 0 and not stdout_text.strip():
        raise Exception(f"COMMAND_FAILED: {stderr_text.strip() or exit_status}")

    return stdout_text


# =========================
# EXPORT
# =========================


SECRET_PATTERNS = [
    re.compile(r"(?i)(password\s+)(\S+)"),
    re.compile(r"(?i)(encrypted-password\s+)(\S+)"),
    re.compile(r"(?i)(secret\s+)(\S+)"),
    re.compile(r"(?i)(community\s+)(\S+)"),
    re.compile(r"(?i)(authentication-key\s+)(\S+)"),
    re.compile(r"(?i)(shared-secret\s+)(\S+)"),
]


def redact_secrets(config):
    redacted_lines = []
    for line in config.splitlines():
        redacted = line
        for pattern in SECRET_PATTERNS:
            redacted = pattern.sub(r"\1<redacted>", redacted)
        redacted_lines.append(redacted)
    return "\n".join(redacted_lines) + "\n"


def export_config(client, vendor, with_secrets=False):
    if vendor == "juniper":
        config = collect_juniper(client)
    elif vendor == "extreme":
        config = collect_extreme(client)
    else:
        raise Exception("UNKNOWN_VENDOR")

    if not config.strip():
        raise Exception("EMPTY_CONFIG")

    if with_secrets:
        return config

    return redact_secrets(config)


def collect_juniper(client):
    command = 'cli -c "set cli screen-length 0; show configuration | display set"'
    return execute_command(client, command, timeout=SSH_TIMEOUT * 4)


def collect_extreme(client):
    execute_command(client, "disable clipaging", timeout=SSH_TIMEOUT)
    return execute_command(client, "show configuration", timeout=SSH_TIMEOUT * 4)


# =========================
# AUX
# =========================


def safe_name(value):
    value = value.strip() if value else "unknown"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "unknown"


def get_hostname(client, vendor):
    commands = {
        "juniper": 'cli -c "show system information | match Hostname"',
        "extreme": "show switch",
    }

    try:
        output = execute_command(client, commands[vendor], timeout=SSH_TIMEOUT)
    except Exception:
        return "unknown"

    if vendor == "juniper":
        for line in output.splitlines():
            if "hostname" in line.lower():
                return line.split(":", 1)[-1].strip()

    if vendor == "extreme":
        for line in output.splitlines():
            lowered = line.lower()
            if "sysname" in lowered or "system name" in lowered:
                return line.split(":", 1)[-1].strip()

    return "unknown"


def save_backup(ip, vendor, hostname, content):
    backup_path = Path(BACKUP_DIR) / vendor
    backup_path.mkdir(parents=True, exist_ok=True)

    extension = "set" if vendor == "juniper" else "cfg"
    filename = f"{safe_name(hostname)}_{safe_name(ip)}.{extension}"
    path = backup_path / filename
    path.write_text(content, encoding="utf-8")
    return str(path)


def load_devices(devices_file, filter_ip=None, filter_vendor=None):
    with open(devices_file, "r", encoding="utf-8") as file_obj:
        devices = json.load(file_obj)

    if not isinstance(devices, list):
        raise RuntimeError("Device file must contain a JSON list")

    normalized = []
    for index, dev in enumerate(devices, start=1):
        if not isinstance(dev, dict):
            raise RuntimeError(f"Device #{index} is not a JSON object")

        ip = dev.get("ip")
        vendor = (dev.get("vendor") or "").lower()
        user = dev.get("user") or dev.get("login")
        password = dev.get("password")

        if not ip or not vendor or not user:
            raise RuntimeError(f"Device #{index} requires ip, vendor, and user/login")

        if vendor not in ("juniper", "extreme"):
            raise RuntimeError(f"Unsupported vendor on device {ip}: {vendor}")

        item = {
            "ip": ip,
            "vendor": vendor,
            "user": user,
            "password": password,
            "ssh_key": dev.get("ssh_key"),
            "ssh_passphrase": dev.get("ssh_passphrase"),
        }
        normalized.append(item)

    if filter_ip:
        normalized = [dev for dev in normalized if dev["ip"] == filter_ip]

    if filter_vendor:
        normalized = [dev for dev in normalized if dev["vendor"] == filter_vendor]

    return normalized


# =========================
# GIT
# =========================


def git_push():
    repo = Repo(GIT_REPO_DIR)
    repo.git.add(all=True)

    if repo.is_dirty(untracked_files=True):
        repo.index.commit(f"Backup netdev {datetime.now().isoformat(timespec='seconds')}")
        repo.remote(name="origin").push()
        logging.info("Changes pushed to Git")
    else:
        logging.info("No changes to push to Git")


# =========================
# PROCESS
# =========================


def process(dev, with_secrets):
    ip = dev["ip"]
    vendor = dev["vendor"]
    last_error = "UNKNOWN"

    for attempt in range(RETRY_COUNT + 1):
        client = None
        try:
            client = ssh_connect(
                ip,
                dev["user"],
                password=dev.get("password"),
                ssh_key=dev.get("ssh_key"),
                passphrase=dev.get("ssh_passphrase"),
            )
            hostname = get_hostname(client, vendor)
            config = export_config(client, vendor, with_secrets)
            path = save_backup(ip, vendor, hostname, config)
            logging.info(f"Backup OK: {vendor} {ip} -> {path}")
            return (True, ip, vendor, "OK")

        except Exception as exc:
            last_error = str(exc)
            logging.warning(f"Backup failed for {vendor} {ip} attempt {attempt + 1}: {last_error}")
            if attempt < RETRY_COUNT:
                time.sleep(2)

        finally:
            if client:
                client.close()

    return (False, ip, vendor, last_error)


# =========================
# MAIN
# =========================


def main():
    args = parse_args()
    devices_file = args.devices_file or DEVICES_FILE

    try:
        validate_runtime_config(devices_file)
        devices = load_devices(devices_file, args.ip, args.vendor)
    except Exception as exc:
        logging.error(exc)
        return 2

    if args.check:
        print(f"Configuration OK. Selected devices: {len(devices)}")
        for dev in devices:
            print(f"- {dev['vendor']} {dev['ip']} user={dev['user']}")
        return 0

    os.makedirs(BACKUP_DIR, exist_ok=True)

    total = len(devices)
    success = 0
    fail = 0
    failures = []

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        results = list(executor.map(lambda dev: process(dev, args.with_secrets), devices))

    for status, ip, vendor, err in results:
        if status:
            success += 1
        else:
            fail += 1
            failures.append((ip, vendor, err))

    print(f"\nTotal: {total} | Success: {success} | Failure: {fail}")

    summary = {"total": total, "success": success, "fail": fail}

    if not args.no_git_push:
        try:
            git_push()
        except Exception as exc:
            logging.error(f"Git error: {exc}")
            fail += 1
            summary["fail"] = fail
            failures.append(("GIT", "git", str(exc)))

    if args.email and failures:
        send_email(summary, failures)
    else:
        logging.info("Email not sent")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
