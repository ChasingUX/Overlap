import SwiftUI

/// The Zoom tab, for the zoom selected on the timeline: its level, then how every zoom in the project moves and
/// blurs. The region is aimed in the preview, by dragging its frame.
struct ZoomPanel: View {
    let store: ProjectStore

    var body: some View {
        if let target = store.selectedZoomTarget {
            ClipPanel(title: "Zoom") {
                PanelGroup(title: "Zoom") {
                    BoxSlider(title: "Level", value: target.zoom.scale, range: Zoom.scaleRange,
                              format: { "\(Int(($0 * 100).rounded()))%" }, defaultValue: Zoom.defaultScale,
                              onChange: { scale in store.previewZoom { $0.scale = scale } },
                              onCommit: { scale in store.setZoom("Change Zoom Level") { $0.scale = scale } })
                }
                PanelGroup(title: "Animation") {
                    // The tiles' names sit under them, so Motion blur keeps clear of them by a group's gap.
                    ZoomAnimationTiles(selected: store.project.zoomAnimation) { store.setZoomAnimation($0) }
                        .padding(.bottom, 14)
                    // Four steps, from none to strong.
                    BoxSlider(title: "Motion blur", value: Double(store.project.motionBlur.rawValue), range: 0...3,
                              format: { (MotionBlur(rawValue: Int($0.rounded())) ?? .medium).name },
                              defaultValue: Double(MotionBlur.medium.rawValue),
                              onCommit: { value in store.setMotionBlur(MotionBlur(rawValue: Int(value.rounded())) ?? .medium) },
                              steps: MotionBlur.allCases.count)
                }
            }
        } else {
            PlaceholderPanel(icon: .zoom, title: "Select a zoom",
                             message: "Right-click a video or image clip and choose Add Zoom.")
        }
    }
}

/// Smooth and Dynamic as two tiles, each drawing how a zoom moves with it: progress over the move, rising to the
/// dashed line where the zoom arrives. Dynamic gets there sooner and passes it a little before settling.
private struct ZoomAnimationTiles: View {
    let selected: ZoomAnimation
    let onSelect: (ZoomAnimation) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ZoomAnimation.allCases, id: \.self) { animation in
                VStack(alignment: .leading, spacing: 5) {
                    Swatch(isRound: false, isSelected: animation == selected, name: animation.name, action: { onSelect(animation) }) {
                        ZoomCurve(animation: animation)
                    }
                    .frame(height: 64)
                    PanelLabel(animation.name)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

/// One easing's curve, drawn from the same function the zooms move by.
private struct ZoomCurve: View {
    let animation: ZoomAnimation

    var body: some View {
        SwiftUI.Canvas { context, size in
            let area = CGRect(x: 14, y: 12, width: size.width - 28, height: size.height - 24)
            // Headroom above the arrival line for Dynamic's overshoot.
            let top = 1.12
            func point(_ progress: Double, _ value: Double) -> CGPoint {
                CGPoint(x: area.minX + progress * area.width, y: area.maxY - value / top * area.height)
            }
            var arrival = Path()
            arrival.move(to: point(0, 1))
            arrival.addLine(to: point(1, 1))
            context.stroke(arrival, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            var curve = Path()
            for step in 0...48 {
                let progress = Double(step) / 48
                let location = point(progress, animation.ease(progress))
                if step == 0 { curve.move(to: location) } else { curve.addLine(to: location) }
            }
            context.stroke(curve, with: .color(.primary.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
