import SwiftUI

/// The Video tab: how the selected picture looks and its color. Where it sits, its size, turn and crop are set by
/// hand in the preview. Background clips choose their fill instead. Sliders show their change as they're dragged
/// and make it one undo step on release.
struct VideoPanel: View {
    let store: ProjectStore

    private var clip: Clip? { store.selectedClips.first }

    var body: some View {
        if let clip, store.applicableTabs.contains(.video) {
            if clip.fill != nil {
                backgroundClip(clip)
            } else {
                picture(clip)
            }
        } else {
            if !store.project.hasVisualClips {
                PlaceholderPanel(icon: .video, title: "Select a video clip",
                                 message: "Add a video, image or title to the timeline, then select it.")
            } else {
                PlaceholderPanel(icon: .video, title: "Select a video clip",
                                 message: "Select a picture on the timeline to set its look and color.",
                                 action: playheadAction)
            }
        }
    }

    /// Offered only when there's a picture under the playhead to select.
    private var playheadAction: (title: String, perform: () -> Void)? {
        guard store.hasPictureAtPlayhead else { return nil }
        return (title: "Select Clip at Playhead", perform: { store.selectClipAtPlayhead() })
    }

    /// The clip's own settings first, then its color. Find loops sits with the clip's settings until it has found
    /// something; then the loops take a group of their own at the end, where they have room.
    private func picture(_ clip: Clip) -> some View {
        let visual = clip.visual
        let loops = store.selectedClips.count == 1 && clip.title == nil && store.project.asset(clip.assetID)?.kind == .video
        let loopsShown = loops && LoopSection.hasStarted(store: store, clip: clip)
        return ClipPanel(title: "Video") {
            PanelGroup(title: store.selectedClips.count > 1 ? "Clips" : "Clip") {
                // Corners and shadow come from the Canvas tab's frame, the same for every picture.
                slider("Opacity", visual.opacity, range: 0...1, default: 1, format: Self.percent) { $0.opacity = $1 }
                if !store.project.isStill(clip) {
                    SpeedSection(store: store)
                }
                if loops, !loopsShown {
                    FindLoopsButton(store: store, clip: clip)
                }
            }

            // Text takes its color from the Text tab.
            if clip.title == nil {
                PanelGroup(title: "Color") {
                    slider("Exposure", visual.color.exposure, range: -2...2, default: 0,
                           format: { String(format: "%+.1f", $0) }) { $0.color.exposure = $1 }
                    slider("Contrast", visual.color.contrast, range: 0.5...1.5, default: 1, format: Self.percent) { $0.color.contrast = $1 }
                    slider("Saturation", visual.color.saturation, range: 0...2, default: 1, format: Self.percent) { $0.color.saturation = $1 }
                    slider("Temperature", visual.color.temperature, range: -1...1, default: 0,
                           format: { "\(Int(($0 * 100).rounded()))" }) { $0.color.temperature = $1 }
                }
            }

            if loopsShown {
                LoopSection(store: store, clip: clip)
            }
        }
    }

    private func backgroundClip(_ clip: Clip) -> some View {
        ClipPanel(title: "Video") {
            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: clip.fill, allowsNone: false,
                                 onPreview: { store.previewClipFill($0) },
                                 onSelect: { fill in if let fill { store.setClipFill(fill) } })
                slider("Opacity", clip.visual.opacity, range: 0...1, default: 1, format: Self.percent) { $0.opacity = $1 }
            }
        }
    }

    /// A slider for one look value. `set` writes the slider's value into the clip's settings.
    private func slider(_ title: String, _ value: Double, range: ClosedRange<Double>, default defaultValue: Double,
                        detents: [Double]? = nil, format: @escaping (Double) -> String,
                        set: @escaping (inout Visual, Double) -> Void) -> some View {
        BoxSlider(title: title, value: value, range: range, format: format, defaultValue: defaultValue,
                  onChange: { new in store.previewVisual { set(&$0, new) } },
                  onCommit: { new in store.setVisual("Change \(title)") { set(&$0, new) } },
                  detents: detents)
    }

    private static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
}
