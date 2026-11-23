# Changelog

## v1.0.0 — 2026-11-23

- Standardized the Android/iOS application release name at `1.0.0`, with build
  number `2019` to keep binary upgrades monotonic.
- Kept recognition bundle `1.3.0` independently versioned and added build-aware
  OTA compatibility metadata so the reset app version does not block model
  updates or authorize unsupported legacy clients.
- Added a non-destructive SQLite v2 migration for cached FSL vocabulary and
  connected the optional backend vocabulary endpoint to offline spelling
  suggestions. Failed or malformed sync responses preserve the last good cache.
- Aligned FastAPI inference with the app's canonical model and label bundle;
  added OTA checksum checks so label or model mismatches are caught before release.
- Pinned the backend's direct runtime dependencies and retained the committed
  Flutter dependency lockfile.
- Updated release workflow defaults, model compatibility checks, project
  documentation, and the v1.0.0 architecture map.
- Made the official Android release Shorebird-enabled and limited distribution
  to one signed ARM64 APK so future Dart-only changes can use OTA patches.
