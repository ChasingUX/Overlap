import AppKit
import AVFoundation
import Observation

enum PanelTab: Int, CaseIterable, Identifiable {
    /// In the rail's order, which is also the View menu's: ⌘1 is Canvas. Transcript shows once a video is on the
    /// timeline. Transitions only shows while a crossfade is selected and Zoom while a zoom is, at the bottom, so
    /// nothing moves when they come and go.
    case canvas = 1, video, audio, text, transcript, media, transitions, zoom

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .media: "Media"
        case .canvas: "Canvas"
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        case .transcript: "Transcript"
        case .transitions: "Transitions"
        case .zoom: "Zoom"
        }
    }

    var icon: AppIcon {
        switch self {
        case .media: .media
        case .canvas: .canvas
        case .video: .video
        case .audio: .audio
        case .text: .text
        case .transcript: .transcript
        case .transitions: .transitions
        case .zoom: .zoom
        }
    }

    /// Tabs that show only while something of theirs is selected.
    var isContextual: Bool { self == .transitions || self == .zoom }

    /// Project tabs always have content; clip tabs edit the selection.
    var isProjectTab: Bool { self == .media || self == .canvas || self == .transcript }
}

/// A short note at the bottom of the window, as when an export finishes or fails.
struct Toast: Identifiable, Equatable {
    enum Kind {
        case done
        case failed
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    /// A file it can show in Finder.
    var file: URL?

    static let doneDuration = Duration.seconds(6)
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct PendingImport: Identifiable {
    let id = UUID()
    var name: String
}

/// The live state of one open project: the model, selection, playback and media caches.
@MainActor
@Observable
final class ProjectStore {
    private(set) var project: Project
    /// The project as it plays and shows: with each captions track's captions made from the transcript. Playback,
    /// export, the timeline and the preview's handles all draw this.
    private(set) var shownProject: Project
    private(set) var selection: Set<UUID> = []
    /// The panel shown. Selecting clips opens the tab that edits them, and clearing the selection goes back to the
    /// tab that left, unless you picked a tab yourself in between.
    var activeTab: PanelTab = .canvas
    /// The project tab selecting clips switched away from, to go back to once nothing is selected.
    @ObservationIgnored private var tabBeforeSelection: PanelTab?
    var isPanelVisible = true
    var pixelsPerSecond: Double = 40
    var timelineViewportWidth: Double = 800
    private(set) var pendingImports: [PendingImport] = []
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var filmstrips: [UUID: Filmstrip] = [:]
    private(set) var waveforms: [UUID: Waveform] = [:]
    /// What recordings look like with Isolate voice on, worked out once one of their clips turns it on.
    private(set) var isolatedWaveforms: [UUID: Waveform] = [:]
    var alert: AlertMessage?
    var assetPendingRemoval: Asset?
    /// The document's name, shown in the title bar.
    var windowTitle = "Untitled"
    /// Whether changes are waiting for the project's autosave, shown as "Saving…" beside its name.
    private(set) var isSaving = false
    /// Set by the document, which autosaves shortly after each change.
    @ObservationIgnored var changed: (() -> Void)?

    /// The document finished saving; `unsaved` is whether anything changed meanwhile.
    func savingFinished(unsaved: Bool) {
        isSaving = unsaved
    }
    /// Set by the window controller, which owns the document that does the renaming.
    @ObservationIgnored var renameHandler: ((String) -> Void)?

    func renameDocument(to name: String) {
        renameHandler?(name)
    }

    /// Renaming from the title bar. The window controller ends the edit when you click anywhere else.
    var isEditingTitle = false
    var titleDraft = ""

    func beginTitleEdit() {
        titleDraft = windowTitle
        isEditingTitle = true
    }

    func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        renameDocument(to: titleDraft)
    }

    func cancelTitleEdit() {
        isEditingTitle = false
    }
    var prototypeFades = false {
        didSet { rebuildPlayback() }
    }

    let playback = PlaybackController()
    /// Where asset copies live right now: a staging folder until the first save, then the package's `Media/`.
    var mediaDirectory: URL

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var avAssets: [UUID: AVURLAsset] = [:]
    @ObservationIgnored private var analyzing: Set<UUID> = []
    @ObservationIgnored private var isolating: Set<UUID> = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// The layout of the composition the player has, to tell edits that only change how things look and sound.
    @ObservationIgnored private var installedLayout: CompositionBuilder.Layout?
    @ObservationIgnored private var installedMix: CompositionBuilder.Mix?

    static let pixelsPerSecondRange = 2.0...800.0

    init(project: Project = Project(), mediaDirectory: URL) {
        var project = project
        project.normalizeTracks()
        self.project = project
        shownProject = project
        self.mediaDirectory = mediaDirectory
        // A zoom being aimed shows its clip whole while paused, and zoomed as it plays.
        playback.onPlayingChange = { [weak self] _ in self?.showAimedClip() }
    }

    func load(_ project: Project, mediaDirectory: URL, transcripts: [UUID: Transcript] = [:]) {
        var project = project
        project.normalizeTracks()
        // A version put back still knows which files turned out to be silent.
        project.treatAsSilent(silentAssets)
        self.project = project
        self.mediaDirectory = mediaDirectory
        // Opened, or put back to a saved version: nothing to save yet.
        isSaving = false
        avAssets = [:]
        installedLayout = nil
        selection = []
        selectedCaptions = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        transcribing = nil
        self.transcripts = transcripts
        transcriptSelection = []
        refreshTranscript()
        project.assets.forEach(analyze)
        analyzeIsolatedVoices()
        updateStage()
        playback.setMasterVolume(project.masterVolume)
        rebuildPlayback()
    }

    /// After the project file moves, media is read from its new place: anything opened from the old one is let
    /// go, and playback is built again from the new.
    func mediaFolderMoved(to directory: URL) {
        guard directory != mediaDirectory else { return }
        mediaDirectory = directory
        avAssets = [:]
        installedLayout = nil
        rebuildPlayback()
    }

    func mediaURL(for asset: Asset) -> URL {
        mediaDirectory.appending(path: asset.fileName)
    }

    func avAsset(for id: UUID) -> AVURLAsset? {
        if let cached = avAssets[id] { return cached }
        guard let asset = project.asset(id) else { return nil }
        let loaded = AVURLAsset(url: mediaURL(for: asset))
        avAssets[id] = loaded
        return loaded
    }

    // MARK: Editing and undo

    /// Applies one undoable edit to the project.
    func apply(_ actionName: String, _ change: (inout Project) -> Void) {
        guard !isExporting else { return }
        let before = project
        change(&project)
        // Text kept to a place on the canvas follows the canvas when it changes size.
        if project.canvas != before.canvas { Self.placeTitles(project.anchoredTitleIDs, in: &project) }
        project.normalizeTracks()
        registerUndo(restoring: before, actionName: actionName)
        isSaving = true
        changed?()
        projectDidChange()
    }

    private func registerUndo(restoring snapshot: Project, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.restore(snapshot, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    private func restore(_ snapshot: Project, actionName: String) {
        let current = project
        project = snapshot
        // Undo steps from before a file's silence was found still say it has sound.
        project.treatAsSilent(silentAssets)
        registerUndo(restoring: current, actionName: actionName)
        isSaving = true
        changed?()
        projectDidChange()
    }

    private func projectDidChange() {
        handlesPreview = nil
        // The transcript and captions first: the stage, the selection and playback go by them.
        refreshTranscript()
        if let captions = selectedCaptions, !project.tracks.contains(where: { $0.id == captions && $0.captions != nil }) {
            selectedCaptions = nil
        }
        updateStage()
        let clipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        selection = selection.intersection(clipIDs)
        if selection.isEmpty, selectedCaptions == nil { leaveSelectionTab() }
        // A crossfade or zoom that no longer exists closes its tab.
        if let transition = selectedTransition, project.crossfade(into: transition) == nil {
            selectTransition(nil)
        }
        if selectedZoom != nil, selectedZoomTarget == nil {
            selectZoom(nil)
        }
        // The Transcript tab goes with the last video on the timeline.
        if activeTab == .transcript, !project.hasVideoClips { activeTab = .media }
        playback.setMasterVolume(project.masterVolume)
        rebuildPlayback()
        analyzeIsolatedVoices()
    }

    func rebuildPlayback() {
        rebuildTask?.cancel()
        let project = shownProject
        let options = CompositionBuilder.Options(prototypeFades: prototypeFades, master: playback.masterGain)
        let layout = CompositionBuilder.layout(of: project)
        let mix = CompositionBuilder.mix(of: project, options: options)
        rebuildTask = Task {
            do {
                let built = try await CompositionBuilder.build(project: project, assets: { self.avAsset(for: $0) }, options: options)
                guard !Task.isCancelled else { return }
                // Text being typed on the canvas stays out of the picture, which the editor draws instead, and a
                // zoom being aimed shows its clip whole.
                built.plan?.update {
                    $0.hiddenClip = editingTitleClip
                    $0.unzoomedClip = aimedClip
                }
                // Same clips in the same places: the player keeps its item and shows the change on its next frame.
                if layout == installedLayout {
                    playback.refresh(with: built, mixChanged: mix != installedMix)
                } else {
                    playback.install(built)
                    installedLayout = layout
                }
                installedMix = mix
            } catch {
                guard !Task.isCancelled else { return }
                alert = AlertMessage(title: "Playback couldn't be updated", message: error.localizedDescription)
            }
        }
    }

    // MARK: Picture

    /// Shows a change to the project's look at once, without an undo step or a rebuild, as while a slider is
    /// dragged. The change is made for real, as one undo step, by an `apply` when the drag ends.
    func previewLook(_ change: (inout Project) -> Void) {
        var preview = project
        change(&preview)
        let shown = shown(preview)
        playback.plan?.update { $0.takeLook(from: shown) { self.resolve($0) } }
        playback.redrawPicture()
        updateStage(for: shown)
    }

    /// A project as it plays and shows, with its captions made.
    func shown(_ project: Project) -> Project {
        project.withCaptions(timelineTranscript)
    }

    /// What the preview shows while nothing on the timeline has a picture: the background, as it plays and
    /// exports, or without one, the bare canvas. Nil once there's a picture to play.
    private(set) var stageImage: CGImage?

    private func updateStage(for project: Project? = nil) {
        let project = project ?? shownProject
        guard !project.hasVisualClips else {
            stageImage = nil
            return
        }
        let canvas = project.canvas ?? Project.defaultCanvas
        stageImage = Compositor.stage(for: RenderPlan(
            canvas: CGSize(width: canvas.width, height: canvas.height),
            background: project.background.flatMap(resolve),
            layers: [],
            hiddenClip: nil
        ))
    }

    func resolve(_ fill: BackgroundFill) -> ResolvedFill? {
        switch fill {
        case let .color(color): .color(color)
        case let .gradient(gradient): .gradient(gradient)
        case let .mesh(mesh): .mesh(mesh)
        case let .wallpaper(id): project.asset(id).map { .image(mediaURL(for: $0)) }
        }
    }

    /// The picture showing handles in the preview. Handles appear when a picture is clicked there (or Crop is
    /// chosen for it), not when it's selected on the timeline, and go when the selection changes.
    var handlesClip: UUID?

    /// The preview's handles crop the picture instead of moving and scaling it.
    var isCropping = false

    /// The text clip being typed into on the canvas. Its rendered text is left out of the picture meanwhile.
    var editingTitleClip: UUID?

    /// Starts typing into a text clip on the canvas.
    func beginEditingTitle(_ id: UUID) {
        guard shownProject.clip(id)?.title != nil, !shownProject.isLocked(clip: id) else { return }
        // A caption is fixed word by word in the transcript; its captions stay selected while it's typed into.
        if let track = shownProject.captionsTrack(ofClip: id) {
            if selectedCaptions != track { selectCaptions(track) }
        } else if selection != [id] {
            select([id])
        }
        handlesClip = id
        editingTitleClip = id
        playback.plan?.update { $0.hiddenClip = id }
        playback.redrawPicture()
    }

    /// Ends typing on the canvas: new text becomes one undo step; nil, as for Esc, leaves the text as it was.
    func endEditingTitle(text: String?) {
        guard let id = editingTitleClip else { return }
        editingTitleClip = nil
        playback.plan?.update { $0.hiddenClip = nil }
        if let caption = shownProject.clip(id), shownProject.captionsTrack(ofClip: id) != nil {
            let words = caption.title?.spokenWords?.compactMap(\.source) ?? []
            if let text, text != caption.title?.text, !words.isEmpty {
                correctWords(words, to: text)
            } else {
                playback.redrawPicture()
            }
            return
        }
        if let text, text != project.clip(id)?.title?.text {
            apply("Edit Text") { Self.changeTitles(of: [id], in: &$0) { $0.text = text } }
        } else {
            playback.redrawPicture()
        }
    }

    /// Double-clicking a picture in the preview: crops it, selecting it and showing its crop handles, or, if it's
    /// already being cropped, stops.
    func toggleCropping(_ id: UUID) {
        if isCropping, handlesClip == id {
            isCropping = false
            return
        }
        if selection != [id] { select([id]) }
        handlesClip = id
        isCropping = true
    }

    /// Changes the selected text clips' text or look, as one undo step.
    func setTitle(_ name: String, _ change: @escaping (inout Title) -> Void) {
        // With captions selected, the Text tab changes their look.
        if selectedCaptions != nil { return changeCaptions(name) { change(&$0.look) } }
        let ids = editableSelection.filter { project.clip($0)?.title != nil }
        guard !ids.isEmpty else { return }
        lastChangedTitle = ids.first
        apply(name) { Self.changeTitles(of: ids, in: &$0, change) }
    }

    /// The title last changed in the Text tab, whose look new text takes.
    @ObservationIgnored private var lastChangedTitle: UUID?

    /// Shows a text change on the selected text clips while it's being made.
    func previewTitle(_ change: @escaping (inout Title) -> Void) {
        var preview = project
        if let track = selectedCaptions, let index = preview.tracks.firstIndex(where: { $0.id == track }) {
            if preview.tracks[index].captions != nil { change(&preview.tracks[index].captions!.look) }
        } else {
            let ids = editableSelection.filter { project.clip($0)?.title != nil }
            Self.changeTitles(of: ids, in: &preview, change)
        }
        handlesPreview = shown(preview)
        previewLook { $0 = preview }
    }

    /// The project as a Text or Canvas slider being dragged shows it, so the preview's handles follow the text, or the
    /// padding, as it moves. Nil once the change is applied, or with no slider being dragged.
    private(set) var handlesPreview: Project?

    /// Changes text clips. One kept to a place goes back onto it, its margin in from the edges whatever its size. Any
    /// other keeps the side it lines up on where it was as its text gets wider or narrower: a title on the left keeps
    /// its left edge, one on the right its right edge, one in the middle its middle.
    static func changeTitles(of ids: Set<UUID>, in project: inout Project, _ change: (inout Title) -> Void) {
        let canvas = project.canvas ?? Project.defaultCanvas
        let size = CGSize(width: canvas.width, height: canvas.height)
        for id in ids {
            guard let clip = project.clip(id), let before = clip.title else { continue }
            var after = before
            change(&after)
            project.changeTitle(of: [id]) { $0 = after }
            if after.anchor != nil {
                placeTitles([id], in: &project)
                continue
            }
            // Color and animation leave the width as it was, so only a change to what's drawn is measured.
            var drawn = before
            drawn.color = after.color
            drawn.animationIn = after.animationIn
            drawn.animationOut = after.animationOut
            guard after.alignment != .center, drawn != after,
                  let old = TitleRenderer.image(for: before, canvas: size), let new = TitleRenderer.image(for: after, canvas: size)
            else { continue }
            // Half the change in width, along the title's own turned line, as shares of the canvas.
            let shift = Double(new.width - old.width) / 2 * clip.visual.scale * (after.alignment == .leading ? 1 : -1)
            let angle = clip.visual.rotation * .pi / 180
            project.changeVisual(of: [id]) { visual in
                visual.x += shift * cos(angle) / size.width
                visual.y += shift * sin(angle) / size.height
            }
        }
    }

    /// Puts text clips kept to a place back on it: their lines line up with its side, and their box sits its margin
    /// in from the canvas's edges, or in the middle.
    static func placeTitles(_ ids: Set<UUID>, in project: inout Project) {
        let canvas = project.canvas ?? Project.defaultCanvas
        let size = CGSize(width: canvas.width, height: canvas.height)
        for id in ids {
            guard let clip = project.clip(id), var title = clip.title, let anchor = title.anchor else { continue }
            if title.alignment != anchor.alignment {
                title.alignment = anchor.alignment
                project.changeTitle(of: [id]) { $0.alignment = anchor.alignment }
            }
            guard let image = TitleRenderer.image(for: title, canvas: size) else { continue }
            let box = TitleAnchor.box(of: CGSize(width: image.width, height: image.height), visual: clip.visual)
            let center = anchor.center(ofBox: box, margin: title.margin, canvas: size)
            project.changeVisual(of: [id]) { visual in
                visual.x = center.x
                visual.y = center.y
            }
        }
    }

    /// Adds text at the playhead on a new track above the others, ready to type: in the middle, or at one of the
    /// nine places.
    func addTextAtPlayhead(at anchor: TitleAnchor = .center) {
        addText(at: playback.currentTime, target: .new(at: project.tracks.count), anchor: anchor)
    }

    /// Adds text, ready to type, in the look of the title last changed so a run of titles matches without setting
    /// each one: its font, color, readability, animation and margin.
    func addText(at start: Time, target: TrackTarget, anchor: TitleAnchor = .center) {
        var title = TitleStyle.centeredTitle.title
        if let look = lookForNewText {
            title.takeLook(of: look)
            title.margin = look.margin
        }
        title.anchor = anchor
        addTitle(title, at: start, target: target)
    }

    /// Adds a title in that style at the playhead, on a new track above the others, ready to type over.
    func addTitleAtPlayhead(_ style: TitleStyle) {
        var title = style.title
        title.anchor = style.anchor
        addTitle(title, visual: style.visual, at: playback.currentTime, target: .new(at: project.tracks.count))
    }

    /// Adds a title on its place, selects it and starts typing into it. Text that comes in moves the playhead to
    /// where it's all the way in: at its very start it's still unseen, so the preview would show nothing once the
    /// typing ends.
    private func addTitle(_ title: Title, visual: Visual = Visual(), at start: Time, target: TrackTarget) {
        apply("Add Text") { project in
            let id = project.addTitle(title, visual: visual, at: start, target: target).id
            Self.placeTitles([id], in: &project)
            selection = [id]
        }
        activeTab = .text
        guard let id = selection.first, selection.count == 1, let clip = project.clip(id), clip.title != nil else { return }
        if title.animationIn != .none, !playback.isPlaying {
            let shown = clip.start + Time(seconds: TitleAnimation.duration)
            if shown < clip.end { playback.seek(to: shown) }
        }
        beginEditingTitle(id)
    }

    /// The title whose look new text takes: the last one changed in the Text tab, or else the last on the timeline.
    private var lookForNewText: Title? {
        if let id = lastChangedTitle, let title = project.clip(id)?.title { return title }
        return project.tracks.flatMap(\.clips).filter { $0.title != nil }.max { $0.start < $1.start }?.title
    }

    /// Moves text to where it was dragged in the preview: onto one of the nine places when it caught on one, which
    /// it then keeps to, or anywhere else, where it stays.
    func moveTitle(to visual: Visual, anchor: TitleAnchor?) {
        let ids = pictureSelection.filter { project.clip($0)?.title != nil }
        guard !ids.isEmpty else { return }
        apply("Move") { project in
            project.changeVisual(of: ids) { $0 = visual }
            project.changeTitle(of: ids) { $0.anchor = anchor }
            project.realignTitles(ids)
            Self.placeTitles(ids, in: &project)
        }
    }

    /// Text clips other than the selected one, which "Use for all titles" would change.
    var otherTitleCount: Int {
        project.tracks.flatMap(\.clips).filter { $0.title != nil && !selection.contains($0.id) }.count
    }

    /// Gives every text clip the selected one's font, color, readability and animation.
    func useLookForAllTitles() {
        guard let id = selection.first, let source = project.clip(id)?.title else { return }
        let others = Set(project.tracks.flatMap(\.clips).filter { $0.title != nil && $0.id != id }.map(\.id))
        guard !others.isEmpty else { return }
        apply("Use for All Titles") { Self.changeTitles(of: others, in: &$0) { $0.takeLook(of: source) } }
    }

    /// Opens the tab that edits the selection: Text for text, else Video, else Audio.
    func showMainTab() {
        guard let tab = mainTab else { return }
        activeTab = tab
        isPanelVisible = true
    }

    func setCrossfadeVideoStyle(_ style: VideoTransition) {
        guard let incoming = selectedTransition else { return }
        apply("Change Crossfade Style") { project in
            guard let location = project.location(ofClip: incoming) else { return }
            project.tracks[location.track].clips[location.clip].crossfadeVideoStyle = style
        }
    }

    /// Gives the selected background clips a new fill.
    /// Shows a fill on the selected background clips while it's being picked, before it's chosen.
    func previewClipFill(_ fill: BackgroundFill) {
        let ids = editableSelection.filter { project.clip($0)?.fill != nil }
        previewLook { project in
            for id in ids {
                guard let location = project.location(ofClip: id) else { continue }
                project.tracks[location.track].clips[location.clip].fill = fill
            }
        }
    }

    func setClipFill(_ fill: BackgroundFill) {
        let ids = editableSelection.filter { project.clip($0)?.fill != nil }
        guard !ids.isEmpty else { return }
        apply("Change Background") { project in
            for id in ids {
                guard let location = project.location(ofClip: id) else { continue }
                project.tracks[location.track].clips[location.clip].fill = fill
            }
        }
    }

    /// Selected clips with a picture, which the Video tab changes.
    private var pictureSelection: Set<UUID> {
        editableSelection.filter { project.clip($0).map(project.showsPicture) ?? false }
    }

    /// Changes the selected clips' placement or look, as one undo step.
    func setVisual(_ name: String, _ change: @escaping (inout Visual) -> Void) {
        let ids = pictureSelection
        guard !ids.isEmpty else { return }
        apply(name) { project in
            project.changeVisual(of: ids, change)
            // Text lines up with the third of the canvas it's moved to, and text kept to a place, scaled or turned,
            // goes back onto it.
            project.realignTitles(ids)
            Self.placeTitles(ids, in: &project)
        }
    }

    /// Shows a placement or look change on the selected clips while it's dragged.
    func previewVisual(_ change: @escaping (inout Visual) -> Void) {
        let ids = pictureSelection
        previewLook { $0.changeVisual(of: ids, change) }
    }

    /// Adds an asset at the playhead on a new track above the others, as Add Text puts text.
    func addAssetAtPlayhead(_ id: UUID) {
        addClip(asset: id, at: playback.currentTime, target: .new(at: project.tracks.count))
    }

    func addClip(asset id: UUID, at start: Time, target: TrackTarget) {
        apply("Add Clip") { project in
            if let clip = project.addClip(asset: id, at: start, target: target) {
                selection = [clip.id]
            }
        }
    }

    func addBackground(_ fill: BackgroundFill, at start: Time, target: TrackTarget) {
        apply("Add Background") { project in
            selection = [project.addBackground(fill, at: start, target: target).id]
        }
    }

    func moveClip(_ id: UUID, to start: Time, target: TrackTarget) {
        apply("Move Clip") { $0.moveClip(id, to: start, target: target) }
    }

    /// ⌥-dragging a clip: a copy lands where it's dropped, selected, and the clip stays where it was.
    func duplicateClip(_ id: UUID, to start: Time, target: TrackTarget) {
        apply("Duplicate Clip") { project in
            if let copy = project.duplicateClip(id, to: start, target: target) { selection = [copy] }
        }
    }

    func moveTrack(from source: Int, to destination: Int) {
        guard source != destination else { return }
        apply("Move Track") { $0.moveTrack(from: source, to: destination) }
    }

    /// Clips on locked tracks are left alone by every edit.
    private var editableSelection: Set<UUID> {
        selection.filter { !project.isLocked(clip: $0) }
    }

    /// Deletes the selected clips. Closing gaps pulls later clips on each track back.
    func deleteSelection(closingGaps: Bool = false) {
        // A selected zoom is what Delete removes, and selected captions go together.
        if selectedZoom != nil { return deleteSelectedZoom() }
        if let track = selectedCaptions { return removeCaptions(track) }
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        apply(closingGaps ? "Delete and Close Gap" : (ids.count == 1 ? "Delete Clip" : "Delete Clips")) {
            $0.removeClips(ids, closingGaps: closingGaps)
        }
    }

    func trim(_ id: UUID, edge: Project.ClipEdge, to time: Time, ripple: Bool) {
        apply("Trim Clip") { $0.trim(id, edge: edge, to: time, ripple: ripple) }
    }

    /// Trims the selected clips, or the clips under the playhead when nothing is selected, so one edge meets the playhead.
    func trimToPlayhead(_ edge: Project.ClipEdge) {
        let time = playback.currentTime
        let ids = (selection.isEmpty ? Set(clips(at: time)) : editableSelection).filter { id in
            project.clip(id).map { $0.start < time && time < $0.end } ?? false
        }
        guard !ids.isEmpty else { return }
        apply(edge == .start ? "Trim Start" : "Trim End") { project in
            for id in ids { project.trim(id, edge: edge, to: time) }
        }
    }

    /// Splits the selected clips at the playhead, or every clip under it when nothing is selected.
    func splitAtPlayhead() {
        let time = playback.currentTime
        let ids = selection.isEmpty ? nil : editableSelection
        apply("Split") { $0.split(at: time, clips: ids) }
    }

    func detachAudio() {
        let ids = editableSelection
        apply("Detach Audio") { project in
            let sounds = project.detachAudio(ids)
            selection.formUnion(sounds)
        }
    }

    var canDetachAudio: Bool {
        editableSelection.contains { id in
            project.clip(id).map { project.showsPicture($0) && project.playsSound($0) } ?? false
        }
    }

    /// A speed being dragged in the panel. The timeline shows it at once; it's committed as one change on release.
    var speedPreview: Double?

    /// The project as the timeline draws it, including a speed still being dragged.
    var timelineProject: Project {
        guard let speedPreview else { return shownProject }
        var preview = project
        preview.setSpeed(speedPreview, for: editableSelection)
        return shown(preview)
    }

    func setSpeed(_ speed: Double) {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        apply("Change Speed") { $0.setSpeed(speed, for: ids) }
    }

    func setPreservesPitch(_ preserves: Bool) {
        let ids = editableSelection
        apply(preserves ? "Keep Pitch" : "Change Pitch with Speed") { project in
            for id in ids {
                if let location = project.location(ofClip: id) {
                    project.tracks[location.track].clips[location.clip].preservesPitch = preserves
                }
            }
        }
    }

    var selectedClips: [Clip] {
        selection.compactMap { project.clip($0) }
    }

    /// The tracks holding the selected clips.
    var selectedTrackIDs: Set<UUID> {
        Set(selection.compactMap { id in project.location(ofClip: id).map { project.tracks[$0.track].id } })
    }

    func setTrackFlag(_ flag: WritableKeyPath<Track, Bool>, to value: Bool, onTracks ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let name = switch flag {
        case \Track.isMuted: value ? "Mute Track" : "Unmute Track"
        case \Track.isSoloed: value ? "Solo Track" : "Unsolo Track"
        default: value ? "Lock Track" : "Unlock Track"
        }
        apply(name) { $0.setFlag(flag, to: value, onTracks: ids) }
    }

    // MARK: Audio

    /// The crossfade shown in the Transitions tab, named by its incoming clip.
    private(set) var selectedTransition: UUID?

    var selectedCrossfade: Crossfade? {
        selectedTransition.flatMap { project.crossfade(into: $0) }
    }

    /// Selecting a crossfade clears the clip selection and opens the Transitions tab.
    func selectTransition(_ incoming: UUID?) {
        if let incoming {
            selectedCaptions = nil
            selectZoom(nil)
            previousTab = activeTab.isContextual ? previousTab : (tabBeforeSelection ?? activeTab)
            tabBeforeSelection = nil
            selection = []
            selectedTransition = incoming
            activeTab = .transitions
            isPanelVisible = true
        } else if selectedTransition != nil {
            selectedTransition = nil
            if activeTab == .transitions { activeTab = previousTab }
        }
    }

    @ObservationIgnored private var previousTab: PanelTab = .canvas

    // MARK: Zooms

    /// A zoom on a clip, as it's picked on the timeline.
    struct ZoomSelection: Hashable {
        var clip: UUID
        var zoom: UUID
    }

    /// The zoom shown in the Zoom tab and aimed in the preview.
    private(set) var selectedZoom: ZoomSelection?

    var selectedZoomTarget: (clip: Clip, zoom: Zoom)? {
        guard let selectedZoom, let clip = project.clip(selectedZoom.clip),
              let zoom = clip.zooms.first(where: { $0.id == selectedZoom.zoom }) else { return nil }
        return (clip, zoom)
    }

    /// The clip whose zoom is being aimed: drawn whole in the preview while paused, so its region can be placed.
    var aimedClip: UUID? { playback.isPlaying ? nil : selectedZoom?.clip }

    /// Selects a zoom, opening the Zoom tab as a crossfade opens Transitions; nil closes it.
    func selectZoom(_ target: ZoomSelection?) {
        if let target {
            selectedCaptions = nil
            if selectedTransition != nil { selectTransition(nil) }
            previousTab = activeTab.isContextual ? previousTab : (tabBeforeSelection ?? activeTab)
            tabBeforeSelection = nil
            selection = []
            handlesClip = nil
            selectedZoom = target
            activeTab = .zoom
            isPanelVisible = true
        } else if selectedZoom != nil {
            selectedZoom = nil
            if activeTab == .zoom { activeTab = previousTab }
        }
        showAimedClip()
    }

    private func showAimedClip() {
        let aimed = aimedClip
        guard playback.plan?.current.unzoomedClip != aimed else { return }
        playback.plan?.update { $0.unzoomedClip = aimed }
        playback.redrawPicture()
    }

    /// Adds a zoom to a video or image clip where `time` falls in it, three seconds long or as long as fits before
    /// the clip or the next zoom ends, and selects it.
    func addZoom(to clipID: UUID, at time: Time) {
        guard let clip = project.clip(clipID), project.isPlaceable(clip), clip.title == nil,
              let location = project.location(ofClip: clipID), !project.tracks[location.track].isLocked else { return }
        let sourceEnd = clip.sourceStart.seconds + clip.sourceDuration.seconds
        var start = clip.sourceSeconds(at: Time(seconds: time.seconds.clamped(to: clip.start.seconds...clip.end.seconds)))
        // Inside another zoom, the new one starts after it.
        if let covering = clip.zooms.first(where: { $0.start <= start && start < $0.end }) { start = covering.end }
        let limit = min(sourceEnd, clip.zooms.filter { $0.start > start }.map(\.start).min() ?? sourceEnd)
        let duration = min(Zoom.defaultDuration * clip.speed, limit - start)
        guard duration >= Zoom.shortest * clip.speed else { return NSSound.beep() }
        let zoom = Zoom(start: start, duration: duration)
        apply("Add Zoom") { $0.changeZooms(of: clipID) { $0.append(zoom) } }
        selectZoom(ZoomSelection(clip: clipID, zoom: zoom.id))
    }

    /// Changes the selected zoom's region or level, as one undo step.
    func setZoom(_ name: String, _ change: @escaping (inout Zoom) -> Void) {
        guard let target = selectedZoom else { return }
        apply(name) { $0.changeZoom(target.zoom, of: target.clip, change) }
    }

    /// Shows a change to the selected zoom while it's dragged.
    func previewZoom(_ change: @escaping (inout Zoom) -> Void) {
        guard let target = selectedZoom else { return }
        previewLook { $0.changeZoom(target.zoom, of: target.clip, change) }
    }

    /// Moves or resizes a zoom on the timeline, as its bar was dragged to.
    func retimeZoom(_ target: ZoomSelection, start: Double, duration: Double, name: String) {
        apply(name) { project in
            project.changeZoom(target.zoom, of: target.clip) { zoom in
                zoom.start = start
                zoom.duration = duration
            }
        }
    }

    func deleteSelectedZoom() {
        guard let target = selectedZoom else { return }
        apply("Delete Zoom") { $0.changeZooms(of: target.clip) { $0.removeAll { $0.id == target.zoom } } }
        selectZoom(nil)
    }

    func setZoomAnimation(_ animation: ZoomAnimation) {
        guard animation != project.zoomAnimation else { return }
        apply("Change Zoom Animation") { $0.zoomAnimation = animation }
    }

    func setMotionBlur(_ blur: MotionBlur) {
        guard blur != project.motionBlur else { return }
        apply("Change Motion Blur") { $0.motionBlur = blur }
    }

    func setCrossfadeCurve(_ curve: Curve) {
        guard let incoming = selectedTransition else { return }
        apply("Change Crossfade Curve") { $0.setCrossfadeCurve(curve, into: incoming) }
    }

    /// Gives every crossfade the selected one's curve, and new crossfades start with it too.
    func useCrossfadeCurveForAll() {
        guard let curve = selectedCrossfade?.curve else { return }
        apply("Use Curve for All Crossfades") { $0.useCrossfadeCurveForAll(curve) }
    }

    /// Lengthens or shortens the selected crossfade about its middle.
    func setCrossfadeDuration(_ duration: Time) {
        guard let incoming = selectedTransition else { return }
        apply("Change Crossfade Duration") { $0.setCrossfadeDuration(duration, into: incoming) }
    }

    /// How many crossfades there are besides the selected one.
    var otherCrossfadeCount: Int {
        project.allCrossfades.filter { $0.incoming.id != selectedTransition }.count
    }

    func setFade(_ edge: Project.ClipEdge, duration: Time? = nil, curve: Curve? = nil, clips ids: Set<UUID>? = nil) {
        let ids = ids ?? editableSelection
        guard !ids.isEmpty else { return }
        apply(edge == .start ? "Change Fade In" : "Change Fade Out") { $0.setFade(edge, of: ids, duration: duration, curve: curve) }
    }

    /// A fade added from a menu starts this long.
    static let addedFadeDuration = Time(seconds: 1)

    /// Selected clips with sound that can take a fade on that edge: ones that don't crossfade there.
    private func clipsThatCanFade(_ edge: Project.ClipEdge) -> [Clip] {
        selectedClips.filter { project.playsSound($0) && project.crossfade(at: edge, of: $0.id) == nil }
    }

    func canFade(_ edge: Project.ClipEdge) -> Bool {
        !clipsThatCanFade(edge).isEmpty
    }

    /// Whether every selected clip that can fade on that edge has a fade there.
    func selectionHasFade(_ edge: Project.ClipEdge) -> Bool {
        let clips = clipsThatCanFade(edge)
        return !clips.isEmpty && clips.allSatisfy { (edge == .start ? $0.fadeIn : $0.fadeOut).duration > .zero }
    }

    /// The fade on that edge of the first selected clip that can take one, if it has one there.
    func selectionFade(_ edge: Project.ClipEdge) -> Fade? {
        guard let clip = clipsThatCanFade(edge).first else { return nil }
        let fade = edge == .start ? clip.fadeIn : clip.fadeOut
        return fade.duration > .zero ? fade : nil
    }

    /// Gives the selected clips that curve of fade on that edge, adding a one-second fade where there isn't one
    /// and keeping the length where there is. No curve takes the fade away.
    func setSelectionFade(_ edge: Project.ClipEdge, curve: Curve?) {
        let clips = clipsThatCanFade(edge)
        guard !clips.isEmpty else { return }
        apply(edge == .start ? "Change Fade In" : "Change Fade Out") { project in
            for clip in clips {
                let hasFade = (edge == .start ? clip.fadeIn : clip.fadeOut).duration > .zero
                if let curve {
                    project.setFade(edge, of: [clip.id], duration: hasFade ? nil : Self.addedFadeDuration, curve: curve)
                } else {
                    project.setFade(edge, of: [clip.id], duration: .zero)
                }
            }
        }
    }

    /// Adds a one-second fade to the selected clips that can take one, or takes it away if they all have one.
    func toggleFade(_ edge: Project.ClipEdge) {
        let ids = Set(clipsThatCanFade(edge).map(\.id))
        setFade(edge, duration: selectionHasFade(edge) ? .zero : Self.addedFadeDuration, clips: ids)
    }

    func setClipVolume(_ volume: Double) {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        apply("Change Volume") { $0.setVolume(volume, of: ids) }
    }

    func setTrackVolume(_ volume: Double) {
        let ids = selectedTrackIDs
        guard !ids.isEmpty else { return }
        apply("Change Track Volume") { $0.setVolume(volume, onTracks: ids) }
    }

    /// Turns voice isolation on or off for the selected clips with sound.
    func setIsolatesVoice(_ isOn: Bool) {
        let ids = editableSelection.filter { id in project.clip(id).map(project.playsSound) ?? false }
        guard !ids.isEmpty else { return }
        apply(isOn ? "Isolate Voice" : "Stop Isolating Voice") { project in
            for id in ids {
                guard let location = project.location(ofClip: id) else { continue }
                project.tracks[location.track].clips[location.clip].isolatesVoice = isOn
            }
        }
    }

    func setMasterVolume(_ volume: Double) {
        // Up to +12 dB, the top of the volume sliders.
        apply("Change Master Volume") { $0.masterVolume = min(max(volume, 0), 4) }
    }

    // MARK: Clipboard

    @ObservationIgnored private var clipboard: [ClipboardItem] = []

    var canPaste: Bool { !clipboard.isEmpty }

    func copySelection() {
        clipboard = selection.compactMap { id in
            project.location(ofClip: id).map { ClipboardItem(clip: project.tracks[$0.track].clips[$0.clip], trackID: project.tracks[$0.track].id) }
        }
    }

    func cutSelection() {
        copySelection()
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        apply("Cut") { $0.removeClips(ids) }
    }

    /// Pastes at the playhead, keeping the copied clips' spacing and tracks.
    func paste() {
        guard !clipboard.isEmpty else { return }
        let items = clipboard
        let time = playback.currentTime
        apply("Paste") { project in
            selection = Set(project.paste(items, at: time))
        }
    }

    // MARK: Navigation

    var isSnappingEnabled = true

    /// Clips under a time, topmost track first.
    func clips(at time: Time) -> [UUID] {
        project.tracks.reversed().flatMap { track in
            track.clips.filter { $0.start <= time && time < $0.end }.map(\.id)
        }
    }

    /// Whether a clip with a picture is under the playhead, for the Video tab to offer it.
    var hasPictureAtPlayhead: Bool {
        clips(at: playback.currentTime).contains { id in project.clip(id).map(project.showsPicture) ?? false }
    }

    func selectClipAtPlayhead() {
        if let top = clips(at: playback.currentTime).first {
            select([top])
        }
    }

    func selectAll() {
        select(Set(project.tracks.flatMap(\.clips).map(\.id)))
    }

    /// Steps by whole frames at the project's frame rate.
    func stepFrames(_ count: Int) {
        playback.pause()
        let frame = 1 / project.frameRate
        playback.seek(to: Time(seconds: playback.currentTime.seconds + Double(count) * frame))
    }

    /// Jumps to the previous or next clip edge.
    func jumpToEdge(forward: Bool) {
        let now = playback.currentTime
        let edges = Set(project.tracks.flatMap(\.clips).flatMap { [$0.start, $0.end] } + [.zero]).sorted()
        let slop = Time(seconds: 0.001)
        let target = forward ? edges.first { $0 > now + slop } : edges.last { $0 < now - slop }
        if let target {
            playback.seek(to: target)
        }
    }

    func requestRemoveAsset(_ asset: Asset) {
        if project.isAssetInUse(asset.id) {
            assetPendingRemoval = asset
        } else {
            removeAsset(asset.id)
        }
    }

    func removeAsset(_ id: UUID) {
        apply("Remove Media") { $0.removeAsset(id) }
        avAssets[id] = nil
    }

    // MARK: Export

    /// Shows the Export sheet.
    var isExportSheetShown = false
    /// What the next export makes. The format chosen last is remembered between exports and projects; everything
    /// else keeps the settings that suit most videos.
    var exportSettings = ProjectStore.rememberedExportSettings() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(exportSettings), forKey: Self.exportSettingsKey) }
    }
    /// Where exports are saved, remembered too.
    var exportFolder = ProjectStore.rememberedExportFolder() {
        didSet { UserDefaults.standard.set(exportFolder.path, forKey: Self.exportFolderKey) }
    }
    /// How far the export has got, while one runs. The project can't be edited until it's done or canceled.
    private(set) var exportProgress: Exporter.Progress?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    var isExporting: Bool { exportProgress != nil }

    private static let exportSettingsKey = "ExportSettings"
    private static let exportFolderKey = "ExportFolder"

    private static func rememberedExportSettings() -> ExportSettings {
        var settings = ExportSettings()
        if let data = UserDefaults.standard.data(forKey: exportSettingsKey),
           let remembered = try? JSONDecoder().decode(ExportSettings.self, from: data) {
            settings.videoFormat = remembered.videoFormat
            settings.audioFormat = remembered.audioFormat
            settings.isAudioOnly = remembered.isAudioOnly
        }
        return settings
    }

    private static func rememberedExportFolder() -> URL {
        if let path = UserDefaults.standard.string(forKey: exportFolderKey), FileManager.default.fileExists(atPath: path) {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// What the next export makes. Without a picture or a background, that's sound only.
    var exportFormat: ExportSettings.Format {
        project.hasPicture ? exportSettings.format : exportSettings.audioFormat
    }

    /// Whether there's anything to export, and no export already running.
    var canExport: Bool {
        project.duration > .zero && !isExporting
    }

    func requestExport() {
        guard !isExporting else { return }
        guard project.duration > .zero else {
            showToast(Toast(kind: .failed, title: "Nothing to export", detail: "Add media to the timeline first."))
            return
        }
        // A project with a picture exports as video unless you choose otherwise this time: an audio-only choice
        // from an earlier export doesn't carry over to it.
        if project.hasPicture { exportSettings.isAudioOnly = false }
        isExportSheetShown = true
    }

    func setNormalizesLoudness(_ isOn: Bool) {
        apply(isOn ? "Normalize Loudness" : "Stop Normalizing Loudness") { $0.normalizesLoudness = isOn }
    }

    /// Exports the project as it is now to `destination`, replacing any file there, then shows it in Finder.
    func export(to destination: URL) {
        guard !isExporting else { return }
        var settings = exportSettings
        if !project.hasPicture { settings.isAudioOnly = true }
        let project = project
        exportProgress = Exporter.Progress(stage: project.normalizesLoudness ? .measuring : .writing, fraction: 0)
        exportTask = Task {
            do {
                let job = try await Exporter.job(for: shownProject, assets: { self.avAsset(for: $0) }, settings: settings, destination: destination)
                try await Exporter.run(job) { progress in
                    Task { @MainActor in
                        // Only forward, so the bar never slips back if two reports arrive out of order.
                        if self.isExporting, progress.fraction >= self.exportProgress?.fraction ?? 0 { self.exportProgress = progress }
                    }
                }
                finishExport()
                showToast(Toast(kind: .done, title: "Exported “\(destination.lastPathComponent)”", file: destination))
            } catch {
                let canceled = Task.isCancelled
                finishExport()
                if !canceled {
                    showToast(Toast(kind: .failed, title: "The export couldn't be finished", detail: error.localizedDescription))
                }
            }
        }
    }

    /// The note at the bottom of the window about how the last export went.
    private(set) var toast: Toast?

    /// Shows a toast. One that says it's done goes by itself after a few seconds; a failure stays until it's closed.
    func showToast(_ toast: Toast) {
        self.toast = toast
        guard toast.kind == .done else { return }
        Task {
            try? await Task.sleep(for: Toast.doneDuration)
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func dismissToast() {
        toast = nil
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func finishExport() {
        exportTask = nil
        exportProgress = nil
        isExportSheetShown = false
    }

    // MARK: Selection

    func select(_ ids: Set<UUID>) {
        // Clicking a caption selects its captions, which are styled and removed together.
        let captions = Set(ids.compactMap { shownProject.captionsTrack(ofClip: $0) })
        let ids = ids.filter { shownProject.captionsTrack(ofClip: $0) == nil }
        if ids.isEmpty, let track = captions.first {
            return selectCaptions(track)
        }
        selectedCaptions = nil
        if !ids.isEmpty {
            selectTransition(nil)
            selectZoom(nil)
        }
        if handlesClip.map({ [$0] }) != ids {
            handlesClip = nil
            isCropping = false
        }
        selection = ids
        guard !ids.isEmpty else { return leaveSelectionTab() }
        // The tab follows the selection from anywhere, staying put while it already edits every selected clip.
        guard !applicableTabs.contains(activeTab), let main = mainTab else { return }
        if activeTab.isProjectTab { tabBeforeSelection = activeTab }
        activeTab = main
    }

    /// Shows a tab you chose, which stays chosen when the selection clears.
    func showTab(_ tab: PanelTab) {
        activeTab = tab
        isPanelVisible = true
        tabBeforeSelection = nil
    }

    /// With nothing selected, goes back to the project tab that selecting clips left.
    private func leaveSelectionTab() {
        if let tab = tabBeforeSelection, !activeTab.isProjectTab, activeTab != .transitions { activeTab = tab }
        tabBeforeSelection = nil
    }

    /// Tabs that can edit every selected clip.
    var applicableTabs: Set<PanelTab> {
        let sets = selection.compactMap { id -> Set<PanelTab>? in
            guard let clip = project.clip(id) else { return nil }
            var tabs: Set<PanelTab> = []
            if project.showsPicture(clip) { tabs.insert(.video) }
            if clip.title != nil { tabs.insert(.text) }
            if project.playsSound(clip) { tabs.insert(.audio) }
            return tabs
        }
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }
    }

    private var mainTab: PanelTab? {
        let tabs = applicableTabs
        if tabs.contains(.text) { return .text }
        if tabs.contains(.video) { return .video }
        if tabs.contains(.audio) { return .audio }
        return nil
    }

    // MARK: Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.supportedTypes
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Picks sound files and puts them on the timeline at the playhead, one after another on a new track at the
    /// bottom, so there's sound to mix straight away.
    func presentAudioImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, placement: (start: playback.currentTime, target: .new(at: 0)))
    }

    /// Copies files into the project and adds them to the library, and to the timeline when `placement` is given.
    /// `imported` hears about each asset as it arrives.
    func importFiles(_ urls: [URL], placement: (start: Time, target: TrackTarget)? = nil, asWallpapers: Bool = false,
                     imported: ((Asset) -> Void)? = nil) {
        Task {
            var nextStart = placement?.start
            // Several files dropped together line up one after another on the same track.
            var nextTarget = placement?.target
            var failures: [String] = []
            for url in urls {
                let pending = PendingImport(name: url.lastPathComponent)
                // Wallpapers come in from the Canvas tab, so the Media tab doesn't show them arriving.
                if !asWallpapers { pendingImports.append(pending) }
                do {
                    let probe = try await MediaImporter.probe(url)
                    let id = UUID()
                    let fileName = "\(id.uuidString).\(url.pathExtension.lowercased())"
                    try await MediaImporter.copy(url, to: mediaDirectory.appending(path: fileName))
                    let asset = Asset(
                        id: id, fileName: fileName, displayName: url.lastPathComponent, kind: probe.kind,
                        duration: probe.duration, hasAudio: probe.hasAudio, pixelWidth: probe.pixelWidth,
                        pixelHeight: probe.pixelHeight, frameRate: probe.frameRate,
                        sampleRate: probe.sampleRate, channelCount: probe.channelCount, isWallpaper: asWallpapers ? true : nil
                    )
                    let start = nextStart
                    let target = nextTarget
                    apply("Import Media") { project in
                        project.assets.append(asset)
                        if let start, let target, let clip = project.addClip(asset: id, at: start, target: target),
                           let location = project.location(ofClip: clip.id) {
                            nextTarget = .existing(project.tracks[location.track].id)
                        }
                    }
                    nextStart = nextStart.map { $0 + (asset.kind == .image ? Clip.stillDuration : asset.duration) }
                    analyze(asset)
                    imported?(asset)
                } catch {
                    failures.append(error.localizedDescription)
                }
                pendingImports.removeAll { $0.id == pending.id }
            }
            if !failures.isEmpty {
                alert = AlertMessage(title: failures.count == 1 ? "A file wasn't imported" : "Some files weren't imported",
                                     message: failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: Canvas

    /// Resizes the canvas from the preview, keeping everything on it where it is. `frame` is in the current
    /// canvas's pixels.
    func resizeCanvas(to frame: CGRect) {
        apply("Resize Canvas") { $0.resizeCanvas(to: frame) }
    }

    func setBackground(_ fill: BackgroundFill?) {
        apply("Change Background") { $0.setBackground(fill) }
    }

    /// Changes how the pictures sit on the background.
    func setFrame(_ name: String, _ change: @escaping (inout PictureFrame) -> Void) {
        apply(name) { project in
            var frame = project.frame ?? PictureFrame()
            change(&frame)
            project.frame = frame
        }
    }

    /// Shows a frame change while it's dragged.
    func previewFrame(_ change: (inout PictureFrame) -> Void) {
        var preview = project
        var frame = preview.frame ?? PictureFrame()
        change(&frame)
        preview.frame = frame
        handlesPreview = shown(preview)
        previewLook { $0 = preview }
    }

    /// Picks image files to use as wallpapers: each is kept in the wallpaper library for every project, and the
    /// last one is used, as this project's background unless `use` says otherwise.
    func presentWallpaperPanel(use: ((BackgroundFill) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Wallpaper"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            WallpaperLibrary.add(url)
        }
        if let last = panel.urls.last {
            useWallpaper(last, use: use)
        }
    }

    /// Uses a library wallpaper, copying it into the project unless it's already there: as this project's
    /// background, or as `use` says, such as for a background clip.
    func useWallpaper(_ url: URL, use: ((BackgroundFill) -> Void)? = nil) {
        let apply: (BackgroundFill) -> Void = use ?? { [weak self] in self?.setBackground($0) }
        if let existing = project.assets.first(where: { $0.kind == .image && $0.displayName == url.lastPathComponent }) {
            apply(.wallpaper(existing.id))
            return
        }
        importFiles([url], asWallpapers: true) { asset in
            apply(.wallpaper(asset.id))
        }
    }

    /// Uses one of the Mac's aerial wallpapers, bringing a 4K still of it into the project unless it's already there:
    /// its portrait version on a canvas taller than it's wide, when it has one.
    func useAerial(_ aerial: SystemWallpapers.Aerial, use: ((BackgroundFill) -> Void)? = nil) {
        let canvas = project.canvas ?? Project.defaultCanvas
        let portrait = canvas.height > canvas.width
        if let existing = project.assets.first(where: { $0.kind == .image && $0.displayName == aerial.fileName(portrait: portrait) }) {
            if let use { use(.wallpaper(existing.id)) } else { setBackground(.wallpaper(existing.id)) }
            return
        }
        Task {
            guard let still = await SystemWallpapers.still(of: aerial, portrait: portrait) else { return }
            useWallpaper(still, use: use)
        }
    }

    // MARK: Media analysis

    func analyze(_ asset: Asset) {
        guard !analyzing.contains(asset.id) else { return }
        analyzing.insert(asset.id)
        let url = mediaURL(for: asset)
        Task {
            if asset.kind == .video, let image = await MediaAnalysis.thumbnail(for: url) {
                thumbnails[asset.id] = image
            } else if asset.kind == .image, let image = await MediaAnalysis.imageThumbnail(for: url) {
                thumbnails[asset.id] = image
            }
            if asset.hasAudio, let waveform = await MediaAnalysis.waveform(for: url) {
                waveforms[asset.id] = waveform
                if waveform.isSilent { treatAsSilent(asset.id) }
            }
        }
        if asset.kind == .video {
            Task {
                await MediaAnalysis.filmstrip(for: url) { strip in
                    self.filmstrips[asset.id] = strip
                }
            }
        }
    }

    // MARK: Loops

    /// Each video's frame prints, once read, for finding where it loops.
    private(set) var framePrints: [UUID: FramePrints] = [:]
    /// How far reading a video's frames has got, 0 to 1, while it's being read.
    private(set) var loopProgress: [UUID: Double] = [:]
    /// The best loops in each video once read. Empty when there are none, or the video couldn't be read.
    private(set) var suggestedLoops: [UUID: [Loop]] = [:]
    /// How often each video repeats, for those that do.
    private(set) var repetitions: [UUID: Repetition] = [:]
    /// The loop pointed at in the Video tab, shaded on its clip in the timeline.
    var highlightedLoop: LoopHighlight?
    @ObservationIgnored private var playheadLoops: (asset: UUID, frame: Int, loops: [Loop])?

    /// Reads a video's frames and finds its best loops, once.
    func findLoops(inAsset id: UUID) {
        guard let asset = project.asset(id), asset.kind == .video, suggestedLoops[id] == nil, loopProgress[id] == nil else { return }
        loopProgress[id] = 0
        let url = mediaURL(for: asset)
        Task {
            let prints = await FramePrints.make(for: url) { [weak self] fraction in self?.loopProgress[id] = fraction }
            let (repetition, loops) = await Self.loops(in: prints)
            framePrints[id] = prints
            repetitions[id] = repetition
            suggestedLoops[id] = loops
            loopProgress[id] = nil
        }
    }

    @concurrent
    private nonisolated static func loops(in prints: FramePrints?) async -> (Repetition?, [Loop]) {
        guard let prints else { return (nil, []) }
        return (prints.repetition(), prints.suggestedLoops())
    }

    /// Where loops of a clip start: the frame under the playhead, or its first frame when the playhead isn't on it.
    private func loopStart(in clip: Clip) -> Double {
        let time = playback.currentTime
        return clip.start <= time && time < clip.end
            ? clip.sourceStart.seconds + (time - clip.start).seconds * clip.speed : clip.sourceStart.seconds
    }

    /// Loops of one or more repeats of a video that repeats, starting where `loopStart` says.
    func repeatingLoops(in clip: Clip) -> [Loop] {
        guard let prints = framePrints[clip.assetID], let repetition = repetitions[clip.assetID] else { return [] }
        return prints.loops(repeating: repetition, from: loopStart(in: clip))
    }

    /// The best places to loop a clip back to the frame under the playhead, or to its first frame when the
    /// playhead isn't on it.
    func loopsFromPlayhead(in clip: Clip) -> [Loop] {
        guard let prints = framePrints[clip.assetID] else { return [] }
        let frame = prints.index(at: loopStart(in: clip))
        if let cached = playheadLoops, cached.asset == clip.assetID, cached.frame == frame { return cached.loops }
        let loops = prints.loops(from: prints.times[frame])
        playheadLoops = (clip.assetID, frame, loops)
        return loops
    }

    /// Whether a clip plays exactly that loop now, to half a frame.
    func plays(_ loop: Loop, in clip: Clip) -> Bool {
        let tolerance = 0.5 / project.frameRate
        let end = clip.sourceStart.seconds + clip.duration.seconds * clip.speed
        return abs(clip.sourceStart.seconds - loop.start) < tolerance && abs(end - loop.end) < tolerance
    }

    /// Trims the selected clip to play one loop.
    func trimToLoop(_ loop: Loop) {
        guard selection.count == 1, let id = selection.first else { return }
        apply("Trim to Loop") { $0.trimToLoop(id, from: Time(seconds: loop.start), to: Time(seconds: loop.end)) }
    }

    /// Media whose sound is silence from start to end. Its clips show no sound strip, and the sound controls leave
    /// them be.
    @ObservationIgnored private var silentAssets: Set<UUID> = []

    private func treatAsSilent(_ id: UUID) {
        silentAssets.insert(id)
        guard project.asset(id)?.hasAudio == true else { return }
        project.treatAsSilent([id])
        projectDidChange()
    }

    /// Works out the isolated waveform of each recording that has a clip with Isolate voice on, once.
    func analyzeIsolatedVoices() {
        let needed = Set(project.tracks.flatMap(\.clips).filter(\.isolatesVoice).map(\.assetID))
        for id in needed where isolatedWaveforms[id] == nil && !isolating.contains(id) {
            guard let asset = project.asset(id), asset.hasAudio else { continue }
            isolating.insert(id)
            let url = mediaURL(for: asset)
            Task {
                if let waveform = await MediaAnalysis.isolatedWaveform(for: url) {
                    isolatedWaveforms[id] = waveform
                }
                isolating.remove(id)
            }
        }
    }

    // MARK: Transcript

    /// What's said in each video, by asset. Kept with the project, but outside undo: transcribing isn't an edit.
    private(set) var transcripts: [UUID: Transcript] = [:]
    /// The transcript as the timeline plays it, kept up to date with every edit and as transcribing finds words.
    private(set) var timelineTranscript = TimelineTranscript()
    /// The video being transcribed: how far in, out of how long, and whether its language's model is still coming.
    private(set) var transcribing: (asset: UUID, seconds: Double, duration: Double, isPreparing: Bool)?
    /// The words found so far in the video being transcribed.
    @ObservationIgnored private var transcribedSoFar: [Transcript.Word] = []
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    /// Set by the document, which saves transcripts with the project.
    @ObservationIgnored var transcriptsChanged: (() -> Void)?
    /// The stretches the words selected in the Transcript tab cover, lit on the timeline and taken out by Delete.
    private(set) var transcriptSelection: [TranscriptCut] = []

    /// Transcripts of the media the project still has, to save.
    var transcriptsToSave: [UUID: Transcript] {
        transcripts.filter { project.asset($0.key) != nil }
    }

    /// Videos on the timeline with sound that haven't been transcribed yet.
    var untranscribedVideos: [Asset] {
        var seen: Set<UUID> = []
        return project.spokenClips.compactMap { clip in
            guard transcripts[clip.assetID] == nil, seen.insert(clip.assetID).inserted,
                  let asset = project.asset(clip.assetID), asset.hasAudio else { return nil }
            return asset
        }
    }

    /// Brings the transcript, and the captions made from it, up to date with the project. `rebuilding` rebuilds
    /// playback when the captions changed, for changes to the transcript itself; an edit rebuilds it anyway.
    private func refreshTranscript(rebuilding: Bool = false) {
        var known = transcripts
        if let transcribing { known[transcribing.asset] = Transcript(words: transcribedSoFar) }
        let updated = project.timelineTranscript(known)
        let changed = updated != timelineTranscript
        if changed {
            timelineTranscript = updated
            transcriptSelection = []
        }
        shownProject = shown(project)
        if rebuilding, changed, project.hasCaptions { rebuildPlayback() }
    }

    /// Writes out what's said in every video on the timeline that hasn't been, one at a time, on this Mac.
    func transcribe() {
        guard transcribeTask == nil else { return }
        let videos = untranscribedVideos
        guard !videos.isEmpty else { return }
        transcribeTask = Task { [weak self] in
            for asset in videos {
                guard let self, !Task.isCancelled else { return }
                transcribedSoFar = []
                transcribing = (asset.id, 0, asset.duration.seconds, false)
                do {
                    let words = try await Transcriber.transcribe(mediaURL(for: asset)) { [weak self] progress in
                        await MainActor.run {
                            guard let self, self.transcribing?.asset == asset.id else { return }
                            self.transcribedSoFar = progress.words
                            self.transcribing = (asset.id, progress.seconds, asset.duration.seconds, progress.isPreparing)
                            self.refreshTranscript(rebuilding: true)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    transcripts[asset.id] = Transcript(words: words)
                    isSaving = true
                    transcriptsChanged?()
                } catch {
                    if !Task.isCancelled, !(error is CancellationError) {
                        alert = AlertMessage(title: "Couldn't transcribe \(asset.shownName)", message: error.localizedDescription)
                    }
                    break
                }
            }
            guard let self else { return }
            transcribing = nil
            transcribedSoFar = []
            transcribeTask = nil
            refreshTranscript(rebuilding: true)
        }
    }

    /// Takes out every marked pause, down to a short breath, and every filler word.
    func removePausesAndFillers() {
        let cuts = timelineTranscript.removable
        guard !cuts.isEmpty, transcribing == nil else { return }
        let transcript = timelineTranscript
        let name = transcript.pauseCount > 0 && transcript.fillerCount > 0 ? "Remove Pauses and Fillers"
            : transcript.pauseCount > 0 ? "Remove Pauses" : "Remove Fillers"
        apply(name) { $0.cut(cuts) }
    }

    /// The transcript items selected in the Transcript tab, by their place in `timelineTranscript.items`.
    func selectTranscript(_ items: IndexSet) {
        transcriptSelection = timelineTranscript.cuts(covering: items)
    }

    /// Takes the selected words out of the video, closing up.
    func cutTranscriptSelection() {
        let cuts = transcriptSelection
        guard !cuts.isEmpty, transcribing == nil else { return }
        transcriptSelection = []
        apply("Cut Words") { $0.cut(cuts) }
    }

    /// While the Transcript tab shows: what Remove would take out and the selected words' stretches, per clip, in
    /// its source's seconds, for the timeline to mark.
    var transcriptMarks: TranscriptMarks? {
        guard isPanelVisible, activeTab == .transcript, !timelineTranscript.isEmpty else { return nil }
        func bySource(_ cuts: [TranscriptCut]) -> [UUID: [ClosedRange<Double>]] {
            var marks: [UUID: [ClosedRange<Double>]] = [:]
            for cut in cuts {
                guard let clip = project.clip(cut.clip) else { continue }
                let from = clip.sourceStart.seconds + (cut.range.start - clip.start).seconds * clip.speed
                let to = clip.sourceStart.seconds + (cut.range.end - clip.start).seconds * clip.speed
                marks[clip.id, default: []].append(from...max(from, to))
            }
            return marks
        }
        return TranscriptMarks(removable: transcribing == nil ? bySource(timelineTranscript.removable) : [:],
                               selected: bySource(transcriptSelection))
    }

    // MARK: Captions

    /// The captions track selected: clicking any caption selects them all, as they share one look.
    private(set) var selectedCaptions: UUID?

    /// The selected captions track and its captions.
    var selectedCaptionsTrack: (id: UUID, captions: Captions)? {
        guard let id = selectedCaptions, let track = project.tracks.first(where: { $0.id == id }), let captions = track.captions else { return nil }
        return (id, captions)
    }

    /// A caption as the Text tab shows the captions' look: the one on screen, or the first.
    var representativeCaption: Clip? {
        guard let id = selectedCaptions, let track = shownProject.tracks.first(where: { $0.id == id }) else { return nil }
        let time = playback.currentTime
        return track.clips.first { $0.start <= time && time < $0.end } ?? track.clips.first
    }

    func selectCaptions(_ track: UUID) {
        selectTransition(nil)
        selectZoom(nil)
        selection = []
        handlesClip = nil
        isCropping = false
        selectedCaptions = track
        // The Text tab styles them; deselecting goes back to the tab that was showing.
        if activeTab != .text {
            if activeTab.isProjectTab { tabBeforeSelection = activeTab }
            activeTab = .text
            isPanelVisible = true
        }
    }

    /// Puts the transcript on screen as captions, on a track of their own above the rest, and selects them.
    func addCaptions() {
        guard !project.hasCaptions else { return }
        let track = Track(name: "Captions", height: 40, captions: Captions())
        apply("Add Captions") { $0.tracks.append(track) }
        selectCaptions(track.id)
    }

    func removeCaptions(_ track: UUID) {
        selectedCaptions = nil
        apply("Remove Captions") { $0.tracks.removeAll { $0.id == track } }
        leaveSelectionTab()
    }

    /// Changes the selected captions' look or layout, as one undo step.
    func changeCaptions(_ name: String, _ change: @escaping (inout Captions) -> Void) {
        guard let track = selectedCaptions else { return }
        apply(name) { project in
            guard let index = project.tracks.firstIndex(where: { $0.id == track }), project.tracks[index].captions != nil else { return }
            change(&project.tracks[index].captions!)
        }
    }

    /// Fixes misheard words: `words`, from one file's transcript, become `text`. The same number of words keep their
    /// times; otherwise the new words share the old ones' time by length. Undoable, and saved with the project.
    func correctWords(_ words: [WordSource], to text: String) {
        guard let asset = words.first?.asset, var transcript = transcripts[asset] else { return }
        let indexes = Set(words.filter { $0.asset == asset }.map(\.index)).filter { transcript.words.indices.contains($0) }.sorted()
        guard let first = indexes.first, let last = indexes.last else { return }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let old = indexes.map { transcript.words[$0] }
        guard tokens != old.map(\.text) else { return }
        var replacement: [Transcript.Word]
        if tokens.count == old.count {
            replacement = zip(old, tokens).map { word, token in Transcript.Word(text: token, start: word.start, end: word.end) }
        } else {
            let start = transcript.words[first].start
            let span = transcript.words[last].end - start
            let letters = Double(max(1, tokens.reduce(0) { $0 + $1.count }))
            var offset = 0.0
            replacement = tokens.map { token in
                let share = span * Double(token.count) / letters
                defer { offset += share }
                return Transcript.Word(text: token, start: start + offset, end: start + offset + share)
            }
        }
        for index in indexes.reversed() { transcript.words.remove(at: index) }
        transcript.words.insert(contentsOf: replacement, at: first)
        transcript.words.sort { $0.start < $1.start }
        var updated = transcripts
        updated[asset] = transcript
        setTranscripts(updated, actionName: tokens.count == 1 && old.count == 1 ? "Fix Word" : "Fix Words")
    }

    private func setTranscripts(_ updated: [UUID: Transcript], actionName: String) {
        let before = transcripts
        transcripts = updated
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.setTranscripts(before, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        isSaving = true
        transcriptsChanged?()
        refreshTranscript(rebuilding: true)
    }

    // MARK: Zoom

    func zoom(by factor: Double) {
        pixelsPerSecond = (pixelsPerSecond * factor).clamped(to: Self.pixelsPerSecondRange)
    }

    func zoomToFit() {
        let seconds = max(project.duration.seconds, 5)
        pixelsPerSecond = ((timelineViewportWidth - 40) / seconds).clamped(to: Self.pixelsPerSecondRange)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
