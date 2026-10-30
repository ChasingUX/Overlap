import AVFoundation
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case noMediaTracks(String)
    case copyFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(name): "\(name) isn't a supported video or audio format."
        case let .noMediaTracks(name): "\(name) has no video or audio to import."
        case let .copyFailed(name, code): "\(name) couldn't be copied into the project (error \(code))."
        }
    }
}

enum MediaImporter {
    /// What an imported file contains, read before it's copied.
    struct Probe: Sendable {
        var kind: AssetKind
        var duration: Time
        var hasAudio: Bool
        var pixelWidth: Int?
        var pixelHeight: Int?
        var frameRate: Double?
        var sampleRate: Double?
        var channelCount: Int?
    }

    static let supportedTypes: [UTType] = [.movie, .audio]

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    @concurrent
    static func probe(_ url: URL) async throws -> Probe {
        let name = url.lastPathComponent
        guard isSupported(url) else { throw ImportError.unsupportedFormat(name) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        guard video != nil || audio != nil else { throw ImportError.noMediaTracks(name) }

        var probe = Probe(kind: video == nil ? .audio : .video, duration: Time(duration), hasAudio: audio != nil)
        if let video {
            let (size, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let upright = CGRect(origin: .zero, size: size).applying(transform)
            probe.pixelWidth = Int(abs(upright.width).rounded())
            probe.pixelHeight = Int(abs(upright.height).rounded())
            probe.frameRate = rate > 0 ? Double(rate) : nil
        }
        if let audio, let format = try await audio.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            probe.sampleRate = description.mSampleRate
            probe.channelCount = Int(description.mChannelsPerFrame)
        }
        return probe
    }

    /// Copies a file, as an instant APFS clone when both sides are on the same drive.
    @concurrent
    static func copy(_ source: URL, to destination: URL) async throws {
        try cloneFile(source, to: destination)
    }

    nonisolated static func cloneFile(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // COPYFILE_CLONE falls back to a normal copy when cloning isn't possible.
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA | COPYFILE_STAT)
        let result = copyfile(source.path, destination.path, nil, flags)
        guard result == 0 else { throw ImportError.copyFailed(source.lastPathComponent, errno) }
    }
}
