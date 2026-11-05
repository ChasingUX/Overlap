import AppKit
import AVFoundation
import Observation

enum PanelTab: Int, CaseIterable, Identifiable {
    /// In the rail's order, which is also the View menu's: ⌘1 is Canvas. Transitions only shows while a crossfade
    /// is selected, at the bottom, so nothing moves when it comes and goes.
    case canvas = 1, video, audio, text, media, transitions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .media: "Media"
        case .canvas: "Canvas"
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        case .transitions: "Transitions"
        }
    }

    var icon: AppIcon {
        switch self {
        case .media: .media
        case .canvas: .canvas
        case .video: .video
        case .audio: .audio
        case .text: .text
        case .transitions: .transitions
        }
    }

    /// Project tabs always have content; clip tabs edit the selection.
    var isProjectTab: Bool { self == .media || self == .canvas }
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
    private(set) var selection: Set<UUID> = []
    var activeTab: PanelTab = .canvas
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
        self.mediaDirectory = mediaDirectory
    }

    func load(_ project: Project, mediaDirectory: URL) {
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
        updateStage()
        let clipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        selection = selection.intersection(clipIDs)
        // A crossfade that no longer exists closes the Transitions tab.
        if let transition = selectedTransition, project.crossfade(into: transition) == nil {
            selectTransition(nil)
        }
        playback.setMasterVolume(project.masterVolume)
        rebuildPlayback()
        analyzeIsolatedVoices()
    }

    func rebuildPlayback() {
        rebuildTask?.cancel()
        let project = project
        let options = CompositionBuilder.Options(prototypeFades: prototypeFades, master: playback.masterGain)
        let layout = CompositionBuilder.layout(of: project)
        let mix = CompositionBuilder.mix(of: project, options: options)
        rebuildTask = Task {
            do {
                let built = try await CompositionBuilder.build(project: project, assets: { self.avAsset(for: $0) }, options: options)
                guard !Task.isCancelled else { return }
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
        playback.plan?.update { $0.takeLook(from: preview) { self.resolve($0) } }
        playback.redrawPicture()
        updateStage(for: preview)
    }

    /// What the preview shows while nothing on the timeline has a picture: the background, as it plays and
    /// exports, or without one, the bare canvas. Nil once there's a picture to play.
    private(set) var stageImage: CGImage?

    private func updateStage(for project: Project? = nil) {
        let project = project ?? self.project
        guard !project.hasVisualClips else {
            stageImage = nil
            return
        }
        let canvas = project.canvas ?? Project.defaultCanvas
        stageImage = Compositor.stage(for: RenderPlan(
            canvas: CGSize(width: canvas.width, height: canvas.height),
            background: project.background.flatMap(resolve),
            frame: project.frame,
            layers: [],
            hiddenClip: nil
        ))
    }

    func resolve(_ fill: BackgroundFill) -> ResolvedFill? {
        switch fill {
        case let .color(color): .color(color)
        case let .gradient(gradient): .gradient(gradient)
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
        guard project.clip(id)?.title != nil, !project.isLocked(clip: id) else { return }
        if selection != [id] { select([id]) }
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
        if let text, text != project.clip(id)?.title?.text {
            apply("Edit Text") { $0.changeTitle(of: [id]) { $0.text = text } }
        } else {
            playback.redrawPicture()
        }
    }

    /// Turns crop mode on or off for the selected picture, showing its handles.
    func toggleCropping() {
        isCropping.toggle()
        if isCropping, selection.count == 1 {
            handlesClip = selection.first
        }
    }

    /// Changes the selected text clips' text or look, as one undo step.
    func setTitle(_ name: String, _ change: @escaping (inout Title) -> Void) {
        let ids = editableSelection.filter { project.clip($0)?.title != nil }
        guard !ids.isEmpty else { return }
        apply(name) { $0.changeTitle(of: ids, change) }
    }

    /// Shows a text change on the selected text clips while it's being made.
    func previewTitle(_ change: @escaping (inout Title) -> Void) {
        let ids = editableSelection.filter { project.clip($0)?.title != nil }
        previewLook { $0.changeTitle(of: ids, change) }
    }

    /// Adds a title in that style at the playhead, on a new track above the others.
    func addTitleAtPlayhead(_ style: TitleStyle) {
        addTitle(style, at: playback.currentTime, target: .new(at: project.tracks.count))
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
        apply(name) { $0.changeVisual(of: ids, change) }
    }

    /// Shows a placement or look change on the selected clips while it's dragged.
    func previewVisual(_ change: @escaping (inout Visual) -> Void) {
        let ids = pictureSelection
        previewLook { $0.changeVisual(of: ids, change) }
    }

    func addClip(asset id: UUID, at start: Time, target: TrackTarget) {
        apply("Add Clip") { project in
            if let clip = project.addClip(asset: id, at: start, target: target) {
                selection = [clip.id]
            }
        }
    }

    func addTitle(_ style: TitleStyle, at start: Time, target: TrackTarget) {
        apply("Add Text") { project in
            selection = [project.addTitle(style.title, visual: style.visual, at: start, target: target).id]
        }
        activeTab = .text
    }

    func addBackground(_ fill: BackgroundFill, at start: Time, target: TrackTarget) {
        apply("Add Background") { project in
            selection = [project.addBackground(fill, at: start, target: target).id]
        }
    }

    func moveClip(_ id: UUID, to start: Time, target: TrackTarget) {
        apply("Move Clip") { $0.moveClip(id, to: start, target: target) }
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
        guard let speedPreview else { return project }
        var preview = project
        preview.setSpeed(speedPreview, for: editableSelection)
        return preview
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
            previousTab = activeTab == .transitions ? previousTab : activeTab
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

    func setCrossfadeCurve(_ curve: Curve) {
        guard let incoming = selectedTransition else { return }
        apply("Change Crossfade Curve") { $0.setCrossfadeCurve(curve, into: incoming) }
    }

    /// Makes the selected crossfade's curve the one new crossfades start with.
    func useCrossfadeCurveAsDefault() {
        guard let curve = selectedCrossfade?.curve else { return }
        apply("Set Default Crossfade") { $0.defaultCrossfadeCurve = curve }
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

    /// Steps by whole frames at the canvas frame rate, or 30 fps without a canvas.
    func stepFrames(_ count: Int) {
        playback.pause()
        let frame = 1 / (project.canvas?.frameRate ?? 30)
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
                let job = try await Exporter.job(for: project, assets: { self.avAsset(for: $0) }, settings: settings, destination: destination)
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
        if !ids.isEmpty { selectTransition(nil) }
        if handlesClip.map({ [$0] }) != ids {
            handlesClip = nil
            isCropping = false
        }
        selection = ids
        let applicable = applicableTabs
        // Clip tabs follow the selection; Media and Canvas never switch on their own.
        if !activeTab.isProjectTab, !applicable.isEmpty, !applicable.contains(activeTab), let main = mainTab {
            activeTab = main
        }
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

    /// Copies files into the project and adds them to the library, and to the timeline when `placement` is given.
    /// `imported` hears about each asset as it arrives.
    func importFiles(_ urls: [URL], placement: (start: Time, target: TrackTarget)? = nil, imported: ((Asset) -> Void)? = nil) {
        Task {
            var nextStart = placement?.start
            // Several files dropped together line up one after another on the same track.
            var nextTarget = placement?.target
            var failures: [String] = []
            for url in urls {
                let pending = PendingImport(name: url.lastPathComponent)
                pendingImports.append(pending)
                do {
                    let probe = try await MediaImporter.probe(url)
                    let id = UUID()
                    let fileName = "\(id.uuidString).\(url.pathExtension.lowercased())"
                    try await MediaImporter.copy(url, to: mediaDirectory.appending(path: fileName))
                    let asset = Asset(
                        id: id, fileName: fileName, displayName: url.lastPathComponent, kind: probe.kind,
                        duration: probe.duration, hasAudio: probe.hasAudio, pixelWidth: probe.pixelWidth,
                        pixelHeight: probe.pixelHeight, frameRate: probe.frameRate,
                        sampleRate: probe.sampleRate, channelCount: probe.channelCount
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

    /// A fixed shape keeps the canvas's resolution: its shorter side stays as it was, so a 4K widescreen canvas
    /// turned vertical is 2160 × 3840.
    func setCanvasAspect(_ aspect: CanvasAspect) {
        apply("Change Canvas Shape") { project in
            project.canvasAspect = aspect
            let rate = project.canvas?.frameRate ?? Project.defaultCanvas.frameRate
            if let size = aspect.size {
                let shorter = project.canvas.map { min($0.width, $0.height) } ?? min(size.width, size.height)
                let scale = Double(shorter) / Double(min(size.width, size.height))
                project.canvas = Canvas(width: Self.evenSize(Int((Double(size.width) * scale).rounded())),
                                        height: Self.evenSize(Int((Double(size.height) * scale).rounded())), frameRate: rate)
            } else if aspect == .auto {
                project.canvas = project.firstVideoCanvas ?? Canvas(width: 1920, height: 1080, frameRate: rate)
            } else if project.canvas == nil {
                project.canvas = Project.defaultCanvas
            }
        }
    }

    /// Resizes the canvas from the preview, keeping everything on it where it is. `frame` is in the current
    /// canvas's pixels.
    func resizeCanvas(to frame: CGRect) {
        apply("Resize Canvas") { $0.resizeCanvas(to: frame) }
    }

    /// A new canvas size. A fixed shape stays chosen, since the Canvas tab keeps its proportions as you type. Auto
    /// gives way to the shape the size has, or Custom, since the size no longer follows the first video.
    func setCanvasSize(width: Int, height: Int) {
        apply("Change Canvas Size") { project in
            let canvas = Canvas(width: Self.evenSize(width), height: Self.evenSize(height),
                                frameRate: project.canvas?.frameRate ?? Project.defaultCanvas.frameRate)
            if project.canvasAspect == .auto {
                project.canvasAspect = CanvasAspect.shape(width: canvas.width, height: canvas.height) ?? .custom
            }
            project.canvas = canvas
        }
    }

    /// Kept even and between 16 and 8192 pixels, so video encoders accept it.
    private static func evenSize(_ value: Int) -> Int {
        min(max(value, 16), 8192) / 2 * 2
    }

    func setFrameRate(_ rate: Double) {
        apply("Change Frame Rate") { project in
            var canvas = project.canvas ?? Project.defaultCanvas
            canvas.frameRate = rate
            project.canvas = canvas
        }
    }

    func setBackground(_ fill: BackgroundFill?) {
        apply("Change Background") { $0.background = fill }
    }

    func setFrame(_ name: String, _ change: (inout PictureFrame) -> Void) {
        apply(name) { change(&$0.frame) }
    }

    /// Picks image files to use as wallpapers: each is kept in the wallpaper library for every project, and the
    /// last one becomes this project's background.
    func presentWallpaperPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Wallpaper"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            WallpaperLibrary.add(url)
        }
        if let last = panel.urls.last {
            useWallpaper(last)
        }
    }

    /// Makes a wallpaper this project's background, copying it into the project unless it's already there.
    func useWallpaper(_ url: URL) {
        if let existing = project.assets.first(where: { $0.kind == .image && $0.displayName == url.lastPathComponent }) {
            setBackground(.wallpaper(existing.id))
            return
        }
        importFiles([url]) { [weak self] asset in
            self?.setBackground(.wallpaper(asset.id))
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
        let tolerance = 0.5 / max(project.canvas?.frameRate ?? 30, 1)
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
