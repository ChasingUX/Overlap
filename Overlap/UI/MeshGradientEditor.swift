import SwiftUI

/// The background's mesh gradient, large, in the canvas's shape, with a dot of each of its colors on its point, joined
/// by the mesh's lines. Drag a dot to move its color, or click it to open the color panel for it. Corners stay put and
/// dots on an edge slide along it, so the gradient always fills the canvas. Then how much grain lies over it.
struct MeshGradientEditor: View {
    let mesh: MeshGradientFill
    let aspectRatio: CGFloat
    /// Shows a change while it's being made, without an undo step.
    let onPreview: (MeshGradientFill) -> Void
    let onCommit: (MeshGradientFill, String) -> Void

    @State private var draft: MeshGradientFill?
    /// The dot the color panel is picking for.
    @State private var editing: Int?
    /// The dot under the pointer, which grows a little to say it can be dragged or clicked.
    @State private var hovered: Int?
    @State private var moved = false
    @State private var session = ColorPanelSession()
    @State private var anchor = AnchorView.Anchor()
    /// The gradient as last shown, for the color panel's changes to build on.
    @State private var latest = Latest()

    private final class Latest {
        var mesh: MeshGradientFill?
    }

    private static let space = "mesh"
    /// The dots and lines sit this far in from the rectangle's edges, so a dot on an edge shows whole; the gradient
    /// runs out to the edges behind them.
    private static let inset: CGFloat = 14

    private static func area(in size: CGSize) -> CGRect {
        CGRect(x: inset, y: inset, width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 2))
    }

    var body: some View {
        let shown = draft ?? mesh
        let _ = latest.mesh = shown
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(MeshGradientRenderer.view(shown))
                    lines(shown, in: size)
                    ForEach(shown.points.indices, id: \.self) { index in
                        dot(index, in: shown, size: size)
                    }
                }
                .coordinateSpace(.named(Self.space))
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .background(AnchorView(anchor: anchor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Gradient")

            BoxSlider(title: "Grain", value: shown.grain, range: MeshGradientFill.grainRange,
                      format: { "\(Int(($0 * 100).rounded()))%" }, defaultValue: MeshGradientFill.standardGrain,
                      onChange: { grain in onPreview(regrained(shown, grain)) },
                      onCommit: { grain in onCommit(regrained(shown, grain), "Change Grain") })
        }
        .onDisappear { session.stop() }
    }

    /// Opens the color panel for a dot: changes show as they're made, and each settled color is an undo step.
    private func pickColor(_ index: Int) {
        guard let current = latest.mesh, current.points.indices.contains(index) else { return }
        editing = index
        session.start(color: current.points[index].color, beside: anchor.view,
                      onChange: { color in
                          if let mesh = latest.mesh { onPreview(recolored(mesh, index, color)) }
                      },
                      onCommit: { color in
                          if let mesh = latest.mesh { onCommit(recolored(mesh, index, color), "Change Gradient Color") }
                      },
                      onEnd: { editing = nil })
    }

    /// A dot over a point, in its own color with a hairline white edge, a little larger while the color panel picks for
    /// it. Dragging it moves the point; a click without moving opens the color panel for it.
    private func dot(_ index: Int, in mesh: MeshGradientFill, size: CGSize) -> some View {
        let point = mesh.points[index]
        let isSelected = index == editing
        let side: CGFloat = isSelected ? 14 : 11
        return Circle()
            .fill(Color(rgba: point.color))
            .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0.7), lineWidth: isSelected ? 1.5 : 1))
            .frame(width: side, height: side)
            // Just enough to lift a dot off a gradient of its own color.
            .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
            .scaleEffect(hovered == index ? 1.3 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered == index)
            .frame(width: 26, height: 26)
        .contentShape(Circle())
        .position(x: Self.area(in: size).minX + point.x * Self.area(in: size).width,
                  y: Self.area(in: size).minY + point.y * Self.area(in: size).height)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    guard moved || hypot(drag.translation.width, drag.translation.height) > 2 else { return }
                    moved = true
                    let area = Self.area(in: size)
                    let next = (draft ?? self.mesh).moving(index, to: (drag.location.x - area.minX) / area.width,
                                                           (drag.location.y - area.minY) / area.height)
                    draft = next
                    onPreview(next)
                }
                .onEnded { _ in
                    if moved, let draft {
                        onCommit(draft, "Move Gradient Color")
                    } else {
                        pickColor(index)
                    }
                    moved = false
                    draft = nil
                }
        )
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityLabel("Color \(index + 1)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The mesh's lines through its points, along each row and each column, as smooth curves.
    private func lines(_ mesh: MeshGradientFill, in size: CGSize) -> some View {
        SwiftUI.Canvas { context, _ in
            let area = Self.area(in: size)
            func at(_ column: Int, _ row: Int) -> CGPoint {
                let point = mesh.points[row * mesh.columns + column]
                return CGPoint(x: area.minX + point.x * area.width, y: area.minY + point.y * area.height)
            }
            var path = Path()
            for row in 0..<mesh.rows {
                Self.curve(through: (0..<mesh.columns).map { at($0, row) }, in: &path)
            }
            for column in 0..<mesh.columns {
                Self.curve(through: (0..<mesh.rows).map { at(column, $0) }, in: &path)
            }
            context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// A Catmull-Rom curve through the points, as cubic Béziers.
    private static func curve(through points: [CGPoint], in path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        for index in 0..<points.count - 1 {
            let before = points[max(index - 1, 0)], from = points[index]
            let to = points[index + 1], after = points[min(index + 2, points.count - 1)]
            path.addCurve(to: to,
                          control1: CGPoint(x: from.x + (to.x - before.x) / 6, y: from.y + (to.y - before.y) / 6),
                          control2: CGPoint(x: to.x - (after.x - from.x) / 6, y: to.y - (after.y - from.y) / 6))
        }
    }

    private func recolored(_ mesh: MeshGradientFill, _ index: Int, _ color: RGBA) -> MeshGradientFill {
        var changed = mesh
        changed.points[index].color = color
        return changed
    }

    private func regrained(_ mesh: MeshGradientFill, _ grain: Double) -> MeshGradientFill {
        var changed = mesh
        changed.grain = grain
        return changed
    }
}
