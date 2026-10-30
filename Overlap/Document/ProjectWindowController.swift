import AppKit
import SwiftUI

/// A project window with a tall unified title bar: the project name centered, and Export on the right.
final class ProjectWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static let titleItem = NSToolbarItem.Identifier("title")
    private static let exportItem = NSToolbarItem.Identifier("export")

    private let store: ProjectStore
    private var titleView: NSView?
    private var clickMonitor: Any?

    init(store: ProjectStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: ProjectWindowView(store: store))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.minSize = NSSize(width: 960, height: 600)
        // The title bar takes the window's own dark color, and the app draws its own title.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.chrome
        window.center()
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "ProjectWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        store.renameHandler = { [weak self] name in
            self?.renameDocument(to: name)
        }

        // Most of the window never takes keyboard focus, so a click there wouldn't end a rename on its own.
        // Any click outside the title while it's being edited saves the new name; the click still goes through.
        window.delegate = self
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.endTitleEditIfClickedOutside(event)
            return event
        }
    }

    private func endTitleEditIfClickedOutside(_ event: NSEvent) {
        guard store.isEditingTitle, event.window === window, let titleView else { return }
        if !titleView.bounds.contains(titleView.convert(event.locationInWindow, from: nil)) {
            store.commitTitleEdit()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        store.commitTitleEdit()
    }

    func windowWillClose(_ notification: Notification) {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    /// Renames a saved project's file in place, or names an unsaved one so its first save uses that name.
    private func renameDocument(to proposed: String) {
        // Slashes and colons can't appear in file names.
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard let document = document as? NSDocument, !name.isEmpty, name != store.windowTitle else { return }

        guard let url = document.fileURL else {
            document.displayName = name
            synchronizeWindowTitleWithDocumentName()
            return
        }
        let destination = url.deletingLastPathComponent().appending(path: name).appendingPathExtension(url.pathExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            store.alert = AlertMessage(title: "“\(name)” already exists",
                                       message: "Choose a different name, or move the other project first.")
            return
        }
        document.move(to: destination) { [weak self] error in
            MainActor.assumeIsolated {
                if let error {
                    self?.store.alert = AlertMessage(title: "The project couldn't be renamed", message: error.localizedDescription)
                }
                self?.synchronizeWindowTitleWithDocumentName()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        // Show the name without ".overlap", whatever Finder's extension setting is.
        let document = document as? NSDocument
        store.windowTitle = document?.fileURL?.deletingPathExtension().lastPathComponent ?? document?.displayName ?? "Untitled"
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        store.isEdited = dirtyFlag
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.titleItem, .flexibleSpace, Self.exportItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        switch itemIdentifier {
        case Self.titleItem:
            let view = NSHostingView(rootView: WindowTitle(store: store))
            titleView = view
            item.view = view
        case Self.exportItem:
            item.view = NSHostingView(rootView: ExportButton(store: store))
            item.label = "Export"
        default:
            return nil
        }
        return item
    }
}

/// The project name, with "Edited" beside it while there are unsaved changes. Hovering shows a rounded
/// background; clicking edits the name in place. Return, or a click anywhere else, renames the project.
private struct WindowTitle: View {
    @Bindable var store: ProjectStore
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if store.isEditingTitle {
                // The field takes exactly the width of its text, so the title doesn't jump wider when editing starts.
                Text(store.titleDraft.isEmpty ? " " : store.titleDraft)
                    .fixedSize()
                    .hidden()
                    .overlay {
                        TextField("Project name", text: $store.titleDraft)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .focused($isFocused)
                            .onSubmit { store.commitTitleEdit() }
                            .onExitCommand { store.cancelTitleEdit() }
                            .onChange(of: isFocused) { _, focused in
                                if !focused { store.commitTitleEdit() }
                            }
                    }
                    .task { isFocused = true }
            } else {
                HStack(spacing: 8) {
                    Text(store.windowTitle)
                        .foregroundStyle(.primary)
                    if store.isEdited {
                        Text("Edited")
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(store.isEditingTitle ? 0.12 : isHovered ? 0.08 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !store.isEditingTitle else { return }
            store.beginTitleEdit()
        }
        .help("Rename project")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Renames the project")
    }
}

private struct ExportButton: View {
    let store: ProjectStore

    var body: some View {
        Button("Export") {
            store.requestExport()
        }
        .buttonStyle(CapsuleButtonStyle())
        // Nothing on the timeline, nothing to export.
        .disabled(!store.canExport)
        .help(store.canExport ? "Export the project to a file" : "Add media to the timeline to export it")
        .fixedSize()
        // The toolbar puts its last item close to the window edge; this gives it room to breathe.
        .padding(.trailing, 8)
    }
}

/// A solid accent-colored capsule, so it reads the same in the toolbar as in the reference design.
private struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CapsuleButton(configuration: configuration)
    }

    private struct CapsuleButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.12)))
                .contentShape(Capsule())
        }
    }
}
