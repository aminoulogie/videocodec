#!/usr/bin/env python3
"""TikTok HD uploader: a small web app on your PC.

  python tiktok_app.py

Then open http://localhost:8765 on the PC, or the Wi-Fi address it prints
on your phone (same Wi-Fi). Drop a video in: it is patched exactly like
`python tiktok_prep.py --patch` (no re-encode, keeps 4K / 60 fps / HDR /
Dolby Vision), then download it and upload it in TikTok Studio.

Needs only Python and ffmpeg (winget install ffmpeg). Files are kept in
the "tiktok_out" folder next to this script. Only devices on your own
network can use it.
"""
import ipaddress
import json
import re
import shutil
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8765
MAX_BYTES = 8 * 1024 ** 3          # 8 GB
OUT = Path(__file__).resolve().parent / "tiktok_out"
HDR = {"smpte2084": "HDR10", "arib-std-b67": "HLG"}
LOCK = threading.Lock()            # one patch at a time (it reads the whole file)


class Fail(Exception):
    pass


# ---------- the patch (same as tiktok_prep.py --patch) ----------

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise Fail(r.stderr.strip()[-800:] or "ffmpeg failed")
    return r.stdout


def probe(path):
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
               "-show_entries",
               "stream=codec_name,width,height,avg_frame_rate,pix_fmt,color_transfer,"
               "nb_read_packets:stream_side_data=side_data_type",
               "-show_entries", "format=size,bit_rate", "-of", "json", str(path)])
    data = json.loads(out)
    if not data.get("streams"):
        raise Fail("no video track in this file")
    v = data["streams"][0]
    num, den = (v.get("avg_frame_rate") or "0/1").split("/")
    fmt = data.get("format", {})
    hdr = HDR.get(v.get("color_transfer"), "SDR")
    if any("DOVI" in s.get("side_data_type", "") for s in v.get("side_data_list", [])):
        hdr += " + Dolby Vision"
    return {
        "codec": v.get("codec_name"),
        "width": v.get("width"), "height": v.get("height"),
        "fps": round(float(num) / float(den), 2) if float(den) else 0,
        "pix_fmt": v.get("pix_fmt"),
        "hdr": hdr,
        "frames": int(v.get("nb_read_packets") or 0),
        "mb": round(int(fmt.get("size", 0)) / 1e6, 1),
        "mbps": round(int(fmt.get("bit_rate", 0)) / 1e6, 1),
    }


def boxes(buf, start, end):
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack(">I4s", buf[pos:pos + 8])
        if size == 1:
            size = struct.unpack(">Q", buf[pos + 8:pos + 16])[0]
        elif size == 0:
            size = end - pos
        if size < 8 or pos + size > end:
            raise Fail("damaged MP4 structure")
        yield typ.decode("latin-1"), pos, size
        pos += size


def mvhd_patch(path):
    buf = bytearray(Path(path).read_bytes())
    top = {t: (o, n) for t, o, n in boxes(buf, 0, len(buf))}
    if "moov" not in top or "mdat" not in top:
        raise Fail("no moov/mdat box")
    mo, mn = top["moov"]
    if mo < top["mdat"][0]:
        raise Fail("moov must come after mdat")
    if struct.unpack(">I", buf[mo:mo + 4])[0] == 1:
        raise Fail("64-bit moov size not handled")
    for t, o, n in boxes(buf, mo + 8, mo + mn):
        if t != "mvhd":
            continue
        body = buf[o + 8:o + n]
        if body[0] == 0:
            ct, mt, ts, _ = struct.unpack(">IIII", body[4:20])
            new = bytes([1]) + body[1:4] + struct.pack(">QQIQ", ct, mt, ts, 0xFFFFFFFFFFFFFFFF) + body[20:]
        else:
            new = body[:24] + b"\xff" * 8 + body[32:]
        box = struct.pack(">I", 8 + len(new)) + b"mvhd" + new
        buf[o:o + n] = box
        struct.pack_into(">I", buf, mo, mn + len(box) - n)
        Path(path).write_bytes(buf)
        return
    raise Fail("no mvhd box")


def patch(src, dst):
    a = probe(src)
    if a["codec"] not in ("hevc", "h264"):
        raise Fail(f"codec {a['codec']} not handled: export H.264 or HEVC from your editor")
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-map", "0:v:0", "-map", "0:a?",
           "-c", "copy", "-map_metadata", "0", "-strict", "unofficial"]
    if a["codec"] == "hevc":
        cmd += ["-tag:v", "hvc1"]
    run(cmd + [str(dst)])
    mvhd_patch(dst)
    b = probe(dst)
    bad = [k for k in ("codec", "width", "height", "pix_fmt", "hdr", "frames") if a[k] != b[k]]
    if bad:
        dst.unlink(missing_ok=True)
        raise Fail("output differs from the original in: " + ", ".join(bad))
    return a, b


# ---------- web app ----------

def safe_name(name):
    stem = re.sub(r"[^\w\- ]+", "", Path(name).stem, flags=re.UNICODE).strip()[:60]
    return stem or "video"


def local_client(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.is_private or a.is_loopback or a.is_link_local


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))     # no packet is sent; picks the Wi-Fi address
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


class App(BaseHTTPRequestHandler):
    server_version = "TikTokHD/1"

    def log_message(self, fmt, *args):
        print(time.strftime("%H:%M:%S"), self.client_address[0], fmt % args)

    def send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self):
        if local_client(self.client_address[0]):
            return True
        self.send(403, {"error": "only devices on your own network"})
        return False

    def do_GET(self):
        if not self.allowed():
            return
        url = urllib.parse.urlparse(self.path)
        if url.path == "/":
            return self.send(200, PAGE, "text/html; charset=utf-8")
        if url.path.startswith("/files/"):
            name = urllib.parse.unquote(url.path[len("/files/"):])
            f = OUT / Path(name).name
            if not f.is_file() or f.parent != OUT:
                return self.send(404, {"error": "not found"})
            size = f.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", f'attachment; filename="{f.name}"')
            self.end_headers()
            with f.open("rb") as fh:
                shutil.copyfileobj(fh, self.wfile, 1024 * 1024)
            return
        self.send(404, {"error": "not found"})

    def do_PUT(self):
        if not self.allowed():
            return
        url = urllib.parse.urlparse(self.path)
        if url.path != "/patch":
            return self.send(404, {"error": "not found"})
        # same-origin only: stops other websites from posting here
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != self.headers.get("Host"):
            return self.send(403, {"error": "wrong origin"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BYTES:
            return self.send(400, {"error": "file missing or larger than 8 GB"})
        name = urllib.parse.parse_qs(url.query).get("name", ["video.mp4"])[0]
        stem = f"{safe_name(name)}-{time.strftime('%H%M%S')}"
        OUT.mkdir(exist_ok=True)
        src = OUT / (stem + "-original" + (Path(name).suffix.lower() or ".mp4"))
        dst = OUT / (stem + "_patched.mp4")
        left = length
        with src.open("wb") as fh:
            while left > 0:
                chunk = self.rfile.read(min(left, 1024 * 1024))
                if not chunk:
                    break
                fh.write(chunk)
                left -= len(chunk)
        if left:
            src.unlink(missing_ok=True)
            return self.send(400, {"error": "upload cut off, try again"})
        try:
            with LOCK:
                a, b = patch(src, dst)
        except Fail as e:
            return self.send(422, {"error": str(e)})
        except Exception as e:                  # never kill the server
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})
        finally:
            src.unlink(missing_ok=True)         # keep only the patched copy
        print(f"patched {dst.name}: {b['width']}x{b['height']} {b['fps']}fps {b['hdr']}")
        self.send(200, {"input": a, "output": b, "file": dst.name,
                        "url": "/files/" + urllib.parse.quote(dst.name)})


PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TikTok HD uploader</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;font:16px/1.45 system-ui,sans-serif;background:#0d0d0f;color:#f2f2f2}
 main{max-width:640px;margin:0 auto;padding:24px 18px 60px}
 h1{font-size:24px;margin:0 0 4px} .sub{color:#9a9aa2;margin:0 0 22px}
 .card{background:#18181c;border:1px solid #2a2a30;border-radius:16px;padding:18px;margin:0 0 16px}
 .step{color:#fe2c55;font-weight:700;font-size:13px;letter-spacing:.06em;text-transform:uppercase}
 #drop{border:2px dashed #3a3a44;border-radius:14px;padding:34px 12px;text-align:center;cursor:pointer}
 #drop.over{border-color:#25f4ee;background:#25f4ee10}
 .btn{display:block;width:100%;box-sizing:border-box;text-align:center;border:0;border-radius:12px;
      padding:14px;font-size:17px;font-weight:600;cursor:pointer;text-decoration:none;margin-top:12px}
 .red{background:#fe2c55;color:#fff} .cyan{background:#25f4ee;color:#000}
 .btn[aria-disabled=true]{opacity:.35;pointer-events:none}
 progress{width:100%;height:10px;margin-top:12px;accent-color:#25f4ee}
 table{width:100%;border-collapse:collapse;font-size:14px;margin-top:10px}
 td{padding:5px 4px;border-bottom:1px solid #2a2a30} td:first-child{color:#9a9aa2}
 .ok{color:#3ddc84} .err{color:#ff6b6b} .muted{color:#9a9aa2;font-size:14px}
 ol{padding-left:20px;margin:8px 0 0} li{margin:4px 0}
</style></head><body><main>
<h1>TikTok HD uploader</h1>
<p class="sub">Keeps 4K, 60 fps and HDR. Nothing is re-encoded.</p>

<div class="card">
 <div class="step">1 · Patch your video</div>
 <div id="drop"><b>Tap to choose a video</b><br><span class="muted">or drop it here (.mov / .mp4)</span></div>
 <input id="file" type="file" accept="video/*,.mov,.mp4" hidden>
 <progress id="bar" max="100" value="0" hidden></progress>
 <div id="status" class="muted" style="margin-top:10px"></div>
 <table id="info" hidden></table>
</div>

<div class="card">
 <div class="step">2 · Save the patched file</div>
 <a id="dl" class="btn cyan" aria-disabled="true">Download patched video</a>
 <p class="muted">Save it to your device. Don't edit or trim it afterwards.</p>
</div>

<div class="card">
 <div class="step">3 · Upload in TikTok Studio (desktop version)</div>
 <a class="btn red" href="https://www.tiktok.com/tiktokstudio/upload" target="_blank" rel="noopener">Open TikTok Studio upload</a>
 <p class="muted" id="howto"></p>
 <ol class="muted">
  <li>Pick the <b>_patched.mp4</b> file you saved.</li>
  <li>Don't trim or edit it in TikTok.</li>
  <li>First time: post as <b>Only me</b> to check the quality.</li>
 </ol>
</div>
</main>
<script>
const $=id=>document.getElementById(id);
const drop=$('drop'),file=$('file'),bar=$('bar'),status=$('status'),info=$('info'),dl=$('dl');
const phone=/Android|iPhone|iPad/i.test(navigator.userAgent);
$('howto').innerHTML = phone
 ? (/iPhone|iPad/i.test(navigator.userAgent)
    ? 'On iPhone (Safari): in the TikTok tab tap <b>aA</b> → <b>Request Desktop Website</b>, then reload.'
    : 'On Android (Chrome): in the TikTok tab tap <b>⋮</b> → tick <b>Desktop site</b>, then reload.')
 : 'On the PC it opens the desktop version already.';
drop.onclick=()=>file.click();
drop.ondragover=e=>{e.preventDefault();drop.classList.add('over')};
drop.ondragleave=()=>drop.classList.remove('over');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('over');if(e.dataTransfer.files[0])send(e.dataTransfer.files[0])};
file.onchange=()=>{if(file.files[0])send(file.files[0])};
const row=(k,a,b)=>`<tr><td>${k}</td><td>${a}</td><td>${b}</td></tr>`;
function send(f){
 dl.setAttribute('aria-disabled','true');info.hidden=true;bar.hidden=false;bar.value=0;
 status.className='muted';status.textContent='Sending '+f.name+' ('+(f.size/1e6).toFixed(0)+' MB)…';
 const x=new XMLHttpRequest();
 x.open('PUT','/patch?name='+encodeURIComponent(f.name));
 x.upload.onprogress=e=>{if(e.lengthComputable){bar.value=e.loaded/e.total*100;
   if(e.loaded===e.total)status.textContent='Patching… (a few seconds)'}};
 x.onload=()=>{bar.hidden=true;let r={};try{r=JSON.parse(x.responseText)}catch(e){}
  if(x.status!==200){status.className='err';status.textContent='✗ '+(r.error||('error '+x.status));return}
  const a=r.input,b=r.output;
  status.className='ok';status.textContent='✓ Patched. Same frames, fps and HDR as your original.';
  info.innerHTML='<tr><td></td><td><b>Original</b></td><td><b>Patched</b></td></tr>'+
   row('Size',a.width+'×'+a.height,b.width+'×'+b.height)+row('Frame rate',a.fps+' fps',b.fps+' fps')+
   row('HDR',a.hdr,b.hdr)+row('Frames',a.frames,b.frames)+row('Codec',a.codec,b.codec)+
   row('Quality',a.mbps+' Mbps',b.mbps+' Mbps')+row('File',a.mb+' MB',b.mb+' MB');
  info.hidden=false;dl.href=r.url;dl.download=r.file;dl.setAttribute('aria-disabled','false');
  dl.textContent='Download '+r.file;};
 x.onerror=()=>{bar.hidden=true;status.className='err';status.textContent='✗ Connection lost. Is the app still running on the PC?'};
 x.send(f);
}
</script></body></html>"""


def main():
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} not found. Run: winget install ffmpeg  (then reopen PowerShell)")
    OUT.mkdir(exist_ok=True)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), App)
    ip = lan_ip()
    print("TikTok HD uploader is running. Leave this window open.")
    print(f"  On this PC:   http://localhost:{PORT}")
    if ip:
        print(f"  On your phone (same Wi-Fi): http://{ip}:{PORT}")
    print(f"  Patched files go to: {OUT}")
    print("  Stop it with Ctrl+C.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("stopped")


if __name__ == "__main__":
    main()
