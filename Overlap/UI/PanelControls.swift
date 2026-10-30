import SwiftUI

/// The panel's controls. Each sits in its own rounded box, with its label on the left.
enum PanelMetrics {
    static let boxHeight: CGFloat = 38
    static let boxRadius: CGFloat = 10
    static let insidePadding: CGFloat = 12
    /// Chosen options sit this far in from the box's edges, with concentric corners.
    static let pillInset: CGFloat = 5
    static let pillRadius: CGFloat = boxRadius - pillInset
}

/// A heading, then the group's controls.
struct PanelGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(spacing: 6) {
                content
            }
        }
    }
}

/// The rounded box every control sits in.
struct ControlBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous)
            .fill(Color(nsColor: Theme.controlBox))
    }
}

/// A box with a label on the left and whatever sets it on the right.
struct ControlRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 13))
        .padding(.leading, PanelMetrics.insidePadding)
        .padding(.trailing, PanelMetrics.pillInset + 2)
        .frame(height: PanelMetrics.boxHeight)
        .background(ControlBox())
    }
}

/// A label and a read-only value.
struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        ControlRow(title: title) {
            Text(value)
                .monospacedDigit()
                .padding(.trailing, PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
        }
    }
}

/// A label and a switch.
struct ToggleRow: View {
    let title: String
    let isOn: Bool
    var isEnabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        ControlRow(title: title) {
            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!isEnabled)
        }
    }
}

/// A few choices as plain words; the chosen one sits on a raised pill. With a title the choices sit at the
/// right; without one they share the box's width.
struct OptionRow<Value: Equatable>: View {
    var title: String?
    let options: [(label: String, value: Value)]
    let selected: Value?
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, PanelMetrics.insidePadding - PanelMetrics.pillInset)
                Spacer(minLength: 8)
            }
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button(option.label) { onSelect(option.value) }
                    .buttonStyle(OptionButtonStyle(isSelected: option.value == selected, fillsWidth: title == nil))
            }
        }
        .font(.system(size: 13))
        .padding(PanelMetrics.pillInset)
        .frame(height: PanelMetrics.boxHeight)
        .background(ControlBox())
    }
}

/// One choice in an option row or grid.
struct OptionButtonStyle: ButtonStyle {
    let isSelected: Bool
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: PanelMetrics.boxHeight - PanelMetrics.pillInset * 2)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    ChosenPill()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.pillRadius))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The raised pill behind a chosen option.
struct ChosenPill: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.pillRadius, style: .continuous)
            .fill(Color(nsColor: Theme.controlChosen))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
    }
}

/// A whole-box button, for actions like making a curve the default.
struct BoxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BoxButton(configuration: configuration)
    }

    private struct BoxButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: PanelMetrics.boxHeight)
                .background(
                    RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous)
                        .fill(Color(nsColor: isEnabled && (isHovered || configuration.isPressed) ? Theme.controlFill : Theme.controlBox))
                )
                .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.boxRadius))
                .onHover { isHovered = $0 }
        }
    }
}

/// A slider that is its whole box. The filled part is a lighter box that ends in a small handle; faint ticks mark
/// the rest of the track, and the value sits at the right. The track runs the box's full width, so a middle value
/// sits in the middle; the handle fades out as it passes under the value rather than cross the number.
/// The fill can end short of the label, which reads over the track. Dragging on the fill changes the value by
/// how far the pointer moves; a click past the handle jumps there first. Double-click resets it. A drag is one
/// change, on release.
struct BoxSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var defaultValue: Double?
    /// Called as the value moves, for previews.
    var onChange: ((Double) -> Void)?
    /// Called on release when the value changed.
    let onCommit: (Double) -> Void
    /// Called on every release, changed or not, after `onCommit`.
    var onEnd: (() -> Void)?

    @State private var draft: Double?
    @State private var dragStart: Double?
    @State private var valueWidth: CGFloat = 0

    private static let tickCount = 7
    private var span: Double { range.upperBound - range.lowerBound }
    private var shown: Double { draft ?? value.clamped(to: range) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // At its lowest the fill is just wide enough to hold the handle.
            let minimum = min(width, 22)
            let track = max(1, width - 2 - minimum)
            let fill = minimum + CGFloat((shown - range.lowerBound) / span) * track
            let valueStart = width - PanelMetrics.insidePadding - valueWidth - 8
            ZStack(alignment: .leading) {
                ControlBox()
                ForEach(1...Self.tickCount, id: \.self) { index in
                    let x = minimum + track * CGFloat(index) / CGFloat(Self.tickCount + 1)
                    if x > fill + 6, x < valueStart {
                        Capsule()
                            .fill(Color(nsColor: Theme.controlTick))
                            .frame(width: 1.5, height: 9)
                            .offset(x: x)
                    }
                }
                RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous)
                    .fill(Color(nsColor: Theme.controlFill))
                    .frame(width: fill)
                Capsule()
                    .fill(Color(nsColor: Theme.controlHandle))
                    .frame(width: 3, height: 16)
                    .offset(x: fill - 8)
                    .opacity(fill - 8 < valueStart ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: fill - 8 < valueStart)
                HStack {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text(format(shown))
                        .monospacedDigit()
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { valueWidth = $0 }
                }
                .padding(.horizontal, PanelMetrics.insidePadding)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? {
                        // Past the handle, jump to the click; anywhere else, move from where it is.
                        let x = drag.startLocation.x
                        guard x > fill + 4 else { return shown }
                        return (range.lowerBound + Double((x - minimum) / track) * span).clamped(to: range)
                    }()
                    dragStart = start
                    let next = (start + Double(drag.translation.width / track) * span).clamped(to: range)
                    if next != shown {
                        draft = next
                        onChange?(next)
                    }
                }
                .onEnded { _ in
                    if let draft, draft != value { onCommit(draft) }
                    draft = nil
                    dragStart = nil
                    onEnd?()
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let defaultValue, defaultValue != value { onCommit(defaultValue) }
            })
        }
        .frame(height: PanelMetrics.boxHeight)
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(shown))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            let next = (value + (direction == .increment ? step : -step)).clamped(to: range)
            if next != value { onCommit(next) }
        }
    }
}
