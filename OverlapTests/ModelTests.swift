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

    @Test func duplicatingLeavesTheClipAndPlacesACopy() throws {
        var project = makeProject()
        let added = project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        var clip = try #require(added)
        project.changeVisual(of: [clip.id]) { $0.opacity = 0.5 }
        clip = try #require(project.clip(clip.id))
        let duplicated = project.duplicateClip(clip.id, to: clip.end, target: .existing(project.tracks[0].id))
        let copyID = try #require(duplicated)
        #expect(copyID != clip.id)
        #expect(project.tracks[0].clips.map(\.start) == [.zero, clip.end])
        let copy = try #require(project.clip(copyID))
        #expect(copy.visual == clip.visual)
        #expect(copy.duration == clip.duration)
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

/// Images, text and background clips: their lengths, trims and what they need.
struct StillClipTests {
    let image = Asset(id: UUID(), fileName: "p.png", displayName: "Photo.png", kind: .image, duration: .zero,
                      hasAudio: false, pixelWidth: 4000, pixelHeight: 3000)

    @Test func imagesStartAtFiveSecondsAndTrimToAnyLength() throws {
        var project = Project()
        project.assets = [image]
        let added = project.addClip(asset: image.id, at: Time(seconds: 2), preferredTrack: 0)
        let clip = try #require(added)
        #expect(clip.duration == Clip.stillDuration)
        // An image has no source to stay inside: it stretches both ways.
        project.trim(clip.id, edge: .end, to: Time(seconds: 60))
        project.trim(clip.id, edge: .start, to: .zero)
        #expect(project.clip(clip.id)?.range == TimeRange(start: .zero, duration: Time(seconds: 60)))
        #expect(project.canvas == Project.defaultCanvas)
    }

    @Test func textAndBackgroundClipsShowPictures() {
        var project = Project()
        let title = project.addTitle(TitleStyle.lowerThird.title, visual: TitleStyle.lowerThird.visual, at: .zero, target: .existing(project.tracks[0].id))
        let background = project.addBackground(BackgroundFill.gradients[0], at: .zero, target: .existing(project.tracks[1].id))
        #expect(project.showsPicture(title) && project.showsPicture(background))
        #expect(!project.playsSound(title) && !project.playsSound(background))
        #expect(project.isPlaceable(title) && !project.isPlaceable(background))
        #expect(project.hasVisualClips)
        #expect(title.visual.x == TitleStyle.lowerThird.visual.x)
    }

    @Test func removingAWallpaperClearsTheBackground() {
        var project = Project()
        project.assets = [image]
        project.background = .wallpaper(image.id)
        project.addBackground(.wallpaper(image.id), at: .zero, target: .existing(project.tracks[0].id))
        project.removeAsset(image.id)
        #expect(project.background == nil)
        #expect(project.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func projectsFromMilestoneThreeStillOpen() throws {
        var project = Project()
        project.addTitle(Title(text: "Hi"), at: .zero, target: .existing(project.tracks[0].id))
        let plain = Clip(assetID: UUID(), start: .zero, sourceStart: .zero, duration: Time(seconds: 3))
        project.tracks[1].clips = [plain]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        for key in ["canvasAspect", "background"] { json.removeValue(forKey: key) }
        // A clip saved before pictures could be placed.
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        var clips = try #require(tracks[1]["clips"] as? [[String: Any]])
        for key in ["visual", "title", "fill", "crossfadeVideoStyle"] { clips[0].removeValue(forKey: key) }
        tracks[1]["clips"] = clips
        json["tracks"] = tracks
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.canvasAspect == .auto)
        #expect(decoded.background == nil)
        #expect(decoded.tracks[1].clips[0] == plain)
        #expect(decoded.tracks[0].clips[0].title?.text == "Hi")
    }

    @Test func aColorLikeABuiltInOneIsntKeptAgain() {
        // The eyedropper picking the built-in near-black, one step off.
        let picked = RGBA(red: 11 / 255, green: 11 / 255, blue: 16 / 255)
        let (kept, use) = WallpaperLibrary.remembering(picked, replacing: nil, in: [])
        #expect(kept.isEmpty)
        #expect(use == RGBA(hex: 0x0C0B10))
    }

    @Test func aColorLikeAKeptOneUsesThatOne() {
        let coral = RGBA(hex: 0xEF5A6F)
        let purple = RGBA(hex: 0x4C1D95)
        let (kept, use) = WallpaperLibrary.remembering(RGBA(hex: 0xF05A6E), replacing: nil, in: [purple, coral])
        #expect(use == coral)
        #expect(kept == [coral, purple])
        // A new color goes first; adjusting it while picking replaces it rather than adding another.
        let first = WallpaperLibrary.remembering(RGBA(hex: 0x336699), replacing: nil, in: kept)
        #expect(first.kept == [RGBA(hex: 0x336699), coral, purple])
        let adjusted = WallpaperLibrary.remembering(RGBA(hex: 0x3366CC), replacing: RGBA(hex: 0x336699), in: first.kept)
        #expect(adjusted.kept == [RGBA(hex: 0x3366CC), coral, purple])
    }

    @Test func nearCopiesKeptEarlierArentShown() {
        let gray = RGBA(hex: 0x9A9CA3)
        let kept = [RGBA(hex: 0x0B0B10), gray, RGBA(hex: 0x9B9CA3)]
        #expect(WallpaperLibrary.shown(kept) == [gray])
    }

    /// The Canvas tab had a whole-picture frame (padding, shadow and corners) until it was taken out. Projects saved
    /// with one still open, without it.
    @Test func projectsSavedWithAFrameStillOpen() throws {
        var project = Project()
        project.background = .color(RGBA(red: 0, green: 0, blue: 1))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json["frame"] = ["padding": 0.1, "shadow": 40, "corners": 0.05]
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == project)
    }
}

/// Media whose sound is silence, as screen recordings without a microphone carry, counts as having none.
struct SilentSoundTests {
    @Test func aWaveformOfSilenceIsSilent() {
        #expect(Waveform(peaksPerSecond: 100, peaks: Array(repeating: 0, count: 870)).isSilent)
        #expect(Waveform(peaksPerSecond: 100, peaks: []).isSilent)
        #expect(!Waveform(peaksPerSecond: 100, peaks: [0, 0, 0.2, 0]).isSilent)
    }

    @Test func silentMediaPlaysNoSound() {
        var project = Project()
        let video = Asset(id: UUID(), fileName: "r.mov", displayName: "r.mov", kind: .video, duration: Time(seconds: 8), hasAudio: true)
        project.assets = [video]
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 8))
        project.tracks[0].clips = [clip]
        #expect(project.playsSound(clip))
        project.treatAsSilent([video.id])
        #expect(!project.playsSound(clip))
    }
}
