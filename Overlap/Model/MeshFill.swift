import Foundation

/// A mesh gradient: a base color under soft pools of color, each fading out from a point, laid out as a stack of CSS
/// radial gradients is, so ones made in a web tool carry over as they are. Grain adds fine noise over the top.
struct MeshFill: Hashable, Sendable, Codable {
    /// How a pool mixes with what's under it, as CSS's `background-blend-mode` does.
    enum Blend: String, Hashable, Sendable, Codable {
        case normal, overlay, saturation, hardLight
    }

    /// One pool: `radial-gradient(circle at x y, color start, transparent end)`.
    struct Spot: Hashable, Sendable, Codable {
        /// The center, as shares of the canvas from its top left. It can sit past an edge.
        var x: Double
        var y: Double
        var color: RGBA
        /// Where the color starts to fade, and where it's gone, as shares of the distance from the center to the
        /// canvas's farthest corner.
        var start: Double
        var end: Double
        var blend = Blend.normal
    }

    var base: RGBA
    /// Top first, as CSS lists them.
    var spots: [Spot]
    var grain = false
}

extension MeshFill {
    /// The built-in gradients.
    static let presets: [MeshFill] = [
        // Lilac
        MeshFill(base: hsl(244, 61, 79), spots: [
            spot(80, 0, hsl(182, 100, 56), 0, 50),
            spot(34, 99, hsl(306, 52, 81), 8, 60),
            spot(23, 66, hsl(248, 87, 79), 15, 85),
            spot(0, 0, hsl(343, 100, 76), 0, 50),
            spot(0, 100, hsl(318, 100, 77), 0, 50),
        ]),
        // Sherbet
        MeshFill(base: hsl(0, 100, 50), spots: [
            spot(40, 20, hsl(28, 100, 74), 0, 50),
            spot(80, 0, hsl(189, 100, 56), 0, 50),
            spot(0, 50, hsl(355, 100, 93), 0, 50),
            spot(80, 50, hsl(340, 100, 76), 0, 50),
            spot(0, 100, hsl(22, 100, 77), 0, 50),
            spot(80, 100, hsl(242, 100, 70), 0, 50),
            spot(0, 0, hsl(343, 100, 76), 0, 50),
        ]),
        // Deep sea
        MeshFill(base: hsl(117, 40, 15), spots: [
            spot(3, 92, hsl(161, 100, 50), 0, 67),
            spot(46, 94, hsl(227, 100, 50), 0, 81),
            spot(93, 95, hsl(230, 100, 23), 0, 66),
            spot(89, 8, hsl(243, 100, 9), 0, 150),
        ]),
        // Prism
        MeshFill(base: .white, spots: [
            spot(-4, 2, hsl(304, 100, 49), 0, 50),
            spot(-9, 97, hsl(189, 100, 56), 0, 50),
            spot(100, 5, hsl(37, 90, 53), 0, 43.35),
            spot(50, 10, hsl(116, 100, 50), 0, 43.35),
            spot(53, 86, hsl(60, 93, 54), 0, 53.05),
            spot(103, 96, hsl(37, 91, 54), 0, 57.76),
        ]),
        // Midnight
        MeshFill(base: hsl(204, 96, 32), spots: [
            spot(87, 90, hsl(0, 0, 3), 0, 68.49),
            spot(39, 88, hsl(0, 0, 3), 5.85, 78.62),
            spot(92, 65, hsl(0, 0, 3), 5.85, 78.62),
        ]),
    ]

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, _ alpha: Double = 1) -> RGBA {
        RGBA(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
    }

    /// A spot given in CSS percentages.
    private static func spot(_ x: Double, _ y: Double, _ color: RGBA, _ start: Double, _ end: Double,
                             _ blend: Blend = .normal) -> Spot {
        Spot(x: x / 100, y: y / 100, color: color, start: start / 100, end: end / 100, blend: blend)
    }
}
