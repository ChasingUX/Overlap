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

// MARK: - Curves

/// The six curve presets and Custom, three to a line in one box; the chosen one sits on a raised pill.
struct CurvePresetGrid: View {
    let selected: Curve
    let onSelect: (Curve) -> Void

    static let defaultCustom = Curve.custom(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    var body: some View {
        // Every custom curve shows as Custom; choosing Custom again keeps the one already drawn.
        OptionGrid(options: Curve.presets.map { ($0.name, $0) } + [("Custom", Self.defaultCustom)],
                   selected: selected.isCustom ? Self.defaultCustom : selected) { curve in
            if curve.isCustom, selected.isCustom { return }
            onSelect(curve)
        }
    }
}

/// Draws a crossfade's curve, the incoming side bright and the outgoing side mirrored and dim, and for a custom
/// curve lets you drag its two bezier handles. A drag is one undoable change.
struct CurveEditor: View {
    let curve: Curve
    let onCommit: (Curve) -> Void

    @State private var draft: Curve?
    @State private var dragging: Int?
    @State private var size: CGSize = .zero

    private let inset: CGFloat = 10

    private var shown: Curve { draft ?? curve }

    var body: some View {
        SwiftUI.Canvas { context, size in
            let area = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            context.stroke(Path(roundedRect: area, cornerRadius: 3), with: .color(.primary.opacity(0.08)))

            context.stroke(path(in: area) { shown.gain(at: 1 - $0) }, with: .color(.primary.opacity(0.35)), lineWidth: 1.5)
            context.stroke(path(in: area) { shown.gain(at: $0) }, with: .color(.primary.opacity(0.9)), lineWidth: 1.5)

            if case let .custom(x1, y1, x2, y2) = shown {
                let first = point(x1, y1, in: area)
                let second = point(x2, y2, in: area)
                var arms = Path()
                arms.move(to: point(0, 0, in: area))
                arms.addLine(to: first)
                arms.move(to: point(1, 1, in: area))
                arms.addLine(to: second)
                context.stroke(arms, with: .color(.accentColor.opacity(0.8)), lineWidth: 1)
                for handle in [first, second] {
                    context.fill(Path(ellipseIn: CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)), with: .color(.accentColor))
                }
            }
        }
        .frame(height: 120)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(handleDrag)
        .accessibilityLabel("Curve")
        .overlay(alignment: .bottomLeading) {
            // The two sides, named in the box's corner.
            HStack(spacing: 10) {
                legend("In", opacity: 0.9)
                legend("Out", opacity: 0.35)
            }
            .padding(.leading, inset + 4)
            .padding(.bottom, inset + 2)
            .allowsHitTesting(false)
        }
        .background(ControlBox())
    }

    private func legend(_ text: String, opacity: Double) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(Color.primary.opacity(opacity)).frame(width: 10, height: 2)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func path(in area: CGRect, _ gain: (Double) -> Double) -> Path {
        var path = Path()
        for step in 0...60 {
            let t = Double(step) / 60
            let next = point(t, gain(t), in: area)
            if step == 0 { path.move(to: next) } else { path.addLine(to: next) }
        }
        return path
    }

    private func point(_ x: Double, _ y: Double, in area: CGRect) -> CGPoint {
        CGPoint(x: area.minX + CGFloat(x) * area.width, y: area.maxY - CGFloat(y) * area.height)
    }

    /// Picks up the nearer handle and moves it, keeping both inside the square so the curve stays a function of time.
    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard case let .custom(x1, y1, x2, y2) = shown else { return }
                let area = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
                let x = Double((drag.location.x - area.minX) / area.width).clamped(to: 0...1)
                let y = Double((area.maxY - drag.location.y) / area.height).clamped(to: 0...1)
                if dragging == nil {
                    let first = hypot(drag.startLocation.x - point(x1, y1, in: area).x, drag.startLocation.y - point(x1, y1, in: area).y)
                    let second = hypot(drag.startLocation.x - point(x2, y2, in: area).x, drag.startLocation.y - point(x2, y2, in: area).y)
                    dragging = first <= second ? 1 : 2
                }
                draft = dragging == 1 ? .custom(x1: x, y1: y, x2: x2, y2: y2) : .custom(x1: x1, y1: y1, x2: x, y2: y)
            }
            .onEnded { _ in
                if let draft { onCommit(draft) }
                draft = nil
                dragging = nil
            }
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
struct MasterPanel: View {
    let store: ProjectStore

    var body: some View {
        ClipPanel(title: "Audio") {
            PanelGroup(title: "Master") {
                DecibelSlider(title: "Volume", volume: store.project.masterVolume,
                              onDrag: { store.playback.setMasterVolume($0) },
                              onCommit: { store.setMasterVolume($0) })
                ToggleRow(title: "Normalize loudness", isOn: store.project.normalizesLoudness) {
                    store.setNormalizesLoudness($0)
                }
                if store.project.normalizesLoudness {
                    PanelNote(text: "Exports are brought to −14 LUFS, the level YouTube and streaming services play at, with peaks kept under −1 dBTP.")
                }
            }
            PanelNote(text: "Select an audio clip, or a video with sound, for its own volume.")
        }
    }
}

/// The selected crossfade: its length, its curve, and making that curve the default.
struct TransitionPanel: View {
    let store: ProjectStore

    var body: some View {
        if let crossfade = store.selectedCrossfade {
            ClipPanel(title: "Transitions") {
                PanelGroup(title: "Crossfade") {
                    ValueRow(title: "Duration", value: String(format: "%.2f s", crossfade.range.duration.seconds))
                    CurvePresetGrid(selected: crossfade.curve) { store.setCrossfadeCurve($0) }
                    CurveEditor(curve: crossfade.curve) { store.setCrossfadeCurve($0) }
                    if [crossfade.outgoing, crossfade.incoming].allSatisfy(store.project.showsPicture) {
                        OptionRow(title: "Video", options: VideoTransition.allCases.map { ($0.name, $0) }, selected: crossfade.videoStyle) {
                            store.setCrossfadeVideoStyle($0)
                        }
                    }
                    Button("Use as Default for New Crossfades") { store.useCrossfadeCurveAsDefault() }
                        .buttonStyle(BoxButtonStyle())
                        .disabled(store.project.defaultCrossfadeCurve == crossfade.curve)
                }
            }
        } else {
            PlaceholderPanel(icon: .transitions, title: "Select a crossfade",
                             message: "Overlap two clips on one track, then click where they overlap.")
        }
    }
}
