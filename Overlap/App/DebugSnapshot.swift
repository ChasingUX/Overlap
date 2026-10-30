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
            // OVERLAP_SNAPSHOT_TAB=master opens the Audio tab with nothing selected, showing the master volume.
            if environment["OVERLAP_SNAPSHOT_TAB"] == "master", let store = document?.store {
                store.select([])
                store.activeTab = .audio
                try? await Task.sleep(for: .milliseconds(300))
            }
            // OVERLAP_SNAPSHOT_TAB=video or audio selects the top track's first clip and opens that tab.
            if let tab = environment["OVERLAP_SNAPSHOT_TAB"].flatMap({ name in PanelTab.allCases.first { $0.title.lowercased() == name } }),
               let store = document?.store, let clip = store.project.tracks.last?.clips.first {
                store.activeTab = tab
                store.select([clip.id])
                try? await Task.sleep(for: .milliseconds(300))
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
                let send = { (type: NSEvent.EventType, y: CGFloat) in
                    if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: edge.midX, y: y), modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                }
                // Window coordinates run upward, so dragging down lowers y.
                send(.leftMouseDown, edge.minY)
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
