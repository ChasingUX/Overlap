import AVFoundation
import Testing
@testable import Overlap

/// Renders the timeline's audio through the same composition and taps the player uses,
/// then measures the result, proving the gain curves land sample-accurately.
@MainActor
struct AudioRenderTests {
    let sampleRate = 48_000.0
    let amplitude: Float = 0.5

    /// Writes a 4-second, 440 Hz mono tone.
    func makeTone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    func render(_ clip: (UUID) -> Clip, configure: (inout Project) -> Void = { _ in }) async throws -> [Float] {
        let url = try makeTone()
        let asset = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Tone", kind: .audio,
                          duration: Time(seconds: 4), hasAudio: true)
        var project = Project()
        project.assets = [asset]
        project.tracks[0].clips = [clip(asset.id)]
        configure(&project)

        let source = AVURLAsset(url: url)
        let built = try await CompositionBuilder.build(project: project, assets: { _ in source })
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
        output.audioMix = built.audioMix

        var rendered: [Float] = []
        try await PCMReader.read(built.composition, output: output) { rendered.append(contentsOf: $0) }
        return rendered
    }

    func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let slice = samples[Int(start * sampleRate)..<min(samples.count, Int(end * sampleRate))]
        let sum = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(slice.count)).squareRoot()
    }

    var fullLevel: Double { Double(amplitude) / 2.squareRoot() }
}

private extension Int {
    var double: Double { Double(self) }
}

extension AudioRenderTests {

    @Test func fadeInFollowsItsCurve() async throws {
        let samples = try await render { id in
            Clip(assetID: id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4),
                 fadeIn: Fade(duration: Time(seconds: 2), curve: .linear))
        }
        #expect(abs(rms(samples, from: 3, to: 3.5) - fullLevel) < 0.02)
        // A linear 2-second fade reaches a quarter at 0.5 s and half at 1 s.
        #expect(abs(rms(samples, from: 0.45, to: 0.55) / fullLevel - 0.25) < 0.03)
        #expect(abs(rms(samples, from: 0.95, to: 1.05) / fullLevel - 0.5) < 0.03)
        #expect(rms(samples, from: 0, to: 0.01) < 0.01)
    }

    @Test func gapBeforeAClipIsSilent() async throws {
        let samples = try await render { id in
            Clip(assetID: id, start: Time(seconds: 1), sourceStart: .zero, duration: Time(seconds: 3))
        }
        #expect(rms(samples, from: 0.1, to: 0.9) < 0.001)
        #expect(abs(rms(samples, from: 1.5, to: 2.5) - fullLevel) < 0.02)
    }

    @Test func doubleSpeedPlaysTheWholeToneInHalfTheTime() async throws {
        let samples = try await render { id in
            Clip(assetID: id, start: .zero, sourceStart: .zero, duration: Time(seconds: 2), speed: 2)
        }
        // The tone must start on time and end at 2 s. Time-stretching leaves a little trailing silence, which is harmless.
        let first = try #require(samples.firstIndex { abs($0) > 0.01 }).double / sampleRate
        let last = try #require(samples.lastIndex { abs($0) > 0.01 }).double / sampleRate
        #expect(first < 0.01)
        #expect(abs(last - 2) < 0.01)
        #expect(abs(rms(samples, from: 0.5, to: 1.5) - fullLevel) < 0.03)
    }

    @Test func mutedTracksAreSilentButKeepTheirLength() async throws {
        let samples = try await render({ id in
            Clip(assetID: id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4))
        }, configure: { $0.tracks[0].isMuted = true })
        #expect(abs(Double(samples.count) / sampleRate - 4) < 0.05)
        #expect(rms(samples, from: 0.5, to: 3.5) < 0.001)
    }

    @Test func masterVolumeCanBoostTheMix() async throws {
        let samples = try await render({ id in
            Clip(assetID: id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4), volume: 0.25)
        }, configure: { $0.masterVolume = 2 })
        #expect(abs(rms(samples, from: 1, to: 3) / fullLevel - 0.5) < 0.02)
    }

    @Test func volumeScalesTheClip() async throws {
        let samples = try await render { id in
            Clip(assetID: id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4), volume: 0.5)
        }
        #expect(abs(rms(samples, from: 1, to: 3) / fullLevel - 0.5) < 0.02)
    }
}
