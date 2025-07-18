# nft_report.sh (v1.1)

`nft_report.sh` is a simple Bash script to generate reports based on `nftables` log entries (with the `NFT-DROP:` prefix). It parses system log files such as `/var/log/syslog`, generates network abuse summaries, and can optionally send the report via email using `msmtp`.

---

## ✅ Features

- Parses nftables drop logs (`NFT-DROP:`) from system log files
- Generates:
  - Top source IPs
  - Top destination ports
  - Most targeted interfaces
  - Source IP to port mapping
- Supports custom log file input (`--log`)
- Fails early if the specified log file does not exist
- Can send reports via SMTP-authenticated email (`--mail`)
- Lightweight, no external dependencies beyond standard Linux tools

---
