import AppKit
import SwiftUI

/// What to export and where to put it, then the export's progress until it's done or canceled. Everything else
/// uses settings that suit most videos: H.264 at the canvas size and high quality, or 48 kHz 24-bit sound, at the
/// loudness the Audio tab sets. A toast says when it's done.
struct ExportSheet: View {
    @Bindable var store: ProjectStore
    @State private var name = ""
    @State private var isConfirmingReplace = false

    private var format: ExportSettings.Format { store.exportFormat }
    private var hasPicture: Bool { store.project.hasVisualClips }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var fileName: String { "\(trimmedName).\(format.fileExtension)" }
    private var destination: URL { store.exportFolder.appending(path: fileName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
            if let progress = store.exportProgress {
                progressView(progress)
            } else {
                choices
            }
        }
        .padding(20)
        .frame(width: 440)
        // The panel's own background, so each control's box shows as it does in the inspector.
        .background(Color(nsColor: Theme.chrome))
        .interactiveDismissDisabled(store.isExporting)
        .onAppear {
            if name.isEmpty { name = store.windowTitle }
        }
    }

    // MARK: Choosing

    @ViewBuilder private var choices: some View {
        PanelGroup(title: "Format") {
            OptionRow(title: "Video", options: ExportSettings.Format.video.map { ($0.name, $0) },
                      selected: format.hasVideo ? format : nil) { chosen in
                store.exportSettings.videoFormat = chosen
                store.exportSettings.isAudioOnly = false
            }
            .disabled(!hasPicture)
            .opacity(hasPicture ? 1 : 0.45)
            OptionRow(title: "Audio only", options: ExportSettings.Format.audio.map { ($0.name, $0) },
                      selected: format.hasVideo ? nil : format) { chosen in
                store.exportSettings.audioFormat = chosen
                store.exportSettings.isAudioOnly = true
            }
            if !hasPicture {
                PanelNote(text: "Nothing on the timeline has a picture, so it exports as sound.")
            }
        }

        PanelGroup(title: "Save As") {
            ControlRow(title: "Name") {
                HStack(spacing: 0) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .onSubmit(exportOrConfirm)
                    Text(".\(format.fileExtension)")
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
            }
            MenuRow(title: "Where", value: FileManager.default.displayName(atPath: store.exportFolder.path)) {
                ForEach(Self.standardFolders, id: \.self) { folder in
                    Button(FileManager.default.displayName(atPath: folder.path)) { store.exportFolder = folder }
                }
                Divider()
                Button("Choose…", action: chooseFolder)
            }
        }

        HStack {
            Spacer()
            Button("Cancel") { store.isExportSheetShown = false }
                .keyboardShortcut(.cancelAction)
            Button("Export", action: exportOrConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
        .confirmationDialog("“\(fileName)” already exists.", isPresented: $isConfirmingReplace) {
            Button("Replace", role: .destructive) { store.export(to: destination) }
        } message: {
            Text("Replacing it overwrites the file in \(FileManager.default.displayName(atPath: store.exportFolder.path)).")
        }
    }

    private func exportOrConfirm() {
        guard !trimmedName.isEmpty else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            isConfirmingReplace = true
        } else {
            store.export(to: destination)
        }
    }

    private static let standardFolders: [URL] = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .moviesDirectory, .musicDirectory]
        .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.exportFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let folder = panel.url {
            store.exportFolder = folder
        }
    }

    // MARK: Exporting

    private func progressView(_ progress: Exporter.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exporting “\(fileName)”…")
                .font(.system(size: 13))
            ProgressBar(fraction: progress.fraction)
            HStack {
                Text("\(Int((progress.fraction * 100).rounded(.down)))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// A thin bar that glides between the values it's given, so progress reported in steps still moves smoothly.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color(nsColor: Theme.controlFill))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.3), value: fraction)
            .accessibilityElement()
            .accessibilityLabel("Export progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
