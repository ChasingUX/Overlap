import SwiftUI

/// What the timeline draws. Rebuilt by SwiftUI whenever the store's observed values change.
struct TimelineSnapshot {
    var project: Project
    var selection: Set<UUID>
    /// The incoming clip of the crossfade shown in the Transitions tab.
    var selectedTransition: UUID?
    var currentTime: Time
    var isPlaying: Bool
    var pixelsPerSecond: Double
    var waveforms: [UUID: Waveform]
    var isolatedWaveforms: [UUID: Waveform]
    var thumbnails: [UUID: CGImage]
    var filmstrips: [UUID: Filmstrip]
    var loopHighlight: LoopHighlight?
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
/// Title styles and background swatches from the panel travel the same way.
enum TimelineDrag {
    static let prefix = "Overlap asset "
    static let titlePrefix = "Overlap title "
    static let fillPrefix = "Overlap background "

    static func payload(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func payload(for style: TitleStyle) -> String {
        titlePrefix + style.rawValue
    }

    static func payload(for fill: BackgroundFill) -> String {
        let data = (try? JSONEncoder().encode(fill)) ?? Data()
        return fillPrefix + data.base64EncodedString()
    }

    static func assetID(from string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }

    static func titleStyle(from string: String) -> TitleStyle? {
        guard string.hasPrefix(titlePrefix) else { return nil }
        return TitleStyle(rawValue: String(string.dropFirst(titlePrefix.count)))
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
            currentTime: store.playback.currentTime,
            isPlaying: store.playback.isPlaying,
            pixelsPerSecond: store.pixelsPerSecond,
            waveforms: store.waveforms,
            isolatedWaveforms: store.isolatedWaveforms,
            thumbnails: store.thumbnails,
            filmstrips: store.filmstrips,
            loopHighlight: store.highlightedLoop
        )
    }
}
