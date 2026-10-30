@preconcurrency import AVFoundation
import Accelerate
import VideoToolbox

/// Renders the whole timeline to one file through the same compositor and audio taps as playback, so the file
/// looks and sounds like the preview. With a loudness target, the mix is measured first, then written with one
/// gain change and its true peaks kept under −1 dBTP.
enum Exporter {
    /// Everything one export needs, built for it alone and handed over whole.
    struct Job: @unchecked Sendable {
        /// Played once to measure the mix. A second build, since an audio tap serves one reader at a time.
        var measuring: BuiltComposition?
        var writing: BuiltComposition
        var settings: ExportSettings
        var canvas: Canvas
        var loudnessTarget: Double?
        var destination: URL
    }

    enum Stage: Sendable {
        case measuring
        case writing
    }

    struct Progress: Sendable {
        var stage: Stage
        /// Through the whole export, 0 to 1.
        var fraction: Double
    }

    static let truePeakCeiling = -1.0

    /// Builds what exporting the project takes, from the project as it is now.
    @MainActor
    static func job(for project: Project, assets: (UUID) -> AVURLAsset?, settings: ExportSettings, destination: URL) async throws -> Job {
        let target = project.normalizesLoudness ? Project.loudnessTarget : nil
        return Job(
            measuring: target == nil ? nil : try await CompositionBuilder.build(project: project, assets: assets),
            writing: try await CompositionBuilder.build(project: project, assets: assets),
            settings: settings,
            canvas: project.canvas ?? Project.defaultCanvas,
            loudnessTarget: target,
            destination: destination
        )
    }

    @concurrent
    static func run(_ job: Job, progress: @escaping @Sendable (Progress) -> Void) async throws {
        // Checked first, so a folder that's gone or locked says so at once rather than after measuring.
        let folder = job.destination.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
              FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ExportError.cannotSave(in: folder.lastPathComponent)
        }
        let settings = job.settings
        let sampleRate = settings.outputSampleRate
        let audioTracks = try await job.writing.composition.loadTracks(withMediaType: .audio)
        let videoTracks = try await job.writing.composition.loadTracks(withMediaType: .video)
        let writesVideo = settings.format.hasVideo && job.writing.videoComposition != nil && !videoTracks.isEmpty
        guard writesVideo || !audioTracks.isEmpty else { throw ExportError.nothingToExport }
        let duration = max(job.writing.duration.seconds, 0.001)
        // How much of the bar measuring takes: about the share of the time it takes, so the bar keeps one pace.
        // It only reads sound, so it's quicker than drawing and encoding every frame, but not by as much as
        // it seems.
        let measuringShare = writesVideo ? 0.3 : 0.45

        var gain: Float = 1
        if let target = job.loudnessTarget, let measuring = job.measuring, !audioTracks.isEmpty {
            progress(Progress(stage: .measuring, fraction: 0))
            if let loudness = try await measureLoudness(of: measuring, sampleRate: sampleRate, progress: { seconds in
                progress(Progress(stage: .measuring, fraction: measuringShare * min(1, seconds / duration)))
            }) {
                gain = Float(pow(10, (target - loudness) / 20))
            }
        }
        let limits = job.loudnessTarget != nil
        try Task.checkCancellation()
        progress(Progress(stage: .writing, fraction: limits ? measuringShare : 0))
        let writingStart = limits ? measuringShare : 0

        // Written beside the destination under a hidden name, then moved into place, so a canceled or failed
        // export never leaves half a file, or replaces a good one.
        let partial = folder.appending(path: ".\(job.destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(settings.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }

        let writer = try AVAssetWriter(outputURL: partial, fileType: fileType(of: settings.format))
        writer.shouldOptimizeForNetworkUse = settings.format.hasVideo

        var videoReader: AVAssetReader?
        var videoProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?
        var videoReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if writesVideo {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.videoComposition = job.writing.videoComposition
            let reader = try AVAssetReader(asset: job.writing.composition)
            videoProvider = reader.outputProvider(for: output)
            videoReader = reader
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings, canvas: job.canvas))
            videoReceiver = writer.inputReceiver(for: input)
        }

        var audioReader: AVAssetReader?
        var audioProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        let format = try CMAudioFormatDescription(audioStreamBasicDescription: floatFormat(sampleRate: sampleRate))
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 2))
            output.audioMix = job.writing.audioMix
            let reader = try AVAssetReader(asset: job.writing.composition)
            audioProvider = reader.outputProvider(for: output)
            audioReader = reader
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(settings), sourceFormatHint: format)
            audioReceiver = writer.inputReceiver(for: input)
        }

        do {
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            try videoReader?.start()
            try audioReader?.start()

            let report: @Sendable (Double) -> Void = { seconds in
                progress(Progress(stage: .writing, fraction: writingStart + (1 - writingStart) * min(1, seconds / duration)))
            }
            let limiter = limits ? TruePeakLimiter(sampleRate: sampleRate, channels: 2, ceiling: truePeakCeiling) : nil
            let gain = gain
            let canceler = WriterCanceler(writer)
            // Picture and sound go in side by side, and the writer takes whichever it needs next. Encoders hold some
            // of what they're given back, so feeding the two in time order can leave each waiting on the other.
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup { group in
                    if let videoProvider, let videoReceiver {
                        group.addTask {
                            while let video = try await videoProvider.next() {
                                try Task.checkCancellation()
                                try await videoReceiver.append(video)
                                report(video.presentationTimeStamp.seconds)
                            }
                            videoReceiver.finish()
                        }
                    }
                    if let audioProvider, let audioReceiver {
                        group.addTask {
                            var sound = SoundStream(gain: gain, limiter: limiter, sampleRate: sampleRate, format: format)
                            while let audio = try await sound.next(from: audioProvider) {
                                try Task.checkCancellation()
                                try await audioReceiver.append(audio)
                                if !writesVideo { report(audio.presentationTimeStamp.seconds) }
                            }
                            audioReceiver.finish()
                        }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                canceler.cancel()
            }
            await writer.finishWriting()
            if writer.status != .completed { throw writer.error ?? ExportError.writeFailed }
        } catch {
            videoReader?.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            throw error
        }

        if FileManager.default.fileExists(atPath: job.destination.path) {
            _ = try FileManager.default.replaceItemAt(job.destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: job.destination)
        }
        progress(Progress(stage: .writing, fraction: 1))
    }

    /// The integrated loudness of a composition's mix, in LUFS, or nil if it's silent. `progress` hears how many
    /// seconds have been read.
    nonisolated(nonsending)
    static func measureLoudness(of built: BuiltComposition, sampleRate: Double = 48_000, progress: (Double) -> Void = { _ in }) async throws -> Double? {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 2))
        output.audioMix = built.audioMix
        var meter = LoudnessMeter(sampleRate: sampleRate, channels: 2)
        var frames = 0
        try await PCMReader.read(built.composition, output: output) { samples in
            meter.add(samples)
            frames += samples.count / 2
            progress(Double(frames) / sampleRate)
        }
        try Task.checkCancellation()
        return meter.integratedLoudness
    }

    /// The mix as it's read, turned up or down to the target and limited, cut into buffers ready to write.
    private struct SoundStream {
        let gain: Float
        var limiter: TruePeakLimiter?
        let sampleRate: Double
        let format: CMAudioFormatDescription
        private var written = 0
        private var isFinished = false

        init(gain: Float, limiter: TruePeakLimiter?, sampleRate: Double, format: CMAudioFormatDescription) {
            self.gain = gain
            self.limiter = limiter
            self.sampleRate = sampleRate
            self.format = format
        }

        mutating func next(from provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?) async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
            guard let provider else { return nil }
            while !isFinished {
                guard let ready = try await provider.next() else {
                    isFinished = true
                    if let rest = limiter?.finish(), !rest.isEmpty { return try buffer(rest) }
                    return nil
                }
                var samples = ready.withUnsafeSampleBuffer { buffer -> [Float] in
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
                    let length = CMBlockBufferGetDataLength(block)
                    var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                    samples.withUnsafeMutableBytes { bytes in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                    }
                    return samples
                }
                if gain != 1 { vDSP.multiply(gain, samples, result: &samples) }
                if limiter != nil {
                    samples = samples.withUnsafeBufferPointer { limiter!.process($0) }
                }
                if !samples.isEmpty { return try buffer(samples) }
            }
            return nil
        }

        private mutating func buffer(_ samples: [Float]) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
            let frames = samples.count / 2
            let data = samples.withUnsafeBytes { Data($0) }
            let ready = CMReadySampleBuffer(audioDataBuffer: CMReadOnlyDataBlockBuffer(data), formatDescription: format,
                                            sampleCount: frames, presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)))
            written += frames
            return CMReadySampleBuffer(ready)
        }
    }

    private static func floatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    private static func fileType(of format: ExportSettings.Format) -> AVFileType {
        switch format {
        case .mp4: .mp4
        case .mov: .mov
        case .wav: .wav
        case .aiff: .aiff
        case .m4a: .m4a
        }
    }

    /// About this many bits per pixel of each frame. HEVC gets the same look from less.
    private static func bitsPerPixel(_ quality: ExportSettings.Quality, codec: ExportSettings.Codec) -> Double {
        let h264 = switch quality {
        case .high: 0.15
        case .medium: 0.08
        case .small: 0.04
        }
        return codec == .hevc ? h264 * 0.65 : h264
    }

    private static func videoSettings(_ settings: ExportSettings, canvas: Canvas) -> [String: Any] {
        let size = settings.pictureSize(for: canvas)
        let rate = canvas.frameRate
        let bitRate = Double(size.width * size.height) * rate * bitsPerPixel(settings.quality, codec: settings.codec)
        return [
            AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            // Standard dynamic range, as the compositor draws.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: rate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int((rate * 2).rounded())),
                AVVideoProfileLevelKey: settings.codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ]
    }

    private static func audioSettings(_ settings: ExportSettings) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        var audio: [String: Any] = [
            AVSampleRateKey: settings.outputSampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData,
        ]
        switch settings.format {
        case .wav, .aiff:
            audio[AVFormatIDKey] = kAudioFormatLinearPCM
            audio[AVLinearPCMBitDepthKey] = settings.bitDepth
            audio[AVLinearPCMIsFloatKey] = false
            audio[AVLinearPCMIsBigEndianKey] = settings.format == .aiff
            audio[AVLinearPCMIsNonInterleaved] = false
        case .mp4, .mov, .m4a:
            audio[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audio[AVEncoderBitRateKey] = switch settings.format.hasVideo ? settings.quality : .high {
            case .high: 256_000
            case .medium: 192_000
            case .small: 128_000
            }
        }
        return audio
    }
}

/// Stops a writer from the cancellation handler, which runs alongside the export. That wakes whichever side is
/// waiting for the writer to take more. The writer's cancel is safe to call from any thread.
private final class WriterCanceler: @unchecked Sendable {
    private let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }

    func cancel() {
        writer.cancelWriting()
    }
}

enum ExportError: LocalizedError, Equatable {
    case nothingToExport
    case cannotSave(in: String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .nothingToExport: "There's nothing on the timeline to export."
        case let .cannotSave(folder): "Overlap can't save to “\(folder)”. Choose another folder."
        case .writeFailed: "The file couldn't be written."
        }
    }
}
