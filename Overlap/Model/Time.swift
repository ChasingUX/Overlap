import CoreMedia

/// A point or length on the timeline, stored as a whole number of flicks (1/705,600,000 s).
/// Flicks divide evenly into every common frame rate and sample rate, so edits never drift.
struct Time: Hashable, Comparable, Sendable, Codable, AdditiveArithmetic {
    static let ticksPerSecond: Int64 = 705_600_000
    static let zero = Time(ticks: 0)

    var ticks: Int64

    init(ticks: Int64) {
        self.ticks = ticks
    }

    init(seconds: Double) {
        ticks = Int64((seconds * Double(Self.ticksPerSecond)).rounded())
    }

    init(_ time: CMTime) {
        guard time.isValid, time.isNumeric else {
            ticks = 0
            return
        }
        ticks = time.convertScale(Int32(Self.ticksPerSecond), method: .roundHalfAwayFromZero).value
    }

    var seconds: Double { Double(ticks) / Double(Self.ticksPerSecond) }

    var cmTime: CMTime { CMTime(value: ticks, timescale: Int32(Self.ticksPerSecond)) }

    static func < (lhs: Time, rhs: Time) -> Bool { lhs.ticks < rhs.ticks }
    static func + (lhs: Time, rhs: Time) -> Time { Time(ticks: lhs.ticks + rhs.ticks) }
    static func - (lhs: Time, rhs: Time) -> Time { Time(ticks: lhs.ticks - rhs.ticks) }

    init(from decoder: Decoder) throws {
        ticks = try decoder.singleValueContainer().decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }
}

/// A half-open span of timeline time: `start` up to, but not including, `end`.
struct TimeRange: Hashable, Sendable {
    var start: Time
    var duration: Time

    var end: Time { start + duration }

    func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

extension Time {
    /// Formats as minutes and seconds, such as 01:05, adding hours past an hour, such as 1:02:05.
    var clock: String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
