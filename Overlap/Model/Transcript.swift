import Foundation

/// What's said in a file: its words in order, each timed in the file's own seconds.
struct Transcript: Codable, Hashable, Sendable {
    struct Word: Codable, Hashable, Sendable {
        /// The word as written, with any punctuation after it: "Hi," or "Done."
        var text: String
        var start: Double
        var end: Double
    }

    var words: [Word]

    /// Sounds a speaker makes while thinking, which Remove takes out. Words like "so" and "like" carry meaning too
    /// often to take out on their own.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm"]
}

extension Transcript.Word {
    var isFiller: Bool {
        Transcript.fillers.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    var endsSentence: Bool {
        text.last.map { ".?!".contains($0) } ?? false
    }
}

/// A stretch of one clip, in timeline time, to take out.
struct TranscriptCut: Hashable, Sendable {
    var clip: UUID
    var range: TimeRange
}

extension TimeRange {
    init(from start: Time, to end: Time) {
        self.init(start: start, duration: max(.zero, end - start))
    }
}

/// The transcript as the timeline plays it: what's said in each video clip, timed on the timeline, in the order the
/// clips start, broken into paragraphs, with the pauses long enough to take out.
struct TimelineTranscript: Equatable {
    enum Item: Equatable {
        case word(text: String, range: TimeRange, isFiller: Bool, clip: UUID)
        /// A silence between two words long enough to take out.
        case pause(range: TimeRange, clip: UUID)

        var range: TimeRange {
            switch self {
            case let .word(_, range, _, _), let .pause(range, _): range
            }
        }

        var clip: UUID {
            switch self {
            case let .word(_, _, _, clip), let .pause(_, clip): clip
            }
        }

        var isFiller: Bool {
            if case let .word(_, _, isFiller, _) = self { return isFiller }
            return false
        }

        var isPause: Bool {
            if case .pause = self { return true }
            return false
        }
    }

    struct Paragraph: Equatable {
        var items: [Item]
        var start: Time { items.first?.range.start ?? .zero }
    }

    var paragraphs: [Paragraph] = []

    /// The shortest silence between words that's marked as a pause.
    static let pauseLength = Time(seconds: 1)
    /// How much of a pause taking it out leaves, split either side, so speech doesn't run together.
    static let keptPause = Time(seconds: 0.4)
    /// A paragraph ends with a sentence once it's this long, or at a sentence followed by a long silence.
    static let paragraphWords = 45
    static let paragraphPause = Time(seconds: 2)

    var items: [Item] { paragraphs.flatMap(\.items) }
    var isEmpty: Bool { paragraphs.isEmpty }
    var pauseCount: Int { items.filter(\.isPause).count }
    var fillerCount: Int { items.filter(\.isFiller).count }

    /// The stretches Remove Pauses and Fillers takes out: each pause down to a short breath, and each filler word
    /// with the breath after it. A pause and a filler side by side go as one, leaving one breath.
    var removable: [TranscriptCut] {
        let all = items
        var cuts: [TranscriptCut] = []
        var lastRemoved: Int?
        for (index, item) in all.enumerated() {
            var range: TimeRange
            switch item {
            case let .pause(pause, _):
                let half = Time(ticks: Self.keptPause.ticks / 2)
                range = TimeRange(from: pause.start + half, to: pause.end - half)
            case let .word(_, word, true, clip):
                // Up to the next word when it follows closely; a pause after it is taken out on its own.
                let next = all.indices.contains(index + 1) ? all[index + 1] : nil
                range = TimeRange(from: word.start, to: next.map { !$0.isPause && $0.clip == clip ? $0.range.start : word.end } ?? word.end)
            default:
                continue
            }
            if let lastRemoved, lastRemoved == index - 1, all[lastRemoved].clip == item.clip, var last = cuts.popLast() {
                last.range = TimeRange(from: last.range.start, to: max(last.range.end, range.end))
                cuts.append(last)
            } else {
                cuts.append(TranscriptCut(clip: item.clip, range: range))
            }
            lastRemoved = index
        }
        return Self.merged(cuts)
    }

    /// The stretches selected items cover: each run of them in one clip, from its first item's start to where the
    /// next item begins, so the silence after the last selected word goes too.
    func cuts(covering indexes: IndexSet) -> [TranscriptCut] {
        let all = items
        var cuts: [TranscriptCut] = []
        for range in indexes.rangeView where range.lowerBound < all.count {
            let selected = all[range.lowerBound..<min(range.upperBound, all.count)]
            var runStart = selected.startIndex
            for index in selected.indices {
                let isLast = index == selected.index(before: selected.endIndex)
                let nextInRun = isLast ? nil : all[index + 1]
                guard nextInRun?.clip != all[index].clip else { continue }
                let clip = all[index].clip
                let followsInClip = all.indices.contains(index + 1) && all[index + 1].clip == clip
                let end = followsInClip ? all[index + 1].range.start : all[index].range.end
                cuts.append(TranscriptCut(clip: clip, range: TimeRange(from: all[runStart].range.start, to: end)))
                runStart = index + 1
            }
        }
        return Self.merged(cuts)
    }

    /// Joins cuts in one clip that touch or overlap, and drops empty ones.
    static func merged(_ cuts: [TranscriptCut]) -> [TranscriptCut] {
        let touching = Time(seconds: 0.05)
        var result: [TranscriptCut] = []
        for cut in cuts.filter({ $0.range.duration > .zero }).sorted(by: { ($0.clip.uuidString, $0.range.start) < ($1.clip.uuidString, $1.range.start) }) {
            if var last = result.last, last.clip == cut.clip, cut.range.start <= last.range.end + touching {
                last.range = TimeRange(from: last.range.start, to: max(last.range.end, cut.range.end))
                result[result.count - 1] = last
            } else {
                result.append(cut)
            }
        }
        return result.sorted { $0.range.start < $1.range.start }
    }

    /// The item playing at `time`, if any.
    func itemIndex(at time: Time) -> Int? {
        items.firstIndex { $0.range.start <= time && time < $0.range.end }
    }
}

extension Project {
    var hasVideoClips: Bool {
        tracks.contains { $0.clips.contains { asset($0.assetID)?.kind == .video } }
    }

    /// The clips a transcript reads from: video clips that play their own sound, in the order they start.
    var spokenClips: [Clip] {
        tracks.enumerated()
            .flatMap { index, track in track.clips.map { (index, $0) } }
            .filter { asset($0.1.assetID)?.kind == .video && $0.1.usesAudio }
            .sorted { ($0.1.start, -$0.0) < ($1.1.start, -$1.0) }
            .map(\.1)
    }

    /// What each spoken clip says, from its file's transcript, timed on the timeline.
    func timelineTranscript(_ transcripts: [UUID: Transcript]) -> TimelineTranscript {
        var paragraphs: [TimelineTranscript.Paragraph] = []
        for clip in spokenClips {
            guard let transcript = transcripts[clip.assetID] else { continue }
            let from = clip.sourceStart.seconds
            let to = from + clip.sourceDuration.seconds
            func onTimeline(_ seconds: Double) -> Time {
                clip.start + Time(seconds: (min(max(seconds, from), to) - from) / clip.speed)
            }
            // A word counts where it starts; one cut off at the clip's end still shows.
            let words = transcript.words.filter { $0.start >= from - 0.01 && $0.start < to }
            var paragraph: [TimelineTranscript.Item] = []
            var count = 0
            var previous: (word: Transcript.Word, end: Time)?
            for word in words {
                let range = TimeRange(from: onTimeline(word.start), to: onTimeline(word.end))
                if let previous {
                    let gap = TimeRange(from: previous.end, to: range.start)
                    // A pause ends the sentence it follows, so a paragraph after it starts with its words.
                    if gap.duration >= TimelineTranscript.pauseLength {
                        paragraph.append(.pause(range: gap, clip: clip.id))
                    }
                    if previous.word.endsSentence, count >= TimelineTranscript.paragraphWords || gap.duration >= TimelineTranscript.paragraphPause {
                        paragraphs.append(TimelineTranscript.Paragraph(items: paragraph))
                        paragraph = []
                        count = 0
                    }
                }
                paragraph.append(.word(text: word.text, range: range, isFiller: word.isFiller, clip: clip.id))
                count += 1
                previous = (word, range.end)
            }
            if !paragraph.isEmpty { paragraphs.append(TimelineTranscript.Paragraph(items: paragraph)) }
        }
        return TimelineTranscript(paragraphs: paragraphs)
    }

    /// The shortest stretch a cut takes out; anything less is left alone.
    static let shortestCut = Time(seconds: 0.05)

    /// Takes each cut out of its clip, closing up: the rest of the clip and the clips after it on its track move
    /// earlier. A video whose sound was split into a clip of its own loses the same stretch from both, so they stay
    /// together. Cuts don't reach into a crossfade.
    mutating func cut(_ cuts: [TranscriptCut]) {
        // Latest first, so each cut leaves the times of the ones before it as they were.
        for cut in cuts.sorted(by: { $0.range.start > $1.range.start }) {
            guard let clip = clip(cut.clip) else { continue }
            let partners = tracks.flatMap(\.clips).filter {
                $0.id != clip.id && $0.assetID == clip.assetID && $0.start == clip.start
                    && $0.sourceStart == clip.sourceStart && $0.duration == clip.duration
            }
            for id in [clip.id] + partners.map(\.id) {
                cutOut(cut.range, from: id)
            }
        }
    }

    private mutating func cutOut(_ range: TimeRange, from id: UUID) {
        guard let location = location(ofClip: id), !tracks[location.track].isLocked else { return }
        let clip = tracks[location.track].clips[location.clip]
        let others = tracks[location.track].clips.filter { $0.id != id }
        let clear = (start: others.filter { $0.start < clip.start && $0.end > clip.start }.map(\.end).max() ?? clip.start,
                     end: others.filter { $0.start > clip.start && $0.start < clip.end }.map(\.start).min() ?? clip.end)
        // Beside a crossfade, a piece keeps a little of its own outside it, so the crossfade stays one.
        var from = max(range.start, clear.start == clip.start ? clip.start : clear.start + Self.minimumClipDuration)
        var to = min(range.end, clear.end == clip.end ? clip.end : clear.end - Self.minimumClipDuration)
        // No sliver of the clip is left either side.
        if from - clip.start < Self.minimumClipDuration, clear.start == clip.start { from = clip.start }
        if clip.end - to < Self.minimumClipDuration, clear.end == clip.end { to = clip.end }
        guard to - from >= Self.shortestCut else { return }
        if to < clip.end { split(at: to, clips: [id]) }
        let middle = from > clip.start ? split(at: from, clips: [id]).first : id
        if let middle { removeClips([middle], closingGaps: true) }
    }
}
