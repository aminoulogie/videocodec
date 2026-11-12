import AVFoundation
import Foundation

/// The same patch as tiktok_prep.py --patch: copy the video without
/// re-encoding, then set the movie header (mvhd) to version 1 with the
/// longest possible duration. Frames, sound and HDR are not touched.
enum PatchError: LocalizedError {
    case damaged(String)
    case export(String)
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .damaged(let s): return "This file can't be patched: \(s)"
        case .export(let s): return "Copying the video failed: \(s)"
        case .changed(let s): return "The patched file differs from the original in: \(s). Don't upload it."
        }
    }
}

struct VideoInfo: Equatable {
    var codec = "?"
    var width = 0
    var height = 0
    var fps: Double = 0
    var hdr = "SDR"
    var dolbyVision = false
    var frames = 0
    var megabytes: Double = 0
    var mbps: Double = 0

    var hdrText: String { dolbyVision ? "\(hdr) + Dolby Vision" : hdr }
    var sizeText: String { "\(width)×\(height)" }
}

enum Patcher {
    // MARK: reading video facts

    static func info(of url: URL, countingFrames: Bool = true) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PatchError.damaged("no video track")
        }
        var v = VideoInfo()
        let (size, transform, fps, descs) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let shown = size.applying(transform)
        v.width = Int(abs(shown.width).rounded())
        v.height = Int(abs(shown.height).rounded())
        v.fps = (Double(fps) * 100).rounded() / 100
        if let d = descs.first {
            v.codec = fourCC(CMFormatDescriptionGetMediaSubType(d))
            let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] ?? [:]
            let transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String ?? ""
            if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                v.hdr = "HLG"
            } else if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                v.hdr = "HDR10"
            }
            let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any] ?? [:]
            v.dolbyVision = atoms.keys.contains { ["dvcC", "dvvC", "dvwC"].contains($0) }
                || ["dvh1", "dvhe", "dva1", "dvav"].contains(v.codec)
        }
        if countingFrames { v.frames = try countFrames(asset: asset, track: track) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .doubleValue ?? 0
        v.megabytes = (bytes / 1e5).rounded() / 10
        let seconds = try await asset.load(.duration).seconds
        if seconds > 0 { v.mbps = (bytes * 8 / seconds / 1e5).rounded() / 10 }
        return v
    }

    private static func countFrames(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // no decoding
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw PatchError.damaged("can't read the video") }
        var n = 0
        while let s = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(s) }
        if reader.status == .failed { throw PatchError.damaged(reader.error?.localizedDescription ?? "read error") }
        return n
    }

    private static func fourCC(_ c: FourCharCode) -> String {
        let b = [24, 16, 8, 0].map { UInt8((c >> UInt32($0)) & 0xFF) }
        return String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    // MARK: the whole job

    /// Copies `src` without re-encoding into `dst` (.mp4), patches it, and
    /// checks that nothing about the picture changed.
    static func run(src: URL, dst: URL, method: PatchMethod = .silent,
                    step: @escaping (String) -> Void) async throws -> (VideoInfo, VideoInfo) {
        step("Reading your video…")
        let before = try await info(of: src)
        guard ["hvc1", "hev1", "avc1", "avc3", "dvh1", "dvhe"].contains(before.codec) else {
            throw PatchError.damaged("codec \(before.codec) — export H.264 or HEVC from your editor")
        }
        step("Copying without re-encoding…")
        let copy = dst.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await passthrough(src: src, dst: copy)
        step("Patching (\(method.title))…")
        try? FileManager.default.removeItem(at: dst)
        switch method {
        case .silent:
            try Mp4.silent(src: copy, dst: dst)
        case .header:
            try patchFile(src: copy, dst: dst)
        case .inflate:
            try Mp4.inflate(src: copy, dst: dst)
        case .fps:
            guard let divisor = Mp4.fpsDivider(before.fps) else {
                throw PatchError.damaged("the FPS method needs a 60 or 120 fps video, this one is \(before.fps) fps")
            }
            try Mp4.fps(src: copy, dst: dst, divisor: divisor)
        }
        step("Checking the result…")
        if method == .silent {
            // Apple's reader refuses Silent's video track (filler samples), so it's checked
            // with our own reader: same tracks, same description, every frame byte for byte.
            do {
                try Mp4.silentCheck(original: copy, patched: dst)
            } catch {
                try? FileManager.default.removeItem(at: dst)
                throw error
            }
            var after = before
            let bytes = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?
                .doubleValue ?? 0
            after.megabytes = (bytes / 1e5).rounded() / 10
            if before.megabytes > 0 { after.mbps = (before.mbps * after.megabytes / before.megabytes * 10).rounded() / 10 }
            return (before, after)
        }
        // Inflate adds filler samples on purpose, so its frame count is not compared.
        let addsFillers = method == .inflate || method == .silent
        let after = try await info(of: dst, countingFrames: !addsFillers)
        var bad: [String] = []
        if before.codec != after.codec { bad.append("codec") }
        if before.sizeText != after.sizeText { bad.append("size") }
        // FPS changes the frame rate the file reports on purpose; Inflate adds samples to it.
        if method == .header && abs(before.fps - after.fps) > 0.05 { bad.append("frame rate") }
        if before.hdr != after.hdr { bad.append("HDR") }
        if before.dolbyVision != after.dolbyVision { bad.append("Dolby Vision") }
        if !addsFillers && before.frames != after.frames { bad.append("frame count") }
        if !bad.isEmpty {
            try? FileManager.default.removeItem(at: dst)
            throw PatchError.changed(bad.joined(separator: ", "))
        }
        return (before, after)
    }

    private static func passthrough(src: URL, dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PatchError.export("passthrough not available for this file")
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw PatchError.export("this video can't be put in an MP4 without re-encoding")
        }
        session.outputURL = dst
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        await session.export()
        if session.status != .completed {
            throw PatchError.export(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
    }

    // MARK: MP4 boxes

    private struct Box { let type: String; let offset: Int; let size: Int; let header: Int }

    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        d[d.startIndex + at ..< d.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ d: Data, _ at: Int) -> UInt64 {
        d[d.startIndex + at ..< d.startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func put32(_ d: inout Data, _ at: Int, _ v: UInt32) {
        for i in 0..<4 { d[d.startIndex + at + i] = UInt8((v >> UInt32(24 - 8 * i)) & 0xFF) }
    }

    private static func put64(_ d: inout Data, _ at: Int, _ v: UInt64) {
        for i in 0..<8 { d[d.startIndex + at + i] = UInt8((v >> UInt64(56 - 8 * i)) & 0xFF) }
    }

    private static func boxType(_ d: Data, _ at: Int) -> String {
        String(bytes: d[d.startIndex + at + 4 ..< d.startIndex + at + 8], encoding: .isoLatin1) ?? "????"
    }

    /// Boxes inside `d[start..<end]` (d holds a whole box tree in memory).
    private static func children(_ d: Data, _ start: Int, _ end: Int) throws -> [Box] {
        var out: [Box] = []
        var p = start
        while p + 8 <= end {
            var size = Int(be32(d, p))
            var h = 8
            if size == 1 {
                guard p + 16 <= end else { throw PatchError.damaged("bad box size") }
                size = Int(be64(d, p + 8))
                h = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= h, p + size <= end else { throw PatchError.damaged("bad box size") }
            out.append(Box(type: boxType(d, p), offset: p, size: size, header: h))
            p += size
        }
        return out
    }

    /// Top-level boxes of a file, reading only their headers.
    private static func topBoxes(_ fh: FileHandle) throws -> [Box] {
        let end = Int(try fh.seekToEnd())
        var out: [Box] = []
        var p = 0
        while p + 8 <= end {
            try fh.seek(toOffset: UInt64(p))
            let head = try fh.read(upToCount: 16) ?? Data()
            guard head.count >= 8 else { break }
            var size = Int(be32(head, 0))
            var h = 8
            if size == 1 {
                guard head.count >= 16 else { throw PatchError.damaged("bad box size") }
                size = Int(be64(head, 8))
                h = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= h, p + size <= end else { throw PatchError.damaged("bad box size") }
            out.append(Box(type: boxType(head, 0), offset: p, size: size, header: h))
            p += size
        }
        return out
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf"]

    /// Adds `delta` to every chunk offset (stco/co64) under d[start..<end].
    private static func shiftOffsets(_ d: inout Data, _ start: Int, _ end: Int, _ delta: Int) throws {
        for b in try children(d, start, end) {
            let body = b.offset + b.header
            if containers.contains(b.type) {
                try shiftOffsets(&d, body, b.offset + b.size, delta)
            } else if b.type == "stco" {
                let n = Int(be32(d, body + 4))
                guard body + 8 + 4 * n <= b.offset + b.size else { throw PatchError.damaged("bad stco") }
                for i in 0..<n {
                    let at = body + 8 + 4 * i
                    let v = Int(be32(d, at)) + delta
                    guard v <= Int(UInt32.max) else { throw PatchError.damaged("file too large") }
                    put32(&d, at, UInt32(v))
                }
            } else if b.type == "co64" {
                let n = Int(be32(d, body + 4))
                guard body + 8 + 8 * n <= b.offset + b.size else { throw PatchError.damaged("bad co64") }
                for i in 0..<n {
                    let at = body + 8 + 8 * i
                    put64(&d, at, be64(d, at) &+ UInt64(delta))
                }
            }
        }
    }

    /// Writes `dst` = `src` with the mvhd patch. Only the moov box is held in memory.
    static func patchFile(src: URL, dst: URL) throws {
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let tops = try topBoxes(fh)
        guard let moovBox = tops.first(where: { $0.type == "moov" }),
              tops.contains(where: { $0.type == "mdat" }) else {
            throw PatchError.damaged("no moov/mdat box")
        }
        guard moovBox.header == 8 else { throw PatchError.damaged("64-bit moov size") }
        try fh.seek(toOffset: UInt64(moovBox.offset))
        guard var moov = try fh.read(upToCount: moovBox.size), moov.count == moovBox.size else {
            throw PatchError.damaged("short read")
        }
        guard let mvhd = try children(moov, 8, moov.count).first(where: { $0.type == "mvhd" }) else {
            throw PatchError.damaged("no mvhd box")
        }
        let body = Data(moov[moov.startIndex + mvhd.offset + mvhd.header ..< moov.startIndex + mvhd.offset + mvhd.size])
        var new = Data()
        if body.first == 0 {
            guard body.count >= 20 else { throw PatchError.damaged("short mvhd") }
            new.append(1)                                   // version 1
            new.append(body[body.startIndex + 1 ..< body.startIndex + 4])   // flags
            var tmp = Data(count: 28)
            put64(&tmp, 0, UInt64(be32(body, 4)))           // creation time
            put64(&tmp, 8, UInt64(be32(body, 8)))           // modification time
            put32(&tmp, 16, be32(body, 12))                 // timescale
            put64(&tmp, 20, UInt64.max)                     // duration
            new.append(tmp)
            new.append(body[body.startIndex + 20 ..< body.endIndex])
        } else {
            guard body.count >= 32 else { throw PatchError.damaged("short mvhd") }
            new = body
            for i in 24..<32 { new[new.startIndex + i] = 0xFF }
        }
        var box = Data(count: 8)
        put32(&box, 0, UInt32(8 + new.count))
        box.replaceSubrange(box.startIndex + 4 ..< box.startIndex + 8, with: Array("mvhd".utf8))
        box.append(new)
        let grow = box.count - mvhd.size
        moov.replaceSubrange(moov.startIndex + mvhd.offset ..< moov.startIndex + mvhd.offset + mvhd.size, with: box)
        put32(&moov, 0, UInt32(moovBox.size + grow))
        // If the video data comes after moov, it moves by `grow` bytes.
        if grow != 0, tops.contains(where: { $0.type == "mdat" && $0.offset > moovBox.offset }) {
            try shiftOffsets(&moov, 8, moov.count, grow)
        }

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
        try copy(from: 0, count: moovBox.offset)
        try out.write(contentsOf: moov)
        let after = moovBox.offset + moovBox.size
        let end = Int(try fh.seekToEnd())
        try copy(from: after, count: end - after)
    }
}
