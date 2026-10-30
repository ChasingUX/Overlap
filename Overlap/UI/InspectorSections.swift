import SwiftUI

/// Speed for the selected clips: a slider from 25% to 400%, quick choices, and pitch correction for clips with
/// sound. The timeline shows a dragged speed at once; it's committed as one change on release.
struct SpeedSection: View {
    let store: ProjectStore

    private static let quickSpeeds = [0.5, 1, 1.5, 2]

    private var speed: Double {
        store.selectedClips.first?.speed ?? 1
    }

    var body: some View {
        VStack(spacing: 6) {
            // The slider works in powers of two, so 50% and 200% sit the same distance either side of 100%.
            BoxSlider(
                title: "Speed",
                value: log2(speed),
                range: log2(Clip.speedRange.lowerBound)...log2(Clip.speedRange.upperBound),
                format: { "\(Int((exp2($0) * 100).rounded()))%" },
                defaultValue: 0,
                onChange: { store.speedPreview = exp2($0) },
                onCommit: { store.setSpeed(exp2($0)) },
                onEnd: { store.speedPreview = nil }
            )
            OptionRow(
                options: Self.quickSpeeds.map { ("\($0.formatted(.number.precision(.fractionLength(0...1))))×", $0) },
                selected: Self.quickSpeeds.first { abs($0 - speed) < 0.001 },
                onSelect: { store.setSpeed($0) }
            )
            if store.selectedClips.contains(where: store.project.playsSound) {
                ToggleRow(title: "Keep pitch", isOn: store.selectedClips.first?.preservesPitch ?? true) {
                    store.setPreservesPitch($0)
                }
            }
        }
    }
}

/// Volume, mute, solo and lock for the tracks holding the selected clips. The track's volume applies to every
/// clip on it, on top of each clip's own volume.
struct TrackSection: View {
    let store: ProjectStore

    var body: some View {
        let ids = store.selectedTrackIDs
        let tracks = store.project.tracks.filter { ids.contains($0.id) }
        PanelGroup(title: tracks.count > 1 ? "Tracks" : "Track") {
            DecibelSlider(title: "Volume", volume: tracks.first?.volume ?? 1) { store.setTrackVolume($0) }
            ForEach([("Mute", \Track.isMuted), ("Solo", \Track.isSoloed), ("Lock", \Track.isLocked)], id: \.0) { title, flag in
                ToggleRow(title: title, isOn: tracks.contains { $0[keyPath: flag] }) {
                    store.setTrackFlag(flag, to: $0, onTracks: ids)
                }
            }
        }
    }
}

/// A small icon button that shows a soft gray tile on hover, like the rail, and a darker one while pressed.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.1 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHovered = $0 }
        }
    }
}

/// A short note for settings that arrive in a later milestone.
struct ComingLater: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
