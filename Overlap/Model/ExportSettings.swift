import Foundation

/// What an export makes. Remembered between exports, not saved in the project.
struct ExportSettings: Hashable, Sendable, Codable {
    enum Format: String, CaseIterable, Codable, Sendable {
        case mp4
        case mov
        case wav
        case aiff
        case m4a

        var name: String { rawValue.uppercased() }
        var hasVideo: Bool { self == .mp4 || self == .mov }
        var fileExtension: String { self == .aiff ? "aif" : rawValue }

        static let video: [Format] = [.mp4, .mov]
        static let audio: [Format] = [.wav, .aiff, .m4a]
    }

    enum Codec: String, CaseIterable, Codable, Sendable {
        case h264
        case hevc

        var name: String { self == .h264 ? "H.264" : "HEVC" }
    }

    enum Quality: String, CaseIterable, Codable, Sendable {
        case high
        case medium
        case small

        var name: String { rawValue.capitalized }
    }

    var videoFormat = Format.mp4
    var audioFormat = Format.wav
    /// Whether the last export was audio only.
    var isAudioOnly = false
    var codec = Codec.h264
    /// The picture's shorter side in pixels, as in 1080p; nil keeps the canvas size.
    var resolution: Int?
    var quality = Quality.high
    /// For audio-only files. Video always carries 48 kHz sound.
    var sampleRate = 48_000.0
    /// For WAV and AIFF.
    var bitDepth = 24

    var format: Format { isAudioOnly ? audioFormat : videoFormat }

    static let resolutions = [2160, 1080, 720]
    static let sampleRates = [48_000.0, 44_100.0]
    static let bitDepths = [16, 24]

    /// The sizes offered for a canvas: its own, and the standard ones below it.
    static func resolutions(below canvas: Canvas) -> [Int?] {
        [nil] + resolutions.filter { $0 < min(canvas.width, canvas.height) }
    }

    /// The picture's size in the file. Encoders need even sizes.
    func pictureSize(for canvas: Canvas) -> (width: Int, height: Int) {
        let shorter = min(canvas.width, canvas.height)
        guard let resolution, resolution < shorter else { return (canvas.width / 2 * 2, canvas.height / 2 * 2) }
        let scale = Double(resolution) / Double(shorter)
        let even = { (length: Int) in max(2, Int((Double(length) * scale / 2).rounded()) * 2) }
        return (even(canvas.width), even(canvas.height))
    }

    /// The sound's sample rate in the file.
    var outputSampleRate: Double { format.hasVideo ? 48_000 : sampleRate }
}
