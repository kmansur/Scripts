# Changelog

## [0.1.3] - 2025-10-10
### Changed
- Email delivery: robust multi-recipient parsing (comma/semicolon; names supported) using `email.utils.getaddresses`.
- Use pure address for envelope sender; log refused recipients from SMTP server.
- README: document MAIL_TO multi-recipient format and troubleshooting note.
- Service/installer unchanged except version bumps.

## [0.1.2] - 2025-10-10
### Changed
- Installer: never overwrite existing config; instead write versioned template `exabgp-notify.cfg.v0.1.2` with a highlighted notice.
- README: document installer config policy.

## [0.1.1] - 2025-10-10
### Added
- SMTP_SSL (implicit TLS, port 465) and SMTP_STARTTLS toggles.
- VERBOSE flag to log matched events and delivery decisions.
- Installer script bundled (`install.sh`) with `--uninstall` option.
- README updated (installer usage, email TLS matrix, test method, permissions).

## [0.1] - 2025-10-10
### Added
- Initial release.
