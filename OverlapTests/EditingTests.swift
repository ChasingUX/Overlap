import Foundation
import Testing
@testable import Overlap

struct EditingTests {
    let interview = Asset(id: UUID(), fileName: "i.mov", displayName: "Interview.mov", kind: .video, duration: Time(seconds: 300),
                          hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 20), hasAudio: true)

    /// A one-track project with a song clip starting at each time.
    func songs(at starts: [Double]) -> Project {
        var project = Project()
        project.assets = [interview, song]
        project.tracks = [Track(name: "Track 1")]
        for start in starts {
            project.addClip(asset: song.id, at: Time(seconds: start), preferredTrack: 0)
        }
        return project
    }

    func seconds(_ time: Time?) -> Double? {
        time.map { ($0.seconds * 1000).rounded() / 1000 }
    }

    @Test func trimStaysInsideTheSourceAndClearOfNeighbors() throws {
        var project = songs(at: [10, 40])
        let id = project.tracks[0].clips[0].id

        // The source starts at its first frame, so the start can't move earlier.
        project.trim(id, edge: .start, to: Time(seconds: 2))
        #expect(seconds(project.clip(id)?.start) == 10)

        project.trim(id, edge: .start, to: Time(seconds: 15))
        let trimmed = try #require(project.clip(id))
        #expect(seconds(trimmed.start) == 15)
        #expect(seconds(trimmed.sourceStart) == 5)
        #expect(seconds(trimmed.duration) == 15)

        // The end stops where the source runs out (5 s in + 15 s = 20 s).
        project.trim(id, edge: .end, to: Time(seconds: 50))
        #expect(seconds(project.clip(id)?.end) == 30)
    }

    @Test func trimStopsAtTheNextClip() {
        var project = songs(at: [0, 20])
        let first = project.tracks[0].clips[0].id
        project.trim(first, edge: .start, to: Time(seconds: 5))
        project.trim(project.tracks[0].clips[1].id, edge: .start, to: Time(seconds: 10))
        // The second clip's start can't move into the first.
        #expect(seconds(project.tracks[0].clips[1].start) == 20)
    }

    @Test func rippleTrimMovesTheClipsAfter() {
        var project = songs(at: [0, 20])
        let first = project.tracks[0].clips[0].id
        project.trim(first, edge: .end, to: Time(seconds: 15), ripple: true)
        #expect(seconds(project.tracks[0].clips[1].start) == 15)

        // Rippling the start keeps the clip where it is and pulls the next one in.
        project.trim(first, edge: .start, to: Time(seconds: 5), ripple: true)
        #expect(seconds(project.clip(first)?.start) == 0)
        #expect(seconds(project.clip(first)?.sourceStart) == 5)
        #expect(seconds(project.tracks[0].clips[1].start) == 10)
    }

    @Test func splitMakesTwoClipsThatPlayOn() {
        var project = songs(at: [0])
        project.split(at: Time(seconds: 8))
        let clips = project.tracks[0].clips
        #expect(clips.count == 2)
        #expect(seconds(clips[0].duration) == 8)
        #expect(seconds(clips[1].start) == 8)
        #expect(seconds(clips[1].sourceStart) == 8)
        #expect(seconds(clips[1].duration) == 12)
    }

    @Test func splitAccountsForSpeed() {
        var project = songs(at: [0])
        project.setSpeed(2, for: [project.tracks[0].clips[0].id])
        project.split(at: Time(seconds: 4))
        // 4 s on the timeline at 2× is 8 s into the source.
        #expect(seconds(project.tracks[0].clips[1].sourceStart) == 8)
    }

    @Test func deleteAndCloseGapPullsLaterClipsBack() {
        var project = songs(at: [0, 20, 40])
        project.removeClips([project.tracks[0].clips[1].id], closingGaps: true)
        #expect(project.tracks[0].clips.map { seconds($0.start) } == [0, 20])
    }

    @Test func speedChangesLengthAndMovesLaterClips() {
        var project = songs(at: [0, 20])
        let first = project.tracks[0].clips[0].id
        project.setSpeed(2, for: [first])
        #expect(seconds(project.clip(first)?.duration) == 10)
        #expect(seconds(project.tracks[0].clips[1].start) == 10)

        project.setSpeed(0.5, for: [first])
        #expect(seconds(project.clip(first)?.duration) == 40)
        #expect(seconds(project.tracks[0].clips[1].start) == 40)
    }

    @Test func detachAudioSplitsPictureFromSound() throws {
        var project = Project()
        project.assets = [interview]
        project.tracks = [Track(name: "Track 1")]
        let added = project.addClip(asset: interview.id, at: .zero, preferredTrack: 0)
        let picture = try #require(added)
        let sounds = project.detachAudio([picture.id])

        #expect(project.tracks.count == 2)
        let sound = try #require(project.clip(sounds[0]))
        let detached = try #require(project.clip(picture.id))
        #expect(project.location(ofClip: sound.id)?.track == 0)
        #expect(project.location(ofClip: picture.id)?.track == 1)
        #expect(project.showsPicture(detached) && !project.playsSound(detached))
        #expect(!project.showsPicture(sound) && project.playsSound(sound))
        #expect(sound.range == detached.range)
    }

    @Test func pasteKeepsSpacingAndTracks() throws {
        var project = songs(at: [0])
        project.addClip(asset: song.id, at: Time(seconds: 5), preferredTrack: 1)
        let items = project.tracks.map { ClipboardItem(clip: $0.clips[0], trackID: $0.id) }
        let pasted = project.paste(items, at: Time(seconds: 100))
        #expect(pasted.count == 2)
        #expect(project.tracks.map(\.clips.count) == [2, 2])
        #expect(seconds(project.clip(pasted[0])?.start) == 100)
        #expect(seconds(project.clip(pasted[1])?.start) == 105)
    }

    @Test func lockedTracksRefuseEdits() {
        var project = songs(at: [0])
        project.tracks[0].isLocked = true
        let id = project.tracks[0].clips[0].id
        project.split(at: Time(seconds: 5))
        project.trim(id, edge: .end, to: Time(seconds: 5))
        project.setSpeed(2, for: [id])
        #expect(project.tracks[0].clips.count == 1)
        #expect(seconds(project.clip(id)?.duration) == 20)
        #expect(!project.isFree(track: 0, range: TimeRange(start: Time(seconds: 50), duration: Time(seconds: 1))))
    }

    @Test func soloLeavesOtherTracksOut() {
        var project = songs(at: [0])
        project.addClip(asset: song.id, at: .zero, preferredTrack: 1)
        project.tracks[1].isSoloed = true
        #expect(project.isActive(project.tracks[1]))
        #expect(!project.isActive(project.tracks[0]))
        project.tracks[1].isMuted = true
        #expect(!project.isActive(project.tracks[1]))
    }

    @Test func projectsFromMilestoneOneStillOpen() throws {
        // A clip saved before speed and detached audio existed.
        let clip = songs(at: [3]).tracks[0].clips[0]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        for key in ["speed", "preservesPitch", "usesVideo", "usesAudio"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == clip)
    }
}

/// The milestone's goal: cut a 5-minute interview down to 2 minutes using only the keyboard commands.
@MainActor
struct KeyboardEditingTests {
    @Test func cutAFiveMinuteInterviewDownToTwo() throws {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let interview = Asset(id: UUID(), fileName: "i.mov", displayName: "Interview.mov", kind: .video, duration: Time(seconds: 300),
                              hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
        store.apply("Import Media") { project in
            project.assets = [interview]
            project.addClip(asset: interview.id, at: .zero, preferredTrack: 0)
        }

        // Each cut: move the playhead, ⌘B, move again, ⌘B, C to select the middle piece, ⇧Delete.
        func cut(from start: Double, to end: Double) {
            store.select([])
            store.playback.seek(to: Time(seconds: start))
            store.splitAtPlayhead()
            store.playback.seek(to: Time(seconds: end))
            store.splitAtPlayhead()
            store.playback.seek(to: Time(seconds: start + 1))
            store.selectClipAtPlayhead()
            store.deleteSelection(closingGaps: true)
        }
        cut(from: 180, to: 300)
        cut(from: 60, to: 120)

        let clips = try #require(store.project.tracks.first?.clips)
        #expect(store.project.duration == Time(seconds: 120))
        #expect(clips.map { ($0.start.seconds, $0.sourceStart.seconds, $0.duration.seconds) }.map { "\($0)" }
            == ["(0.0, 0.0, 60.0)", "(60.0, 120.0, 60.0)"])
    }
}

/// The Canvas tab's shape and size.
@MainActor
struct CanvasSizeTests {
    func makeStore() -> ProjectStore {
        ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func aNewShapeKeepsTheResolution() {
        let store = makeStore()
        store.setCanvasAspect(.wide)
        #expect(store.project.canvas.map { [$0.width, $0.height] } == [1920, 1080])
        store.setCanvasSize(width: 3840, height: 2160)
        #expect(store.project.canvasAspect == .wide)
        store.setCanvasAspect(.tall)
        #expect(store.project.canvas.map { [$0.width, $0.height] } == [2160, 3840])
        store.setCanvasAspect(.standard)
        #expect(store.project.canvas.map { [$0.width, $0.height] } == [2880, 2160])
    }

    @Test func sizingAutoChoosesTheShapeItHas() {
        let store = makeStore()
        store.setCanvasAspect(.auto)
        store.setCanvasSize(width: 1080, height: 1080)
        #expect(store.project.canvasAspect == .square)
        store.setCanvasAspect(.auto)
        store.setCanvasSize(width: 2000, height: 1001)
        #expect(store.project.canvasAspect == .custom)
        #expect(store.project.canvas.map { [$0.width, $0.height] } == [2000, 1000])
    }
}
