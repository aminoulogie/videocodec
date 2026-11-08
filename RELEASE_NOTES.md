**1.6**: TikTok stopped honouring the old patch for many uploads, so there are now three methods. Patch tab: pick Header (the old one), Inflate (tiny filler samples so the file reads as very dense) or FPS (60 fps reads as 30). All of them keep the picture and sound bit for bit. If a video still comes out soft, patch it again with another method and post as Only me to compare. Same three methods on PC: `python tiktok_prep.py --method all video.mov out.mp4` (keep tiktok_methods.py next to it).

**1.5**: The Accounts tab can now act on all accounts at once. Link button: open the same link in every account. Film button: pick a patched video and it is handed to TikTok Studio's upload box in every account at the same time (each account has to be logged in). Each account reports its own result on screen.

**1.4**: New Accounts tab. Add as many TikTok accounts as you like, each one in its own separate container (own login, own cookies, nothing shared), and keep them all open at once. Tap a name at the bottom to switch, hold a name to delete that account and wipe its login. Needs iOS 17 or newer; on iOS 16 the tab says so and the rest of the app works as before.

**1.3**: Fixes "couldn't find TikTok's upload box" (1.2 asked the page without waiting for its answer, so it never saw the box). The film button also tries harder: it fills TikTok's upload box directly (also inside frames and shadow DOM), else presses TikTok's own Select video and puts the video in instead of the file picker, else drops it on the upload area, else asks you to tap Select video (the video goes in instead of the picker). New: ⋯ → Page report, to copy and send if it still fails.

**1.2**: Save the patched video (Save to Files…, Save to Photos, Share / AirDrop). "Upload in TikTok Studio" now puts the video in TikTok's upload box by itself (also the film button in the TikTok tab); if TikTok's page changes and that fails, the app says so and you pick it from Files.

**1.1**: TikTok Studio no longer shows "download in App Store": in desktop mode the app now presents itself as Safari on a Mac (Mac user agent, no touch, desktop-size screen, 1280 px layout).

**TikTokHD.ipa**: the iPhone app. Install it with Sideloadly on Windows (free Apple ID; install again every 7 days).

- **Patch** tab: pick a video (Photos or Files). It's copied without re-encoding and patched; the app shows original vs patched (size, fps, HDR, Dolby Vision, frames) and refuses if anything changed. Saved in Files > On My iPhone > TikTok HD.
- **TikTok** tab: TikTok in the app. Mobile site for browsing and login; TikTok Studio opens as the desktop site scaled to the phone screen.

**tiktok_prep.py** / **tiktok_app.py**: the same patch on a PC (needs Python + ffmpeg).

Upload the patched file from Files (not Photos: iOS compresses videos picked from Photos). Post as Only me first to check. TikTok can stop honouring the patch at any time.
