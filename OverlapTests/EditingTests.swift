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

/// Resizing the canvas from the preview: what's on it keeps its place and size.
struct CanvasResizeTests {
    let square = Asset(id: UUID(), fileName: "s.mov", displayName: "s.mov", kind: .video, duration: Time(seconds: 5), hasAudio: false,
                       pixelWidth: 1080, pixelHeight: 1080, frameRate: 30)

    /// Where a media clip shows, in canvas pixels: its center and width.
    func shown(_ clip: Clip, on canvas: Canvas) -> (x: Double, y: Double, width: Double) {
        let fit = min(Double(canvas.width) / 1080, Double(canvas.height) / 1080)
        return (Double(canvas.width) / 2 + clip.visual.x * Double(canvas.width), Double(canvas.height) / 2 + clip.visual.y * Double(canvas.height),
                1080 * fit * clip.visual.scale)
    }

    func project() -> Project {
        var project = Project()
        project.assets = [square]
        project.canvas = Canvas(width: 1920, height: 1080)
        project.canvasAspect = .wide
        var clip = Clip(assetID: square.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))
        // Against the left edge, as tall as the canvas.
        clip.visual.x = (540 - 960) / 1920.0
        project.tracks[0].clips = [clip]
        return project
    }

    @Test func cuttingTheRightSideKeepsThePictureWhereItIs() throws {
        var project = project()
        project.resizeCanvas(to: CGRect(x: 0, y: 0, width: 1080, height: 1080))
        let canvas = try #require(project.canvas)
        #expect(canvas.width == 1080 && canvas.height == 1080)
        #expect(project.canvasAspect == .custom)
        let after = shown(project.tracks[0].clips[0], on: canvas)
        #expect(abs(after.x - 540) < 1e-6 && abs(after.y - 540) < 1e-6 && abs(after.width - 1080) < 1e-6)
    }

    @Test func growingBothSidesKeepsThePictureWhereItIs() throws {
        var project = project()
        let before = shown(project.tracks[0].clips[0], on: try #require(project.canvas))
        project.resizeCanvas(to: CGRect(x: -200, y: -100, width: 2320, height: 1280))
        let canvas = try #require(project.canvas)
        let after = shown(project.tracks[0].clips[0], on: canvas)
        // The same place, measured from the old canvas's corner, and the same size.
        #expect(abs(after.x - 200 - before.x) < 1e-6 && abs(after.y - 100 - before.y) < 1e-6)
        #expect(abs(after.width - before.width) < 1e-6)
    }

    @Test func textKeepsItsSize() throws {
        var project = project()
        let title = project.addTitle(Title(text: "Hi"), at: .zero, target: .existing(project.tracks[0].id))
        project.resizeCanvas(to: CGRect(x: 0, y: 0, width: 1920, height: 2160))
        // Text is drawn in proportion to the canvas's height, so twice the height takes half the scale.
        #expect(abs((project.clip(title.id)?.visual.scale ?? 0) - 0.5) < 1e-9)
    }
}

/// Selecting clips opens the tab that edits them, and clearing the selection goes back.
@MainActor
struct TabFollowsSelectionTests {
    let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Interview.mov", kind: .video, duration: Time(seconds: 10),
                      hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 20), hasAudio: true)

    func makeStore() -> (ProjectStore, video: UUID, song: UUID) {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var videoClip = UUID()
        var songClip = UUID()
        store.apply("Import Media") { [video, song] project in
            project.assets = [video, song]
            videoClip = project.addClip(asset: video.id, at: .zero, preferredTrack: 0)?.id ?? videoClip
            songClip = project.addClip(asset: song.id, at: Time(seconds: 30), preferredTrack: 0)?.id ?? songClip
        }
        return (store, videoClip, songClip)
    }

    @Test func selectingFromAProjectTabOpensTheClipsTabAndClearingGoesBack() {
        let (store, video, song) = makeStore()
        store.showTab(.media)
        store.select([video])
        #expect(store.activeTab == .video)
        store.select([song])
        #expect(store.activeTab == .audio)
        store.select([])
        #expect(store.activeTab == .media)
    }

    @Test func aTabThatEditsTheSelectionStays() {
        let (store, video, _) = makeStore()
        store.showTab(.audio)
        store.select([video])
        #expect(store.activeTab == .audio)
    }

    @Test func aTabYouPickStaysWhenTheSelectionClears() {
        let (store, video, _) = makeStore()
        store.select([video])
        store.showTab(.audio)
        store.select([])
        #expect(store.activeTab == .audio)
    }

    @Test func deletingTheSelectionGoesBack() {
        let (store, video, _) = makeStore()
        store.select([video])
        #expect(store.activeTab == .video)
        store.deleteSelection()
        #expect(store.activeTab == .canvas)
    }
}

/// Choosing a background frames the pictures on it; None takes the frame away.
struct BackgroundFrameTests {
    @Test func theFirstBackgroundFramesThePictures() {
        var project = Project()
        #expect(project.frame == nil)
        project.setBackground(BackgroundFill.gradients[0])
        #expect(project.frame == .standard)
    }

    @Test func aChangedFrameStaysAcrossBackgrounds() {
        var project = Project()
        project.setBackground(BackgroundFill.gradients[0])
        project.frame?.padding = 0.2
        project.setBackground(BackgroundFill.colors[0])
        #expect(project.frame?.padding == 0.2)
    }

    @Test func noneTakesTheFrameAway() {
        var project = Project()
        project.setBackground(BackgroundFill.gradients[0])
        project.setBackground(nil)
        #expect(project.frame == nil)
        #expect(project.background == nil)
    }

    @Test func removingTheWallpaperTakesTheFrameAway() {
        var project = Project()
        let image = Asset(id: UUID(), fileName: "Sonoma.heic", displayName: "Sonoma.heic", kind: .image, duration: .zero,
                          hasAudio: false, pixelWidth: 3840, pixelHeight: 2160, frameRate: nil)
        project.assets = [image]
        project.setBackground(.wallpaper(image.id))
        project.removeAsset(image.id)
        #expect(project.background == nil)
        #expect(project.frame == nil)
    }

    @Test func aZeroFrameFromAnOlderProjectReadsAsNone() throws {
        var project = Project()
        project.background = .color(.white)
        project.frame = PictureFrame()
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(reopened.frame == nil)
        var framed = project
        framed.frame = .standard
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(framed)).frame == .standard)
    }

    @Test func theFrameRateFollowsTheFirstVideoRoundedToACommonOne() {
        var project = Project()
        #expect(project.frameRate == 30)
        // A screen recording's uneven rate comes out even.
        let recording = Asset(id: UUID(), fileName: "r.mov", displayName: "r.mov", kind: .video, duration: Time(seconds: 5),
                              hasAudio: false, pixelWidth: 1920, pixelHeight: 1080, frameRate: 58.7)
        project.assets = [recording]
        project.tracks[0].clips = [Clip(assetID: recording.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))]
        #expect(project.frameRate == 59.94)
        project.assets[0].frameRate = 29.97002997
        #expect(project.frameRate == 29.97)
        project.assets[0].frameRate = 120
        #expect(project.frameRate == 60)
    }

    @Test func cssColorsComeOutAsBrowsersShowThem() {
        let red = RGBA(hue: 0, saturation: 100, lightness: 50)
        #expect(red.isNear(RGBA(red: 1, green: 0, blue: 0)))
        #expect(RGBA(hue: 120, saturation: 100, lightness: 25).isNear(RGBA(red: 0, green: 0.5, blue: 0)))
        #expect(RGBA(hue: 240, saturation: 100, lightness: 50).isNear(RGBA(red: 0, green: 0, blue: 1)))
        #expect(RGBA(hue: 304, saturation: 0, lightness: 100).isNear(.white))
        #expect(RGBA(hue: 182, saturation: 100, lightness: 56).isNear(RGBA(hex: 0x1FF8FF)))
    }
}
