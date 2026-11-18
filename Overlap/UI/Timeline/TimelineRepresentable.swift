import SwiftUI

/// What the timeline draws. Rebuilt by SwiftUI whenever the store's observed values change.
struct TimelineSnapshot {
    var project: Project
    var selection: Set<UUID>
    /// The incoming clip of the crossfade shown in the Transitions tab.
    var selectedTransition: UUID?
    /// The zoom shown in the Zoom tab.
    var selectedZoom: ProjectStore.ZoomSelection?
    var currentTime: Time
    var isPlaying: Bool
    var pixelsPerSecond: Double
    var waveforms: [UUID: Waveform]
    var isolatedWaveforms: [UUID: Waveform]
    var thumbnails: [UUID: CGImage]
    var filmstrips: [UUID: Filmstrip]
    var loopHighlight: LoopHighlight?
    var transcriptMarks: TranscriptMarks?
    /// The captions track selected, whose captions all show selected.
    var selectedCaptions: UUID?
    /// Music kept low under speech, which its waveform shows.
    var ducking: Ducking?
}

/// While the Transcript tab shows: per clip, the stretches Remove Pauses and Fillers would take out and those the
/// selected words cover, in the clip's source seconds, so they move with the clip.
struct TranscriptMarks: Equatable {
    var removable: [UUID: [ClosedRange<Double>]]
    var selected: [UUID: [ClosedRange<Double>]]
}

/// A loop pointed at in the Video tab: the stretch of its clip's source, in seconds, to shade on the clip.
struct LoopHighlight: Equatable {
    var clip: UUID
    var start: Double
    var end: Double
}

/// Drags from the Media tab carry the asset's ID as a prefixed string. The prefix has a space so the string
/// isn't a valid URL: otherwise the drag also advertises itself as a URL, and file drop targets (like the
/// Media tab's own) light up for it.
/// Background swatches from the panel travel the same way.
enum TimelineDrag {
    static let prefix = "Overlap asset "
    static let fillPrefix = "Overlap background "

    static func payload(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func payload(for fill: BackgroundFill) -> String {
        let data = (try? JSONEncoder().encode(fill)) ?? Data()
        return fillPrefix + data.base64EncodedString()
    }

    static func assetID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }

    static func fill(from string: String) -> BackgroundFill? {
        guard string.hasPrefix(fillPrefix), let data = Data(base64Encoded: String(string.dropFirst(fillPrefix.count))) else { return nil }
        return try? JSONDecoder().decode(BackgroundFill.self, from: data)
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore

    func makeNSView(context: Context) -> TimelineView {
        TimelineView(store: store, snapshot: snapshot)
    }

    func updateNSView(_ view: TimelineView, context: Context) {
        view.snapshot = snapshot
    }

    private var snapshot: TimelineSnapshot {
        TimelineSnapshot(
            project: store.timelineProject,
            selection: store.selection,
            selectedTransition: store.selectedTransition,
            selectedZoom: store.selectedZoom,
            currentTime: store.playback.currentTime,
            isPlaying: store.playback.isPlaying,
            pixelsPerSecond: store.pixelsPerSecond,
            waveforms: store.waveforms,
            isolatedWaveforms: store.isolatedWaveforms,
            thumbnails: store.thumbnails,
            filmstrips: store.filmstrips,
            loopHighlight: store.highlightedLoop,
            transcriptMarks: store.transcriptMarks,
            selectedCaptions: store.selectedCaptions,
            ducking: store.ducking
        )
    }
}
