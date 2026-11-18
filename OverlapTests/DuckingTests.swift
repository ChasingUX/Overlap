import AVFoundation
import Testing
@testable import Overlap

/// Music kept low under speech: the dip's shape, what it lowers, and that it's heard.
@MainActor
struct DuckingTests {
    let sampleRate = 48_000.0

    @Test func musicDipsUnderSpeechAndComesBackInLongPauses() {
        // Two sentences with a short pause between, then a long one.
        let ducking = Ducking(speech: [1...2, 2.4...3, 6...7])
        #expect(ducking.gain(at: 0) == 1)
        #expect(ducking.gain(at: 1.5) == Ducking.level)
        // The short pause stays low; the long one comes back up.
        #expect(ducking.gain(at: 2.2) == Ducking.level)
        #expect(ducking.gain(at: 4.5) == 1)
        // It eases down just before speech and up just after.
        let before = ducking.gain(at: 1 - Ducking.down / 2)
        #expect(before > Ducking.level && before < 1)
        let after = ducking.gain(at: 3 + Ducking.up / 2)
        #expect(after > Ducking.level && after < 1)
        #expect(Ducking(speech: []).gain(at: 3) == 1)
    }

    @Test func onlySoundFilesAreLowered() {
        var project = Project()
        let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 30), hasAudio: true)
        let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Talk.mov", kind: .video, duration: Time(seconds: 30), hasAudio: true)
        project.assets = [song, video]
        #expect(project.isDucked(Clip(assetID: song.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))))
        #expect(!project.isDucked(Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))))
    }

    @Test func theDipIsHeard() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { samples[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate)) }
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)

        let song = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Theme", kind: .audio, duration: Time(seconds: 4), hasAudio: true)
        var project = Project()
        project.assets = [song]
        project.tracks[0].clips = [Clip(assetID: song.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4))]
        let source = AVURLAsset(url: url)
        let built = try await CompositionBuilder.build(project: project, assets: { _ in source },
                                                       options: CompositionBuilder.Options(ducking: Ducking(speech: [1.5...2.5])))
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
        output.audioMix = built.audioMix
        var rendered: [Float] = []
        try await PCMReader.read(built.composition, output: output) { rendered.append(contentsOf: $0) }

        func rms(_ start: Double, _ end: Double) -> Double {
            let slice = rendered[Int(start * sampleRate)..<min(rendered.count, Int(end * sampleRate))]
            return (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
        }
        let full = 0.5 / 2.squareRoot()
        #expect(abs(rms(0.2, 1.0) - full) < 0.02)
        #expect(abs(rms(1.7, 2.3) / full - Ducking.level) < 0.03)
        #expect(abs(rms(3.3, 3.9) - full) < 0.02)
    }

    @Test func theProjectSwitchGoesByTheTranscript() {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Talk.mov", kind: .video, duration: Time(seconds: 10), hasAudio: true)
        var project = Project()
        project.assets = [video]
        project.tracks[0].clips = [Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 10))]
        store.load(project, mediaDirectory: store.mediaDirectory)
        // No transcript and no music: nothing to offer.
        #expect(!store.canDuckMusic)
        store.setDucksMusic(true)
        #expect(store.project.ducksMusic)
        // No transcript yet: nothing to go by.
        #expect(store.ducking == nil)
        store.load(store.project, mediaDirectory: store.mediaDirectory,
                   transcripts: [video.id: Transcript(words: [Transcript.Word(text: "Hello.", start: 2, end: 3)])])
        #expect(store.ducking?.gain(at: 2.5) == Ducking.level)
        // Speech, but still no music to lower.
        #expect(!store.canDuckMusic)
        let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 30), hasAudio: true)
        store.apply("Add") { project in
            project.assets.append(song)
            project.tracks.append(Track(name: "Music", clips: [Clip(assetID: song.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 10))]))
        }
        #expect(store.canDuckMusic)
        store.setDucksMusic(false)
        #expect(store.ducking == nil)
    }
}
