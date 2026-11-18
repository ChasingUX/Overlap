import Foundation

/// A mesh gradient as SwiftUI's `MeshGradient` draws it: a grid of points across the canvas, each with a color, the
/// colors blending smoothly between them. Points sit at shares of the canvas from its top left, so a gradient fills
/// any shape of canvas alike. Grain adds fine noise over the top.
struct MeshGradientFill: Hashable, Sendable, Codable {
    struct Point: Hashable, Sendable, Codable {
        var x: Double
        var y: Double
        var color: RGBA
    }

    var columns = 3
    var rows = 3
    /// Row by row, from the top left.
    var points: [Point]
    /// How much grain, from none to 1.
    var grain = 0.0
    /// Gradients you make have one, so shaping one keeps it up to date where it's saved; built-in ones don't.
    var id: UUID?

    static let grainRange = 0.0...1.0
    /// How much grain the built-in gradients start with: enough to look finished, not enough to see as noise.
    static let standardGrain = 0.3

    /// Where a point can be dragged: corners stay put, points on an edge slide along it, and the rest go anywhere on
    /// the canvas, so the gradient always covers it.
    func moving(_ index: Int, to x: Double, _ y: Double) -> MeshGradientFill {
        guard points.indices.contains(index) else { return self }
        var moved = self
        let column = index % columns, row = index / columns
        let onLeft = column == 0, onRight = column == columns - 1, onTop = row == 0, onBottom = row == rows - 1
        if !(onLeft || onRight) { moved.points[index].x = x.clamped(to: 0...1) }
        if !(onTop || onBottom) { moved.points[index].y = y.clamped(to: 0...1) }
        return moved
    }
}

extension MeshGradientFill {
    /// A 3×3 gradient from nine colors, row by row, with its middle and edge points nudged off the grid so it reads
    /// as soft pools of color rather than a grid.
    private static func grid(_ colors: [Int], middle: (Double, Double), top: Double = 0.5, bottom: Double = 0.5,
                             left: Double = 0.5, right: Double = 0.5) -> MeshGradientFill {
        let places: [(Double, Double)] = [
            (0, 0), (top, 0), (1, 0),
            (0, left), middle, (1, right),
            (0, 1), (bottom, 1), (1, 1),
        ]
        return MeshGradientFill(points: zip(places, colors).map { place, hex in
            Point(x: place.0, y: place.1, color: RGBA(hex: hex))
        }, grain: standardGrain)
    }

    /// A new gradient, made with the + after the built-in ones: three hues that go together, each in a darker and a
    /// lighter shade, spread over a 3×3 grid nudged off its lines.
    static func surprise() -> MeshGradientFill {
        var generator = SystemRandomNumberGenerator()
        return surprise(using: &generator)
    }

    static func surprise(using generator: inout some RandomNumberGenerator) -> MeshGradientFill {
        let base = Double.random(in: 0..<360, using: &generator)
        // Neighbors on the wheel, or one across from the others.
        let steps: [(Double, Double)] = [(35, 70), (40, 180), (120, 240), (-40, 40)]
        let step = steps.randomElement(using: &generator) ?? (35, 70)
        let hues = [base, base + step.0, base + step.1].map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
        func color(_ hue: Double, _ lightness: ClosedRange<Double>) -> RGBA {
            RGBA(hue: hue, saturation: .random(in: 68...90, using: &generator), lightness: .random(in: lightness, using: &generator))
        }
        let dark = 28.0...40.0, middle = 52.0...62.0, light = 70.0...80.0
        let colors = [
            color(hues[0], dark), color(hues[0], middle), color(hues[1], dark),
            color(hues[0], light), color(hues[1], middle), color(hues[2], middle),
            color(hues[1], light), color(hues[2], middle), color(hues[2], light),
        ]
        func nudge(_ value: Double) -> Double { value + .random(in: -0.12...0.12, using: &generator) }
        let places: [(Double, Double)] = [
            (0, 0), (nudge(0.5), 0), (1, 0),
            (0, nudge(0.5)), (nudge(0.5), nudge(0.5)), (1, nudge(0.5)),
            (0, 1), (nudge(0.5), 1), (1, 1),
        ]
        return MeshGradientFill(points: zip(places, colors).map { Point(x: $0.0, y: $0.1, color: $1) },
                                grain: standardGrain, id: UUID())
    }

    /// The built-in gradients.
    static let presets: [MeshGradientFill] = [
        // Aurora
        grid([0x3B1C6E, 0x1F2FA8, 0x0A6BE0, 0xA43FC6, 0x6B7CF0, 0x19C9E6, 0xFF5A3C, 0xFFB43A, 0x2FE0B0],
             middle: (0.55, 0.5), top: 0.55, bottom: 0.48, left: 0.52, right: 0.5),
        // Sunset
        grid([0x2B1055, 0x7A2C8F, 0xD94F70, 0xFF6F61, 0xFF9F68, 0xFFC371, 0xFFD194, 0xFFB88C, 0xFF7E5F],
             middle: (0.45, 0.55), top: 0.4, bottom: 0.6, left: 0.45, right: 0.55),
        // Ocean
        grid([0x031B34, 0x0B3C75, 0x1565C0, 0x0D6E8A, 0x1FA2C9, 0x4FD1E8, 0x0F9B8E, 0x52E5C4, 0xA8F0E6],
             middle: (0.6, 0.45), top: 0.5, bottom: 0.42, left: 0.58, right: 0.45),
        // Midnight
        grid([0x050814, 0x0B1230, 0x1B2A6B, 0x0A0F26, 0x1C2F7A, 0x3A55C9, 0x04060F, 0x0D1838, 0x233D99],
             middle: (0.62, 0.4), top: 0.5, bottom: 0.5, left: 0.55, right: 0.4),
        // Candy
        grid([0xFF7EB3, 0xFF758C, 0xFFB199, 0xC084FC, 0xF472B6, 0xFBBF24, 0x818CF8, 0xA78BFA, 0xF9A8D4],
             middle: (0.5, 0.42), top: 0.5, bottom: 0.55, left: 0.6, right: 0.45),
        // Silver
        grid([0xF2F2F4, 0xD9DBE0, 0xB8BCC6, 0xE6E7EA, 0xC4C7CF, 0x9AA0AD, 0xD5D7DC, 0xAEB3BD, 0x7D8494],
             middle: (0.58, 0.55), top: 0.5, bottom: 0.5, left: 0.5, right: 0.5),
        // Lagoon
        grid([0x0B3D2E, 0x12715B, 0x2FC79A, 0x0E5E6F, 0x19A7B7, 0x7FE7DC, 0x134E6F, 0x2B86C5, 0xA0D8EF],
             middle: (0.45, 0.45), top: 0.55, bottom: 0.45, left: 0.45, right: 0.55),
    ]
}
