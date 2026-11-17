import SwiftUI
import UniformTypeIdentifiers

/// The Media tab: the project's assets, newest last, each with its picture or sound, name and length. Click one to
/// add it at the playhead, or drag it onto the timeline or the canvas.
struct MediaPanel: View {
    let store: ProjectStore
    @State private var isDropTargeted = false

    /// For checks: OVERLAP_SNAPSHOT_HOVERASSET=1 draws the first asset as if the pointer were over it.
    private static let hoversFirstRow: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["OVERLAP_SNAPSHOT_HOVERASSET"] != nil
        #else
        false
        #endif
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The top row other panels' first labels line up with.
            HStack {
                PanelLabel("Assets")
                Spacer()
                Button {
                    store.presentImportPanel()
                } label: {
                    AppIcon.importMedia.image
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("Import media (⌘I)")
                .accessibilityLabel("Import media")
            }
            .frame(height: PanelMetrics.topRowHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, PanelMetrics.topRowInset)

            let listed = store.project.assets.filter(\.isListedInMedia)
            if listed.isEmpty && store.pendingImports.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.pendingImports) { pending in
                            PendingRow(name: pending.name)
                        }
                        ForEach(listed) { asset in
                            AssetRow(asset: asset, store: store, startsHovered: Self.hoversFirstRow && asset.id == listed.first?.id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
        // Only files from Finder count as a drop here, so dragging an asset out of the list doesn't light up the outline.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in
                        store.importFiles([url])
                    }
                }
            }
            return true
        }
    }

    private var emptyState: some View {
        PlaceholderPanel(icon: .media, title: "Import video and audio",
                         message: "Drag files here or onto the timeline, or choose Import.",
                         action: (title: "Import Media…", perform: { store.presentImportPanel() }))
            // In the middle of the whole panel, as other tabs' empty states are, not just of the space under the top row.
            .padding(.bottom, PanelMetrics.topRowHeight + PanelMetrics.topRowInset * 2)
    }
}

private struct PendingRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 48, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Copying into the project…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One asset: its picture or sound, its name and what it is. It lights up under the pointer, and clicking it adds
/// it at the playhead. Dragging it carries its thumbnail to the timeline or the canvas.
private struct AssetRow: View {
    let asset: Asset
    let store: ProjectStore

    @State private var isHovered: Bool

    init(asset: Asset, store: ProjectStore, startsHovered: Bool = false) {
        self.asset = asset
        self.store = store
        _isHovered = State(initialValue: startsHovered)
    }

    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnail(asset: asset, store: store)
                .frame(width: 48, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.shownName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(asset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { store.addAssetAtPlayhead(asset.id) }
        .onDrag {
            NSItemProvider(object: TimelineDrag.payload(for: asset.id) as NSString)
        } preview: {
            AssetDragPreview(asset: asset, store: store)
        }
        .help("Add at the playhead, or drag to the timeline or the canvas")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.addAssetAtPlayhead(asset.id) }
        .accessibilityHint("Adds it at the playhead")
        .contextMenu {
            Button("Remove from Project", role: .destructive) {
                store.requestRemoveAsset(asset)
            }
        }
    }
}

/// An asset's picture, or its sound's waveform, or an icon for what it is until either is made.
private struct AssetThumbnail: View {
    let asset: Asset
    let store: ProjectStore

    var body: some View {
        if let image = store.thumbnails[asset.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if asset.kind == .audio, let waveform = store.waveforms[asset.id] {
            WaveformThumbnail(waveform: waveform, duration: asset.duration.seconds)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                (asset.kind == .video ? AppIcon.video : asset.kind == .image ? AppIcon.image : AppIcon.waveform).image
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What follows the pointer while an asset is dragged: its thumbnail, bigger, in the picture's own shape.
struct AssetDragPreview: View {
    let asset: Asset
    let store: ProjectStore

    static let width: CGFloat = 128

    /// The picture's shape, kept between a wide strip and a square; a sound is a strip.
    private var height: CGFloat {
        guard asset.kind != .audio, let image = store.thumbnails[asset.id], image.width > 0 else { return 44 }
        let ratio = CGFloat(image.height) / CGFloat(image.width)
        return (Self.width * ratio).clamped(to: 44...Self.width)
    }

    var body: some View {
        AssetThumbnail(asset: asset, store: store)
            .frame(width: Self.width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .environment(\.colorScheme, .dark)
    }

    #if DEBUG
    /// The thumbnail as it's dragged, at twice its size, for the debug self-check.
    @MainActor static func debugImage(of asset: Asset, store: ProjectStore) -> CGImage? {
        let renderer = ImageRenderer(content: AssetDragPreview(asset: asset, store: store))
        renderer.scale = 2
        return renderer.cgImage
    }
    #endif
}

extension Asset {
    /// The name without its file's extension: "Theme" for Theme.m4a. A name whose last dot isn't a media file's
    /// extension, such as a screen recording's time, stays whole.
    var shownName: String {
        let name = displayName as NSString
        let ext = name.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent) || type.conforms(to: .image) else { return displayName }
        let stem = name.deletingPathExtension
        return stem.isEmpty ? displayName : stem
    }

    /// What it is and how long: "Video · 0:15", "Audio · 0:20", or "Image", which has no length of its own.
    var summary: String {
        switch kind {
        case .video: "Video · \(duration.shortDuration)"
        case .audio: "Audio · \(duration.shortDuration)"
        case .image: "Image"
        }
    }
}

/// A whole file's waveform in the timeline's style: 1.5-point gray bars on the audio clip background,
/// scaled to the file's loudest moment so quiet recordings still show their shape.
private struct WaveformThumbnail: View {
    let waveform: Waveform
    let duration: Double

    var body: some View {
        // Spelled out because the project model has its own `Canvas`.
        SwiftUI.Canvas { context, size in
            let inset: CGFloat = 5
            let step: CGFloat = 2.5
            let bars = max(1, Int((size.width - inset * 2) / step))
            let span = duration / Double(bars)
            let peaks = (0..<bars).map { waveform.peak(from: Double($0) * span, to: Double($0 + 1) * span) }
            let loudest = max(peaks.max() ?? 0, 0.001)
            // The loudest bar reaches half the thumbnail's height.
            let usable = size.height * 0.5
            for (index, peak) in peaks.enumerated() {
                let height = max(1, CGFloat(peak / loudest) * usable)
                let bar = CGRect(x: inset + CGFloat(index) * step, y: (size.height - height) / 2, width: 1.5, height: height)
                context.fill(Path(bar), with: .color(Color(nsColor: Theme.thumbnailWaveform)))
            }
        }
        .background(Color(nsColor: Theme.audioClipBottom))
        .accessibilityHidden(true)
    }
}

extension Time {
    /// Formats as minutes and seconds, such as 3:05.
    var shortDuration: String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
