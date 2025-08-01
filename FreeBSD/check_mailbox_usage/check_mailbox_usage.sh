#!/bin/sh

# Mailbox Usage Report for FreeBSD
# Version 1.2

# Base directories
DIRS="/var/Users1 /var/Users2"

# Output report file
REPORT="/tmp/mailbox_usage_report_$(date +%Y%m%d).txt"

# Temporary file for sorting
TMPFILE="/tmp/mailbox_usage.tmp"

# Header
{
  echo "Mailbox Usage Report - Generated on $(date)"
  echo "-------------------------------------------------------"
  printf "%-50s %10s\n" "Mailbox" "Size (GB)"
  echo "-------------------------------------------------------"
} > "$REPORT"

# Clear temporary file
> "$TMPFILE"

# Loop through directories and subdirectories
for BASE_DIR in $DIRS; do
    if [ -d "$BASE_DIR" ]; then
        find "$BASE_DIR" -mindepth 3 -maxdepth 3 -type d -name Maildir | while read -r MAILDIR; do
            SIZE=$(du -sh -g "$MAILDIR" | cut -f1)
            MAILBOX=$(dirname "$MAILDIR")
            printf "%-50s %10s\n" "$MAILBOX" "$SIZE" >> "$TMPFILE"
        done
    else
        echo "Directory $BASE_DIR does not exist." >> "$TMPFILE"
    fi
done

# Sort and append to report
sort "$TMPFILE" >> "$REPORT"

# Footer
echo "-------------------------------------------------------" >> "$REPORT"
echo "Report completed and saved to $REPORT"

# Cleanup temporary file
rm "$TMPFILE"