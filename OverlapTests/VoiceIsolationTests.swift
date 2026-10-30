import AVFoundation
import Testing
@testable import Overlap

/// Voice isolation through the same composition and taps the player uses. There's no speech to test with, so these
/// check what can be measured: steady noise is taken out, timing holds, and the switch off leaves sound untouched.
@MainActor
struct VoiceIsolationTests {
    let sampleRate = 48_000.0
    let directory = FileManager.default.temporaryDirectory.appending(path: "VoiceIsolationTests-\(UUID().uuidString)")

    /// Four seconds of mono white noise at about −20 dBFS RMS.
    func makeNoise() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "noise.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        var generator = SystemRandomNumberGenerator()
        for frame in 0..<Int(frames) {
            samples[frame] = Float.random(in: -0.173...0.173, using: &generator)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    func render(isolatesVoice: Bool) async throws -> [Float] {
        let url = try makeNoise()
        let asset = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Noise", kind: .audio,
                          duration: Time(seconds: 4), hasAudio: true)
        var clip = Clip(assetID: asset.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4))
        clip.isolatesVoice = isolatesVoice
        var project = Project()
        project.assets = [asset]
        project.tracks[0].clips = [clip]
        let source = AVURLAsset(url: url)
        let built = try await CompositionBuilder.build(project: project, assets: { _ in source })
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
        output.audioMix = built.audioMix
        var rendered: [Float] = []
        try await PCMReader.read(built.composition, output: output) { rendered.append(contentsOf: $0) }
        return rendered
    }

    func decibels(_ samples: ArraySlice<Float>) -> Double {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(sum / Double(samples.count), 1e-12))
    }

    @Test func voiceIsolationIsAvailable() throws {
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        #expect(VoiceIsolation(format: format, maximumFrames: 4096) != nil)
        format.mChannelsPerFrame = 1
        #expect(VoiceIsolation(format: format, maximumFrames: 4096) != nil)
        // The builder makes up for this delay, so it has to be known.
        #expect(VoiceIsolation.latency(sampleRate: 48_000, channels: 1) > 0)
    }

    /// Speech made by the system voice, at 48 kHz.
    func makeSpeech() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "speech.wav")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@48000",
                         "Overlap makes videos for the team. This checks that isolated speech stays in step with the picture."]
        try say.run()
        say.waitUntilExit()
        return url
    }

    func renderSpeech(isolatesVoice: Bool, at start: Double) async throws -> [Float] {
        let url = try makeSpeech()
        let length = try await AVURLAsset(url: url).load(.duration).seconds
        let asset = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Speech", kind: .audio,
                          duration: Time(seconds: length), hasAudio: true, sampleRate: sampleRate, channelCount: 1)
        var clip = Clip(assetID: asset.id, start: Time(seconds: start), sourceStart: .zero, duration: Time(seconds: length))
        clip.isolatesVoice = isolatesVoice
        var project = Project()
        project.assets = [asset]
        project.tracks[0].clips = [clip]
        let source = AVURLAsset(url: url)
        let built = try await CompositionBuilder.build(project: project, assets: { _ in source })
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
        output.audioMix = built.audioMix
        var rendered: [Float] = []
        try await PCMReader.read(built.composition, output: output) { rendered.append(contentsOf: $0) }
        return rendered
    }

    /// Loudness over time in 5 ms steps, for lining two takes up.
    func envelope(_ samples: [Float]) -> [Double] {
        stride(from: 0, to: samples.count - 240, by: 240).map { start in
            samples[start..<start + 240].reduce(0.0) { $0 + Double(abs($1)) }
        }
    }

    /// How many 5 ms steps `later` trails `earlier`, from −40 to 40.
    func lag(of later: [Double], behind earlier: [Double]) -> Int {
        (-40...40).max { a, b in
            let score = { (shift: Int) in
                zip(earlier.indices, earlier).reduce(0.0) { sum, pair in
                    let index = pair.0 + shift
                    return index >= 0 && index < later.count ? sum + pair.1 * later[index] : sum
                }
            }
            return score(a) < score(b)
        }!
    }

    @Test func isolatedSpeechStaysInStep() async throws {
        let original = try await renderSpeech(isolatesVoice: false, at: 1)
        let isolated = try await renderSpeech(isolatesVoice: true, at: 1)
        #expect(isolated.count == original.count)
        // Within one 5 ms step of the original, though the isolation itself trails by about 56 ms.
        #expect(abs(lag(of: envelope(isolated), behind: envelope(original))) <= 1)
        // Speech comes through at about its own level.
        let speech = Int(sampleRate * 1.2)..<(original.count - Int(sampleRate * 0.3))
        #expect(abs(decibels(isolated[speech]) - decibels(original[speech])) < 6)
    }

    @Test func steadyNoiseIsTakenOut() async throws {
        let original = try await render(isolatesVoice: false)
        let isolated = try await render(isolatesVoice: true)
        #expect(isolated.count == original.count)
        let middle = Int(sampleRate)..<Int(sampleRate * 3)
        let before = decibels(original[middle])
        let after = decibels(isolated[middle])
        #expect(abs(before + 20) < 1)
        #expect(after < before - 10)
    }

    // MARK: Waveforms

    @Test func isolatedWaveformDropsSteadyNoise() async throws {
        let url = try makeNoise()
        let original = try #require(await MediaAnalysis.waveform(for: url))
        let isolated = try #require(await MediaAnalysis.isolatedWaveform(for: url))
        #expect(abs(isolated.peaks.count - original.peaks.count) <= 1)
        let mean = { (peaks: [Float]) in peaks.reduce(0, +) / Float(peaks.count) }
        #expect(mean(isolated.peaks) < mean(original.peaks) / 4)
    }

    @Test func isolatedWaveformLinesUpWithTheSpeech() async throws {
        let url = try makeSpeech()
        let original = try #require(await MediaAnalysis.waveform(for: url)).peaks.map(Double.init)
        let isolated = try #require(await MediaAnalysis.isolatedWaveform(for: url)).peaks.map(Double.init)
        // Within one 10 ms peak of the original.
        #expect(abs(lag(of: isolated, behind: original)) <= 1)
    }

    @Test func turningIsolationOnDrawsTheIsolatedWaveform() async throws {
        let url = try makeNoise()
        let asset = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Noise", kind: .audio,
                          duration: Time(seconds: 4), hasAudio: true)
        var project = Project()
        project.assets = [asset]
        project.tracks[0].clips = [Clip(assetID: asset.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4))]
        let store = ProjectStore(project: project, mediaDirectory: directory)
        let clip = try #require(store.project.tracks[0].clips.first?.id)
        store.select([clip])
        #expect(store.isolatedWaveforms.isEmpty)
        store.setIsolatesVoice(true)
        let deadline = ContinuousClock.now + .seconds(10)
        while store.isolatedWaveforms[asset.id] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.isolatedWaveforms[asset.id] != nil)
    }
}
