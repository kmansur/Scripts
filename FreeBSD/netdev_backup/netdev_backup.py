#!/usr/bin/env python3
"""
Script: netdev_backup.py
Version: 1.2.0
Author: Karim Mansur - NetTech

Purpose:
- connects to MikroTik, Juniper, Extreme Networks, HP/3Com, and Ubiquiti devices
- loads MikroTik devices from MySQL and other vendors from JSON
- supports SSH and Telnet transports for legacy non-MikroTik devices
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
import socket
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from email.mime.text import MIMEText
from pathlib import Path

import mysql.connector
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

DB_CONFIG = {
    "host": os.getenv("DB_HOST"),
    "database": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASS"),
}
if os.getenv("DB_PORT"):
    DB_CONFIG["port"] = int(os.getenv("DB_PORT"))

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
# DEVICE MODEL
# =========================

VENDOR_ALIASES = {
    "mikrotik": "mikrotik",
    "juniper": "juniper",
    "extreme": "extreme",
    "hp": "hp_procurve",
    "hp_procurve": "hp_procurve",
    "aruba": "hp_procurve",
    "arubaos_switch": "hp_procurve",
    "hp_comware": "hp_comware",
    "h3c": "hp_comware",
    "3com": "hp_comware",
    "3com_comware": "hp_comware",
    "ubiquiti": "ubiquiti_edgeswitch",
    "ubiquiti_edgeswitch": "ubiquiti_edgeswitch",
    "edgeswitch": "ubiquiti_edgeswitch",
    "ubiquiti_edgeos": "ubiquiti_edgeos",
    "edgeos": "ubiquiti_edgeos",
    "ubiquiti_unifi": "ubiquiti_unifi",
    "unifi": "ubiquiti_unifi",
}

SUPPORTED_TRANSPORTS = ("ssh", "telnet")
DEFAULT_PROMPT_PATTERN = r"(?m)(?:^|\n)[^\n\r]{1,120}[>#\]]\s*$"
USERNAME_PATTERN = re.compile(r"(?i)(login|username|user\s*name)\s*:\s*$")
PASSWORD_PATTERN = re.compile(r"(?i)password\s*:\s*$")
AUTH_FAILURE_PATTERN = re.compile(
    r"(?i)(authentication failed|login incorrect|invalid login|access denied|permission denied|invalid password)"
)


def normalize_vendor(vendor):
    normalized = (vendor or "").strip().lower()
    if normalized not in VENDOR_ALIASES:
        raise RuntimeError(f"Unsupported vendor: {vendor}")
    return VENDOR_ALIASES[normalized]


def normalize_transport(transport):
    normalized = (transport or "ssh").strip().lower()
    if normalized not in SUPPORTED_TRANSPORTS:
        raise RuntimeError(f"Unsupported transport: {transport}")
    return normalized

# =========================
# ARGS
# =========================


def parse_args():
    parser = argparse.ArgumentParser(
        description="Back up MikroTik, Juniper, Extreme, HP/3Com, and Ubiquiti configurations to Git"
    )
    parser.add_argument("--ip", help="Filter by device IP address")
    parser.add_argument("--vendor", choices=sorted(VENDOR_ALIASES), help="Filter by vendor")
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


def validate_runtime_config(devices_file, require_json=True, require_db=True):
    require_env("BACKUP_DIR", BACKUP_DIR)
    require_env("GIT_REPO_DIR", GIT_REPO_DIR)

    if require_json:
        require_env("DEVICES_FILE", devices_file)

    if require_json and devices_file and not os.path.exists(devices_file):
        raise RuntimeError(f"Device file not found: {devices_file}")

    if not os.path.isdir(GIT_REPO_DIR):
        raise RuntimeError(f"GIT_REPO_DIR is not a directory: {GIT_REPO_DIR}")

    if require_db:
        for name, value in (
            ("DB_HOST", DB_CONFIG.get("host")),
            ("DB_NAME", DB_CONFIG.get("database")),
            ("DB_USER", DB_CONFIG.get("user")),
            ("DB_PASS", DB_CONFIG.get("password")),
        ):
            require_env(name, value)


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
        <h2>Network Device Backup - ALERT</h2>

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
        msg["Subject"] = f"[ALERT] Network Device Backup - {summary['fail']} failures"
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
# TRANSPORT
# =========================


def ssh_connect(ip, user, password=None, ssh_key=None, passphrase=None, port=22):
    client = paramiko.SSHClient()
    client.load_system_host_keys()

    if STRICT_HOST_KEY_CHECKING:
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
    else:
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    kwargs = {
        "hostname": ip,
        "port": port,
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


def execute_ssh_command(client, command, timeout=None):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout or SSH_TIMEOUT)
    stdout_text = stdout.read().decode(errors="ignore")
    stderr_text = stderr.read().decode(errors="ignore")
    exit_status = stdout.channel.recv_exit_status()

    if stderr_text.strip():
        logging.debug(f"SSH stderr: {stderr_text.strip()}")

    if exit_status != 0 and not stdout_text.strip():
        raise Exception(f"COMMAND_FAILED: {stderr_text.strip() or exit_status}")

    return stdout_text


class SSHSession:
    transport = "ssh"

    def __init__(self, client):
        self.client = client

    def run(self, command, timeout=None):
        return execute_ssh_command(self.client, command, timeout=timeout)

    def exec_command(self, command):
        return self.client.exec_command(command)

    def open_sftp(self):
        return self.client.open_sftp()

    def close(self):
        self.client.close()


class TelnetSession:
    transport = "telnet"

    def __init__(self, sock, prompt_pattern=None):
        self.sock = sock
        self.prompt_pattern = re.compile(prompt_pattern or DEFAULT_PROMPT_PATTERN)

    def _send(self, text):
        self.sock.sendall(text.encode() + b"\r\n")

    def _process_telnet_bytes(self, data):
        output = bytearray()
        index = 0

        while index < len(data):
            byte = data[index]
            if byte != 255:
                output.append(byte)
                index += 1
                continue

            if index + 1 >= len(data):
                break

            command = data[index + 1]
            if command == 255:
                output.append(255)
                index += 2
            elif command in (251, 252, 253, 254) and index + 2 < len(data):
                option = data[index + 2]
                if command in (251, 252):
                    self.sock.sendall(bytes([255, 254, option]))
                else:
                    self.sock.sendall(bytes([255, 252, option]))
                index += 3
            elif command == 250:
                end = data.find(bytes([255, 240]), index + 2)
                index = len(data) if end == -1 else end + 2
            else:
                index += 2

        return bytes(output)

    def read_until(self, patterns, timeout=None):
        deadline = time.monotonic() + (timeout or SSH_TIMEOUT)
        buffer = ""

        while time.monotonic() < deadline:
            remaining = max(0.1, min(0.5, deadline - time.monotonic()))
            self.sock.settimeout(remaining)

            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue

            if not data:
                break

            clean = self._process_telnet_bytes(data)
            if clean:
                buffer += clean.decode(errors="ignore")

            for pattern in patterns:
                if pattern.search(buffer):
                    return buffer

        raise Exception("TIMEOUT")

    def login(self, user, password, enable_password=None, enable_command="enable"):
        output = self.read_until(
            [USERNAME_PATTERN, PASSWORD_PATTERN, self.prompt_pattern],
            timeout=SSH_TIMEOUT,
        )

        if USERNAME_PATTERN.search(output):
            self._send(user)
            output = self.read_until([PASSWORD_PATTERN, self.prompt_pattern], timeout=SSH_TIMEOUT)

        if PASSWORD_PATTERN.search(output):
            if not password:
                raise Exception("AUTH_CONFIG")
            self._send(password)
            output = self.read_until(
                [AUTH_FAILURE_PATTERN, self.prompt_pattern],
                timeout=SSH_TIMEOUT,
            )

        if AUTH_FAILURE_PATTERN.search(output):
            raise Exception("AUTH")

        if enable_password:
            self._send(enable_command or "enable")
            output = self.read_until([PASSWORD_PATTERN, self.prompt_pattern], timeout=SSH_TIMEOUT)
            if PASSWORD_PATTERN.search(output):
                self._send(enable_password)
                output = self.read_until(
                    [AUTH_FAILURE_PATTERN, self.prompt_pattern],
                    timeout=SSH_TIMEOUT,
                )
            if AUTH_FAILURE_PATTERN.search(output):
                raise Exception("ENABLE_AUTH")

    def run(self, command, timeout=None):
        self._send(command)
        output = self.read_until([self.prompt_pattern], timeout=timeout or SSH_TIMEOUT * 4)
        return self._clean_command_output(command, output)

    def _clean_command_output(self, command, output):
        lines = output.replace("\r\n", "\n").replace("\r", "\n").split("\n")

        while lines and not lines[0].strip():
            lines.pop(0)

        if lines and lines[0].strip() == command.strip():
            lines.pop(0)

        while lines and not lines[-1].strip():
            lines.pop()

        if lines and self.prompt_pattern.search("\n" + lines[-1]):
            lines.pop()

        return "\n".join(lines).strip() + "\n"

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def telnet_connect(ip, user, password=None, port=23, enable_password=None, enable_command="enable", prompt=None):
    if not password:
        raise Exception("AUTH_CONFIG")

    try:
        sock = socket.create_connection((ip, port), timeout=SSH_TIMEOUT)
        session = TelnetSession(sock, prompt_pattern=prompt)
        try:
            session.login(user, password, enable_password=enable_password, enable_command=enable_command)
            return session
        except Exception:
            session.close()
            raise
    except socket.timeout:
        raise Exception("TIMEOUT")
    except OSError as exc:
        raise Exception(f"TELNET: {exc}")


def connect_device(dev):
    transport = normalize_transport(dev.get("transport"))
    ip = dev["ip"]
    port = int(dev.get("port") or (23 if transport == "telnet" else 22))

    if transport == "ssh":
        return SSHSession(
            ssh_connect(
                ip,
                dev["user"],
                password=dev.get("password"),
                ssh_key=dev.get("ssh_key"),
                passphrase=dev.get("ssh_passphrase"),
                port=port,
            )
        )

    if transport == "telnet":
        return telnet_connect(
            ip,
            dev["user"],
            password=dev.get("password"),
            port=port,
            enable_password=dev.get("enable_password"),
            enable_command=dev.get("enable_command", "enable"),
            prompt=dev.get("prompt"),
        )

    raise Exception(f"UNKNOWN_TRANSPORT: {transport}")


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
CLI_ERROR_PATTERN = re.compile(
    r"(?i)(invalid input|unknown command|unrecognized command|command not found|ambiguous command|syntax error)"
)


def redact_secrets(config):
    redacted_lines = []
    for line in config.splitlines():
        redacted = line
        for pattern in SECRET_PATTERNS:
            redacted = pattern.sub(r"\1<redacted>", redacted)
        redacted_lines.append(redacted)
    return "\n".join(redacted_lines) + "\n"


def export_config(client, vendor, with_secrets=False):
    if vendor == "mikrotik":
        config = collect_mikrotik(client, with_secrets)
    elif vendor == "juniper":
        config = collect_juniper(client)
    elif vendor == "extreme":
        config = collect_extreme(client)
    elif vendor == "hp_procurve":
        config = collect_hp_procurve(client)
    elif vendor == "hp_comware":
        config = collect_hp_comware(client)
    elif vendor == "ubiquiti_edgeswitch":
        config = collect_ubiquiti_edgeswitch(client)
    elif vendor == "ubiquiti_edgeos":
        config = collect_ubiquiti_edgeos(client)
    elif vendor == "ubiquiti_unifi":
        config = collect_ubiquiti_unifi(client)
    else:
        raise Exception("UNKNOWN_VENDOR")

    if not config.strip():
        raise Exception("EMPTY_CONFIG")

    if CLI_ERROR_PATTERN.search("\n".join(config.splitlines()[:10])):
        raise Exception("COMMAND_REJECTED")

    if with_secrets:
        return config

    return redact_secrets(config)


def collect_juniper(client):
    command = 'cli -c "set cli screen-length 0; show configuration | display set"'
    return client.run(command, timeout=SSH_TIMEOUT * 4)


def collect_extreme(client):
    run_best_effort(client, ["disable clipaging"])
    return client.run("show configuration", timeout=SSH_TIMEOUT * 4)


def run_best_effort(client, commands):
    for command in commands:
        try:
            client.run(command, timeout=SSH_TIMEOUT)
        except Exception as exc:
            logging.debug(f"Optional command failed ({command}): {exc}")


def collect_hp_procurve(client):
    run_best_effort(client, ["no page", "terminal length 1000"])
    return client.run("show running-config", timeout=SSH_TIMEOUT * 4)


def collect_hp_comware(client):
    run_best_effort(client, ["screen-length disable"])
    return client.run("display current-configuration", timeout=SSH_TIMEOUT * 4)


def collect_ubiquiti_edgeswitch(client):
    run_best_effort(client, ["terminal length 0"])
    return client.run("show running-config", timeout=SSH_TIMEOUT * 4)


def collect_ubiquiti_edgeos(client):
    run_best_effort(client, ["terminal length 0"])
    return client.run("show configuration commands", timeout=SSH_TIMEOUT * 4)


def collect_ubiquiti_unifi(client):
    run_best_effort(client, ["terminal length 0"])
    return client.run("mca-ctrl -t dump-cfg", timeout=SSH_TIMEOUT * 4)


def collect_mikrotik(client, with_secrets=False):
    if client.transport != "ssh":
        raise Exception("MIKROTIK_REQUIRES_SSH")

    filename = f"netdev_backup_{uuid.uuid4().hex}"
    remote = f"{filename}.rsc"
    local_tmp = Path("/tmp") / remote

    command = "/export compact "
    if with_secrets:
        command += "show-sensitive "
    command += f"file={filename}"

    client.exec_command(command)
    time.sleep(3)

    try:
        sftp = client.open_sftp()
        try:
            sftp.get(remote, str(local_tmp))
        finally:
            sftp.close()

        content = local_tmp.read_text(errors="ignore")
        return content

    except Exception:
        raise Exception("EXPORT")

    finally:
        try:
            client.exec_command(f"/file remove {remote}")
        except Exception:
            logging.debug(f"Could not remove remote MikroTik export file: {remote}")
        try:
            local_tmp.unlink()
        except FileNotFoundError:
            pass


# =========================
# AUX
# =========================


def safe_name(value):
    value = value.strip() if value else "unknown"
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "unknown"


def get_hostname(client, vendor):
    commands = {
        "mikrotik": "/system identity print",
        "juniper": 'cli -c "show system information | match Hostname"',
        "extreme": "show switch",
        "hp_procurve": "show system",
        "hp_comware": "display current-configuration | include sysname",
        "ubiquiti_edgeswitch": "show system",
        "ubiquiti_edgeos": "show host name",
        "ubiquiti_unifi": "hostname",
    }

    try:
        output = client.run(commands[vendor], timeout=SSH_TIMEOUT)
    except Exception:
        return "unknown"

    if vendor == "mikrotik":
        for line in output.splitlines():
            if "name:" in line:
                return line.split("name:", 1)[-1].strip()

    elif vendor == "juniper":
        for line in output.splitlines():
            if "hostname" in line.lower():
                return line.split(":", 1)[-1].strip()

    elif vendor == "extreme":
        for line in output.splitlines():
            lowered = line.lower()
            if "sysname" in lowered or "system name" in lowered:
                return line.split(":", 1)[-1].strip()

    elif vendor == "hp_procurve":
        for line in output.splitlines():
            lowered = line.lower()
            if "system name" in lowered or "name" == lowered.split(":", 1)[0].strip():
                return line.split(":", 1)[-1].strip()

    elif vendor == "hp_comware":
        for line in output.splitlines():
            if line.strip().lower().startswith("sysname "):
                return line.split(None, 1)[-1].strip()

    elif vendor == "ubiquiti_edgeswitch":
        for line in output.splitlines():
            lowered = line.lower()
            if "system name" in lowered or "device name" in lowered:
                return line.split(":", 1)[-1].strip()

    elif vendor in ("ubiquiti_edgeos", "ubiquiti_unifi"):
        for line in output.splitlines():
            if line.strip():
                return line.strip()

    return "unknown"


def save_backup(ip, vendor, hostname, content):
    backup_path = Path(BACKUP_DIR) / vendor
    backup_path.mkdir(parents=True, exist_ok=True)

    extensions = {
        "mikrotik": "rsc",
        "juniper": "set",
        "extreme": "cfg",
        "hp_procurve": "cfg",
        "hp_comware": "cfg",
        "ubiquiti_edgeswitch": "cfg",
        "ubiquiti_edgeos": "cfg",
        "ubiquiti_unifi": "cfg",
    }
    extension = extensions.get(vendor, "txt")
    filename = f"{safe_name(hostname)}_{safe_name(ip)}.{extension}"
    path = backup_path / filename
    path.write_text(content, encoding="utf-8")
    return str(path)


def load_json_devices(devices_file, filter_ip=None, filter_vendor=None):
    with open(devices_file, "r", encoding="utf-8") as file_obj:
        devices = json.load(file_obj)

    if not isinstance(devices, list):
        raise RuntimeError("Device file must contain a JSON list")

    normalized = []
    for index, dev in enumerate(devices, start=1):
        if not isinstance(dev, dict):
            raise RuntimeError(f"Device #{index} is not a JSON object")

        ip = dev.get("ip")
        vendor = normalize_vendor(dev.get("vendor"))
        transport = normalize_transport(dev.get("transport"))
        user = dev.get("user") or dev.get("login")
        password = dev.get("password")

        if not ip or not vendor or not user:
            raise RuntimeError(f"Device #{index} requires ip, vendor, and user/login")

        item = {
            "ip": ip,
            "vendor": vendor,
            "transport": transport,
            "port": dev.get("port"),
            "user": user,
            "password": password,
            "ssh_key": dev.get("ssh_key"),
            "ssh_passphrase": dev.get("ssh_passphrase"),
            "enable_password": dev.get("enable_password"),
            "enable_command": dev.get("enable_command", "enable"),
            "prompt": dev.get("prompt"),
            "source": "json",
        }
        normalized.append(item)

    if filter_ip:
        normalized = [dev for dev in normalized if dev["ip"] == filter_ip]

    if filter_vendor:
        normalized = [dev for dev in normalized if dev["vendor"] == filter_vendor]

    return normalized


def load_mikrotik_devices_from_db(filter_ip=None):
    query = """
        SELECT ip, login, senha, descricao
        FROM gateway
        WHERE descricao REGEXP '^(PE|CE)-'
    """

    conn = mysql.connector.connect(**DB_CONFIG)
    try:
        cur = conn.cursor(dictionary=True)
        try:
            cur.execute(query)
            devices = cur.fetchall()
        finally:
            cur.close()
    finally:
        conn.close()

    normalized = []
    for dev in devices:
        ip = dev.get("ip")
        user = dev.get("login")
        password = dev.get("senha")

        if not ip or not user or not password:
            logging.warning(f"Skipping incomplete MikroTik DB record: {dev.get('descricao') or ip}")
            continue

        normalized.append(
            {
                "ip": ip,
                "vendor": "mikrotik",
                "transport": "ssh",
                "port": 22,
                "user": user,
                "password": password,
                "ssh_key": None,
                "ssh_passphrase": None,
                "name": dev.get("descricao"),
                "source": "db",
            }
        )

    if filter_ip:
        normalized = [dev for dev in normalized if dev["ip"] == filter_ip]

    return normalized


def merge_devices(json_devices, db_devices):
    merged = {}

    for dev in json_devices:
        merged[dev["ip"]] = dev

    for dev in db_devices:
        existing = merged.get(dev["ip"])
        if existing and existing["vendor"] != "mikrotik":
            logging.warning(
                f"Skipping DB MikroTik {dev['ip']}: duplicate JSON device uses vendor {existing['vendor']}"
            )
            continue
        merged[dev["ip"]] = dev

    return list(merged.values())


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
            client = connect_device(dev)
            hostname = get_hostname(client, vendor)
            config = export_config(client, vendor, with_secrets)
            path = save_backup(ip, vendor, hostname, config)
            logging.info(f"Backup OK: {vendor} {ip} via {dev.get('transport', 'ssh')} -> {path}")
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
    filter_vendor = normalize_vendor(args.vendor) if args.vendor else None
    load_json = filter_vendor is None or filter_vendor != "mikrotik"
    load_db = filter_vendor is None or filter_vendor == "mikrotik"

    try:
        validate_runtime_config(devices_file, require_json=load_json, require_db=load_db)

        json_devices = []
        db_devices = []

        if load_json:
            json_devices = load_json_devices(devices_file, args.ip, filter_vendor)

        if load_db:
            db_devices = load_mikrotik_devices_from_db(args.ip)

        devices = merge_devices(json_devices, db_devices)

    except Exception as exc:
        logging.error(exc)
        return 2

    if args.check:
        print(f"Configuration OK. Selected devices: {len(devices)}")
        for dev in devices:
            print(
                f"- {dev['vendor']} {dev['ip']} "
                f"transport={dev.get('transport', 'ssh')} user={dev['user']} source={dev.get('source', 'unknown')}"
            )
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
