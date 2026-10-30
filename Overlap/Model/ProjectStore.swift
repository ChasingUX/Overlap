import AppKit
import AVFoundation
import Observation

enum PanelTab: Int, CaseIterable, Identifiable {
    /// Transitions only shows while a crossfade is selected.
    case media = 1, canvas, video, audio, text, transitions

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
    var activeTab: PanelTab = .media
    var isPanelVisible = true
    var pixelsPerSecond: Double = 40
    var timelineViewportWidth: Double = 800
    private(set) var pendingImports: [PendingImport] = []
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var filmstrips: [UUID: Filmstrip] = [:]
    private(set) var waveforms: [UUID: Waveform] = [:]
    var alert: AlertMessage?
    var assetPendingRemoval: Asset?
    /// The document's name and unsaved-changes state, shown in the title bar.
    var windowTitle = "Untitled"
    var isEdited = false
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
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

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
        self.project = project
        self.mediaDirectory = mediaDirectory
        avAssets = [:]
        selection = []
        project.assets.forEach(analyze)
        playback.setMasterVolume(project.masterVolume)
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
        let before = project
        change(&project)
        project.normalizeTracks()
        registerUndo(restoring: before, actionName: actionName)
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
        registerUndo(restoring: current, actionName: actionName)
        projectDidChange()
    }

    private func projectDidChange() {
        let clipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        selection = selection.intersection(clipIDs)
        // A crossfade that no longer exists closes the Transitions tab.
        if let transition = selectedTransition, project.crossfade(into: transition) == nil {
            selectTransition(nil)
        }
        playback.setMasterVolume(project.masterVolume)
        rebuildPlayback()
    }

    func rebuildPlayback() {
        rebuildTask?.cancel()
        let project = project
        let options = CompositionBuilder.Options(prototypeFades: prototypeFades, master: playback.masterGain)
        rebuildTask = Task {
            do {
                let built = try await CompositionBuilder.build(project: project, assets: { self.avAsset(for: $0) }, options: options)
                guard !Task.isCancelled else { return }
                playback.install(built)
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

    @ObservationIgnored private var previousTab: PanelTab = .media

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

    func requestExport() {
        alert = AlertMessage(title: "Export arrives in milestone 5",
                             message: "MP4, MOV and audio-only export are planned for milestone 5.")
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

    func setCanvasAspect(_ aspect: CanvasAspect) {
        apply("Change Canvas Shape") { project in
            project.canvasAspect = aspect
            let rate = project.canvas?.frameRate ?? Project.defaultCanvas.frameRate
            if let size = aspect.size {
                project.canvas = Canvas(width: size.width, height: size.height, frameRate: rate)
            } else if aspect == .auto {
                project.canvas = project.firstVideoCanvas ?? Canvas(width: 1920, height: 1080, frameRate: rate)
            } else if project.canvas == nil {
                project.canvas = Project.defaultCanvas
            }
        }
    }

    /// A custom canvas size, kept even and between 16 and 8192 pixels so video encoders accept it.
    func setCanvasSize(width: Int, height: Int) {
        func even(_ value: Int) -> Int { min(max(value, 16), 8192) / 2 * 2 }
        apply("Change Canvas Size") { project in
            project.canvasAspect = .custom
            project.canvas = Canvas(width: even(width), height: even(height),
                                    frameRate: project.canvas?.frameRate ?? Project.defaultCanvas.frameRate)
        }
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
