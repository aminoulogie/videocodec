# videocodec: project memory

TikTok HD: an iPhone app (`ios/`, SwiftUI, sideloaded with Sideloadly) and PC scripts (`pc/`, Python)
that patch videos so TikTok keeps their quality. See README.md.

## Rules from the user (always)
- **Every release file ends with its version** (2026-11-12): `TikTokHD-<version>.ipa`, and
  `TikTokHD-PC-<version>.zip` for the PC scripts (they import each other by name, so they ship
  together in one zip, never renamed one by one). Never publish a bare `TikTokHD.ipa`: downloading
  a new one then arrives as "TikTokHD 2.ipa" and the user has to rename it. The names are made in
  the publish step of `.github/workflows/ios.yml` from `VERSION`. Any new release file follows the
  same pattern.
- Bump `VERSION` and add a line on top of RELEASE_NOTES.md for each release; a push to `main`
  publishes it.

## Notes
- Silent's filler samples make AVFoundation report "no video track": check Silent results with
  `Mp4.silentCheck`, not AVFoundation (fixed in 1.8).
- Inflate gives slow motion on TikTok (fillers take a frame's time each): not recommended.
- The TikTok tab's page can be ended by iOS (out of memory with big 4K/HDR uploads);
  `webViewWebContentProcessDidTerminate` reports it and ⋯ → Page report lists reloads/crashes.
- Verify Swift changes with the workflow (workflow_dispatch on the branch) before merging:
  no Swift compiler in the cloud sessions.
- `--prepare` (PC, 1.9) is the only mode that re-encodes; every method stays a bit for bit copy of
  its input. iPhone (1.10): `Prepare.swift`,
  AVAssetReader -> AVAssetWriter (hardware encoder, bitrate not CRF, keeps the source codec, HEVC 10-bit
  for HDR, frames snapped to an exact grid). Not in tiktok_app.py yet.
