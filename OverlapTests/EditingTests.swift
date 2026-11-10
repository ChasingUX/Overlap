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

/// The Text tab's title look: readability, copying a look to every title, older titles, and new titles opening to type.
@MainActor
struct TitleLookTests {
    func makeStore() -> ProjectStore {
        ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func readabilityIsOneChoice() {
        var title = Title(text: "Hi")
        #expect(title.readability == .none)
        title.readability = .shadow
        #expect(title.shadow && title.backdrop == nil)
        title.readability = .plate
        #expect(!title.shadow && title.backdrop == Title.plate)
        // A plate keeps its color while it stays a plate.
        title.backdrop = .white
        title.readability = .plate
        #expect(title.backdrop == .white)
        title.readability = .none
        #expect(!title.shadow && title.backdrop == nil)
    }

    @Test func aLookCopiesItsFontColorReadabilityAndAnimationOnly() {
        let source = Title(text: "Source", fontFamily: TitleFont.serif, size: 120, weight: .heavy, color: RGBA(hex: 0xECB851),
                           alignment: .trailing, animationIn: .pop, animationOut: .slide, shadow: true)
        var other = Title(text: "Other", size: 40, alignment: .leading, backdrop: .white)
        other.takeLook(of: source)
        #expect(other.fontFamily == TitleFont.serif && other.weight == .heavy && other.color == source.color)
        #expect(other.readability == .shadow)
        #expect(other.animationIn == .pop && other.animationOut == .slide)
        #expect(other.text == "Other" && other.size == 40 && other.alignment == .leading)
    }

    @Test func titlesSavedBeforeShadowsOpen() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Title(text: "Old"))) as? [String: Any])
        json.removeValue(forKey: "shadow")
        let title = try JSONDecoder().decode(Title.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(title.text == "Old" && !title.shadow)
    }

    @Test func useForAllTitlesChangesTheOthers() {
        let store = makeStore()
        store.addTitleAtPlayhead(.centeredTitle)
        store.endEditingTitle(text: nil)
        store.addTitleAtPlayhead(.callout)
        store.endEditingTitle(text: nil)
        #expect(store.otherTitleCount == 1)
        store.setTitle("Change Font") { $0.fontFamily = TitleFont.mono }
        store.useLookForAllTitles()
        let titles = store.project.tracks.flatMap(\.clips).compactMap(\.title)
        #expect(titles.count == 2)
        #expect(titles.allSatisfy { $0.fontFamily == TitleFont.mono && $0.readability == .plate })
        #expect(Set(titles.map(\.text)) == ["Title", "Callout"])
    }

    @Test func aNewTitleOpensReadyToType() {
        let store = makeStore()
        store.addTitleAtPlayhead(.lowerThird)
        let id = try? #require(store.selection.first)
        #expect(store.editingTitleClip == id)
        store.endEditingTitle(text: "Jesse · Design")
        #expect(store.editingTitleClip == nil)
        #expect(store.project.tracks.flatMap(\.clips).compactMap(\.title).first?.text == "Jesse · Design")
    }

    @Test func alignmentFollowsWhereTheTitleSits() {
        #expect(TitleAlignment(position: -0.38) == .leading)
        #expect(TitleAlignment(position: 0.1) == .center)
        #expect(TitleAlignment(position: 0.33) == .trailing)
        let store = makeStore()
        for (style, alignment) in [(TitleStyle.lowerThird, TitleAlignment.leading), (.centeredTitle, .center), (.callout, .trailing)] {
            store.addTitleAtPlayhead(style)
            store.endEditingTitle(text: nil)
            #expect(store.selectedClips.first?.title?.alignment == alignment)
        }
        // Moving the callout into the left third lines it up on the left.
        store.setVisual("Move") { $0.x = -0.3 }
        #expect(store.selectedClips.first?.title?.alignment == .leading)
    }

    @Test func aTitleOnTheLeftKeepsItsLeftEdgeAsItsTextGrows() throws {
        let store = makeStore()
        store.addTitleAtPlayhead(.lowerThird)
        let canvas = try #require(store.project.canvas)
        let size = CGSize(width: canvas.width, height: canvas.height)
        func leftEdge() throws -> Double {
            let clip = try #require(store.selectedClips.first)
            let title = try #require(clip.title)
            let image = try #require(TitleRenderer.image(for: title, canvas: size))
            return clip.visual.x * size.width - Double(image.width) / 2 * clip.visual.scale
        }
        let before = try leftEdge()
        store.endEditingTitle(text: "Someone with a much longer name\nRole")
        #expect(abs(try leftEdge() - before) < 1)
        // A centered title keeps its middle instead.
        store.addTitleAtPlayhead(.centeredTitle)
        store.endEditingTitle(text: "A much longer title than before")
        #expect(store.selectedClips.first?.visual.x == 0)
    }

    @Test func theSystemDesignsAreTheirOwnFonts() {
        let system = TitleRenderer.font(for: Title(text: "A"), size: 40)
        for family in [TitleFont.rounded, TitleFont.serif, TitleFont.mono] {
            #expect(TitleRenderer.font(for: Title(text: "A", fontFamily: family), size: 40).fontName != system.fontName)
        }
        #expect(TitleFont.name(of: TitleFont.serif) == "New York")
        #expect(TitleFont.name(of: "") == "System")
    }
}

/// The Audio tab shows the mix's controls only when something on the timeline plays sound.
struct ProjectSoundTests {
    @Test func onlyClipsThatPlaySoundCount() {
        var project = Project()
        #expect(!project.hasSound)
        let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "s.m4a", kind: .audio, duration: Time(seconds: 5), hasAudio: true)
        let silent = Asset(id: UUID(), fileName: "v.mov", displayName: "v.mov", kind: .video, duration: Time(seconds: 5), hasAudio: false,
                           pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
        project.assets = [song, silent]
        project.tracks[0].clips = [Clip(assetID: silent.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))]
        #expect(!project.hasSound)
        project.tracks[1].clips = [Clip(assetID: song.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 5))]
        #expect(project.hasSound)
        // A song merely imported, not on the timeline, has nothing to mix.
        project.tracks[1].clips = []
        #expect(!project.hasSound)
    }
}

/// Zooms: where the view is over time, and how clips carry their zooms through edits.
struct ZoomTests {
    let zoom = Zoom(start: 2, duration: 3, x: 0.7, y: 0.3, scale: 2)

    @Test func aZoomEasesInHoldsAndEasesOut() {
        let state = { (t: Double) in ZoomPath.state(at: t, zooms: [zoom], animation: .smooth) }
        #expect(state(1.9) == .none)
        #expect(state(3.5) == ZoomState(x: 0.7, y: 0.3, scale: 2))
        // Halfway in, the magnification is halfway, in steps of magnification.
        #expect(abs(state(2.4).scale - sqrt(2)) < 0.01)
        #expect(state(4.9).scale < 1.2)
        #expect(state(5.1) == .none)
    }

    @Test func zoomsCloseTogetherPanAcross() {
        let next = Zoom(start: 5.3, duration: 3, x: 0.3, y: 0.7, scale: 2)
        let middle = ZoomPath.state(at: 5.15, zooms: [zoom, next], animation: .smooth)
        // In the gap the view stays zoomed in, between the two regions, rather than pulling back out.
        #expect(abs(middle.scale - 2) < 0.001)
        #expect(middle.x < 0.7 && middle.x > 0.3)
        // Farther apart, it pulls back out between them.
        let far = Zoom(start: 7, duration: 3, x: 0.3, y: 0.7, scale: 2)
        #expect(ZoomPath.state(at: 6, zooms: [zoom, far], animation: .smooth) == .none)
    }

    @Test func dynamicGoesALittlePastBeforeSettling() {
        let peak = stride(from: 0.0, through: 1, by: 0.01).map { ZoomAnimation.dynamic.ease($0) }.max() ?? 0
        #expect(peak > 1.03 && peak < 1.08)
        #expect(ZoomAnimation.smooth.ease(0.5) == 0.5)
        #expect(ZoomAnimation.dynamic.duration < ZoomAnimation.smooth.duration)
    }

    @Test func theViewStaysInsideThePicture() {
        let edge = Zoom(start: 0, duration: 3, x: 0.05, y: 0.98, scale: 2)
        let state = ZoomPath.state(at: 1.5, zooms: [edge], animation: .smooth)
        #expect(state.x == 0.25 && state.y == 0.75)
    }

    @Test func splittingGivesEachHalfItsZooms() {
        var project = Project()
        var clip = Clip(assetID: UUID(), start: Time(seconds: 10), sourceStart: Time(seconds: 1), duration: Time(seconds: 10))
        clip.zooms = [Zoom(start: 2, duration: 2), Zoom(start: 5, duration: 3), Zoom(start: 9, duration: 1)]
        project.tracks[0].clips = [clip]
        // The cut lands at source second 6, inside the middle zoom.
        _ = project.split(at: Time(seconds: 15))
        let halves = project.tracks[0].clips
        #expect(halves[0].zooms.map(\.start) == [2, 5])
        #expect(halves[1].zooms.map(\.start) == [5, 9])
        #expect(halves[0].zooms[1].id != halves[1].zooms[0].id)
    }

    @Test func clipsSavedBeforeZoomsOpen() throws {
        let clip = Clip(assetID: UUID(), start: .zero, sourceStart: .zero, duration: Time(seconds: 1))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        json.removeValue(forKey: "zooms")
        #expect(try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: json)).zooms.isEmpty)
    }
}
