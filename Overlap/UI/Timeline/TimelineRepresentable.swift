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
    var heightScale: Double
    /// How much of the timeline's left side the rail and panel cover. Audio-only they run the full height, over
    /// the timeline, and its content starts after them.
    var coveredWidth: CGFloat = 0
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

/// The timeline with its track heights (1.2× with a preview, 1.6× audio-only, where it fills the window) and the
/// width the rail and panel cover. SwiftUI steps both through the window's own layout animation one frame at a
/// time (it does this for views like this one, not for AppKit views), so the tracks and their content move in
/// step with the preview and panel.
struct AnimatedTimeline: View, @preconcurrency Animatable {
    let store: ProjectStore
    var heightScale: Double
    var coveredWidth: CGFloat

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(heightScale, coveredWidth) }
        set {
            heightScale = newValue.first
            coveredWidth = newValue.second
        }
    }

    var body: some View {
        TimelineRepresentable(store: store, heightScale: heightScale, coveredWidth: coveredWidth)
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let store: ProjectStore
    var heightScale: Double
    var coveredWidth: CGFloat

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
            heightScale: heightScale,
            coveredWidth: coveredWidth
        )
    }
}
