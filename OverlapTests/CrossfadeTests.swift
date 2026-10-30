import AVFoundation
import Foundation
import Testing
@testable import Overlap

/// Overlaps on one track: where they're allowed, how trims treat them, and the curves they use.
struct CrossfadeTests {
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 20),
                     hasAudio: true, sampleRate: 48_000, channelCount: 2)
    let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Interview.mov", kind: .video, duration: Time(seconds: 10),
                      hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)

    func makeProject() -> Project {
        var project = Project()
        project.assets = [song, video]
        return project
    }

    func seconds(_ value: Double) -> Time { Time(seconds: value) }

    /// A 10-second-long piece of the song, starting `sourceStart` seconds in.
    func piece(at start: Double, sourceStart: Double = 5, duration: Double = 10) -> Clip {
        Clip(assetID: song.id, start: seconds(start), sourceStart: seconds(sourceStart), duration: seconds(duration))
    }

    @Test func partialOverlapCrossfadesOnOneTrack() throws {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: song.id, at: seconds(15), preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 2)
        let crossfade = try #require(project.crossfades(onTrack: 0).first)
        #expect(crossfade.range == TimeRange(start: seconds(15), duration: seconds(5)))
        #expect(crossfade.curve == .equalPower)
    }

    @Test func aClipInsideAnotherMovesUpATrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: video.id, at: seconds(5), preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 1)
        #expect(project.tracks[1].clips.count == 1)
    }

    @Test func aClipCoveringAnotherMovesUpATrack() {
        var project = makeProject()
        project.addClip(asset: video.id, at: seconds(5), preferredTrack: 0)
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 1)
        #expect(project.tracks[1].clips.count == 1)
    }

    @Test func threeClipsAtOnceMovesUpATrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: song.id, at: seconds(15), preferredTrack: 0)
        project.addClip(asset: song.id, at: seconds(18), preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 2)
        #expect(project.tracks[1].clips.count == 1)
    }

    @Test func aClipCanCrossfadeAtBothEnds() {
        var project = makeProject()
        project.tracks[0].clips = [piece(at: 0), piece(at: 14)]
        project.addClip(asset: video.id, at: seconds(8), preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 3)
        #expect(project.crossfades(onTrack: 0).map(\.range.duration) == [seconds(2), seconds(4)])
    }

    @Test func trimmingGrowsACrossfadeButNeverCoversAClip() throws {
        var project = makeProject()
        let first = piece(at: 0, sourceStart: 0)
        let second = piece(at: 8, sourceStart: 10)
        project.tracks[0].clips = [first, second]

        project.trim(second.id, edge: .start, to: seconds(4))
        #expect(project.crossfade(into: second.id)?.range == TimeRange(start: seconds(4), duration: seconds(6)))

        // Pulled all the way back, the later clip still starts after the earlier one.
        project.trim(second.id, edge: .start, to: .zero)
        let start = try #require(project.clip(second.id)?.start)
        #expect(start == Project.minimumClipDuration)

        // Pushed past the later clip's end, the earlier clip stops short of it.
        project.trim(first.id, edge: .end, to: seconds(30))
        let firstEnd = try #require(project.clip(first.id)?.end)
        let secondEnd = try #require(project.clip(second.id)?.end)
        #expect(firstEnd < secondEnd)
    }

    @Test func trimmingTouchingClipsDoesntStartACrossfade() {
        var project = makeProject()
        let first = piece(at: 0, sourceStart: 0)
        let second = piece(at: 10)
        project.tracks[0].clips = [first, second]
        project.trim(first.id, edge: .end, to: seconds(14))
        project.trim(second.id, edge: .start, to: seconds(6))
        #expect(project.clip(first.id)?.end == seconds(10))
        #expect(project.clip(second.id)?.start == seconds(10))
        #expect(project.crossfades(onTrack: 0).isEmpty)
    }

    @Test func aCrossfadeSetsAsideTheFadeOnItsEdge() throws {
        var project = makeProject()
        var first = piece(at: 0, sourceStart: 0)
        first.fadeOut = Fade(duration: seconds(2), curve: .linear)
        let second = piece(at: 20)
        project.tracks[0].clips = [first, second]
        let track = project.tracks[0].id
        func played() throws -> Fade {
            try #require(project.clip(first.id)).playedFade(.end, crossfades: project.crossfades(onTrack: 0))
        }
        #expect(try played().duration == seconds(2))

        // Dragged over, the crossfade takes the edge; the fade is kept but not played.
        project.moveClip(second.id, to: seconds(8), target: .existing(track))
        #expect(try played() == Fade.none)
        #expect(project.clip(first.id)?.fadeOut.duration == seconds(2))

        // Pulled apart again, the fade comes back.
        project.moveClip(second.id, to: seconds(12), target: .existing(track))
        #expect(try played().duration == seconds(2))
    }

    @Test func eachCrossfadeKeepsItsOwnCurve() {
        var project = makeProject()
        let pieces = [piece(at: 0), piece(at: 8), piece(at: 16)]
        project.tracks[0].clips = pieces
        project.setCrossfadeCurve(.sCurve, into: pieces[1].id)
        #expect(project.crossfades(onTrack: 0).map(\.curve) == [.sCurve, .equalPower])
        #expect(project.defaultCrossfadeCurve == .equalPower)
    }

    @Test func projectsFromMilestoneTwoStillOpen() throws {
        var project = makeProject()
        project.tracks[0].clips = [piece(at: 0)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        for key in ["masterVolume", "defaultCrossfadeCurve"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == project)
        #expect(decoded.masterVolume == 1)
        #expect(decoded.defaultCrossfadeCurve == .equalPower)
        #expect(decoded.tracks[0].clips[0].crossfadeCurve == nil)
    }
}

/// The Transitions tab only exists while a crossfade is selected.
@MainActor
struct TransitionSelectionTests {
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 20),
                     hasAudio: true, sampleRate: 48_000, channelCount: 2)

    func makeStore() -> (ProjectStore, incoming: UUID) {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var incoming = UUID()
        store.apply("Import Media") { [song] project in
            project.assets = [song]
            project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
            incoming = project.addClip(asset: song.id, at: Time(seconds: 15), preferredTrack: 0)?.id ?? incoming
        }
        return (store, incoming)
    }

    @Test func selectingACrossfadeOpensTransitionsUntilAClipIsSelected() throws {
        let (store, incoming) = makeStore()
        store.activeTab = .media
        store.selectTransition(incoming)
        #expect(store.activeTab == .transitions)
        #expect(store.selectedCrossfade?.incoming.id == incoming)

        store.setCrossfadeCurve(.sCurve)
        store.useCrossfadeCurveAsDefault()
        #expect(store.project.defaultCrossfadeCurve == .sCurve)

        store.select([incoming])
        #expect(store.selectedTransition == nil)
        #expect(store.activeTab != .transitions)
    }

    @Test func fadeMenusSkipACrossfadedEdge() {
        let (store, incoming) = makeStore()
        store.select([incoming])
        #expect(!store.canFade(.start))
        #expect(store.canFade(.end))
        store.toggleFade(.start)
        #expect(store.project.clip(incoming)?.fadeIn.duration == .zero)
        store.toggleFade(.end)
        #expect(store.project.clip(incoming)?.fadeOut.duration == ProjectStore.addedFadeDuration)
    }

    @Test func fadeCurveMenuAddsChangesAndRemovesAFade() {
        let (store, incoming) = makeStore()
        store.select([incoming])
        store.setSelectionFade(.end, curve: .linear)
        #expect(store.selectionFade(.end) == Fade(duration: ProjectStore.addedFadeDuration, curve: .linear))

        // A new curve keeps the length the handle set.
        store.setFade(.end, duration: Time(seconds: 3))
        store.setSelectionFade(.end, curve: .easeIn)
        #expect(store.selectionFade(.end) == Fade(duration: Time(seconds: 3), curve: .easeIn))

        store.setSelectionFade(.end, curve: nil)
        #expect(store.selectionFade(.end) == nil)
    }

    @Test func pullingClipsApartClearsTheCrossfade() {
        let (store, incoming) = makeStore()
        store.selectTransition(incoming)
        store.moveClip(incoming, to: Time(seconds: 25), target: .existing(store.project.tracks[0].id))
        #expect(store.selectedTransition == nil)
        #expect(store.activeTab != .transitions)
    }
}

/// The milestone's goal: crossfade two songs with an S-curve and hear it exactly as drawn.
/// Each side is measured alone by making the other side silent.
@MainActor
struct CrossfadeRenderTests {
    let sampleRate = 48_000.0
    let amplitude: Float = 0.5

    func makeTone(amplitude: Float) throws -> URL {
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

    /// Two 4-second clips on one track, overlapping from 2 s to 4 s with an S-curve.
    func render(outgoingIsTone: Bool, outgoingFadeOut: Fade = .none) async throws -> [Float] {
        let tone = try makeTone(amplitude: amplitude)
        let silence = try makeTone(amplitude: 0)
        let urls = outgoingIsTone ? [tone, silence] : [silence, tone]
        let assets = urls.map { url in
            Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Tone", kind: .audio, duration: Time(seconds: 4), hasAudio: true)
        }
        var project = Project()
        project.assets = assets
        project.defaultCrossfadeCurve = .sCurve
        project.tracks[0].clips = [
            Clip(assetID: assets[0].id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4), fadeOut: outgoingFadeOut),
            Clip(assetID: assets[1].id, start: Time(seconds: 2), sourceStart: .zero, duration: Time(seconds: 4)),
        ]
        #expect(project.crossfades(onTrack: 0).count == 1)

        let sources = Dictionary(uniqueKeysWithValues: zip(assets.map(\.id), urls.map { AVURLAsset(url: $0) }))
        let built = try await CompositionBuilder.build(project: project, assets: { sources[$0] })
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
        output.audioMix = built.audioMix

        var rendered: [Float] = []
        try await PCMReader.read(built.composition, output: output) { rendered.append(contentsOf: $0) }
        return rendered
    }

    /// The level around `time`, as a share of the tone's full level.
    func gain(_ samples: [Float], at time: Double) -> Double {
        let slice = samples[Int((time - 0.02) * sampleRate)..<Int((time + 0.02) * sampleRate)]
        let rms = (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
        return rms / (Double(amplitude) / 2.squareRoot())
    }

    @Test func incomingSongRisesAlongTheSCurve() async throws {
        let samples = try await render(outgoingIsTone: false)
        #expect(gain(samples, at: 1) < 0.001)
        #expect(abs(gain(samples, at: 2.5) - 0.15625) < 0.01)
        #expect(abs(gain(samples, at: 3) - 0.5) < 0.01)
        #expect(abs(gain(samples, at: 3.5) - 0.84375) < 0.01)
        #expect(abs(gain(samples, at: 5) - 1) < 0.01)
    }

    @Test func aFadeOutUnderTheCrossfadeIsNotHeard() async throws {
        // The outgoing clip's own 2-second fade out would deepen the dip; the crossfade plays alone.
        let samples = try await render(outgoingIsTone: true, outgoingFadeOut: Fade(duration: Time(seconds: 2), curve: .linear))
        #expect(abs(gain(samples, at: 2.5) - 0.84375) < 0.01)
        #expect(abs(gain(samples, at: 3) - 0.5) < 0.01)
        #expect(abs(gain(samples, at: 3.5) - 0.15625) < 0.01)
    }

    @Test func outgoingSongFallsAlongTheMirroredSCurve() async throws {
        let samples = try await render(outgoingIsTone: true)
        #expect(abs(gain(samples, at: 1) - 1) < 0.01)
        #expect(abs(gain(samples, at: 2.5) - 0.84375) < 0.01)
        #expect(abs(gain(samples, at: 3) - 0.5) < 0.01)
        #expect(abs(gain(samples, at: 3.5) - 0.15625) < 0.01)
        #expect(gain(samples, at: 5) < 0.001)
    }
}

/// Volume sliders put 0 dB in the middle, with silence at the left and +12 dB at the right.
struct DecibelSliderTests {
    @Test func zeroDecibelsSitsInTheMiddle() {
        #expect(DecibelSlider.position(ofGain: 1) == 0.5)
        #expect(DecibelSlider.position(ofGain: 0) == 0)
        #expect(abs(DecibelSlider.position(ofGain: pow(10, 12.0 / 20)) - 1) < 1e-9)
    }

    @Test func positionsRoundTrip() {
        for position in stride(from: 0.05, through: 1, by: 0.05) {
            #expect(abs(DecibelSlider.position(ofGain: DecibelSlider.gain(atPosition: position)) - position) < 1e-9)
        }
    }
}

/// Sliders catch on their detents, such as the default, when dragged near them.
struct SliderDetentTests {
    @Test func catchesTheNearestDetentWithinReach() {
        #expect(BoxSlider.detent(for: 0.02, among: [0], reach: 0.05) == 0)
        #expect(BoxSlider.detent(for: -0.04, among: [0], reach: 0.05) == 0)
        #expect(BoxSlider.detent(for: 88, among: [-90, 0, 90], reach: 3) == 90)
    }

    @Test func letsGoOutsideReach() {
        #expect(BoxSlider.detent(for: 0.06, among: [0], reach: 0.05) == nil)
        #expect(BoxSlider.detent(for: 45, among: [-90, 0, 90], reach: 3) == nil)
        #expect(BoxSlider.detent(for: 0.5, among: [], reach: 1) == nil)
    }

    @Test func speedCatchesAtTheUsualSpeeds() {
        // The speed slider works in powers of two; a drag near 150% lands on exactly 1.5.
        let stops = SpeedSection.usualSpeeds.map(log2)
        let caught = BoxSlider.detent(for: log2(1.47), among: stops, reach: 0.05)
        #expect(caught.map(SpeedSection.speed(atSliderValue:)) == 1.5)
        #expect(SpeedSection.usualSpeeds.map { SpeedSection.speed(atSliderValue: log2($0)) } == [0.5, 1, 1.5, 2])
        #expect(BoxSlider.detent(for: log2(1.25), among: stops, reach: 0.05) == nil)
    }
}
