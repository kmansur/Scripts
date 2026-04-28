#!/usr/bin/env python3
"""
Script: netdev_backup.py
Versao: 1.0.0
Autor: GitHub Copilot (adaptado ao seu ambiente)

Funcionalidade:
- conecta via SSH em roteadores Juniper MX e switches Extreme Networks
- coleta configuração de forma vendor-specific
- salva backup em diretório local
- comita e envia para repositório Git
- opcionalmente envia email em caso de falha
"""

import argparse
import json
import logging
import os
import smtplib
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from email.mime.text import MIMEText

import mysql.connector

# =========================
# LOG
# =========================

logging.getLogger("paramiko").setLevel(logging.WARNING)

LOG_FILE = "/var/log/netdev_backup.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

# =========================
# ENV
# =========================

ENV_PATH = "/usr/local/etc/netdev_backup/netdev_backup.env"

if not os.path.exists(ENV_PATH):
    print(f"ENV nao encontrado: {ENV_PATH}")
    sys.exit(1)

load_dotenv(ENV_PATH)

BACKUP_DIR = os.getenv("BACKUP_DIR")
GIT_REPO_DIR = os.getenv("GIT_REPO_DIR")
STATIC_DEVICES_FILE = os.getenv("STATIC_DEVICES_FILE")

DB_CONFIG = {
    "host": os.getenv("DB_HOST"),
    "database": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASS"),
}

SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_PORT = int(os.getenv("SMTP_PORT", 587))
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")
EMAIL_FROM = os.getenv("EMAIL_FROM")
EMAIL_TO = os.getenv("EMAIL_TO")

SSH_TIMEOUT = int(os.getenv("SSH_TIMEOUT", 15))
MAX_WORKERS = int(os.getenv("MAX_WORKERS", 4))
RETRY_COUNT = int(os.getenv("RETRY_COUNT", 2))

# =========================
# ARGS
# =========================

def parse_args():
    parser = argparse.ArgumentParser(description="Backup Juniper MX e Extreme Networks para Git interno")
    parser.add_argument("--ip", help="Filtra por IP do dispositivo")
    parser.add_argument("--vendor", choices=["juniper", "extreme"], help="Filtra por vendor")
    parser.add_argument("--email", action="store_true", help="Envia email somente se houver falhas")
    parser.add_argument("--with-secrets", action="store_true", help="Tenta coletar segredos quando suportado")
    parser.add_argument("--devices-file", help="Arquivo JSON de dispositivos para sobrescrever DEVICES_FILE")
    return parser.parse_args()

# =========================
# EMAIL
# =========================

def send_email(summary, failures):
    try:
        recipients = [x.strip() for x in EMAIL_TO.split(",") if x.strip()]

        html = f"""
        <html>
        <body style=\"font-family: Arial;\">
        <h2>⚠️ Backup Juniper/Extreme - ALERTA</h2>

        <h3>Resumo</h3>
        <table border=\"1\" cellpadding=\"5\">
            <tr><td><b>Total</b></td><td>{summary['total']}</td></tr>
            <tr><td><b>Sucesso</b></td><td style=\"color:green;\">{summary['success']}</td></tr>
            <tr><td><b>Falha</b></td><td style=\"color:red;\">{summary['fail']}</td></tr>
        </table>

        <h3>Falhas</h3>
        <table border=\"1\" cellpadding=\"5\">
        <tr><th>IP</th><th>Vendor</th><th>Erro</th></tr>
        """

        for ip, vendor, err in failures:
            html += f"<tr><td>{ip}</td><td>{vendor}</td><td style='color:red;'>{err}</td></tr>"

        html += "</table></body></html>"

        msg = MIMEText(html, "html")
        msg["Subject"] = f"[ALERTA] Backup Juniper/Extreme - {summary['fail']} falhas"
        msg["From"] = EMAIL_FROM
        msg["To"] = ", ".join(recipients)

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.starttls()
            if SMTP_USER and SMTP_PASS:
                server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(EMAIL_FROM, recipients, msg.as_string())

        logging.info("Email enviado")

    except Exception as exc:
        logging.error(f"Erro email: {exc}")

# =========================
# SSH
# =========================

def ssh_connect(ip, user, password=None, ssh_key=None, passphrase=None):
    client = paramiko.SSHClient()
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
    else:
        kwargs["password"] = password

    try:
        client.connect(**kwargs)
        return client

    except paramiko.AuthenticationException:
        raise Exception("AUTH")
    except paramiko.SSHException as exc:
        message = str(exc).lower()
        if "banner" in message or "timeout" in message:
            raise Exception("TIMEOUT")
        raise Exception("SSH")
    except Exception:
        raise Exception("TIMEOUT")

# =========================
# EXPORT
# =========================

def export_config(client, vendor, with_secrets=False):
    if vendor == "juniper":
        return collect_juniper(client, with_secrets)
    if vendor == "extreme":
        return collect_extreme(client, with_secrets)
    if vendor == "mikrotik":
        return collect_mikrotik(client, with_secrets)
    raise Exception("UNKNOWN_VENDOR")


def execute_command(client, command):
    stdin, stdout, stderr = client.exec_command(command)
    stdout_text = stdout.read().decode(errors="ignore")
    stderr_text = stderr.read().decode(errors="ignore")
    if stderr_text.strip():
        logging.debug(f"SSH stderr: {stderr_text.strip()}")
    return stdout_text


def collect_juniper(client, with_secrets=False):
    sensitive = " | display set" if with_secrets else " | display set"
    command = f'cli -c "set cli screen-length 0; show configuration{sensit