"""MP4 structure patches for TikTok uploads (inflate + fps methods).

Derived from KizaruZero/tiktok-fidelity (MIT, see TIKTOK_FIDELITY_LICENSE.txt).
Change made here: inflate_video_samples pointed its filler samples at the wrong
byte offset when the file has its index (moov) after the video data. The
filler samples then read the index bytes instead of zeros (ffmpeg: "Invalid
NAL unit size"). The offset is now computed after the index size is known.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct
from typing import Iterator, Optional


class MP4Error(ValueError):
    """Raised when an ISO-BMFF/MP4 structure cannot be safely parsed."""


@dataclass(frozen=True)
class Box:
    start: int
    size: int
    type: str
    header_size: int

    @property
    def end(self) -> int:
        return self.start + self.size

    @property
    def payload_start(self) -> int:
        return self.start + self.header_size

    @property
    def payload_end(self) -> int:
        return self.end


def _u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def _u64(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from(">Q", data, offset)[0]


def _p32(value: int) -> bytes:
    return struct.pack(">I", value)


def _p64(value: int) -> bytes:
    return struct.pack(">Q", value)


def iter_boxes(data: bytes | bytearray, start: int, end: int) -> Iterator[Box]:
    """Iterate well-formed ISO-BMFF boxes inside [start, end)."""
    pos = start
    while pos < end:
        if pos + 8 > end:
            raise MP4Error(f"Truncated box header at offset {pos}")
        size32 = _u32(data, pos)
        typ = bytes(data[pos + 4 : pos + 8]).decode("latin-1")
        header = 8
        if size32 == 1:
            if pos + 16 > end:
                raise MP4Error(f"Truncated extended-size box at offset {pos}")
            size = _u64(data, pos + 8)
            header = 16
        elif size32 == 0:
            size = end - pos
        else:
            size = size32
        if size < header or pos + size > end:
            raise MP4Error(
                f"Invalid box {typ!r} at {pos}: size={size}, remaining={end - pos}"
            )
        yield Box(pos, size, typ, header)
        pos += size


def top_level_boxes(data: bytes | bytearray) -> list[Box]:
    return list(iter_boxes(data, 0, len(data)))


def find_child(data: bytes | bytearray, parent: Box, typ: str) -> Optional[Box]:
    for box in iter_boxes(data, parent.payload_start, parent.payload_end):
        if box.type == typ:
            return box
    return None


def find_children(data: bytes | bytearray, parent: Box, typ: str) -> list[Box]:
    return [
        box
        for box in iter_boxes(data, parent.payload_start, parent.payload_end)
        if box.type == typ
    ]


def find_top(data: bytes | bytearray, typ: str) -> Optional[Box]:
    for box in iter_boxes(data, 0, len(data)):
        if box.type == typ:
            return box
    return None


def box_path(data: bytes | bytearray, parent: Box, path: list[str]) -> Optional[Box]:
    current = parent
    for typ in path:
        current = find_child(data, current, typ)
        if current is None:
            return None
    return current


def _full_box_version(data: bytes | bytearray, box: Box) -> int:
    if box.payload_start + 4 > box.end:
        raise MP4Error(f"Box {box.type} is too small to be a FullBox")
    return data[box.payload_start]


def _header_offsets(box: Box, version: int) -> tuple[int, int, int]:
    """Return (timescale_offset, duration_offset, duration_width)."""
    p = box.payload_start
    if version == 0:
        # version/flags, creation_time, modification_time, timescale, duration
        return p + 12, p + 16, 4
    if version == 1:
        # version/flags, creation_time(8), modification_time(8), timescale, duration(8)
        return p + 20, p + 24, 8
    raise MP4Error(f"Unsupported {box.type} version {version}")


def read_header_timing(data: bytes | bytearray, box: Box) -> tuple[int, int, int]:
    """Return (version, timescale, duration) for mvhd/mdhd."""
    version = _full_box_version(data, box)
    ts_off, dur_off, width = _header_offsets(box, version)
    timescale = _u32(data, ts_off)
    duration = _u32(data, dur_off) if width == 4 else _u64(data, dur_off)
    return version, timescale, duration


def patch_timing_box(data: bytearray, box: Box, divisor: int) -> tuple[int, int, int, int]:
    """Divide timescale and duration by divisor, preserving box size and all media bytes."""
    if divisor <= 0:
        raise ValueError("divisor must be positive")
    version = _full_box_version(data, box)
    ts_off, dur_off, width = _header_offsets(box, version)
    old_ts = _u32(data, ts_off)
    old_dur = _u32(data, dur_off) if width == 4 else _u64(data, dur_off)
    new_ts = max(1, old_ts // divisor)
    new_dur = old_dur // divisor
    data[ts_off : ts_off + 4] = _p32(new_ts)
    data[dur_off : dur_off + width] = _p32(new_dur) if width == 4 else _p64(new_dur)
    return old_ts, new_ts, old_dur, new_dur


def track_handler(data: bytes | bytearray, trak: Box) -> Optional[str]:
    mdia = find_child(data, trak, "mdia")
    if not mdia:
        return None
    hdlr = find_child(data, mdia, "hdlr")
    if not hdlr:
        return None
    p = hdlr.payload_start
    if p + 12 > hdlr.end:
        return None
    # FullBox header (4) + pre_defined (4) + handler_type (4)
    raw = bytes(data[p + 8 : p + 12])
    return raw.decode("latin-1")


def media_payload_sha256(data: bytes | bytearray) -> str:
    """Hash every top-level mdat payload in order.

    This deliberately ignores moov/metadata and hashes encoded audio/video
    payload bytes. A metadata-only transformation must leave this unchanged.
    """
    h = hashlib.sha256()
    found = False
    for box in iter_boxes(data, 0, len(data)):
        if box.type == "mdat":
            found = True
            h.update(data[box.payload_start : box.payload_end])
    if not found:
        raise MP4Error("No top-level mdat box found")
    return h.hexdigest()


def patch_fps_metadata(
    input_bytes: bytes,
    *,
    divisor: int,
    patch_audio: bool = True,
) -> tuple[bytes, dict]:
    """Apply the community 60/120-FPS metadata technique without re-encoding.

    The transformation is intentionally conservative: only timing fields in
    mvhd/mdhd boxes are changed. The encoded mdat payload is byte-for-byte
    preserved. This is an empirical TikTok-specific technique, not an official
    TikTok API guarantee.
    """
    data = bytearray(input_bytes)
    moov = find_top(data, "moov")
    if moov is None:
        raise MP4Error("No moov box found")

    mvhd = find_child(data, moov, "mvhd")
    if mvhd is None:
        raise MP4Error("No mvhd box found")

    changed = []
    old_ts, new_ts, old_dur, new_dur = patch_timing_box(data, mvhd, divisor)
    changed.append({
        "box": "mvhd",
        "old_timescale": old_ts,
        "new_timescale": new_ts,
        "old_duration": old_dur,
        "new_duration": new_dur,
    })

    traks = find_children(data, moov, "trak")
    video_count = 0
    mdhd_count = 0
    for trak in traks:
        handler = track_handler(data, trak)
        if handler == "vide":
            video_count += 1
        if not patch_audio and handler != "vide":
            continue
        mdia = find_child(data, trak, "mdia")
        mdhd = find_child(data, mdia, "mdhd") if mdia else None
        if mdhd is None:
            continue
        mdhd_count += 1
        o_ts, n_ts, o_dur, n_dur = patch_timing_box(data, mdhd, divisor)
        changed.append({
            "box": "mdhd",
            "handler": handler or "unknown",
            "old_timescale": o_ts,
            "new_timescale": n_ts,
            "old_duration": o_dur,
            "new_duration": n_dur,
        })

    if video_count == 0:
        raise MP4Error("No video track found")
    if mdhd_count == 0:
        raise MP4Error("No mdhd box found for selected tracks")

    return bytes(data), {
        "divisor": divisor,
        "patched_boxes": changed,
        "video_tracks": video_count,
        "patched_mdhd": mdhd_count,
    }


# ISO-BMFF sample-table inflation used by several public TikTok upload tools.
DUMMY_SIZES = {
    "avc1": 8,
    "avc3": 8,
    "hvc1": 16,
    "hev1": 16,
    "dvh1": 16,
    "dvhe": 16,
    "dvav": 8,
    "dva1": 8,
    "vp09": 4,
    "av01": 4,
    "mp4v": 8,
}


def _find_video_stbl(data: bytes | bytearray, moov: Box) -> tuple[Box, Box, Box, Box]:
    for trak in find_children(data, moov, "trak"):
        mdia = find_child(data, trak, "mdia")
        if not mdia:
            continue
        if track_handler(data, trak) != "vide":
            continue
        minf = find_child(data, mdia, "minf")
        if not minf:
            continue
        stbl = find_child(data, minf, "stbl")
        if stbl:
            return trak, mdia, minf, stbl
    raise MP4Error("No video stbl found")


def _sample_entry_codec(data: bytes | bytearray, stbl: Box) -> str:
    stsd = find_child(data, stbl, "stsd")
    if not stsd or stsd.payload_start + 20 > stsd.end:
        return "unknown"
    # FullBox header (4) + entry_count (4) + sample-entry size (4) + format (4)
    p = stsd.payload_start + 12
    return bytes(data[p : p + 4]).decode("latin-1")


def _parse_stts(data: bytes | bytearray, box: Box) -> tuple[list[tuple[int, int]], int]:
    p = box.payload_start
    if p + 8 > box.end:
        raise MP4Error("Invalid stts box")
    count = _u32(data, p + 4)
    entries: list[tuple[int, int]] = []
    total_samples = 0
    total_duration = 0
    off = p + 8
    for _ in range(count):
        if off + 8 > box.end:
            raise MP4Error("Truncated stts entry")
        n = _u32(data, off)
        delta = _u32(data, off + 4)
        entries.append((n, delta))
        total_samples += n
        total_duration += n * delta
        off += 8
    if total_samples == 0:
        raise MP4Error("stts contains no samples")
    sample_delta = max(1, round(total_duration / total_samples))
    return entries, sample_delta


def _parse_sample_sizes(data: bytes | bytearray, stsz: Box) -> list[int]:
    p = stsz.payload_start
    if p + 12 > stsz.end:
        raise MP4Error("Invalid stsz box")
    sample_size = _u32(data, p + 4)
    count = _u32(data, p + 8)
    if sample_size:
        return [sample_size] * count
    off = p + 12
    out = []
    for _ in range(count):
        if off + 4 > stsz.end:
            raise MP4Error("Truncated stsz entry")
        out.append(_u32(data, off))
        off += 4
    return out


def _parse_chunk_offsets(data: bytes | bytearray, box: Box) -> list[int]:
    p = box.payload_start
    if p + 8 > box.end:
        raise MP4Error("Invalid chunk offset box")
    count = _u32(data, p + 4)
    off = p + 8
    step = 8 if box.type == "co64" else 4
    out: list[int] = []
    for _ in range(count):
        if off + step > box.end:
            raise MP4Error("Truncated chunk offset entry")
        out.append(_u64(data, off) if step == 8 else _u32(data, off))
        off += step
    return out


def _parse_stsc(data: bytes | bytearray, box: Box) -> list[tuple[int, int, int]]:
    p = box.payload_start
    if p + 8 > box.end:
        raise MP4Error("Invalid stsc box")
    count = _u32(data, p + 4)
    out = []
    off = p + 8
    for _ in range(count):
        if off + 12 > box.end:
            raise MP4Error("Truncated stsc entry")
        out.append((_u32(data, off), _u32(data, off + 4), _u32(data, off + 8)))
        off += 12
    return out


def _make_full_box(typ: str, payload: bytes) -> bytes:
    size = 8 + len(payload)
    if size >= (1 << 32):
        raise MP4Error(f"Generated {typ} box is too large")
    return _p32(size) + typ.encode("latin-1") + payload


def _build_stts(entries: list[tuple[int, int]], delta: int, fake: int) -> bytes:
    # Keep every original timing entry (variable frame rate stays correct),
    # then describe the filler samples with one extra entry.
    payload = b"\x00\x00\x00\x00" + _p32(len(entries) + 1)
    for n, d in entries:
        payload += _p32(n) + _p32(d)
    payload += _p32(fake) + _p32(delta)
    return _make_full_box("stts", payload)


def _build_stsz(real_sizes: list[int], dummy_size: int, multiplier: int) -> bytes:
    total = len(real_sizes) * multiplier
    body = bytearray(b"\x00" * (4 + 4 + 4))
    body[0:4] = _p32(0)
    body[4:8] = _p32(0)
    body[8:12] = _p32(total)
    payload = bytes(body) + b"".join(_p32(x) for x in real_sizes) + _p32(dummy_size) * (total - len(real_sizes))
    return _make_full_box("stsz", payload)


def _build_stsc(entries: list[tuple[int, int, int]], first_fake_chunk: int) -> bytes:
    payload = bytearray(b"\x00\x00\x00\x00" + _p32(len(entries) + 1))
    for first_chunk, samples_per_chunk, sample_desc in entries:
        payload += _p32(first_chunk) + _p32(samples_per_chunk) + _p32(sample_desc)
    payload += _p32(first_fake_chunk) + _p32(1) + _p32(1)
    return _make_full_box("stsc", bytes(payload))


def _build_chunk_offsets(typ: str, offsets: list[int]) -> bytes:
    payload = bytearray(b"\x00\x00\x00\x00" + _p32(len(offsets)))
    if typ == "co64":
        for off in offsets:
            payload += _p64(off)
    else:
        for off in offsets:
            if off >= (1 << 32):
                raise MP4Error("stco overflow; use co64 input/output for very large files")
            payload += _p32(off)
    return _make_full_box(typ, bytes(payload))


def _replace_boxes(data: bytes, replacements: list[tuple[Box, bytes]]) -> bytes:
    out = bytearray()
    pos = 0
    for box, new_bytes in sorted(replacements, key=lambda x: x[0].start):
        if box.start < pos:
            raise MP4Error("Overlapping replacement boxes")
        out += data[pos:box.start]
        out += new_bytes
        pos = box.end
    out += data[pos:]
    return bytes(out)


def _adjust_ancestor_sizes(buf: bytearray, boxes: list[Box], delta: int) -> None:
    for box in boxes:
        new_size = box.size + delta
        if box.header_size == 8:
            if new_size >= (1 << 32):
                raise MP4Error(f"Box {box.type} would overflow 32-bit size")
            buf[box.start : box.start + 4] = _p32(new_size)
        else:
            buf[box.start + 8 : box.start + 16] = _p64(new_size)


def _adjust_all_chunk_offsets(buf: bytearray, moov: Box, delta: int, skip_video_fake: bool = False) -> None:
    """Add delta to every stco/co64 entry in moov.

    The caller uses this only when moov precedes mdat, so the original media
    chunks move by delta. Fake video entries are created with pre-shifted
    coordinates so they should be included in the same delta pass.
    """
    if delta == 0:
        return

    container_types = {"moov", "trak", "mdia", "minf", "stbl"}

    def walk(box: Box):
        for child in iter_boxes(buf, box.payload_start, box.payload_end):
            if child.type in {"stco", "co64"}:
                p = child.payload_start
                count = _u32(buf, p + 4)
                step = 8 if child.type == "co64" else 4
                off = p + 8
                for _ in range(count):
                    if step == 8:
                        value = _u64(buf, off) + delta
                        buf[off : off + 8] = _p64(value)
                    else:
                        value = _u32(buf, off) + delta
                        if value >= (1 << 32):
                            raise MP4Error("stco overflow after moov relocation")
                        buf[off : off + 4] = _p32(value)
                    off += step
            elif child.type in container_types:
                walk(child)
    walk(moov)


def inflate_video_samples(
    input_bytes: bytes,
    *,
    multiplier: int = 5,
) -> tuple[bytes, dict]:
    """Experimental MP4 sample-table inflation, without video re-encoding.

    The original encoded samples are retained. Extra video samples with tiny
    zero-filled payloads are described in stts/stsz/stsc/stco (or co64) and a
    new mdat is appended. This follows the public structural technique used by
    NoBlur/tiktok-quality, but is implemented independently here.

    This is experimental: TikTok behavior can change, and some desktop/media
    players may dislike the intentionally unusual sample tables.
    """
    if multiplier < 2:
        raise ValueError("multiplier must be >= 2")
    data = bytes(input_bytes)
    top = top_level_boxes(data)
    moov = next((b for b in top if b.type == "moov"), None)
    if moov is None:
        raise MP4Error("No moov box found")
    trak, mdia, minf, stbl = _find_video_stbl(data, moov)

    stts = find_child(data, stbl, "stts")
    stsz = find_child(data, stbl, "stsz")
    stsc = find_child(data, stbl, "stsc")
    stco = find_child(data, stbl, "stco")
    co64 = find_child(data, stbl, "co64")
    if not all((stts, stsz, stsc)) or not (stco or co64):
        raise MP4Error("Video sample tables must include stts, stsz, stsc and stco/co64")

    stts_entries, sample_delta = _parse_stts(data, stts)
    real_count = sum(n for n, _ in stts_entries)
    real_sizes = _parse_sample_sizes(data, stsz)
    if len(real_sizes) != real_count:
        raise MP4Error(f"stsz sample count {len(real_sizes)} != stts sample count {real_count}")

    codec = _sample_entry_codec(data, stbl)
    dummy_size = DUMMY_SIZES.get(codec, 8)
    original_offsets = _parse_chunk_offsets(data, stco or co64)
    original_stsc = _parse_stsc(data, stsc)

    fake_count = real_count * (multiplier - 1)
    new_stts = _build_stts(stts_entries, sample_delta, fake_count)
    new_stsz = _build_stsz(real_sizes, dummy_size, multiplier)
    new_stsc = _build_stsc(original_stsc, len(original_offsets) + 1)

    chunk_type = "stco" if stco else "co64"
    first_mdat_pre = next((b for b in top if b.type == "mdat"), None)
    moov_before_mdat_pre = bool(first_mdat_pre and moov.start < first_mdat_pre.start)
    # Table sizes depend only on counts, so measure the moov growth first.
    probe_chunk = _build_chunk_offsets(chunk_type, original_offsets + [len(data) + 8] * fake_count)
    delta = (
        len(new_stts) - stts.size
        + len(new_stsz) - stsz.size
        + len(new_stsc) - stsc.size
        + len(probe_chunk) - (stco or co64).size
    )
    if delta == 0:
        raise MP4Error("Unexpected zero moov delta")
    # The filler mdat is appended after the (grown) file. If the index comes
    # first, the later global shift adds delta to every offset, so start from
    # the old end of file; if the index comes last, nothing shifts, so add
    # delta here.
    safe_offset_unshifted = len(data) + 8 + (0 if moov_before_mdat_pre else delta)
    fake_offsets = [safe_offset_unshifted] * fake_count
    new_chunk = _build_chunk_offsets(chunk_type, original_offsets + fake_offsets)
    if len(new_chunk) != len(probe_chunk):
        raise MP4Error("Chunk table size changed unexpectedly (co64 promotion not supported)")

    replacements = [
        (stts, new_stts),
        (stsz, new_stsz),
        (stsc, new_stsc),
        (stco or co64, new_chunk),
    ]
    rebuilt = bytearray(_replace_boxes(data, replacements))
    _adjust_ancestor_sizes(rebuilt, [stbl, minf, mdia, trak, moov], delta)

    # If moov sits before the original media data, all original sample offsets
    # move by the expanded moov. The fake offsets are also shifted here.
    first_mdat = next((b for b in top if b.type == "mdat"), None)
    moov_before_mdat = bool(first_mdat and moov.start < first_mdat.start)
    if moov_before_mdat:
        moov_new = Box(moov.start, moov.size + delta, moov.type, moov.header_size)
        _adjust_all_chunk_offsets(rebuilt, moov_new, delta)

    # Each filler sample is a well-formed length-prefixed NAL (same shape as the
    # 8-byte "00 00 00 04 00 00 00 00" padding of the reference tools), so
    # decoders skip it instead of choking on a zero-length NAL.
    one = (dummy_size - 4).to_bytes(4, "big") + bytes(dummy_size - 4)
    padding = one * fake_count
    new_mdat_offset = len(rebuilt)
    mdat_size = 8 + len(padding)
    if mdat_size >= (1 << 32):
        # Keep this implementation on the normal 32-bit MP4 box path.
        raise MP4Error("Experimental trailing mdat would exceed 32-bit box size")
    rebuilt += _p32(mdat_size) + b"mdat" + padding

    # The returned fake sample offset should point exactly to the appended mdat payload.
    # Recompute the first fake offset for the report; the actual table already points
    # there after the global relocation pass when needed.
    actual_safe_offset = new_mdat_offset + 8
    return bytes(rebuilt), {
        "multiplier": multiplier,
        "codec": codec,
        "dummy_size": dummy_size,
        "real_frames": real_count,
        "fake_frames": fake_count,
        "moov_delta": delta,
        "fake_mdat_payload_offset": actual_safe_offset,
        "fake_mdat_bytes": len(padding),
        "moov_before_mdat": moov_before_mdat,
    }


# ---------------------------------------------------------------------------
# "Silent" layout (independent implementation of the technique described by
# AscendedTweaks/silent-method, Nov 2026). Container only, nothing re-encoded:
#   - ftyp, moov, then one mdat (index first, "faststart")
#   - samples of all tracks interleaved by time; runs of video frames share a chunk
#   - filler 8-byte video samples in stsz/stco only (not in stts, so players
#     ignore them), up to duration x 400 samples
#   - last video frame lasts 1 tick in stts
#   - btrt: max bitrate = average bitrate; pasp 1:1 when missing
#   - creation/modification times zeroed; udta and meta removed
# ---------------------------------------------------------------------------

SILENT_FAKE_PER_SEC = 400
SILENT_FILLER = b"\x00\x00\x00\x04\x00\x00\x00\x00"


def _children_list(data, start, end):
    return list(iter_boxes(data, start, end))


def _box(typ, payload):
    return _p32(8 + len(payload)) + typ.encode("latin-1") + payload


def _rle(values):
    out = []
    for v in values:
        if out and out[-1][1] == v:
            out[-1][0] += 1
        else:
            out.append([1, v])
    return out


def _silent_track(data, trak):
    mdia = find_child(data, trak, "mdia")
    minf = find_child(data, mdia, "minf") if mdia else None
    stbl = find_child(data, minf, "stbl") if minf else None
    if stbl is None:
        raise MP4Error("track without sample table")
    hdlr = find_child(data, mdia, "hdlr")
    handler = bytes(data[hdlr.payload_start + 8:hdlr.payload_start + 12]).decode("latin-1") if hdlr else "????"
    mdhd = find_child(data, mdia, "mdhd")
    _, timescale, duration = read_header_timing(data, mdhd)
    kids = {b.type: b for b in iter_boxes(data, stbl.payload_start, stbl.payload_end)}
    for need in ("stts", "stsz", "stsc", "stsd"):
        if need not in kids:
            raise MP4Error(f"track without {need}")
    if "stco" not in kids and "co64" not in kids:
        raise MP4Error("track without chunk offsets")
    entries, _ = _parse_stts(data, kids["stts"]) if _u32(data, kids["stts"].payload_start + 4) else ([], 0)
    deltas = []
    for n, d in entries:
        deltas.extend([d] * n)
    sizes = _parse_sample_sizes(data, kids["stsz"])[:len(deltas)]  # only timed samples (re-patch safe)
    chunks = _parse_chunk_offsets(data, kids.get("stco") or kids.get("co64"))
    stsc = _parse_stsc(data, kids["stsc"])
    if _u32(data, kids["stsd"].payload_start + 4) != 1 or any(e[2] != 1 for e in stsc):
        raise MP4Error("multiple sample descriptions are not supported")
    offs = []
    ei = 0
    for ci, base in enumerate(chunks):
        while ei + 1 < len(stsc) and stsc[ei + 1][0] <= ci + 1:
            ei += 1
        o = base
        for _ in range(stsc[ei][1] if stsc else 0):
            if len(offs) >= len(sizes):
                break
            offs.append(o)
            o += sizes[len(offs) - 1]
    if len(offs) != len(sizes):
        raise MP4Error("sample table is inconsistent")
    shift = 0
    edts = find_child(data, trak, "edts")
    elst = find_child(data, edts, "elst") if edts else None
    if elst:
        p = elst.payload_start
        ver = data[p]
        for k in range(_u32(data, p + 4)):
            if ver == 0:
                t = struct.unpack(">i", bytes(data[p + 12 + 8 * k:p + 16 + 8 * k]))[0]
            else:
                t = struct.unpack(">q", bytes(data[p + 16 + 16 * k:p + 24 + 16 * k]))[0]
            if t != -1:
                shift = t
                break
    dts, t = [], 0
    for d in deltas:
        dts.append(t)
        t += d
    return {"trak": trak, "stbl": stbl, "handler": handler, "timescale": timescale or 1,
            "duration": duration, "deltas": deltas, "sizes": sizes, "offs": offs,
            "shift": shift, "dts": dts}


def _silent_stsd(data, stsd, tr):
    p = stsd.payload_start
    esize = _u32(data, p + 8)
    etype = bytes(data[p + 12:p + 16]).decode("latin-1")
    entry_start, entry_end = p + 16, p + 8 + esize
    kids = list(iter_boxes(data, entry_start + 78, entry_end))  # 78 bytes of VisualSampleEntry fields
    old = {b.type: b for b in kids}
    if "btrt" in old:
        avg = _u32(data, old["btrt"].payload_start + 8)
    else:
        avg = (sum(tr["sizes"]) * 8 * tr["timescale"]) // tr["duration"] if tr["duration"] else 0
    body = bytes(data[entry_start:entry_start + 78])
    for b in kids:
        if b.type in ("pasp", "btrt"):
            continue
        body += bytes(data[b.start:b.end])
    pasp = bytes(data[old["pasp"].payload_start:old["pasp"].payload_end]) if "pasp" in old else _p32(1) + _p32(1)
    body += _box("pasp", pasp) + _box("btrt", _p32(0) + _p32(avg) + _p32(avg))
    head = bytes(data[p:p + 8])  # version/flags + entry_count
    return _box("stsd", head + _box(etype, body))


def _zero_times(data, box):
    b = bytearray(data[box.start:box.end])
    body = box.payload_start - box.start
    n = 8 if b[body] == 0 else 16
    b[body + 4:body + 4 + n] = b"\x00" * n
    return bytes(b)


def silent_layout(src_path, dst_path, max_seconds=300):
    """Rewrite src into dst with the Silent layout. Returns a report dict."""
    import os
    size = os.path.getsize(src_path)
    with open(src_path, "rb") as f:
        tops = []
        pos = 0
        while pos + 8 <= size:
            f.seek(pos)
            head = f.read(16)
            sz, typ = struct.unpack(">I4s", head[:8])
            typ = typ.decode("latin-1")
            if sz == 1:
                sz = struct.unpack(">Q", head[8:16])[0]
            elif sz == 0:
                sz = size - pos
            if sz < 8:
                raise MP4Error("damaged MP4 structure")
            if typ == "moof":
                raise MP4Error("fragmented MP4 is not supported")
            tops.append((typ, pos, sz))
            pos += sz
        ftyp = next((t for t in tops if t[0] == "ftyp"), None)
        moovt = next((t for t in tops if t[0] == "moov"), None)
        if not ftyp or not moovt:
            raise MP4Error("not a valid MP4 (ftyp/moov missing)")
        f.seek(ftyp[1]); ftyp_bytes = f.read(ftyp[2])
        f.seek(moovt[1]); moov = f.read(moovt[2])

        mbox = Box(0, len(moov), "moov", 8)
        traks = [b for b in iter_boxes(moov, 8, len(moov)) if b.type == "trak"]
        tracks = [_silent_track(moov, t) for t in traks]
        vi = next((i for i, t in enumerate(tracks) if t["handler"] == "vide"), -1)
        if vi < 0:
            raise MP4Error("no video track")
        v = tracks[vi]
        if v["duration"] / v["timescale"] > max_seconds:
            raise MP4Error(f"video longer than {max_seconds // 60} minutes")

        # interleave by time (video first on ties); runs of video frames share a chunk
        from fractions import Fraction
        ev = []
        for i, tr in enumerate(tracks):
            for s, d in enumerate(tr["dts"]):
                ev.append((Fraction(d - tr["shift"], tr["timescale"]), 0 if i == vi else 1, i, s))
        ev.sort()
        chunks = []
        for _, _, i, s in ev:
            if chunks and chunks[-1][0] == i and i == vi:
                chunks[-1][1].append(s)
            else:
                chunks.append([i, [s]])
        layout = [[] for _ in tracks]
        rel = 0
        for i, ss in chunks:
            layout[i].append([rel, len(ss)])
            for s in ss:
                rel += tracks[i]["sizes"][s]
        import math
        n_fake = max(0, math.floor(v["duration"] * SILENT_FAKE_PER_SEC / v["timescale"] + 0.5) - len(v["sizes"]))
        for _ in range(n_fake):
            layout[vi].append([rel, 1])

        def stbl_bytes(i, base):
            tr = tracks[i]
            is_v = i == vi
            sizes = tr["sizes"] + ([len(SILENT_FILLER)] * n_fake if is_v else [])
            first_fake = len(layout[i]) - n_fake + 1 if is_v else -1
            stsc = []
            for k, (_, n) in enumerate(layout[i]):
                if not stsc or stsc[-1][1] != n or k + 1 == first_fake:
                    stsc.append((k + 1, n, 1))
            out = b""
            for b in iter_boxes(moov, tr["stbl"].payload_start, tr["stbl"].payload_end):
                if b.type == "stts" and is_v:
                    r = _rle(tr["deltas"][:-1] + [1])
                    out += _box("stts", _p32(0) + _p32(len(r)) + b"".join(_p32(n) + _p32(d) for n, d in r))
                elif b.type == "stsd" and is_v:
                    out += _silent_stsd(moov, b, tr)
                elif b.type == "stsz":
                    out += _box("stsz", _p32(0) + _p32(0) + _p32(len(sizes)) + b"".join(_p32(x) for x in sizes))
                elif b.type == "stsc":
                    out += _box("stsc", _p32(0) + _p32(len(stsc)) + b"".join(_p32(a) + _p32(n) + _p32(c) for a, n, c in stsc))
                elif b.type in ("stco", "co64"):
                    offs = [base + o for o, _ in layout[i]]
                    out += _box("stco", _p32(0) + _p32(len(offs)) + b"".join(_p32(o) for o in offs))
                else:
                    out += bytes(moov[b.start:b.end])
            return out

        def rebuild(parent, base, track_idx=None):
            out = b""
            for b in iter_boxes(moov, parent.payload_start, parent.payload_end):
                if b.type in ("udta", "meta"):
                    continue
                if b.type in ("mvhd", "tkhd", "mdhd"):
                    out += _zero_times(moov, b)
                elif b.type == "trak":
                    idx = traks.index(next(t for t in traks if t.start == b.start))
                    out += _box("trak", rebuild(b, base, idx))
                elif b.type in ("mdia", "minf"):
                    out += _box(b.type, rebuild(b, base, track_idx))
                elif b.type == "stbl":
                    out += _box("stbl", stbl_bytes(track_idx, base))
                else:
                    out += bytes(moov[b.start:b.end])
            return out

        head = ftyp_bytes + _box("free", b"")
        probe = _box("moov", rebuild(mbox, 0))
        base = len(head) + len(probe) + 8
        mdat_size = 8 + rel + len(SILENT_FILLER)
        if base + mdat_size >= 1 << 32:
            raise MP4Error("output over 4 GB is not supported")
        new_moov = _box("moov", rebuild(mbox, base))
        if len(new_moov) != len(probe):
            raise MP4Error("index size changed unexpectedly")

        with open(dst_path, "wb") as out:
            out.write(head + new_moov + _p32(mdat_size) + b"mdat")
            run = None
            for i, ss in chunks:
                for s in ss:
                    o, n = tracks[i]["offs"][s], tracks[i]["sizes"][s]
                    if run and run[0] + run[1] == o:
                        run[1] += n
                    else:
                        if run:
                            f.seek(run[0]); out.write(f.read(run[1]))
                        run = [o, n]
            if run:
                f.seek(run[0]); out.write(f.read(run[1]))
            out.write(SILENT_FILLER)
    return {"frames": len(v["sizes"]), "fakes": n_fake, "tracks": len(tracks)}
