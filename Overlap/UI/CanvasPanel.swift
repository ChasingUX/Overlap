import AppKit
import SwiftUI

/// The Canvas tab: the canvas's shape and frame rate, and what shows behind the picture.
struct CanvasPanel: View {
    let store: ProjectStore
    /// Set when Custom is chosen from the menu, so the size fields take the keyboard.
    @State private var editsCustomSize = false

    private var canvas: Canvas { store.project.canvas ?? Project.defaultCanvas }
    private var aspect: CanvasAspect { store.project.canvasAspect }

    var body: some View {
        ClipPanel(title: "Canvas") {
            PanelGroup(title: "Size") {
                PanelCard {
                    PopUpRow(title: "Shape", value: shapeValue, items: { shapeItems })
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
            }

            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: store.project.background,
                                 onPreview: { fill in store.previewLook { $0.background = fill } },
                                 onSelect: { store.setBackground($0) })
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

/// Width and height for the canvas, plain numbers on the card until clicked, then typed over and taken on Return
/// or on leaving the field. A fixed shape, or Auto, keeps its proportions: change one side and the other follows.
/// Custom takes both as typed. Choosing Custom from the menu puts the cursor in the width.
private struct CanvasSizeRow: View {
    let canvas: Canvas
    let keepsShape: Bool
    var takesFocus = false
    let onCommit: (Int, Int) -> Void

    @State private var width = ""
    @State private var height = ""
    @FocusState private var focus: Side?
    @State private var hovered: Side?

    private enum Side { case width, height }

    var body: some View {
        ControlRow(title: "Pixels") {
            HStack(spacing: 2) {
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
            .frame(width: 42, height: valueHeight(inCard: true))
            .background {
                // A field shows once it's pointed at, and stays lit while you type in it.
                RoundedRectangle(cornerRadius: PanelMetrics.pillRadius, style: .continuous)
                    .fill(Color(nsColor: focus == side ? Theme.controlChosen : Theme.controlFill))
                    .opacity(focus == side || hovered == side ? 1 : 0)
            }
            .focused($focus, equals: side)
            .onHover { isOver in
                if isOver { hovered = side } else if hovered == side { hovered = nil }
            }
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

/// Background swatches in three sections. Colors: None, the built-in colors, then your own, with + for a color of
/// your own and an eyedropper for one from the screen. Gradients. Wallpapers, with + to add one. Colors are round;
/// gradients and wallpapers are tiles the canvas's shape. Swatches drag onto the timeline as background clips.
struct BackgroundPicker: View {
    let store: ProjectStore
    let selected: BackgroundFill?
    var allowsNone = true
    /// Shows a color while it's being picked in the color panel.
    let onPreview: (BackgroundFill) -> Void
    let onSelect: (BackgroundFill?) -> Void

    @State private var libraryThumbnails: [URL: CGImage] = [:]
    @State private var isPickingColor = false

    /// None and the six built-in colors make one full row; your colors start the next.
    private static let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private static let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var projectWallpapers: [Asset] {
        store.project.assets.filter { $0.kind == .image }
    }

    /// Library wallpapers this project hasn't brought in yet.
    private var libraryWallpapers: [URL] {
        let names = Set(projectWallpapers.map(\.displayName))
        return WallpaperLibrary.wallpapers().filter { !names.contains($0.lastPathComponent) }
    }

    /// The canvas's shape, kept between square and twice as wide as tall so tiles stay a sensible size.
    private var tileAspect: CGFloat {
        let canvas = store.project.canvas ?? Project.defaultCanvas
        return (CGFloat(canvas.width) / CGFloat(max(canvas.height, 1))).clamped(to: 1...2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Colors")
            LazyVGrid(columns: Self.colorColumns, spacing: 10) {
                if allowsNone {
                    Swatch(isRound: true, isSelected: selected == nil, name: "None", isTool: true, action: { onSelect(nil) }) {
                        Slash().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
                }
                ForEach(BackgroundFill.colors, id: \.self, content: colorSwatch)
            }
            LazyVGrid(columns: Self.colorColumns, spacing: 10) {
                ForEach(WallpaperLibrary.customColors.map { BackgroundFill.color($0) }, id: \.self, content: colorSwatch)
                AddColorSwatch(color: selectedColor, onChange: { onPreview(.color($0)) },
                               onActiveChange: { isPickingColor = $0 }) { color, earlier in
                    onSelect(.color(WallpaperLibrary.remember(color, replacing: earlier)))
                }
                .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
                .overlay { SwatchRing(isRound: true, isSelected: isPickingColor, isHovered: false) }
                .accessibilityLabel("Custom color")
                .help("Choose a color of your own")
                EyedropperSwatch { color in
                    onSelect(.color(WallpaperLibrary.remember(color)))
                }
                .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
            }
            .padding(.top, 4)

            caption("Gradients")
                .padding(.top, 8)
            LazyVGrid(columns: Self.tileColumns, spacing: 8) {
                ForEach(BackgroundFill.gradients, id: \.self) { fill in
                    tile(name: "Gradient", isSelected: selected == fill, action: { onSelect(fill) }) { FillFace(fill: fill) }
                        .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
                }
            }

            caption("Wallpapers")
                .padding(.top, 8)
            LazyVGrid(columns: Self.tileColumns, spacing: 8) {
                ForEach(projectWallpapers) { asset in
                    let fill = BackgroundFill.wallpaper(asset.id)
                    tile(name: "Wallpaper", isSelected: selected == fill, action: { onSelect(fill) }) {
                        FillFace(fill: fill, thumbnail: store.thumbnails[asset.id])
                    }
                    .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
                }
                ForEach(libraryWallpapers, id: \.self) { url in
                    tile(name: "Wallpaper", isSelected: false, action: { store.useWallpaper(url) { onSelect($0) } }) {
                        FillFace(fill: nil, thumbnail: libraryThumbnails[url])
                    }
                    .task { libraryThumbnails[url] = await MediaAnalysis.imageThumbnail(for: url) }
                }
                AddWallpaperTile { store.presentWallpaperPanel { onSelect($0) } }
                    .aspectRatio(tileAspect, contentMode: .fit)
            }
        }
        .padding(10)
        .background(ControlBox())
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }

    /// A round swatch for a color. It counts as chosen when the background is within a hair of it, as a color
    /// kept before near-copies were skipped can be.
    private func colorSwatch(_ fill: BackgroundFill) -> some View {
        Swatch(isRound: true, isSelected: isChosen(fill), name: "Color", action: { onSelect(fill) }) { FillFace(fill: fill) }
            .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
            .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
    }

    private func tile<Face: View>(name: String, isSelected: Bool, action: @escaping () -> Void,
                                  @ViewBuilder face: () -> Face) -> some View {
        Swatch(isRound: false, isSelected: isSelected, name: name, action: action, face: face)
            .aspectRatio(tileAspect, contentMode: .fit)
    }

    private func isChosen(_ fill: BackgroundFill) -> Bool {
        if case let .color(chosen)? = selected, case let .color(color) = fill {
            return chosen.isNear(color)
        }
        return selected == fill
    }

    private var selectedColor: RGBA {
        if case let .color(color)? = selected { color } else { .white }
    }
}

/// Swatch sizes, and how far outside a swatch the ring marking it sits.
enum SwatchMetrics {
    static let circle: CGFloat = 24
    static let tileRadius: CGFloat = 6
    static let ringWidth: CGFloat = 2
    /// The ring's outer edge: a two-point gap, then the ring.
    static let ringOutset: CGFloat = 4
    /// How much black None, + and the eyedropper are filled with, so they sit darker than the box, unlike a color.
    static let toolShade = 0.3
}

/// A swatch's outline: round for colors, a rounded rectangle for tiles, `outset` points outside the swatch.
private func swatchShape(isRound: Bool, outset: CGFloat = 0) -> RoundedRectangle {
    isRound ? RoundedRectangle(cornerRadius: SwatchMetrics.circle / 2 + outset, style: .circular)
        : RoundedRectangle(cornerRadius: SwatchMetrics.tileRadius + outset, style: .continuous)
}

/// The ring just outside a swatch, past a small gap: the accent color on the chosen one, faint under the pointer.
struct SwatchRing: View {
    let isRound: Bool
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        if isSelected || isHovered {
            swatchShape(isRound: isRound, outset: SwatchMetrics.ringOutset)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: SwatchMetrics.ringWidth)
                .padding(-SwatchMetrics.ringOutset)
                .allowsHitTesting(false)
        }
    }
}

/// A clickable swatch: its face on a faint fill, a hairline so dark colors stand out from the box, and the ring.
/// A tool (None, the eyedropper) sits on the dark tool shade instead, matching the + drawn by its color well.
struct Swatch<Face: View>: View {
    let isRound: Bool
    let isSelected: Bool
    let name: String
    var isTool = false
    let action: () -> Void
    @ViewBuilder var face: Face

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            swatchShape(isRound: isRound)
                .fill(isTool ? Color.black.opacity(SwatchMetrics.toolShade) : Color.primary.opacity(0.06))
                .overlay { face }
                .clipShape(swatchShape(isRound: isRound))
                .overlay { swatchShape(isRound: isRound).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1) }
                .overlay { SwatchRing(isRound: isRound, isSelected: isSelected, isHovered: isHovered) }
                .contentShape(swatchShape(isRound: isRound))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What a fill looks like on a swatch: the color, the gradient, or the wallpaper's thumbnail.
struct FillFace: View {
    let fill: BackgroundFill?
    var thumbnail: CGImage?

    var body: some View {
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
            case .wallpaper?, nil:
                Color.clear
            }
        }
    }
}

/// The last wallpaper tile: a dashed outline with a +, which adds wallpapers to the library.
private struct AddWallpaperTile: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            swatchShape(isRound: false)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.4 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovered ? .primary : .secondary)
                }
                .contentShape(swatchShape(isRound: false))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Add wallpapers")
        .accessibilityLabel("Add wallpapers")
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
