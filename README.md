# videocodec

Post 4K / 60 fps / HDR videos on TikTok with the least quality loss.

The patch: the video is copied **without re-encoding** (every frame stays bit for bit the same) and
its movie header (`mvhd`) gets version 1 with the longest possible duration, the method of
[buwryme/tiktok-lossless-upload](https://github.com/buwryme/tiktok-lossless-upload) (Editing News'
patcher). Upload the result through **TikTok Studio's desktop version**. TikTok can stop honouring it
at any time.

## iPhone app (`ios/`)
Download **TikTokHD.ipa** from [Releases](../../releases), install it with
[Sideloadly](https://sideloadly.io) on Windows (needs Apple's iTunes from apple.com, a cable and an
Apple ID). On the iPhone: Settings > Privacy & Security > Developer Mode on, then trust the app in
Settings > General > VPN & Device Management. Free Apple ID: install again every 7 days.

- **Patch** tab: choose a video from Photos (original file) or Files. Checks the result (codec, size,
  fps, HDR, Dolby Vision, frame count) and refuses if anything changed. Saved in
  Files > On My iPhone > TikTok HD.
- **TikTok** tab: tiktok.com in its mobile version (log in with email/phone/username; Google sign-in
  is blocked in in-app browsers). **Upload** opens TikTok Studio as the desktop site, scaled to the
  screen. In Studio pick the file through Choose File > Browse > On My iPhone > TikTok HD (not Photos:
  iOS compresses videos picked from Photos).

Built by GitHub Actions (`.github/workflows/ios.yml`): every push to `main` makes an unsigned `.ipa`
artifact and publishes the release named after `VERSION` (bump it for a new release).

## PC (`pc/`, needs Python and ffmpeg: `winget install ffmpeg`)
```
python pc/tiktok_prep.py --patch hike.mov hike_patched.mp4
python pc/tiktok_app.py        # web page on http://localhost:8765 (phone: same Wi-Fi)
```

**If one method stops working:** TikTok changes how it handles uploads often, so a single trick does not last.
The PC tool has three, all of which copy the video bit for bit and change only the container:
```
python pc/tiktok_prep.py --method all hike.mov hike.mp4   # writes hike_mvhd / hike_inflate / hike_fps
```
- `mvhd`: the movie header set to the longest duration (the original method here).
- `inflate`: NoBlur style, tiny filler video samples so the file reads as very high density.
- `fps`: a 60 fps clip reads as 30 fps (120 reads as 30), so TikTok keeps every frame.

Upload each version through TikTok Studio on desktop with "Allow high-quality uploads" on, posted as Only me,
and keep the one that stays sharp. `inflate` and `fps` come from KizaruZero/tiktok-fidelity (MIT,
`pc/TIKTOK_FIDELITY_LICENSE.txt`) with a fix for files whose index comes last.
