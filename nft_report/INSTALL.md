## Requirements (Debian)

Install required packages:

```bash
sudo apt update
sudo apt install msmtp msmtp-mta gawk coreutils grep -y
```

## Sample /etc/msmtprc Configuration

```bash
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /tmp/msmtp.log

account default
host smtp.yourdomain.com
port 587
from mailproc@yourdomain.com
user mailproc@yourdomain.com
password YOUR_PASSWORD_HERE
```

Security:
Ensure restricted access to credentials:

```bash
sudo chmod 600 /etc/msmtprc
sudo chown root:root /etc/msmtprc
```

Installation
Copy the script:

```bash
sudo mkdir -p /usr/local/scripts
sudo cp nft_report.sh /usr/local/scripts/
sudo chmod +x /usr/local/scripts/nft_report.sh
```

Usage
Display a report using the current system log:
```bash
./nft_report.sh
```
Analyze a rotated log file (e.g., yesterday):

```bash
./nft_report.sh --log /var/log/syslog.1
```
Send the report via email:
```bash
./nft_report.sh --mail
```
Use a custom log file and send it via email:
```bash
./nft_report.sh --log /var/log/syslog.1 --mail
```
Show help:
```bash
./nft_report.sh --help
```

Logrotate Integration (Optional)
To automatically run the report after system log rotation, edit /etc/logrotate.d/rsyslog and add this block:

```conf
postrotate
    /usr/lib/rsyslog/rsyslog-rotate
    /usr/local/scripts/nft_report.sh --log /var/log/syslog.1 --mail
endscript
```

This ensures the report is generated and emailed each time syslog is rotated.

License
This script is released under the MIT License.
