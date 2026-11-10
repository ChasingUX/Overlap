import AppKit
import SwiftUI

/// The Canvas tab: what shows behind the picture, and how the picture sits on it. The canvas is sized on the
/// preview, by dragging its edges with ⌘ held, and plays at the project's frame rate, which follows the first video.
struct CanvasPanel: View {
    let store: ProjectStore

    var body: some View {
        ClipPanel(title: "Canvas") {
            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: store.project.background,
                                 onPreview: { fill in store.previewLook { $0.setBackground(fill) } },
                                 onSelect: { store.setBackground($0) })
            }

            // How the pictures sit on it, once there's a background to show around them.
            if store.project.background != nil {
                PanelGroup(title: "Frame") {
                    let frame = store.project.frame ?? PictureFrame()
                    frameSlider("Padding", frame.padding, range: PictureFrame.paddingRange, default: PictureFrame.standard.padding,
                                format: { "\(Int(($0 * 100).rounded()))%" }) { $0.padding = $1 }
                    frameSlider("Shadow", frame.shadow, range: 0...100, default: PictureFrame.standard.shadow,
                                format: { "\(Int($0.rounded()))" }) { $0.shadow = $1 }
                    frameSlider("Corners", frame.corners, range: 0...0.5, default: PictureFrame.standard.corners,
                                format: { "\(Int(($0 / 0.5 * 100).rounded()))%" }) { $0.corners = $1 }
                }
            }
        }
    }

    private func frameSlider(_ title: String, _ value: Double, range: ClosedRange<Double>, default defaultValue: Double,
                             format: @escaping (Double) -> String,
                             set: @escaping (inout PictureFrame, Double) -> Void) -> some View {
        BoxSlider(title: title, value: value, range: range, format: format, defaultValue: defaultValue,
                  onChange: { new in store.previewFrame { set(&$0, new) } },
                  onCommit: { new in store.setFrame("Change \(title)") { set(&$0, new) } })
    }
}

/// Background choices, top to bottom: None, which leaves the pictures filling the canvas; gradients and wallpapers
/// as square tiles, a row or two of each with Show More for the rest; then plain colors, the built-in ones, a
/// spectrum that opens the color panel, with its eyedropper, for one of your own.
/// Wallpapers are your own images and the Mac's aerials this Mac has downloaded. Any of them drags onto the timeline
/// as a background clip.
struct BackgroundPicker: View {
    let store: ProjectStore
    let selected: BackgroundFill?
    var allowsNone = true
    /// Shows a color while it's being picked in the color panel.
    let onPreview: (BackgroundFill) -> Void
    let onSelect: (BackgroundFill?) -> Void

    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var aerials: [SystemWallpapers.Aerial] = []
    @State private var isPickingColor = false
    @State private var showsAllGradients = false
    @State private var showsAllWallpapers = false

    private static let tileColumns = Array(repeating: GridItem(.flexible(), spacing: SwatchMetrics.tileGap), count: 5)
    private static let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 9)
    /// Two rows of gradients, and of wallpapers with the tile that adds one.
    private static let shownGradients = 10
    private static let shownWallpapers = 9

    /// The project's own images, then wallpapers you've added and the Mac's aerials, each once. One the project has
    /// brought in keeps its place, showing the project's copy.
    private var wallpapers: [WallpaperChoice] {
        let images = store.project.assets.filter { $0.kind == .image }
        let files = WallpaperLibrary.wallpapers()
        let names = Set(files.map(\.lastPathComponent)).union(aerials.flatMap(\.fileNames))
        let brought = { (names: Set<String>) in images.first { names.contains($0.displayName) }.map { WallpaperChoice.asset($0) } }
        return images.filter { !names.contains($0.displayName) }.map { WallpaperChoice.asset($0) }
            + files.map { brought([$0.lastPathComponent]) ?? .file($0) }
            + aerials.map { brought($0.fileNames) ?? .aerial($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if allowsNone {
                NoneButton(isSelected: selected == nil) { choose(nil) }
                    .padding(.bottom, 8)
            }

            let gradients = BackgroundFill.gradients
            heading("Gradients", showsAll: gradients.count > Self.shownGradients ? $showsAllGradients : nil)
            LazyVGrid(columns: Self.tileColumns, spacing: SwatchMetrics.tileGap) {
                ForEach(showsAllGradients ? gradients : Array(gradients.prefix(Self.shownGradients)), id: \.self) { fill in
                    tile(name: "Gradient", isSelected: selected == fill, action: { choose(fill) }) { FillFace(fill: fill) }
                        .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
                }
            }

            let wallpapers = wallpapers
            heading("Wallpapers", showsAll: wallpapers.count > Self.shownWallpapers ? $showsAllWallpapers : nil)
                .padding(.top, 10)
            LazyVGrid(columns: Self.tileColumns, spacing: SwatchMetrics.tileGap) {
                ForEach(showsAllWallpapers ? wallpapers : Array(wallpapers.prefix(Self.shownWallpapers))) { choice in
                    wallpaperTile(choice)
                }
                AddWallpaperTile { store.presentWallpaperPanel { choose($0) } }
                    .aspectRatio(1, contentMode: .fit)
            }
            if aerials.count < 5 {
                Text("Aerials you download in System Settings › Wallpaper show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            caption("Plain color")
                .padding(.top, 10)
            LazyVGrid(columns: Self.colorColumns, spacing: 8) {
                ForEach(BackgroundFill.colors, id: \.self, content: colorSwatch)
                // Chosen while the background is a color of your own. The color panel picks for it until anything
                // else is chosen, so the panel, left open, can't change the background after that.
                ColorWellSwatch(color: selectedColor, showsSpectrum: true, isPicking: isPickingColor, onChange: { onPreview(.color($0)) },
                                onActiveChange: { isPickingColor = $0 }) { color, _ in
                    onSelect(.color(color))
                }
                .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
                .overlay { SwatchRing(isRound: true, isSelected: isOwnColor, isHovered: false) }
                .accessibilityLabel("Custom color")
                .help("Choose a color of your own")
            }
        }
        .task { aerials = await SystemWallpapers.downloaded() }
    }

    private func heading(_ text: String, showsAll: Binding<Bool>?) -> some View {
        HStack {
            caption(text)
            Spacer()
            if let showsAll {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showsAll.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(showsAll.wrappedValue ? "Show Less" : "Show More")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(showsAll.wrappedValue ? 180 : 0))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        PanelLabel(text)
    }

    @ViewBuilder
    private func wallpaperTile(_ choice: WallpaperChoice) -> some View {
        switch choice {
        case let .asset(asset):
            let fill = BackgroundFill.wallpaper(asset.id)
            tile(name: (asset.displayName as NSString).deletingPathExtension, isSelected: selected == fill, action: { choose(fill) }) {
                FillFace(fill: fill, thumbnail: store.thumbnails[asset.id])
            }
            .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
        case let .file(url):
            let name = url.deletingPathExtension().lastPathComponent
            tile(name: name, isSelected: false, action: { store.useWallpaper(url) { choose($0) } }) {
                FillFace(fill: nil, thumbnail: thumbnails[url])
            }
            .help(name)
            .task { thumbnails[url] = await MediaAnalysis.imageThumbnail(for: url) }
        case let .aerial(aerial):
            tile(name: aerial.name, isSelected: false, action: { store.useAerial(aerial) { choose($0) } }) {
                FillFace(fill: nil, thumbnail: thumbnails[aerial.thumbnail])
            }
            .help(aerial.name)
            .task { thumbnails[aerial.thumbnail] = await MediaAnalysis.imageThumbnail(for: aerial.thumbnail) }
        }
    }

    /// A round swatch for a color. It counts as chosen when the background is within a hair of it, as one picked in
    /// the color panel or with its eyedropper can be.
    private func colorSwatch(_ fill: BackgroundFill) -> some View {
        Swatch(isRound: true, isSelected: isChosen(fill), name: "Color", action: { choose(fill) }) { FillFace(fill: fill) }
            .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
            .onDrag { NSItemProvider(object: TimelineDrag.payload(for: fill) as NSString) }
    }

    private func tile<Face: View>(name: String, isSelected: Bool, action: @escaping () -> Void,
                                  @ViewBuilder face: () -> Face) -> some View {
        Swatch(isRound: false, isSelected: isSelected, name: name, action: action, face: face)
            .aspectRatio(1, contentMode: .fit)
    }

    /// Chooses a background other than a color of your own, which ends the color panel's picking.
    private func choose(_ fill: BackgroundFill?) {
        isPickingColor = false
        onSelect(fill)
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

    /// Whether the background is a color that isn't one of the built-in ones.
    private var isOwnColor: Bool {
        guard case .color? = selected else { return false }
        return !BackgroundFill.colors.contains(where: isChosen)
    }
}

/// A wallpaper tile: an image already in the project, or one that comes into it when chosen, from the wallpapers
/// you've added or a still of one of the Mac's aerials.
private enum WallpaperChoice: Identifiable {
    case asset(Asset)
    case file(URL)
    case aerial(SystemWallpapers.Aerial)

    var id: String {
        switch self {
        case let .asset(asset): asset.id.uuidString
        case let .file(url): url.path
        case let .aerial(aerial): aerial.id
        }
    }
}

/// None, as wide as the panel: the pictures fill the canvas, with nothing behind them.
private struct NoneButton: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("None")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: PanelMetrics.boxHeight)
                .background {
                    RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous)
                        .fill(Color(nsColor: isHovered && !isSelected ? Theme.controlFill : Theme.controlBox))
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: PanelMetrics.boxRadius + SwatchMetrics.ringOutset, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: SwatchMetrics.ringWidth)
                            .padding(-SwatchMetrics.ringOutset)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("No background")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Swatch sizes, and how far outside a swatch the ring marking it sits.
enum SwatchMetrics {
    static let circle: CGFloat = 20
    /// A color swatch at the end of a row, a little smaller than the picker's.
    static let rowCircle: CGFloat = 20
    static let tileRadius: CGFloat = 12
    /// Between gradient and wallpaper tiles, across and down.
    static let tileGap: CGFloat = 12
    static let ringWidth: CGFloat = 2
    /// The ring's outer edge: a two-point gap, then the ring.
    static let ringOutset: CGFloat = 4
    /// How much black None and + are filled with, so they sit darker than the box, unlike a color.
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
/// A tool, such as None, sits on the dark tool shade instead, matching the + drawn by its color well.
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
            case let .mesh(mesh)?:
                // Drawn by the renderer the canvas uses, so the tile looks as the background will.
                // Drawn at twice a tile's size, so grain softens as it does on a canvas seen whole.
                if let image = MeshRenderer.image(mesh, size: CGSize(width: 192, height: 192)) {
                    Image(decorative: image, scale: 1).resizable()
                }
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
