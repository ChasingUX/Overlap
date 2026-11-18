import AppKit
import SwiftUI

/// The Text tab. With a text clip selected: where it sits, from nine places, and how large; its font, weight and
/// color; how it stands out from the picture; and how it comes in and goes out. The words are typed on the canvas.
/// Its lines follow its place, lining up left on the left and right on the right. With captions selected, the same
/// look for every caption, with how many lines each has and whether the spoken word lights up. With no text
/// selected, a button adds some at the playhead, ready to type.
struct TextPanel: View {
    let store: ProjectStore

    var body: some View {
        if let selected = store.selectedCaptionsTrack {
            ClipPanel(title: "Captions") {
                TitleEditor(store: store, clip: store.representativeCaption ?? Clip(assetID: Clip.noAsset, start: .zero, sourceStart: .zero,
                                                                                   duration: Clip.stillDuration),
                            title: selected.captions.look, captions: selected.captions)
                    .id(selected.id)
            }
        } else if let clip = store.selectedClips.first, let title = clip.title {
            ClipPanel(title: "Text") {
                TitleEditor(store: store, clip: clip, title: title)
                    .id(clip.id)
            }
        } else {
            PlaceholderPanel(icon: .text, title: "Add text", message: "Adds a title at the playhead, ready to type on the canvas.",
                             action: (title: "Add Text", perform: { store.addTextAtPlayhead() }))
        }
    }
}

/// Every setting of the selected text clip, or of the selected captions' look.
private struct TitleEditor: View {
    let store: ProjectStore
    let clip: Clip
    let title: Title
    /// Set for captions, which change together and don't animate.
    var captions: Captions?

    /// Set while the second animation row shows though both ends are the same, as just after it's switched on.
    @State private var splitsAnimation = false
    @State private var isPickingColor = false

    private static let families = NSFontManager.shared.availableFontFamilies
    private static let faces = TitleFont.faces.filter { families.contains($0) }
    /// White, black and three of the plain colors, before the spectrum.
    private static let colors: [RGBA] = [0xFFFFFF, 0x141414, 0xECB851, 0xDB5B5D, 0x4D9DE7].map { RGBA(hex: $0) }

    private var showsGoingOut: Bool { splitsAnimation || title.animationIn != title.animationOut }

    /// Text drawn larger or smaller by its handles shows and sets the size it's seen at.
    private var shownSize: Double { title.size * clip.visual.scale }
    /// A margin only moves text on a corner or an edge.
    private var usesMargin: Bool { title.anchor.map { $0 != .center } ?? false }

    var body: some View {
        PanelGroup(title: "Position") {
            HStack(spacing: 8) {
                NinePointPicker(selected: title.anchor) { anchor in
                    store.setTitle("Change Position") { $0.anchor = anchor }
                }
                .frame(width: PanelMetrics.boxHeight * 2 + 6, height: PanelMetrics.boxHeight * 2 + 6)
                VStack(spacing: 6) {
                    BoxSlider(title: "Size", value: shownSize, range: Title.sizeRange, format: { "\(Int($0.rounded()))" },
                              onChange: { size in store.previewTitle { [scale = clip.visual.scale] in $0.size = size / scale } },
                              onCommit: { size in store.setTitle("Change Size") { [scale = clip.visual.scale] in $0.size = size / scale } })
                    BoxSlider(title: "Margin", value: title.margin, range: Title.marginRange,
                              format: { "\(Int(($0 * 100).rounded()))%" }, defaultValue: Title.defaultMargin,
                              onChange: { margin in store.previewTitle { $0.margin = margin } },
                              onCommit: { margin in store.setTitle("Change Margin") { $0.margin = margin } })
                        .disabled(!usesMargin)
                        .opacity(usesMargin ? 1 : 0.45)
                        .help(usesMargin ? "How far in from the canvas's edges the text sits" : "Choose a corner or an edge to set how far in the text sits")
                }
            }
        }

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

        if let captions {
            captionSettings(captions)
        } else {
            animation
        }
    }

    /// How many lines each caption has, and whether the word being said lights up; then taking them off.
    @ViewBuilder
    private func captionSettings(_ captions: Captions) -> some View {
        PanelGroup(title: "Captions") {
            OptionRow(options: [("One line", 1), ("Two lines", 2)], selected: captions.lines) { lines in
                store.changeCaptions("Change Caption Lines") { $0.lines = lines }
            }
            PanelCard {
                ToggleRow(title: "Highlight each word", isOn: captions.highlightsSpokenWord) { on in
                    store.changeCaptions(on ? "Highlight Each Word" : "Stop Highlighting") { $0.highlightsSpokenWord = on }
                }
                .help("Lights each word as it's said, and dims the rest")
            }
        }
        Button { store.deleteSelection() } label: {
            Text("Remove captions")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BoxButtonStyle())
        .help("Takes the captions off; the transcript stays")
    }

    @ViewBuilder
    private var animation: some View {
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

/// Nine places for text in a small square: the corners, the middles of the edges, and the middle. The chosen one is a
/// larger white dot. With none chosen, the text sits wherever it was dragged.
private struct NinePointPicker: View {
    let selected: TitleAnchor?
    let onSelect: (TitleAnchor) -> Void

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(-1...1, id: \.self) { row in
                GridRow {
                    ForEach(-1...1, id: \.self) { column in
                        let anchor = TitleAnchor(column: column, row: row)
                        AnchorDot(isSelected: anchor == selected) { onSelect(anchor) }
                            .help(anchor.name)
                            .accessibilityLabel(anchor.name)
                    }
                }
            }
        }
        .padding(4)
        .background(ControlBox())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Position")
    }
}

/// One of the nine places: a small gray dot that brightens under the pointer, and a slightly larger white one chosen.
private struct AnchorDot: View {
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            let side: CGFloat = isSelected ? 5 : isHovered ? 4 : 3
            Circle()
                .fill(Color.primary.opacity(isSelected ? 0.95 : isHovered ? 0.65 : 0.3))
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
