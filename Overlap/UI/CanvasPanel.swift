import AppKit
import SwiftUI

/// The Canvas tab: the canvas's shape and frame rate, what shows behind the picture, and the whole-picture frame.
struct CanvasPanel: View {
    let store: ProjectStore
    /// Set when Custom is chosen from the menu, so the size fields take the keyboard.
    @State private var editsCustomSize = false

    private var canvas: Canvas { store.project.canvas ?? Project.defaultCanvas }
    private var aspect: CanvasAspect { store.project.canvasAspect }

    var body: some View {
        ClipPanel(title: "Canvas") {
            PanelGroup(title: "Size") {
                PopUpRow(title: "Shape", value: shapeValue,
                         icon: Self.shapeImage(width: canvas.width, height: canvas.height, dashed: aspect == .auto),
                         items: { shapeItems })
                CanvasSizeRow(canvas: canvas, keepsShape: aspect != .custom, takesFocus: editsCustomSize) {
                    store.setCanvasSize(width: $0, height: $1)
                }
                MenuRow(title: "Frame rate", value: Self.rateName(canvas.frameRate)) {
                    ForEach(CanvasAspect.frameRates, id: \.self) { rate in
                        Toggle(Self.rateName(rate), isOn: Binding(get: { abs(canvas.frameRate - rate) < 0.01 },
                                                                  set: { _ in store.setFrameRate(rate) }))
                    }
                }
            }

            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: store.project.background,
                                 onPreview: { fill in store.previewLook { $0.background = fill } },
                                 onSelect: { store.setBackground($0) })
            }

            PanelGroup(title: "Frame") {
                FrameControls(store: store)
            }
        }
    }

    /// Auto says what it's following; the rest go by name, since the menu and the Pixels row give the numbers.
    private var shapeValue: String {
        switch aspect {
        case .auto: "Auto · \(CanvasAspect.ratioName(width: canvas.width, height: canvas.height))"
        default: aspect.title
        }
    }

    private var shapeItems: [PopUpRow.Item] {
        // What Auto would give: the first video's shape, or widescreen before there is one.
        let follows = store.project.firstVideoCanvas ?? Canvas(width: 1920, height: 1080, frameRate: canvas.frameRate)
        var items = [PopUpRow.Item(title: CanvasAspect.auto.title,
                                   detail: CanvasAspect.ratioName(width: follows.width, height: follows.height),
                                   subtitle: "Matches the first video",
                                   image: Self.shapeImage(width: follows.width, height: follows.height, dashed: true),
                                   isChosen: aspect == .auto,
                                   action: { choose(.auto) })]
        for (index, shape) in CanvasAspect.allCases.filter({ $0.size != nil }).enumerated() {
            let size = shape.size!
            items.append(PopUpRow.Item(title: shape.title, detail: shape.rawValue,
                                       image: Self.shapeImage(width: size.width, height: size.height, dashed: false),
                                       isChosen: aspect == shape, startsGroup: index == 0, action: { choose(shape) }))
        }
        // A pencil, for typing a size of your own, so its title lines up with the shapes'.
        let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        items.append(PopUpRow.Item(title: "Custom…", detail: aspect == .custom ? "\(canvas.width) × \(canvas.height)" : nil,
                                   image: pencil, isChosen: aspect == .custom, startsGroup: true, action: {
            editsCustomSize = true
            if aspect != .custom { store.setCanvasAspect(.custom) }
        }))
        return items
    }

    private func choose(_ shape: CanvasAspect) {
        editsCustomSize = false
        if shape != aspect { store.setCanvasAspect(shape) }
    }

    static func rateName(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...3)))) fps"
    }

    /// A shape's outline, small enough for a menu: the size's proportions in a box the height of a line of text,
    /// dashed for Auto, which follows the first video. A template, so it takes the menu's colors.
    static func shapeImage(width: Int, height: Int, dashed: Bool) -> NSImage {
        let ratio = Double(width) / Double(max(height, 1))
        let room = CGSize(width: 15, height: 11)
        let size = ratio > room.width / room.height
            ? CGSize(width: room.width, height: room.width / ratio)
            : CGSize(width: room.height * ratio, height: room.height)
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { bounds in
            let shape = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            let path = NSBezierPath(roundedRect: shape, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1.3
            if dashed { path.setLineDash([2, 1.6], count: 2, phase: 0) }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Width and height fields for the canvas, taken on Return or on leaving the field. A fixed shape, or Auto, keeps
/// its proportions: change one side and the other follows. Custom takes both as typed. Choosing Custom from the
/// menu puts the cursor in the width.
private struct CanvasSizeRow: View {
    let canvas: Canvas
    let keepsShape: Bool
    var takesFocus = false
    let onCommit: (Int, Int) -> Void

    @State private var width = ""
    @State private var height = ""
    @FocusState private var focus: Side?

    private enum Side { case width, height }

    var body: some View {
        ControlRow(title: "Pixels") {
            HStack(spacing: 4) {
                field($width, .width)
                Text("×")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                field($height, .height)
            }
        }
        .onAppear {
            load()
            if takesFocus { focus = .width }
        }
        .onChange(of: canvas) { load() }
        .onChange(of: takesFocus) { _, takes in
            if takes { focus = .width }
        }
        .onChange(of: focus) { left, _ in
            if let left { commit(left) }
        }
    }

    private func field(_ text: Binding<String>, _ side: Side) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 52, height: PanelMetrics.boxHeight - PanelMetrics.pillInset * 2)
            .background(ChosenPill())
            .focused($focus, equals: side)
            .onSubmit { commit(side) }
            .accessibilityLabel(side == .width ? "Width" : "Height")
    }

    private func load() {
        width = String(canvas.width)
        height = String(canvas.height)
    }

    private func commit(_ side: Side) {
        guard var w = Int(width), var h = Int(height), w > 0, h > 0 else { return load() }
        if keepsShape {
            let ratio = Double(canvas.width) / Double(max(canvas.height, 1))
            switch side {
            case .width: h = Int((Double(w) / ratio).rounded())
            case .height: w = Int((Double(h) * ratio).rounded())
            }
        }
        guard w != canvas.width || h != canvas.height else { return load() }
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

/// Background swatches: None, built-in colors, saved custom colors, gradients and wallpapers, then + for a color
/// of your own and an eyedropper for one from the screen, and a way to add wallpapers. Swatches drag onto the
/// timeline as background clips.
struct BackgroundPicker: View {
    let store: ProjectStore
    let selected: BackgroundFill?
    var allowsNone = true
    /// Shows a color while it's being picked in the color panel.
    let onPreview: (BackgroundFill) -> Void
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
                AddColorSwatch(color: selectedColor, onChange: { onPreview(.color($0)) }) { color, earlier in
                    WallpaperLibrary.remember(color, replacing: earlier)
                    onSelect(.color(color))
                }
                .frame(height: 26)
                .accessibilityLabel("Custom color")
                .help("Choose a color of your own")
                EyedropperSwatch { color in
                    WallpaperLibrary.remember(color)
                    onSelect(.color(color))
                }
                .frame(height: 26)
            }
            .padding(8)
            .background(ControlBox())

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
                Slash()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
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

/// None's mark: a line from corner to corner, whatever the tile's size, ending where the tile's rounded corners
/// cut it off.
private struct Slash: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
