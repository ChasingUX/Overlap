import AppKit

/// The timeline: time labels along the top with grid lines running down through the tracks,
/// tracks drawn top (highest) to bottom (track 1). Drawn by hand so zooming and dragging stay smooth.
final class TimelineView: NSView {
    private enum Layout {
        static let rulerHeight: CGFloat = 30
        static let leadingInset: CGFloat = 16
        /// How much taller than its stored height a track draws.
        static let trackScale = 1.2
        static let trackGap: CGFloat = 4
        static let rowSpacing: CGFloat = 4
        static let clipInset: CGFloat = 3
        static let snapDistance: CGFloat = 8
        static let dragThreshold: CGFloat = 3
        /// How far a moved clip's pointer can stray up or down before the clip leaves its track. Until then it only slides sideways.
        static let trackChangeTolerance: CGFloat = 24
        /// The share of a track's height, at its top and at its bottom, that means "between tracks" while dragging a clip.
        static let betweenTracksZone: CGFloat = 0.25
        /// The top of the first track. Dragged clips and tracks never go above it, into the time labels.
        static let lanesTop: CGFloat = rulerHeight + trackGap
    }

    private enum Interaction {
        case none
        case scrubbing
        case pressingClip(id: UUID, grabTime: Time, grabY: CGFloat, downPoint: CGPoint)
        /// `leftTrack` turns on once the pointer strays past the tolerance; until then the clip stays on its track.
        case movingClip(id: UUID, grabTime: Time, grabY: CGFloat, downY: CGFloat, leftTrack: Bool)
        /// A press on empty space: a click moves the playhead, a sideways drag scrubs, an upward or downward drag moves the track.
        case pressingEmptySpace(track: Int?, grabY: CGFloat, downPoint: CGPoint)
        case movingTrack(index: Int, grabY: CGFloat, pointerY: CGFloat)
        /// Dragging a clip's edge. `time` is where the edge will land; holding ⇧ ripples the clips after it.
        case trimming(id: UUID, edge: Project.ClipEdge, grabOffset: Time, time: Time?, ripple: Bool)
        /// ⌘-dragging a box over clips to add them to the selection.
        case boxSelecting(origin: CGPoint, current: CGPoint, base: Set<UUID>)
        /// Dragging a fade handle. `duration` is the fade's new length.
        case fading(id: UUID, edge: Project.ClipEdge, startDuration: Time, downX: CGFloat, duration: Time?)
    }

    /// A clip being moved or dropped. It floats under the pointer while the tracks make room for it.
    private struct DragPreview {
        var clip: Clip
        var target: TrackTarget
        /// Where a gap opens among the other tracks, counted from the top; nil when the clip joins a track.
        var gap: Int?
        /// The floating clip's top edge, in view coordinates.
        var top: CGFloat
        var label: String?
        var movingClip: UUID?
    }

    private enum DropContent {
        case asset(Asset)
        case files([URL])
        case title(TitleStyle)
        case fill(BackgroundFill)
    }

    private let store: ProjectStore
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var zoomAnchor: (time: Time, x: CGFloat)?
    private var interaction = Interaction.none
    private var dragPreview: DragPreview?
    /// Where each track is drawn right now, by track ID, easing toward its place in `targetLayout()`.
    private var laneY: [UUID: CGFloat] = [:]
    /// Steps track movement once per screen refresh while anything is moving.
    private var animationLink: CADisplayLink?
    private var lastAnimationStep: CFTimeInterval?
    /// The project with an in-progress trim applied, drawn until the trim is committed.
    private var previewProject: Project?
    /// The clip under the pointer, which shows its fade handles.
    private var hoveredClip: UUID?
    /// Frames for text clips, drawn once for each look and size.
    private struct TitleFrameKey: Hashable {
        var title: Title
        var visual: Visual
        var canvas: Canvas
        var height: Int
    }
    private var titleFrames: [TitleFrameKey: CGImage] = [:]

    var snapshot: TimelineSnapshot {
        didSet { snapshotDidChange(from: oldValue) }
    }

    init(store: ProjectStore, snapshot: TimelineSnapshot) {
        self.store = store
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        // Views no longer clip by default; without this, scrolled labels and grid lines draw over the panel.
        clipsToBounds = true
        registerForDraggedTypes([.string, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The timeline has the keyboard when the window opens, so single-key shortcuts such as Space work straight
    /// away, instead of the first text field in the panel taking it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.initialFirstResponder == nil {
            window.initialFirstResponder = self
        }
    }
    /// Drags here move clips and tracks, with or without modifiers; they never move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry

    private var project: Project { previewProject ?? snapshot.project }
    /// Where time zero sits when scrolled to the start: a margin in from the left edge.
    private var contentLeft: CGFloat { Layout.leadingInset }
    private var pixelsPerSecond: CGFloat { CGFloat(snapshot.pixelsPerSecond) }

    private func x(for time: Time) -> CGFloat {
        contentLeft + CGFloat(time.seconds) * pixelsPerSecond - scrollX
    }

    private func time(atX x: CGFloat) -> Time {
        Time(seconds: max(0, Double((x - contentLeft + scrollX) / pixelsPerSecond)))
    }

    private func rowHeight(_ track: Track) -> CGFloat {
        CGFloat(track.height * Layout.trackScale)
    }

    private var defaultRowHeight: CGFloat {
        rowHeight(Track(name: ""))
    }

    /// The track a clip is alone on. Dragging that clip carries the whole row, so its track steps out of the layout.
    private func soloTrack(of clipID: UUID?) -> Int? {
        guard let clipID, let location = project.location(ofClip: clipID),
              project.tracks[location.track].clips.count == 1 else { return nil }
        return location.track
    }

    /// Track indexes from the top down, leaving out the solo track of a clip being dragged.
    private func laneOrder(excluding clipID: UUID?) -> [Int] {
        let solo = soloTrack(of: clipID)
        return project.tracks.indices.reversed().filter { $0 != solo }
    }

    /// Resting tops of tracks in an order, in content coordinates (before scrolling).
    private func restingTops(_ order: [Int]) -> [CGFloat] {
        var y = Layout.lanesTop
        return order.map { index in
            defer { y += rowHeight(project.tracks[index]) + Layout.rowSpacing }
            return y
        }
    }

    /// Where a dragged item centered at `center` slots in among the tracks other than `excluded`, counted from the top.
    /// It's compared against every track's resting midpoint, its own row included, so a drag always starts in place.
    private func insertionPosition(forCenter center: CGFloat, excluding excluded: Int?) -> Int {
        let order = Array(project.tracks.indices.reversed())
        return zip(order, restingTops(order)).filter { index, top in
            index != excluded && top + rowHeight(project.tracks[index]) / 2 < center
        }.count
    }

    /// Where a dragged clip lands. Over the middle of a track it fits on, it joins that track; elsewhere a new
    /// track opens between the others. Uses resting positions, so the gap opening never moves the target.
    private func landing(forCenter center: CGFloat, range: TimeRange, movingClip: UUID?) -> (target: TrackTarget, gap: Int?) {
        let order = Array(project.tracks.indices.reversed())
        let solo = soloTrack(of: movingClip)
        for (position, (index, top)) in zip(order, restingTops(order)).enumerated() {
            let height = rowHeight(project.tracks[index])
            let zone = height * Layout.betweenTracksZone
            guard center >= top + zone, center <= top + height - zone else { continue }
            // Over its own row, a solo clip keeps its track, and the row stays open.
            if index == solo { return (.existing(project.tracks[index].id), position) }
            if project.isFree(track: index, range: range, excluding: movingClip) {
                return (.existing(project.tracks[index].id), nil)
            }
        }
        let position = insertionPosition(forCenter: center, excluding: solo)
        if let solo, order.firstIndex(of: solo) == position {
            return (.existing(project.tracks[solo].id), position)
        }
        let others = laneOrder(excluding: movingClip)
        let modelIndex = position < others.count ? others[position] + 1 : (others.last ?? 0)
        return (.new(at: modelIndex), position)
    }

    /// A dragged clip or track follows the pointer but never rises into the time labels.
    private func floatingTop(pointerY: CGFloat, grabY: CGFloat) -> CGFloat {
        max(Layout.lanesTop, pointerY - grabY)
    }

    private var movingTrack: (index: Int, rect: CGRect)? {
        guard case let .movingTrack(index, grabY, pointerY) = interaction else { return nil }
        return (index, CGRect(x: 0, y: floatingTop(pointerY: pointerY, grabY: grabY), width: bounds.width, height: rowHeight(project.tracks[index])))
    }

    /// Where every track belongs right now, top down in content coordinates, plus any gap opened for a drag.
    private func targetLayout() -> (lanes: [(index: Int, y: CGFloat)], gap: CGRect?) {
        var order = Array(project.tracks.indices.reversed())
        var gapPosition: Int?
        var gapHeight = defaultRowHeight
        if let moving = movingTrack {
            order.removeAll { $0 == moving.index }
            gapPosition = insertionPosition(forCenter: moving.rect.midY + scrollY, excluding: moving.index)
            gapHeight = moving.rect.height
        } else if let dragPreview {
            order = laneOrder(excluding: dragPreview.movingClip)
            gapPosition = dragPreview.gap
        }

        var y = Layout.lanesTop
        var lanes: [(index: Int, y: CGFloat)] = []
        var gap: CGRect?
        for position in 0...order.count {
            if position == gapPosition {
                gap = CGRect(x: 0, y: y, width: bounds.width, height: gapHeight)
                y += gapHeight + Layout.rowSpacing
            }
            guard position < order.count else { break }
            lanes.append((order[position], y))
            y += rowHeight(project.tracks[order[position]]) + Layout.rowSpacing
        }
        return (lanes, gap)
    }

    /// Track rectangles as drawn now, in view coordinates.
    private var rows: [(track: Int, rect: CGRect)] {
        targetLayout().lanes.map { lane in
            let track = project.tracks[lane.index]
            let y = laneY[track.id] ?? lane.y
            return (lane.index, CGRect(x: 0, y: y - scrollY, width: bounds.width, height: rowHeight(track)))
        }
    }

    private var contentHeight: CGFloat {
        let spacing = CGFloat(max(0, project.tracks.count - 1)) * Layout.rowSpacing
        return Layout.lanesTop + project.tracks.map(rowHeight).reduce(0, +) + spacing + 40
    }

    private func clipRect(_ clip: Clip, in row: CGRect) -> CGRect {
        CGRect(
            x: x(for: clip.start),
            y: row.minY + Layout.clipInset,
            width: max(2, CGFloat(clip.duration.seconds) * pixelsPerSecond),
            height: row.height - Layout.clipInset * 2
        )
    }

    /// Snaps a clip's start or end to the playhead, other clip edges or zero when within a few pixels. N turns it off.
    private func snapped(_ proposed: Time, duration: Time, excluding: UUID?) -> Time {
        guard store.isSnappingEnabled else { return max(.zero, proposed) }
        var candidates = [Time.zero, snapshot.currentTime]
        for track in snapshot.project.tracks {
            for clip in track.clips where clip.id != excluding {
                candidates += [clip.start, clip.end]
            }
        }
        let threshold = Double(Layout.snapDistance / pixelsPerSecond)
        var best: (distance: Double, start: Time)?
        for candidate in candidates {
            for offset in [Time.zero, duration] {
                let distance = abs((candidate - (proposed + offset)).seconds)
                if distance <= threshold, distance < (best?.distance ?? .infinity) {
                    best = (distance, candidate - offset)
                }
            }
        }
        return max(.zero, best?.start ?? proposed)
    }

    /// A clip edge under the pointer, on a track that isn't locked. Narrow clips keep most of their middle for moving.
    private func trimEdge(at point: CGPoint) -> (clip: Clip, edge: Project.ClipEdge)? {
        for row in rows where row.rect.minY <= point.y && point.y < row.rect.maxY && !project.tracks[row.track].isLocked {
            for clip in project.tracks[row.track].clips {
                let rect = clipRect(clip, in: row.rect)
                let zone = min(6, rect.width / 4)
                guard point.x >= rect.minX - zone, point.x <= rect.maxX + zone else { continue }
                if abs(point.x - rect.minX) <= zone { return (clip, .start) }
                if abs(point.x - rect.maxX) <= zone { return (clip, .end) }
            }
        }
        return nil
    }

    /// The region where two clips on a track overlap.
    private func crossfadeRect(_ crossfade: Crossfade, in row: CGRect) -> CGRect {
        let incoming = clipRect(crossfade.incoming, in: row)
        return CGRect(x: incoming.minX, y: incoming.minY,
                      width: max(2, CGFloat(crossfade.range.duration.seconds) * pixelsPerSecond), height: incoming.height)
    }

    /// A crossfade under the pointer. Its outer few points belong to the trim edges, so either clip can still be trimmed.
    private func crossfade(at point: CGPoint) -> Crossfade? {
        for row in rows where row.rect.minY <= point.y && point.y < row.rect.maxY {
            for crossfade in project.crossfades(onTrack: row.track) {
                let rect = crossfadeRect(crossfade, in: row.rect)
                if rect.insetBy(dx: min(6, rect.width / 4), dy: 0).contains(point) { return crossfade }
            }
        }
        return nil
    }

    /// The crossfades a dragged clip would make with the clips already on the track it would join, so they show before the drop.
    private var dragCrossfades: (track: Int, crossfades: [Crossfade])? {
        guard let dragPreview, dragPreview.gap == nil, case let .existing(id) = dragPreview.target,
              let index = project.tracks.firstIndex(where: { $0.id == id }) else { return nil }
        var landed = project
        landed.tracks[index].clips.removeAll { $0.id == dragPreview.clip.id }
        landed.tracks[index].clips.append(dragPreview.clip)
        landed.tracks[index].clips.sort { $0.start < $1.start }
        let crossfades = landed.crossfades(onTrack: index).filter { $0.incoming.id == dragPreview.clip.id || $0.outgoing.id == dragPreview.clip.id }
        return crossfades.isEmpty ? nil : (index, crossfades)
    }

    private var fadingClip: UUID? {
        if case let .fading(id, _, _, _, _) = interaction { id } else { nil }
    }

    /// Clips with sound show fade handles while selected or under the pointer, unless their track is locked.
    private func showsFadeHandles(_ clip: Clip, track: Int, in rect: CGRect) -> Bool {
        rect.width >= 30 && project.playsSound(clip) && !project.tracks[track].isLocked
            && (snapshot.selection.contains(clip.id) || hoveredClip == clip.id || fadingClip == clip.id)
    }

    /// A fade handle sits on the clip's top edge where the fade ends, clear of the rounded corners.
    private func fadeHandle(_ edge: Project.ClipEdge, of clip: Clip, in rect: CGRect) -> CGPoint {
        let length = CGFloat((edge == .start ? clip.fadeIn : clip.fadeOut).duration.seconds) * pixelsPerSecond
        let x = edge == .start ? rect.minX + length : rect.maxX - length
        let inset: CGFloat = 10
        return CGPoint(x: x.clamped(to: (rect.minX + inset)...max(rect.minX + inset, rect.maxX - inset)), y: rect.minY)
    }

    /// The edges that get a fade handle: ones that have a fade (added from a menu or the Audio tab) and don't
    /// crossfade, since a crossfade already fades that edge. An edge being dragged keeps its handle even at zero.
    private func fadeEdges(of clip: Clip, crossfades: [Crossfade]) -> [Project.ClipEdge] {
        [Project.ClipEdge.start, .end].filter { edge in
            if case let .fading(id, dragged, _, _, _) = interaction, id == clip.id, dragged == edge { return true }
            let hasFade = (edge == .start ? clip.fadeIn : clip.fadeOut).duration > .zero
            let crossfaded = crossfades.contains { edge == .start ? $0.incoming.id == clip.id : $0.outgoing.id == clip.id }
            return hasFade && !crossfaded
        }
    }

    private func fadeHandleHit(at point: CGPoint) -> (clip: Clip, edge: Project.ClipEdge)? {
        for row in rows where row.rect.minY - 6 <= point.y && point.y < row.rect.maxY {
            let crossfades = project.crossfades(onTrack: row.track)
            for clip in project.tracks[row.track].clips {
                let rect = clipRect(clip, in: row.rect)
                guard showsFadeHandles(clip, track: row.track, in: rect) else { continue }
                for edge in fadeEdges(of: clip, crossfades: crossfades) {
                    let handle = fadeHandle(edge, of: clip, in: rect)
                    if hypot(point.x - handle.x, point.y - handle.y) <= 7 { return (clip, edge) }
                }
            }
        }
        return nil
    }

    /// The clip under the pointer, counting a little above its top edge where the fade handles sit.
    private func clip(near point: CGPoint) -> Clip? {
        for row in rows {
            for clip in project.tracks[row.track].clips.reversed() where clipRect(clip, in: row.rect).insetBy(dx: 0, dy: -6).contains(point) {
                return clip
            }
        }
        return nil
    }

    private var maxScrollX: CGFloat {
        max(0, CGFloat(project.duration.seconds + 10) * pixelsPerSecond - (bounds.width - contentLeft))
    }

    private var maxScrollY: CGFloat {
        max(0, contentHeight - bounds.height)
    }

    // MARK: Track animation

    /// Starts tracks easing toward their places after the layout changes. New tracks appear in place.
    private func updateLanes() {
        let targets = laneTargets()
        laneY = laneY.filter { targets[$0.key] != nil }
        for (id, y) in targets where laneY[id] == nil {
            laneY[id] = y
        }
        if targets.contains(where: { abs((laneY[$0.key] ?? $0.value) - $0.value) > 0.5 }) {
            startAnimation()
        }
        needsDisplay = true
    }

    private func laneTargets() -> [UUID: CGFloat] {
        Dictionary(uniqueKeysWithValues: targetLayout().lanes.map { (project.tracks[$0.index].id, $0.y) })
    }

    private func startAnimation() {
        guard animationLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepAnimation(_:)))
        // Common modes keep it running while the mouse is held down.
        link.add(to: .main, forMode: .common)
        animationLink = link
        lastAnimationStep = nil
    }

    @objc private func stepAnimation(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = now - (lastAnimationStep ?? now - 1.0 / 60)
        lastAnimationStep = now
        var isMoving = false
        // Tracks making room during a drag close 30% of the way every 60th of a second, at any refresh rate.
        let share = 1 - pow(0.7, elapsed * 60)
        for (id, target) in laneTargets() {
            let current = laneY[id] ?? target
            let next = current + (target - current) * share
            if abs(target - next) < 0.5 {
                laneY[id] = target
            } else {
                laneY[id] = next
                isMoving = true
            }
        }
        needsDisplay = true
        if !isMoving {
            animationLink?.invalidate()
            animationLink = nil
        }
    }

    // MARK: Updates

    private func snapshotDidChange(from old: TimelineSnapshot) {
        if old.pixelsPerSecond != snapshot.pixelsPerSecond {
            // Keep the anchor (the pointer, else the playhead, else the left edge) still while zooming.
            let oldPPS = CGFloat(old.pixelsPerSecond)
            let anchor: (time: Time, x: CGFloat)
            if let zoomAnchor {
                anchor = zoomAnchor
            } else {
                let playheadX = contentLeft + CGFloat(snapshot.currentTime.seconds) * oldPPS - scrollX
                if playheadX >= 0, playheadX <= bounds.width {
                    anchor = (snapshot.currentTime, playheadX)
                } else {
                    anchor = (Time(seconds: Double(scrollX / oldPPS)), contentLeft)
                }
            }
            scrollX = CGFloat(anchor.time.seconds) * pixelsPerSecond - (anchor.x - contentLeft)
            zoomAnchor = nil
        }
        // Page along with the playhead during playback.
        if snapshot.isPlaying, x(for: snapshot.currentTime) > bounds.width - 24 {
            scrollX = CGFloat(snapshot.currentTime.seconds) * pixelsPerSecond - 40
        }
        scrollX = max(0, scrollX)
        scrollY = scrollY.clamped(to: 0...maxScrollY)
        if old.project != snapshot.project {
            updateLanes()
        }
        needsDisplay = true
    }

    /// Picks up an edit right away, so tracks animate from where they were dragged instead of jumping back first.
    private func refreshFromStore() {
        snapshot.project = store.project
        snapshot.selection = store.selection
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The timeline only redraws when asked, so without this a resize would stretch the last drawing.
        needsDisplay = true
        reportViewportWidth()
        updateLanes()
    }

    /// The width that shows time, for zooming to fit.
    private func reportViewportWidth() {
        let width = Double(bounds.width - contentLeft)
        Task { @MainActor [store] in
            store.timelineViewportWidth = width
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.timeline.setFill()
        bounds.fill()
        drawTimeGrid()

        let layout = targetLayout()
        let rows = rows
        let moving = movingTrack
        if let gap = layout.gap {
            (moving == nil ? Theme.landingTrack : Theme.timelineSlot).setFill()
            gap.offsetBy(dx: 0, dy: -scrollY).fill(using: .sourceOver)
        }
        if case let .existing(id)? = dragPreview?.target, dragPreview?.gap == nil,
           let row = rows.first(where: { project.tracks[$0.track].id == id }) {
            Theme.landingTrack.setFill()
            row.rect.fill(using: .sourceOver)
        }

        NSGraphicsContext.saveGraphicsState()
        CGRect(x: 0, y: Layout.rulerHeight, width: bounds.width, height: bounds.height).clip()
        for row in rows {
            drawClips(of: row.track, in: row.rect)
        }
        if let moving {
            drawLiftedTrack(moving.index, in: moving.rect)
        }
        if let dragPreview {
            let floating = CGRect(x: 0, y: dragPreview.top, width: bounds.width, height: defaultRowHeight)
            let drag = dragCrossfades
            drawClip(dragPreview.clip, in: clipRect(dragPreview.clip, in: floating), selected: true, label: dragPreview.label, lifted: true,
                     crossfades: drag?.crossfades ?? [])
            // The crossfades the drop would make, drawn on the track it would join.
            if let drag, let row = rows.first(where: { $0.track == drag.track }) {
                for crossfade in drag.crossfades {
                    drawCrossfade(crossfade, in: crossfadeRect(crossfade, in: row.rect))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        for row in rows where row.rect.maxY > Layout.rulerHeight {
            drawTrackStatus(project.tracks[row.track], in: row.rect)
        }
        if case let .boxSelecting(origin, current, _) = interaction {
            let box = selectionBox(origin, current)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            box.fill(using: .sourceOver)
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if rows.isEmpty, dragPreview == nil, moving == nil {
            drawEmptyHint()
        }
        drawPlayhead()
    }

    private func selectionBox(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drawEmptyHint() {
        let hint = "Drag media, titles or backgrounds here" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = hint.size(withAttributes: attributes)
        let area = CGRect(x: 0, y: Layout.rulerHeight, width: bounds.width, height: bounds.height - Layout.rulerHeight)
        hint.draw(at: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawClips(of track: Int, in row: CGRect) {
        // Muted tracks, and tracks a solo leaves out, draw dimmed.
        NSGraphicsContext.saveGraphicsState()
        if !project.isActive(project.tracks[track]) {
            NSGraphicsContext.current?.cgContext.setAlpha(0.4)
        }
        let moving = dragPreview?.movingClip
        let crossfades = project.crossfades(onTrack: track).filter { $0.incoming.id != moving && $0.outgoing.id != moving }
        // Neighbors of a dragged clip already fade the way they will once it's dropped.
        let gains = crossfades + (dragCrossfades.flatMap { $0.track == track ? $0.crossfades : nil } ?? [])
        // Later clips draw over earlier ones, so where two overlap the incoming clip is on top.
        let clips = project.tracks[track].clips.filter { $0.id != moving }.sorted { $0.start < $1.start }
        for clip in clips {
            drawClip(clip, in: clipRect(clip, in: row), selected: snapshot.selection.contains(clip.id), crossfades: gains)
        }
        for crossfade in crossfades {
            drawCrossfade(crossfade, in: crossfadeRect(crossfade, in: row))
        }
        for clip in clips {
            let rect = clipRect(clip, in: row)
            if showsFadeHandles(clip, track: track, in: rect) { drawFadeHandles(clip, edges: fadeEdges(of: clip, crossfades: crossfades), in: rect) }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Where two clips overlap: a darker box with both gain curves crossing, the incoming one brighter.
    private func drawCrossfade(_ crossfade: Crossfade, in rect: CGRect) {
        guard rect.maxX >= 0, rect.minX <= bounds.width else { return }
        let selected = snapshot.selectedTransition == crossfade.incoming.id
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : Theme.crossfadeFill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let area = rect.insetBy(dx: 0, dy: 6)
        let steps = max(12, Int(rect.width / 3))
        for rising in [false, true] {
            let path = NSBezierPath()
            for step in 0...steps {
                let progress = Double(step) / Double(steps)
                let gain = crossfade.curve.gain(at: rising ? progress : 1 - progress)
                let point = CGPoint(x: area.minX + CGFloat(progress) * area.width, y: area.maxY - CGFloat(gain) * area.height)
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            (rising ? Theme.crossfadeIncoming : Theme.crossfadeOutgoing).setStroke()
            path.stroke()
        }

        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        stroke.lineWidth = selected ? 1.5 : 1
        (selected ? NSColor.controlAccentColor : Theme.crossfadeStroke).setStroke()
        stroke.stroke()
    }

    /// A fade darkens the part of the clip above its curve.
    private func drawFadeShade(_ fade: Fade, edge: Project.ClipEdge, in rect: CGRect) {
        let length = min(CGFloat(fade.duration.seconds) * pixelsPerSecond, rect.width / 2)
        guard length >= 1 else { return }
        let curve = NSBezierPath()
        let steps = max(8, Int(length / 3))
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let x = edge == .start ? rect.minX + CGFloat(progress) * length : rect.maxX - CGFloat(progress) * length
            let point = CGPoint(x: x, y: rect.maxY - CGFloat(fade.curve.gain(at: progress)) * rect.height)
            if step == 0 { curve.move(to: point) } else { curve.line(to: point) }
        }
        let shade = curve.copy() as! NSBezierPath
        shade.line(to: CGPoint(x: edge == .start ? rect.minX + length : rect.maxX - length, y: rect.minY))
        shade.line(to: CGPoint(x: edge == .start ? rect.minX : rect.maxX, y: rect.minY))
        shade.close()
        Theme.fadeShade.setFill()
        shade.fill()
        curve.lineWidth = 1
        Theme.fadeLine.setStroke()
        curve.stroke()
    }

    /// How text comes in or goes out, over its first or last half second: the same ramp a sound fade draws.
    private func drawTitleAnimation(_ animation: TitleAnimation, edge: Project.ClipEdge, in rect: CGRect) {
        guard animation != .none else { return }
        drawFadeShade(Fade(duration: Time(seconds: TitleAnimation.duration), curve: .sCurve), edge: edge, in: rect)
    }

    /// White dots on the top edge where each fade ends; dragging one sets the fade's length.
    private func drawFadeHandles(_ clip: Clip, edges: [Project.ClipEdge], in rect: CGRect) {
        for edge in edges {
            let center = fadeHandle(edge, of: clip, in: rect)
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
        // While dragging, the fade's length shows beside its handle.
        guard case let .fading(id, edge, _, _, duration?) = interaction, id == clip.id else { return }
        let text = String(format: "%.1f s", duration.seconds) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let handle = fadeHandle(edge, of: clip, in: rect)
        let x = edge == .start ? handle.x + 9 : handle.x - 9 - size.width
        let tag = CGRect(x: x - 5, y: rect.minY + 6, width: size.width + 10, height: size.height + 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: x, y: tag.minY + 1), withAttributes: attributes)
    }

    /// Small icons at a track's left edge for mute, solo and lock, shown only while they're on.
    private func drawTrackStatus(_ track: Track, in row: CGRect) {
        let symbols = [
            track.isMuted ? "speaker.slash.fill" : nil,
            track.isSoloed ? "s.circle.fill" : nil,
            track.isLocked ? "lock.fill" : nil,
        ].compactMap { $0 }
        guard !symbols.isEmpty else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.9)]))
        let pill = CGRect(x: 3, y: row.midY - 9, width: CGFloat(symbols.count) * 14 + 6, height: 18)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        for (index, symbol) in symbols.enumerated() {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { continue }
            let size = image.size
            image.draw(in: CGRect(x: pill.minX + 3 + CGFloat(index) * 14 + (14 - size.width) / 2, y: row.midY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawClip(_ clip: Clip, in rect: CGRect, selected: Bool, label: String? = nil, lifted: Bool = false, crossfades: [Crossfade] = []) {
        guard rect.maxX >= 0, rect.minX <= bounds.width else { return }
        let asset = project.asset(clip.assetID)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        // A video's detached sound draws like an audio clip.
        let isAudio = !project.showsPicture(clip)
        let top = isAudio ? Theme.audioClipTop : Theme.clipTop
        let bottom = isAudio ? Theme.audioClipBottom : Theme.clipBottom

        // A soft shadow under every clip, deeper while it's being dragged.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = lifted ? 12 : 4
        shadow.shadowOffset = NSSize(width: 0, height: lifted ? -4 : -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(lifted ? 0.6 : 0.35)
        shadow.set()
        bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // In the flipped view, 90 degrees runs top to bottom.
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // A background clip shows its color, gradient or wallpaper.
        if let fill = clip.fill {
            drawFill(fill, in: rect)
        }
        var waveformArea = rect.insetBy(dx: 0, dy: 4)
        let filmstrip = snapshot.filmstrips[clip.assetID]
        let hasSound = project.playsSound(clip)
        let canvas = project.canvas ?? Project.defaultCanvas
        // Text shows as a frame of the canvas with the text in place; media shows its own frames.
        let thumbnail = clip.title != nil ? titleFrame(for: clip, canvas: canvas, height: rect.height) : snapshot.thumbnails[clip.assetID]
        let hasFrames = project.showsPicture(clip) && (filmstrip != nil || thumbnail != nil)
        if hasFrames {
            let frames = hasSound
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.6)
                : rect
            let aspect: Double = if let ratio = filmstrip?.aspectRatio {
                ratio
            } else if clip.title == nil, let width = asset?.pixelWidth, let height = asset?.pixelHeight, height > 0 {
                Double(width) / Double(height)
            } else {
                Double(canvas.width) / Double(max(canvas.height, 1))
            }
            drawFilmstrip(filmstrip, fallback: thumbnail, aspect: aspect, clip: clip, in: frames)
            waveformArea = CGRect(x: rect.minX, y: frames.maxY, width: rect.width, height: rect.maxY - frames.maxY)
        } else if isAudio {
            waveformArea = CGRect(x: rect.minX, y: rect.minY + 16, width: rect.width, height: rect.height - 18)
        }
        // With Isolate voice on, the clip shows the isolated sound once it's worked out, and its own until then.
        let waveform = (clip.isolatesVoice ? snapshot.isolatedWaveforms[clip.assetID] : nil) ?? snapshot.waveforms[clip.assetID]
        if hasSound, let waveform, waveformArea.height > 4 {
            // The waveform follows the clip's gain, so fades and crossfades look the way they sound.
            var gain = GainSegment(clip: clip, fadeIn: clip.playedFade(.start, crossfades: crossfades),
                                   fadeOut: clip.playedFade(.end, crossfades: crossfades))
            gain.addCrossfades(crossfades, of: clip.id)
            drawWaveform(waveform, clip: clip, gain: gain, clipRect: rect, area: waveformArea)
        }
        if hasSound {
            drawFadeShade(clip.playedFade(.start, crossfades: crossfades), edge: .start, in: rect)
            drawFadeShade(clip.playedFade(.end, crossfades: crossfades), edge: .end, in: rect)
        }
        if let title = clip.title {
            drawTitleAnimation(title.animationIn, edge: .start, in: rect)
            drawTitleAnimation(title.animationOut, edge: .end, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        if selected {
            Theme.clipSelectedStroke.setStroke()
            stroke.lineWidth = 1.5
        } else {
            Theme.clipStroke.setStroke()
            stroke.lineWidth = 1
        }
        stroke.stroke()
        var name = label ?? asset?.displayName
            ?? clip.title.map { $0.text.split(separator: "\n").first.map(String.init) ?? "Text" }
            ?? (clip.fill != nil ? "Background" : "Missing media")
        if clip.speed != 1 {
            name += "  \(clip.speed.formatted(.number.precision(.fractionLength(0...2))))×"
        }
        // An incoming clip's name starts after its crossfade, which draws over the clip's start.
        let crossfadeIn = crossfades.first { $0.incoming.id == clip.id }
        drawLabel(name, in: rect, overImage: hasFrames || clip.fill != nil, leadingInset: crossfadeIn.map { CGFloat($0.range.duration.seconds) * pixelsPerSecond } ?? 0)
    }

    /// A text clip's frame at the track's height, in screen pixels. Heights round up to steps, so tracks easing
    /// between heights don't draw a new frame every step.
    private func titleFrame(for clip: Clip, canvas: Canvas, height: CGFloat) -> CGImage? {
        guard let title = clip.title else { return nil }
        let pixels = Int((height * (window?.backingScaleFactor ?? 2) / 24).rounded(.up)) * 24
        let key = TitleFrameKey(title: title, visual: clip.visual, canvas: canvas, height: pixels)
        if let cached = titleFrames[key] { return cached }
        guard let frame = TitleRenderer.frame(for: title, visual: clip.visual,
                                              canvas: CGSize(width: canvas.width, height: canvas.height), height: pixels) else { return nil }
        // Old looks pile up as text is edited; starting over now and then keeps the cache small.
        if titleFrames.count > 64 { titleFrames.removeAll() }
        titleFrames[key] = frame
        return frame
    }

    private func drawFill(_ fill: BackgroundFill, in rect: CGRect) {
        func color(_ rgba: RGBA) -> NSColor {
            NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        switch fill {
        case let .color(rgba):
            color(rgba).setFill()
            rect.fill(using: .sourceOver)
        case let .gradient(gradient):
            // The view is flipped, so the angle runs clockwise from the right, as the gradient's does.
            NSGradient(starting: color(gradient.from), ending: color(gradient.to))?.draw(in: rect, angle: gradient.angle)
        case let .wallpaper(id):
            guard let image = snapshot.thumbnails[id], let context = NSGraphicsContext.current?.cgContext else { return }
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            context.saveGState()
            context.translateBy(x: 0, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height))
            context.restoreGState()
        }
    }

    /// Tiles frames across the clip, each showing the moment at its own position on the timeline.
    private func drawFilmstrip(_ filmstrip: Filmstrip?, fallback: CGImage?, aspect: Double, clip: Clip, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let tileWidth = rect.height * CGFloat(aspect)
        guard tileWidth > 1 else { return }

        context.interpolationQuality = .medium
        var tile = rect.minX < 0 ? Int(-rect.minX / tileWidth) : 0
        while true {
            let tileX = rect.minX + CGFloat(tile) * tileWidth
            guard tileX < min(rect.maxX, bounds.width) else { break }
            let sourceTime = clip.sourceStart.seconds + Double((CGFloat(tile) + 0.5) * tileWidth / pixelsPerSecond) * clip.speed
            if let image = filmstrip?.frame(at: sourceTime) ?? fallback {
                // The view is flipped, so flip back to draw the image upright.
                let target = CGRect(x: tileX, y: rect.minY, width: tileWidth, height: rect.height)
                context.saveGState()
                context.translateBy(x: 0, y: target.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: target.minX, y: 0, width: target.width, height: target.height))
                context.restoreGState()
            }
            tile += 1
        }
    }

    private func drawWaveform(_ waveform: Waveform, clip: Clip, gain: GainSegment, clipRect rect: CGRect, area: CGRect) {
        let path = NSBezierPath()
        // 1.5-point bars with a 1-point gap between them.
        let step: CGFloat = 2.5
        let barWidth: CGFloat = 1.5
        // Source time runs `speed` times faster than the timeline.
        let secondsPerStep = Double(step / pixelsPerSecond) * clip.speed
        var column = max(rect.minX, 0)
        let end = min(rect.maxX, bounds.width)
        while column < end {
            let sourceTime = clip.sourceStart.seconds + Double((column - rect.minX) / pixelsPerSecond) * clip.speed
            let level = Double(waveform.peak(from: sourceTime, to: sourceTime + secondsPerStep)) * gain.gain(atLocal: Double((column - rect.minX) / pixelsPerSecond))
            let height = max(1, CGFloat(min(1, level)) * area.height * 0.95)
            path.appendRect(CGRect(x: column, y: area.midY - height / 2, width: barWidth, height: height))
            column += step
        }
        Theme.waveform.setFill()
        path.fill()
    }

    private func drawLabel(_ text: String, in rect: CGRect, overImage: Bool, leadingInset: CGFloat = 0) {
        let visibleMinX = max(rect.minX + leadingInset, 0)
        let width = rect.maxX - visibleMinX - 12
        guard width > 16 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: overImage ? NSColor.white : NSColor.labelColor,
        ]
        let label = text as NSString
        let size = label.size(withAttributes: attributes)
        let labelRect = CGRect(x: visibleMinX + 6, y: rect.minY + 2, width: min(size.width, width), height: size.height)
        if overImage {
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: labelRect.insetBy(dx: -4, dy: -1), xRadius: 4, yRadius: 4).fill()
        }
        label.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    /// The track being reordered, floating under the pointer.
    private func drawLiftedTrack(_ track: Int, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.set()
        Theme.timelineLifted.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
        drawClips(of: track, in: rect)
    }

    /// Time labels along the top, with faint lines that run down through every track.
    private func drawTimeGrid() {
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 * Double(pixelsPerSecond) >= 80 } ?? 600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var tick = (time(atX: 0).seconds / step).rounded(.down) * step
        while x(for: Time(seconds: tick)) < bounds.width {
            let tickX = x(for: Time(seconds: tick))
            // Set the color for every line: drawing a label changes the current fill color.
            // Translucent fills must blend; a plain fill() copies the alpha and punches through the background.
            Theme.gridline.setFill()
            CGRect(x: tickX, y: Layout.rulerHeight - 6, width: 1, height: bounds.height).fill(using: .sourceOver)
            let label = rulerLabel(tick, step: step) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: tickX - (tick == 0 ? 0 : size.width / 2), y: 6), withAttributes: attributes)
            tick += step
        }
    }

    private func rulerLabel(_ seconds: Double, step: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return step < 1
            ? String(format: "%02d:%04.1f", minutes, remainder)
            : String(format: "%02d:%02d", minutes, Int(remainder.rounded()))
    }

    /// A line with a pin-shaped head: a round top that tapers to a point where the line begins.
    private func drawPlayhead() {
        let playheadX = x(for: snapshot.currentTime)
        guard playheadX >= -8, playheadX <= bounds.width + 8 else { return }
        let width: CGFloat = 12
        let height: CGFloat = 16
        let top = Layout.rulerHeight - 9
        let radius = width / 2
        let tip = CGPoint(x: playheadX, y: top + height)

        Theme.playhead.setFill()
        CGRect(x: playheadX - 0.75, y: tip.y - 1, width: 1.5, height: bounds.height).fill()
        let head = NSBezierPath()
        head.move(to: tip)
        head.curve(to: CGPoint(x: playheadX - radius, y: top + radius),
                   controlPoint1: CGPoint(x: playheadX - 1, y: tip.y - 3),
                   controlPoint2: CGPoint(x: playheadX - radius, y: top + radius + 4))
        // In the flipped view, 180° to 360° runs over the top.
        head.appendArc(withCenter: CGPoint(x: playheadX, y: top + radius), radius: radius, startAngle: 180, endAngle: 360, clockwise: false)
        head.curve(to: tip,
                   controlPoint1: CGPoint(x: playheadX + radius, y: top + radius + 4),
                   controlPoint2: CGPoint(x: playheadX + 1, y: tip.y - 3))
        head.close()
        head.fill()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if point.y < Layout.rulerHeight {
            interaction = .scrubbing
            store.playback.seek(to: time(atX: point.x))
            return
        }

        // Fade handles come first: they sit on a clip's top edge, inside its trim zones.
        if let (clip, edge) = fadeHandleHit(at: point) {
            if !snapshot.selection.contains(clip.id) { store.select([clip.id]) }
            let fade = edge == .start ? clip.fadeIn : clip.fadeOut
            interaction = .fading(id: clip.id, edge: edge, startDuration: fade.duration, downX: point.x, duration: nil)
            return
        }

        // A click inside an overlap selects its crossfade.
        if !event.modifierFlags.contains(.command), let crossfade = crossfade(at: point) {
            store.selectTransition(crossfade.incoming.id)
            store.playback.seek(to: time(atX: point.x))
            return
        }

        // A clip's edges trim it.
        if !event.modifierFlags.contains(.command), let (clip, edge) = trimEdge(at: point) {
            if !snapshot.selection.contains(clip.id) { store.select([clip.id]) }
            let edgeTime = edge == .start ? clip.start : clip.end
            interaction = .trimming(id: clip.id, edge: edge, grabOffset: time(atX: point.x) - edgeTime, time: nil, ripple: false)
            return
        }

        // The playhead moves on a click or a sideways scrub, never on the press that starts a drag.
        let row = rows.first { $0.rect.minY <= point.y && point.y < $0.rect.maxY }
        guard let row, let clip = project.tracks[row.track].clips.first(where: { clipRect($0, in: row.rect).contains(point) }) else {
            if event.modifierFlags.contains(.command) {
                interaction = .boxSelecting(origin: point, current: point, base: snapshot.selection)
            } else {
                interaction = .pressingEmptySpace(track: row?.track, grabY: point.y - (row?.rect.minY ?? point.y), downPoint: point)
            }
            return
        }

        var selection = snapshot.selection
        if event.modifierFlags.contains(.command) {
            if selection.contains(clip.id) { selection.remove(clip.id) } else { selection.insert(clip.id) }
        } else if event.modifierFlags.contains(.shift) {
            selection.insert(clip.id)
        } else if !selection.contains(clip.id) {
            selection = [clip.id]
        }
        store.select(selection)
        // Double-clicking a clip opens the tab that edits it, from anywhere.
        if event.clickCount == 2 {
            store.showMainTab()
        }
        interaction = .pressingClip(id: clip.id, grabTime: time(atX: point.x) - clip.start, grabY: point.y - row.rect.minY, downPoint: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .scrubbing:
            store.playback.seek(to: time(atX: point.x))
        case let .pressingClip(id, grabTime, grabY, downPoint):
            // Clips on locked tracks select but don't move.
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) > Layout.dragThreshold, !project.isLocked(clip: id) else { return }
            NSCursor.closedHand.push()
            moveClip(id: id, grabTime: grabTime, grabY: grabY, downY: downPoint.y, leftTrack: false, point: point)
        case let .movingClip(id, grabTime, grabY, downY, leftTrack):
            moveClip(id: id, grabTime: grabTime, grabY: grabY, downY: downY, leftTrack: leftTrack, point: point)
        case let .pressingEmptySpace(track, grabY, downPoint):
            // The first clear movement decides: up or down moves the track, anything else scrubs.
            let dx = abs(point.x - downPoint.x)
            let dy = abs(point.y - downPoint.y)
            guard hypot(dx, dy) > Layout.dragThreshold else { return }
            if let track, dy > dx {
                NSCursor.closedHand.push()
                interaction = .movingTrack(index: track, grabY: grabY, pointerY: point.y)
                updateLanes()
            } else {
                interaction = .scrubbing
                store.playback.seek(to: time(atX: point.x))
            }
        case let .movingTrack(index, grabY, _):
            interaction = .movingTrack(index: index, grabY: grabY, pointerY: point.y)
            updateLanes()
        case let .trimming(id, edge, grabOffset, _, _):
            let ripple = event.modifierFlags.contains(.shift)
            let edgeTime = snappedEdge(time(atX: point.x) - grabOffset, excluding: id)
            var preview = snapshot.project
            preview.trim(id, edge: edge, to: edgeTime, ripple: ripple)
            previewProject = preview
            interaction = .trimming(id: id, edge: edge, grabOffset: grabOffset, time: edgeTime, ripple: ripple)
            needsDisplay = true
        case let .boxSelecting(origin, _, base):
            interaction = .boxSelecting(origin: origin, current: point, base: base)
            let box = selectionBox(origin, point)
            let hits = rows.flatMap { row in
                project.tracks[row.track].clips.filter { clipRect($0, in: row.rect).intersects(box) }.map(\.id)
            }
            store.select(base.union(hits))
            needsDisplay = true
        case let .fading(id, edge, startDuration, downX, _):
            let delta = Time(seconds: Double((point.x - downX) / pixelsPerSecond))
            var preview = snapshot.project
            preview.setFade(edge, of: [id], duration: max(.zero, edge == .start ? startDuration + delta : startDuration - delta))
            previewProject = preview
            let duration = preview.clip(id).map { edge == .start ? $0.fadeIn.duration : $0.fadeOut.duration }
            interaction = .fading(id: id, edge: edge, startDuration: startDuration, downX: downX, duration: duration)
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case let .pressingClip(_, _, _, downPoint):
            store.playback.seek(to: time(atX: downPoint.x))
        case let .pressingEmptySpace(_, _, downPoint):
            store.select([])
            store.selectTransition(nil)
            store.playback.seek(to: time(atX: downPoint.x))
        case let .movingClip(id, _, _, _, _):
            if let dragPreview {
                store.moveClip(id, to: dragPreview.clip.start, target: dragPreview.target)
            }
            NSCursor.pop()
        case let .movingTrack(index, _, _):
            if let moving = movingTrack {
                let position = insertionPosition(forCenter: moving.rect.midY + scrollY, excluding: index)
                store.moveTrack(from: index, to: project.tracks.count - 1 - position)
            }
            NSCursor.pop()
        case let .trimming(id, edge, _, time, ripple):
            if let time {
                store.trim(id, edge: edge, to: time, ripple: ripple)
            }
        case let .fading(id, edge, _, _, duration):
            if let duration {
                store.setFade(edge, duration: duration, clips: [id])
            }
        default:
            break
        }
        interaction = .none
        dragPreview = nil
        previewProject = nil
        refreshFromStore()
        updateLanes()
    }

    /// Snaps a trimmed edge to the playhead or another clip's edge.
    private func snappedEdge(_ proposed: Time, excluding id: UUID) -> Time {
        snapped(proposed, duration: .zero, excluding: id)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The clip under the pointer shows its fade handles. Clip edges and fade handles show the resize pointer.
    override func mouseMoved(with event: NSEvent) {
        guard case .none = interaction else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hovered = point.y < Layout.rulerHeight ? nil : clip(near: point)?.id
        if hovered != hoveredClip {
            hoveredClip = hovered
            needsDisplay = true
        }
        let resizes = fadeHandleHit(at: point) != nil || (crossfade(at: point) == nil && trimEdge(at: point) != nil)
        (resizes ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredClip != nil else { return }
        hoveredClip = nil
        needsDisplay = true
    }

    // MARK: Right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = rows.first(where: { $0.rect.minY <= point.y && point.y < $0.rect.maxY }) else { return nil }
        let track = project.tracks[row.track]
        let menu = NSMenu()

        if let crossfade = crossfade(at: point) {
            store.selectTransition(crossfade.incoming.id)
            let header = NSMenuItem(title: "Crossfade Curve", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for curve in Curve.presets {
                let item = menuItem(curve.name, #selector(contextCurve(_:)))
                item.representedObject = curve
                item.state = crossfade.curve == curve ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        } else if let clip = track.clips.first(where: { clipRect($0, in: row.rect).contains(point) }) {
            if !snapshot.selection.contains(clip.id) { store.select([clip.id]) }
            menu.addItem(menuItem("Split at Playhead", #selector(contextSplit), key: "b"))
            if store.canDetachAudio {
                menu.addItem(menuItem("Detach Audio", #selector(contextDetachAudio), key: "s", modifiers: [.control, .shift]))
            }
            let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
            let speeds = NSMenu()
            for value in [0.25, 0.5, 1, 1.5, 2, 4] {
                let item = menuItem("\(value.formatted(.number.precision(.fractionLength(0...2))))×", #selector(contextSpeed(_:)))
                item.representedObject = value
                item.state = abs(clip.speed - value) < 0.001 ? .on : .off
                speeds.addItem(item)
            }
            speed.submenu = speeds
            menu.addItem(speed)
            // Edges that crossfade take no fade of their own.
            let fadeEdges = [Project.ClipEdge.start, .end].filter(store.canFade)
            if !fadeEdges.isEmpty {
                menu.addItem(.separator())
                for edge in fadeEdges {
                    menu.addItem(fadeMenu(edge))
                }
            }
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete", #selector(contextDelete), key: Self.deleteKey, modifiers: []))
            menu.addItem(menuItem("Delete and Close Gap", #selector(contextRippleDelete), key: Self.deleteKey, modifiers: .shift))
            menu.addItem(.separator())
        }

        for (title, flag, isOn) in [("Mute Track", \Track.isMuted, track.isMuted), ("Solo Track", \Track.isSoloed, track.isSoloed), ("Lock Track", \Track.isLocked, track.isLocked)] {
            let item = menuItem(title, #selector(contextToggleTrack(_:)))
            item.representedObject = TrackFlagRequest(trackID: track.id, flag: flag, value: !isOn)
            item.state = isOn ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private final class TrackFlagRequest: NSObject {
        let trackID: UUID
        let flag: WritableKeyPath<Track, Bool>
        let value: Bool

        init(trackID: UUID, flag: WritableKeyPath<Track, Bool>, value: Bool) {
            self.trackID = trackID
            self.flag = flag
            self.value = value
        }
    }

    /// A right-click menu item. Commands that have a shortcut show it, matching the main menus.
    private func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private static let deleteKey = String(Character(UnicodeScalar(UInt8(NSBackspaceCharacter))))

    @objc private func contextSplit() { store.splitAtPlayhead() }
    @objc private func contextDetachAudio() { store.detachAudio() }
    @objc private func contextDelete() { store.deleteSelection() }
    @objc private func contextRippleDelete() { store.deleteSelection(closingGaps: true) }

    /// What a Fade In or Fade Out menu choice sets: a curve, or none to take the fade away.
    private struct FadeChoice {
        let edge: Project.ClipEdge
        let curve: Curve?
    }

    /// Fade In or Fade Out: None, then the curves. Choosing a curve where there's no fade adds a one-second
    /// fade; its length is then set by dragging its handle.
    private func fadeMenu(_ edge: Project.ClipEdge) -> NSMenuItem {
        let current = store.selectionFade(edge)
        let submenu = NSMenu()
        let none = menuItem("None", #selector(contextFade(_:)))
        none.representedObject = FadeChoice(edge: edge, curve: nil)
        none.state = current == nil ? .on : .off
        submenu.addItem(none)
        submenu.addItem(.separator())
        for curve in Curve.presets {
            let item = menuItem(curve.name, #selector(contextFade(_:)))
            item.representedObject = FadeChoice(edge: edge, curve: curve)
            item.state = current?.curve == curve ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: edge == .start ? "Fade In" : "Fade Out", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func contextFade(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? FadeChoice else { return }
        store.setSelectionFade(choice.edge, curve: choice.curve)
    }

    @objc private func contextCurve(_ item: NSMenuItem) {
        if let curve = item.representedObject as? Curve { store.setCrossfadeCurve(curve) }
    }

    @objc private func contextSpeed(_ item: NSMenuItem) {
        if let speed = item.representedObject as? Double { store.setSpeed(speed) }
    }

    @objc private func contextToggleTrack(_ item: NSMenuItem) {
        guard let request = item.representedObject as? TrackFlagRequest else { return }
        store.setTrackFlag(request.flag, to: request.value, onTracks: [request.trackID])
    }

    /// Moves a clip sideways only, until the pointer goes far enough up or down to mean a track change.
    private func moveClip(id: UUID, grabTime: Time, grabY: CGFloat, downY: CGFloat, leftTrack: Bool, point: CGPoint) {
        let leftTrack = leftTrack || abs(point.y - downY) > Layout.trackChangeTolerance
        interaction = .movingClip(id: id, grabTime: grabTime, grabY: grabY, downY: downY, leftTrack: leftTrack)
        updateMovePreview(id: id, grabTime: grabTime, grabY: grabY, point: leftTrack ? point : CGPoint(x: point.x, y: downY))
    }

    private func updateMovePreview(id: UUID, grabTime: Time, grabY: CGFloat, point: CGPoint) {
        guard var clip = project.clip(id) else { return }
        clip.start = snapped(time(atX: point.x) - grabTime, duration: clip.duration, excluding: id)
        let top = floatingTop(pointerY: point.y, grabY: grabY)
        let landing = landing(forCenter: top + scrollY + defaultRowHeight / 2, range: clip.range, movingClip: id)
        dragPreview = DragPreview(clip: clip, target: landing.target, gap: landing.gap, top: top, label: nil, movingClip: id)
        updateLanes()
    }

    override func keyDown(with event: NSEvent) {
        // Delete leaves a gap; ⇧Delete closes it. The Edit menu normally catches these first.
        if event.keyCode == 51 || event.keyCode == 117 {
            store.deleteSelection(closingGaps: event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale

        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            zoomAnchor = (time(atX: point.x), point.x)
            store.zoom(by: exp(Double(dy) * 0.01))
            return
        }
        if abs(dx) > abs(dy) {
            scrollX -= dx
        } else if maxScrollY > 0 {
            scrollY -= dy
        } else {
            scrollX -= dy
        }
        scrollX = scrollX.clamped(to: 0...maxScrollX)
        scrollY = scrollY.clamped(to: 0...maxScrollY)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoomAnchor = (time(atX: point.x), point.x)
        store.zoom(by: 1 + Double(event.magnification))
    }

    // MARK: Drop from the Media tab or Finder

    private func dropContent(_ info: NSDraggingInfo) -> DropContent? {
        let pasteboard = info.draggingPasteboard
        if let string = pasteboard.string(forType: .string) {
            if let id = TimelineDrag.assetID(from: string), let asset = project.asset(id) { return .asset(asset) }
            if let style = TimelineDrag.titleStyle(from: string) { return .title(style) }
            if let fill = TimelineDrag.fill(from: string) { return .fill(fill) }
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(MediaImporter.isSupported)
        return urls.isEmpty ? nil : .files(urls)
    }

    private func updateDropPreview(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let content = dropContent(info) else {
            dragPreview = nil
            updateLanes()
            return []
        }
        let point = convert(info.draggingLocation, from: nil)
        var clip: Clip
        var label: String?
        switch content {
        case let .asset(asset):
            clip = Clip(assetID: asset.id, start: .zero, sourceStart: .zero, duration: asset.kind == .image ? Clip.stillDuration : asset.duration)
        case let .title(style):
            clip = Clip(assetID: Clip.noAsset, start: .zero, sourceStart: .zero, duration: Clip.stillDuration)
            clip.title = style.title
        case let .fill(fill):
            clip = Clip(assetID: Clip.noAsset, start: .zero, sourceStart: .zero, duration: Clip.stillDuration)
            clip.fill = fill
        case let .files(urls):
            // Files from Finder haven't been read yet, so they show as a placeholder until they're imported.
            clip = Clip(assetID: UUID(), start: .zero, sourceStart: .zero, duration: Time(seconds: 4))
            label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        }
        clip.start = snapped(time(atX: point.x), duration: clip.duration, excluding: nil)
        let top = floatingTop(pointerY: point.y, grabY: defaultRowHeight / 2)
        let landing = landing(forCenter: top + scrollY + defaultRowHeight / 2, range: clip.range, movingClip: nil)
        dragPreview = DragPreview(clip: clip, target: landing.target, gap: landing.gap, top: top, label: label, movingClip: nil)
        updateLanes()
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragPreview = nil
        updateLanes()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dragPreview = nil
            refreshFromStore()
            updateLanes()
        }
        guard let dragPreview, let content = dropContent(sender) else { return false }
        switch content {
        case let .asset(asset):
            store.addClip(asset: asset.id, at: dragPreview.clip.start, target: dragPreview.target)
        case let .files(urls):
            store.importFiles(urls, placement: (dragPreview.clip.start, dragPreview.target))
        case let .title(style):
            store.addTitle(style, at: dragPreview.clip.start, target: dragPreview.target)
        case let .fill(fill):
            store.addBackground(fill, at: dragPreview.clip.start, target: dragPreview.target)
        }
        return true
    }
}

#if DEBUG
extension TimelineView {
    /// The right-click menu for the first selected clip, as text: one line per item, checked items marked,
    /// submenu items indented.
    func debugMenuLines() -> [String] {
        guard let window, let id = snapshot.selection.first,
              let row = rows.first(where: { project.tracks[$0.track].clips.contains { $0.id == id } }),
              let clip = project.clip(id) else { return [] }
        let rect = clipRect(clip, in: row.rect)
        let point = convert(CGPoint(x: max(rect.midX, 20), y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = menu(for: event) else { return [] }
        func lines(_ menu: NSMenu, depth: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                let line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "—" : (item.state == .on ? "✓ " : "") + item.title)
                return [line] + (item.submenu.map { lines($0, depth: depth + 1) } ?? [])
            }
        }
        return lines(menu, depth: 0)
    }

    /// The top track's height as drawn right now.
    var debugTopRowHeight: Double {
        Double(rows.first?.rect.height ?? 0)
    }

    enum DebugDrag: String {
        case clip, clipAbove, clipBelow, track, scrub, scrolled, trim, fade, overlap
    }

    /// Where the clip being dragged would land: on its own track, another track, or a new one, and how many crossfades it would make.
    var debugDragSummary: [String: Any] {
        guard let dragPreview else { return [:] }
        let ownTrack = dragPreview.movingClip.flatMap { project.location(ofClip: $0) }.map { project.tracks[$0.track].id }
        let target = switch dragPreview.target {
        case let .existing(id): id == ownTrack ? "same" : "other"
        case .new: "new"
        }
        return ["target": target, "crossfades": dragCrossfades?.crossfades.count ?? 0]
    }

    /// Starts a real drag with synthesized mouse events and stops before releasing, so a snapshot can show it.
    func debugBeginDrag(_ kind: DebugDrag) {
        let rows = rows
        let start: CGPoint
        let end: CGPoint
        switch kind {
        case .trim:
            // Grab the top clip's right edge and pull it 120 points left.
            guard let row = rows.first, let clip = project.tracks[row.track].clips.first else { return }
            let rect = clipRect(clip, in: row.rect)
            start = CGPoint(x: rect.maxX - 2, y: rect.midY)
            end = CGPoint(x: rect.maxX - 122, y: rect.midY)
        case .overlap:
            // Slide the second clip of a two-clip track back over the first by 3 seconds, drifting 14 points down
            // on the way. The drift is inside the tolerance, so the clip should stay on its track and crossfade.
            guard let row = rows.first(where: { project.tracks[$0.track].clips.count >= 2 }) else { return }
            let clips = project.tracks[row.track].clips.sorted { $0.start < $1.start }
            let rect = clipRect(clips[1], in: row.rect)
            start = CGPoint(x: rect.minX + 40, y: rect.midY)
            end = CGPoint(x: start.x + x(for: clips[0].end - Time(seconds: 3)) - rect.minX, y: rect.midY + 14)
        case .fade:
            // Grab the selected clip's fade-in handle and pull it 100 points right.
            guard let row = rows.first(where: { row in project.tracks[row.track].clips.contains { snapshot.selection.contains($0.id) } }),
                  let clip = project.tracks[row.track].clips.first(where: { snapshot.selection.contains($0.id) }) else { return }
            start = fadeHandle(.start, of: clip, in: clipRect(clip, in: row.rect))
            end = CGPoint(x: start.x + 100, y: start.y)
        case .scrolled:
            // Scroll part of a second past a tick, so a label and grid line sit just left of the view's edge.
            scrollX = CGFloat(3.3) * pixelsPerSecond
            needsDisplay = true
            return
        case .scrub:
            // Press on empty space below the tracks and drag sideways; the playhead should end at 10 seconds.
            let y = (rows.last?.rect.maxY ?? Layout.lanesTop) + 30
            start = CGPoint(x: x(for: Time(seconds: 2)), y: y)
            end = CGPoint(x: x(for: Time(seconds: 10)), y: y + 4)
        case .track:
            // Press on empty space in the topmost track that has clips, then drag it to the bottom.
            guard let row = rows.first(where: { !project.tracks[$0.track].clips.isEmpty }),
                  let last = rows.last,
                  let emptyX = stride(from: bounds.width - 8, to: 0, by: -12).first(where: { x in
                      !project.tracks[row.track].clips.contains { clipRect($0, in: row.rect).contains(CGPoint(x: x, y: row.rect.midY)) }
                  })
            else { return }
            start = CGPoint(x: emptyX, y: row.rect.midY)
            end = CGPoint(x: emptyX, y: last.rect.maxY - 8)
        case .clip, .clipAbove, .clipBelow:
            // Drag the top track's clip down between the next two tracks or below everything,
            // or the bottom track's clip up past the top.
            guard let first = rows.first, let last = rows.last else { return }
            let row = kind == .clipAbove ? last : first
            guard let clip = project.tracks[row.track].clips.first else { return }
            let rect = clipRect(clip, in: row.rect)
            start = CGPoint(x: rect.minX + 40, y: rect.midY)
            let endY = switch kind {
            case .clipAbove: CGFloat(14)
            case .clipBelow: last.rect.maxY + 40
            default: rows.count > 2 ? rows[2].rect.minY - Layout.rowSpacing / 2 : rect.midY + row.rect.height
            }
            end = CGPoint(x: rect.minX + 200, y: endY)
        }
        send(.leftMouseDown, at: start)
        send(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        send(.leftMouseDragged, at: end)
    }

    private func send(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window, let event = NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        type == .leftMouseDown ? mouseDown(with: event) : mouseDragged(with: event)
    }
}
#endif
