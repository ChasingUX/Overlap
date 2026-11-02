import SwiftUI

/// The playback controls bar: time on the left, transport in the center, zoom on the right.
struct TransportBar: View {
    @Bindable var store: ProjectStore

    var body: some View {
        ZStack {
            HStack {
                HStack(spacing: 5) {
                    Text(store.playback.currentTime.clock)
                        .foregroundStyle(.primary)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text(store.playback.duration.clock)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer()
                HStack(spacing: 8) {
                    zoomButton(.zoomOut, label: "Zoom out", factor: 1 / 1.5)
                    Slider(value: zoom, in: log(ProjectStore.pixelsPerSecondRange.lowerBound)...log(ProjectStore.pixelsPerSecondRange.upperBound))
                        .controlSize(.small)
                        .tint(Color(nsColor: Theme.sliderTint))
                        .frame(width: 110)
                        .accessibilityLabel("Timeline zoom")
                    zoomButton(.zoomIn, label: "Zoom in", factor: 1.5)
                }
            }
            HStack(spacing: 20) {
                transportButton(.goToStart, label: "Go to start") { store.playback.seek(to: .zero) }
                transportButton(store.playback.isPlaying ? .pause : .play, label: store.playback.isPlaying ? "Pause" : "Play", size: 18) {
                    store.playback.togglePlay()
                }
                transportButton(.goToEnd, label: "Go to end") { store.playback.seek(to: store.project.duration) }
            }
            // With nothing on the timeline there's nothing to play.
            .disabled(store.project.duration == .zero)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(Color(nsColor: Theme.chrome))
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// The slider works on a log scale so each step feels like the same amount of zoom.
    private var zoom: Binding<Double> {
        Binding(
            get: { log(store.pixelsPerSecond) },
            set: { store.pixelsPerSecond = exp($0) }
        )
    }

    private func zoomButton(_ icon: AppIcon, label: String, factor: Double) -> some View {
        Button {
            store.zoom(by: factor)
        } label: {
            icon.image
                .font(.system(size: 11, weight: .regular))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(label)
        .accessibilityLabel(label)
    }

    private func transportButton(_ icon: AppIcon, label: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.image
                .font(.system(size: size))
        }
        .buttonStyle(TransportButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Play, pause and skip: while pressed, a gray rounded tile appears behind the icon and the button eases back a little.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TransportButton(configuration: configuration)
    }
}

private struct TransportButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
