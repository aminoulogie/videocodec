import AVFoundation
import Foundation
import VideoToolbox

/// The same idea as `tiktok_prep.py --prepare`: re-encode the video once into a
/// regular file (constant frame rate, a keyframe every second, AAC sound) before
/// it is patched. This is the only part of the app that re-encodes.
struct PrepareOptions: Equatable {
    /// Scale down so the short side is 1080 (the size that holds best on TikTok).
    var to1080 = false
}

enum Prepare {
    typealias Rate = (timescale: Int32, tick: Int64, fps: Double)

    /// Nearest standard frame rate, as exact ticks (59.94 = 1001 / 60000).
    static func standardRate(_ fps: Double) -> Rate {
        let table: [(Int32, Int64)] = [
            (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1),
            (60000, 1001), (60, 1), (120000, 1001), (120, 1), (240, 1),
        ]
        var best: Rate = (60, 1, 60)
        var gap = Double.infinity
        for (timescale, tick) in table {
            let f = Double(timescale) / Double(tick)
            if abs(f - fps) < gap {
                gap = abs(f - fps)
                best = (timescale, tick, f)
            }
        }
        if gap > 1.5, fps > 1 {
            return (Int32((fps * 1000).rounded()), 1000, fps)
        }
        return best
    }

    private static func fourCC(_ c: FourCharCode) -> String {
        let b = [24, 16, 8, 0].map { UInt8((c >> UInt32($0)) & 0xFF) }
        return String(bytes: b, encoding: .ascii) ?? "?"
    }

    /// Re-encodes `src` into `dst` (.mp4). `progress` gets 0...100.
    static func encode(src: URL, dst: URL, options: PrepareOptions,
                       progress: @escaping (Int) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw PatchError.damaged("no video track")
        }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (size, transform, nominal, descs) = try await vTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        let bytes = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?
            .doubleValue ?? 0

        // What the source is: HEVC or not, HDR or not.
        var transfer: String?
        var sourceIsHEVC = false
        if let d = descs.first {
            sourceIsHEVC = ["hvc1", "hev1", "dvh1", "dvhe"].contains(fourCC(CMFormatDescriptionGetMediaSubType(d)))
            let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any] ?? [:]
            let t = ext[kCVImageBufferTransferFunctionKey as String] as? String ?? ""
            if t == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                transfer = AVVideoTransferFunction_ITU_R_2100_HLG
            } else if t == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                transfer = AVVideoTransferFunction_SMPTE_ST_2084_PQ
            }
        }
        let hdr = transfer != nil
        let useHEVC = hdr || sourceIsHEVC      // HDR needs HEVC 10-bit; otherwise keep the source's codec

        // Size (before rotation: the rotation is kept as a flag, like the original).
        var w = Int(abs(size.width).rounded())
        var h = Int(abs(size.height).rounded())
        let scaled = options.to1080 && min(w, h) > 1080
        if scaled {
            let k = 1080.0 / Double(min(w, h))
            w = Int((Double(w) * k).rounded())
            h = Int((Double(h) * k).rounded())
        }
        w -= w % 2
        h -= h % 2
        guard w > 0, h > 0 else { throw PatchError.damaged("no picture size") }

        let rate = standardRate(Double(nominal))
        let gop = max(1, Int(rate.fps.rounded()))

        // Bitrate: generous for the size and frame rate, but not far above the source's own.
        let motion = min(rate.fps, 60) + max(0, rate.fps - 60) * 0.5
        var bitrate = Double(w * h) * motion * (useHEVC ? 0.10 : 0.15)
        if duration > 0, bytes > 0 {
            bitrate = min(bitrate, max(bytes * 8 / duration * 1.5, 8_000_000))
        }
        bitrate = max(bitrate, 4_000_000)

        // Reader: decoded frames, 10-bit when HDR.
        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                              : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let vOut = AVAssetReaderTrackOutput(
            track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw PatchError.export("can't read this video") }
        reader.add(vOut)

        // Writer: one closed group of pictures per second, no frame reordering.
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoMaxKeyFrameIntervalKey: gop,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoExpectedSourceFrameRateKey: gop,
        ]
        if useHEVC {
            compression[AVVideoProfileLevelKey] = (hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel
                                                       : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        var vSettings: [String: Any] = [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if scaled { vSettings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill }
        if let transfer {
            vSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        guard writer.canApply(outputSettings: vSettings, forMediaType: .video) else {
            throw PatchError.export("this iPhone can't encode \(w)×\(h) at \(gop) fps. Turn on Scale to 1080p.")
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        vIn.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(vIn) else { throw PatchError.export("the encoder refused this video") }
        writer.add(vIn)

        // Sound: first audio track, stereo AAC.
        var audioPump: AudioPump?
        if let aTrack {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: [aTrack], audioSettings: pcm)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let aac: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut)
                writer.add(aIn)
                audioPump = AudioPump(out: aOut, input: aIn)
            }
        }

        guard reader.startReading() else {
            throw PatchError.export(reader.error?.localizedDescription ?? "can't read the video")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw PatchError.export(writer.error?.localizedDescription ?? "can't start the encoder")
        }
        writer.startSession(atSourceTime: .zero)

        let videoPump = VideoPump(out: vOut, input: vIn, adaptor: adaptor, reader: reader,
                                  rate: rate, duration: duration, progress: progress)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            videoPump.start(on: DispatchQueue(label: "prepare.video")) { group.leave() }
            if let audioPump {
                group.enter()
                audioPump.start(on: DispatchQueue(label: "prepare.audio")) { group.leave() }
            }
            group.notify(queue: .global()) { done.resume() }
        }

        if let why = videoPump.failed {
            writer.cancelWriting()
            throw PatchError.export(writer.error?.localizedDescription ?? why)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw PatchError.export(reader.error?.localizedDescription ?? "reading the video failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PatchError.export(writer.error?.localizedDescription ?? "the encoder stopped")
        }
    }
}

/// Feeds decoded frames to the encoder on an exact frame grid: a frame that comes
/// too early is dropped, a hole is filled with the frame before it. iPhone videos
/// often have slightly uneven frame times; the result has none.
private final class VideoPump: @unchecked Sendable {
    private let out: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let reader: AVAssetReader
    private let rate: Prepare.Rate
    private let duration: Double
    private let progress: (Int) -> Void
    private var next: Int64 = 0
    private var previous: CVPixelBuffer?
    private var pending: [CVPixelBuffer] = []
    private var finished = false
    private var lastPercent = -1
    private(set) var failed: String?

    init(out: AVAssetReaderOutput, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         reader: AVAssetReader, rate: Prepare.Rate, duration: Double, progress: @escaping (Int) -> Void) {
        self.out = out
        self.input = input
        self.adaptor = adaptor
        self.reader = reader
        self.rate = rate
        self.duration = duration
        self.progress = progress
    }

    func start(on queue: DispatchQueue, done: @escaping @Sendable () -> Void) {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            if finished { return }
            while input.isReadyForMoreMediaData {
                if pending.isEmpty {
                    guard let sample = out.copyNextSampleBuffer() else {
                        finish(done)
                        return
                    }
                    guard let picture = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard t.isFinite, t >= 0 else { continue }
                    let slot = Int64((t * rate.fps).rounded())
                    if slot < next { continue }                       // too early: drop
                    let gap = min(slot - next, Int64(rate.fps * 10))  // hole: repeat the frame before
                    next = slot - gap
                    if gap > 0 {
                        pending.append(contentsOf: Array(repeating: previous ?? picture, count: Int(gap)))
                    }
                    pending.append(picture)
                    previous = picture
                    if duration > 0 {
                        let percent = min(100, Int(t / duration * 100))
                        if percent != lastPercent {
                            lastPercent = percent
                            progress(percent)
                        }
                    }
                }
                let picture = pending.removeFirst()
                let time = CMTime(value: next * rate.tick, timescale: rate.timescale)
                if !adaptor.append(picture, withPresentationTime: time) {
                    failed = "the encoder refused a frame"
                    reader.cancelReading()
                    finish(done)
                    return
                }
                next += 1
            }
        }
    }

    private func finish(_ done: () -> Void) {
        finished = true
        pending.removeAll()
        previous = nil
        input.markAsFinished()
        done()
    }
}

private final class AudioPump: @unchecked Sendable {
    private let out: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private var finished = false

    init(out: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.out = out
        self.input = input
    }

    func start(on queue: DispatchQueue, done: @escaping @Sendable () -> Void) {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            if finished { return }
            while input.isReadyForMoreMediaData {
                guard let sample = out.copyNextSampleBuffer(), input.append(sample) else {
                    finished = true
                    input.markAsFinished()
                    done()
                    return
                }
            }
        }
    }
}
