# Changelog

## v0.3
- Add `--dry-run` for full plan preview with no changes.
- Add `--pre-flight` validations (root, tools, mountpoint, BE existence, marker path, zpool free hint).
- Add `--allow` / `--deny` for policy enforcement using `pkg -r <MNT> upgrade -n` plan.
- Minor hardening and clearer messages.

## v0.2
- Late color init; mkdir -p for mountpoint.
- Stronger marker handling (permissions, validation, custom path).
- `--test-marker` diagnostic sub-command.
- More robust mount detection and clearer messaging.

## v0.1
- Initial version with temporary/permanent activation and promote-after-reboot flow.
