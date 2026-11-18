import CoreGraphics
import Foundation

/// What a captions track shows: what's said in the videos on the timeline, a phrase at a time, all in one look. The
/// track keeps no clips of its own; they're made from the transcript wherever the project plays or shows, so they
/// follow every cut, move and fixed word.
struct Captions: Hashable, Sendable, Codable {
    /// The look every caption has: font, weight, color, size, readability, place and margin. Its text isn't used.
    var look = Captions.defaultLook
    /// One line a caption, or two.
    var lines = 1
    /// Lights the word being said and dims the rest.
    var highlightsSpokenWord = false

    /// About how many characters fit on a caption's line.
    static let lineLength = 32

    /// Smaller and steadier than a title: semibold white on a plate, in the middle of the bottom, and no animation,
    /// as captions change every few seconds.
    static let defaultLook: Title = {
        var look = Title(text: "")
        look.size = 48
        look.weight = .semibold
        look.color = .white
        look.backdrop = Title.plate
        look.animationIn = .none
        look.animationOut = .none
        look.anchor = .bottom
        look.alignment = .center
        return look
    }()
}

extension Captions {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        look = try container.decodeIfPresent(Title.self, forKey: .look) ?? Self.defaultLook
        lines = try container.decodeIfPresent(Int.self, forKey: .lines) ?? 1
        highlightsSpokenWord = try container.decodeIfPresent(Bool.self, forKey: .highlightsSpokenWord) ?? false
    }
}

/// One caption: its text, when it shows, and its words.
struct CaptionPhrase: Equatable {
    var text: String
    var range: TimeRange
    var words: [SpokenWord]
}

extension TimelineTranscript {
    /// A caption stays up this long after its last word, unless the next one comes first.
    static let captionHold = Time(seconds: 0.6)
    /// Captions closer together than this run on, so the screen doesn't blink between them.
    static let captionJoin = Time(seconds: 0.4)
    /// The shortest a caption shows, room allowing.
    static let shortestCaption = Time(seconds: 0.8)
    /// A silence this long between two words starts a new caption.
    static let captionBreak = Time(seconds: 0.6)
    /// Short words that lead into what follows, which a caption shouldn't end on.
    static let leadingWords: Set<String> = ["a", "an", "the", "to", "of", "and", "or", "but", "for", "from", "with", "in", "on",
                                            "at", "by", "as", "your", "my", "our", "their", "its", "that"]

    /// The transcript as captions of up to `lines` lines: phrases broken at sentence ends, pauses, a change of clip
    /// and when a line is full, without filler words.
    func captionPhrases(lines: Int) -> [CaptionPhrase] {
        let limit = Captions.lineLength * max(1, lines)
        var phrases: [CaptionPhrase] = []
        var current: [(text: String, range: TimeRange, source: WordSource?)] = []
        var currentClip: UUID?

        func finish() {
            guard let first = current.first, let last = current.last else { return }
            var text = ""
            var words: [SpokenWord] = []
            for word in current {
                if !text.isEmpty { text += " " }
                let location = (text as NSString).length
                text += word.text
                words.append(SpokenWord(start: (word.range.start - first.range.start).seconds,
                                        end: (word.range.end - first.range.start).seconds,
                                        location: location, length: (word.text as NSString).length, source: word.source))
            }
            // Two lines break at the space nearest the middle; a line break takes a space's place, so the words
            // keep their places in the text.
            // A comma near the middle is the better place, and a line doesn't end on "the" or "to".
            if lines > 1, text.count > Captions.lineLength {
                let middle = text.count / 2
                func cost(_ space: String.Index) -> Int {
                    var cost = abs(text.distance(from: text.startIndex, to: space) - middle)
                    let before = text[..<space]
                    if before.hasSuffix(",") { cost -= 6 }
                    if let word = before.split(separator: " ").last, Self.leadingWords.contains(word.lowercased()) { cost += 6 }
                    return cost
                }
                if let split = text.indices.filter({ text[$0] == " " }).min(by: { cost($0) < cost($1) }) {
                    text.replaceSubrange(split...split, with: "\n")
                }
            }
            phrases.append(CaptionPhrase(text: text, range: TimeRange(from: first.range.start, to: last.range.end), words: words))
            current = []
        }

        let all = items
        for (index, item) in all.enumerated() {
            switch item {
            case .pause:
                finish()
            case let .word(text, range, isFiller, clip):
                guard !isFiller else { continue }
                if clip != currentClip {
                    finish()
                    currentClip = clip
                }
                let length = current.reduce(0) { $0 + $1.text.count + 1 } + text.count
                if !current.isEmpty, length > limit {
                    // A caption doesn't end on "the" or "to": those go on with the words they lead into.
                    var carried: [(text: String, range: TimeRange, source: WordSource?)] = []
                    while current.count > 1, let last = current.last, Self.leadingWords.contains(last.text.lowercased()) {
                        carried.insert(current.removeLast(), at: 0)
                    }
                    finish()
                    current = carried
                }
                if let last = current.last, range.start - last.range.end >= Self.captionBreak { finish() }
                current.append((text, range, sources.indices.contains(index) ? sources[index] : nil))
                let sofar = current.reduce(0) { $0 + $1.text.count + 1 }
                // Sentences end a caption, and so does a comma once it's half full.
                if Transcript.Word(text: text, start: 0, end: 0).endsSentence || (text.hasSuffix(",") && sofar >= limit / 2) { finish() }
            }
        }
        finish()

        // Each stays up a moment after its last word, runs on into the next when that's close, and never overlaps it.
        for index in phrases.indices {
            let start = phrases[index].range.start
            var end = max(phrases[index].range.end + Self.captionHold, start + Self.shortestCaption)
            if phrases.indices.contains(index + 1) {
                let next = phrases[index + 1].range.start
                if next - phrases[index].range.end <= Self.captionHold + Self.captionJoin { end = next }
                end = min(end, next)
            }
            phrases[index].range = TimeRange(from: start, to: max(end, start + Time(seconds: 0.1)))
        }
        return phrases
    }
}

extension Project {
    var hasCaptions: Bool {
        tracks.contains { $0.captions != nil }
    }

    /// The project as it plays and shows: each captions track filled with a text clip for each phrase of the
    /// transcript, in the track's look, placed on its spot on the canvas.
    func withCaptions(_ transcript: TimelineTranscript) -> Project {
        guard hasCaptions else { return self }
        var shown = self
        let canvas = self.canvas ?? Self.defaultCanvas
        let size = CGSize(width: canvas.width, height: canvas.height)
        for index in tracks.indices {
            guard let captions = tracks[index].captions else { continue }
            let track = tracks[index].id
            shown.tracks[index].clips = transcript.captionPhrases(lines: captions.lines).enumerated().map { number, phrase in
                var title = captions.look
                title.text = phrase.text
                title.spokenWords = phrase.words
                title.highlightsSpokenWord = captions.highlightsSpokenWord
                title.alignment = title.anchor?.alignment ?? .center
                var clip = Clip(assetID: Clip.noAsset, start: phrase.range.start, sourceStart: .zero, duration: phrase.range.duration)
                clip.id = Self.captionID(track: track, number: number)
                clip.title = title
                if let anchor = title.anchor {
                    let center = anchor.center(ofBox: TitleRenderer.size(for: title, canvas: size), margin: title.margin, canvas: size)
                    clip.visual.x = center.x
                    clip.visual.y = center.y
                }
                return clip
            }
        }
        return shown
    }

    /// The same for the same caption every time it's made, so the preview can take on a new look in place.
    static func captionID(track: UUID, number: Int) -> UUID {
        var bytes = track.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            for shift in 0..<4 {
                raw[12 + shift] ^= UInt8(truncatingIfNeeded: number >> (shift * 8))
            }
            // Never the track's own ID.
            raw[11] ^= 0xA5
        }
        return UUID(uuid: bytes)
    }

    /// The captions track a caption clip is on, in a project its captions have been made in.
    func captionsTrack(ofClip id: UUID) -> UUID? {
        guard let location = location(ofClip: id), tracks[location.track].captions != nil else { return nil }
        return tracks[location.track].id
    }
}
