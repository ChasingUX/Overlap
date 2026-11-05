import SwiftUI

/// Speed for the selected clips: a slider from 25% to 400% that catches at the usual speeds, and pitch correction
/// for clips with sound. The timeline shows a dragged speed at once; it's committed as one change on release.
struct SpeedSection: View {
    let store: ProjectStore

    /// Where the slider catches, with a tap on a Force Touch trackpad.
    nonisolated static let usualSpeeds = [0.5, 1, 1.5, 2]

    private var speed: Double {
        store.selectedClips.first?.speed ?? 1
    }

    /// The speed at a place on the slider. A usual speed comes back exactly, not a hair off, once it's been
    /// through the slider's powers of two.
    nonisolated static func speed(atSliderValue value: Double) -> Double {
        let speed = exp2(value)
        return usualSpeeds.first { abs($0 - speed) < 1e-9 } ?? speed
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
                onChange: { store.speedPreview = Self.speed(atSliderValue: $0) },
                onCommit: { store.setSpeed(Self.speed(atSliderValue: $0)) },
                onEnd: { store.speedPreview = nil },
                detents: Self.usualSpeeds.map(log2)
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
            .panelNoteLayout()
    }
}

/// A short line of help under a group of controls.
struct PanelNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .panelNoteLayout()
    }
}

extension View {
    /// Help text under controls: wrapping to its lines, flush with the boxes' left edge rather than centered under
    /// them, and set a little apart from them.
    func panelNoteLayout() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}
