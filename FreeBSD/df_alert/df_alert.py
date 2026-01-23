#!/usr/bin/env python3
# df_alert.py - TrueNAS df monitor + HTML mail
# Version: 1.6.1.1

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime

VERSION = "1.6.1.1"

# Ajuste aqui
HOST_LABEL = "truenas"

TO_LIST = [
    "suporte@domain.com.br",
    "alerta@domain.com.br",
]

FROM_HDR = f"{HOST_LABEL}@domain.com.br"

WARN_PCT_DEFAULT = 80
HARD_PCT_DEFAULT = 95
COOLDOWN_HOURS_DEFAULT = 12

STATE_FILE = "/tmp/df_alert.last_send"
LOG_FILE = "/tmp/df_alert.log"

# Somente estes (match exato)
WATCHLIST = [
    "zpool0/CN0D0_Sun",
    "zpool1/CN0D1_Mon",
    "zpool2/CN0D2_Tue",
    "zpool3/CN0D3_Wed",
    "zpool4/CN1D0_Thu",
    "zpool5/CN1D1_Fri",
    "zpool6/CN1D2_Sat",
    "zpool0/home",
]

# ANSI cores
ANSI_RESET = "\033[0m"
ANSI_RED = "\033[31m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"  # laranja/amarelo no terminal


def run(cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, text=True, capture_output=True)


def now_str() -> str:
    return datetime.now().strftime("%a %b %d %H:%M:%S %z %Y").strip()


def pct_to_level(pct: int, warn: int, hard: int) -> str:
    if pct >= hard:
        return "HARD"
    if pct >= warn:
        return "WARNING"
    return "OK"


def tag_for_fs(fs: str) -> str:
    if fs.startswith("//"):
        return "SMB"
    if ":/" in fs:
        return "NFS"
    if fs.startswith("zpool"):
        return "ZFS"
    return "FS"


def human_gib_from_kblocks(kblocks: int) -> str:
    # df -kP => 1K blocks
    gib = kblocks / (1024 * 1024)
    return f"{gib:0.1f}"


def parse_df() -> list:
    p = run("df -kP")
    if p.returncode != 0:
        raise RuntimeError(f"df falhou: rc={p.returncode} stderr={p.stderr.strip()}")

    lines = p.stdout.strip().splitlines()
    if not lines:
        return []

    rows = []
    for line in lines[1:]:
        parts = line.split()
        # Filesystem 1024-blocks Used Available Capacity Mounted on
        if len(parts) < 6:
            continue
        fs = parts[0]
        used_k = int(parts[2])
        avail_k = int(parts[3])
        cap = parts[4].strip()
        mnt = parts[5]

        if not cap.endswith("%"):
            continue

        pct = int(cap[:-1])

        if fs not in WATCHLIST:
            continue

        level = pct_to_level(pct, warn=args.warn, hard=args.hard)
        tag = tag_for_fs(fs)

        rows.append({
            "fs": fs,
            "pct": pct,
            "level": level,
            "mnt": mnt,
            "used_gib": human_gib_from_kblocks(used_k),
            "avail_gib": human_gib_from_kblocks(avail_k),
            "tag": tag,
        })

    # ordena por uso desc
    rows.sort(key=lambda r: r["pct"], reverse=True)
    return rows


def need_send(rows: list, force: bool, cooldown_hours: int) -> bool:
    if force:
        return True

    # manda só se existir WARNING/HARD
    alert = any(r["level"] in ("WARNING", "HARD") for r in rows)
    if not alert:
        return False

    # cooldown
    try:
        st = os.stat(STATE_FILE)
        age_sec = time.time() - st.st_mtime
        if age_sec < cooldown_hours * 3600:
            return False
    except FileNotFoundError:
        pass

    return True


def terminal_table(rows: list) -> str:
    # larguras fixas (ajuste aqui se quiser)
    w_fs = 28
    w_pct = 4
    w_lvl = 7
    w_mnt = 26
    w_used = 10
    w_avail = 10
    w_tag = 4

    header = (
        f"{'FILESYSTEM':<{w_fs}}  "
        f"{'USO':>{w_pct}} "
        f"{'NIVEL':<{w_lvl}} "
        f"{'MOUNT':<{w_mnt}} "
        f"{'USED':>{w_used}} "
        f"{'AVAIL':>{w_avail}} "
        f"{'TAG':<{w_tag}}"
    )
    sep = "=" * len(header)

    out = [header, sep]

    for r in rows:
        color = ANSI_GREEN
        if r["level"] == "HARD":
            color = ANSI_RED
        elif r["level"] == "WARNING":
            color = ANSI_YELLOW

        line = (
            f"{r['fs']:<{w_fs}}  "
            f"{(str(r['pct']) + '%'):>{w_pct}} "
            f"{r['level']:<{w_lvl}} "
            f"{r['mnt']:<{w_mnt}} "
            f"{(r['used_gib']):>{w_used}} "
            f"{(r['avail_gib']):>{w_avail}} "
            f"{r['tag']:<{w_tag}}"
        )

        # pinta a LINHA toda (seu pedido)
        out.append(f"{color}{line}{ANSI_RESET}")

    out.append(sep)
    return "\n".join(out)


def html_color(pct: int) -> tuple[str, str]:
    # até 79 verde, 80-89 laranja, 90+ vermelho negrito
    if pct <= 79:
        return ("#15803d", "normal")
    if 80 <= pct <= 89:
        return ("#c2410c", "bold")  # laranja escuro + destaque
    return ("#b00020", "bold")


def build_html(rows: list, warn: int, hard: int) -> str:
    hard_count = sum(1 for r in rows if r["level"] == "HARD")
    warn_count = sum(1 for r in rows if r["level"] == "WARNING")

    dt = datetime.now().strftime("%a %b %d %H:%M:%S -03 %Y")

    tr = []
    for r in rows:
        color, weight = html_color(r["pct"])
        pct_style = f"color:{color};font-weight:{weight};"
        lvl_style = pct_style

        tr.append(
            "<tr>"
            f"<td>{r['level']}</td>"
            f"<td>{r['tag']}</td>"
            f"<td>{r['fs']}</td>"
            f"<td>{r['mnt']}</td>"
            f"<td align='right' style='{pct_style}'>{r['pct']}%</td>"
            f"<td align='right'>{r['used_gib']} GiB</td>"
            f"<td align='right'>{r['avail_gib']} GiB</td>"
            f"<td style='{lvl_style}'>{r['level']}</td>"
            "</tr>"
        )

    html = (
        "<html><body style='font-family:Arial,Helvetica,sans-serif;font-size:13px;'>"
        "<h3 style='margin:0;'>TrueNAS - alerta de capacidade</h3>"
        f"<div>Host: <b>{HOST_LABEL}</b></div>"
        f"<div>Data: <b>{dt}</b></div>"
        f"<div>Limites: Warning &ge; {warn}% | Hard &ge; {hard}%</div>"
        f"<div>Resumo: <b>{hard_count}</b> HARD, <b>{warn_count}</b> WARNING</div>"
        "<br/>"
        "<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse;'>"
        "<tr style='background:#f3f4f6;'>"
        "<th align='left'>Nivel</th>"
        "<th align='left'>Tag</th>"
        "<th align='left'>Filesystem</th>"
        "<th align='left'>Mount</th>"
        "<th align='right'>Uso</th>"
        "<th align='right'>Used</th>"
        "<th align='right'>Avail</th>"
        "<th align='left'>Status</th>"
        "</tr>"
        + "".join(tr) +
        "</table>"
        f"<br/><div style='color:#6b7280;'>df_alert.py v{VERSION}</div>"
        "</body></html>"
    )
    return html


def build_text(rows: list, warn: int, hard: int) -> str:
    # fallback: texto simples
    lines = [
        f"TrueNAS - alerta de capacidade",
        f"Host: {HOST_LABEL}",
        f"Data: {now_str()}",
        f"Limites: Warning >= {warn}% | Hard >= {hard}%",
        "",
    ]
    for r in rows:
        lines.append(f"{r['fs']} {r['pct']}% {r['level']} {r['mnt']} used={r['used_gib']}GiB avail={r['avail_gib']}GiB tag={r['tag']}")
    lines.append(f"\n(df_alert.py v{VERSION})")
    return "\n".join(lines)


def midclt_send(subject: str, to_list: list[str], text: str, html: str, timeout: int = 120) -> tuple[bool, str]:
    # TrueNAS espera: to: list[str], subject: str, text: str, html: str
    payload = {
        "to": to_list,
        "subject": subject,
        "text": text,
        "html": html,
    }

    cmd = "midclt call mail.send " + shlex.quote(json.dumps(payload))
    p = run(cmd)
    if p.returncode != 0:
        return False, f"midclt mail.send rc={p.returncode} stderr={p.stderr.strip()} stdout={p.stdout.strip()}"

    job_id_str = p.stdout.strip()
    if not job_id_str.isdigit():
        return False, f"midclt mail.send retorno inesperado: {job_id_str}"

    job_id = int(job_id_str)

    # espera job terminar
    cmd_wait = f"midclt call core.job_wait {job_id} {timeout}"
    pw = run(cmd_wait)
    if pw.returncode != 0:
        return False, f"job_wait rc={pw.returncode} stderr={pw.stderr.strip()} stdout={pw.stdout.strip()}"

    try:
        j = json.loads(pw.stdout)
        state = j.get("state")
        error = j.get("error")
        if state != "SUCCESS":
            return False, f"job_id={job_id} state={state} error={error}"
        return True, f"job_id={job_id} state=SUCCESS"
    except Exception:
        # mesmo assim considera enviado, se job_wait voltou ok
        return True, f"job_id={job_id} state=SUCCESS (nao parseou JSON)"


def write_state(ok: bool, info: str, to_env: str):
    with open(STATE_FILE, "w") as f:
        f.write(f"date={now_str()} host={HOST_LABEL} rc={'0' if ok else '1'} info={info} to={to_env}\n")


def log_append(msg: str):
    with open(LOG_FILE, "a") as f:
        f.write(f"{now_str()} {msg}\n")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("-v", "--verbose", action="store_true", help="mostra resumo no terminal")
    ap.add_argument("-f", "--force", action="store_true", help="forca envio (ignora cooldown)")
    ap.add_argument("--warn", type=int, default=WARN_PCT_DEFAULT)
    ap.add_argument("--hard", type=int, default=HARD_PCT_DEFAULT)
    ap.add_argument("--cooldown-hours", type=int, default=COOLDOWN_HOURS_DEFAULT)
    ap.add_argument("--subject-prefix", default=f"{HOST_LABEL} - ")
    args = ap.parse_args()

    try:
        rows = parse_df()
    except Exception as e:
        print(f"ERRO: {e}")
        sys.exit(2)

    if not rows:
        print("SEM DADOS (watchlist nao bateu com df).")
        sys.exit(1)

    send_needed = need_send(rows, force=args.force, cooldown_hours=args.cooldown_hours)

    if args.verbose:
        print(f"send_needed={'1' if send_needed else '0'} (0=nao envia, 1=envia)")
        print(f"cooldown_hours={args.cooldown_hours} force={'1' if args.force else '0'}")
        print(f"warn>={args.warn}% hard>={args.hard}%\n")
        print(terminal_table(rows))
        print("")

    if not send_needed:
        log_append("SEM ALERTA. Nao enviou email.")
        if args.verbose:
            print("SEM ALERTA. Nao enviou email.")
            print(f"TMP: {LOG_FILE}")
            print("Dica: thresholds e cooldown podem impedir envio.")
        sys.exit(0)

    # monta email
    subject = args.subject_prefix + "TrueNAS - alerta de capacidade"
    html = build_html(rows, args.warn, args.hard)
    text = build_text(rows, args.warn, args.hard)

    ok, info = midclt_send(subject, TO_LIST, text, html, timeout=180)

    log_append(f"send_needed=1 midclt={ok} info={info}")

    if ok:
        write_state(True, info, " ".join(TO_LIST))
        if args.verbose:
            print(f"EMAIL OK ({info})")
        sys.exit(0)
    else:
        # não marca cooldown se falhou
        if args.verbose:
            print(f"EMAIL FALHOU ({info})")
            print("Veja /var/log/middlewared.log")
        sys.exit(3)