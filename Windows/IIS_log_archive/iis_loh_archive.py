#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Script: iis_log_archiver.py
Version: 1.2.0
Author: Karim Mansur - NetTech

Description:
Archive IIS logs (u_exYYMMDD.log) using WinRAR.

Rules:
- Group logs by year/month
- Create archive: W3SVCX_MM_YYYY.rar
- NEVER compress current month
- Skip current day logs
- Optional delete after compression
"""

import os
import re
import subprocess
import logging
import logging.handlers
import argparse
import sys
from datetime import datetime

# ================= CONFIG =================

DEFAULT_LOG_DIR = r'C:\inetpub\logs\LogFiles'
ARCHIVE_SUFFIX = '.rar'
COMPRESSION_LEVEL = 5

# ==========================================


# ---------- LOGGING ----------
def setup_logging(log_file, verbose):
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)

    file_handler = logging.handlers.RotatingFileHandler(
        log_file, maxBytes=10 * 1024 * 1024, backupCount=5
    )
    file_formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(file_formatter)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    console_formatter = logging.Formatter('%(levelname)s: %(message)s')
    console_handler.setFormatter(console_formatter)
    logger.addHandler(console_handler)


# ---------- WINRAR ----------
def find_winrar():
    paths = [
        r'C:\Program Files\WinRAR\WinRAR.exe',
        r'C:\Program Files (x86)\WinRAR\WinRAR.exe'
    ]
    for p in paths:
        if os.path.exists(p):
            return p
    raise FileNotFoundError("WinRAR not found")


# ---------- PARSE DATE ----------
def extract_date(filename):
    match = re.search(r'u_ex(\d{6})\.log$', filename)
    if not match:
        return None

    yymmdd = match.group(1)
    yy = int(yymmdd[:2])
    mm = int(yymmdd[2:4])

    if mm < 1 or mm > 12:
        return None

    year = 2000 + yy
    return year, mm


# ---------- GROUP ----------
def group_logs(files):
    groups = {}
    for f in files:
        data = extract_date(f)
        if not data:
            continue

        year, month = data
        key = (year, month)
        groups.setdefault(key, []).append(f)

    return groups


# ---------- COMPRESS ----------
def compress(winrar, files, archive_path, dry_run):

    if dry_run:
        logging.info(f"[DRY-RUN] Would create: {archive_path}")
        return True

    file_list = ' '.join(f'"{f}"' for f in files)

    cmd = f'"{winrar}" a -m{COMPRESSION_LEVEL} -ep1 "{archive_path}" {file_list}'

    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

        if result.returncode == 0:
            logging.info(f"[OK] Created: {archive_path}")
            return True
        else:
            logging.error(f"[ERROR] WinRAR: {result.stderr}")
            return False

    except Exception as e:
        logging.error(f"[EXCEPTION] {e}")
        return False


# ---------- PROCESS DIR ----------
def process_directory(path, winrar, delete, dry_run, stats):

    files = [f for f in os.listdir(path) if f.startswith('u_ex') and f.endswith('.log')]

    if not files:
        return

    now = datetime.now()
    current_year = now.year
    current_month = now.month
    today_str = now.strftime('%y%m%d')

    valid_files = []

    for f in files:

        if today_str in f:
            continue

        data = extract_date(f)
        if not data:
            continue

        year, month = data

        # skip current month
        if year == current_year and month == current_month:
            continue

        valid_files.append(f)

    groups = group_logs(valid_files)

    subdir_name = os.path.basename(path)

    for (year, month), group in groups.items():

        # 🔥 NOVO PADRÃO
        archive_name = f"{subdir_name}_{month:02d}_{year}{ARCHIVE_SUFFIX}"
        archive_path = os.path.join(path, archive_name)

        if os.path.exists(archive_path):
            logging.info(f"[SKIP] Exists: {archive_path}")
            stats["skipped"] += 1
            continue

        full_paths = [os.path.join(path, f) for f in group]

        success = compress(winrar, full_paths, archive_path, dry_run)

        if success:
            stats["compressed"] += len(full_paths)

            if delete and not dry_run:
                for f in full_paths:
                    try:
                        os.remove(f)
                        logging.info(f"[DELETED] {f}")
                    except Exception as e:
                        logging.error(f"[DELETE ERROR] {f} - {e}")
                        stats["errors"] += 1
        else:
            stats["errors"] += 1


# ---------- WALK ----------
def process_all(base_dir, winrar, delete, dry_run):

    stats = {
        "dirs": 0,
        "compressed": 0,
        "skipped": 0,
        "errors": 0
    }

    for root, dirs, files in os.walk(base_dir):
        if os.path.basename(root).startswith('W3'):
            stats["dirs"] += 1
            logging.info(f"Processing: {root}")
            process_directory(root, winrar, delete, dry_run, stats)

    return stats


# ---------- MAIN ----------
def main():

    parser = argparse.ArgumentParser(description="IIS Log Archiver (WinRAR)")
    parser.add_argument('--log-dir', default=DEFAULT_LOG_DIR)
    parser.add_argument('--delete', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--log-file', default='iis_log_archiver.log')

    args = parser.parse_args()

    setup_logging(args.log_file, args.verbose)

    try:
        winrar = find_winrar()
        logging.info(f"WinRAR found: {winrar}")
    except Exception as e:
        logging.error(e)
        sys.exit(1)

    try:
        stats = process_all(args.log_dir, winrar, args.delete, args.dry_run)

        logging.info("===== SUMMARY =====")
        logging.info(f"Directories processed: {stats['dirs']}")
        logging.info(f"Files compressed: {stats['compressed']}")
        logging.info(f"Skipped: {stats['skipped']}")
        logging.info(f"Errors: {stats['errors']}")

    except Exception as e:
        logging.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()