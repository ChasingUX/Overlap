import AppKit
import SwiftUI

/// The Text tab. With a text clip selected: its font, weight, color, how it stands out from the picture, and how it
/// comes in and goes out. The words are typed on the canvas, and the preview's handles place and size the text; its
/// lines follow where it sits, lining up left in the canvas's left third, right in its right third. Otherwise, the title styles as small canvases with the text in place, to drag onto the timeline or
/// click to add at the playhead, ready to type over.
struct TextPanel: View {
    let store: ProjectStore

    var body: some View {
        if let clip = store.selectedClips.first, let title = clip.title {
            ClipPanel(title: "Text") {
                TitleEditor(store: store, title: title)
                    .id(clip.id)
            }
        } else {
            ClipPanel(title: "Text") {
                PanelGroup(title: "Titles") {
                    TitleStyleGrid(store: store)
                }
            }
        }
    }
}

/// The title styles two to a row, each drawn by the renderer the canvas uses, at the canvas's shape.
private struct TitleStyleGrid: View {
    let store: ProjectStore

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 2)

    var body: some View {
        let canvas = store.project.canvas ?? Project.defaultCanvas
        let size = CGSize(width: canvas.width, height: canvas.height)
        LazyVGrid(columns: Self.columns, spacing: 12) {
            ForEach(TitleStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 5) {
                    Swatch(isRound: false, isSelected: false, name: style.name, action: { store.addTitleAtPlayhead(style) }) {
                        if let image = TitleStyleGrid.picture(of: style, canvas: size) {
                            Image(decorative: image, scale: 1).resizable()
                        }
                    }
                    .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                    .onDrag { NSItemProvider(object: TimelineDrag.payload(for: style) as NSString) }
                    .help("Click to add at the playhead, or drag onto the timeline")
                    PanelLabel(style.name)
                        .padding(.leading, 2)
                }
            }
        }
    }

    /// Styles drawn once per canvas shape, at twice a tile's size.
    @MainActor private static var pictures: [String: CGImage] = [:]

    private static func picture(of style: TitleStyle, canvas: CGSize) -> CGImage? {
        let key = "\(style.rawValue) \(Int(canvas.width))×\(Int(canvas.height))"
        if let found = pictures[key] { return found }
        let drawn = TitleRenderer.frame(for: style.title, visual: style.visual, canvas: canvas, height: 220, asTile: true)
        if pictures.count > 48 { pictures.removeAll() }
        pictures[key] = drawn
        return drawn
    }
}

/// Every setting of the selected text clip.
private struct TitleEditor: View {
    let store: ProjectStore
    let title: Title

    /// Set while the second animation row shows though both ends are the same, as just after it's switched on.
    @State private var splitsAnimation = false
    @State private var isPickingColor = false

    private static let families = NSFontManager.shared.availableFontFamilies
    private static let faces = TitleFont.faces.filter { families.contains($0) }
    /// White, black and three of the plain colors, before the spectrum.
    private static let colors: [RGBA] = [0xFFFFFF, 0x141414, 0xECB851, 0xDB5B5D, 0x4D9DE7].map { RGBA(hex: $0) }

    private var showsGoingOut: Bool { splitsAnimation || title.animationIn != title.animationOut }

    var body: some View {
        PanelGroup(title: "Title") {
            PanelCard {
                MenuRow(title: "Font", value: TitleFont.name(of: title.fontFamily)) {
                    font("System", family: "")
                    ForEach(TitleFont.designs, id: \.family) { design in
                        font(design.name, family: design.family)
                    }
                    Divider()
                    ForEach(Self.faces, id: \.self) { face in
                        font(face, family: face)
                    }
                    Divider()
                    Menu("More Fonts") {
                        ForEach(Self.families, id: \.self) { family in
                            font(family, family: family)
                        }
                    }
                }
                MenuRow(title: "Weight", value: title.weight.name) {
                    ForEach(TitleWeight.allCases, id: \.self) { weight in
                        Toggle(weight.name, isOn: Binding(get: { title.weight == weight },
                                                          set: { _ in store.setTitle("Change Weight") { $0.weight = weight } }))
                    }
                }
            }
        }

        PanelGroup(title: "Color") {
            colorSwatches
        }

        PanelGroup(title: "Readability") {
            OptionRow(options: TitleReadability.allCases.map { ($0.name, $0) }, selected: title.readability) { readability in
                store.setTitle("Change Readability") { $0.readability = readability }
            }
            // The plate's color, only while there's a plate. It keeps its see-through amount.
            if let plate = title.backdrop {
                PanelCard {
                    ColorRow(title: "Plate color", color: RGBA(red: plate.red, green: plate.green, blue: plate.blue),
                             onChange: { color in store.previewTitle { $0.backdrop = Self.plate(color, alpha: plate.alpha) } },
                             onCommit: { color in store.setTitle("Change Plate") { $0.backdrop = Self.plate(color, alpha: plate.alpha) } })
                }
            }
        }

        PanelGroup(title: "Animate") {
            // One row sets both ends, until they're split.
            OptionRow(options: TitleAnimation.allCases.map { ($0.name, $0) }, selected: title.animationIn) { animation in
                let both = !showsGoingOut
                store.setTitle("Change Animation") {
                    $0.animationIn = animation
                    if both { $0.animationOut = animation }
                }
            }
            PanelCard {
                ToggleRow(title: "Different going out", isOn: showsGoingOut) { on in
                    splitsAnimation = on
                    if !on { store.setTitle("Change Animation") { $0.animationOut = $0.animationIn } }
                }
            }
            // Under the switch that names it, so it needs no label of its own and has the whole width, as the first.
            if showsGoingOut {
                OptionRow(options: TitleAnimation.allCases.map { ($0.name, $0) }, selected: title.animationOut) { animation in
                    store.setTitle("Change Animation") { $0.animationOut = animation }
                }
            }
        }

        // Only worth offering with other titles to change.
        if store.otherTitleCount > 0 {
            Button { store.useLookForAllTitles() } label: {
                Text("Use for all titles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BoxButtonStyle())
            .help("Give every title this one's font, color, readability and animation")
        }
    }

    private func font(_ name: String, family: String) -> some View {
        Toggle(name, isOn: Binding(get: { title.fontFamily == family },
                                   set: { _ in store.setTitle("Change Font") { $0.fontFamily = family } }))
    }

    /// The quick colors, then the spectrum for one of your own, chosen only while the text is a color of its own.
    private var colorSwatches: some View {
        let isOwnColor = !Self.colors.contains { $0.isNear(title.color) }
        return HStack(spacing: 10) {
            ForEach(Self.colors, id: \.self) { color in
                Swatch(isRound: true, isSelected: title.color.isNear(color), name: "Text color", action: {
                    isPickingColor = false
                    store.setTitle("Change Text Color") { $0.color = color }
                }) {
                    Color(rgba: color)
                }
                .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
            }
            ColorWellSwatch(color: title.color, showsSpectrum: true, isPicking: isPickingColor,
                            onChange: { color in store.previewTitle { $0.color = color } },
                            onActiveChange: { isPickingColor = $0 }) { color, _ in
                store.setTitle("Change Text Color") { $0.color = color }
            }
            .frame(width: SwatchMetrics.circle, height: SwatchMetrics.circle)
            .overlay { SwatchRing(isRound: true, isSelected: isOwnColor, isHovered: false) }
            .accessibilityLabel("Custom text color")
            .help("Choose a color of your own")
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private static func plate(_ color: RGBA, alpha: Double) -> RGBA {
        RGBA(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }
}
