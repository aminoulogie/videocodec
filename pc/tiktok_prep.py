#!/usr/bin/env python3
"""Prepare a video for TikTok without touching its pixels.

  python tiktok_prep.py input.mp4 [output.mp4]
  python tiktok_prep.py --patch input.mov [output.mp4]

--patch: lossless remux, then the mvhd duration patch used by
  buwryme/tiktok-lossless-upload (Editing News' method). Keeps HEVC,
  HDR and Dolby Vision. Unverified: TikTok can stop honouring it.

--method NAME (copy video bit for bit, change only the container):
  silent   recommended: index first, tracks interleaved, filler samples
           listed only in the size table, bitrate box fixed, metadata removed
           (the Silent Method layout, Nov 2026)
  mvhd     same as --patch
  inflate  NoBlur style: adds tiny filler video samples so the file reads
           as very high density (needs no audio track)
  fps      60 fps reads as 30 fps (header timing divided by 2; 120 -> 4)
  all      writes one file per method so you can test which one TikTok
           still honours (TikTok changes this often, results vary)

--prepare (optional, runs before the method; the only mode that re-encodes):
  what the 4K / 120 fps posters do before patching (HandBrake step):
  a clean constant-frame-rate encode with a keyframe every second, so
  the container patch has a regular file to work on and TikTok's own
  encoder has an easy source if it ignores the patch.
  SDR -> H.264 CRF 18, HDR -> HEVC 10-bit CRF 18 (HDR10 / HLG kept,
  Dolby Vision is lost). Without --method it uses silent.
    --codec h264|hevc   force the codec (HDR always uses hevc)
    --crf N             quality, lower = better and bigger (default 18)
    --1080              scale down to 1080p (the most reliable size)
    --clean             light denoise + sharpen (only helps when TikTok
                        still compresses the video; leave off otherwise)

- HEVC (H.265, usually HDR): lossless remux. Copies video and audio
  bit for bit, keeps HDR info, tags it hvc1, moves the index to the
  front (faststart). Nothing is re-encoded.
- H.264: runs tiktok-quality (pip install tiktok-quality) if installed,
  otherwise does the same lossless remux.
Afterwards it checks the output has the same codec, size, fps, HDR
and frame count as the input.

Note: no file can stop TikTok re-encoding it on its servers. This only
makes sure what you upload is the untouched original, cleanly packed.
"""
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tiktok_methods as tm

HDR_TRANSFERS = {"smpte2084": "HDR10 (PQ)", "arib-std-b67": "HLG"}


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"[!] failed: {' '.join(cmd)}\n{r.stderr.strip()[-1500:]}")
    return r.stdout


def probe(path):
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
               "-show_entries",
               "stream=codec_name,codec_tag_string,width,height,avg_frame_rate,pix_fmt,"
               "color_transfer,color_primaries,color_space,nb_read_packets:"
               "stream_side_data=side_data_type",
               "-show_entries", "format=duration,size,bit_rate",
               "-of", "json", str(path)])
    data = json.loads(out)
    if not data.get("streams"):
        sys.exit(f"[!] no video track in {path}")
    v = data["streams"][0]
    num, den = (v.get("avg_frame_rate") or "0/1").split("/")
    v["fps"] = float(num) / float(den) if float(den) else 0.0
    v["frames"] = int(v.get("nb_read_packets") or 0)
    v["side"] = sorted({s.get("side_data_type", "") for s in v.get("side_data_list", [])})
    v["format"] = data.get("format", {})
    return v


def describe(v):
    hdr = HDR_TRANSFERS.get(v.get("color_transfer"), "SDR")
    if any("DOVI" in s for s in v["side"]):
        hdr += " + Dolby Vision"
    mb = int(v["format"].get("size", 0)) / 1e6
    mbps = int(v["format"].get("bit_rate", 0)) / 1e6
    return (f"{v['codec_name']} ({v.get('codec_tag_string')}) {v['width']}x{v['height']} "
            f"{v['fps']:.2f}fps {v.get('pix_fmt')} {hdr}, {v['frames']} frames, "
            f"{mb:.1f} MB, {mbps:.1f} Mbps")


def remux(src, dst, codec, faststart=True):
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src),
           "-map", "0:v:0", "-map", "0:a?", "-c", "copy",
           "-map_metadata", "0", "-strict", "unofficial"]  # keeps Dolby Vision
    if faststart:
        cmd += ["-movflags", "+faststart"]
    if codec == "hevc":
        cmd += ["-tag:v", "hvc1"]
    run(cmd + [str(dst)])


def std_fps(fps):
    """Nearest standard rate as (text for ffmpeg, frames per second)."""
    table = [("24000/1001", 23.976), ("24", 24), ("25", 25), ("30000/1001", 29.97),
             ("30", 30), ("50", 50), ("60000/1001", 59.94), ("60", 60),
             ("120000/1001", 119.88), ("120", 120)]
    best = min(table, key=lambda t: abs(t[1] - fps))
    if abs(best[1] - fps) > 1.5:
        return f"{fps:.3f}", fps
    return best


def prepare(src, dst, a, codec=None, crf=18, to1080=False, clean=False):
    """Re-encode src into a regular file: constant frame rate, one closed GOP
    per second, standard pixel format, AAC sound. Returns the codec used."""
    hdr = a.get("color_transfer") in HDR_TRANSFERS
    if hdr:
        if codec == "h264":
            print("[warn] HDR needs HEVC: using hevc instead of h264")
        codec = "hevc"
    codec = codec or "h264"
    rate, fps = std_fps(a["fps"])
    gop = max(1, round(fps))
    vf = []
    if to1080 and min(a["width"], a["height"]) > 1080:
        vf.append("scale='if(gt(iw,ih),-2,1080)':'if(gt(iw,ih),1080,-2)':flags=lanczos")
    if clean:
        vf += ["hqdn3d=1.5:1.5:4:4", "unsharp=5:5:0.4:5:5:0.0"]
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-map", "0:v:0", "-map", "0:a:0?",
           "-map_metadata", "-1", "-fps_mode", "cfr", "-r", rate]
    if vf:
        cmd += ["-vf", ",".join(vf)]
    if codec == "hevc":
        x = [f"keyint={gop}", f"min-keyint={gop}", "open-gop=0", "scenecut=0", "log-level=error"]
        cmd += ["-c:v", "libx265", "-preset", "slow", "-crf", str(crf), "-tag:v", "hvc1"]
        if hdr:
            trc = a["color_transfer"]
            x += ["repeat-headers=1", "colorprim=bt2020", f"transfer={trc}", "colormatrix=bt2020nc"]
            if trc == "smpte2084":
                x.append("hdr10-opt=1")
            cmd += ["-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020",
                    "-color_trc", trc, "-colorspace", "bt2020nc"]
        else:
            cmd += ["-pix_fmt", "yuv420p"]
        cmd += ["-x265-params", ":".join(x)]
    else:
        cmd += ["-c:v", "libx264", "-preset", "slow", "-crf", str(crf), "-pix_fmt", "yuv420p",
                "-profile:v", "high", "-g", str(gop), "-keyint_min", str(gop),
                "-sc_threshold", "0", "-flags", "+cgop"]
    cmd += ["-c:a", "aac", "-b:a", "320k", "-ar", "48000", str(dst)]
    run(cmd)
    return codec


def boxes(buf, start, end):
    """Yield (type, offset, size) of the MP4 boxes in buf[start:end]."""
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack(">I4s", buf[pos:pos + 8])
        if size == 1:
            size = struct.unpack(">Q", buf[pos + 8:pos + 16])[0]
        elif size == 0:
            size = end - pos
        if size < 8 or pos + size > end:
            sys.exit("[!] damaged MP4 structure")
        yield typ.decode("latin-1"), pos, size
        pos += size


def mvhd_patch(path):
    """Editing News / tiktok-lossless-upload method: mvhd version 1 with the
    longest possible duration. Pixels and sample tables are not touched.
    Needs moov after mdat (no chunk offsets move)."""
    buf = bytearray(Path(path).read_bytes())
    top = {t: (o, n) for t, o, n in boxes(buf, 0, len(buf))}
    if "moov" not in top or "mdat" not in top:
        sys.exit("[!] no moov/mdat box")
    mo, mn = top["moov"]
    if mo < top["mdat"][0]:
        sys.exit("[!] moov must come after mdat for this patch")
    if struct.unpack(">I", buf[mo:mo + 4])[0] == 1:
        sys.exit("[!] 64-bit moov size not handled")
    for t, o, n in boxes(buf, mo + 8, mo + mn):
        if t != "mvhd":
            continue
        body = buf[o + 8:o + n]
        if body[0] == 0:
            ct, mt, ts, du = struct.unpack(">IIII", body[4:20])
            new = bytes([1]) + body[1:4] + struct.pack(">QQIQ", ct, mt, ts, 0xFFFFFFFFFFFFFFFF) + body[20:]
        else:
            new = body[:24] + b"\xff" * 8 + body[32:]
        box = struct.pack(">I", 8 + len(new)) + b"mvhd" + new
        grow = len(box) - n
        buf[o:o + n] = box
        struct.pack_into(">I", buf, mo, mn + grow)
        Path(path).write_bytes(buf)
        return
    sys.exit("[!] no mvhd box")


METHODS = ("silent", "mvhd", "inflate", "fps")


def _mdat_payload(data):
    return b"".join(data[b.payload_start:b.payload_end]
                    for b in tm.iter_boxes(data, 0, len(data)) if b.type == "mdat")


def build_method(method, src, dst, a):
    """Lossless remux of src, then one container patch. Returns dst."""
    codec = a["codec_name"]
    if codec not in ("hevc", "h264"):
        sys.exit(f"[!] codec {codec} not handled: export H.264 or HEVC")
    # keep the index (moov) after the video data: every patch below expects that
    remux(src, dst, codec, faststart=False)
    if method == "mvhd":
        mvhd_patch(dst)
        return dst
    if method == "silent":
        tmp = Path(dst).with_name(Path(dst).stem + ".remux.mp4")
        Path(dst).replace(tmp)
        try:
            rep = tm.silent_layout(str(tmp), str(dst))
        except tm.MP4Error as e:
            sys.exit(f"[!] silent: {e}")
        finally:
            tmp.unlink(missing_ok=True)
        print(f"       silent: {rep['frames']} frames + {rep['fakes']} filler samples, index first, tracks interleaved")
        return dst
    original = Path(dst).read_bytes()
    if method == "inflate":
        out, rep = tm.inflate_video_samples(original, multiplier=5)
        if not _mdat_payload(out).startswith(_mdat_payload(original)):
            sys.exit("[!] safety check failed: original video data was not preserved")
        print(f"       inflate: {rep['real_frames']} real frames + {rep['fake_frames']} filler samples")
    elif method == "fps":
        fps = a["fps"]
        div = 2 if 55 <= fps <= 65 else 4 if 110 <= fps <= 130 else 0
        if not div:
            sys.exit(f"[!] fps method needs a 60 or 120 fps clip, this one is {fps:.2f}")
        out, rep = tm.patch_fps_metadata(original, divisor=div)
        if tm.media_payload_sha256(out) != tm.media_payload_sha256(original):
            sys.exit("[!] safety check failed: video data changed")
        print(f"       fps: header timing divided by {div} ({fps:.0f} reads as {fps / div:.0f})")
    else:
        sys.exit(f"[!] unknown method {method}")
    Path(dst).write_bytes(out)
    return dst


def main():
    patch = "--patch" in sys.argv
    sys.argv = [a for a in sys.argv if a != "--patch"]
    method = None
    if "--method" in sys.argv:
        i = sys.argv.index("--method")
        try:
            method = sys.argv[i + 1]
        except IndexError:
            sys.exit("[!] --method needs a name: silent, mvhd, inflate, fps or all")
        del sys.argv[i:i + 2]
        if method not in METHODS + ("all",):
            sys.exit(f"[!] unknown method {method}: use silent, mvhd, inflate, fps or all")
    if patch and not method:
        method = "mvhd"
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"[!] {tool} not found. Windows: winget install ffmpeg (then reopen PowerShell)")
    src = Path(sys.argv[1])
    if not src.is_file():
        sys.exit(f"[!] file not found: {src}")
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_name(src.stem + "_tiktok.mp4")
    if dst.resolve() == src.resolve():
        sys.exit("[!] output must be a different file")

    a = probe(src)
    print("input :", describe(a))
    codec = a["codec_name"]
    if a["fps"] < 59:
        print(f"[warn] input is {a['fps']:.2f} fps, not 60: export 60 fps from your editor first")

    if method:
        names = METHODS if method == "all" else (method,)
        outputs = []
        for name in names:
            out = dst if len(names) == 1 else dst.with_name(f"{dst.stem}_{name}{dst.suffix}")
            print(f"--method {name}: lossless copy + container patch")
            try:
                build_method(name, src, out, a)
            except SystemExit as e:
                if len(names) == 1:
                    raise
                print(f"[skip] {name}: {e}")
                continue
            b = probe(out)
            print("output:", describe(b))
            bad = [k for k in ["codec_name", "width", "height", "pix_fmt", "color_transfer"]
                   if a.get(k) != b.get(k)]
            if bad:
                sys.exit(f"[!] output differs from input in: {', '.join(bad)}. Don't upload it.")
            outputs.append(out)
        if not outputs:
            sys.exit("[!] no method could be applied to this file")
        print("[ok] picture data untouched, same codec, size and HDR")
        print("Upload in TikTok Studio in a desktop browser with 'Allow high-quality uploads' on.")
        print("Post as 'Only me' first and check each version; TikTok changes this often.")
        print("Your PC player may show a wrong length or speed for these files: that's expected.")
        for o in outputs:
            print(f"\n  {o}")
        return
    if patch:
        if codec not in ("hevc", "h264"):
            sys.exit(f"[!] codec {codec} not handled: export H.264 or HEVC")
        print("--patch: lossless remux + mvhd duration patch (tiktok-lossless-upload method)")
        remux(src, dst, codec, faststart=False)
        mvhd_patch(dst)
        b = probe(dst)
        print("output:", describe(b))
        bad = [k for k in ["codec_name", "width", "height", "pix_fmt", "color_transfer", "frames"]
               if a.get(k) != b.get(k)]
        if bad:
            sys.exit(f"[!] output differs from input in: {', '.join(bad)}. Don't upload it.")
        print("[ok] same frames, fps and HDR; duration header set to maximum")
        print("Upload it in TikTok Studio in a desktop browser (not the phone app).")
        print("Your PC player may show a wrong length for this file: that's expected.")
        print(f"\n  {dst}")
        return
    if codec == "h264" and shutil.which("tiktok-quality"):
        print("H.264: running tiktok-quality")
        run(["tiktok-quality", str(src), str(dst)])
        b = probe(dst)
        print("output:", describe(b))
        print("(tiktok-quality declares extra frames on purpose, so the frame count differs)")
    elif codec in ("hevc", "h264"):
        if codec == "h264":
            print("tiktok-quality not installed (pip install tiktok-quality): lossless remux only")
        else:
            print("HEVC: lossless remux (tiktok-quality only works on H.264)")
        remux(src, dst, codec)
        b = probe(dst)
        print("output:", describe(b))
        same = ["codec_name", "width", "height", "pix_fmt", "color_transfer",
                "color_primaries", "color_space", "frames"]
        bad = [k for k in same if a.get(k) != b.get(k)]
        if abs(a["fps"] - b["fps"]) > 0.01:
            bad.append("fps")
        if bad:
            sys.exit(f"[!] output differs from input in: {', '.join(bad)}. Don't upload it.")
        print("[ok] same picture, fps, HDR and frame count as the original")
    else:
        sys.exit(f"[!] codec {codec} not handled: export H.264 or HEVC from your editor")

    print(f"\nUpload this file at tiktok.com/upload (PC), 'Allow high-quality uploads' on:\n  {dst}")


if __name__ == "__main__":
    main()
