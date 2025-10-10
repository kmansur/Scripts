#!/usr/bin/env python3
# exabgp_notify.py
# Version: 0.1.2
# License: MIT-like (adapt as needed)
#
# Purpose: read ExaBGP log lines from STDIN (tail -F), detect "route added/removed"
# and send Telegram/Email notifications. Decoupled from ExaBGP.
# Tested on Debian 12.
import os, re, sys, time, ssl, smtplib
from urllib import request, parse
from collections import deque

VERSION = "0.1.2"

DEFAULT_CONFIG_PATH = "/etc/exabgp-notify/exabgp-notify.cfg"

def load_envfile(path):
    cfg = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
                    v = v[1:-1]
                cfg[k] = v
    except FileNotFoundError:
        pass
    return cfg

def getenv(cfg, key, default=""):
    return cfg.get(key, os.getenv(key, default)).strip()

def getenv_int(cfg, key, default):
    try: return int(getenv(cfg, key, str(default)))
    except: return default

def getenv_bool(cfg, key, default=False):
    raw = getenv(cfg, key, "1" if default else "0").lower()
    return raw in ("1","true","yes","on")

def send_telegram(bot_token, chat_id, text):
    if not (bot_token and chat_id): return
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    data = {"chat_id": chat_id, "text": text, "disable_web_page_preview": True, "parse_mode": "HTML"}
    req = request.Request(url, data=parse.urlencode(data).encode("utf-8"), method="POST")
    try:
        with request.urlopen(req, timeout=10) as r: r.read()
    except Exception as e:
        print(f"[exabgp_notify] telegram error: {e}", file=sys.stderr)

def send_email(smtp_host, smtp_port, smtp_user, smtp_pass, mail_from, mail_to_csv, subject, body, smtp_ssl=False, smtp_starttls=True):
    if not (smtp_host and mail_from and mail_to_csv): return
    to_list = [x.strip() for x in mail_to_csv.split(",") if x.strip()]
    if not to_list: return
    msg = (f"From: {mail_from}\r\nTo: {', '.join(to_list)}\r\nSubject: {subject}\r\n"
           "Content-Type: text/plain; charset=utf-8\r\n\r\n" + body)
    ctx = ssl.create_default_context()
    try:
        if smtp_ssl:
            with smtplib.SMTP_SSL(smtp_host, smtp_port, context=ctx, timeout=10) as s:
                s.ehlo()
                if smtp_user and smtp_pass: s.login(smtp_user, smtp_pass)
                s.sendmail(mail_from, to_list, msg.encode("utf-8"))
        else:
            with smtplib.SMTP(smtp_host, smtp_port, timeout=10) as s:
                s.ehlo()
                if smtp_starttls:
                    try:
                        s.starttls(context=ctx); s.ehlo()
                    except smtplib.SMTPException:
                        pass
                if smtp_user and smtp_pass: s.login(smtp_user, smtp_pass)
                s.sendmail(mail_from, to_list, msg.encode("utf-8"))
    except Exception as e:
        print(f"[exabgp_notify] smtp error: {e}", file=sys.stderr)

RE_LINE = re.compile(
    r'^(?P<ts>\w{3},\s+\d{2}\s+\w{3}\s+\d{4}\s+\d{2}:\d{2}:\d{2}).*?\bapi\s+route\s+'
    r'(?P<action>added|removed)\s+to\s+neighbor\s+(?P<neighbor>\d{1,3}(?:\.\d{1,3}){3}).*?:\s+'
    r'(?P<prefix>\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\s+next-hop\s+(?P<nexthop>\d{1,3}(?:\.\d{1,3}){3})\s+'
    r'local-preference\s+(?P<lpref>\d+)\s+community\s+(?P<comm>[\d:]+)',
    re.IGNORECASE
)

def build_text(d):
    return (f"<b>ExaBGP</b>: route <b>{d['action'].upper()}</b>\n"
            f"Prefix: <code>{d['prefix']}</code>\n"
            f"Next-hop: {d['nexthop']}  LP: {d['lpref']}  Community: {d['comm']}\n"
            f"Neighbor: {d['neighbor']}\n"
            f"When: {d['ts']}")

def strip_tags(s): return re.sub(r"<[^>]+>", "", s)

def make_throttler(window_sec, max_events):
    events = deque()
    def allowed():
        t = int(time.time())
        while events and (t - events[0]) > window_sec: events.popleft()
        if len(events) >= max_events: return False
        events.append(t); return True
    return allowed

def make_dedup(ttl_sec):
    cache = {}
    def allowed(key):
        t = int(time.time())
        for k,exp in list(cache.items()):
            if exp <= t: cache.pop(k, None)
        if key in cache: return False
        cache[key] = t + ttl_sec; return True
    return allowed

def main():
    cfg_path = DEFAULT_CONFIG_PATH
    argv = sys.argv[1:]
    if "--config" in argv:
        try: cfg_path = argv[argv.index("--config")+1]
        except: print("[exabgp_notify] --config requires a file path", file=sys.stderr); sys.exit(2)
    cfg = load_envfile(cfg_path)

    only_actions = {x.strip().lower() for x in getenv(cfg,"ONLY_ACTIONS","added,removed").split(",") if x.strip()}
    throttle_window = getenv_int(cfg, "THROTTLE_WINDOW_SEC", 60)
    throttle_max    = getenv_int(cfg, "THROTTLE_MAX", 30)
    dedup_ttl       = getenv_int(cfg, "DEDUP_TTL_SEC", 60)
    dry_run         = getenv_bool(cfg, "DRY_RUN", False)
    verbose         = getenv_bool(cfg, "VERBOSE", False)

    allowed_by_rate  = make_throttler(throttle_window, throttle_max)
    allowed_by_dedup = make_dedup(dedup_ttl)

    # Telegram
    tg_token = getenv(cfg, "TELEGRAM_BOT_TOKEN", "")
    tg_chat  = getenv(cfg, "TELEGRAM_CHAT_ID", "")

    # SMTP & TLS
    smtp_host = getenv(cfg, "SMTP_HOST", "")
    smtp_port = getenv_int(cfg, "SMTP_PORT", 587)
    smtp_user = getenv(cfg, "SMTP_USER", "")
    smtp_pass = getenv(cfg, "SMTP_PASS", "")
    mail_from = getenv(cfg, "MAIL_FROM", "")
    mail_to   = getenv(cfg, "MAIL_TO", "")
    smtp_ssl = getenv_bool(cfg, "SMTP_SSL", smtp_port == 465)
    smtp_starttls = getenv_bool(cfg, "SMTP_STARTTLS", True)

    for raw in sys.stdin:
        line = raw.strip()
        if not line: continue
        m = RE_LINE.search(line)
        if not m: continue

        d = m.groupdict()
        action = d["action"].lower()
        if action not in only_actions: continue

        text = build_text(d)
        subj = f"ExaBGP: route {d['action'].upper()} {d['prefix']} (nh {d['nexthop']})"
        key  = f\"{d['action']}|{d['prefix']}|{d['neighbor']}\"

        if verbose:
            print(f\"[exabgp_notify] MATCH: action={action} prefix={d['prefix']} nh={d['nexthop']} neighbor={d['neighbor']}\", file=sys.stderr)

        if not allowed_by_dedup(key):
            if verbose: print(\"[exabgp_notify] SUPPRESSED by dedup\", file=sys.stderr)
            continue
        if not allowed_by_rate():
            if verbose: print(\"[exabgp_notify] SUPPRESSED by throttling\", file=sys.stderr)
            continue

        if dry_run:
            print(f\"[DRY_RUN] {strip_tags(text)}\", file=sys.stderr)
            continue

        try:
            if tg_token and tg_chat:
                if verbose: print(\"[exabgp_notify] Sending Telegram\", file=sys.stderr)
                send_telegram(tg_token, tg_chat, text)
        except Exception as e:
            print(f\"[exabgp_notify] telegram dispatch failed: {e}\", file=sys.stderr)

        try:
            if smtp_host and mail_from and mail_to:
                if verbose: print(f\"[exabgp_notify] Sending Email -> {mail_to} (SSL={smtp_ssl}, STARTTLS={smtp_starttls}, PORT={smtp_port})\", file=sys.stderr)
                send_email(smtp_host, smtp_port, smtp_user, smtp_pass, mail_from, mail_to, subj, strip_tags(text), smtp_ssl=smtp_ssl, smtp_starttls=smtp_starttls)
        except Exception as e:
            print(f\"[exabgp_notify] email dispatch failed: {e}\", file=sys.stderr)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: pass
