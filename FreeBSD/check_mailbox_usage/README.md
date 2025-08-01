# Mailbox Usage Report Script

## Overview

This shell script generates a report detailing the disk usage of email mailboxes on a FreeBSD system. It calculates mailbox sizes in gigabytes (GB), sorting the results alphabetically, and saves the output to a clearly formatted report file.

## Features

* Automatically scans specified mailbox directories.
* Calculates mailbox sizes precisely in GB.
* Generates sorted, readable reports.
* Stores output reports in the `/tmp` directory for easy access.

## Directory Structure

The script is designed for mailbox structures such as:

```
/var/Users1/A/andre/Maildir
/var/Users2/K/karen.smith/Maildir
```

## Requirements

* FreeBSD operating system
* Standard FreeBSD utilities (`du`, `awk`, `find`, `sort`)

## Installation

1. Clone or copy the script to your FreeBSD system.
2. Make the script executable:

```shell
chmod +x mailbox_usage_report.sh
```

## Usage

Run the script directly from the command line:

```shell
./mailbox_usage_report.sh
```

## Output

A report file named `mailbox_usage_report_YYYYMMDD.txt` will be generated in `/tmp`, containing an alphabetically sorted list of mailboxes and their sizes in GB:

```
Mailbox Usage Report - Generated on Tue Aug  1 2025
-------------------------------------------------------
Mailbox                                            Size (GB)
-------------------------------------------------------
/var/Users1/A/andre                                    2.45
/var/Users2/K/karen.smith                              0.92
-------------------------------------------------------
Report completed and saved to /tmp/mailbox_usage_report_YYYYMMDD.txt
```

## Customization

You can modify the directories scanned by editing the `DIRS` variable in the script.

```shell
DIRS="/your/custom/path /another/custom/path"
```

## License

This script is provided as-is without any warranty. It is licensed under the MIT License.
