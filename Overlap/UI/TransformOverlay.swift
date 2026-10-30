import AppKit

/// Handles over the preview for a picture clicked there: drag inside to move it, a corner to scale it (from the
/// opposite corner, or from the middle with Option held), the top handle to rotate it, or in crop mode an edge
/// to crop it. Clicking a picture selects it and shows its handles;
/// clicking anywhere else in the preview, inside the canvas or around it, hides them. Double-clicking text types
/// into it right there. Selecting on the timeline
/// doesn't show them. The overlay covers the whole preview, so handles off the canvas can still be grabbed.
/// Drags show at once through the store's live preview and become one undo step on release.
final class TransformOverlay: NSView {
    struct State {
        var project: Project
        var selection: Set<UUID>
        var handlesClip: UUID?
        var time: Time
        var isCropping: Bool
        var editingTitle: UUID?
    }

    private enum Drag {
        case move(start: Visual, from: CGPoint)
        /// `anchor` is the corner opposite the one grabbed; `from` is where the pointer started.
        case scale(start: Visual, anchor: CGPoint, from: CGPoint)
        case rotate(start: Visual, center: CGPoint)
        case crop(start: Visual, edge: Edge)
    }

    private enum Edge: CaseIterable { case left, top, right, bottom }

    private let store: ProjectStore
    var state: State? {
        didSet {
            needsDisplay = true
            showTitleEditor()
        }
    }
    /// Where the canvas is drawn within the overlay.
    var canvasRect: CGRect = .zero {
        didSet {
            needsDisplay = true
            showTitleEditor()
        }
    }
    /// The editor for text being typed into on the canvas.
    private var titleEditor: TitleTextEditor?
    /// The strip along the bottom where the divider above the controls bar is grabbed; clicks there go to it.
    private static let dividerReach: CGFloat = 6
    private var drag: Drag?
    /// The settings being dragged to, drawn until the store catches up on release.
    private var draft: (id: UUID, visual: Visual)?
    /// The lines the dragged picture has snapped to, in canvas points, drawn while the drag lasts.
    private var guides: (vertical: [CGFloat], horizontal: [CGFloat]) = ([], [])
    /// Whether the drag is resting on a snap, so the trackpad taps once, as it catches.
    private var isSnapped = false
    private var titleSizes: [Title: CGSize] = [:]

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // MARK: Geometry

    private var canvas: CGSize {
        let canvas = state?.project.canvas ?? Project.defaultCanvas
        return CGSize(width: canvas.width, height: canvas.height)
    }

    /// The whole-picture frame shrinks everything by its padding when there's a background to show around it.
    private var frameScale: CGFloat {
        guard let project = state?.project, project.background != nil else { return 1 }
        return 1 - 2 * project.frame.padding
    }

    /// View points per canvas point.
    private var viewScale: CGFloat {
        canvasRect.width / canvas.width
    }

    /// Canvas points to view points, through the frame's inset.
    private func view(_ point: CGPoint) -> CGPoint {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return CGPoint(x: canvasRect.minX + (center.x + (point.x - center.x) * frameScale) * viewScale,
                       y: canvasRect.minY + (center.y + (point.y - center.y) * frameScale) * viewScale)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return CGPoint(x: center.x + ((point.x - canvasRect.minX) / viewScale - center.x) / frameScale,
                       y: center.y + ((point.y - canvasRect.minY) / viewScale - center.y) / frameScale)
    }

    /// The whole picture's size before its own scale: the source fitted to the canvas, or the drawn text.
    private func fullSize(of clip: Clip) -> CGSize? {
        if let title = clip.title {
            if titleSizes[title] == nil, let image = TitleRenderer.image(for: title, canvas: canvas) {
                titleSizes[title] = CGSize(width: image.width, height: image.height)
            }
            return titleSizes[title]
        }
        guard let asset = state?.project.asset(clip.assetID), let width = asset.pixelWidth, let height = asset.pixelHeight,
              width > 0, height > 0 else { return nil }
        let fit = min(canvas.width / CGFloat(width), canvas.height / CGFloat(height))
        return CGSize(width: CGFloat(width) * fit, height: CGFloat(height) * fit)
    }

    /// Where the whole picture's center sits, in canvas points. Moving, scaling and rotating turn around it.
    private func center(of visual: Visual) -> CGPoint {
        CGPoint(x: canvas.width / 2 + visual.x * canvas.width, y: canvas.height / 2 + visual.y * canvas.height)
    }

    /// The shown picture's corners in canvas points, clockwise from the top left. `whole` ignores the crop.
    private func corners(of clip: Clip, visual: Visual, whole: Bool = false) -> [CGPoint]? {
        guard let size = fullSize(of: clip) else { return nil }
        let crop = whole ? Crop() : visual.crop
        let scale = visual.scale
        let left = (-size.width / 2 + crop.left * size.width) * scale
        let right = (size.width / 2 - crop.right * size.width) * scale
        let top = (-size.height / 2 + crop.top * size.height) * scale
        let bottom = (size.height / 2 - crop.bottom * size.height) * scale
        let center = center(of: visual)
        return [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)].map {
            rotate(CGPoint(x: center.x + $0.x, y: center.y + $0.y), around: center, degrees: visual.rotation)
        }
    }

    private func rotate(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle), y: center.y + dx * sin(angle) + dy * cos(angle))
    }

    /// Pictures the handles can work on, on top first: placeable clips showing at the playhead on active tracks.
    private var visibleClips: [Clip] {
        guard let state else { return [] }
        let project = state.project
        return project.tracks.enumerated().reversed().flatMap { index, track -> [Clip] in
            guard project.isActive(track) else { return [] }
            return track.clips.filter { project.isPlaceable($0) && $0.start <= state.time && state.time < $0.end }.reversed()
        }
    }

    /// The picture showing handles: clicked in the preview, still the selection, and showing at the playhead.
    private var selectedClip: Clip? {
        guard let state, let id = state.handlesClip, state.selection == [id] else { return nil }
        return visibleClips.first { $0.id == id }
    }

    private func visual(of clip: Clip) -> Visual {
        draft?.id == clip.id ? draft!.visual : clip.visual
    }

    // MARK: Snapping

    /// How near, in canvas points, a picture has to come to a line to snap to it: six points on screen.
    private var snapDistance: CGFloat {
        6 / max(0.001, viewScale * frameScale)
    }

    /// The lines pictures snap to: the canvas's edges and middle, and the edges and middles of the other pictures
    /// showing now.
    private func snapLines(excluding id: UUID) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        var vertical = [0, canvas.width / 2, canvas.width]
        var horizontal = [0, canvas.height / 2, canvas.height]
        for clip in visibleClips where clip.id != id {
            guard let box = corners(of: clip, visual: clip.visual).map(boundingBox) else { continue }
            vertical += [box.minX, box.midX, box.maxX]
            horizontal += [box.minY, box.midY, box.maxY]
        }
        return (vertical, horizontal)
    }

    private func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The nearest line within reach of any of a picture's edges or its middle: how far to move, and the line.
    private func nearest(_ edges: [CGFloat], to lines: [CGFloat]) -> (shift: CGFloat, line: CGFloat)? {
        var best: (shift: CGFloat, line: CGFloat)?
        for edge in edges {
            for line in lines where abs(line - edge) <= snapDistance && abs(line - edge) < abs(best?.shift ?? .infinity) {
                best = (line - edge, line)
            }
        }
        return best
    }

    /// Moves a dragged picture onto the nearest line on each axis.
    private func snappedMove(_ visual: Visual, of clip: Clip) -> Visual {
        guard let box = corners(of: clip, visual: visual).map(boundingBox) else { return visual }
        let lines = snapLines(excluding: clip.id)
        var snapped = visual
        let across = nearest([box.minX, box.midX, box.maxX], to: lines.vertical)
        let down = nearest([box.minY, box.midY, box.maxY], to: lines.horizontal)
        if let across { snapped.x += across.shift / canvas.width }
        if let down { snapped.y += down.shift / canvas.height }
        guides = (across.map { [$0.line] } ?? [], down.map { [$0.line] } ?? [])
        return snapped
    }

    /// A picture scaled by `ratio` around a point that stays where it is.
    private func scaled(_ visual: Visual, by ratio: CGFloat, around pivot: CGPoint) -> Visual {
        var scaled = visual
        scaled.scale = (visual.scale * ratio).clamped(to: Visual.scaleRange)
        let applied = scaled.scale / visual.scale
        let center = center(of: visual)
        scaled.x = (pivot.x + (center.x - pivot.x) * applied - canvas.width / 2) / canvas.width
        scaled.y = (pivot.y + (center.y - pivot.y) * applied - canvas.height / 2) / canvas.height
        return scaled
    }

    /// Scales a dragged picture further so its nearest edge meets a line, when one is within reach. Scaling around
    /// a point grows each edge's distance from that point in proportion.
    private func snappedScale(_ visual: Visual, of clip: Clip, around pivot: CGPoint) -> Visual {
        guard let box = corners(of: clip, visual: visual).map(boundingBox) else { return visual }
        let lines = snapLines(excluding: clip.id)
        var best: (ratio: CGFloat, gap: CGFloat, vertical: CGFloat?, horizontal: CGFloat?)?
        for (edge, isVertical) in [(box.minX, true), (box.maxX, true), (box.minY, false), (box.maxY, false)] {
            let fixed = isVertical ? pivot.x : pivot.y
            // An edge through the fixed point doesn't move as the picture scales.
            guard abs(edge - fixed) > 1 else { continue }
            for line in isVertical ? lines.vertical : lines.horizontal where abs(line - edge) <= snapDistance {
                let ratio = (line - fixed) / (edge - fixed)
                guard ratio > 0, abs(line - edge) < (best?.gap ?? .infinity) else { continue }
                best = (ratio, abs(line - edge), isVertical ? line : nil, isVertical ? nil : line)
            }
        }
        guard let best else { return visual }
        guides = (best.vertical.map { [$0] } ?? [], best.horizontal.map { [$0] } ?? [])
        return scaled(visual, by: best.ratio, around: pivot)
    }

    // MARK: Typing on the canvas

    /// Lays the text editor over the text being typed into, at the size it's drawn, and takes it away once
    /// typing ends.
    private func showTitleEditor() {
        guard let id = state?.editingTitle, let clip = state?.project.clip(id), let title = clip.title, canvasRect.width > 0 else {
            if let editor = titleEditor {
                titleEditor = nil
                editor.removeFromSuperview()
            }
            return
        }
        // View points per canvas pixel at the text's own scale, matching how the title is drawn.
        let scale = viewScale * frameScale * clip.visual.scale
        let size = CGFloat(title.size) * canvas.height / 1080 * scale
        let inset = title.backdrop == nil ? CGSize(width: 2 * scale, height: 2 * scale) : CGSize(width: size * 0.45, height: size * 0.3)
        let isNew = titleEditor == nil
        let editor = titleEditor ?? TitleTextEditor(text: title.text,
                                                    onCommit: { [weak self] text in self?.store.endEditingTitle(text: text) },
                                                    onCancel: { [weak self] in self?.store.endEditingTitle(text: nil) })
        editor.show(title, font: TitleRenderer.font(for: title, size: size), inset: inset,
                    maxWidth: canvas.width * 0.9 * scale, center: view(center(of: clip.visual)))
        guard isNew else { return }
        addSubview(editor)
        titleEditor = editor
        needsDisplay = true
        // Focus once the view update that brought the editor in is done, with the text selected to type over.
        DispatchQueue.main.async { [weak editor] in
            guard let editor, editor.window != nil else { return }
            editor.window?.makeFirstResponder(editor.textView)
            editor.textView.selectAll(nil)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawGuides()
        // The editor stands in for the handles while text is typed.
        guard titleEditor == nil, let clip = selectedClip else { return }
        let visual = visual(of: clip)
        guard let points = corners(of: clip, visual: visual)?.map(view) else { return }

        if state?.isCropping == true, clip.title == nil, let full = corners(of: clip, visual: visual, whole: true)?.map(view) {
            outline(full, dashed: true)
            outline(points, dashed: false)
            for edge in Edge.allCases {
                bar(at: edgeMidpoint(points, edge), vertical: edge == .left || edge == .right, rotation: visual.rotation)
            }
            return
        }

        outline(points, dashed: false)
        let top = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        let rotation = rotationHandle(points)
        let stem = NSBezierPath()
        stem.move(to: top)
        stem.line(to: rotation)
        stem.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        stem.stroke()
        dot(at: rotation)
        for corner in points {
            square(at: corner)
        }
    }

    /// Thin accent lines across the canvas where the dragged picture snapped.
    private func drawGuides() {
        guard drag != nil else { return }
        let path = NSBezierPath()
        for x in guides.vertical {
            path.move(to: view(CGPoint(x: x, y: 0)))
            path.line(to: view(CGPoint(x: x, y: canvas.height)))
        }
        for y in guides.horizontal {
            path.move(to: view(CGPoint(x: 0, y: y)))
            path.line(to: view(CGPoint(x: canvas.width, y: y)))
        }
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func rotationHandle(_ points: [CGPoint]) -> CGPoint {
        let top = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        let bottom = CGPoint(x: (points[2].x + points[3].x) / 2, y: (points[2].y + points[3].y) / 2)
        let length = max(1, hypot(top.x - bottom.x, top.y - bottom.y))
        return CGPoint(x: top.x + (top.x - bottom.x) / length * 22, y: top.y + (top.y - bottom.y) / length * 22)
    }

    private func edgeMidpoint(_ points: [CGPoint], _ edge: Edge) -> CGPoint {
        let (a, b) = switch edge {
        case .top: (points[0], points[1])
        case .right: (points[1], points[2])
        case .bottom: (points[2], points[3])
        case .left: (points[3], points[0])
        }
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func outline(_ points: [CGPoint], dashed: Bool) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        // A dark line under a white one reads over any picture.
        path.lineWidth = 3
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        path.lineWidth = 1.25
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        NSColor.white.withAlphaComponent(dashed ? 0.6 : 0.95).setStroke()
        path.stroke()
    }

    private func square(at point: CGPoint) {
        let rect = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor.white.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func dot(at point: CGPoint) {
        let path = NSBezierPath(ovalIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
        NSColor.white.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    private func bar(at point: CGPoint, vertical: Bool, rotation: Double) {
        let size = vertical ? CGSize(width: 5, height: 18) : CGSize(width: 18, height: 5)
        let path = NSBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                                xRadius: 2.5, yRadius: 2.5)
        var transform = AffineTransform(translationByX: point.x, byY: point.y)
        transform.rotate(byDegrees: rotation)
        path.transform(using: transform)
        NSColor.white.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    // MARK: Mouse

    /// Clicks belong to the overlay over a picture, and anywhere in the preview while handles show, to hide them.
    /// Elsewhere they fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.y < bounds.maxY - Self.dividerReach else { return nil }
        // While typing, the editor takes clicks on itself; anywhere else in the preview applies the text.
        if let titleEditor {
            return titleEditor.frame.contains(local) ? super.hitTest(point) : self
        }
        return selectedClip != nil || target(at: local) != nil ? self : nil
    }

    private func target(at point: CGPoint) -> (clip: Clip, drag: Drag)? {
        if let clip = selectedClip, let found = handle(of: clip, at: point) {
            return (clip, found)
        }
        for clip in visibleClips {
            guard let points = corners(of: clip, visual: clip.visual)?.map(view), contains(points, point) else { continue }
            return (clip, .move(start: clip.visual, from: canvasPoint(point)))
        }
        return nil
    }

    private func handle(of clip: Clip, at point: CGPoint) -> Drag? {
        let visual = visual(of: clip)
        guard let points = corners(of: clip, visual: visual)?.map(view) else { return nil }
        let center = center(of: visual)
        let near = { (handle: CGPoint) in hypot(handle.x - point.x, handle.y - point.y) <= 8 }

        if state?.isCropping == true, clip.title == nil {
            if let edge = Edge.allCases.first(where: { near(edgeMidpoint(points, $0)) }) {
                return .crop(start: visual, edge: edge)
            }
        } else {
            if near(rotationHandle(points)) { return .rotate(start: visual, center: center) }
            if let corner = points.firstIndex(where: near), let canvasCorners = corners(of: clip, visual: visual) {
                return .scale(start: visual, anchor: canvasCorners[(corner + 2) % 4], from: canvasPoint(point))
            }
        }
        return contains(points, point) ? .move(start: visual, from: canvasPoint(point)) : nil
    }

    private func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        let path = NSBezierPath()
        path.move(to: polygon[0])
        polygon.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path.contains(point)
    }

    /// A press here works the handles; it never moves the window. Views that aren't opaque say otherwise by default,
    /// and the window's own drag gesture then claims presses made with a modifier held, such as Option.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // While typing, the editor applies the text on its own as this click comes in.
        guard titleEditor == nil else { return }
        // Double-clicking text types into it on the canvas.
        if event.clickCount == 2, let (clip, _) = target(at: point), clip.title != nil {
            store.beginEditingTitle(clip.id)
            return
        }
        guard let (clip, found) = target(at: point) else {
            store.handlesClip = nil
            store.isCropping = false
            return
        }
        if state?.selection != [clip.id] { store.select([clip.id]) }
        store.handlesClip = clip.id
        drag = found
        draft = (clip.id, clip.visual)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let id = draft?.id, let clip = state?.project.clip(id) else { return }
        let point = canvasPoint(convert(event.locationInWindow, from: nil))
        // Snapping follows the Snapping setting, like the timeline; holding ⌘ skips it for the moment.
        let snaps = store.isSnappingEnabled && !event.modifierFlags.contains(.command)
        guides = ([], [])
        var rotationCaught = false
        var visual: Visual
        switch drag {
        case let .move(start, from):
            visual = start
            visual.x = start.x + (point.x - from.x) / canvas.width
            visual.y = start.y + (point.y - from.y) / canvas.height
            if snaps { visual = snappedMove(visual, of: clip) }
        case let .scale(start, anchor, from):
            // The opposite corner stays put, as in other design apps; Option scales around the middle instead.
            let pivot = event.modifierFlags.contains(.option) ? center(of: start) : anchor
            let ratio = hypot(point.x - pivot.x, point.y - pivot.y) / max(1, hypot(from.x - pivot.x, from.y - pivot.y))
            visual = scaled(start, by: ratio, around: pivot)
            if snaps { visual = snappedScale(visual, of: clip, around: pivot) }
        case let .rotate(start, center):
            visual = start
            var degrees = atan2(point.y - center.y, point.x - center.x) * 180 / .pi + 90
            if degrees > 180 { degrees -= 360 }
            if event.modifierFlags.contains(.shift) {
                degrees = (degrees / 15).rounded() * 15
            } else if snaps, abs(degrees - (degrees / 90).rounded() * 90) < 3 {
                // Upright and quarter turns are easy to land on.
                degrees = (degrees / 90).rounded() * 90
                rotationCaught = true
            }
            visual.rotation = degrees
        case let .crop(start, edge):
            visual = start
            visual.crop = cropped(start, edge: edge, to: point, clip: clip)
        }
        // A tap on a Force Touch trackpad as the picture catches on a line or a quarter turn, as sliders do.
        let snappedNow = !guides.vertical.isEmpty || !guides.horizontal.isEmpty || rotationCaught
        if snappedNow, !isSnapped {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        isSnapped = snappedNow
        draft = (id, visual)
        store.previewVisual { $0 = visual }
        needsDisplay = true
    }

    /// Moves one crop edge to the pointer, measured along the picture's own axes as a share of the whole picture.
    private func cropped(_ start: Visual, edge: Edge, to point: CGPoint, clip: Clip) -> Crop {
        guard let size = fullSize(of: clip) else { return start.crop }
        let center = center(of: start)
        let local = rotate(point, around: center, degrees: -start.rotation)
        let across = ((local.x - center.x) / start.scale + size.width / 2) / size.width
        let down = ((local.y - center.y) / start.scale + size.height / 2) / size.height
        var crop = start.crop
        switch edge {
        case .left: crop.left = across.clamped(to: 0...max(0, 0.95 - crop.right))
        case .right: crop.right = (1 - across).clamped(to: 0...max(0, 0.95 - crop.left))
        case .top: crop.top = down.clamped(to: 0...max(0, 0.95 - crop.bottom))
        case .bottom: crop.bottom = (1 - down).clamped(to: 0...max(0, 0.95 - crop.top))
        }
        return crop
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            draft = nil
            guides = ([], [])
            isSnapped = false
            needsDisplay = true
        }
        guard let drag, let draft, draft.visual != state?.project.clip(draft.id)?.visual else { return }
        let name = switch drag {
        case .move: "Move"
        case .scale: "Scale"
        case .rotate: "Rotate"
        case .crop: "Crop"
        }
        let visual = draft.visual
        store.setVisual(name) { $0 = visual }
    }
}

#if DEBUG
extension TransformOverlay {
    /// Clicks the selected picture in the preview and drags it by `offset` view points with synthesized mouse
    /// events, pausing between moves: from its center to move it, or from its bottom-right corner to scale it.
    /// Returns how many frames the compositor drew after each move, or nil when nothing is selected.
    func debugDrag(fromCorner: Bool, by offset: CGSize) async -> [Int]? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window,
              let points = corners(of: clip, visual: clip.visual)?.map(view) else { return nil }
        let center = view(center(of: clip.visual))
        let send = { (type: NSEvent.EventType, point: CGPoint) in
            guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: self.mouseDown(with: event)
            case .leftMouseDragged: self.mouseDragged(with: event)
            default: self.mouseUp(with: event)
            }
        }
        // A click first, to show the handles, as a person would.
        send(.leftMouseDown, center)
        send(.leftMouseUp, center)
        try? await Task.sleep(for: .milliseconds(200))

        let start = fromCorner ? points[2] : center
        var drawn: [Int] = []
        send(.leftMouseDown, start)
        for step in 1...4 {
            let before = Compositor.renders.load(ordering: .relaxed)
            let fraction = CGFloat(step) / 4
            send(.leftMouseDragged, CGPoint(x: start.x + offset.width * fraction, y: start.y + offset.height * fraction))
            try? await Task.sleep(for: .milliseconds(150))
            drawn.append(Compositor.renders.load(ordering: .relaxed) - before)
        }
        send(.leftMouseUp, CGPoint(x: start.x + offset.width, y: start.y + offset.height))
        return drawn
    }

    /// Double-clicks the first text showing, types `text` into it, calls `midway` while it's being edited, then
    /// clicks outside the canvas to apply it, or presses Esc to cancel. Reports what happened at each stage.
    func debugEditTitle(typing text: String, cancel: Bool, midway: () -> Void) async -> [String: Any] {
        guard let clip = visibleClips.first(where: { $0.title != nil }), let window else { return [:] }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let post = { (type: NSEvent.EventType, point: CGPoint, clicks: Int) in
            guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        let middle = view(center(of: clip.visual))
        for clicks in [1, 2] {
            post(.leftMouseDown, middle, clicks)
            try? await Task.sleep(for: .milliseconds(40))
            post(.leftMouseUp, middle, clicks)
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(400))
        var report: [String: Any] = [
            "editing": store.editingTitleClip == clip.id,
            "editorShown": titleEditor != nil,
            "editorFocused": titleEditor.map { window.firstResponder === $0.textView } ?? false,
            "renderedTextHidden": store.playback.plan?.current.hiddenClip == clip.id,
        ]
        titleEditor?.textView.insertText(text, replacementRange: titleEditor?.textView.selectedRange() ?? NSRange())
        try? await Task.sleep(for: .milliseconds(200))
        midway()
        if cancel {
            titleEditor?.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        } else {
            post(.leftMouseDown, CGPoint(x: canvasRect.minX / 2, y: bounds.midY), 1)
            try? await Task.sleep(for: .milliseconds(40))
            post(.leftMouseUp, CGPoint(x: canvasRect.minX / 2, y: bounds.midY), 1)
        }
        try? await Task.sleep(for: .milliseconds(500))
        report["textAfter"] = store.project.clip(clip.id)?.title?.text ?? ""
        report["editingAfter"] = store.editingTitleClip != nil
        report["editorAfter"] = titleEditor != nil
        report["renderedTextHiddenAfter"] = store.playback.plan?.current.hiddenClip != nil
        report["undoName"] = store.undoManager?.undoActionName ?? ""
        return report
    }

    /// Clicks the selected picture to show its handles, then clicks the preview's surround, outside the canvas.
    /// Reports whether the handles showed after each click.
    func debugClickOutsideCanvas() async -> (afterPicture: Bool, afterOutside: Bool)? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window else { return nil }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let click = { (point: CGPoint) async in
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                else { continue }
                NSApplication.shared.postEvent(event, atStart: false)
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await click(view(center(of: clip.visual)))
        let afterPicture = store.handlesClip == id
        await click(CGPoint(x: canvasRect.minX / 2, y: bounds.midY))
        return (afterPicture, store.handlesClip == id)
    }

    /// Clicks the selected picture and drags its bottom-right corner 120 points right and 60 down, with ⌘ held so
    /// snapping stays out of it, and Option too when asked. Reports how far, in canvas points, the top-left corner
    /// and the middle moved, and the new scale.
    func debugCornerScale(fromMiddle: Bool) async -> (cornerMoved: Double, middleMoved: Double, scale: Double)? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window,
              let before = corners(of: clip, visual: clip.visual) else { return nil }
        let middleBefore = center(of: clip.visual)
        let flags: NSEvent.ModifierFlags = fromMiddle ? [.option] : [.command]
        // Posted to the app with real timestamps, as hardware events arrive, so the window and its gestures see
        // them as they would a person's drag.
        let send = { (type: NSEvent.EventType, point: CGPoint) in
            guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil), modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        // Clicks reach a window's views only once it's the key window, as it is for a person using it.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        try? await Task.sleep(for: .milliseconds(300))
        let middle = view(middleBefore)
        send(.leftMouseDown, middle)
        try? await Task.sleep(for: .milliseconds(60))
        send(.leftMouseUp, middle)
        // The handles show once the store's change reaches the overlay.
        try? await Task.sleep(for: .milliseconds(300))
        let grab = view(before[2])
        let end = CGPoint(x: grab.x + 120, y: grab.y + 60)
        send(.leftMouseDown, grab)
        try? await Task.sleep(for: .milliseconds(40))
        for step in 1...12 {
            let fraction = CGFloat(step) / 12
            send(.leftMouseDragged, CGPoint(x: grab.x + 120 * fraction, y: grab.y + 60 * fraction))
            try? await Task.sleep(for: .milliseconds(16))
        }
        send(.leftMouseUp, end)
        try? await Task.sleep(for: .milliseconds(400))
        guard let moved = state?.project.clip(id), let after = corners(of: moved, visual: moved.visual) else { return nil }
        let middleAfter = center(of: moved.visual)
        return (Double(hypot(after[0].x - before[0].x, after[0].y - before[0].y)),
                Double(hypot(middleAfter.x - middleBefore.x, middleAfter.y - middleBefore.y)), moved.visual.scale)
    }

    /// Clicks the selected picture and drags it so its left edge stops three screen points short of the canvas's
    /// middle line, with ⌘ held or not. Reports where the edge landed, in canvas points from the middle line, and
    /// how many guides showed just before release.
    func debugSnapToMiddle(holdingCommand: Bool) async -> (gap: Double, guides: Int)? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window,
              let box = corners(of: clip, visual: clip.visual).map(boundingBox) else { return nil }
        let start = view(center(of: clip.visual))
        let target = (canvas.width / 2 - box.minX) * viewScale * frameScale - 3
        let send = { (type: NSEvent.EventType, point: CGPoint) in
            guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil),
                                                 modifierFlags: holdingCommand ? .command : [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: self.mouseDown(with: event)
            case .leftMouseDragged: self.mouseDragged(with: event)
            default: self.mouseUp(with: event)
            }
        }
        send(.leftMouseDown, start)
        send(.leftMouseUp, start)
        let end = CGPoint(x: start.x + target, y: start.y)
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x + target / 2, y: start.y))
        send(.leftMouseDragged, end)
        let shown = guides.vertical.count + guides.horizontal.count
        send(.leftMouseUp, end)
        try? await Task.sleep(for: .milliseconds(300))
        guard let moved = state?.project.clip(id), let after = corners(of: moved, visual: moved.visual).map(boundingBox) else { return nil }
        return (Double(after.minX - canvas.width / 2), shown)
    }
}
#endif
