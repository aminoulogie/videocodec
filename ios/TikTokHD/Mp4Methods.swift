import Foundation

/// Container patches that make TikTok keep the original video. All of them copy
/// the picture and sound bit for bit and only touch the MP4 boxes around them.
/// TikTok changes how it handles uploads often, so there are several; if one
/// stops working, try another.
enum PatchMethod: String, CaseIterable, Identifiable {
    case silent, header, inflate, fps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent: return "Silent"
        case .header: return "Header"
        case .inflate: return "Inflate"
        case .fps: return "FPS"
        }
    }

    var blurb: String {
        switch self {
        case .silent:
            return "Recommended. Rebuilds the file layout the way the newest community method does (Nov 2026): index first, sound and picture interleaved, filler samples, metadata removed."
        case .header:
            return "Sets the movie length to the longest possible. The original trick."
        case .inflate:
            return "Not recommended: can come out in slow motion. Adds filler frames after the real ones, so the video track runs about 5 times longer than the clip and TikTok may stretch the real frames over it. Use Silent instead."
        case .fps:
            return "A 60 fps clip reads as 30 fps (120 as 30). It may look slowed down on this phone; TikTok keeps every frame."
        }
    }
}

/// The inflate and fps patches, ported from the PC tool (pc/tiktok_methods.py).
/// Only the moov box is held in memory; the video data is streamed through.
enum Mp4 {
    struct Box {
        let type: String
        let offset: Int
        let size: Int
        let header: Int
        var body: Int { offset + header }
        var end: Int { offset + size }
    }

    // MARK: bytes

    static func u32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(b[i + k]) }
        return v
    }

    static func put32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8((v >> 24) & 0xFF)
        b[i + 1] = UInt8((v >> 16) & 0xFF)
        b[i + 2] = UInt8((v >> 8) & 0xFF)
        b[i + 3] = UInt8(v & 0xFF)
    }

    static func put64(_ b: inout [UInt8], _ i: Int, _ v: UInt64) {
        for k in 0..<8 { b[i + k] = UInt8((v >> UInt64(56 - 8 * k)) & 0xFF) }
    }

    static func bytes32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func bytes64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) }
    }

    static func fourcc(_ b: [UInt8], _ i: Int) -> String {
        String(bytes: b[i ..< i + 4], encoding: .isoLatin1) ?? "????"
    }

    /// A box with a 32-bit size: size, type, then `payload`.
    static func makeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        bytes32(8 + payload.count) + Array(type.utf8) + payload
    }

    // MARK: boxes

    /// Boxes inside b[start..<end].
    static func children(_ b: [UInt8], _ start: Int, _ end: Int) throws -> [Box] {
        var out: [Box] = []
        var p = start
        while p + 8 <= end {
            var size = u32(b, p)
            var h = 8
            if size == 1 {
                guard p + 16 <= end else { throw PatchError.damaged("bad box size") }
                let big = u64(b, p + 8)
                guard big <= UInt64(Int.max) else { throw PatchError.damaged("bad box size") }
                size = Int(big)
                h = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= h, p + size <= end else { throw PatchError.damaged("bad box size") }
            out.append(Box(type: fourcc(b, p + 4), offset: p, size: size, header: h))
            p += size
        }
        return out
    }

    static func child(_ b: [UInt8], _ parent: Box, _ type: String) throws -> Box? {
        try children(b, parent.body, parent.end).first { $0.type == type }
    }

    /// Top-level boxes of a file, reading only their headers.
    static func topBoxes(_ fh: FileHandle) throws -> [Box] {
        let end = Int(try fh.seekToEnd())
        var out: [Box] = []
        var p = 0
        while p + 8 <= end {
            try fh.seek(toOffset: UInt64(p))
            let head = [UInt8](try fh.read(upToCount: 16) ?? Data())
            guard head.count >= 8 else { break }
            var size = u32(head, 0)
            var h = 8
            if size == 1 {
                guard head.count >= 16 else { throw PatchError.damaged("bad box size") }
                size = Int(u64(head, 8))
                h = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= h, p + size <= end else { throw PatchError.damaged("bad box size") }
            out.append(Box(type: fourcc(head, 4), offset: p, size: size, header: h))
            p += size
        }
        return out
    }

    struct Layout {
        let moovBox: Box
        let moov: [UInt8]
        let fileSize: Int
        let moovBeforeMdat: Bool
    }

    static func layout(_ fh: FileHandle) throws -> Layout {
        let tops = try topBoxes(fh)
        guard let moovBox = tops.first(where: { $0.type == "moov" }),
              let firstMdat = tops.first(where: { $0.type == "mdat" }) else {
            throw PatchError.damaged("no moov/mdat box")
        }
        guard moovBox.header == 8 else { throw PatchError.damaged("64-bit moov size") }
        try fh.seek(toOffset: UInt64(moovBox.offset))
        guard let data = try fh.read(upToCount: moovBox.size), data.count == moovBox.size else {
            throw PatchError.damaged("short read")
        }
        let fileSize = Int(try fh.seekToEnd())
        return Layout(moovBox: moovBox, moov: [UInt8](data), fileSize: fileSize,
                      moovBeforeMdat: moovBox.offset < firstMdat.offset)
    }

    /// dst = src with its moov box replaced by `newMoov`, then `extra` appended.
    static func write(from fh: FileHandle, to dst: URL, layout l: Layout, newMoov: [UInt8], extra: [UInt8] = []) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        func copy(from: Int, count: Int) throws {
            try fh.seek(toOffset: UInt64(from))
            var left = count
            while left > 0 {
                guard let chunk = try fh.read(upToCount: min(left, 4 << 20)), !chunk.isEmpty else {
                    throw PatchError.damaged("short read")
                }
                try out.write(contentsOf: chunk)
                left -= chunk.count
            }
        }
        try copy(from: 0, count: l.moovBox.offset)
        try out.write(contentsOf: Data(newMoov))
        let after = l.moovBox.offset + l.moovBox.size
        try copy(from: after, count: l.fileSize - after)
        if !extra.isEmpty { try out.write(contentsOf: Data(extra)) }
    }

    // MARK: video track

    /// moov > trak > mdia > minf > stbl of the first video track.
    static func videoChain(_ moov: [UInt8]) throws -> [Box] {
        let top = Box(type: "moov", offset: 0, size: moov.count, header: 8)
        for trak in try children(moov, 8, moov.count) where trak.type == "trak" {
            guard let mdia = try child(moov, trak, "mdia"),
                  let hdlr = try child(moov, mdia, "hdlr"),
                  hdlr.size - hdlr.header >= 12,
                  fourcc(moov, hdlr.body + 8) == "vide",
                  let minf = try child(moov, mdia, "minf"),
                  let stbl = try child(moov, minf, "stbl") else { continue }
            return [top, trak, mdia, minf, stbl]
        }
        throw PatchError.damaged("no video track")
    }

    // MARK: fps method

    static func fpsDivider(_ fps: Double) -> Int? {
        if fps >= 55 && fps <= 65 { return 2 }
        if fps >= 110 && fps <= 130 { return 4 }
        return nil
    }

    /// mvhd / mdhd: divide the time scale and the duration. Box sizes don't change.
    private static func divideTiming(_ b: inout [UInt8], _ box: Box, _ divisor: Int) throws {
        let body = box.body
        let room = box.size - box.header
        guard room >= 20 else { throw PatchError.damaged("short header box") }
        if b[body] == 1 {
            guard room >= 32 else { throw PatchError.damaged("short header box") }
            let ts = u32(b, body + 20)
            let dur = u64(b, body + 24)
            put32(&b, body + 20, max(1, ts / divisor))
            put64(&b, body + 24, dur / UInt64(divisor))
        } else {
            let ts = u32(b, body + 12)
            let dur = u32(b, body + 16)
            put32(&b, body + 12, max(1, ts / divisor))
            put32(&b, body + 16, dur / divisor)
        }
    }

    /// 60 fps reads as 30 (120 reads as 30): time scale and duration in mvhd and
    /// every mdhd are divided. The video data is not touched.
    static func fps(src: URL, dst: URL, divisor: Int) throws {
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let l = try layout(fh)
        var moov = l.moov
        _ = try videoChain(moov)
        guard let mvhd = try children(moov, 8, moov.count).first(where: { $0.type == "mvhd" }) else {
            throw PatchError.damaged("no mvhd box")
        }
        try divideTiming(&moov, mvhd, divisor)
        for trak in try children(moov, 8, moov.count) where trak.type == "trak" {
            guard let mdia = try child(moov, trak, "mdia"),
                  let mdhd = try child(moov, mdia, "mdhd") else { continue }
            try divideTiming(&moov, mdhd, divisor)
        }
        try write(from: fh, to: dst, layout: l, newMoov: moov)
    }

    // MARK: inflate method

    private static func dummySize(for codec: String) -> Int {
        switch codec {
        case "hvc1", "hev1", "dvh1", "dvhe": return 16
        default: return 8
        }
    }

    /// Adds `delta` to every stco/co64 entry under b[start..<end].
    private static func shiftOffsets(_ b: inout [UInt8], _ start: Int, _ end: Int, _ delta: Int) throws {
        for box in try children(b, start, end) {
            let body = box.body
            switch box.type {
            case "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf":
                try shiftOffsets(&b, body, box.end, delta)
            case "stco":
                let n = u32(b, body + 4)
                guard body + 8 + 4 * n <= box.end else { throw PatchError.damaged("bad stco") }
                for i in 0..<n {
                    let at = body + 8 + 4 * i
                    let v = u32(b, at) + delta
                    guard v <= Int(UInt32.max) else { throw PatchError.damaged("file too large for this method") }
                    put32(&b, at, v)
                }
            case "co64":
                let n = u32(b, body + 4)
                guard body + 8 + 8 * n <= box.end else { throw PatchError.damaged("bad co64") }
                for i in 0..<n {
                    let at = body + 8 + 8 * i
                    put64(&b, at, u64(b, at) &+ UInt64(delta))
                }
            default:
                break
            }
        }
    }

    /// Describes `multiplier - 1` extra filler samples per real video frame in the
    /// sample tables and appends a small mdat that holds them. The real frames are
    /// not touched. Returns (real frames, filler samples).
    @discardableResult
    static func inflate(src: URL, dst: URL, multiplier: Int = 5) throws -> (real: Int, fake: Int) {
        guard multiplier >= 2 else { throw PatchError.damaged("bad multiplier") }
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let l = try layout(fh)
        var moov = l.moov
        let chain = try videoChain(moov)
        guard chain.allSatisfy({ $0.header == 8 }), let stbl = chain.last else {
            throw PatchError.damaged("64-bit box sizes")
        }

        let kids = try children(moov, stbl.body, stbl.end)
        func find(_ t: String) -> Box? { kids.first { $0.type == t } }
        guard let stts = find("stts"), let stsz = find("stsz"), let stsc = find("stsc"),
              let stsd = find("stsd"), let co = find("stco") ?? find("co64") else {
            throw PatchError.damaged("video sample tables are incomplete")
        }

        // stts: keep every entry, remember the average frame time
        guard stts.size - stts.header >= 8 else { throw PatchError.damaged("bad stts") }
        let sttsCount = u32(moov, stts.body + 4)
        guard stts.body + 8 + 8 * sttsCount <= stts.end else { throw PatchError.damaged("bad stts") }
        var sttsEntries: [(Int, Int)] = []
        var real = 0
        var totalTime = 0
        for i in 0..<sttsCount {
            let at = stts.body + 8 + 8 * i
            let n = u32(moov, at)
            let d = u32(moov, at + 4)
            sttsEntries.append((n, d))
            real += n
            totalTime += n * d
        }
        guard real > 0 else { throw PatchError.damaged("stts has no samples") }
        let delta = max(1, Int((Double(totalTime) / Double(real)).rounded()))

        // stsz: every real sample size
        guard stsz.size - stsz.header >= 12 else { throw PatchError.damaged("bad stsz") }
        let uniform = u32(moov, stsz.body + 4)
        let szCount = u32(moov, stsz.body + 8)
        guard szCount == real else { throw PatchError.damaged("sample counts differ") }
        var sizes: [Int] = []
        if uniform != 0 {
            sizes = Array(repeating: uniform, count: szCount)
        } else {
            guard stsz.body + 12 + 4 * szCount <= stsz.end else { throw PatchError.damaged("bad stsz") }
            sizes.reserveCapacity(szCount)
            for i in 0..<szCount { sizes.append(u32(moov, stsz.body + 12 + 4 * i)) }
        }

        // stsc
        guard stsc.size - stsc.header >= 8 else { throw PatchError.damaged("bad stsc") }
        let scCount = u32(moov, stsc.body + 4)
        guard stsc.body + 8 + 12 * scCount <= stsc.end else { throw PatchError.damaged("bad stsc") }
        var scEntries: [(Int, Int, Int)] = []
        for i in 0..<scCount {
            let at = stsc.body + 8 + 12 * i
            scEntries.append((u32(moov, at), u32(moov, at + 4), u32(moov, at + 8)))
        }

        // chunk offsets
        let is64 = co.type == "co64"
        let step = is64 ? 8 : 4
        guard co.size - co.header >= 8 else { throw PatchError.damaged("bad chunk table") }
        let coCount = u32(moov, co.body + 4)
        guard co.body + 8 + step * coCount <= co.end else { throw PatchError.damaged("bad chunk table") }
        var offsets: [UInt64] = []
        offsets.reserveCapacity(coCount)
        for i in 0..<coCount {
            let at = co.body + 8 + step * i
            offsets.append(is64 ? u64(moov, at) : UInt64(u32(moov, at)))
        }

        guard stsd.size >= 20 else { throw PatchError.damaged("bad stsd") }
        let codec = fourcc(moov, stsd.body + 12)
        let dummy = dummySize(for: codec)
        let fake = real * (multiplier - 1)
        guard real + fake <= 12_000_000 else { throw PatchError.damaged("too many frames for Inflate") }

        // new tables
        var sttsPayload: [UInt8] = [0, 0, 0, 0] + bytes32(sttsEntries.count + 1)
        for (n, d) in sttsEntries { sttsPayload += bytes32(n) + bytes32(d) }
        sttsPayload += bytes32(fake) + bytes32(delta)
        let newStts = makeBox("stts", sttsPayload)

        var szPayload: [UInt8] = [0, 0, 0, 0] + bytes32(0) + bytes32(real + fake)
        szPayload.reserveCapacity(12 + 4 * (real + fake))
        for s in sizes { szPayload += bytes32(s) }
        let dummyBytes = bytes32(dummy)
        for _ in 0..<fake { szPayload += dummyBytes }
        let newStsz = makeBox("stsz", szPayload)

        var scPayload: [UInt8] = [0, 0, 0, 0] + bytes32(scEntries.count + 1)
        for (a, b, c) in scEntries { scPayload += bytes32(a) + bytes32(b) + bytes32(c) }
        scPayload += bytes32(coCount + 1) + bytes32(1) + bytes32(1)
        let newStsc = makeBox("stsc", scPayload)

        func chunkTable(fakeOffset: UInt64) throws -> [UInt8] {
            var p: [UInt8] = [0, 0, 0, 0] + bytes32(offsets.count + fake)
            p.reserveCapacity(8 + step * (offsets.count + fake))
            if is64 {
                for o in offsets { p += bytes64(o) }
                let f = bytes64(fakeOffset)
                for _ in 0..<fake { p += f }
            } else {
                for o in offsets { p += bytes32(Int(o)) }
                guard fakeOffset <= UInt64(UInt32.max) else { throw PatchError.damaged("file too large for this method") }
                let f = bytes32(Int(fakeOffset))
                for _ in 0..<fake { p += f }
            }
            return makeBox(co.type, p)
        }

        // The tables only grow with their entry counts, so measure the growth first.
        let probe = try chunkTable(fakeOffset: 0)
        let grow = (newStts.count - stts.size) + (newStsz.count - stsz.size)
            + (newStsc.count - stsc.size) + (probe.count - co.size)
        guard grow > 0 else { throw PatchError.damaged("unexpected table size") }
        // The filler mdat goes at the very end. If the index comes first, every offset
        // is shifted by `grow` afterwards, so start from the old end of the file.
        let fakeOffset = UInt64(l.moovBeforeMdat ? l.fileSize + 8 : l.fileSize + grow + 8)
        let newCo = try chunkTable(fakeOffset: fakeOffset)

        // swap the four boxes, last one first so the earlier offsets stay valid
        let swaps: [(Box, [UInt8])] = [(stts, newStts), (stsz, newStsz), (stsc, newStsc), (co, newCo)]
        for (box, bytes) in swaps.sorted(by: { $0.0.offset > $1.0.offset }) {
            moov.replaceSubrange(box.offset ..< box.end, with: bytes)
        }
        for box in chain {
            let s = box.size + grow
            guard s < (1 << 32) else { throw PatchError.damaged("box too large") }
            put32(&moov, box.offset, s)
        }
        guard moov.count == l.moovBox.size + grow else { throw PatchError.damaged("size mismatch") }
        if l.moovBeforeMdat {
            try shiftOffsets(&moov, 8, moov.count, grow)
        }

        // the filler samples: each one is a well-formed length-prefixed NAL of zeros
        let one = bytes32(dummy - 4) + [UInt8](repeating: 0, count: dummy - 4)
        let mdatSize = 8 + dummy * fake
        guard mdatSize < (1 << 32) else { throw PatchError.damaged("filler too large") }
        var mdat = bytes32(mdatSize) + Array("mdat".utf8)
        mdat.reserveCapacity(mdatSize)
        for _ in 0..<fake { mdat += one }

        try write(from: fh, to: dst, layout: l, newMoov: moov, extra: mdat)
        return (real, fake)
    }

    // MARK: silent method

    /// Independent implementation of the layout described by AscendedTweaks/silent-method
    /// (Nov 2026). Mirrors silent_layout() in pc/tiktok_methods.py byte for byte:
    /// ftyp, free, moov, one mdat; samples of all tracks interleaved by time (runs of
    /// video frames share a chunk); 8-byte filler video samples listed only in stsz/stco
    /// (up to duration x 400); last video frame lasts 1 tick; btrt max = avg; pasp 1:1
    /// when missing; creation and modification times zeroed; udta and meta removed.
    static let silentFakePerSecond = 400
    static let silentFiller: [UInt8] = [0, 0, 0, 4, 0, 0, 0, 0]

    private struct SilentTrack {
        var trakOffset: Int
        var stbl: Box
        var handler: String
        var timescale: Int
        var duration: Int
        var deltas: [Int]
        var sizes: [Int]
        var offs: [UInt64]
        var shift: Int
        var dts: [Int]
    }

    private static func headerTiming(_ b: [UInt8], _ box: Box) throws -> (timescale: Int, duration: Int) {
        let body = box.body
        guard box.size - box.header >= 20 else { throw PatchError.damaged("short header box") }
        if b[body] == 1 {
            guard box.size - box.header >= 32 else { throw PatchError.damaged("short header box") }
            return (u32(b, body + 20), Int(clamping: u64(b, body + 24)))
        }
        return (u32(b, body + 12), u32(b, body + 16))
    }

    private static func signed32(_ v: Int) -> Int { v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }

    private static func silentTrack(_ m: [UInt8], _ trak: Box) throws -> SilentTrack {
        guard let mdia = try child(m, trak, "mdia"), let minf = try child(m, mdia, "minf"),
              let stbl = try child(m, minf, "stbl"), let mdhd = try child(m, mdia, "mdhd") else {
            throw PatchError.damaged("track without sample table")
        }
        var handler = "????"
        if let hdlr = try child(m, mdia, "hdlr"), hdlr.size - hdlr.header >= 12 { handler = fourcc(m, hdlr.body + 8) }
        let (ts, dur) = try headerTiming(m, mdhd)
        let kids = try children(m, stbl.body, stbl.end)
        func find(_ t: String) -> Box? { kids.first { $0.type == t } }
        guard let stts = find("stts"), let stsz = find("stsz"), let stsc = find("stsc"),
              let stsd = find("stsd"), let co = find("stco") ?? find("co64") else {
            throw PatchError.damaged("track sample tables are incomplete")
        }
        var deltas: [Int] = []
        let sc = u32(m, stts.body + 4)
        guard stts.body + 8 + 8 * sc <= stts.end else { throw PatchError.damaged("bad stts") }
        for k in 0..<sc {
            let n = u32(m, stts.body + 8 + 8 * k), d = u32(m, stts.body + 12 + 8 * k)
            deltas.append(contentsOf: repeatElement(d, count: n))
        }
        let uniform = u32(m, stsz.body + 4), zc = u32(m, stsz.body + 8)
        var sizes: [Int] = []
        for k in 0..<min(zc, deltas.count) {
            if uniform != 0 { sizes.append(uniform) } else {
                guard stsz.body + 16 + 4 * k <= stsz.end else { throw PatchError.damaged("bad stsz") }
                sizes.append(u32(m, stsz.body + 12 + 4 * k))
            }
        }
        let is64 = co.type == "co64", step = is64 ? 8 : 4, cc = u32(m, co.body + 4)
        guard co.body + 8 + step * cc <= co.end else { throw PatchError.damaged("bad chunk table") }
        let chunks: [UInt64] = (0..<cc).map { k in
            let at = co.body + 8 + step * k
            return is64 ? u64(m, at) : UInt64(u32(m, at))
        }
        let ec = u32(m, stsc.body + 4)
        guard stsc.body + 8 + 12 * ec <= stsc.end else { throw PatchError.damaged("bad stsc") }
        let stscE: [(Int, Int, Int)] = (0..<ec).map { k in
            let at = stsc.body + 8 + 12 * k
            return (u32(m, at), u32(m, at + 4), u32(m, at + 8))
        }
        if u32(m, stsd.body + 4) != 1 || stscE.contains(where: { $0.2 != 1 }) {
            throw PatchError.damaged("multiple sample descriptions are not supported")
        }
        var offs: [UInt64] = []
        offs.reserveCapacity(sizes.count)
        var ei = 0
        for (ci, base) in chunks.enumerated() {
            while ei + 1 < stscE.count && stscE[ei + 1].0 <= ci + 1 { ei += 1 }
            var o = base
            let per = stscE.isEmpty ? 0 : stscE[ei].1
            for _ in 0..<per {
                if offs.count >= sizes.count { break }
                offs.append(o)
                o += UInt64(sizes[offs.count - 1])
            }
        }
        guard offs.count == sizes.count else { throw PatchError.damaged("sample table is inconsistent") }
        var shift = 0
        if let edts = try child(m, trak, "edts"), let elst = try child(m, edts, "elst") {
            let p = elst.body, ver = m[p]
            for k in 0..<u32(m, p + 4) {
                let t: Int
                if ver == 0 { t = signed32(u32(m, p + 12 + 8 * k)) } else { t = Int(Int64(bitPattern: u64(m, p + 16 + 16 * k))) }
                if t != -1 { shift = t; break }
            }
        }
        var dts: [Int] = []
        dts.reserveCapacity(deltas.count)
        var t = 0
        for d in deltas { dts.append(t); t += d }
        return SilentTrack(trakOffset: trak.offset, stbl: stbl, handler: handler, timescale: max(ts, 1),
                           duration: dur, deltas: deltas, sizes: sizes, offs: offs, shift: shift, dts: dts)
    }

    private static func silentStsd(_ m: [UInt8], _ stsd: Box, _ tr: SilentTrack) throws -> [UInt8] {
        let p = stsd.body
        let esize = u32(m, p + 8)
        let etype = fourcc(m, p + 12)
        let es = p + 16, ee = p + 8 + esize
        guard ee <= stsd.end, es + 78 <= ee else { throw PatchError.damaged("bad sample description") }
        let kids = try children(m, es + 78, ee)
        let btrt = kids.first { $0.type == "btrt" }, pasp = kids.first { $0.type == "pasp" }
        let avg: Int
        if let b = btrt { avg = u32(m, b.body + 8) } else {
            avg = tr.duration > 0 ? (tr.sizes.reduce(0, +) * 8 * tr.timescale) / tr.duration : 0
        }
        var body = Array(m[es ..< es + 78])
        for k in kids where k.type != "pasp" && k.type != "btrt" { body += m[k.offset ..< k.end] }
        body += makeBox("pasp", pasp.map { Array(m[$0.body ..< $0.end]) } ?? bytes32(1) + bytes32(1))
        body += makeBox("btrt", bytes32(0) + bytes32(avg) + bytes32(avg))
        return makeBox("stsd", Array(m[p ..< p + 8]) + makeBox(etype, body))
    }

    private static func zeroTimes(_ m: [UInt8], _ box: Box) -> [UInt8] {
        var b = Array(m[box.offset ..< box.end])
        let body = box.header
        let n = b[body] == 0 ? 8 : 16
        for i in (body + 4) ..< min(b.count, body + 4 + n) { b[i] = 0 }
        return b
    }

    /// Returns (real video frames, filler samples).
    @discardableResult
    static func silent(src: URL, dst: URL, maxSeconds: Int = 300) throws -> (frames: Int, fakes: Int) {
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let tops = try topBoxes(fh)
        if tops.contains(where: { $0.type == "moof" }) { throw PatchError.damaged("fragmented MP4 is not supported") }
        guard let ft = tops.first(where: { $0.type == "ftyp" }), let mv = tops.first(where: { $0.type == "moov" }) else {
            throw PatchError.damaged("not a valid MP4 (ftyp/moov missing)")
        }
        guard mv.header == 8 else { throw PatchError.damaged("64-bit moov size") }
        func readAt(_ o: Int, _ n: Int) throws -> [UInt8] {
            try fh.seek(toOffset: UInt64(o))
            guard let d = try fh.read(upToCount: n), d.count == n else { throw PatchError.damaged("short read") }
            return [UInt8](d)
        }
        let ftyp = try readAt(ft.offset, ft.size)
        let m = try readAt(mv.offset, mv.size)
        let moovBox = Box(type: "moov", offset: 0, size: m.count, header: 8)
        let traks = try children(m, 8, m.count).filter { $0.type == "trak" }
        let tracks = try traks.map { try silentTrack(m, $0) }
        guard let vi = tracks.firstIndex(where: { $0.handler == "vide" }) else { throw PatchError.damaged("no video track") }
        let v = tracks[vi]
        if Double(v.duration) / Double(v.timescale) > Double(maxSeconds) {
            throw PatchError.damaged("video longer than \(maxSeconds / 60) minutes")
        }

        // interleave by time, video first on ties; runs of video frames share a chunk
        struct Ev { let n: Int; let d: Int; let nv: Int; let i: Int; let s: Int }
        var ev: [Ev] = []
        for (i, tr) in tracks.enumerated() {
            for (s, d) in tr.dts.enumerated() { ev.append(Ev(n: d - tr.shift, d: tr.timescale, nv: i == vi ? 0 : 1, i: i, s: s)) }
        }
        ev.sort { a, b in
            let l = a.n * b.d, r = b.n * a.d
            if l != r { return l < r }
            if a.nv != b.nv { return a.nv < b.nv }
            if a.i != b.i { return a.i < b.i }
            return a.s < b.s
        }
        var chunks: [(Int, [Int])] = []
        for e in ev {
            if let last = chunks.last, last.0 == e.i, e.i == vi { chunks[chunks.count - 1].1.append(e.s) } else { chunks.append((e.i, [e.s])) }
        }
        var layout = Array(repeating: [(Int, Int)](), count: tracks.count)
        var rel = 0
        for (i, ss) in chunks {
            layout[i].append((rel, ss.count))
            for s in ss { rel += tracks[i].sizes[s] }
        }
        let want = Int((Double(v.duration) * Double(silentFakePerSecond) / Double(v.timescale) + 0.5).rounded(.down))
        let nFake = max(0, want - v.sizes.count)
        for _ in 0..<nFake { layout[vi].append((rel, 1)) }

        func stblBytes(_ i: Int, _ base: Int) throws -> [UInt8] {
            let tr = tracks[i], isV = i == vi
            let sizes = isV ? tr.sizes + Array(repeating: silentFiller.count, count: nFake) : tr.sizes
            let firstFake = isV ? layout[i].count - nFake + 1 : -1
            var stsc: [(Int, Int, Int)] = []
            for (k, c) in layout[i].enumerated() {
                if stsc.isEmpty || stsc[stsc.count - 1].1 != c.1 || k + 1 == firstFake { stsc.append((k + 1, c.1, 1)) }
            }
            var out: [UInt8] = []
            for b in try children(m, tr.stbl.body, tr.stbl.end) {
                switch b.type {
                case "stts" where isV:
                    var vals = Array(tr.deltas.dropLast())
                    if !tr.deltas.isEmpty { vals.append(1) }
                    var runs: [(Int, Int)] = []
                    for x in vals {
                        if let l = runs.last, l.1 == x { runs[runs.count - 1].0 += 1 } else { runs.append((1, x)) }
                    }
                    var p = bytes32(0) + bytes32(runs.count)
                    for (n, d) in runs { p += bytes32(n) + bytes32(d) }
                    out += makeBox("stts", p)
                case "stsd" where isV:
                    out += try silentStsd(m, b, tr)
                case "stsz":
                    var p = bytes32(0) + bytes32(0) + bytes32(sizes.count)
                    p.reserveCapacity(12 + 4 * sizes.count)
                    for x in sizes { p += bytes32(x) }
                    out += makeBox("stsz", p)
                case "stsc":
                    var p = bytes32(0) + bytes32(stsc.count)
                    for (a, n, c) in stsc { p += bytes32(a) + bytes32(n) + bytes32(c) }
                    out += makeBox("stsc", p)
                case "stco", "co64":
                    var p = bytes32(0) + bytes32(layout[i].count)
                    p.reserveCapacity(8 + 4 * layout[i].count)
                    for (o, _) in layout[i] { p += bytes32(base + o) }
                    out += makeBox("stco", p)
                default:
                    out += m[b.offset ..< b.end]
                }
            }
            return out
        }

        func rebuild(_ parent: Box, _ base: Int, _ ti: Int?) throws -> [UInt8] {
            var out: [UInt8] = []
            for b in try children(m, parent.body, parent.end) {
                switch b.type {
                case "udta", "meta":
                    continue
                case "mvhd", "tkhd", "mdhd":
                    out += zeroTimes(m, b)
                case "trak":
                    out += makeBox("trak", try rebuild(b, base, traks.firstIndex { $0.offset == b.offset }))
                case "mdia", "minf":
                    out += makeBox(b.type, try rebuild(b, base, ti))
                case "stbl":
                    guard let ti else { throw PatchError.damaged("sample table outside a track") }
                    out += makeBox("stbl", try stblBytes(ti, base))
                default:
                    out += m[b.offset ..< b.end]
                }
            }
            return out
        }

        let head = ftyp + makeBox("free", [])
        let probe = makeBox("moov", try rebuild(moovBox, 0, nil))
        let base = head.count + probe.count + 8
        let mdatSize = 8 + rel + silentFiller.count
        guard base + mdatSize < (1 << 32) else { throw PatchError.damaged("output over 4 GB is not supported") }
        let newMoov = makeBox("moov", try rebuild(moovBox, base, nil))
        guard newMoov.count == probe.count else { throw PatchError.damaged("index size changed unexpectedly") }

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        try out.write(contentsOf: Data(head + newMoov + bytes32(mdatSize) + Array("mdat".utf8)))
        func copy(_ o: UInt64, _ n: Int) throws {
            try fh.seek(toOffset: o)
            var left = n
            while left > 0 {
                guard let c = try fh.read(upToCount: min(left, 4 << 20)), !c.isEmpty else { throw PatchError.damaged("short read") }
                try out.write(contentsOf: c)
                left -= c.count
            }
        }
        var run: (UInt64, Int)?
        for (i, ss) in chunks {
            for s in ss {
                let o = tracks[i].offs[s], n = tracks[i].sizes[s]
                if let r = run, r.0 + UInt64(r.1) == o { run = (r.0, r.1 + n) } else {
                    if let r = run { try copy(r.0, r.1) }
                    run = (o, n)
                }
            }
        }
        if let r = run { try copy(r.0, r.1) }
        try out.write(contentsOf: Data(silentFiller))
        return (v.sizes.count, nFake)
    }

    // MARK: checking a Silent result

    /// Apple's video reader (AVFoundation) refuses the video track of a Silent file: its size
    /// table lists the filler samples, its time table doesn't, so it reports "no video track".
    /// This checks the result with our own reader instead: the same tracks, every real sample
    /// the same bytes in the same order, and the video's description (codec, size, HDR, Dolby
    /// Vision boxes) the same apart from the pasp/btrt boxes Silent sets. Returns the video's
    /// real frame count.
    @discardableResult
    static func silentCheck(original: URL, patched: URL) throws -> Int {
        func load(_ u: URL) throws -> (FileHandle, [UInt8], [Box], [SilentTrack]) {
            let fh = try FileHandle(forReadingFrom: u)
            let tops = try topBoxes(fh)
            guard let mv = tops.first(where: { $0.type == "moov" }), mv.header == 8 else {
                try? fh.close()
                throw PatchError.changed("index (moov) missing")
            }
            try fh.seek(toOffset: UInt64(mv.offset))
            guard let d = try fh.read(upToCount: mv.size), d.count == mv.size else {
                try? fh.close()
                throw PatchError.changed("index (moov) short")
            }
            let m = [UInt8](d)
            let traks = try children(m, 8, m.count).filter { $0.type == "trak" }
            return (fh, m, traks, try traks.map { try silentTrack(m, $0) })
        }
        let (fa, ma, _, ta) = try load(original)
        defer { try? fa.close() }
        let (fb, mb, _, tb) = try load(patched)
        defer { try? fb.close() }
        guard ta.count == tb.count else { throw PatchError.changed("number of tracks") }
        guard let vi = ta.firstIndex(where: { $0.handler == "vide" }), tb[vi].handler == "vide" else {
            throw PatchError.changed("video track")
        }
        // the video's description
        func desc(_ m: [UInt8], _ tr: SilentTrack) throws -> (String, [UInt8], [[UInt8]]) {
            guard let stsd = try children(m, tr.stbl.body, tr.stbl.end).first(where: { $0.type == "stsd" }) else {
                throw PatchError.changed("sample description")
            }
            let p = stsd.body, es = p + 16, ee = p + 8 + u32(m, p + 8)
            guard ee <= stsd.end, es + 78 <= ee else { throw PatchError.changed("sample description") }
            let kids = try children(m, es + 78, ee).filter { $0.type != "pasp" && $0.type != "btrt" }
            return (fourcc(m, p + 12), Array(m[es ..< es + 78]), kids.map { Array(m[$0.offset ..< $0.end]) })
        }
        let (ca, ha, ka) = try desc(ma, ta[vi]), (cb, hb, kb) = try desc(mb, tb[vi])
        if ca != cb { throw PatchError.changed("codec") }
        if ha != hb { throw PatchError.changed("size") }
        if ka != kb { throw PatchError.changed("HDR / Dolby Vision / codec settings") }
        // every real sample, byte for byte
        func readAt(_ fh: FileHandle, _ o: UInt64, _ n: Int) throws -> Data {
            try fh.seek(toOffset: o)
            guard let d = try fh.read(upToCount: n), d.count == n else { throw PatchError.changed("sample data short") }
            return d
        }
        for i in 0 ..< ta.count {
            let a = ta[i], b = tb[i]
            if a.handler != b.handler { throw PatchError.changed("track \(i + 1) type") }
            if a.sizes != b.sizes || a.deltas.count != b.deltas.count {
                throw PatchError.changed(i == vi ? "frame count" : "sound samples")
            }
            for s in 0 ..< a.sizes.count where a.sizes[s] > 0 {
                if try readAt(fa, a.offs[s], a.sizes[s]) != readAt(fb, b.offs[s], b.sizes[s]) {
                    throw PatchError.changed(i == vi ? "picture data (frame \(s + 1))" : "sound data")
                }
            }
        }
        return ta[vi].sizes.count
    }
}
