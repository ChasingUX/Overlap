import AppKit
import SwiftUI

/// The Text tab. With a text clip selected: its font, size, weight, color, alignment, backdrop and how it comes in
/// and goes out; the words themselves are typed on the canvas, by double-clicking the text in the preview. Otherwise, the title styles, to drag onto the timeline or click to add at the playhead.
struct TextPanel: View {
    let store: ProjectStore

    var body: some View {
        if let clip = store.selectedClips.first, let title = clip.title {
            ClipPanel(title: "Text") {
                TitleEditor(store: store, title: title)
            }
        } else {
            ClipPanel(title: "Text") {
                PanelGroup(title: "Titles") {
                    ForEach(TitleStyle.allCases, id: \.self) { style in
                        TitleStyleTile(style: style) { store.addTitleAtPlayhead(style) }
                            .onDrag { NSItemProvider(object: TimelineDrag.payload(for: style) as NSString) }
                    }
                }
                ComingLater(text: "Drag a title onto the timeline, or click one to add it at the playhead.")
            }
        }
    }
}

/// A title style, drawn roughly as it looks.
private struct TitleStyleTile: View {
    let style: TitleStyle
    let action: () -> Void

    var body: some View {
        let title = style.title
        Button(action: action) {
            VStack(alignment: title.alignment == .leading ? .leading : .center, spacing: 6) {
                Text(title.text.replacingOccurrences(of: "\n", with: " · "))
                    .font(.system(size: min(22, 8 + title.size / 8), weight: Font.Weight(title.weight)))
                    .foregroundStyle(.white)
                    .padding(.horizontal, title.backdrop == nil ? 0 : 8)
                    .padding(.vertical, title.backdrop == nil ? 0 : 3)
                    .background(title.backdrop.map { RoundedRectangle(cornerRadius: 4).fill(Color(rgba: $0)) })
                    .frame(maxWidth: .infinity, alignment: title.alignment == .leading ? .leading : .center)
                Text(style.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: title.alignment == .leading ? .leading : .center)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(ControlBox())
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.boxRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.name)
    }
}

/// Every setting of the selected text clip.
private struct TitleEditor: View {
    let store: ProjectStore
    let title: Title

    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        PanelGroup(title: "Title") {
            MenuRow(title: "Font", value: title.fontFamily.isEmpty ? "System" : title.fontFamily) {
                Toggle("System", isOn: Binding(get: { title.fontFamily.isEmpty }, set: { _ in store.setTitle("Change Font") { $0.fontFamily = "" } }))
                Divider()
                ForEach(Self.families, id: \.self) { family in
                    Toggle(family, isOn: Binding(get: { title.fontFamily == family },
                                                 set: { _ in store.setTitle("Change Font") { $0.fontFamily = family } }))
                }
            }
            BoxSlider(title: "Size", value: title.size, range: 12...300, format: { "\(Int($0.rounded())) pt" }, defaultValue: 96,
                      onChange: { size in store.previewTitle { $0.size = size } },
                      onCommit: { size in store.setTitle("Change Size") { $0.size = size } },
                      // 96 pt is only where a style starts, so the size doesn't catch on it.
                      detents: [])
            OptionGrid(options: TitleWeight.allCases.map { ($0.name, $0) }, selected: title.weight) { weight in
                store.setTitle("Change Weight") { $0.weight = weight }
            }
            ColorRow(title: "Color", color: title.color,
                     onChange: { color in store.previewTitle { $0.color = color } },
                     onCommit: { color in store.setTitle("Change Text Color") { $0.color = color } })
            OptionRow(options: [("Left", TitleAlignment.leading), ("Center", .center), ("Right", .trailing)], selected: title.alignment) { alignment in
                store.setTitle("Change Alignment") { $0.alignment = alignment }
            }
            ToggleRow(title: "Backdrop", isOn: title.backdrop != nil) { on in
                store.setTitle(on ? "Add Backdrop" : "Remove Backdrop") { $0.backdrop = on ? RGBA(red: 0, green: 0, blue: 0, alpha: 0.55) : nil }
            }
            if let backdrop = title.backdrop {
                ColorRow(title: "Backdrop color", color: RGBA(red: backdrop.red, green: backdrop.green, blue: backdrop.blue),
                         onChange: { color in store.previewTitle { $0.backdrop = RGBA(red: color.red, green: color.green, blue: color.blue, alpha: backdrop.alpha) } },
                         onCommit: { color in
                             store.setTitle("Change Backdrop") { $0.backdrop = RGBA(red: color.red, green: color.green, blue: color.blue, alpha: backdrop.alpha) }
                         })
            }
        }

        PanelGroup(title: "Comes in") {
            OptionRow(options: TitleAnimation.allCases.map { ($0.name, $0) }, selected: title.animationIn) { animation in
                store.setTitle("Change Animation") { $0.animationIn = animation }
            }
        }
        PanelGroup(title: "Goes out") {
            OptionRow(options: TitleAnimation.allCases.map { ($0.name, $0) }, selected: title.animationOut) { animation in
                store.setTitle("Change Animation") { $0.animationOut = animation }
            }
        }
        ComingLater(text: "Double-click the text in the preview to change it. Drag it there, or use the Video tab, to place and size it.")
    }
}

private extension Font.Weight {
    init(_ weight: TitleWeight) {
        self = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}
