import Foundation

/// Music kept low while someone in the videos is talking: the stretches of speech, from the transcript's words, and
/// one dip under them that eases down just before each and back up just after. Short pauses stay low, so the music
/// doesn't pump between sentences.
struct Ducking: Hashable, Sendable {
    /// Timeline seconds, in order, at least `join` apart.
    private(set) var speech: [ClosedRange<Double>]

    /// About −12 dB: the usual level for a bed of music under narration.
    static let level = 0.25
    /// How long the music takes to go down before speech, and to come back after it.
    static let down = 0.25
    static let up = 0.5
    /// Pauses shorter than this stay low. It's at least the time to come up and go down again, so dips never overlap.
    static let join = 0.75

    init(speech: [ClosedRange<Double>]) {
        var merged: [ClosedRange<Double>] = []
        for range in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound - last.upperBound < Self.join {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        self.speech = merged
    }

    /// How loud the music plays at a moment on the timeline: 1 away from speech, `level` under it.
    func gain(at seconds: Double) -> Double {
        // The last stretch whose way down has begun by now.
        var low = 0
        var high = speech.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if speech[middle].lowerBound - Self.down <= seconds {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found >= 0 else { return 1 }
        let stretch = speech[found]
        func eased(_ progress: Double) -> Double {
            let p = progress.clamped(to: 0...1)
            return p * p * (3 - 2 * p)
        }
        if seconds < stretch.lowerBound {
            return 1 - (1 - Self.level) * eased((seconds - (stretch.lowerBound - Self.down)) / Self.down)
        }
        if seconds <= stretch.upperBound { return Self.level }
        if seconds < stretch.upperBound + Self.up {
            return Self.level + (1 - Self.level) * eased((seconds - stretch.upperBound) / Self.up)
        }
        return 1
    }
}

extension TimelineTranscript {
    /// When someone's talking, word by word, in timeline seconds.
    var speech: [ClosedRange<Double>] {
        items.compactMap { item in
            guard case let .word(_, range, _, _) = item else { return nil }
            return range.start.seconds...max(range.start.seconds, range.end.seconds)
        }
    }
}

extension Project {
    /// Whether ducking lowers a clip: sound files, such as music and ambience. A video's own sound, speech or not,
    /// plays as it is.
    func isDucked(_ clip: Clip) -> Bool {
        asset(clip.assetID)?.kind == .audio
    }
}
