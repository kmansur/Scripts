#!/usr/bin/env python3
# exabgp_notify.py
# Version: 0.1
# License: MIT-like (adapt as needed)
#
# Purpose
# -------
# Read ExaBGP log lines from STDIN (intended to be piped from `tail -F`),
# detect route "added"/"removed" events, and send notifications to Telegram
# and/or email (SMTP). The script is decoupled from ExaBGP itself – it never
# touches your BGP session – and simply parses human-readable log entries
# produced by ExaBGP.
#
# Design
# ------
# - This program reads one line at a time from stdin.
# - For each line matching the "route added/removed" pattern, it builds a
#   compact message and delivers it to the configured channels.
# - It implements basic de-duplication and throttling to reduce noise.
# - Configuration is loaded from /etc/exabgp-notify/exabgp-notify.cfg
#   (KEY=VALUE lines), which is also compatible with systemd's EnvironmentFile.
#
# Security posture
# ----------------
# - No external dependencies: only Python 3 standard library.
# - Intended to run as a non-privileged user (e.g. 'exabgp') with read-only
#   access to the ExaBGP log file. The systemd service applies several
#   hardening options (NoNewPrivileges, ProtectSystem, etc.).
#
# Tested on
# ---------
# Debian 12 (bookworm)
#
# Usage (typically via systemd unit):
#   tail -F /var/log/exabgp/exabgp.log | /usr/local/scripts/exabgp_notify.py --config /etc/exabgp-notify/exabgp-notify.cfg
#
# Author: NetTech / Karim's assistant
# -----------------------------------------------------------------------------

import os
import re
import sys
import time
import ssl
import smtplib
from urllib import request, parse

VERSION = "0.1"

# --------------------------
# Configuration management
# --------------------------
# The config file is a simple KEY=VALUE format with optional comments (# ...).
# It is compatible with systemd's EnvironmentFile.
DEFAULT_CONFIG_PATH = "/etc/exabgp-notify/exabgp-notify.cfg"

def load_envfile(path):
    """
    Load KEY=VALUE lines from a file into a dict.
    - Ignores blank lines and lines starting with '#'
    - Supports unquoted or double-quoted values
    - Does not perform shell expansion for security
    """
    cfg = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip()
                # Strip optional surrounding double quotes
                if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                    val = val[1:-1]
                cfg[key] = val
    except FileNotFoundError:
        # It's valid to run without a config file; environment may provide values instead.
        pass
    return cfg

def getenv(cfg, key, default=""):
    """Return config value from (1) config dict, (2) environment, (3) default"""
    return cfg.get(key, os.getenv(key, default)).strip()

def getenv_int(cfg, key, default):
    try:
        return int(getenv(cfg, key, str(default)))
    except Exception:
        return default

def getenv_bool(cfg, key, default=False):
    raw = getenv(cfg, key, "1" if default else "0").lower()
    return raw in ("1", "true", "yes", "on")

# --------------------------
# Notification backends
# --------------------------
def send_telegram(bot_token, chat_id, text):
    if not (bot_token and chat_id):
        return
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    data = {
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": True,
        "parse_mode": "HTML",
    }
    req = request.Request(url, data=parse.urlencode(data).encode("utf-8"), method="POST")
    try:
        with request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception as e:
        print(f"[exabgp_notify] telegram error: {e}", file=sys.stderr)

def send_email(smtp_host, smtp_port, smtp_user, smtp_pass, mail_from, mail_to_csv, subject, body):
    if not (smtp_host and mail_from and mail_to_csv):
        return
    to_list = [x.strip() for x in mail_to_csv.split(",") if x.strip()]
    if not to_list:
        return
    msg = (
        f"From: {mail_from}\r\n"
        f"To: {', '.join(to_list)}\r\n"
        f"Subject: {subject}\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "\r\n"
        f"{body}"
    )
    ctx = ssl.create_default_context()
    try:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=10) as s:
            s.ehlo()
            # Try STARTTLS when possible
            try:
                s.starttls(context=ctx)
                s.ehlo()
            except smtplib.SMTPException:
                pass
            if smtp_user and smtp_pass:
                s.login(smtp_user, smtp_pass)
            s.sendmail(mail_from, to_list, msg.encode("utf-8"))
    except Exception as e:
        print(f"[exabgp_notify] smtp error: {e}", file=sys.stderr)

# --------------------------
# Parsing logic
# --------------------------
# Example line (human-readable log):
# Thu, 09 Oct 2025 17:21:33 2890183 api           route added to neighbor 172.31.192.1 local-ip 172.31.192.2 ... : 187.120.203.0/24 next-hop 10.0.0.1 local-preference 210 community 53140:615
RE_LINE = re.compile(
    r'^(?P<ts>\w{3},\s+\d{2}\s+\w{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}).*?\bapi\s+route\s+'
    r'(?P<action>added|removed)\s+to\s+neighbor\s+(?P<neighbor>\d{1,3}(?:\.\d{1,3}){3}).*?:\s+'
    r'(?P<prefix>\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\s+next-hop\s+(?P<nexthop>\d{1,3}(?:\.\d{1,3}){3})\s+'
    r'local-preference\s+(?P<lpref>\d+)\s+community\s+(?P<comm>[\d:]+)',
    re.IGNORECASE
)

def build_text(d):
    """Build a concise, human-friendly notification text (Telegram flavoured)."""
    return (
        f"<b>ExaBGP</b>: route <b>{d['action'].upper()}</b>\n"
        f"Prefix: <code>{d['prefix']}</code>\n"
        f"Next-hop: {d['nexthop']}  LP: {d['lpref']}  Community: {d['comm']}\n"
        f"Neighbor: {d['neighbor']}\n"
        f"When: {d['ts']}"
    )

def strip_tags(s):
    """Remove minimal HTML tags for email/plaintext body."""
    return re.sub(r"<[^>]+>", "", s)

# --------------------------
# Noise control (throttling & dedup)
# --------------------------
from collections import deque
def make_throttler(window_sec, max_events):
    events = deque()
    def allowed():
        t = int(time.time())
        while events and (t - events[0]) > window_sec:
            events.popleft()
        if len(events) >= max_events:
            return False
        events.append(t)
        return True
    return allowed

def make_dedup(ttl_sec):
    cache = {}
    def allowed(key):
        t = int(time.time())
        # cleanup
        to_del = [k for k,exp in cache.items() if exp <= t]
        for k in to_del:
            cache.pop(k, None)
        if key in cache:
            return False
        cache[key] = t + ttl_sec
        return True
    return allowed

# --------------------------
# Main
# --------------------------
def main():
    # Load configuration
    cfg_path = DEFAULT_CONFIG_PATH
    # Optional CLI arg: --config /path/to/file
    argv = sys.argv[1:]
    if "--config" in argv:
        try:
            cfg_path = argv[argv.index("--config") + 1]
        except Exception:
            print("[exabgp_notify] --config requires a file path", file=sys.stderr)
            sys.exit(2)
    cfg = load_envfile(cfg_path)

    # Resolve settings (config -> env -> default)
    only_actions = {x.strip().lower() for x in getenv(cfg, "ONLY_ACTIONS", "added,removed").split(",") if x.strip()}
    throttle_window = getenv_int(cfg, "THROTTLE_WINDOW_SEC", 60)
    throttle_max    = getenv_int(cfg, "THROTTLE_MAX", 30)
    dedup_ttl       = getenv_int(cfg, "DEDUP_TTL_SEC", 60)
    dry_run         = getenv_bool(cfg, "DRY_RUN", False)

    allowed_by_rate = make_throttler(throttle_window, throttle_max)
    allowed_by_dedup = make_dedup(dedup_ttl)

    # Telegram
    tg_token = getenv(cfg, "TELEGRAM_BOT_TOKEN", "")
    tg_chat  = getenv(cfg, "TELEGRAM_CHAT_ID", "")

    # SMTP
    smtp_host = getenv(cfg, "SMTP_HOST", "")
    smtp_port = getenv_int(cfg, "SMTP_PORT", 587)
    smtp_user = getenv(cfg, "SMTP_USER", "")
    smtp_pass = getenv(cfg, "SMTP_PASS", "")
    mail_from = getenv(cfg, "MAIL_FROM", "")
    mail_to   = getenv(cfg, "MAIL_TO", "")

    # Process stdin
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue

        m = RE_LINE.search(line)
        if not m:
            continue

        d = m.groupdict()
        action = d["action"].lower()
        if action not in only_actions:
            continue

        text = build_text(d)
        key  = f"{d['action']}|{d['prefix']}|{d['neighbor']}"

        if not allowed_by_dedup(key):
            # Suppressed by de-duplication window
            continue
        if not allowed_by_rate():
            # Suppressed by throttling window
            continue

        if dry_run:
            print(f"[DRY_RUN] {strip_tags(text)}", file=sys.stderr)
            continue

        # Dispatch
        try:
            send_telegram(tg_token, tg_chat, text)
        except Exception as e:
            print(f"[exabgp_notify] telegram dispatch failed: {e}", file=sys.stderr)
        try:
            subj = f"ExaBGP: route {d['action'].upper()} {d['prefix']} (nh {d['nexthop']})"
            send_email(smtp_host, smtp_port, smtp_user, smtp_pass, mail_from, mail_to, subj, strip_tags(text))
        except Exception as e:
            print(f"[exabgp_notify] email dispatch failed: {e}", file=sys.stderr)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
