#!/bin/bash
# nft_report.sh - version 1.0
# Generates a report of nftables drops (with prefix NFT-DROP)
# Optionally sends the report via email using msmtp
# Supports --mail to send, --log to change log file, and --help for usage

# ========== CONFIGURATION ==========
LOG="/var/log/syslog"
PREFIX="NFT-DROP:"
DESTINATION="karim@nettech.com.br"
SENDER="mailproc@mpc.com.br"
SUBJECT="nftables Drop Report - $(date +%Y-%m-%d)"
TMP_FILE="/tmp/nft_report_$$.log"
SEND_EMAIL=false
# ===================================

# Show help and exit
show_help() {
  echo "Usage: $0 [options]"
  echo
  echo "Available options:"
  echo "  --mail           Send the report via email using msmtp"
  echo "  --log <file>     Use a different log file (default: /var/log/syslog)"
  echo "  --help           Show this help message"
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mail)
      SEND_EMAIL=true
      shift
      ;;
    --log)
      if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
        LOG="$2"
        shift 2
      else
        echo "Error: --log requires a file path as argument."
        exit 1
      fi
      ;;
    --help)
      show_help
      ;;
    *)
      echo "Error: unknown option '$1'"
      echo "Use --help to see available options."
      exit 1
      ;;
  esac
done

# Generate the report and store it in a temporary file
{
  echo "=== nftables Block Report ==="
  echo "Analyzed log file: $LOG"
  echo "Generated on: $(date)"
  echo "-----------------------------------------"
  echo

  TOTAL=$(grep "$PREFIX" "$LOG" | wc -l)
  echo "🔒 Total blocked attempts: $TOTAL"
  echo

  echo "📌 Top source IPs:"
  grep "$PREFIX" "$LOG" | grep -oP "(?<=\sSRC=)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
    | sort | uniq -c | sort -rn | head -20
  echo

  echo "📦 Top destination ports:"
  grep "$PREFIX" "$LOG" | grep -oP "(?<=DPT=)[0-9]+" \
    | sort | uniq -c | sort -rn | head -20
  echo

  echo "🌐 Most targeted interfaces:"
  grep "$PREFIX" "$LOG" | grep -oP "(?<=IN=)[^ ]+" \
    | sort | uniq -c | sort -rn
  echo

  echo "🔍 Attempts by source IP and destination port:"
  grep "$PREFIX" "$LOG" | grep -oP "SRC=\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|DPT=\K[0-9]+" \
    | paste - - | awk '{print $1 " → " $2}' \
    | sort | uniq -c | sort -rn | head -20
} > "$TMP_FILE"

# Output or send the report
if $SEND_EMAIL; then
  {
    echo "To: $DESTINATION"
    echo "From: $SENDER"
    echo "Subject: $SUBJECT"
    echo
    cat "$TMP_FILE"
  } | msmtp --from="$SENDER" --account=default "$DESTINATION"
else
  cat "$TMP_FILE"
fi

# Cleanup
rm -f "$TMP_FILE"