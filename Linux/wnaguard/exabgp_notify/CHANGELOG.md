# Changelog

## [0.1] - 2025-10-10
### Added
- Initial release of `exabgp-notify`.
- Python script that parses ExaBGP human-readable log lines from STDIN and sends notifications to Telegram and/or Email.
- Systemd unit with hardening options; uses `/etc/exabgp-notify/exabgp-notify.cfg` as EnvironmentFile.
- Example configuration with throttling and de-duplication knobs.
- Detailed README with install, permissions, troubleshooting, and security notes.
