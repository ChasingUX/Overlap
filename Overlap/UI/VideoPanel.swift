import SwiftUI

/// The Video tab: where the selected picture sits, how it looks and its color. Background clips choose their fill
/// instead. Sliders show their change as they're dragged and make it one undo step on release.
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
            PlaceholderPanel(icon: .video, title: "Select a video clip",
                             message: "Position, look and color settings for the selected picture show up here.",
                             action: ("Select Clip at Playhead", store.selectClipAtPlayhead))
        }
    }

    private func picture(_ clip: Clip) -> some View {
        let visual = clip.visual
        return ClipPanel(title: "Video") {
            PanelGroup(title: "Position") {
                slider("X", visual.x, range: -1...1, default: 0, format: Self.percent) { $0.x = $1 }
                slider("Y", visual.y, range: -1...1, default: 0, format: Self.percent) { $0.y = $1 }
                // Scale works in powers of two, so 50% and 200% sit the same distance either side of 100%.
                slider("Scale", log2(visual.scale), range: log2(Visual.scaleRange.lowerBound)...log2(Visual.scaleRange.upperBound),
                       default: 0, format: { "\(Int((exp2($0) * 100).rounded()))%" }) { $0.scale = exp2($1) }
                slider("Rotation", visual.rotation, range: -180...180, default: 0, format: { "\(Int($0.rounded()))°" }) { $0.rotation = $1 }
                // Text has no edges to crop.
                if clip.title == nil {
                    HStack(spacing: 6) {
                        Button(store.isCropping ? "Done Cropping" : "Crop") { store.isCropping.toggle() }
                            .buttonStyle(BoxButtonStyle())
                        if !visual.crop.isEmpty {
                            Button("Reset Crop") { store.setVisual("Reset Crop") { $0.crop = Crop() } }
                                .buttonStyle(BoxButtonStyle())
                        }
                    }
                }
            }

            PanelGroup(title: "Look") {
                slider("Opacity", visual.opacity, range: 0...1, default: 1, format: Self.percent) { $0.opacity = $1 }
                slider("Corners", visual.corners, range: 0...0.5, default: 0, format: { "\(Int(($0 / 0.5 * 100).rounded()))%" }) { $0.corners = $1 }
                slider("Shadow", visual.shadow, range: 0...100, default: 0, format: { "\(Int($0.rounded()))" }) { $0.shadow = $1 }
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

            if !store.project.isStill(clip) {
                PanelGroup(title: store.selectedClips.count > 1 ? "Clips" : "Clip") {
                    SpeedSection(store: store)
                }
            }
        }
    }

    private func backgroundClip(_ clip: Clip) -> some View {
        ClipPanel(title: "Video") {
            PanelGroup(title: "Background") {
                BackgroundPicker(store: store, selected: clip.fill, allowsNone: false) { fill in
                    if let fill { store.setClipFill(fill) }
                }
                slider("Opacity", clip.visual.opacity, range: 0...1, default: 1, format: Self.percent) { $0.opacity = $1 }
            }
        }
    }

    /// A slider for one placement or look value. `set` writes the slider's value into the clip's settings.
    private func slider(_ title: String, _ value: Double, range: ClosedRange<Double>, default defaultValue: Double,
                        format: @escaping (Double) -> String, set: @escaping (inout Visual, Double) -> Void) -> some View {
        BoxSlider(title: title, value: value, range: range, format: format, defaultValue: defaultValue,
                  onChange: { new in store.previewVisual { set(&$0, new) } },
                  onCommit: { new in store.setVisual("Change \(title)") { set(&$0, new) } })
    }

    private static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
}
