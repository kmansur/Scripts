# Changelog

## 1.4.0 — 2025-09-20
- Merge logic: **Onionoo + exit-addresses** (+ optional dan.me.uk)
- Per-source counters and concise summary
- Stable sorted output for consistent diff/cmp
- Clear logging ([info]/[warn]/[debug]/[error])

## 1.3.0 — 2025-09-20
- Robust Onionoo parsing (multiline JSON slurp)
- Added Tor `exit-addresses` fallback
- Verbosity levels; IPv4-only; short-circuit via `cmp -s`
- Atomic replace; correct `pfctl -t ... -T replace -f ...`
- Optional third-party primary via feature flag
