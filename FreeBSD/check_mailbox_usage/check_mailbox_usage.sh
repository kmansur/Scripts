#!/bin/sh

# Mailbox Usage Report for FreeBSD
# Version 1.1

# Base directories
DIRS="/var/Users1 /var/Users2"

# Output report file
REPORT="mailbox_usage_report_$(date +%Y%m%d).txt"

echo "Mailbox Usage Report - Generated on $(date)" > "$REPORT"
echo "-------------------------------------------------------" >> "$REPORT"
printf "%-50s %10s\n" "Mailbox" "Size" >> "$REPORT"
echo "-------------------------------------------------------" >> "$REPORT
"

# Loop through directories and subdirectories
for BASE_DIR in $DIRS; do
    if [ -d "$BASE_DIR" ]; then
        find "$BASE_DIR" -mindepth 3 -maxdepth 3 -type d -name Maildir | while read -r MAILDIR; do
            SIZE=$(du -sh "$MAILDIR" | cut -f1)
            MAILBOX=$(dirname "$MAILDIR")
            printf "%-50s %10s\n" "$MAILBOX" "$SIZE" >> "$REPORT"
        done
    else
        echo "Directory $BASE_DIR does not exist." >> "$REPORT"
    fi
done

echo "-------------------------------------------------------" >> "$REPORT"
echo "Report completed and saved to $REPORT"