**1.2**: Save the patched video (Save to Files…, Save to Photos, Share / AirDrop). "Upload in TikTok Studio" now puts the video in TikTok's upload box by itself (also the film button in the TikTok tab); if TikTok's page changes and that fails, the app says so and you pick it from Files.

**1.1**: TikTok Studio no longer shows "download in App Store": in desktop mode the app now presents itself as Safari on a Mac (Mac user agent, no touch, desktop-size screen, 1280 px layout).

**TikTokHD.ipa**: the iPhone app. Install it with Sideloadly on Windows (free Apple ID; install again every 7 days).

- **Patch** tab: pick a video (Photos or Files). It's copied without re-encoding and patched; the app shows original vs patched (size, fps, HDR, Dolby Vision, frames) and refuses if anything changed. Saved in Files > On My iPhone > TikTok HD.
- **TikTok** tab: TikTok in the app. Mobile site for browsing and login; TikTok Studio opens as the desktop site scaled to the phone screen.

**tiktok_prep.py** / **tiktok_app.py**: the same patch on a PC (needs Python + ffmpeg).

Upload the patched file from Files (not Photos: iOS compresses videos picked from Photos). Post as Only me first to check. TikTok can stop honouring the patch at any time.
