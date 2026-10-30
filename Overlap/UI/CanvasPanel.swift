import SwiftUI

/// The Canvas tab: the canvas's shape and frame rate, what shows behind the picture, and the whole-picture frame.
struct CanvasPanel: View {
    let store: ProjectStore

    private var canvas: Canvas { store.project.canvas ?? Project.defaultCanvas }

    var body: some View {
        ClipPanel(title: "Canvas") {
            PanelGroup(title: "Size") {
                OptionGrid(options: CanvasAspect.allCases.map { ($0.name, $0) }, selected: store.project.canvasAspect) {
                    store.setCanvasAspect($0)
                }
                if store.project.canvasAspect == .custom {
                    CanvasSizeRow(canvas: canvas) { store.setCanvasSize(width: $0, height: $1) }
                } else {
                    ValueRow(title: "Pixels", value: "\(canvas.width) × \(canvas.height)")
                }
                MenuRow(title: "Frame rate", value: Self.rateName(canvas.frameRate)) {
                    ForEach(CanvasAspect.frameRates, id: \.self) { rate in
                        Toggle(Self.rateName(rate), isOn: Binding(get: { abs(canvas.frameRate - rate) < 0.01 },
                                                                  set: { _ in store.setFrameRate(rate) }))
                    }
                }
            }

            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: store.project.background) { store.setBackground($0) }
            }

            PanelGroup(title: "Frame") {
                FrameControls(store: store)
            }
        }
    }

    static func rateName(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...3)))) fps"
    }
}

/// Width and height fields for a custom canvas.
private struct CanvasSizeRow: View {
    let canvas: Canvas
    let onCommit: (Int, Int) -> Void

    @State private var width = ""
    @State private var height = ""

    var body: some View {
        ControlRow(title: "Size") {
            HStack(spacing: 4) {
                field($width)
                Text("×").foregroundStyle(.secondary)
                field($height)
            }
        }
        .onAppear(perform: load)
        .onChange(of: canvas) { load() }
    }

    private func field(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 52, height: PanelMetrics.boxHeight - PanelMetrics.pillInset * 2)
            .background(ChosenPill())
            .onSubmit(commit)
    }

    private func load() {
        width = String(canvas.width)
        height = String(canvas.height)
    }

    private func commit() {
        guard let w = Int(width), let h = Int(height) else { return load() }
        onCommit(w, h)
    }
}

/// Padding, shadow and corners for the composed picture. They need a background to show around it.
private struct FrameControls: View {
    let store: ProjectStore

    private var frame: PictureFrame { store.project.frame }

    var body: some View {
        let hasBackground = store.project.background != nil
        VStack(spacing: 6) {
            slider("Padding", \.padding, range: 0...0.25, format: { "\(Int(($0 * 100).rounded()))%" })
            slider("Shadow", \.shadow, range: 0...100, format: { "\(Int($0.rounded()))" })
            slider("Corners", \.corners, range: 0...0.25, format: { "\(Int(($0 / 0.25 * 100).rounded()))%" })
        }
        .disabled(!hasBackground)
        .opacity(hasBackground ? 1 : 0.5)
        if !hasBackground {
            ComingLater(text: "Choose a background to frame the picture.")
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<PictureFrame, Double>, range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        BoxSlider(title: title, value: frame[keyPath: key], range: range, format: format, defaultValue: 0,
                  onChange: { value in store.previewLook { $0.frame[keyPath: key] = value } },
                  onCommit: { value in store.setFrame("Change \(title)") { $0[keyPath: key] = value } })
    }
}

/// Background swatches: None, built-in colors, saved custom colors, gradients and wallpapers, then a custom color
/// well and a way to add wallpapers. Swatches drag onto the timeline as background clips.
struct BackgroundPicker: View {
    let store: ProjectStore
    let selected: BackgroundFill?
    var allowsNone = true
    let onSelect: (BackgroundFill?) -> Void

    @State private var libraryThumbnails: [URL: CGImage] = [:]

    private var projectWallpapers: [Asset] {
        store.project.assets.filter { $0.kind == .image }
    }

    /// Library wallpapers this project hasn't brought in yet.
    private var libraryWallpapers: [URL] {
        let names = Set(projectWallpapers.map(\.displayName))
        return WallpaperLibrary.wallpapers().filter { !names.contains($0.lastPathComponent) }
    }

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                if allowsNone {
                    Swatch(fill: nil, isSelected: selected == nil) { onSelect(nil) }
                }
                let fills = BackgroundFill.colors + WallpaperLibrary.customColors.map { .color($0) } + BackgroundFill.gradients
                    + projectWallpapers.map { .wallpaper($0.id) }
                ForEach(fills, id: \.self) { fill in
                    Swatch(fill: fill, thumbnail: thumbnail(of: fill), isSelected: selected == fill) { onSelect(fill) }
                        .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
                }
                ForEach(libraryWallpapers, id: \.self) { url in
                    Swatch(fill: nil, thumbnail: libraryThumbnails[url], isSelected: false) { store.useWallpaper(url) }
                        .task { libraryThumbnails[url] = await MediaAnalysis.imageThumbnail(for: url) }
                }
            }
            .padding(8)
            .background(ControlBox())

            ColorRow(title: "Custom color", color: selectedColor,
                     onChange: { color in store.previewLook { $0.background = .color(color) } },
                     onCommit: { color in
                         WallpaperLibrary.remember(color)
                         onSelect(.color(color))
                     })
            Button("Add Wallpaper…") { store.presentWallpaperPanel() }
                .buttonStyle(BoxButtonStyle())
        }
    }

    private var selectedColor: RGBA {
        if case let .color(color)? = selected { color } else { .white }
    }

    private func thumbnail(of fill: BackgroundFill) -> CGImage? {
        if case let .wallpaper(id) = fill { store.thumbnails[id] } else { nil }
    }
}

/// A small tile showing a fill. None shows as an empty tile with a slash.
struct Swatch: View {
    let fill: BackgroundFill?
    var thumbnail: CGImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay { content }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                }
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            switch fill {
            case let .color(color)?:
                Color(rgba: color)
            case let .gradient(gradient)?:
                let angle = gradient.angle * .pi / 180
                LinearGradient(colors: [Color(rgba: gradient.from), Color(rgba: gradient.to)],
                               startPoint: UnitPoint(x: 0.5 - cos(angle) / 2, y: 0.5 - sin(angle) / 2),
                               endPoint: UnitPoint(x: 0.5 + cos(angle) / 2, y: 0.5 + sin(angle) / 2))
            case .wallpaper?:
                Color.primary.opacity(0.1)
            case nil:
                Path { path in
                    path.move(to: CGPoint(x: 6, y: 20))
                    path.addLine(to: CGPoint(x: 30, y: 6))
                }
                .stroke(Color.secondary, lineWidth: 1.5)
            }
        }
    }

    private var name: String {
        switch fill {
        case .color?: "Color"
        case .gradient?: "Gradient"
        case .wallpaper?: "Wallpaper"
        case nil: thumbnail == nil ? "None" : "Wallpaper"
        }
    }
}
