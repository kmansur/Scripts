#!/usr/bin/env python3
"""
Script: mikrotik_backup.py
Versao: 1.11.3
Autor: Karim Mansur - NetTech

Melhorias:
- Email apenas quando houver falha
- Multiplos destinatarios (EMAIL_TO separado por virgula)
- Relatorio HTML
"""

import os
import sys
import logging
import argparse
import smtplib
from email.mime.text import MIMEText
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from time import sleep

import mysql.connector
import paramiko
from dotenv import load_dotenv
from git import Repo

# =========================
# LOG
# =========================

logging.getLogger("paramiko").setLevel(logging.WARNING)

LOG_FILE = "/var/log/mikrotik_backup.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

# =========================
# ARGS
# =========================

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--with-secrets", action="store_true")
    parser.add_argument("--email", action="store_true")
    return parser.parse_args()

# =========================
# ENV
# =========================

ENV_PATH = "/usr/local/etc/mikrotik_backup/mikrotik_backup.env"

if not os.path.exists(ENV_PATH):
    print("ENV nao encontrado")
    sys.exit(1)

load_dotenv(ENV_PATH)

DB_CONFIG = {
    "host": os.getenv("DB_HOST"),
    "database": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASS"),
}

BACKUP_DIR = os.getenv("BACKUP_DIR")
GIT_REPO_DIR = os.getenv("GIT_REPO_DIR")

SMTP_HOST = os.getenv("SMTP_HOST")
SMTP_PORT = int(os.getenv("SMTP_PORT", 587))
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")
EMAIL_FROM = os.getenv("EMAIL_FROM")
EMAIL_TO = os.getenv("EMAIL_TO")

SSH_TIMEOUT = int(os.getenv("SSH_TIMEOUT", 10))
MAX_WORKERS = int(os.getenv("MAX_WORKERS", 5))
RETRY_COUNT = int(os.getenv("RETRY_COUNT", 2))

# =========================
# EMAIL
# =========================

def send_email(summary, failures):
    try:
        recipients = [x.strip() for x in EMAIL_TO.split(",")]

        html = f"""
        <html>
        <body style="font-family: Arial;">
        <h2>⚠️ Backup Mikrotik - ALERTA</h2>

        <h3>Resumo</h3>
        <table border="1" cellpadding="5">
            <tr><td><b>Total</b></td><td>{summary['total']}</td></tr>
            <tr><td><b>Sucesso</b></td><td style="color:green;">{summary['success']}</td></tr>
            <tr><td><b>Falha</b></td><td style="color:red;">{summary['fail']}</td></tr>
        </table>

        <h3>Falhas</h3>
        <table border="1" cellpadding="5">
        <tr><th>Nome</th><th>IP</th><th>Erro</th></tr>
        """

        for name, ip, err in failures:
            html += f"<tr><td>{name}</td><td>{ip}</td><td style='color:red;'>{err}</td></tr>"

        html += "</table></body></html>"

        msg = MIMEText(html, "html")
        msg["Subject"] = f"[ALERTA] Backup Mikrotik - {summary['fail']} falhas"
        msg["From"] = EMAIL_FROM
        msg["To"] = ", ".join(recipients)

        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(EMAIL_FROM, recipients, msg.as_string())

        logging.info("Email enviado")

    except Exception as e:
        logging.error(f"Erro email: {e}")

# =========================
# SSH
# =========================

def ssh_connect(ip, user, password):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            hostname=ip,
            username=user,
            password=password,
            timeout=SSH_TIMEOUT,
            banner_timeout=SSH_TIMEOUT,
            auth_timeout=SSH_TIMEOUT,
            look_for_keys=False,
            allow_agent=False
        )
        return client

    except paramiko.AuthenticationException:
        raise Exception("AUTH")

    except paramiko.ssh_exception.SSHException as e:
        if "banner" in str(e).lower():
            raise Exception("TIMEOUT")
        raise Exception("SSH")

    except Exception:
        raise Exception("TIMEOUT")

# =========================
# EXPORT
# =========================

def export_config(client, ip, with_secrets=False):
    filename = f"backup_{ip.replace('.', '_')}"
    remote = f"{filename}.rsc"
    local_tmp = f"/tmp/{remote}"

    cmd = "/export compact "
    if with_secrets:
        cmd += "show-sensitive "
    cmd += f"file={filename}"

    client.exec_command(cmd)
    sleep(3)

    try:
        sftp = client.open_sftp()
        sftp.get(remote, local_tmp)
        sftp.close()
    except:
        raise Exception("EXPORT")

    client.exec_command(f"/file remove {remote}")

    with open(local_tmp, "r", errors="ignore") as f:
        content = f.read()

    os.remove(local_tmp)
    return content

# =========================
# AUX
# =========================

def get_hostname(client):
    try:
        stdin, stdout, _ = client.exec_command("/system identity print")
        for line in stdout.read().decode().splitlines():
            if "name:" in line:
                return line.split("name:")[1].strip()
    except:
        pass
    return "unknown"

def save_backup(ip, hostname, content):
    hostname = hostname.replace(" ", "_")
    path = os.path.join(BACKUP_DIR, f"{hostname}_{ip}.rsc")

    with open(path, "w") as f:
        f.write(content)

    return path

# =========================
# DB
# =========================

def get_devices(filter_ip=None):
    query = """
        SELECT ip, login, senha, descricao
        FROM gateway
        WHERE descricao REGEXP '^(PE|CE)-'
    """

    conn = mysql.connector.connect(**DB_CONFIG)
    cur = conn.cursor(dictionary=True)
    cur.execute(query)
    devices = cur.fetchall()
    cur.close()
    conn.close()

    if filter_ip:
        devices = [d for d in devices if d["ip"] == filter_ip]

    return devices

# =========================
# GIT
# =========================

def git_push():
    repo = Repo(GIT_REPO_DIR)
    repo.git.add(all=True)

    if repo.is_dirty(untracked_files=True):
        repo.index.commit(f"Backup {datetime.now()}")
        repo.remote(name="origin").push()

# =========================
# PROCESS
# =========================

def process(dev, with_secrets):
    ip = dev["ip"]
    name = dev.get("descricao", "SEM_NOME")

    for _ in range(RETRY_COUNT + 1):
        try:
            client = ssh_connect(ip, dev["login"], dev["senha"])
            hostname = get_hostname(client)
            config = export_config(client, ip, with_secrets)
            save_backup(ip, hostname, config)
            client.close()
            return (True, hostname, ip, "OK")
        except Exception as e:
            err = str(e)
            sleep(2)

    return (False, name, ip, err)

# =========================
# MAIN
# =========================

def main():
    args = parse_args()

    os.makedirs(BACKUP_DIR, exist_ok=True)

    devices = get_devices(args.ip)

    total = len(devices)
    success = 0
    fail = 0
    failures = []

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        results = list(ex.map(lambda d: process(d, args.with_secrets), devices))

    for status, name, ip, err in results:
        if status:
            success += 1
        else:
            fail += 1
            failures.append((name, ip, err))

    print(f"\nTotal: {total} | Sucesso: {success} | Falha: {fail}")

    summary = {"total": total, "success": success, "fail": fail}

    git_push()

    if args.email and fail > 0:
        send_email(summary, failures)
    else:
        logging.info("Sem falhas - email nao enviado")

if __name__ == "__main__":
    main()