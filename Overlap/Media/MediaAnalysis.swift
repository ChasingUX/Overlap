import AVFoundation
import ImageIO

/// Peak levels for drawing an asset's waveform.
struct Waveform: Sendable {
    let peaksPerSecond: Double
    let peaks: [Float]

    /// The loudest peak between two source times, 0 to 1.
    func peak(from start: Double, to end: Double) -> Float {
        let first = max(0, Int(start * peaksPerSecond))
        let last = min(peaks.count, max(first + 1, Int(end * peaksPerSecond)))
        guard first < last else { return 0 }
        return peaks[first..<last].max() ?? 0
    }
}

/// Small frames sampled evenly across a video, for drawing clips as a filmstrip.
/// Frame `i` stands for the source time from `i * interval` up to `(i + 1) * interval`.
struct Filmstrip: Sendable {
    let interval: Double
    var frames: [CGImage?]

    /// The frame for a source time, or the nearest one already generated.
    func frame(at seconds: Double) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let index = Int(seconds / interval).clamped(to: 0...(frames.count - 1))
        if let frame = frames[index] { return frame }
        for offset in 1..<max(2, frames.count) {
            if index - offset >= 0, let frame = frames[index - offset] { return frame }
            if index + offset < frames.count, let frame = frames[index + offset] { return frame }
        }
        return nil
    }

    var aspectRatio: Double? {
        guard let frame = frames.lazy.compactMap({ $0 }).first, frame.height > 0 else { return nil }
        return Double(frame.width) / Double(frame.height)
    }
}

enum MediaAnalysis {
    /// Samples up to 300 frames (at least one every half second), calling `update` as batches arrive.
    @concurrent
    static func filmstrip(for url: URL, update: @escaping @Sendable @MainActor (Filmstrip) -> Void) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return }
        let interval = max(0.5, duration / 300)
        let count = max(1, Int((duration / interval).rounded(.up)))
        let times = (0..<count).map { index in
            CMTime(seconds: min(duration - 0.001, (Double(index) + 0.5) * interval), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var strip = Filmstrip(interval: interval, frames: Array(repeating: nil, count: count))
        var unsent = 0
        for await element in generator.images(for: times) {
            if case let .success(requestedTime, image, _) = element {
                strip.frames[Int(requestedTime.seconds / interval).clamped(to: 0...(count - 1))] = image
                unsent += 1
            }
            if unsent >= 12 {
                await update(strip)
                unsent = 0
            }
        }
        await update(strip)
    }

    /// A small upright copy of an image file.
    @concurrent
    static func imageThumbnail(for url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent
    static func thumbnail(for url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    /// Reads the audio as 8 kHz mono and keeps 100 peaks per second.
    @concurrent
    static func waveform(for url: URL) async -> Waveform? {
        let sampleRate = 8_000.0
        let peaksPerSecond = 100.0
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))

        let samplesPerPeak = Int(sampleRate / peaksPerSecond)
        var peaks: [Float] = []
        var currentPeak: Float = 0
        var count = 0
        do {
            try await PCMReader.read(asset, output: output) { samples in
                for sample in samples {
                    currentPeak = max(currentPeak, abs(sample))
                    count += 1
                    if count == samplesPerPeak {
                        peaks.append(min(currentPeak, 1))
                        currentPeak = 0
                        count = 0
                    }
                }
            }
        } catch {
            return nil
        }
        if count > 0 { peaks.append(min(currentPeak, 1)) }
        return Waveform(peaksPerSecond: peaksPerSecond, peaks: peaks)
    }
}
