import AppKit
import SwiftUI

/// One `.overlap` package: `Project.json` plus a `Media/` folder holding a copy of every imported file.
@objc(ProjectDocument)
final class ProjectDocument: NSDocument {
    nonisolated static let projectFileName = "Project.json"
    nonisolated static let mediaFolderName = "Media"

    let store: ProjectStore

    override init() {
        // Until the first save, imported media is copied into a staging folder.
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "Overlap-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: Self.mediaFolderName, directoryHint: .isDirectory)
        store = ProjectStore(mediaDirectory: staging)
        super.init()
        store.undoManager = undoManager
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(ProjectWindowController(store: store))
    }

    // MARK: Reading and writing
    // The document doesn't opt into background reading or writing, so AppKit calls these on the main thread.

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url.appending(path: Self.projectFileName))
        let project = try JSONDecoder().decode(Project.self, from: data)
        MainActor.assumeIsolated {
            store.load(project, mediaDirectory: url.appending(path: Self.mediaFolderName, directoryHint: .isDirectory))
        }
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        try MainActor.assumeIsolated {
            let fileManager = FileManager.default
            let media = url.appending(path: Self.mediaFolderName, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: media, withIntermediateDirectories: true)

            // Only media the project still uses is carried into the new package. Clones make this instant.
            for asset in store.project.assets {
                let source = store.mediaURL(for: asset)
                let destination = media.appending(path: asset.fileName)
                guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { continue }
                try MediaImporter.cloneFile(source, to: destination)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store.project).write(to: url.appending(path: Self.projectFileName))
        }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            MainActor.assumeIsolated {
                // After a save, read media from the saved package. A "save a copy" leaves the document where it was.
                if error == nil, saveOperation != .saveToOperation {
                    self?.store.mediaDirectory = url.appending(path: Self.mediaFolderName, directoryHint: .isDirectory)
                }
            }
            completionHandler(error)
        }
    }

    // MARK: Menu actions

    @objc func importMedia(_ sender: Any?) {
        store.presentImportPanel()
    }

    @objc func exportProject(_ sender: Any?) {
        store.requestExport()
    }

    @objc func togglePlayback(_ sender: Any?) {
        store.playback.togglePlay()
    }

    @objc func goToStart(_ sender: Any?) {
        store.playback.seek(to: .zero)
    }

    @objc func goToEnd(_ sender: Any?) {
        store.playback.seek(to: store.project.duration)
    }

    @objc func zoomInTimeline(_ sender: Any?) {
        store.zoom(by: 1.5)
    }

    @objc func zoomOutTimeline(_ sender: Any?) {
        store.zoom(by: 1 / 1.5)
    }

    @objc func zoomTimelineToFit(_ sender: Any?) {
        store.zoomToFit()
    }

    @objc func togglePanel(_ sender: Any?) {
        store.isPanelVisible.toggle()
    }

    @objc func showPanelTab(_ sender: NSMenuItem) {
        guard let tab = PanelTab(rawValue: sender.tag) else { return }
        store.activeTab = tab
        store.isPanelVisible = true
    }

    @objc func delete(_ sender: Any?) {
        store.deleteSelection()
    }

    @objc func deleteAndCloseGap(_ sender: Any?) {
        store.deleteSelection(closingGaps: true)
    }

    // These use the standard selectors, so they reach a text field first when one is being edited.
    @objc(cut:) func cutClips(_ sender: Any?) {
        store.cutSelection()
    }

    @objc(copy:) func copyClips(_ sender: Any?) {
        store.copySelection()
    }

    @objc(paste:) func pasteClips(_ sender: Any?) {
        store.paste()
    }

    @objc(selectAll:) func selectAllClips(_ sender: Any?) {
        store.selectAll()
    }

    @objc func selectClipAtPlayhead(_ sender: Any?) {
        store.selectClipAtPlayhead()
    }

    @objc func splitAtPlayhead(_ sender: Any?) {
        store.splitAtPlayhead()
    }

    @objc func trimStartToPlayhead(_ sender: Any?) {
        store.trimToPlayhead(.start)
    }

    @objc func trimEndToPlayhead(_ sender: Any?) {
        store.trimToPlayhead(.end)
    }

    @objc func detachAudio(_ sender: Any?) {
        store.detachAudio()
    }

    @objc func toggleFadeIn(_ sender: Any?) {
        store.toggleFade(.start)
    }

    @objc func toggleFadeOut(_ sender: Any?) {
        store.toggleFade(.end)
    }

    @objc func toggleSnapping(_ sender: Any?) {
        store.isSnappingEnabled.toggle()
    }

    @objc func playBackward(_ sender: Any?) {
        store.playback.shuttle(forward: false)
    }

    @objc func pausePlayback(_ sender: Any?) {
        store.playback.pause()
    }

    @objc func playForward(_ sender: Any?) {
        store.playback.shuttle(forward: true)
    }

    @objc func previousFrame(_ sender: Any?) {
        store.stepFrames(-1)
    }

    @objc func nextFrame(_ sender: Any?) {
        store.stepFrames(1)
    }

    @objc func previousEdit(_ sender: Any?) {
        store.jumpToEdge(forward: false)
    }

    @objc func nextEdit(_ sender: Any?) {
        store.jumpToEdge(forward: true)
    }

    @objc func togglePrototypeFades(_ sender: Any?) {
        store.prototypeFades.toggle()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Single-key shortcuts (Space, J, K, L, C, N, arrows, Delete) stay out of the way while typing in a text field.
        let isSingleKey = !menuItem.keyEquivalent.isEmpty && menuItem.keyEquivalentModifierMask.isDisjoint(with: [.command, .control, .option])
        if isSingleKey, windowForSheet?.firstResponder is NSText {
            return false
        }
        switch menuItem.action {
        case #selector(togglePlayback(_:)):
            menuItem.title = store.playback.isPlaying ? "Pause" : "Play"
        case #selector(togglePanel(_:)):
            menuItem.title = store.isPanelVisible ? "Hide Panel" : "Show Panel"
        case #selector(showPanelTab(_:)):
            menuItem.state = store.activeTab.rawValue == menuItem.tag ? .on : .off
            if menuItem.tag == PanelTab.transitions.rawValue {
                return store.selectedTransition != nil
            }
        case #selector(togglePrototypeFades(_:)):
            menuItem.state = store.prototypeFades ? .on : .off
        case #selector(toggleSnapping(_:)):
            menuItem.state = store.isSnappingEnabled ? .on : .off
        case #selector(delete(_:)), #selector(deleteAndCloseGap(_:)), #selector(cutClips(_:)), #selector(copyClips(_:)):
            return !store.selection.isEmpty
        case #selector(pasteClips(_:)):
            return store.canPaste
        case #selector(detachAudio(_:)):
            return store.canDetachAudio
        case #selector(toggleFadeIn(_:)):
            menuItem.title = store.selectionHasFade(.start) ? "Remove Fade In" : "Add Fade In"
            return store.canFade(.start)
        case #selector(toggleFadeOut(_:)):
            menuItem.title = store.selectionHasFade(.end) ? "Remove Fade Out" : "Add Fade Out"
            return store.canFade(.end)
        default:
            break
        }
        return super.validateMenuItem(menuItem)
    }
}
