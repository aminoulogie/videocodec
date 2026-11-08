"""Writes the Python results for every fixture so CI can compare them with Swift.

python3 tests/parity.py OUTDIR  ->  OUTDIR/<fixture>.<method>.mp4
"""
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "pc"))
import tiktok_methods as tm  # noqa: E402

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
for f in sorted((root / "tests" / "fixtures").glob("*.mp4")):
    tm.silent_layout(str(f), str(out / f"{f.stem}.silent.mp4"))
    data = f.read_bytes()
    (out / f"{f.stem}.inflate.mp4").write_bytes(tm.inflate_video_samples(data, multiplier=5)[0])
    if "60" in f.stem:
        (out / f"{f.stem}.fps.mp4").write_bytes(tm.patch_fps_metadata(data, divisor=2)[0])
    print("python:", f.name)
