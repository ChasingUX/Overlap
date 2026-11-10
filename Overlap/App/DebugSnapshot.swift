#if DEBUG
import AppKit
import AVFoundation
import Synchronization

/// Debug-only self-check, used when the app is launched with `OVERLAP_SNAPSHOT=/path/prefix`.
/// Waits for the first project to load, optionally plays it (`OVERLAP_SNAPSHOT_PLAY=1`), then writes each
/// window as `<prefix>-<n>.png` plus a playback report as `<prefix>.json`, and quits.
/// The video layer itself doesn't render into these images; everything else does.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let prefix = environment["OVERLAP_SNAPSHOT"] else { return }
        let shouldPlay = environment["OVERLAP_SNAPSHOT_PLAY"] != nil

        Task {
            try? await Task.sleep(for: .seconds(2))
            let document = NSDocumentController.shared.documents.first as? ProjectDocument
            let startTime = document?.store.playback.currentTime.seconds ?? 0
            if shouldPlay, let document {
                document.store.playback.togglePlay()
                try? await Task.sleep(for: .seconds(3))
            }
            // OVERLAP_SNAPSHOT_DEMO=pip builds the milestone 4 picture: the first video shrunk with rounded corners and
            // a shadow over a gradient, with a title over it. The playhead moves to 2 s.
            if environment["OVERLAP_SNAPSHOT_DEMO"] == "pip", let store = document?.store {
                store.apply("Demo") { project in
                    project.background = BackgroundFill.gradients[0]
                    for (trackIndex, track) in project.tracks.enumerated() {
                        for (clipIndex, clip) in track.clips.enumerated() where project.asset(clip.assetID)?.kind == .video {
                            project.tracks[trackIndex].clips[clipIndex].visual = Visual(x: 0.18, y: -0.04, scale: 0.55, corners: 0.05, shadow: 70)
                        }
                    }
                    var title = TitleStyle.lowerThird.title
                    title.text = "Overlap\nMilestone 4"
                    title.animationIn = .none
                    project.addTitle(title, visual: TitleStyle.lowerThird.visual, at: .zero, target: .new(at: project.tracks.count))
                }
                store.playback.seek(to: Time(seconds: 2))
                try? await Task.sleep(for: .seconds(1))
            }
            // OVERLAP_SNAPSHOT_SELECT=video selects the video showing at the playhead and opens the Video tab.
            // OVERLAP_SNAPSHOT_HANDLE=move or scale then drags it in the preview, 120 points right and 60 down.
            var handleReport: [String: Any] = [:]
            // Without one at the playhead, the playhead moves into the first video.
            if environment["OVERLAP_SNAPSHOT_SELECT"] == "video", let store = document?.store,
               !store.project.tracks.flatMap(\.clips).contains(where: {
                   store.project.asset($0.assetID)?.kind == .video && $0.start <= store.playback.currentTime && store.playback.currentTime < $0.end
               }),
               let first = store.project.tracks.flatMap(\.clips).filter({ store.project.asset($0.assetID)?.kind == .video }).min(by: { $0.start < $1.start }) {
                store.playback.seek(to: first.start + Time(seconds: 1))
                try? await Task.sleep(for: .milliseconds(300))
            }
            if environment["OVERLAP_SNAPSHOT_SELECT"] == "video", let store = document?.store,
               let video = store.project.tracks.flatMap(\.clips).first(where: {
                   store.project.asset($0.assetID)?.kind == .video && $0.start <= store.playback.currentTime && store.playback.currentTime < $0.end
               }) {
                store.select([video.id])
                store.activeTab = .video
                try? await Task.sleep(for: .milliseconds(400))
                // OVERLAP_SNAPSHOT_HANDLE=outside clicks the picture, then outside the canvas.
                if environment["OVERLAP_SNAPSHOT_HANDLE"] == "outside",
                   let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first,
                   let result = await overlay.debugClickOutsideCanvas() {
                    handleReport = ["handlesAfterPictureClick": result.afterPicture, "handlesAfterOutsideClick": result.afterOutside]
                }
                // OVERLAP_SNAPSHOT_HANDLE=corner or cornermiddle scales it by its bottom-right corner, with Option for the second.
                if let kind = environment["OVERLAP_SNAPSHOT_HANDLE"], kind.hasPrefix("corner"),
                   let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first,
                   let result = await overlay.debugCornerScale(fromMiddle: kind == "cornermiddle") {
                    handleReport = ["topLeftMoved": result.cornerMoved, "middleMoved": result.middleMoved, "scale": result.scale]
                }
                // OVERLAP_SNAPSHOT_HANDLE=snap or snapcommand drags its left edge to just short of the canvas's middle.
                if let kind = environment["OVERLAP_SNAPSHOT_HANDLE"], kind.hasPrefix("snap"),
                   let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first,
                   let result = await overlay.debugSnapToMiddle(holdingCommand: kind == "snapcommand") {
                    handleReport = ["gapFromMiddle": result.gap, "guidesShown": result.guides]
                } else if let kind = environment["OVERLAP_SNAPSHOT_HANDLE"], kind == "move" || kind == "scale",
                   let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first {
                    let before = store.project.clip(video.id)?.visual
                    let drawn = await overlay.debugDrag(fromCorner: kind == "scale", by: CGSize(width: 120, height: 60))
                    try? await Task.sleep(for: .milliseconds(600))
                    let after = store.project.clip(video.id)?.visual
                    handleReport = [
                        "dragged": drawn != nil,
                        "framesDrawnDuringDrag": drawn ?? [],
                        "before": [before?.x ?? 0, before?.y ?? 0, before?.scale ?? 0],
                        "after": [after?.x ?? 0, after?.y ?? 0, after?.scale ?? 0],
                        "canUndo": store.undoManager?.canUndo ?? false,
                    ]
                }
            }

            // OVERLAP_SNAPSHOT_TITLES=1 lays out every title style one after another on a new top track, from 0 s.
            if environment["OVERLAP_SNAPSHOT_TITLES"] != nil, let store = document?.store {
                store.apply("Titles") { project in
                    let track = project.tracks.count
                    for (index, style) in TitleStyle.allCases.enumerated() {
                        let target: TrackTarget = index == 0 ? .new(at: track) : .existing(project.tracks[track].id)
                        project.addTitle(style.title, visual: style.visual, at: Time(seconds: Double(index) * 5), target: target)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
                // OVERLAP_SNAPSHOT_AT=<seconds> also parks the playhead there, for the frame of one style.
                if let seconds = environment["OVERLAP_SNAPSHOT_AT"].flatMap(Double.init) {
                    store.playback.seek(to: Time(seconds: seconds))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }

            // OVERLAP_SNAPSHOT_TITLESEEK=<seconds> adds a Centered Title there, as clicking its tile does, then moves the
            // playhead before, into and past it (or to OVERLAP_SNAPSHOT_SEEKS=<seconds,…>). After each move it reports the
            // time the compositor drew, which must be the new playhead's, and when the brightness in the middle of the
            // shown frame changed, where the title's white text sits. The shown frame only keeps up while the window is
            // on screen: macOS draws a covered window about once a second.
            var titleSeekReport: [[String: Any]] = []
            if let start = environment["OVERLAP_SNAPSHOT_TITLESEEK"].flatMap(Double.init), let store = document?.store,
               let preview = NSApplication.shared.windows.first(where: \.isVisible)?.contentView.flatMap({ find(PlayerLayerView.self, in: $0) }) {
                func middleBrightness() -> Double {
                    guard let buffer = preview.playerLayer.displayedPixelBuffer() else { return -1 }
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    let row = CVPixelBufferGetBytesPerRow(buffer)
                    var brightest = 0.0
                    for y in stride(from: height * 2 / 5, to: height * 3 / 5, by: 2) {
                        for x in stride(from: width * 2 / 5, to: width * 3 / 5, by: 2) {
                            let pixel = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                            brightest = max(brightest, Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2]))
                        }
                    }
                    return (brightest / 765 * 100).rounded() / 100
                }
                store.playback.seek(to: Time(seconds: start))
                try? await Task.sleep(for: .milliseconds(500))
                store.addTitleAtPlayhead(.centeredTitle)
                try? await Task.sleep(for: .milliseconds(1500))
                let targets = environment["OVERLAP_SNAPSHOT_SEEKS"]?.split(separator: ",").compactMap { Double($0) }
                    ?? [start - 1.5, start + 1, start + 2.5, start + 4, start + 6, start + 1.5]
                for target in targets {
                    store.playback.seek(to: Time(seconds: max(0, target)))
                    let moved = Date()
                    var changes: [[Double]] = []
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(20))
                        let brightness = middleBrightness()
                        if changes.last?[1] != brightness {
                            changes.append([(Date().timeIntervalSince(moved) * 1000).rounded(), brightness])
                        }
                    }
                    titleSeekReport.append(["to": target, "ms, brightness": changes,
                                            "drawn at": Compositor.lastRenderedTime.withLock { $0 } ?? -1])
                }
            }

            // OVERLAP_SNAPSHOT_LOOPS=<seconds> selects the first video clip, parks the playhead that far into it, opens
            // the Video tab and finds the video's loops. It reports them, captures `<prefix>-loops.png` with the
            // first one highlighted on the timeline, then trims the clip to it and reports the clip.
            var loopsReport: [String: Any] = [:]
            if let offset = environment["OVERLAP_SNAPSHOT_LOOPS"].flatMap(Double.init), let store = document?.store,
               let clip = store.project.tracks.flatMap(\.clips).first(where: { store.project.asset($0.assetID)?.kind == .video }) {
                store.select([clip.id])
                store.activeTab = .video
                store.playback.seek(to: clip.start + Time(seconds: offset))
                store.findLoops(inAsset: clip.assetID)
                let started = Date()
                while store.suggestedLoops[clip.assetID] == nil, Date().timeIntervalSince(started) < 30 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                loopsReport["seconds"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
                loopsReport["repeats every"] = store.repetitions[clip.assetID]?.length ?? -1
                let describe = { (loops: [Loop]) in loops.map { String(format: "%.2f–%.2f", $0.start, $0.end) } }
                loopsReport["suggested"] = describe(store.suggestedLoops[clip.assetID] ?? [])
                loopsReport["repeating"] = describe(store.repeatingLoops(in: clip))
                loopsReport["from playhead"] = describe(store.loopsFromPlayhead(in: clip))
                let first = store.repeatingLoops(in: clip).first ?? store.suggestedLoops[clip.assetID]?.first
                if let first {
                    store.highlightedLoop = LoopHighlight(clip: clip.id, start: first.start, end: first.end)
                }
                try? await Task.sleep(for: .milliseconds(400))
                if let window = NSApplication.shared.windows.first(where: \.isVisible), let view = window.contentView?.superview,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-loops.png"))
                    // The panel scrolled to its end, where the Loop section sits, as `<prefix>-loops-panel.png`.
                    func scrollViews(in view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                    }
                    for scroll in scrollViews(in: view) where scroll.frame.width < 400 {
                        if let document = scroll.documentView {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if let panel = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: panel)
                        try? panel.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-loops-panel.png"))
                    }
                }
                if let first {
                    store.highlightedLoop = nil
                    store.trimToLoop(first)
                    if let trimmed = store.project.clip(clip.id) {
                        loopsReport["trimmed"] = [trimmed.start.seconds, trimmed.sourceStart.seconds, trimmed.duration.seconds]
                        loopsReport["plays it"] = store.plays(first, in: trimmed)
                    }
                }
            }

            // OVERLAP_SNAPSHOT_EDITED=1 makes an edit, then samples every half second for eight seconds whether the
            // document counts it as unsaved and the title says Saving…, then undoes it and times the next autosave.
            var editedSamples: [[Double]] = []
            if environment["OVERLAP_SNAPSHOT_EDITED"] != nil, let document {
                let store = document.store
                store.setMasterVolume(store.project.masterVolume * 0.9)
                // An edit made from a click ends with its event, which is when the undo step closes and AppKit counts
                // the change. This one comes from no event, so post one.
                func closeUndoStep() {
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                }
                closeUndoStep()
                let started = Date()
                for _ in 0..<16 {
                    try? await Task.sleep(for: .milliseconds(500))
                    editedSamples.append([(Date().timeIntervalSince(started) * 10).rounded() / 10, document.isDocumentEdited ? 1 : 0,
                                          store.isSaving ? 1 : 0, document.hasUnautosavedChanges ? 1 : 0])
                }
                // Then undo it, which needs saving again, and wait for that autosave.
                document.undoManager?.undo()
                closeUndoStep()
                editedSamples.append([-1, store.isSaving ? 1 : 0])
                let undone = Date()
                while store.isSaving, Date().timeIntervalSince(undone) < 15 { try? await Task.sleep(for: .milliseconds(100)) }
                editedSamples.append([-2, store.isSaving ? 1 : 0, (Date().timeIntervalSince(undone) * 10).rounded() / 10])
            }

            // OVERLAP_SNAPSHOT_LOOPPLAY=1 turns Loop Playback on, plays the last second and on past the end, and samples
            // the player every 10 ms, to see how long the jump back to the start takes. The setting is put back after.
            var loopPlayReport: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_LOOPPLAY"] != nil, let store = document?.store, store.playback.duration > .zero {
                let saved = UserDefaults.standard.object(forKey: "loopsPlayback")
                store.playback.loopsPlayback = true
                store.playback.seek(to: store.playback.duration - Time(seconds: 1))
                try? await Task.sleep(for: .milliseconds(500))
                store.playback.togglePlay()
                let started = Date()
                var samples: [(wall: Double, time: Double)] = []
                while Date().timeIntervalSince(started) < 2.5 {
                    samples.append((Date().timeIntervalSince(started), store.playback.player.currentTime().seconds))
                    try? await Task.sleep(for: .milliseconds(10))
                }
                store.playback.pause()
                if let wrap = samples.indices.dropFirst().first(where: { samples[$0].time < samples[$0 - 1].time - 0.5 }) {
                    let before = samples[wrap - 1]
                    // When the start is playing again: the first sample after the wrap that's moved on.
                    let moving = samples[wrap...].first { $0.time > 0.03 }
                    let duration = store.playback.duration.seconds
                    loopPlayReport["last before wrap"] = [before.wall, before.time]
                    loopPlayReport["first moving after"] = moving.map { [$0.wall, $0.time] } ?? []
                    // Wall time spent beyond what the media itself took, from the last sample to the first moving one.
                    if let moving {
                        loopPlayReport["stall ms"] = ((moving.wall - before.wall - (duration - before.time) - moving.time) * 1000).rounded()
                    }
                }
                loopPlayReport["still playing"] = samples.last.map { $0.time > 0.5 } ?? false
                UserDefaults.standard.set(saved, forKey: "loopsPlayback")
            }

            // OVERLAP_SNAPSHOT_GUIDES=<video> brings in that video, selects its clip, and drags it to the canvas's left
            // edge, reporting the guides lit and capturing `<prefix>-guides.png` while the mouse is still down.
            var guidesReport: [String: Any] = [:]
            if let path = environment["OVERLAP_SNAPSHOT_GUIDES"], let store = document?.store {
                store.importFiles([URL(fileURLWithPath: path)], placement: (.zero, .new(at: store.project.tracks.count)))
                let started = Date()
                while store.project.tracks.flatMap(\.clips).isEmpty, Date().timeIntervalSince(started) < 10 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let clip = store.project.tracks.flatMap(\.clips).first {
                    store.select([clip.id])
                    store.playback.seek(to: Time(seconds: 1))
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let window = NSApplication.shared.windows.first(where: \.isVisible),
                       let overlay = window.contentView.flatMap({ find(TransformOverlay.self, in: $0) }),
                       let lit = await overlay.debugDragToLeftEdge(whileHeld: {
                           if let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                               view.cacheDisplay(in: view.bounds, to: bitmap)
                               try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-guides.png"))
                           }
                       }) {
                        guidesReport = ["vertical": lit.vertical, "horizontal": lit.horizontal,
                                        "canvas": store.project.canvas.map { [$0.width, $0.height] } ?? []]
                    }
                }
            }

            // OVERLAP_SNAPSHOT_CANVASRESIZE=<points>[,both] ⌘-drags the canvas's right edge that far, ⌘⌥ with ",both",
            // capturing `<prefix>-resizing.png` before letting go, then reports the canvas and the first clip's placement.
            var canvasResizeReport: [String: Any] = [:]
            // "to:<pixels>" drags the edge to that canvas x instead, and reports the guides lit there.
            if let spec = environment["OVERLAP_SNAPSHOT_CANVASRESIZE"].map({ spec -> String in
                   guard spec.hasPrefix("to:"), let x = Double(spec.dropFirst(3)),
                         let overlay = NSApplication.shared.windows.first(where: \.isVisible)?.contentView.flatMap({ find(TransformOverlay.self, in: $0) }),
                         let canvas = document?.store.project.canvas else { return spec }
                   return String((x - Double(canvas.width)) * Double(overlay.debugViewScale))
               }), let offset = spec.split(separator: ",").first.flatMap({ Double($0) }),
               let store = document?.store, let window = NSApplication.shared.windows.first(where: \.isVisible),
               let overlay = window.contentView.flatMap({ find(TransformOverlay.self, in: $0) }) {
                store.playback.seek(to: Time(seconds: 1))
                try? await Task.sleep(for: .milliseconds(600))
                let before = store.project.tracks.flatMap(\.clips).first?.visual
                var lit: [Double] = []
                await overlay.debugResizeCanvas(by: CGFloat(offset), bothSides: spec.hasSuffix(",both")) {
                    lit = overlay.debugResizeGuides
                    if let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-resizing.png"))
                    }
                }
                try? await Task.sleep(for: .milliseconds(800))
                let after = store.project.tracks.flatMap(\.clips).first?.visual
                canvasResizeReport = ["canvas": store.project.canvas.map { [$0.width, $0.height] } ?? [], "guides": lit,
                                      "aspect": store.project.canvasAspect.rawValue,
                                      "before": before.map { [$0.x, $0.y, $0.scale] } ?? [], "after": after.map { [$0.x, $0.y, $0.scale] } ?? []]
            }

            // OVERLAP_SNAPSHOT_CANVASDRAG=<points> ⌘-drags the canvas's right edge that far with real events posted to
            // the window over a second, as a person's drag arrives, and reports how often the resize was drawn and how
            // long each picture took.
            var canvasDragReport: [String: Any] = [:]
            if let offset = environment["OVERLAP_SNAPSHOT_CANVASDRAG"].flatMap(Double.init),
               let window = NSApplication.shared.windows.first(where: \.isVisible),
               let overlay = window.contentView.flatMap({ find(TransformOverlay.self, in: $0) }), let content = window.contentView {
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(600))
                overlay.debugResizeDraws = 0
                overlay.debugGhostTimes = []
                let edge = overlay.convert(CGPoint(x: overlay.debugCanvasRect.maxX, y: overlay.debugCanvasRect.midY), to: nil)
                let send = { (type: NSEvent.EventType, x: CGFloat) in
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: edge.y), modifierFlags: .command,
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                }
                send(.leftMouseDown, edge.x)
                var drawsDuring: [Int] = []
                for step in 1...30 {
                    try? await Task.sleep(for: .milliseconds(33))
                    send(.leftMouseDragged, edge.x + CGFloat(offset) * CGFloat(step) / 30)
                    if step % 5 == 0 { drawsDuring.append(overlay.debugResizeDraws) }
                }
                try? await Task.sleep(for: .milliseconds(100))
                send(.leftMouseUp, edge.x + CGFloat(offset))
                try? await Task.sleep(for: .milliseconds(500))
                let times = overlay.debugGhostTimes
                canvasDragReport = ["draws every 5 moves": drawsDuring, "ghosts drawn": times.count,
                                    "ghost ms median": times.sorted().dropFirst(times.count / 2).first ?? -1, "ghost ms max": times.max() ?? -1,
                                    "canvas": document?.store.project.canvas.map { [$0.width, $0.height] } ?? []]
                _ = content
            }

            // OVERLAP_SNAPSHOT_TEXTEDIT=commit or cancel double-clicks the first text showing, types into it on the
            // canvas, captures the window midway as `<prefix>-editing.png`, then applies or cancels.
            var textEditReport: [String: Any] = [:]
            if let mode = environment["OVERLAP_SNAPSHOT_TEXTEDIT"],
               let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first {
                textEditReport = await overlay.debugEditTitle(typing: "Typed on the canvas", cancel: mode == "cancel") {
                    if let window = overlay.window, let view = window.contentView?.superview,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-editing.png"))
                    }
                }
            }

            // OVERLAP_SNAPSHOT_CROPCLICK=1 double-clicks the first picture showing, captures the window as
            // `<prefix>-cropping.png`, then double-clicks it again.
            var cropClickReport: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_CROPCLICK"] != nil,
               let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first {
                cropClickReport = await overlay.debugDoubleClickPicture {
                    if let window = overlay.window, let view = window.contentView?.superview,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-cropping.png"))
                    }
                }
            }

            // OVERLAP_SNAPSHOT_PICTUREMENU=1 lists the first picture's right-click menu, then moves, shrinks and crops
            // it and chooses Reset Position, Reset Crop and Crop from the menu in turn.
            var pictureMenu: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_PICTUREMENU"] != nil, let store = document?.store,
               let overlay = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { find(TransformOverlay.self, in: $0) } }).first {
                func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
                if store.playback.currentTime == .zero,
                   let first = store.project.tracks.flatMap(\.clips).filter({ store.project.isPlaceable($0) && $0.title == nil }).min(by: { $0.start < $1.start }) {
                    store.playback.seek(to: first.start + Time(seconds: 1))
                    await settle()
                }
                let untouched = overlay.debugPictureMenu()
                store.setVisual("Debug") { $0.x = 0.2; $0.scale = 0.5; $0.crop.left = 0.1 }
                await settle()
                let changed = overlay.debugPictureMenu(choosing: "Reset Position")
                await settle()
                let afterPosition = store.selectedClips.first?.visual
                _ = overlay.debugPictureMenu(choosing: "Reset Crop")
                await settle()
                let afterCrop = store.selectedClips.first?.visual
                let beforeCrop = overlay.debugPictureMenu(choosing: "Crop")
                await settle()
                pictureMenu = [
                    "untouched": untouched, "changed": changed,
                    "resetPosition": afterPosition.map { [$0.x, $0.y, $0.scale, $0.rotation] } ?? [],
                    "cropKeptAfterResetPosition": afterPosition.map { !$0.crop.isEmpty } ?? false,
                    "cropEmptyAfterResetCrop": afterCrop?.crop.isEmpty ?? false,
                    "beforeCrop": beforeCrop, "cropping": store.isCropping,
                    "whileCropping": overlay.debugPictureMenu(),
                ]
            }

            // OVERLAP_SNAPSHOT_EXPORT=sheet opens the Export sheet. A format name (mp4, mov, wav, aiff, m4a) also
            // exports through it, as pressing Export does, into the snapshot's folder, and reports the file; fail
            // exports to a folder that isn't there. The sheet is captured as <prefix>-export.png, mid-export as
            // -export-progress.png, and the window with its toast afterwards as -export-done.png.
            var exportReport: [String: Any] = [:]
            if let mode = environment["OVERLAP_SNAPSHOT_EXPORT"], let store = document?.store {
                let capture = { (suffix: String) in
                    guard let sheet = NSApplication.shared.windows.lazy.compactMap(\.attachedSheet).first,
                          let view = sheet.contentView?.superview ?? sheet.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-\(suffix).png"))
                }
                if let format = ExportSettings.Format(rawValue: mode) {
                    if format.hasVideo { store.exportSettings.videoFormat = format } else { store.exportSettings.audioFormat = format }
                    store.exportSettings.isAudioOnly = !format.hasVideo
                }
                store.requestExport()
                try? await Task.sleep(for: .milliseconds(600))
                capture("export")
                if mode == "sheet" {
                    // An open sheet would hold up quitting.
                    store.isExportSheetShown = false
                } else {
                    let folder = URL(filePath: prefix).deletingLastPathComponent()
                    let destination = (mode == "fail" ? folder.appending(path: "Missing Folder") : folder)
                        .appending(path: "Exported.\(store.exportFormat.fileExtension)")
                    let started = Date()
                    store.export(to: destination)
                    try? await Task.sleep(for: .milliseconds(400))
                    capture("export-progress")
                    var fractions: [Double] = []
                    while store.isExporting, Date().timeIntervalSince(started) < 300 {
                        fractions.append(store.exportProgress?.fraction ?? 0)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    let asset = AVURLAsset(url: destination)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                    var loudness: Double?
                    if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first {
                        let output = AVAssetReaderTrackOutput(track: track, outputSettings: PCMReader.floatSettings(sampleRate: 48_000, channels: 2))
                        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
                        try? await PCMReader.read(asset, output: output) { meter.add($0) }
                        loudness = meter.integratedLoudness
                    }
                    let video = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
                    exportReport = [
                        "file": destination.lastPathComponent,
                        "bytes": size,
                        "seconds": Date().timeIntervalSince(started),
                        "duration": (try? await asset.load(.duration).seconds) ?? 0,
                        "projectDuration": store.project.duration.seconds,
                        "loudness": loudness ?? -999,
                        "videoSize": video.map { [Double($0.width), Double($0.height)] } ?? [],
                        "sheetShown": store.isExportSheetShown,
                        "alert": store.alert?.message ?? "",
                        "toast": [store.toast?.title ?? "", store.toast?.detail ?? "", store.toast?.file?.lastPathComponent ?? ""],
                        "fractions": fractions.map { ($0 * 100).rounded() / 100 },
                    ]
                    try? await Task.sleep(for: .milliseconds(500))
                    if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.attachedSheet == nil }),
                       let view = window.contentView?.superview ?? window.contentView,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-export-done.png"))
                    }
                }
            }

            // OVERLAP_SNAPSHOT_TAB=master or titles opens the Audio or Text tab with nothing selected, showing the
            // master volume or the title styles.
            if let empty = ["master": PanelTab.audio, "titles": .text][environment["OVERLAP_SNAPSHOT_TAB"] ?? ""], let store = document?.store {
                store.select([])
                store.activeTab = empty
                try? await Task.sleep(for: .milliseconds(300))
            }
            // OVERLAP_SNAPSHOT_PERF=1 measures the spec's performance targets on the open project: a full rebuild,
            // five edits from the change to the new frame on screen, a full timeline redraw, and frames dropped
            // over ten seconds of playback from the middle.
            var perfReport: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_PERF"] != nil, let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible), let content = window.contentView,
               let preview = find(PlayerLayerView.self, in: content), let timeline = findTimeline(in: content) {
                let clock = ContinuousClock()
                let seconds = { (duration: Duration) in Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds) }
                let buildStart = clock.now
                _ = try? await CompositionBuilder.build(project: store.project, assets: { store.avAsset(for: $0) })
                let build = seconds(clock.now - buildStart)

                let middle = store.project.duration.seconds / 2
                store.playback.seek(to: Time(seconds: middle))
                try? await Task.sleep(for: .milliseconds(800))
                let picture = store.project.tracks.flatMap(\.clips).first { store.project.showsPicture($0) && $0.start.seconds <= middle && middle < $0.end.seconds }
                /// How long a change takes to show: until the compositor has drawn a frame of the new build and no
                /// held frame covers it.
                @MainActor func timeToShow(_ change: () -> Void) async -> Double {
                    let oldPlan = store.playback.plan
                    // Paused, the compositor only draws when asked, so any frame from here on is the new one.
                    let rendersBefore = Compositor.renders.load(ordering: .relaxed)
                    let start = clock.now
                    change()
                    while clock.now - start < .seconds(5) {
                        if store.playback.plan !== oldPlan, Compositor.renders.load(ordering: .relaxed) > rendersBefore,
                           !store.playback.debugIsSwapping, !preview.debugDisplayState.stillShown {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                    let elapsed = seconds(clock.now - start)
                    try? await Task.sleep(for: .milliseconds(300))
                    return elapsed
                }
                var edits: [Double] = []
                var moves: [Double] = []
                if let picture {
                    for step in 0..<5 {
                        edits.append(await timeToShow {
                            store.apply("Measure") { $0.changeVisual(of: [picture.id]) { $0.opacity = 0.9 - Double(step) * 0.1 } }
                        })
                    }
                }
                // Nudging a sound clip changes the layout, so these need a new item.
                if let sound = store.project.tracks.flatMap(\.clips).first(where: { !store.project.showsPicture($0) && $0.start.seconds > middle }),
                   let location = store.project.location(ofClip: sound.id) {
                    for step in 0..<5 {
                        moves.append(await timeToShow {
                            store.apply("Measure") { $0.tracks[location.track].clips[location.clip].start = sound.start + Time(seconds: Double(step + 1) * 0.1) }
                        })
                    }
                }

                var draws: [Double] = []
                for _ in 0..<5 {
                    let start = clock.now
                    timeline.needsDisplay = true
                    timeline.displayIfNeeded()
                    draws.append(seconds(clock.now - start))
                }

                // Counted from a second in, once playback has settled.
                store.playback.togglePlay()
                try? await Task.sleep(for: .seconds(1))
                let rendersBefore = Compositor.renders.load(ordering: .relaxed)
                let playStart = clock.now
                try? await Task.sleep(for: .seconds(9))
                let played = seconds(clock.now - playStart)
                let rendered = Compositor.renders.load(ordering: .relaxed) - rendersBefore
                store.playback.pause()
                let event = store.playback.player.currentItem?.accessLog()?.events.last
                perfReport = [
                    "clips": store.project.tracks.flatMap(\.clips).count,
                    "tracks": store.project.tracks.count,
                    "duration": store.project.duration.seconds,
                    "buildSeconds": build,
                    "lookEditSeconds": edits,
                    "moveEditSeconds": moves,
                    "timelineDrawSeconds": draws,
                    "renderedFramesPerSecond": Double(rendered) / played,
                    "droppedFrames": event?.numberOfDroppedVideoFrames ?? -1,
                    "stalls": event?.numberOfStalls ?? -1,
                ]
            }

            // OVERLAP_SNAPSHOT_WINDOWRESIZE=1 makes the window 200 points taller, then 400 shorter, and reports the
            // preview's and the timeline area's heights at each size. The timeline should hold its height.
            var windowResize: [[Double]] = []
            if environment["OVERLAP_SNAPSHOT_WINDOWRESIZE"] != nil,
               let window = NSApplication.shared.windows.first(where: \.isVisible), let content = window.contentView,
               let preview = find(PlayerLayerView.self, in: content) {
                let measure = {
                    windowResize.append([Double(content.bounds.height), Double(preview.frame.height), Double(content.bounds.height - preview.frame.height)])
                }
                measure()
                for change in [200.0, -400.0] {
                    var frame = window.frame
                    frame.origin.y -= change
                    frame.size.height += change
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .milliseconds(400))
                    measure()
                }
            }

            // OVERLAP_SNAPSHOT_SAVEPANEL=1 presses Save in a new, unsaved project and reports the sheet it shows, which
            // should be the save panel with a name and a place to save, then cancels it.
            var savePanelReport: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_SAVEPANEL"] != nil, let document, document.fileURL == nil,
               let window = document.windowControllers.first?.window {
                document.save(nil)
                try? await Task.sleep(for: .milliseconds(800))
                let panel = window.attachedSheet as? NSSavePanel
                savePanelReport = [
                    "sheet": window.attachedSheet.map { String(describing: type(of: $0)) } ?? "none",
                    "isSavePanel": panel != nil,
                    "name": panel?.nameFieldStringValue ?? "",
                    "folder": panel?.directoryURL?.path ?? "",
                    "canPickFolder": panel.map { !$0.isExpanded || $0.isExpanded } ?? false,
                ]
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                try? await Task.sleep(for: .milliseconds(300))
            }

            // OVERLAP_SNAPSHOT_MOVE=<folder> moves the saved project there, as Move To… and renaming do, then checks
            // that its media loads from the new place and that it still plays.
            var moveReport: [String: Any] = [:]
            if let folder = environment["OVERLAP_SNAPSHOT_MOVE"], let document, let url = document.fileURL {
                let store = document.store
                let destination = URL(filePath: folder).appending(path: url.lastPathComponent)
                let moved = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    document.move(to: destination) { error in
                        continuation.resume(returning: error?.localizedDescription ?? "")
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
                let before = store.playback.currentTime.seconds
                store.playback.togglePlay()
                try? await Task.sleep(for: .seconds(1))
                store.playback.pause()
                moveReport = [
                    "error": moved,
                    "fileURL": document.fileURL?.path ?? "",
                    "mediaDirectory": store.mediaDirectory.path,
                    "mediaFound": store.project.assets.allSatisfy { FileManager.default.fileExists(atPath: store.mediaURL(for: $0).path) },
                    "played": store.playback.currentTime.seconds - before,
                    "playerError": store.playback.player.currentItem?.error?.localizedDescription ?? "",
                ]
            }

            // OVERLAP_SNAPSHOT_POPUP=1 clicks the first pop-up menu row in the panel, as a person would, then while its
            // menu is open records its items and captures it as <prefix>-popup.png before closing it.
            var popUpReport: [[String: Any]] = []
            if environment["OVERLAP_SNAPSHOT_POPUP"] != nil, let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible), let content = window.contentView {
                if let tab = environment["OVERLAP_SNAPSHOT_PANEL"].flatMap({ name in PanelTab.allCases.first { $0.title.lowercased() == name } }) {
                    store.select([])
                    store.activeTab = tab
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let anchor = find(PopUpAnchorNSView.self, in: content) {
                    PopUpAnchor.debugOnOpen = { menu in
                        popUpReport = menu.items.map { item in
                            item.isSeparatorItem ? ["separator": true] : [
                                "title": item.title, "subtitle": item.subtitle ?? "", "detail": item.badge?.stringValue ?? "",
                                "image": item.image != nil, "chosen": item.state == .on,
                            ]
                        }
                        // Every image view in the open menu: what it shows and whether it's visible.
                        func images(in view: NSView) -> [String] {
                            var found: [String] = []
                            if let imageView = view as? NSImageView, let image = imageView.image {
                                let frame = imageView.convert(imageView.bounds, to: nil)
                                found.append(String(format: "%.0fx%.0f at %.0f,%.0f hidden=%@ alpha=%.2f", image.size.width, image.size.height,
                                                    frame.minX, frame.minY, imageView.isHiddenOrHasHiddenAncestor ? "yes" : "no", imageView.alphaValue))
                            }
                            return found + view.subviews.flatMap(images)
                        }
                        let menuWindows = NSApplication.shared.windows.filter { $0.isVisible && $0 !== window }
                        popUpReport.append(["imageViews": menuWindows.flatMap { $0.contentView.map(images) ?? [] }])
                        for menuWindow in NSApplication.shared.windows where menuWindow.isVisible && menuWindow !== window {
                            guard let view = menuWindow.contentView?.superview ?? menuWindow.contentView,
                                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-popup.png"))
                        }
                        // OVERLAP_SNAPSHOT_POPUP=<title> also chooses that item, as clicking it would.
                        if let title = environment["OVERLAP_SNAPSHOT_POPUP"], let index = menu.items.firstIndex(where: { $0.title == title }) {
                            menu.performActionForItem(at: index)
                        }
                        menu.cancelTracking()
                    }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(300))
                    let point = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApplication.shared.postEvent(event, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .milliseconds(1200))
                    PopUpAnchor.debugOnOpen = nil
                    popUpReport.append(["firstResponder": String(describing: type(of: window.firstResponder as Any)),
                                        "canvasAspect": store.project.canvasAspect.rawValue])
                }
            }

            // OVERLAP_SNAPSHOT_PANEL=<tab> opens any tab with nothing selected, for its empty state.
            if let tab = environment["OVERLAP_SNAPSHOT_PANEL"].flatMap({ name in PanelTab.allCases.first { $0.title.lowercased() == name } }),
               let store = document?.store {
                store.select([])
                store.selectTransition(nil)
                store.activeTab = tab
                try? await Task.sleep(for: .milliseconds(300))
            }
            // OVERLAP_SNAPSHOT_PIXELS=<width>|<height>|<aspect> picks the shape, then types each number given into
            // the Pixels row's field for it and leaves the field, as Tab would. Either may be empty.
            var pixelsReport: [String: Any] = [:]
            if let typed = environment["OVERLAP_SNAPSHOT_PIXELS"]?.split(separator: "|", omittingEmptySubsequences: false).map(String.init),
               typed.count == 3, let store = document?.store, let window = NSApplication.shared.windows.first(where: \.isVisible),
               let content = window.contentView {
                if let aspect = CanvasAspect(rawValue: typed[2]) { store.setCanvasAspect(aspect) }
                store.activeTab = .canvas
                try? await Task.sleep(for: .milliseconds(300))
                func fields(in view: NSView) -> [NSTextField] {
                    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
                }
                for (index, number) in typed.prefix(2).enumerated() where !number.isEmpty {
                    let current = index == 0 ? store.project.canvas?.width : store.project.canvas?.height
                    guard let field = fields(in: content).first(where: { $0.isEditable && $0.stringValue == current.map(String.init) }) else { continue }
                    window.makeFirstResponder(field)
                    try? await Task.sleep(for: .milliseconds(100))
                    field.currentEditor()?.selectAll(nil)
                    field.currentEditor()?.insertText(number)
                    try? await Task.sleep(for: .milliseconds(100))
                    window.makeFirstResponder(nil)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                pixelsReport = ["canvas": store.project.canvas.map { [$0.width, $0.height] } ?? [],
                                "aspect": store.project.canvasAspect.rawValue,
                                "fields": fields(in: content).filter(\.isEditable).map(\.stringValue)]
            }
            // OVERLAP_SNAPSHOT_ADDCOLOR=<hex> clicks the Canvas tab's + swatch, picks that color in the color panel and
            // reports what was kept. The saved custom colors are put back as they were afterward.
            var addColorReport: [String: Any] = [:]
            if let hex = environment["OVERLAP_SNAPSHOT_ADDCOLOR"].flatMap({ Int($0, radix: 16) }), let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible), let content = window.contentView {
                store.activeTab = .canvas
                try? await Task.sleep(for: .milliseconds(300))
                let saved = UserDefaults.standard.data(forKey: "customBackgroundColors")
                if let well = find(SwatchColorWell.self, in: content) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    let point = well.convert(CGPoint(x: well.bounds.midX, y: well.bounds.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApplication.shared.postEvent(event, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    addColorReport["wellActive"] = well.isActive
                    addColorReport["panelVisible"] = NSColorPanel.shared.isVisible
                    // Where the panel opened against the swatch, in screen points: its frame, then the swatch's.
                    let swatch = window.convertToScreen(well.convert(well.bounds, to: nil))
                    addColorReport["panelFrame"] = [NSColorPanel.shared.frame.minX, NSColorPanel.shared.frame.maxY,
                                                    NSColorPanel.shared.frame.width, NSColorPanel.shared.frame.height].map { Double($0.rounded()) }
                    addColorReport["swatchFrame"] = [swatch.minX, swatch.maxY, swatch.width, swatch.height].map { Double($0.rounded()) }
                    addColorReport["scrollEdge"] = well.enclosingScrollView.map { Double(window.convertToScreen($0.convert($0.bounds, to: nil)).maxX) } ?? -1
                    addColorReport["windowFrame"] = [window.frame.minX, window.frame.maxY, window.frame.width].map { Double($0.rounded()) }
                    // Two picks in a row, as a drag through the panel would make, then a pause.
                    for step in [0.5, 1.0] {
                        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255 * step, green: CGFloat((hex >> 8) & 0xFF) / 255 * step,
                                            blue: CGFloat(hex & 0xFF) / 255 * step, alpha: 1)
                        NSColorPanel.shared.color = color
                        try? await Task.sleep(for: .milliseconds(step == 0.5 ? 700 : 100))
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                    if case let .color(color)? = store.project.background {
                        addColorReport["background"] = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
                    }
                    addColorReport["kept"] = WallpaperLibrary.customColors.map { [$0.red, $0.green, $0.blue].map { Int(($0 * 255).rounded()) } }
                    if let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-addcolor.png"))
                    }
                    NSColorPanel.shared.close()
                }
                UserDefaults.standard.set(saved, forKey: "customBackgroundColors")
            }
            // OVERLAP_SNAPSHOT_TAB=video or audio selects the top track's first clip and opens that tab.
            if let tab = environment["OVERLAP_SNAPSHOT_TAB"].flatMap({ name in PanelTab.allCases.first { $0.title.lowercased() == name } }),
               let store = document?.store, let clip = store.project.tracks.last?.clips.first {
                store.activeTab = tab
                store.select([clip.id])
                try? await Task.sleep(for: .milliseconds(300))
            }
            // OVERLAP_SNAPSHOT_ISOLATE=1 turns voice isolation on for the selected clips, then plays two seconds.
            var isolationReport: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_ISOLATE"] != nil, let store = document?.store {
                store.setIsolatesVoice(true)
                try? await Task.sleep(for: .milliseconds(600))
                let before = store.playback.currentTime.seconds
                store.playback.togglePlay()
                try? await Task.sleep(for: .seconds(2))
                isolationReport = [
                    "isolated": store.project.tracks.flatMap(\.clips).filter(\.isolatesVoice).count,
                    "played": store.playback.currentTime.seconds - before,
                    "isPlaying": store.playback.isPlaying,
                    "error": store.playback.player.currentItem?.error?.localizedDescription ?? "",
                ]
                store.playback.pause()
            }

            // OVERLAP_SNAPSHOT_SPEEDPREVIEW=<speed> drags the selected clip's speed there without letting go.
            // The timeline should show the new length while the project keeps the old one.
            var speedReport: [String: Any] = [:]
            if let speed = environment["OVERLAP_SNAPSHOT_SPEEDPREVIEW"].flatMap(Double.init), let store = document?.store,
               let clip = store.selectedClips.first {
                store.speedPreview = speed
                try? await Task.sleep(for: .milliseconds(300))
                speedReport = [
                    "committed": store.project.clip(clip.id)?.duration.seconds ?? 0,
                    "shown": store.timelineProject.clip(clip.id)?.duration.seconds ?? 0,
                ]
            }

            // OVERLAP_SNAPSHOT_CROSSFADE=transition or fade slides the second clip on a two-clip track back so the
            // two overlap by 4 seconds with an S-curve, gives the first a 3-second fade in, then either selects the
            // crossfade or selects the first clip in the Audio tab.
            var crossfadeReport: [String: Any] = [:]
            if let mode = environment["OVERLAP_SNAPSHOT_CROSSFADE"], let store = document?.store,
               let track = store.project.tracks.first(where: { $0.clips.count >= 2 }) {
                let clips = track.clips.sorted { $0.start < $1.start }
                store.moveClip(clips[1].id, to: clips[0].end - Time(seconds: 4), target: .existing(track.id))
                store.setFade(.start, duration: Time(seconds: 3), curve: .sCurve, clips: [clips[0].id])
                store.selectTransition(clips[1].id)
                store.setCrossfadeCurve(.sCurve)
                if mode == "fade" {
                    store.activeTab = .audio
                    store.select([clips[0].id])
                }
                try? await Task.sleep(for: .milliseconds(500))
                crossfadeReport = [
                    "range": store.selectedCrossfade.map { [$0.range.start.seconds, $0.range.duration.seconds] } ?? [],
                    "curve": store.selectedCrossfade?.curve.name ?? "",
                    "activeTab": store.activeTab.title,
                ]
            }

            // OVERLAP_SNAPSHOT_MENU=1 lists the selected clip's right-click menu in the report.
            var menuLines: [String] = []
            if environment["OVERLAP_SNAPSHOT_MENU"] != nil,
               let timeline = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap(findTimeline) }).first {
                menuLines = timeline.debugMenuLines()
            }

            var dragSummary: [String: Any] = [:]
            // OVERLAP_SNAPSHOT_DRAG=clip or track captures the timeline mid-drag, without dropping. The report's
            // "dragTarget" says which track the clip would land on.
            if let drag = environment["OVERLAP_SNAPSHOT_DRAG"].flatMap(TimelineView.DebugDrag.init),
               let timeline = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap(findTimeline) }).first {
                timeline.debugBeginDrag(drag)
                // Let the tracks finish sliding into place.
                try? await Task.sleep(for: .milliseconds(600))
                timeline.displayIfNeeded()
                dragSummary = timeline.debugDragSummary
            }

            // OVERLAP_SNAPSHOT_COPYDRAG=1 ⌥-drags the top clip to just after itself and drops a copy there.
            var copyDrag: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_COPYDRAG"] != nil,
               let timeline = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap(findTimeline) }).first {
                copyDrag = await timeline.debugCopyDrag()
            }

            // OVERLAP_SNAPSHOT_EDIT=split parks the playhead at 5 s, splits there, and records every time the
            // player reports while the rebuilt composition swaps in. The playhead should never leave 5 s.
            var editTimes: [Double] = []
            if environment["OVERLAP_SNAPSHOT_EDIT"] == "split", let store = document?.store {
                store.playback.seek(to: Time(seconds: 5))
                try? await Task.sleep(for: .milliseconds(500))
                store.playback.reportedTimes = []
                store.splitAtPlayhead()
                try? await Task.sleep(for: .seconds(1))
                editTimes = store.playback.reportedTimes ?? []
                store.playback.reportedTimes = nil
            }

            // OVERLAP_SNAPSHOT_EDIT=move parks the playhead inside the video, nudges the video clip half a second
            // later, and samples the preview every 5 ms. Whenever the player has no frame to show, the still from
            // before the edit should be covering it.
            var moveDisplay: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_EDIT"] == "move", let store = document?.store,
               let preview = NSApplication.shared.windows.first(where: \.isVisible)?.contentView.flatMap({ find(PlayerLayerView.self, in: $0) }),
               let video = store.project.tracks.flatMap(\.clips).first(where: store.project.showsPicture),
               let track = store.project.location(ofClip: video.id).map({ store.project.tracks[$0.track].id }) {
                store.playback.seek(to: video.start + Time(seconds: 3))
                try? await Task.sleep(for: .seconds(1))
                store.moveClip(video.id, to: video.start + Time(seconds: 0.5), target: .existing(track))
                var samples: [(ready: Bool, stillShown: Bool)] = []
                for _ in 0..<200 {
                    try? await Task.sleep(for: .milliseconds(5))
                    samples.append(preview.debugDisplayState)
                }
                moveDisplay = [
                    "samples": samples.count,
                    "notReady": samples.filter { !$0.ready }.count,
                    "uncoveredGaps": samples.filter { !$0.ready && !$0.stillShown }.count,
                    "stillShown": samples.filter(\.stillShown).count,
                    "endsReady": samples.last.map { $0.ready && !$0.stillShown } ?? false,
                ]
            }

            // OVERLAP_SNAPSHOT_TITLEEDIT=<name> starts editing the title, types a name, then clicks the timeline
            // through the app's event queue. The edit should end, rename the file, and never widen the title.
            var titleEdit: [String: Any] = [:]
            if let name = environment["OVERLAP_SNAPSHOT_TITLEEDIT"], let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible),
               let titleView = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "title" })?.view,
               let timeline = window.contentView.flatMap({ find(TimelineView.self, in: $0) }) {
                let widthBefore = titleView.fittingSize.width
                store.beginTitleEdit()
                try? await Task.sleep(for: .milliseconds(300))
                let widthEditing = titleView.fittingSize.width
                let fieldHasFocus = window.firstResponder is NSText
                if let bitmap = titleView.bitmapImageRepForCachingDisplay(in: titleView.bounds) {
                    titleView.cacheDisplay(in: titleView.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-title-editing.png"))
                }
                store.titleDraft = name
                try? await Task.sleep(for: .milliseconds(100))
                let click = timeline.convert(CGPoint(x: timeline.bounds.midX, y: timeline.bounds.maxY - 20), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: click, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                titleEdit = [
                    "widthBefore": Double(widthBefore), "widthEditing": Double(widthEditing),
                    "fieldHadFocus": fieldHasFocus, "stillEditing": store.isEditingTitle,
                ]
            }

            // OVERLAP_SNAPSHOT_PINCH=1 pinches the timeline open three times just right of the start, which should
            // hold the start still, then three times in the middle, which should hold the time under the pointer.
            // Last it pinches past the zoom limit and zooms out from the store, which shouldn't pull toward the pinch.
            var pinch: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_PINCH"] != nil, let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible),
               let timeline = window.contentView.flatMap({ find(TimelineView.self, in: $0) }) {
                func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
                let startBefore = timeline.debugX(for: .zero).start
                for _ in 0..<3 { timeline.debugPinch(by: 1.4, atX: startBefore + 30); await settle() }
                let startAfter = timeline.debugX(for: .zero).start
                let middle = timeline.bounds.midX
                let startNow = timeline.debugX(for: .zero).start
                let pixels = store.pixelsPerSecond
                let underPointer = Time(seconds: Double(middle - startNow) / pixels)
                for _ in 0..<3 { timeline.debugPinch(by: 1.4, atX: middle); await settle() }
                let pointerAfter = timeline.debugX(for: underPointer).time
                for _ in 0..<30 { timeline.debugPinch(by: 1.4, atX: middle + 200); await settle() }
                let atLimit = store.pixelsPerSecond
                timeline.debugPinch(by: 1.4, atX: middle + 200)
                // The playhead is off screen by now, so a zoom from the store should hold the left edge.
                let leftBefore = timeline.debugX(for: .zero).leftEdge
                store.zoom(by: 0.5)
                await settle()
                pinch = [
                    "startBefore": Double(startBefore), "startAfterNearStart": Double(startAfter),
                    "pointerX": Double(middle), "pointerTimeAfter": Double(pointerAfter),
                    "atLimit": atLimit, "leftEdgeBeforeStoreZoom": leftBefore,
                    "leftEdgeAfterStoreZoom": timeline.debugX(for: .zero).leftEdge,
                    "playheadX": Double(timeline.debugX(for: store.playback.currentTime).time),
                ]
            }

            // OVERLAP_SNAPSHOT_RENAME=<name> renames the project the way committing the title does.
            if let name = environment["OVERLAP_SNAPSHOT_RENAME"], let store = document?.store {
                store.renameDocument(to: name)
                try? await Task.sleep(for: .seconds(1))
            }

            // OVERLAP_SNAPSHOT_RESIZE=1 drags the preview's bottom edge down in ten 10-point steps through the
            // window, recording the preview's height after each. Steady growth means the divider doesn't shake.
            var resizeHeights: [Double] = []
            if environment["OVERLAP_SNAPSHOT_RESIZE"] != nil,
               let window = NSApplication.shared.windows.first(where: \.isVisible),
               let preview = window.contentView.flatMap({ find(PlayerLayerView.self, in: $0) }) {
                let edge = preview.convert(preview.bounds, to: nil)
                // Focused, with events posted at real times, as a person's drag arrives.
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(300))
                let send = { (type: NSEvent.EventType, y: CGFloat) in
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: edge.midX, y: y), modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                }
                // Window coordinates run upward, so dragging down lowers y.
                send(.leftMouseDown, edge.minY)
                try? await Task.sleep(for: .milliseconds(40))
                for step in 1...10 {
                    send(.leftMouseDragged, edge.minY - CGFloat(step) * 10)
                    try? await Task.sleep(for: .milliseconds(40))
                    resizeHeights.append(Double(preview.frame.height))
                }
                send(.leftMouseUp, edge.minY - 100)
            }

            // OVERLAP_SNAPSHOT_PANELEND=1 scrolls the panel to its end before the captures below.
            if environment["OVERLAP_SNAPSHOT_PANELEND"] != nil, let content = NSApplication.shared.windows.first(where: \.isVisible)?.contentView {
                func scrollViews(in view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                for scroll in scrollViews(in: content) where scroll.frame.width < 400 {
                    if let document = scroll.documentView {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }

            for (index, window) in NSApplication.shared.windows.filter(\.isVisible).enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-\(index).png"))
            }

            // The preview's video layer can't be captured above, so render the same frame from the composition.
            if let item = document?.store.playback.player.currentItem {
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = item.videoComposition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                if let frame = try? await generator.image(at: item.currentTime()).image {
                    let bitmap = NSBitmapImageRep(cgImage: frame)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-frame.png"))
                }
            }

            // Where the video frame sits inside the preview: x, y, width, height, then the preview's width and height.
            var previewFrame: [Double] = []
            if let preview = NSApplication.shared.windows.first(where: \.isVisible)?.contentView.flatMap({ find(PlayerLayerView.self, in: $0) }) {
                let frame = preview.playerLayer.frame
                previewFrame = [frame.minX, frame.minY, frame.width, frame.height, preview.bounds.width, preview.bounds.height].map { Double($0) }
            }

            if let store = document?.store {
                let report: [String: Any] = [
                    "previewFrame": previewFrame,
                    "startTime": startTime,
                    "currentTime": store.playback.currentTime.seconds,
                    "isPlaying": store.playback.isPlaying,
                    "duration": store.playback.duration.seconds,
                    "tracks": store.project.tracks.map { $0.clips.count },
                    "hasVisualClips": store.project.hasVisualClips,
                    "waveforms": store.waveforms.count,
                    "thumbnails": store.thumbnails.count,
                    "playerStatus": store.playback.player.currentItem?.status.rawValue ?? -1,
                    "playerError": store.playback.player.currentItem?.error?.localizedDescription ?? "",
                    "resizeHeights": resizeHeights,
                    "editTimes": editTimes,
                    "crossfade": crossfadeReport,
                    "dragTarget": dragSummary,
                    "menu": menuLines,
                    "moveDisplay": moveDisplay,
                    "speedPreview": speedReport,
                    "handle": handleReport,
                    "textEdit": textEditReport,
                    "cropClick": cropClickReport,
                    "pictureMenu": pictureMenu,
                    "copyDrag": copyDrag,
                    "export": exportReport,
                    "perf": perfReport,
                    "windowResize": windowResize,
                    "move": moveReport,
                    "popUp": popUpReport,
                    "savePanel": savePanelReport,
                    "isolation": isolationReport,
                    "firstResponder": NSApplication.shared.windows.first(where: \.isVisible)?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
                    "storeSaving": document?.store.isSaving ?? false,
                    "documentEdited": document?.isDocumentEdited ?? false,
                    "windowEdited": NSApplication.shared.windows.first(where: \.isVisible)?.isDocumentEdited ?? false,
                    "windowOnScreen": NSApplication.shared.windows.first(where: \.isVisible)?.occlusionState.contains(.visible) ?? false,
                    "appActive": NSApplication.shared.isActive,
                    "pixels": pixelsReport,
                    "loops": loopsReport,
                    "loopPlay": loopPlayReport,
                    "guides": guidesReport,
                    "canvasResize": canvasResizeReport,
                    "canvasDrag": canvasDragReport,
                    "edited": editedSamples,
                    "titleSeek": titleSeekReport,
                    "addColor": addColorReport,
                    "windowTitle": store.windowTitle,
                    "titleEdit": titleEdit,
                    "pinch": pinch,
                    "fileURL": document?.fileURL?.path ?? "",
                ]
                let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: URL(filePath: "\(prefix).json"))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private static func findTimeline(in view: NSView) -> TimelineView? {
        find(TimelineView.self, in: view)
    }

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
#endif
