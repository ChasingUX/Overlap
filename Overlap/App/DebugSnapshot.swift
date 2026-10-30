#if DEBUG
import AppKit
import AVFoundation

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
            // a shadow over a gradient, inside a padded frame, with a title over it. The playhead moves to 2 s.
            if environment["OVERLAP_SNAPSHOT_DEMO"] == "pip", let store = document?.store {
                store.apply("Demo") { project in
                    project.background = BackgroundFill.gradients[0]
                    project.frame = PictureFrame(padding: 0.06, shadow: 60, corners: 0.03)
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

            // OVERLAP_SNAPSHOT_EDIT=removeVideo deletes every video clip, then samples the preview's height and the
            // top track's height every 30 ms. Both should change over several samples, and the timeline should be
            // the same view afterward.
            var transition: [String: Any] = [:]
            if environment["OVERLAP_SNAPSHOT_EDIT"] == "removeVideo", let store = document?.store,
               let window = NSApplication.shared.windows.first(where: \.isVisible), let content = window.contentView,
               let preview = find(PlayerLayerView.self, in: content), let timeline = find(TimelineView.self, in: content) {
                let videoClips = store.project.tracks.flatMap(\.clips).filter(store.project.showsPicture).map(\.id)
                store.select(Set(videoClips))
                store.deleteSelection()
                var previewHeights: [Double] = []
                var rowHeights: [Double] = []
                var timelineTops: [Double] = []
                var coveredWidths: [Double] = []
                // OVERLAP_SNAPSHOT_MIDWAY=<sample> also captures the window partway through, as `<prefix>-mid.png`.
                let midway = environment["OVERLAP_SNAPSHOT_MIDWAY"].flatMap(Int.init)
                for sample in 0..<70 {
                    try? await Task.sleep(for: .milliseconds(8))
                    if sample == midway, let view = window.contentView?.superview,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(prefix)-mid.png"))
                    }
                    previewHeights.append(Double(preview.frame.height))
                    rowHeights.append(timeline.debugTopRowHeight)
                    // The timeline's top edge, measured down from the top of the window's content.
                    let frame = timeline.convert(timeline.bounds, to: nil)
                    timelineTops.append(Double(content.bounds.height - frame.maxY))
                    coveredWidths.append(timeline.debugCoveredWidth)
                }
                transition = [
                    "previewHeights": previewHeights,
                    "rowHeights": rowHeights,
                    "timelineTops": timelineTops,
                    "coveredWidths": coveredWidths,
                    "timelineLeft": Double(timeline.convert(timeline.bounds, to: nil).minX),
                    "timelineWidth": Double(timeline.bounds.width),
                    "sameTimeline": find(TimelineView.self, in: content) === timeline,
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
                    "transition": transition,
                    "crossfade": crossfadeReport,
                    "dragTarget": dragSummary,
                    "menu": menuLines,
                    "moveDisplay": moveDisplay,
                    "speedPreview": speedReport,
                    "handle": handleReport,
                    "textEdit": textEditReport,
                    "export": exportReport,
                    "isolation": isolationReport,
                    "windowTitle": store.windowTitle,
                    "titleEdit": titleEdit,
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
