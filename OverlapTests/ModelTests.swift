import CoreMedia
import Foundation
import Testing
@testable import Overlap

struct TimeTests {
    @Test func secondsRoundTrip() {
        #expect(Time(seconds: 1.5).seconds == 1.5)
    }

    @Test func ntscFrameIsExact() {
        // One 29.97 fps frame is a whole number of flicks, so frame math never drifts.
        let frame = Time(CMTime(value: 1001, timescale: 30000))
        #expect(frame.ticks == 23_543_520)
        #expect(Time(frame.cmTime) == frame)
    }

    @Test func clockFormat() {
        #expect(Time(seconds: 65.7).clock == "01:05")
        #expect(Time(seconds: 3725).clock == "1:02:05")
    }
}

struct CurveTests {
    static let all = Curve.presets + [.custom(x1: 0.42, y1: 0, x2: 0.58, y2: 1)]

    @Test(arguments: all)
    func startsSilentAndEndsFull(curve: Curve) {
        #expect(abs(curve.gain(at: 0)) < 1e-9)
        #expect(abs(curve.gain(at: 1) - 1) < 1e-9)
    }

    @Test(arguments: all)
    func neverDecreases(curve: Curve) {
        var previous = 0.0
        for step in 0...100 {
            let gain = curve.gain(at: Double(step) / 100)
            #expect(gain >= previous - 1e-9)
            previous = gain
        }
    }

    @Test func equalPowerKeepsLoudnessSteady() {
        for step in 0...10 {
            let t = Double(step) / 10
            let incoming = Curve.equalPower.gain(at: t)
            let outgoing = Curve.equalPower.gain(at: 1 - t)
            #expect(abs(incoming * incoming + outgoing * outgoing - 1) < 1e-9)
        }
    }

    @Test func straightBezierIsLinear() {
        let curve = Curve.custom(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        for step in 0...10 {
            let t = Double(step) / 10
            #expect(abs(curve.gain(at: t) - t) < 1e-6)
        }
    }
}

struct ProjectEditingTests {
    let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Interview.mov", kind: .video, duration: Time(seconds: 10),
                      hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 20),
                     hasAudio: true, sampleRate: 48_000, channelCount: 2)

    func makeProject() -> Project {
        var project = Project()
        project.assets = [video, song]
        return project
    }

    @Test func clipLandsOnFreeTrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 1)
    }

    @Test func droppingOverAWholeClipMovesUpATrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 1)
        #expect(project.tracks[1].clips.count == 1)
    }

    @Test func touchingClipsShareATrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: song.id, at: Time(seconds: 20), preferredTrack: 0)
        #expect(project.tracks[0].clips.count == 2)
    }

    @Test func dropAboveTopTrackAddsATrack() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: project.tracks.count)
        #expect(project.tracks.count == 4)
        #expect(project.tracks[3].clips.count == 1)
    }

    @Test func firstVideoSetsTheCanvas() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        #expect(project.canvas == nil)
        #expect(!project.hasVisualClips)
        project.addClip(asset: video.id, at: .zero, preferredTrack: 1)
        #expect(project.canvas == Canvas(width: 1920, height: 1080, frameRate: 30))
        #expect(project.hasVisualClips)
    }

    @Test func moveAcrossTracks() throws {
        var project = makeProject()
        let added = project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        let clip = try #require(added)
        project.moveClip(clip.id, to: Time(seconds: 3), preferredTrack: 2)
        #expect(project.tracks[0].clips.isEmpty)
        #expect(project.tracks[2].clips.first?.start == Time(seconds: 3))
    }

    @Test func reorderingTracksKeepsTheirClips() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        let bottom = project.tracks[0].id
        project.moveTrack(from: 0, to: 2)
        #expect(project.tracks.map(\.name) == ["Track 2", "Track 3", "Track 1"])
        #expect(project.tracks[2].id == bottom)
        #expect(project.tracks[2].clips.count == 1)
    }

    @Test func emptyTracksAreRemoved() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 1)
        project.normalizeTracks()
        #expect(project.tracks.map(\.clips.count) == [1])

        project.addClip(asset: video.id, at: .zero, preferredTrack: project.tracks.count)
        project.removeClips(Set(project.tracks[0].clips.map(\.id)))
        project.normalizeTracks()
        #expect(project.tracks.count == 1)
        #expect(project.asset(project.tracks[0].clips[0].assetID)?.kind == .video)
    }

    @Test func dropBelowBottomTrackAddsATrackUnderneath() {
        var project = makeProject()
        project.addClip(asset: video.id, at: .zero, preferredTrack: 0)
        project.normalizeTracks()
        project.addClip(asset: song.id, at: .zero, preferredTrack: Project.newBottomTrack)
        #expect(project.tracks.count == 2)
        #expect(project.asset(project.tracks[0].clips[0].assetID)?.kind == .audio)
        #expect(project.asset(project.tracks[1].clips[0].assetID)?.kind == .video)
    }

    @Test func placingOnANewTrackInsertsItBetweenOthers() throws {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: video.id, at: .zero, preferredTrack: 1)
        project.normalizeTracks()
        let added = project.addClip(asset: song.id, at: Time(seconds: 30), target: .new(at: 1))
        let clip = try #require(added)
        #expect(project.tracks.count == 3)
        #expect(project.tracks[1].clips.map(\.id) == [clip.id])

        // Moving it onto an existing track where it fits keeps that track.
        project.moveClip(clip.id, to: Time(seconds: 30), target: .existing(project.tracks[2].id))
        project.normalizeTracks()
        #expect(project.tracks.map(\.clips.count) == [1, 2])
    }

    @Test func removingAnAssetRemovesItsClips() {
        var project = makeProject()
        project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        project.addClip(asset: video.id, at: .zero, preferredTrack: 1)
        project.removeAsset(song.id)
        #expect(project.assets.map(\.id) == [video.id])
        #expect(project.tracks.flatMap(\.clips).count == 1)
    }

    @Test func savesAndLoadsUnchanged() throws {
        var project = makeProject()
        let added = project.addClip(asset: song.id, at: Time(seconds: 1), preferredTrack: 0)
        let clip = try #require(added)
        project.moveClip(clip.id, to: Time(seconds: 2), preferredTrack: 0)
        project.tracks[0].clips[0].fadeIn = Fade(duration: Time(seconds: 1), curve: .custom(x1: 0.2, y1: 0.1, x2: 0.8, y2: 0.9))
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
    }
}

struct GainProgramTests {
    let program: GainProgram = {
        let clip = Clip(assetID: UUID(), start: Time(seconds: 2), sourceStart: .zero, duration: Time(seconds: 4), volume: 0.5)
        let fade = Fade(duration: Time(seconds: 1), curve: .linear)
        return GainProgram(segments: [GainSegment(clip: clip, fadeIn: fade, fadeOut: fade)])
    }()

    @Test func silentOutsideClips() {
        #expect(program.gain(at: 1.9) == 0)
        #expect(program.gain(at: 6.1) == 0)
    }

    @Test func followsFadesAndVolume() {
        #expect(abs(program.gain(at: 2.5) - 0.25) < 1e-9)
        #expect(abs(program.gain(at: 4) - 0.5) < 1e-9)
        #expect(abs(program.gain(at: 5.5) - 0.25) < 1e-9)
    }

    @Test func fadesNeverExceedHalfTheClip() {
        let clip = Clip(assetID: UUID(), start: .zero, sourceStart: .zero, duration: Time(seconds: 2))
        let segment = GainSegment(clip: clip, fadeIn: Fade(duration: Time(seconds: 5), curve: .linear), fadeOut: .none)
        #expect(segment.fadeIn == 1)
    }
}

struct MediaImporterTests {
    @Test func cloneCopiesTheBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = folder.appending(path: "source.wav")
        let destination = folder.appending(path: "Media/copy.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("overlap".utf8).write(to: source)
        try MediaImporter.cloneFile(source, to: destination)
        #expect(try Data(contentsOf: destination) == Data("overlap".utf8))
    }

    @Test func recognizesSupportedFormats() {
        #expect(MediaImporter.isSupported(URL(filePath: "/a/Interview.mov")))
        #expect(MediaImporter.isSupported(URL(filePath: "/a/Theme.m4a")))
        #expect(MediaImporter.isSupported(URL(filePath: "/a/Voice.wav")))
        #expect(!MediaImporter.isSupported(URL(filePath: "/a/Notes.txt")))
    }
}

struct TimelineDragTests {
    @Test func payloadRoundTrips() {
        let id = UUID()
        #expect(TimelineDrag.assetID(from: TimelineDrag.payload(for: id)) == id)
    }

    /// If the payload read as a URL, the Media tab's file drop target would light up while dragging out of it.
    @Test func payloadIsNotAURL() {
        let provider = NSItemProvider(object: TimelineDrag.payload(for: UUID()) as NSString)
        #expect(!provider.canLoadObject(ofClass: URL.self))
        #expect(provider.registeredTypeIdentifiers == ["public.utf8-plain-text"])
    }
}
