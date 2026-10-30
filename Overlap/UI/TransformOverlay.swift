import AppKit

/// Handles over the preview for the selected picture: drag inside to move it, a corner to scale it, the top
/// handle to rotate it, or in crop mode an edge to crop it. Clicking a picture in the preview selects it.
/// Drags show at once through the store's live preview and become one undo step on release.
final class TransformOverlay: NSView {
    struct State {
        var project: Project
        var selection: Set<UUID>
        var time: Time
        var isCropping: Bool
    }

    private enum Drag {
        case move(start: Visual, from: CGPoint)
        case scale(start: Visual, center: CGPoint, distance: CGFloat)
        case rotate(start: Visual, center: CGPoint)
        case crop(start: Visual, edge: Edge)
    }

    private enum Edge: CaseIterable { case left, top, right, bottom }

    private let store: ProjectStore
    var state: State? {
        didSet { needsDisplay = true }
    }
    private var drag: Drag?
    /// The settings being dragged to, drawn until the store catches up on release.
    private var draft: (id: UUID, visual: Visual)?
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

    /// Canvas points to view points, through the frame's inset.
    private func view(_ point: CGPoint) -> CGPoint {
        let k = bounds.width / canvas.width
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return CGPoint(x: (center.x + (point.x - center.x) * frameScale) * k, y: (center.y + (point.y - center.y) * frameScale) * k)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        let k = bounds.width / canvas.width
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return CGPoint(x: center.x + (point.x / k - center.x) / frameScale, y: center.y + (point.y / k - center.y) / frameScale)
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

    private var selectedClip: Clip? {
        guard let state, state.selection.count == 1 else { return nil }
        return visibleClips.first { state.selection.contains($0.id) }
    }

    private func visual(of clip: Clip) -> Visual {
        draft?.id == clip.id ? draft!.visual : clip.visual
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let clip = selectedClip else { return }
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

    /// Clicks only belong to the overlay over a picture; elsewhere they fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return target(at: local) != nil ? self : nil
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
            if points.contains(where: near) {
                let at = canvasPoint(point)
                return .scale(start: visual, center: center, distance: max(1, hypot(at.x - center.x, at.y - center.y)))
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (clip, found) = target(at: point) else { return }
        if state?.selection != [clip.id] { store.select([clip.id]) }
        drag = found
        draft = (clip.id, clip.visual)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let id = draft?.id, let clip = state?.project.clip(id) else { return }
        let point = canvasPoint(convert(event.locationInWindow, from: nil))
        var visual: Visual
        switch drag {
        case let .move(start, from):
            visual = start
            visual.x = start.x + (point.x - from.x) / canvas.width
            visual.y = start.y + (point.y - from.y) / canvas.height
            // Centered pictures snap to the canvas's middle lines.
            let snap = 6 / (bounds.width / canvas.width) / canvas.width
            if abs(visual.x) < snap { visual.x = 0 }
            if abs(visual.y) < snap * canvas.width / canvas.height { visual.y = 0 }
        case let .scale(start, center, distance):
            visual = start
            visual.scale = (start.scale * hypot(point.x - center.x, point.y - center.y) / distance).clamped(to: Visual.scaleRange)
        case let .rotate(start, center):
            visual = start
            var degrees = atan2(point.y - center.y, point.x - center.x) * 180 / .pi + 90
            if event.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            if degrees > 180 { degrees -= 360 }
            visual.rotation = degrees
        case let .crop(start, edge):
            visual = start
            visual.crop = cropped(start, edge: edge, to: point, clip: clip)
        }
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
    /// Drags the selected picture by `offset` view points with synthesized mouse events: from its center to move
    /// it, or from its bottom-right corner to scale it. Returns false when nothing is selected.
    func debugDrag(fromCorner: Bool, by offset: CGSize) -> Bool {
        guard let clip = selectedClip, let window, let points = corners(of: clip, visual: clip.visual)?.map(view) else { return false }
        let start = fromCorner ? points[2] : view(center(of: clip.visual))
        let end = CGPoint(x: start.x + offset.width, y: start.y + offset.height)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, middle), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            guard let event = NSEvent.mouseEvent(with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            switch type {
            case .leftMouseDown: mouseDown(with: event)
            case .leftMouseDragged: mouseDragged(with: event)
            default: mouseUp(with: event)
            }
        }
        return true
    }
}
#endif
