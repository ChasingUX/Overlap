import SwiftUI
import UniformTypeIdentifiers

struct MediaPanel: View {
    let store: ProjectStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media")
                    .font(.headline)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if store.project.assets.isEmpty && store.pendingImports.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.pendingImports) { pending in
                            PendingRow(name: pending.name)
                        }
                        ForEach(store.project.assets) { asset in
                            AssetRow(asset: asset, store: store)
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
        VStack(spacing: 8) {
            AppIcon.media.image
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Import video and audio")
                .font(.headline)
            Text("Drag files here or onto the timeline, or choose Import. Each file is copied into the project.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Import Media…") {
                store.presentImportPanel()
            }
            .padding(.top, 6)
        }
        .padding(24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
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

private struct AssetRow: View {
    let asset: Asset
    let store: ProjectStore

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 48, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: TimelineDrag.payload(for: asset.id) as NSString)
        }
        .contextMenu {
            Button("Remove from Project", role: .destructive) {
                store.requestRemoveAsset(asset)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = store.thumbnails[asset.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if asset.kind == .audio, let waveform = store.waveforms[asset.id] {
            WaveformThumbnail(waveform: waveform, duration: asset.duration.seconds)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                (asset.kind == .video ? AppIcon.video : AppIcon.waveform).image
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        switch asset.kind {
        case .video:
            if let width = asset.pixelWidth, let height = asset.pixelHeight { parts.append("\(width)×\(height)") }
            if let rate = asset.frameRate { parts.append("\(rate.formatted(.number.precision(.fractionLength(0...2)))) fps") }
        case .audio:
            if let rate = asset.sampleRate { parts.append("\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
            if let channels = asset.channelCount { parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) ch") }
        }
        parts.append(asset.duration.shortDuration)
        return parts.joined(separator: " · ")
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
