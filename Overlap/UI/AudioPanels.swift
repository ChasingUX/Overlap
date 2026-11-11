import SwiftUI

// MARK: - Volume

/// A volume slider in decibels with 0 dB in the middle: the left half fades down to silence (−∞ dB), the right
/// half boosts up to +12 dB. Double-click resets to 0 dB.
struct DecibelSlider: View {
    let title: String
    /// Linear gain, 1 = 0 dB.
    let volume: Double
    /// Called while dragging, for changes that can be heard without a rebuild.
    var onDrag: ((Double) -> Void)?
    let onCommit: (Double) -> Void

    static let silence = -60.0
    static let boost = 12.0

    /// Where a level sits along the slider, 0 to 1.
    static func position(ofGain gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let decibels = 20 * log10(gain)
        return decibels <= 0
            ? 0.5 * max(0, decibels - silence) / -silence
            : 0.5 + 0.5 * min(decibels, boost) / boost
    }

    static func decibels(atPosition position: Double) -> Double {
        position <= 0.5 ? silence * (1 - position / 0.5) : boost * (position - 0.5) / 0.5
    }

    static func gain(atPosition position: Double) -> Double {
        position <= 0 ? 0 : pow(10, decibels(atPosition: position) / 20)
    }

    var body: some View {
        BoxSlider(
            title: title,
            value: Self.position(ofGain: volume),
            range: 0...1,
            format: { position in
                guard position > 0 else { return "−∞ dB" }
                let decibels = (Self.decibels(atPosition: position) * 10).rounded() / 10
                return decibels == 0 ? "0.0 dB" : String(format: "%+.1f dB", decibels)
            },
            defaultValue: 0.5,
            onChange: { onDrag?(Self.gain(atPosition: $0)) },
            onCommit: { onCommit(Self.gain(atPosition: $0)) }
        )
    }
}

// MARK: - Panels

/// The Audio tab with a clip selected: its volume, its track, and its speed for sound-only clips. Fades are
/// added from the Clip and right-click menus and sized by dragging their handles on the timeline.
struct AudioClipPanel: View {
    let store: ProjectStore

    var body: some View {
        ClipPanel(title: "Audio") {
            PanelGroup(title: store.selectedClips.count > 1 ? "Clips" : "Clip") {
                DecibelSlider(title: "Volume", volume: store.selectedClips.first?.volume ?? 1) { store.setClipVolume($0) }
                // Clips with a picture set their speed in the Video tab.
                if !store.applicableTabs.contains(.video) {
                    SpeedSection(store: store)
                }
                if store.selectedClips.contains(where: store.project.playsSound) {
                    ToggleRow(title: "Isolate voice", isOn: store.selectedClips.contains(where: \.isolatesVoice)) {
                        store.setIsolatesVoice($0)
                    }
                    .help("Keeps speech and takes out background noise, music and room echo")
                }
            }
            TrackSection(store: store)
        }
    }
}

/// The Audio tab with no sound selected: the master mix.
/// The whole mix's volume and loudness, or, with nothing on the timeline that plays sound, a note saying so.
struct MasterPanel: View {
    let store: ProjectStore

    var body: some View {
        if !store.project.hasSound {
            PlaceholderPanel(icon: .audio, title: "No audio", message: "Add a sound file or a video with sound to the timeline.",
                             action: (title: "Import Audio…", perform: { store.presentAudioImportPanel() }))
        } else {
            mix
        }
    }

    private var mix: some View {
        ClipPanel(title: "Audio") {
            PanelGroup(title: "Master") {
                DecibelSlider(title: "Volume", volume: store.project.masterVolume,
                              onDrag: { store.playback.setMasterVolume($0) },
                              onCommit: { store.setMasterVolume($0) })
                ToggleRow(title: "Normalize loudness", isOn: store.project.normalizesLoudness) {
                    store.setNormalizesLoudness($0)
                }
                .help("Exports at the level YouTube and streaming services play at: −14 LUFS, with peaks under −1 dBTP")
            }
        }
    }
}

/// The selected crossfade: its length, its curve, how the picture changes when both clips show one, and giving
/// every crossfade the same curve. Its length slides the later clip, as dragging it would.
struct TransitionPanel: View {
    let store: ProjectStore

    /// The longest the slider reaches, unless the crossfade is already longer.
    private static let usualLongest = 5.0

    var body: some View {
        if let crossfade = store.selectedCrossfade {
            ClipPanel(title: "Transitions") {
                PanelGroup(title: "Crossfade") {
                    duration(of: crossfade)
                    // Set apart from the slider, as their names under them set them apart from what follows.
                    CrossfadeCurveTiles(selected: crossfade.curve) { store.setCrossfadeCurve($0) }
                        .padding(.top, 10)
                }
                // How the picture changes, only when both clips show one.
                if [crossfade.outgoing, crossfade.incoming].allSatisfy(store.project.showsPicture) {
                    PanelGroup(title: "Picture") {
                        OptionRow(options: VideoTransition.allCases.map { ($0.name, $0) }, selected: crossfade.videoStyle) {
                            store.setCrossfadeVideoStyle($0)
                        }
                    }
                }
                // Only worth offering with other crossfades to change.
                if store.otherCrossfadeCount > 0 {
                    Button { store.useCrossfadeCurveForAll() } label: {
                        Text("Use for all crossfades")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BoxButtonStyle())
                    .help("Give every crossfade this curve, and start new ones with it")
                }
            }
        } else {
            PlaceholderPanel(icon: .transitions, title: "Select a crossfade",
                             message: "Overlap two clips on one track, then click where they overlap.")
        }
    }

    /// Lengthens or shortens the crossfade by sliding the later clip, as far as the clips around allow.
    @ViewBuilder private func duration(of crossfade: Crossfade) -> some View {
        let length = crossfade.range.duration.seconds
        let shortest = Project.shortestCrossfade.seconds
        let longest = store.project.longestCrossfade(into: crossfade.incoming.id)?.seconds ?? length
        let top = max(length, min(longest, Self.usualLongest))
        if top - shortest > 0.05 {
            BoxSlider(title: "Duration", value: length, range: shortest...top, format: { String(format: "%.1f s", $0) },
                      onCommit: { store.setCrossfadeDuration(Time(seconds: $0)) })
        } else {
            ValueRow(title: "Duration", value: String(format: "%.1f s", length))
        }
    }
}

/// The offered curves as tiles, each drawing a crossfade on it: the incoming clip rising bright as the outgoing
/// one falls dim. A curve that isn't offered any more leaves none chosen.
private struct CrossfadeCurveTiles: View {
    let selected: Curve
    let onSelect: (Curve) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Curve.presets, id: \.self) { curve in
                VStack(alignment: .leading, spacing: 5) {
                    Swatch(isRound: false, isSelected: curve == selected, name: curve.name, action: { onSelect(curve) }) {
                        CrossfadeCurve(curve: curve)
                    }
                    .frame(height: 56)
                    PanelLabel(curve.name)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

/// One curve's two sides, drawn from the gain the crossfade plays by, as the timeline draws them.
private struct CrossfadeCurve: View {
    let curve: Curve

    var body: some View {
        SwiftUI.Canvas { context, size in
            let area = CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24)
            for rising in [false, true] {
                var path = Path()
                for step in 0...48 {
                    let progress = Double(step) / 48
                    let gain = curve.gain(at: rising ? progress : 1 - progress)
                    let point = CGPoint(x: area.minX + progress * area.width, y: area.maxY - gain * area.height)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.primary.opacity(rising ? 0.9 : 0.35)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
