# IIS Log Archiver (WinRAR)

Python script to archive IIS logs by month using WinRAR.

---

## Objective

- Organize IIS logs
- Reduce disk usage
- Automate monthly archiving
- Ensure safety (no active logs processed)

---

## Expected Structure

Base directory:

C:\inetpub\logs\LogFiles\

Subdirectories:

W3SVC1\
W3SVC2\
W3SVC9\
...

Files:

u_exYYMMDD.log  
Example: u_ex260223.log

---

## How It Works

The script:

1. Scans all `W3SVC*` directories
2. Identifies valid log files
3. Groups logs by month/year
4. Creates `.rar` archive in the same directory

---

## Archive Naming

Before:

u_ex260201.log  
u_ex260202.log  

After:

W3SVC9_02_2026.rar  

Format:

<W3SVC>_<MM>_<YYYY>.rar

---

## Safety Rules

The script NEVER:

- Compresses current month
- Compresses current day
- Overwrites existing archives
- Deletes logs if compression fails

---

## Requirements

- Windows Server
- Python 3.x
- WinRAR installed

Supported paths:

C:\Program Files\WinRAR\WinRAR.exe  
C:\Program Files (x86)\WinRAR\WinRAR.exe  

---

## Usage

Default execution:

python iis_log_archiver.py

---

Dry run (recommended first):

python iis_log_archiver.py --dry-run --verbose

---

Execution with deletion:

python iis_log_archiver.py --delete

---

Verbose execution:

python iis_log_archiver.py --delete --verbose

---

## Parameters

| Parameter   | Description |
|------------|------------|
| --log-dir  | Base log directory |
| --delete   | Delete logs after compression |
| --dry-run  | Simulation mode |
| --verbose  | Detailed output |
| --log-file | Log file name |

---

## Logs

Default log file:

iis_log_archiver.log

Contains:

- Execution details
- Errors
- Processed files
- Summary

---

## Summary Example

===== SUMMARY =====  
Directories processed: 5  
Files compressed: 320  
Skipped: 2  
Errors: 0  

---

## Task Scheduler

Program:

python

Arguments:

C:\scripts\iis_log_archiver.py --delete

---

## Best Practices

Before production:

1. Run:
--dry-run

2. Run without delete:
python iis_log_archiver.py --verbose

3. Validate `.rar` files

4. Then enable:
--delete

---

## Attention Points

- Ensure enough disk space
- Verify write permissions
- Ensure WinRAR is installed
- Avoid concurrent executions

---

## Security

- Does not process active logs
- Does not overwrite archives
- Deletes only after success

---

## Future Improvements

- Email alerts on error
- Retention policy (e.g., keep 90 days)
- Parallel execution
- Lockfile to prevent concurrency

---

## Author

NetTech  
Infrastructure, automation and networking
