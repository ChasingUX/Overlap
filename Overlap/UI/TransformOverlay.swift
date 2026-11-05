import AppKit
import AVFoundation
import CoreImage

/// Handles over the preview for a picture clicked there: drag inside to move it, a corner to scale it (from the
/// opposite corner, or from the middle with Option held), the top handle to rotate it, or in crop mode an edge
/// to crop it. Clicking a picture selects it and shows its handles;
/// clicking anywhere else in the preview, inside the canvas or around it, hides them. Double-clicking text types
/// into it right there. Selecting on the timeline
/// doesn't show them. The overlay covers the whole preview, so handles off the canvas can still be grabbed.
/// Drags show at once through the store's live preview and become one undo step on release.
/// Holding ⌘ over the canvas's edge resizes the canvas instead (with ⌥, both sides at once), keeping everything on it
/// where it is: while dragging, what falls outside shows faintly.
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

    /// The canvas being resized from one edge or corner: which way each side moves (−1 the left or top edge, 1 the
    /// right or bottom, 0 neither), where the pointer started, the canvas being dragged to in the starting canvas's
    /// pixels, and the picture drawn for it, across the old canvas and the new.
    private struct CanvasResize {
        var horizontal: Int
        var vertical: Int
        var from: CGPoint
        var frame: CGRect
        var frames: [CMPersistentTrackID: CIImage] = [:]
        var ghost: CGImage?
        /// Picture edges the dragged canvas edge has caught on, in the starting canvas's pixels.
        var guides: (vertical: [CGFloat], horizontal: [CGFloat]) = ([], [])
    }

    private var canvasResize: CanvasResize?
    #if DEBUG
    /// While a debug check records a canvas resize: how often it was drawn, and how long each ghost took, in ms.
    var debugResizeDraws = 0
    var debugGhostTimes: [Double] = []
    #endif
    private var flagsMonitor: Any?
    private var showsResizeCursor = false

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

    /// View points per canvas point.
    private var viewScale: CGFloat {
        canvasRect.width / canvas.width
    }

    /// Canvas points to view points.
    private func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: canvasRect.minX + point.x * viewScale, y: canvasRect.minY + point.y * viewScale)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - canvasRect.minX) / viewScale, y: (point.y - canvasRect.minY) / viewScale)
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
        6 / max(0.001, viewScale)
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
        showGuides(for: snapped, of: clip, lines: lines)
        return snapped
    }

    /// Lights every line the picture's edges and middle lie on once snapped. It can meet several at once: one as
    /// tall as the canvas meets its top and its bottom together.
    private func showGuides(for visual: Visual, of clip: Clip, lines: (vertical: [CGFloat], horizontal: [CGFloat])) {
        guard let box = corners(of: clip, visual: visual).map(boundingBox) else {
            guides = ([], [])
            return
        }
        // Within half a point on screen counts as on the line.
        let reach = 0.5 / max(0.001, viewScale)
        func met(_ low: CGFloat, _ middle: CGFloat, _ high: CGFloat, _ lines: [CGFloat]) -> [CGFloat] {
            let meets = { (edge: CGFloat) in lines.filter { abs($0 - edge) <= reach } }
            // With both edges on lines, the middle line says nothing more.
            let ends = meets(low) + meets(high)
            let mid = !meets(low).isEmpty && !meets(high).isEmpty ? [] : meets(middle)
            return Array(Set(ends + mid)).sorted()
        }
        guides = (met(box.minX, box.midX, box.maxX, lines.vertical), met(box.minY, box.midY, box.maxY, lines.horizontal))
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
        let snapped = scaled(visual, by: best.ratio, around: pivot)
        showGuides(for: snapped, of: clip, lines: lines)
        return snapped
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
        let scale = viewScale * clip.visual.scale
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
        if let canvasResize { return drawCanvasResize(canvasResize) }
        // The editor stands in for the handles while text is typed.
        guard titleEditor == nil, let clip = selectedClip else { return drawGuides() }
        let visual = visual(of: clip)
        guard let points = corners(of: clip, visual: visual)?.map(view) else { return drawGuides() }

        if state?.isCropping == true, clip.title == nil, let full = corners(of: clip, visual: visual, whole: true)?.map(view) {
            outline(full, dashed: true)
            outline(points, dashed: false)
            for edge in Edge.allCases {
                bar(at: edgeMidpoint(points, edge), vertical: edge == .left || edge == .right, rotation: visual.rotation)
            }
            return
        }

        outline(points, dashed: false)
        // Over the outline, so a guide along the picture's own edge shows, and under the handles.
        drawGuides()
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
        // ⌘ as the click being placed has it, which is the keyboard's when it's a person's.
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command), canvasEdges(at: local) != nil { return self }
        return selectedClip != nil || target(at: local) != nil ? self : nil
    }

    // MARK: Resizing the canvas

    /// The canvas edges within reach of a point: −1 for the left or top, 1 for the right or bottom, 0 for neither.
    private func canvasEdges(at point: CGPoint) -> (horizontal: Int, vertical: Int)? {
        let reach: CGFloat = 6
        guard canvasRect.width > 0, canvasRect.insetBy(dx: -reach, dy: -reach).contains(point) else { return nil }
        let horizontal = abs(point.x - canvasRect.minX) <= reach ? -1 : abs(point.x - canvasRect.maxX) <= reach ? 1 : 0
        let vertical = abs(point.y - canvasRect.minY) <= reach ? -1 : abs(point.y - canvasRect.maxY) <= reach ? 1 : 0
        return horizontal == 0 && vertical == 0 ? nil : (horizontal, vertical)
    }

    private func resizeCursor(_ edges: (horizontal: Int, vertical: Int)) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch (edges.horizontal, edges.vertical) {
        case (-1, -1): .topLeft
        case (1, -1): .topRight
        case (-1, 1): .bottomLeft
        case (1, 1): .bottomRight
        case (-1, _): .left
        case (1, _): .right
        case (_, -1): .top
        default: .bottom
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        // Pressing or letting go of ⌘ over an edge changes the pointer without moving it.
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, let window = self.window {
                self.updateResizeCursor(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: event.modifierFlags)
            }
            return event
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if canvasResize == nil { updateResizeCursor(at: CGPoint(x: -1000, y: -1000), flags: []) }
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    private func updateResizeCursor(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard canvasResize == nil else { return }
        if flags.contains(.command), titleEditor == nil, let edges = canvasEdges(at: point) {
            resizeCursor(edges).set()
            showsResizeCursor = true
        } else if showsResizeCursor {
            NSCursor.arrow.set()
            showsResizeCursor = false
        }
    }

    private func beginCanvasResize(_ edges: (horizontal: Int, vertical: Int), at point: CGPoint) {
        canvasResize = CanvasResize(horizontal: edges.horizontal, vertical: edges.vertical, from: point,
                                    frame: CGRect(origin: .zero, size: canvas))
        resizeCursor(edges).set()
        needsDisplay = true
        // The player only draws inside the canvas, so the picture across the old canvas and the new is drawn here,
        // once the video frames showing now are read from their files.
        Task { [weak self] in
            guard let self else { return }
            let frames = await videoFrames()
            guard canvasResize != nil else { return }
            canvasResize?.frames = frames
            drawGhost()
        }
    }

    private func dragCanvas(to point: CGPoint, bothSides: Bool) {
        guard var resize = canvasResize, viewScale > 0 else { return }
        let dx = (point.x - resize.from.x) / viewScale
        let dy = (point.y - resize.from.y) / viewScale
        var minX: CGFloat = 0, maxX = canvas.width, minY: CGFloat = 0, maxY = canvas.height
        switch resize.horizontal {
        case -1: minX += dx; if bothSides { maxX -= dx }
        case 1: maxX += dx; if bothSides { minX -= dx }
        default: break
        }
        switch resize.vertical {
        case -1: minY += dy; if bothSides { maxY -= dy }
        case 1: maxY += dy; if bothSides { minY -= dy }
        default: break
        }
        // A dragged edge catches on the edges of the pictures showing now, and a guide lights there. With ⌥ the
        // opposite edge mirrors it.
        var guides: (vertical: [CGFloat], horizontal: [CGFloat]) = ([], [])
        if store.isSnappingEnabled {
            let edges = pictureEdges()
            let reach = 6 / viewScale
            let caught = { (value: CGFloat, lines: [CGFloat]) in
                lines.filter { abs($0 - value) <= reach }.min { abs($0 - value) < abs($1 - value) }
            }
            if resize.horizontal == -1, let line = caught(minX, edges.vertical) {
                minX = line
                if bothSides { maxX = canvas.width - line }
                guides.vertical.append(line)
            } else if resize.horizontal == 1, let line = caught(maxX, edges.vertical) {
                maxX = line
                if bothSides { minX = canvas.width - line }
                guides.vertical.append(line)
            }
            if resize.vertical == -1, let line = caught(minY, edges.horizontal) {
                minY = line
                if bothSides { maxY = canvas.height - line }
                guides.horizontal.append(line)
            } else if resize.vertical == 1, let line = caught(maxY, edges.horizontal) {
                maxY = line
                if bothSides { minY = canvas.height - line }
                guides.horizontal.append(line)
            }
        }
        // A tap on a Force Touch trackpad as it catches, as when dragging a picture.
        let wasCaught = !resize.guides.vertical.isEmpty || !resize.guides.horizontal.isEmpty
        if !guides.vertical.isEmpty || !guides.horizontal.isEmpty, !wasCaught {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        resize.guides = guides
        // Never thinner than a sliver: the edge being dragged stops, or both stop around the middle.
        let smallest: CGFloat = 64
        if maxX - minX < smallest {
            if bothSides { (minX, maxX) = ((minX + maxX - smallest) / 2, (minX + maxX + smallest) / 2) }
            else if resize.horizontal == -1 { minX = maxX - smallest } else { maxX = minX + smallest }
        }
        if maxY - minY < smallest {
            if bothSides { (minY, maxY) = ((minY + maxY - smallest) / 2, (minY + maxY + smallest) / 2) }
            else if resize.vertical == -1 { minY = maxY - smallest } else { maxY = minY + smallest }
        }
        resize.frame = CGRect(x: minX, y: minY, width: min(maxX - minX, 8192), height: min(maxY - minY, 8192))
        canvasResize = resize
        // The new edge follows the pointer whether or not there's a picture to draw.
        needsDisplay = true
        drawGhost()
    }

    /// The left and right, and top and bottom, edges of the pictures showing now, in canvas pixels.
    private func pictureEdges() -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        var vertical: [CGFloat] = []
        var horizontal: [CGFloat] = []
        for clip in visibleClips {
            guard let box = corners(of: clip, visual: clip.visual).map(boundingBox) else { continue }
            vertical += [box.minX, box.maxX]
            horizontal += [box.minY, box.maxY]
        }
        return (vertical, horizontal)
    }

    /// The picture at the playhead across the old canvas and the new one, everything placed as it will be: what
    /// the new canvas keeps draws as it is, and the rest faintly.
    private func drawGhost() {
        guard var resize = canvasResize, let project = state?.project else { return }
        let union = resize.frame.union(CGRect(origin: .zero, size: canvas))
        // With nothing to play there's no plan yet: just the background, or the bare canvas, as the stage shows it.
        guard let plan = store.playback.plan?.current else {
            let stage = RenderPlan(canvas: union.size, background: project.background.flatMap(store.resolve),
                                   layers: [], hiddenClip: nil)
            resize.ghost = Compositor.stage(for: stage)
            canvasResize = resize
            needsDisplay = true
            return
        }
        var ghost = plan
        ghost.canvas = union.size
        ghost.layers = plan.layers.map { layer in
            var layer = layer
            if !layer.isBackground, let clip = project.clip(layer.clipID) {
                layer.visual = project.visual(of: clip, keptFrom: canvas, onto: union)
            }
            return layer
        }
        #if DEBUG
        let started = Date()
        #endif
        resize.ghost = Compositor.still(of: ghost, at: store.playback.currentTime.seconds, frames: resize.frames,
                                        scale: viewScale * (window?.backingScaleFactor ?? 2))
        #if DEBUG
        debugGhostTimes.append((Date().timeIntervalSince(started) * 1000).rounded())
        #endif
        canvasResize = resize
        needsDisplay = true
    }

    /// The video frames showing now, read from their files, by composition track.
    private func videoFrames() async -> [CMPersistentTrackID: CIImage] {
        guard let plan = store.playback.plan?.current, let project = state?.project else { return [:] }
        let time = store.playback.currentTime.seconds
        var frames: [CMPersistentTrackID: CIImage] = [:]
        for layer in plan.layers where layer.isActive(at: time) {
            guard case let .video(trackID, _) = layer.source, let clip = project.clip(layer.clipID),
                  let asset = project.asset(clip.assetID) else { continue }
            let source = clip.sourceStart.seconds + (time - clip.start.seconds) * clip.speed
            if let image = await Self.frame(of: store.mediaURL(for: asset), at: source) {
                frames[trackID] = CIImage(cgImage: image)
            }
        }
        return frames
    }

    /// A video's stored frame at a source time, as the compositor gets it: not yet turned upright.
    @concurrent
    private nonisolated static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The canvas being resized: its picture, faint outside the new canvas, the new canvas's edge, and its size.
    private func drawCanvasResize(_ resize: CanvasResize) {
        #if DEBUG
        debugResizeDraws += 1
        #endif
        let rect = { (canvas: CGRect) in
            CGRect(x: self.canvasRect.minX + canvas.minX * self.viewScale, y: self.canvasRect.minY + canvas.minY * self.viewScale,
                   width: canvas.width * self.viewScale, height: canvas.height * self.viewScale)
        }
        let old = rect(CGRect(origin: .zero, size: canvas))
        let new = rect(resize.frame)
        if let ghost = resize.ghost {
            // It stands in for the player's picture.
            Theme.previewSurround.setFill()
            old.fill()
            let whole = rect(resize.frame.union(CGRect(origin: .zero, size: canvas)))
            let image = NSImage(cgImage: ghost, size: whole.size)
            image.draw(in: whole, from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: new).addClip()
            image.draw(in: whole, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Until the picture is ready, what would be cut off dims.
            let outside = NSBezierPath(rect: old)
            outside.append(NSBezierPath(rect: new))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.6).setFill()
            outside.fill()
        }
        let corners = [CGPoint(x: new.minX, y: new.minY), CGPoint(x: new.maxX, y: new.minY),
                       CGPoint(x: new.maxX, y: new.maxY), CGPoint(x: new.minX, y: new.maxY)]
        outline(corners, dashed: false)

        // Guides where the edge caught, across the old canvas and the new, over the outline.
        let span = rect(resize.frame.union(CGRect(origin: .zero, size: canvas)))
        let guides = NSBezierPath()
        for x in resize.guides.vertical {
            let viewX = canvasRect.minX + x * viewScale
            guides.move(to: CGPoint(x: viewX, y: span.minY))
            guides.line(to: CGPoint(x: viewX, y: span.maxY))
        }
        for y in resize.guides.horizontal {
            let viewY = canvasRect.minY + y * viewScale
            guides.move(to: CGPoint(x: span.minX, y: viewY))
            guides.line(to: CGPoint(x: span.maxX, y: viewY))
        }
        guides.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        guides.stroke()

        let even = { (value: CGFloat) in min(max(Int(value.rounded()), 16), 8192) / 2 * 2 }
        let label = "\(even(resize.frame.width)) × \(even(resize.frame.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let pill = CGRect(x: new.midX - size.width / 2 - 7, y: new.maxY - size.height - 14, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attributes)
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
        if event.modifierFlags.contains(.command), let edges = canvasEdges(at: point) {
            beginCanvasResize(edges, at: point)
            return
        }
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
        if canvasResize != nil {
            dragCanvas(to: convert(event.locationInWindow, from: nil), bothSides: event.modifierFlags.contains(.option))
            return
        }
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
        if let resize = canvasResize {
            canvasResize = nil
            if resize.frame != CGRect(origin: .zero, size: canvas) { store.resizeCanvas(to: resize.frame) }
            updateResizeCursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
            needsDisplay = true
            return
        }
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
    /// Drags the selected picture until its left edge is just short of the canvas's left edge, as a person would,
    /// then calls `whileHeld` before letting go. Reports the guides lit, in canvas points.
    func debugDragToLeftEdge(whileHeld: () async -> Void) async -> (vertical: [Double], horizontal: [Double])? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window,
              let box = corners(of: clip, visual: clip.visual).map(boundingBox) else { return nil }
        let start = view(center(of: clip.visual))
        let target = -(box.minX - 3) * viewScale
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
        let end = CGPoint(x: start.x + target, y: start.y)
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x + target / 2, y: start.y))
        send(.leftMouseDragged, end)
        let lit = (guides.vertical.map(Double.init), guides.horizontal.map(Double.init))
        display()
        await whileHeld()
        send(.leftMouseUp, end)
        return lit
    }

    var debugCanvasRect: CGRect { canvasRect }
    var debugViewScale: CGFloat { viewScale }
    var debugResizeGuides: [Double] {
        canvasResize.map { ($0.guides.vertical + $0.guides.horizontal).map(Double.init) } ?? []
    }

    /// Holds ⌘ and drags the canvas's right edge by `offset` view points, with ⌥ too when `bothSides`, then calls
    /// `whileHeld` before letting go.
    func debugResizeCanvas(by offset: CGFloat, bothSides: Bool, whileHeld: () async -> Void) async {
        guard let window else { return }
        let start = CGPoint(x: canvasRect.maxX, y: canvasRect.midY)
        let flags: NSEvent.ModifierFlags = bothSides ? [.command, .option] : .command
        let send = { (type: NSEvent.EventType, point: CGPoint) in
            guard let event = NSEvent.mouseEvent(with: type, location: self.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: self.mouseDown(with: event)
            case .leftMouseDragged: self.mouseDragged(with: event)
            default: self.mouseUp(with: event)
            }
        }
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x + offset / 2, y: start.y))
        send(.leftMouseDragged, CGPoint(x: start.x + offset, y: start.y))
        // The video frames for the picture across both canvases are read in the background.
        try? await Task.sleep(for: .milliseconds(800))
        send(.leftMouseDragged, CGPoint(x: start.x + offset, y: start.y))
        display()
        await whileHeld()
        send(.leftMouseUp, CGPoint(x: start.x + offset, y: start.y))
    }

    func debugSnapToMiddle(holdingCommand: Bool) async -> (gap: Double, guides: Int)? {
        guard let id = state?.selection.first, let clip = visibleClips.first(where: { $0.id == id }), let window,
              let box = corners(of: clip, visual: clip.visual).map(boundingBox) else { return nil }
        let start = view(center(of: clip.visual))
        let target = (canvas.width / 2 - box.minX) * viewScale - 3
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
