import Foundation

enum AssetKind: String, Codable, Sendable {
    case video
    case audio
    /// A still image. It has no length of its own; its clips start at five seconds and trim to any length.
    case image
}

/// An imported media file. Its copy lives in the package's `Media/` folder under `fileName`.
struct Asset: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var fileName: String
    var displayName: String
    var kind: AssetKind
    var duration: Time
    var hasAudio: Bool
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var sampleRate: Double?
    var channelCount: Int?
}

struct Clip: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var assetID: UUID
    /// Where the clip starts on the timeline.
    var start: Time
    /// The in point within the asset.
    var sourceStart: Time
    /// Length on the timeline. The clip plays `duration × speed` of its source.
    var duration: Time
    /// Linear gain, 1 = 0 dB.
    var volume: Double = 1
    var fadeIn: Fade = .none
    var fadeOut: Fade = .none
    /// The curve of the crossfade into this clip when it overlaps the clip before; nil uses the project default.
    var crossfadeCurve: Curve?
    /// 0.5 plays at half speed and lasts twice as long.
    var speed: Double = 1
    /// Keeps voices at their natural pitch when the speed changes.
    var preservesPitch = true
    /// A video's picture and sound can be split into two clips, each keeping one part.
    var usesVideo = true
    var usesAudio = true
    /// Where the picture sits in the canvas, and how it looks.
    var visual = Visual()
    /// A text clip's text and look. Text clips have no asset.
    var title: Title?
    /// What a background clip shows. Background clips have no asset and always draw behind the picture.
    var fill: BackgroundFill?
    /// How the picture changes in a crossfade into this clip; nil dissolves.
    var crossfadeVideoStyle: VideoTransition?
    /// Keeps speech and takes out background noise, music and room echo, with Apple's voice isolation.
    var isolatesVoice = false

    static let speedRange = 0.25...4.0
    /// The asset ID of text and background clips, which show what they hold instead of a file.
    static let noAsset = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    /// How long a new still, text or background clip lasts.
    static let stillDuration = Time(seconds: 5)

    var end: Time { start + duration }
    var range: TimeRange { TimeRange(start: start, duration: duration) }
    /// How much of the source the clip plays.
    var sourceDuration: Time { Time(seconds: duration.seconds * speed) }
}

extension Clip {
    /// Fields added after the first release fall back to their defaults, so older projects still open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        start = try container.decode(Time.self, forKey: .start)
        sourceStart = try container.decode(Time.self, forKey: .sourceStart)
        duration = try container.decode(Time.self, forKey: .duration)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try container.decodeIfPresent(Fade.self, forKey: .fadeIn) ?? .none
        fadeOut = try container.decodeIfPresent(Fade.self, forKey: .fadeOut) ?? .none
        crossfadeCurve = try container.decodeIfPresent(Curve.self, forKey: .crossfadeCurve)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        preservesPitch = try container.decodeIfPresent(Bool.self, forKey: .preservesPitch) ?? true
        usesVideo = try container.decodeIfPresent(Bool.self, forKey: .usesVideo) ?? true
        usesAudio = try container.decodeIfPresent(Bool.self, forKey: .usesAudio) ?? true
        visual = try container.decodeIfPresent(Visual.self, forKey: .visual) ?? Visual()
        title = try container.decodeIfPresent(Title.self, forKey: .title)
        fill = try container.decodeIfPresent(BackgroundFill.self, forKey: .fill)
        crossfadeVideoStyle = try container.decodeIfPresent(VideoTransition.self, forKey: .crossfadeVideoStyle)
        isolatesVoice = try container.decodeIfPresent(Bool.self, forKey: .isolatesVoice) ?? false
    }
}

struct Track: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var name: String
    var clips: [Clip] = []
    var volume: Double = 1
    var isMuted = false
    var isSoloed = false
    var isLocked = false
    var height: Double = 56
}

struct Canvas: Hashable, Sendable, Codable {
    var width: Int
    var height: Int
    var frameRate: Double
}

/// Everything saved in `Project.json`. Tracks are ordered bottom to top: higher indexes draw on top.
struct Project: Equatable, Sendable, Codable {
    var formatVersion = 1
    var canvas: Canvas?
    var assets: [Asset] = []
    var tracks: [Track] = (1...3).map { Track(name: "Track \($0)") }
    /// Linear gain on the whole mix, 1 = 0 dB.
    var masterVolume: Double = 1
    /// The curve new crossfades use until they're given their own.
    var defaultCrossfadeCurve: Curve = .equalPower
    /// How the canvas size is chosen. Auto follows the first video added.
    var canvasAspect = CanvasAspect.auto
    /// What shows behind the picture; nil is none, and the canvas is black where nothing covers it.
    var background: BackgroundFill?
    var frame = PictureFrame()
    /// Whether exports are brought to `loudnessTarget`. Off leaves the mix as it plays.
    var normalizesLoudness = true

    /// The loudness exports are brought to, in LUFS: the level YouTube and streaming services play at.
    static let loudnessTarget = -14.0

    /// The size and frame rate pictures are composed at, until a video sets one.
    static let defaultCanvas = Canvas(width: 1920, height: 1080, frameRate: 30)

    var duration: Time {
        tracks.flatMap(\.clips).map(\.end).max() ?? .zero
    }

    func asset(_ id: UUID) -> Asset? {
        assets.first { $0.id == id }
    }

    /// True when the timeline holds anything that draws in the preview.
    var hasVisualClips: Bool {
        tracks.contains { track in
            track.clips.contains(where: showsPicture)
        }
    }

    /// Whether the project makes a picture: anything visual on the timeline, or a background, which can stand on
    /// its own behind sound.
    var hasPicture: Bool {
        hasVisualClips || background != nil
    }

    /// Whether a clip draws in the preview: a video whose picture hasn't been split off, an image, text or a background.
    func showsPicture(_ clip: Clip) -> Bool {
        if clip.title != nil || clip.fill != nil { return true }
        switch asset(clip.assetID)?.kind {
        case .video: return clip.usesVideo
        case .image: return true
        default: return false
        }
    }

    /// Whether a clip has no length of its own to stay inside: an image, text or a background.
    func isStill(_ clip: Clip) -> Bool {
        clip.title != nil || clip.fill != nil || asset(clip.assetID)?.kind == .image
    }

    /// Whether a clip draws its own picture, so the Video tab can place it. Background clips fill the canvas instead.
    func isPlaceable(_ clip: Clip) -> Bool {
        showsPicture(clip) && clip.fill == nil
    }

    /// Whether a clip plays sound: any clip with audio, unless its sound was split off.
    /// Takes media whose sound turned out to be silence as having none, so its clips show no sound and the
    /// sound controls leave them be. Learned when the waveform is read, not saved as an edit.
    mutating func treatAsSilent(_ ids: Set<UUID>) {
        for index in assets.indices where ids.contains(assets[index].id) {
            assets[index].hasAudio = false
        }
    }

    func playsSound(_ clip: Clip) -> Bool {
        asset(clip.assetID)?.hasAudio == true && clip.usesAudio
    }

    /// Whether a track is heard and seen: not muted, and not left out by another track's solo.
    func isActive(_ track: Track) -> Bool {
        !track.isMuted && (track.isSoloed || !tracks.contains(where: \.isSoloed))
    }

    func isAssetInUse(_ id: UUID) -> Bool {
        tracks.contains { $0.clips.contains { $0.assetID == id } }
    }

    func location(ofClip id: UUID) -> (track: Int, clip: Int)? {
        for (trackIndex, track) in tracks.enumerated() {
            if let clipIndex = track.clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    func clip(_ id: UUID) -> Clip? {
        location(ofClip: id).map { tracks[$0.track].clips[$0.clip] }
    }
}

extension Project {
    /// Fields added after the first release fall back to their defaults, so older projects still open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        canvas = try container.decodeIfPresent(Canvas.self, forKey: .canvas)
        assets = try container.decode([Asset].self, forKey: .assets)
        tracks = try container.decode([Track].self, forKey: .tracks)
        masterVolume = try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1
        defaultCrossfadeCurve = try container.decodeIfPresent(Curve.self, forKey: .defaultCrossfadeCurve) ?? .equalPower
        canvasAspect = try container.decodeIfPresent(CanvasAspect.self, forKey: .canvasAspect) ?? .auto
        background = try container.decodeIfPresent(BackgroundFill.self, forKey: .background)
        frame = try container.decodeIfPresent(PictureFrame.self, forKey: .frame) ?? PictureFrame()
        normalizesLoudness = try container.decodeIfPresent(Bool.self, forKey: .normalizesLoudness) ?? true
    }
}

/// Where two clips on one track overlap. The outgoing clip fades out as the incoming one fades in, mirrored on one curve.
struct Crossfade: Hashable, Sendable {
    var outgoing: Clip
    var incoming: Clip
    var curve: Curve

    var videoStyle: VideoTransition { incoming.crossfadeVideoStyle ?? .dissolve }

    var range: TimeRange { TimeRange(start: incoming.start, duration: outgoing.end - incoming.start) }
}

extension Project {
    /// Crossfades on a track, in time order. Clips only ever overlap their next neighbor.
    func crossfades(onTrack index: Int) -> [Crossfade] {
        let clips = tracks[index].clips.sorted { $0.start < $1.start }
        return zip(clips, clips.dropFirst()).compactMap { outgoing, incoming in
            incoming.start < outgoing.end ? Crossfade(outgoing: outgoing, incoming: incoming, curve: curve(into: incoming)) : nil
        }
    }

    /// The crossfade leading into a clip, if it overlaps the clip before it.
    func crossfade(into clipID: UUID) -> Crossfade? {
        guard let location = location(ofClip: clipID) else { return nil }
        return crossfades(onTrack: location.track).first { $0.incoming.id == clipID }
    }

    func crossfade(outOf clipID: UUID) -> Crossfade? {
        guard let location = location(ofClip: clipID) else { return nil }
        return crossfades(onTrack: location.track).first { $0.outgoing.id == clipID }
    }

    /// The crossfade at one edge of a clip: the one it fades in through at its start, or out through at its end.
    func crossfade(at edge: ClipEdge, of clipID: UUID) -> Crossfade? {
        edge == .start ? crossfade(into: clipID) : crossfade(outOf: clipID)
    }

    func curve(into clip: Clip) -> Curve {
        clip.crossfadeCurve ?? defaultCrossfadeCurve
    }
}

// MARK: - Editing

/// Where a clip lands: on an existing track, or on a new track inserted at an index (bottom to top).
enum TrackTarget: Hashable, Sendable {
    case existing(UUID)
    case new(at: Int)
}

/// A copied clip and the track it came from.
struct ClipboardItem: Sendable {
    var clip: Clip
    var trackID: UUID
}

extension Project {
    /// Whether `range` can go on a track, ignoring the clip `excluding`. It may partly overlap a neighbor at
    /// either end, which makes a crossfade, but it can't cover a clip, sit inside one, or make three clips
    /// play at once. Locked tracks take nothing.
    func isFree(track index: Int, range: TimeRange, excluding: UUID? = nil) -> Bool {
        guard tracks.indices.contains(index) else { return true }
        guard !tracks[index].isLocked else { return false }
        let others = tracks[index].clips.filter { $0.id != excluding }.map(\.range)
        for other in others where other.overlaps(range) {
            let coversOther = range.start <= other.start && other.end <= range.end
            let insideOther = other.start <= range.start && range.end <= other.end
            if coversOther || insideOther { return false }
        }
        return Self.mostAtOnce(others + [range]) <= 2
    }

    /// The most ranges that cover any one moment.
    static func mostAtOnce(_ ranges: [TimeRange]) -> Int {
        // Ends sort before starts at the same moment, so clips that only touch don't count as overlapping.
        var events: [(time: Time, change: Int)] = []
        for range in ranges {
            events.append((range.start, 1))
            events.append((range.end, -1))
        }
        events.sort { first, second in
            first.time == second.time ? first.change < second.change : first.time < second.time
        }
        var current = 0
        var most = 0
        for (_, change) in events {
            current += change
            most = max(most, current)
        }
        return most
    }

    func isLocked(clip id: UUID) -> Bool {
        location(ofClip: id).map { tracks[$0.track].isLocked } ?? false
    }

    /// Pass as a preferred track to add a new track below all the others.
    static let newBottomTrack = -1

    /// The preferred track if `range` fits there, otherwise the next free track above it, adding one if needed.
    /// A preferred index past the top track adds a new top track; `newBottomTrack` adds one at the bottom.
    mutating func trackForPlacement(preferred: Int, range: TimeRange, excluding: UUID? = nil) -> Int {
        if preferred == Self.newBottomTrack {
            tracks.insert(Track(name: "Track \(tracks.count + 1)"), at: 0)
            return 0
        }
        var index = max(0, preferred)
        while index < tracks.count, !isFree(track: index, range: range, excluding: excluding) {
            index += 1
        }
        while index >= tracks.count {
            tracks.append(Track(name: "Track \(tracks.count + 1)"))
        }
        return index
    }

    /// Puts a clip on its target. A taken spot on an existing track pushes the clip to the next free track above.
    @discardableResult
    mutating func place(_ clip: Clip, on target: TrackTarget) -> Int {
        let index: Int
        switch target {
        case let .existing(id):
            index = trackForPlacement(preferred: tracks.firstIndex { $0.id == id } ?? tracks.count, range: clip.range, excluding: clip.id)
        case let .new(position):
            index = position.clamped(to: 0...tracks.count)
            tracks.insert(Track(name: "Track \(tracks.count + 1)"), at: index)
        }
        insert(clip, onTrack: index)
        return index
    }

    @discardableResult
    mutating func addClip(asset assetID: UUID, at start: Time, preferredTrack: Int) -> Clip? {
        guard let clip = newClip(asset: assetID, at: start) else { return nil }
        insert(clip, onTrack: trackForPlacement(preferred: preferredTrack, range: clip.range))
        return clip
    }

    @discardableResult
    mutating func addClip(asset assetID: UUID, at start: Time, target: TrackTarget) -> Clip? {
        guard let clip = newClip(asset: assetID, at: start) else { return nil }
        place(clip, on: target)
        return clip
    }

    mutating func moveClip(_ id: UUID, to start: Time, preferredTrack: Int) {
        guard let from = location(ofClip: id) else { return }
        var clip = tracks[from.track].clips.remove(at: from.clip)
        clip.start = max(.zero, start)
        insert(clip, onTrack: trackForPlacement(preferred: preferredTrack, range: clip.range))
    }

    mutating func moveClip(_ id: UUID, to start: Time, target: TrackTarget) {
        guard let from = location(ofClip: id) else { return }
        var clip = tracks[from.track].clips.remove(at: from.clip)
        clip.start = max(.zero, start)
        place(clip, on: target)
    }

    /// A clip for a whole asset, or five seconds of an image. The first video added sets the canvas, unless
    /// it's been given a fixed shape.
    private mutating func newClip(asset assetID: UUID, at start: Time) -> Clip? {
        guard let asset = asset(assetID) else { return nil }
        if asset.kind == .video, canvasAspect == .auto, !hasVideoClips, let width = asset.pixelWidth, let height = asset.pixelHeight {
            canvas = Canvas(width: width, height: height, frameRate: asset.frameRate ?? 30)
        } else if asset.kind == .image, canvas == nil {
            canvas = Self.defaultCanvas
        }
        let duration = asset.kind == .image ? Clip.stillDuration : asset.duration
        return Clip(assetID: assetID, start: max(.zero, start), sourceStart: .zero, duration: duration)
    }

    /// The size and frame rate of the first video imported that's on the timeline, which an Auto canvas follows.
    var firstVideoCanvas: Canvas? {
        let used = Set(tracks.flatMap(\.clips).map(\.assetID))
        guard let video = assets.first(where: { $0.kind == .video && used.contains($0.id) }),
              let width = video.pixelWidth, let height = video.pixelHeight else { return nil }
        return Canvas(width: width, height: height, frameRate: video.frameRate ?? Self.defaultCanvas.frameRate)
    }

    private var hasVideoClips: Bool {
        tracks.contains { $0.clips.contains { asset($0.assetID)?.kind == .video } }
    }

    /// Adds a text clip, five seconds long.
    @discardableResult
    mutating func addTitle(_ title: Title, visual: Visual = Visual(), at start: Time, target: TrackTarget) -> Clip {
        if canvas == nil { canvas = Self.defaultCanvas }
        var clip = Clip(assetID: Clip.noAsset, start: max(.zero, start), sourceStart: .zero, duration: Clip.stillDuration)
        clip.title = title
        clip.visual = visual
        place(clip, on: target)
        return clip
    }

    /// Adds a background clip, five seconds long.
    @discardableResult
    mutating func addBackground(_ fill: BackgroundFill, at start: Time, target: TrackTarget) -> Clip {
        if canvas == nil { canvas = Self.defaultCanvas }
        var clip = Clip(assetID: Clip.noAsset, start: max(.zero, start), sourceStart: .zero, duration: Clip.stillDuration)
        clip.fill = fill
        place(clip, on: target)
        return clip
    }

    private mutating func insert(_ clip: Clip, onTrack index: Int) {
        tracks[index].clips.append(clip)
        tracks[index].clips.sort { $0.start < $1.start }
    }

    /// Keeps the timeline tidy: tracks without clips are removed. New tracks appear when clips are dropped above or below the others.
    mutating func normalizeTracks() {
        tracks.removeAll { $0.clips.isEmpty }
    }

    /// Moves a track to a new index; the tracks between shift to make room.
    mutating func moveTrack(from source: Int, to destination: Int) {
        guard tracks.indices.contains(source), tracks.indices.contains(destination), source != destination else { return }
        tracks.insert(tracks.remove(at: source), at: destination)
    }

    /// Removes clips. Closing gaps pulls later clips on the same track back by each removed clip's length.
    mutating func removeClips(_ ids: Set<UUID>, closingGaps: Bool = false) {
        for track in tracks.indices {
            let removed = tracks[track].clips.filter { ids.contains($0.id) }.sorted { $0.start > $1.start }
            tracks[track].clips.removeAll { ids.contains($0.id) }
            guard closingGaps else { continue }
            for gone in removed {
                for index in tracks[track].clips.indices where tracks[track].clips[index].start >= gone.end {
                    tracks[track].clips[index].start = tracks[track].clips[index].start - gone.duration
                }
            }
        }
    }

    /// The shortest a trim can make a clip.
    static let minimumClipDuration = Time(seconds: 0.1)

    enum ClipEdge {
        case start, end
    }

    /// Moves one edge of a clip to `time`, staying inside its source media. A normal trim stops at the
    /// neighboring clip; a ripple trim keeps the clip's start in place and moves the clips after it instead.
    mutating func trim(_ id: UUID, edge: ClipEdge, to time: Time, ripple: Bool = false) {
        guard let location = location(ofClip: id), !tracks[location.track].isLocked else { return }
        var clip = tracks[location.track].clips[location.clip]
        // Stills have no source to stay inside; media clips stop at the ends of their file.
        let still = isStill(clip)
        guard still || asset(clip.assetID) != nil else { return }
        let sourceLength = asset(clip.assetID)?.duration ?? .zero
        // Neighbors in time order: two before and two after.
        let sorted = tracks[location.track].clips.sorted { $0.start < $1.start }
        let index = sorted.firstIndex { $0.id == id } ?? 0
        let before = index > 0 ? sorted[index - 1] : nil
        let twoBefore = index > 1 ? sorted[index - 2] : nil
        let after = index + 1 < sorted.count ? sorted[index + 1] : nil
        let twoAfter = index + 2 < sorted.count ? sorted[index + 2] : nil
        let oldEnd = clip.end
        let shift: Time

        switch edge {
        case .start:
            var earliest = still ? .zero : clip.start - Time(seconds: clip.sourceStart.seconds / clip.speed)
            var latest = clip.end - Self.minimumClipDuration
            if !ripple, let before {
                if before.end > clip.start {
                    // Already crossfading: the overlap can grow, but not past the earlier clip's start or into the one before it.
                    earliest = max(earliest, before.start + Self.minimumClipDuration, twoBefore?.end ?? .zero)
                } else {
                    earliest = max(earliest, before.end)
                }
            }
            if let after, after.start < clip.end {
                // The start can't pass the next clip's start, or this clip would sit inside it.
                latest = min(latest, after.start)
            }
            let newStart = min(max(time, earliest, .zero), latest)
            let delta = newStart - clip.start
            clip.sourceStart = still ? .zero : max(.zero, clip.sourceStart + Time(seconds: delta.seconds * clip.speed))
            clip.duration = clip.duration - delta
            if ripple {
                shift = .zero - delta
            } else {
                clip.start = newStart
                shift = .zero
            }
        case .end:
            var latest = still ? Time(seconds: 24 * 3600) : clip.start + Time(seconds: (sourceLength - clip.sourceStart).seconds / clip.speed)
            var earliest = clip.start + Self.minimumClipDuration
            if !ripple, let after {
                if after.start < clip.end {
                    latest = min(latest, after.end - Self.minimumClipDuration, twoAfter?.start ?? latest)
                } else {
                    latest = min(latest, after.start)
                }
            }
            if let before, before.end > clip.start {
                earliest = max(earliest, before.end)
            }
            let newEnd = min(max(time, earliest), latest)
            shift = newEnd - clip.end
            clip.duration = clip.duration + shift
        }

        tracks[location.track].clips[location.clip] = clip
        if shift != .zero {
            shiftClips(onTrack: location.track, startingAtOrAfter: oldEnd, by: shift, except: id)
        }
        tracks[location.track].clips.sort { $0.start < $1.start }
    }

    /// Makes the canvas `frame`, given in the current canvas's pixels, without moving or resizing anything on it:
    /// pictures keep their place and size, and the canvas shows more around them or cuts some off. Background
    /// clips fill whatever the canvas is. The shape becomes Custom.
    mutating func resizeCanvas(to frame: CGRect) {
        let old = canvas ?? Project.defaultCanvas
        let even = { (value: CGFloat) in min(max(Int(value.rounded()), 16), 8192) / 2 * 2 }
        let size = CGSize(width: even(frame.width), height: even(frame.height))
        let from = CGSize(width: old.width, height: old.height)
        let to = CGRect(origin: frame.origin, size: size)
        for track in tracks.indices where !tracks[track].isLocked {
            for index in tracks[track].clips.indices where tracks[track].clips[index].fill == nil {
                let clip = tracks[track].clips[index]
                tracks[track].clips[index].visual = visual(of: clip, keptFrom: from, onto: to)
            }
        }
        canvas = Canvas(width: Int(size.width), height: Int(size.height), frameRate: old.frameRate)
        canvasAspect = .custom
    }

    /// A clip's placement on a canvas `to`, given in the pixels of the canvas `from`, that keeps the picture where
    /// it was and the size it was. Placement is a share of the canvas, and size grows with it: media fits the
    /// canvas at a scale of 1, and text is drawn in proportion to the canvas's height.
    func visual(of clip: Clip, keptFrom from: CGSize, onto to: CGRect) -> Visual {
        var visual = clip.visual
        let center = CGPoint(x: from.width / 2 + visual.x * from.width - to.minX, y: from.height / 2 + visual.y * from.height - to.minY)
        visual.x = (center.x - to.width / 2) / to.width
        visual.y = (center.y - to.height / 2) / to.height
        if clip.title != nil {
            visual.scale *= from.height / to.height
        } else if let asset = asset(clip.assetID), let width = asset.pixelWidth, let height = asset.pixelHeight, width > 0, height > 0 {
            let fit = { (canvas: CGSize) in min(canvas.width / CGFloat(width), canvas.height / CGFloat(height)) }
            visual.scale *= fit(from) / fit(to.size)
        }
        visual.scale = visual.scale.clamped(to: Visual.scaleRange)
        return visual
    }

    /// Makes a clip play one loop of its source, from `sourceStart` up to `sourceEnd`. Like any trim, the picture
    /// stays where it is on the timeline, unless the clip would then run into another clip or before zero: then it
    /// keeps its start, and any clips it would run into move along.
    mutating func trimToLoop(_ id: UUID, from sourceStart: Time, to sourceEnd: Time) {
        guard let location = location(ofClip: id), !tracks[location.track].isLocked, sourceEnd > sourceStart else { return }
        var clip = tracks[location.track].clips[location.clip]
        let others = tracks[location.track].clips.filter { $0.id != id }
        let duration = Time(seconds: (sourceEnd - sourceStart).seconds / clip.speed)
        let inPlace = clip.start + Time(seconds: (sourceStart - clip.sourceStart).seconds / clip.speed)
        let fits = inPlace >= .zero && !others.contains { $0.start < inPlace + duration && $0.end > inPlace }
        let oldEnd = clip.end
        clip.start = fits ? inPlace : clip.start
        clip.sourceStart = sourceStart
        clip.duration = duration
        tracks[location.track].clips[location.clip] = clip
        if !fits, let next = others.filter({ $0.start >= oldEnd }).map(\.start).min(), clip.end > next {
            shiftClips(onTrack: location.track, startingAtOrAfter: oldEnd, by: clip.end - next, except: id)
        }
        tracks[location.track].clips.sort { $0.start < $1.start }
    }

    private mutating func shiftClips(onTrack track: Int, startingAtOrAfter time: Time, by shift: Time, except id: UUID) {
        for index in tracks[track].clips.indices where tracks[track].clips[index].id != id && tracks[track].clips[index].start >= time {
            tracks[track].clips[index].start = tracks[track].clips[index].start + shift
        }
    }

    /// Splits clips that span `time` into two. With no clips given, splits every clip under the time. Returns the new right-hand clips.
    @discardableResult
    mutating func split(at time: Time, clips ids: Set<UUID>? = nil) -> [UUID] {
        var created: [UUID] = []
        for track in tracks.indices where !tracks[track].isLocked {
            var additions: [Clip] = []
            for index in tracks[track].clips.indices {
                let clip = tracks[track].clips[index]
                guard ids?.contains(clip.id) ?? true, clip.start < time, time < clip.end else { continue }
                let offset = time - clip.start
                var left = clip
                left.duration = offset
                left.fadeOut = .none
                var right = clip
                right.id = UUID()
                right.start = time
                right.sourceStart = clip.sourceStart + Time(seconds: offset.seconds * clip.speed)
                right.duration = clip.end - time
                right.fadeIn = .none
                tracks[track].clips[index] = left
                additions.append(right)
                created.append(right.id)
            }
            tracks[track].clips += additions
            tracks[track].clips.sort { $0.start < $1.start }
        }
        return created
    }

    /// Changes clips' speed. Each keeps its start and plays the same part of its source, so its length changes;
    /// later clips on the track move with its new end.
    mutating func setSpeed(_ speed: Double, for ids: Set<UUID>) {
        let speed = speed.clamped(to: Clip.speedRange)
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked else { continue }
            var clip = tracks[location.track].clips[location.clip]
            let source = clip.sourceDuration
            let oldEnd = clip.end
            clip.speed = speed
            clip.duration = Time(seconds: source.seconds / speed)
            tracks[location.track].clips[location.clip] = clip
            shiftClips(onTrack: location.track, startingAtOrAfter: oldEnd, by: clip.end - oldEnd, except: id)
        }
    }

    /// Sets a fade's length, up to half the clip, and optionally its curve.
    mutating func setFade(_ edge: ClipEdge, of ids: Set<UUID>, duration: Time? = nil, curve: Curve? = nil) {
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked else { continue }
            var clip = tracks[location.track].clips[location.clip]
            var fade = edge == .start ? clip.fadeIn : clip.fadeOut
            if let duration {
                fade.duration = min(max(duration, .zero), Time(seconds: clip.duration.seconds / 2))
            }
            if let curve { fade.curve = curve }
            if edge == .start { clip.fadeIn = fade } else { clip.fadeOut = fade }
            tracks[location.track].clips[location.clip] = clip
        }
    }

    mutating func setVolume(_ volume: Double, of ids: Set<UUID>) {
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked else { continue }
            tracks[location.track].clips[location.clip].volume = max(0, volume)
        }
    }

    mutating func setVolume(_ volume: Double, onTracks ids: Set<UUID>) {
        for index in tracks.indices where ids.contains(tracks[index].id) {
            tracks[index].volume = max(0, volume)
        }
    }

    /// Sets the curve of the crossfade into a clip.
    mutating func setCrossfadeCurve(_ curve: Curve, into id: UUID) {
        guard let location = location(ofClip: id), !tracks[location.track].isLocked else { return }
        tracks[location.track].clips[location.clip].crossfadeCurve = curve
    }

    /// Splits each video's sound into its own clip on a new track just below. Returns the new sound clips.
    @discardableResult
    mutating func detachAudio(_ ids: Set<UUID>) -> [UUID] {
        var created: [UUID] = []
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked else { continue }
            var picture = tracks[location.track].clips[location.clip]
            guard showsPicture(picture), playsSound(picture) else { continue }
            var sound = picture
            sound.id = UUID()
            sound.usesVideo = false
            picture.usesAudio = false
            tracks[location.track].clips[location.clip] = picture
            place(sound, on: .new(at: location.track))
            created.append(sound.id)
        }
        return created
    }

    /// Pastes copies of clips with the playhead at the earliest one, each on its original track when there's room.
    @discardableResult
    mutating func paste(_ items: [ClipboardItem], at time: Time) -> [UUID] {
        guard let earliest = items.map(\.clip.start).min() else { return [] }
        var pasted: [UUID] = []
        for item in items where asset(item.clip.assetID) != nil || isStill(item.clip) {
            var clip = item.clip
            clip.id = UUID()
            clip.start = time + (clip.start - earliest)
            let hasTrack = tracks.contains { $0.id == item.trackID }
            place(clip, on: hasTrack ? .existing(item.trackID) : .new(at: tracks.count))
            pasted.append(clip.id)
        }
        return pasted
    }

    mutating func setFlag(_ flag: WritableKeyPath<Track, Bool>, to value: Bool, onTracks ids: Set<UUID>) {
        for index in tracks.indices where ids.contains(tracks[index].id) {
            tracks[index][keyPath: flag] = value
        }
    }

    mutating func changeTitle(of ids: Set<UUID>, _ change: (inout Title) -> Void) {
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked,
                  var title = tracks[location.track].clips[location.clip].title else { continue }
            change(&title)
            tracks[location.track].clips[location.clip].title = title
        }
    }

    mutating func changeVisual(of ids: Set<UUID>, _ change: (inout Visual) -> Void) {
        for id in ids {
            guard let location = location(ofClip: id), !tracks[location.track].isLocked else { continue }
            change(&tracks[location.track].clips[location.clip].visual)
        }
    }

    /// Removes an asset with its clips, and wherever it's a wallpaper.
    mutating func removeAsset(_ id: UUID) {
        let wallpaper = BackgroundFill.wallpaper(id)
        removeClips(Set(tracks.flatMap(\.clips).filter { $0.assetID == id || $0.fill == wallpaper }.map(\.id)))
        if background == wallpaper { background = nil }
        assets.removeAll { $0.id == id }
    }
}

extension Clip {
    /// The fade the clip plays at an edge. A crossfade and a fade never share an edge: where the clip crossfades,
    /// the crossfade does the fading and the clip's own fade is set aside. It's kept, and plays again if the clips
    /// are pulled apart.
    func playedFade(_ edge: Project.ClipEdge, crossfades: [Crossfade]) -> Fade {
        let crossfaded = crossfades.contains { edge == .start ? $0.incoming.id == id : $0.outgoing.id == id }
        return crossfaded ? Fade.none : (edge == .start ? fadeIn : fadeOut)
    }
}
