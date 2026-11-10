import Foundation

/// A zoom into part of a clip's picture. Over its span the view eases in to the region around `x` and `y` at
/// `scale`, holds, and eases back out; two zooms close together pan from one region to the next instead. Its times
/// are the source's own seconds, so trimming, moving or speeding up the clip keeps it on the same moment.
struct Zoom: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    /// Source seconds.
    var start: Double
    var duration: Double
    /// The middle of the region zoomed into, as shares of the shown picture from its top left.
    var x = 0.5
    var y = 0.5
    /// How far in: 1.5 shows two thirds of the picture across.
    var scale = 1.5

    var end: Double { start + duration }

    static let scaleRange = 1.25...4.0
    static let defaultScale = 1.5
    static let defaultDuration = 3.0
    /// The shortest a zoom can be dragged to.
    static let shortest = 0.5
}

/// How zooms move: Smooth eases gently in and out; Dynamic is quicker and settles with a slight spring.
enum ZoomAnimation: String, Hashable, Sendable, Codable, CaseIterable {
    case smooth, dynamic

    var name: String { rawValue.capitalized }

    /// How long a zoom takes to move in, out or across, in seconds.
    var duration: Double {
        switch self {
        case .smooth: 0.8
        case .dynamic: 0.5
        }
    }

    /// Progress through a move, 0 to 1, for a share of its time. Dynamic overshoots a little before settling.
    func ease(_ u: Double) -> Double {
        let u = u.clamped(to: 0...1)
        switch self {
        case .smooth:
            return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .dynamic:
            // An ease-out-back: about 5% past the target at its peak.
            let back = 1.2
            return 1 + (back + 1) * pow(u - 1, 3) + back * pow(u - 1, 2)
        }
    }
}

/// How much zooms blur while they move. Holds are always sharp.
enum MotionBlur: Int, Hashable, Sendable, Codable, CaseIterable {
    case off, low, medium, high

    var name: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// How strongly the view's speed turns into blur.
    var strength: Double {
        switch self {
        case .off: 0
        case .low: 0.35
        case .medium: 0.7
        case .high: 1.2
        }
    }
}

/// Where a picture is zoomed to at a moment: the visible part's middle, as shares of the shown picture from its
/// top left, and how far in.
struct ZoomState: Hashable, Sendable {
    var x = 0.5
    var y = 0.5
    var scale = 1.0

    static let none = ZoomState()

    var isZoomed: Bool { scale > 1.0001 }

    /// Kept to a view that lies inside the picture: at least the whole picture's scale, its middle no nearer an edge
    /// than half the visible part.
    var clamped: ZoomState {
        let scale = max(1, scale)
        let half = 0.5 / scale
        return ZoomState(x: x.clamped(to: half...(1 - half)), y: y.clamped(to: half...(1 - half)), scale: scale)
    }

    /// Partway from one view to another. The scale moves evenly in steps of magnification, so a zoom from 1× to 4×
    /// feels as even as one from 1× to 2×, and the middle moves in a straight line.
    static func between(_ a: ZoomState, _ b: ZoomState, _ progress: Double) -> ZoomState {
        ZoomState(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress,
                  scale: exp(log(a.scale) + (log(b.scale) - log(a.scale)) * progress))
    }
}

/// Works out a clip's view from its zooms at any moment.
enum ZoomPath {
    /// The view at source time `t`. A zoom eases in over its first stretch and out over its last, each the
    /// animation's length or half the zoom if it's shorter. Zooms closer together than one move pan across
    /// instead, over a move centered between them.
    static func state(at t: Double, zooms: [Zoom], animation: ZoomAnimation) -> ZoomState {
        guard !zooms.isEmpty else { return .none }
        let zooms = zooms.sorted { $0.start < $1.start }
        let move = animation.duration
        let target = { (zoom: Zoom) in ZoomState(x: zoom.x, y: zoom.y, scale: zoom.scale).clamped }
        func chained(_ index: Int) -> Bool {
            index + 1 < zooms.count && zooms[index + 1].start - zooms[index].end < move
        }
        // Pans between chained zooms come first: they reach into both zooms.
        for index in zooms.indices where chained(index) {
            let (from, to) = (zooms[index], zooms[index + 1])
            let middle = (from.end + to.start) / 2
            let half = min(move / 2, from.duration / 2, to.duration / 2)
            if t >= middle - half, t < middle + half {
                return ZoomState.between(target(from), target(to), animation.ease((t - (middle - half)) / (2 * half))).clamped
            }
        }
        for (index, zoom) in zooms.enumerated() where t >= zoom.start && t < zoom.end {
            let ramp = min(move, zoom.duration / 2)
            if !(index > 0 && chained(index - 1)), t < zoom.start + ramp {
                return ZoomState.between(.none, target(zoom), animation.ease((t - zoom.start) / ramp)).clamped
            }
            if !chained(index), t > zoom.end - ramp {
                return ZoomState.between(target(zoom), .none, animation.ease((t - (zoom.end - ramp)) / ramp)).clamped
            }
            return target(zoom)
        }
        return .none
    }
}

extension Clip {
    /// The clip's zooms that fall within the part of the source it plays, as a split leaves each half.
    func zoomsWithinSource() -> [Zoom] {
        let range = sourceStart.seconds...(sourceStart.seconds + sourceDuration.seconds)
        return zooms.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
    }

    /// Source seconds at a time on the timeline, inside the clip.
    func sourceSeconds(at time: Time) -> Double {
        sourceStart.seconds + (time.seconds - start.seconds) * speed
    }

    /// Timeline seconds for a moment in the source.
    func timelineSeconds(atSource seconds: Double) -> Double {
        start.seconds + (seconds - sourceStart.seconds) / speed
    }
}
