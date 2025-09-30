# Changelog

## v0.3.1
- Fix POSIX /bin/sh compatibility (remove process substitution, fix function calls, tidy redirects).
- Update documentation/paths to `/usr/local/scripts` and provided GitHub raw URL.
- Keep v0.3 features: `--dry-run`, `--pre-flight`, `--allow`/`--deny`.

## v0.3
- Added `--dry-run`, `--pre-flight`, and allow/deny policy checks.

## v0.2
- Late color initialization (so `--no-color` applies).
- Ensure mountpoint directory exists (`mkdir -p`).
- Stronger marker handling (permissions, validation, custom path).
- `--test-marker` diagnostic sub-command.
- More robust mount detection and clearer messaging.

## v0.1
- Initial public version with temporary/permanent activation, promote-after-reboot flow, and marker writer.