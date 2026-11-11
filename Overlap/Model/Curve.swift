import Foundation

/// The shape of a fade or crossfade. `gain(at:)` maps progress through a fade-in (0 to 1) to linear gain (0 to 1).
/// A fade-out uses the same curve mirrored: its gain at progress p is `gain(at: 1 - p)`.
enum Curve: Hashable, Sendable, Codable {
    case linear
    case easeIn
    case easeOut
    case sCurve
    case equalPower
    case exponential
    /// A cubic bezier from (0, 0) to (1, 1) with two control points, like CSS cubic-bezier.
    case custom(x1: Double, y1: Double, x2: Double, y2: Double)

    /// The curves offered for fades and crossfades. The others still play where a project already uses them.
    static let presets: [Curve] = [.linear, .sCurve, .equalPower]

    var name: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .sCurve: "Smooth"
        case .equalPower: "Equal power"
        case .exponential: "Exponential"
        case .custom: "Custom"
        }
    }

    var isCustom: Bool {
        if case .custom = self { true } else { false }
    }

    func gain(at progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return 1 - (1 - t) * (1 - t)
        case .sCurve:
            return t * t * (3 - 2 * t)
        case .equalPower:
            return sin(t * .pi / 2)
        case .exponential:
            // Rises evenly in decibels from -60 dB to 0 dB, with true silence at the start.
            return t == 0 ? 0 : pow(10, -60 * (1 - t) / 20)
        case let .custom(x1, y1, x2, y2):
            return Self.bezierY(forX: t, x1: x1, y1: y1, x2: x2, y2: y2)
        }
    }

    private static func bezierY(forX x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        func component(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
        }
        // x(u) is monotonic for control points inside 0...1, so bisection always converges.
        var low = 0.0
        var high = 1.0
        var u = x
        for _ in 0..<32 {
            u = (low + high) / 2
            if component(u, x1, x2) < x { low = u } else { high = u }
        }
        return min(max(component(u, y1, y2), 0), 1)
    }
}

struct Fade: Hashable, Sendable, Codable {
    var duration: Time
    var curve: Curve

    static let none = Fade(duration: .zero, curve: .sCurve)
}
