**1.8.1**: Release files now carry their version in the name: `TikTokHD-1.8.1.ipa` and `TikTokHD-PC-1.8.1.zip` (the PC scripts together, since they need each other), so a new download no longer arrives as "TikTokHD 2.ipa".

**1.8**: **Silent works on iPhone now.** In 1.7 every Silent patch failed with "no video track": the file was fine, but the app checked it with Apple's video reader, which refuses Silent's filler samples. The app now checks Silent files with its own reader (same tracks, same codec/size/HDR/Dolby Vision, every frame byte for byte). TikTok tab: when iOS ends TikTok's page (out of memory, often with a big 4K/HDR video at the end of an upload), the app now says so instead of the page silently reloading, and ⋯ → Page report lists every reload and crash with its time. Inflate is now marked "not recommended": its filler frames each take a frame's time, so the video track is about 5 times longer than the clip and TikTok can turn it into slow motion (Silent's fillers take no time). The desktop site now presents itself as Safari 26 (TikTok showed "Please upgrade to the latest version" to Safari 18).

**1.7**: New default method, **Silent**, a rebuild of the newest community method (Silent Method, Nov 2026): the index goes first, sound and picture are interleaved, filler samples are added only to the size table, the bitrate box is fixed and editing-app metadata is removed. The picture and sound stay bit for bit the same. New in the TikTok tab: ⋯ → **Check video quality** on your posted video shows the streams TikTok really serves (resolution, codec, bitrate). Don't judge by "Save video": TikTok always gives a smaller copy there. Right after posting only low streams may exist, so check again after 10 to 30 minutes. Same Silent method on PC: `python tiktok_prep.py --method silent video.mov out.mp4`.

**1.6**: TikTok stopped honouring the old patch for many uploads, so there are now three methods. Patch tab: pick Header (the old one), Inflate (tiny filler samples so the file reads as very dense) or FPS (60 fps reads as 30). All of them keep the picture and sound bit for bit. If a video still comes out soft, patch it again with another method and post as Only me to compare. Same three methods on PC: `python tiktok_prep.py --method all video.mov out.mp4` (keep tiktok_methods.py next to it).

**1.5**: The Accounts tab can now act on all accounts at once. Link button: open the same link in every account. Film button: pick a patched video and it is handed to TikTok Studio's upload box in every account at the same time (each account has to be logged in). Each account reports its own result on screen.

**1.4**: New Accounts tab. Add as many TikTok accounts as you like, each one in its own separate container (own login, own cookies, nothing shared), and keep them all open at once. Tap a name at the bottom to switch, hold a name to delete that account and wipe its login. Needs iOS 17 or newer; on iOS 16 the tab says so and the rest of the app works as before.

**1.3**: Fixes "couldn't find TikTok's upload box" (1.2 asked the page without waiting for its answer, so it never saw the box). The film button also tries harder: it fills TikTok's upload box directly (also inside frames and shadow DOM), else presses TikTok's own Select video and puts the video in instead of the file picker, else drops it on the upload area, else asks you to tap Select video (the video goes in instead of the picker). New: ⋯ → Page report, to copy and send if it still fails.

**1.2**: Save the patched video (Save to Files…, Save to Photos, Share / AirDrop). "Upload in TikTok Studio" now puts the video in TikTok's upload box by itself (also the film button in the TikTok tab); if TikTok's page changes and that fails, the app says so and you pick it from Files.

**1.1**: TikTok Studio no longer shows "download in App Store": in desktop mode the app now presents itself as Safari on a Mac (Mac user agent, no touch, desktop-size screen, 1280 px layout).

**TikTokHD-<version>.ipa**: the iPhone app. Install it with Sideloadly on Windows (free Apple ID; install again every 7 days).

- **Patch** tab: pick a video (Photos or Files). It's copied without re-encoding and patched; the app shows original vs patched (size, fps, HDR, Dolby Vision, frames) and refuses if anything changed. Saved in Files > On My iPhone > TikTok HD.
- **TikTok** tab: TikTok in the app. Mobile site for browsing and login; TikTok Studio opens as the desktop site scaled to the phone screen.

**TikTokHD-PC-<version>.zip** (tiktok_prep.py, tiktok_app.py, tiktok_methods.py; unzip into one folder): the same patch on a PC (needs Python + ffmpeg).

Upload the patched file from Files (not Photos: iOS compresses videos picked from Photos). Post as Only me first to check. TikTok can stop honouring the patch at any time.
