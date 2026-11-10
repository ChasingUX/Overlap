import AppKit
import SwiftUI

/// The panel's controls. Each sits in its own rounded box, with its label on the left.
enum PanelMetrics {
    static let boxHeight: CGFloat = 38
    static let boxRadius: CGFloat = 10
    static let insidePadding: CGFloat = 12
    /// Chosen options sit this far in from the box's edges, with concentric corners.
    static let pillInset: CGFloat = 5
    static let pillRadius: CGFloat = boxRadius - pillInset
    /// A row in a `PanelCard`, a little shorter than a box of its own.
    static let cardRowHeight: CGFloat = 36
    /// How far a plain value's hover fill reaches past its text.
    static let valueInset: CGFloat = 6
    /// A panel's labels: 11-point text, 13 points tall.
    static let labelSize: CGFloat = 11
    static let labelHeight: CGFloat = 13
    /// A panel's top row: as tall as its 24-point buttons, such as Media's Import, 12 points down.
    static let topRowInset: CGFloat = 12
    static let topRowHeight: CGFloat = 24
    /// Where a panel's first label starts: centered in the top row, as Media's is beside Import, so every panel's
    /// top label sits at the same height.
    static let firstLabelTop = topRowInset + (topRowHeight - labelHeight) / 2
    /// An empty tab's title: the headline's size, a weight lighter.
    static let emptyTitleFont = Font.system(size: 13, weight: .semibold)
}

extension EnvironmentValues {
    /// Set inside a `PanelCard`, where rows share one box and their values sit plain on it.
    @Entry var isInPanelCard = false
}

/// A heading, then the group's controls.
struct PanelGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title)
            VStack(spacing: 6) {
                content
            }
        }
    }
}

/// A panel's labels, for groups and the parts within them: small and gray, never white, so the controls lead.
struct PanelLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: PanelMetrics.labelSize))
            .foregroundStyle(.secondary)
    }
}

/// Wraps text at the narrowest width that keeps it on as many lines as it takes at full width, so its lines come
/// out about even rather than a full line and a word or two, as CSS's balanced wrapping does.
struct BalancedText: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite, width > 0 else { return text.sizeThatFits(proposal) }
        return text.sizeThatFits(ProposedViewSize(width: balancedWidth(of: text, within: width), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let width = balancedWidth(of: text, within: bounds.width)
        text.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: width, height: nil))
    }

    /// The narrowest width, to a point, that doesn't add a line.
    private func balancedWidth(of text: LayoutSubview, within width: CGFloat) -> CGFloat {
        let height = text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        var narrow: CGFloat = 1
        var wide = width
        while wide - narrow > 1 {
            let middle = (narrow + wide) / 2
            if text.sizeThatFits(ProposedViewSize(width: middle, height: nil)).height > height + 0.5 {
                narrow = middle
            } else {
                wide = middle
            }
        }
        return wide
    }
}

/// Rows that share one box, with a hairline between each, and their values plain on the box rather than on pills.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(nsColor: Theme.separator))
                            .frame(height: 1 / displayScale)
                            .padding(.horizontal, PanelMetrics.insidePadding)
                    }
                    row
                }
            }
        }
        .background(ControlBox())
        .environment(\.isInPanelCard, true)
    }
}

/// What a value sits on: the chosen pill in a box of its own; in a card, nothing until the pointer is over it.
struct ValueBackground: View {
    let isPlain: Bool
    var isHighlighted = false

    var body: some View {
        if isPlain {
            RoundedRectangle(cornerRadius: PanelMetrics.pillRadius, style: .continuous)
                .fill(Color(nsColor: Theme.controlFill))
                .opacity(isHighlighted ? 1 : 0)
        } else {
            ChosenPill()
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

    @Environment(\.isInPanelCard) private var isInCard

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
        .padding(.trailing, isInCard ? PanelMetrics.insidePadding - PanelMetrics.valueInset : PanelMetrics.pillInset + 2)
        .frame(height: isInCard ? PanelMetrics.cardRowHeight : PanelMetrics.boxHeight)
        .background {
            if !isInCard { ControlBox() }
        }
    }
}

/// A label and a read-only value.
struct ValueRow: View {
    let title: String
    let value: String

    @Environment(\.isInPanelCard) private var isInCard

    var body: some View {
        ControlRow(title: title) {
            Text(value)
                .monospacedDigit()
                .padding(.trailing, isInCard ? PanelMetrics.valueInset : PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
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

/// More choices than fit in a row, in a grid of plain words in one box; the chosen one sits on a raised pill.
struct OptionGrid<Value: Equatable>: View {
    let options: [(label: String, value: Value)]
    let selected: Value?
    var columns = 3
    let onSelect: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button(option.label) { onSelect(option.value) }
                    .buttonStyle(OptionButtonStyle(isSelected: option.value == selected, fillsWidth: true))
            }
        }
        .font(.system(size: 12))
        .padding(PanelMetrics.pillInset)
        .background(ControlBox())
    }
}

/// A label and a pop-up menu showing its current choice on a pill.
struct MenuRow<Items: View>: View {
    let title: String
    let value: String
    @ViewBuilder var items: Items

    @Environment(\.isInPanelCard) private var isInCard
    @State private var isHovered = false

    var body: some View {
        ControlRow(title: title) {
            Menu {
                items
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, isInCard ? PanelMetrics.valueInset : 10)
                .frame(height: valueHeight(inCard: isInCard))
                .background(ValueBackground(isPlain: isInCard, isHighlighted: isHovered))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHovered = $0 }
        }
    }
}

/// A label and a color well. The color panel sends changes as it's dragged; they show at once through
/// `onChange`, and `onCommit` follows once the color has settled, as one undo step.
struct ColorRow: View {
    let title: String
    let color: RGBA
    var onChange: ((RGBA) -> Void)?
    let onCommit: (RGBA) -> Void

    @Environment(\.isInPanelCard) private var isInCard

    var body: some View {
        ControlRow(title: title) {
            ColorSwatch(name: title, color: color, onChange: { onChange?($0) }, onCommit: onCommit)
                .padding(.trailing, isInCard ? PanelMetrics.valueInset : PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
        }
    }
}

/// A round swatch of a color, for a row: clicking it opens the color panel for it, ringed meanwhile. Each change
/// shows as it's made, and the color is kept once you stop changing it for a moment.
struct ColorSwatch: View {
    let name: String
    let color: RGBA
    let onChange: (RGBA) -> Void
    let onCommit: (RGBA) -> Void

    @State private var isPicking = false

    var body: some View {
        ColorWellSwatch(color: color, showsColor: true, onChange: onChange, onActiveChange: { isPicking = $0 }) { color, _ in
            onCommit(color)
        }
        .frame(width: SwatchMetrics.rowCircle, height: SwatchMetrics.rowCircle)
        .overlay { SwatchRing(isRound: true, isSelected: isPicking, isHovered: false) }
        .accessibilityLabel(name)
    }
}

/// A round swatch that opens the system color panel, shows each change as it's made, and keeps the color once you
/// stop changing it for a moment: a dark one with a +, for a color of your own, or one showing its color. It's a
/// color well underneath, so it takes turns with the other color controls for the one panel.
struct ColorWellSwatch: NSViewRepresentable {
    /// Where the panel starts.
    let color: RGBA
    /// Shows the color itself rather than a +.
    var showsColor = false
    /// Shows every hue around the circle rather than a +.
    var showsSpectrum = false
    /// Set false to end the color panel's picking for this swatch, as when something else is chosen. Nil leaves it
    /// to the panel.
    var isPicking: Bool?
    let onChange: (RGBA) -> Void
    /// Whether the color panel is picking for this swatch, so it can show the chosen ring meanwhile.
    var onActiveChange: (Bool) -> Void = { _ in }
    /// The color kept, and the one kept earlier while picking this time, which it replaces.
    let onCommit: (RGBA, _ earlier: RGBA?) -> Void

    func makeNSView(context: Context) -> SwatchColorWell {
        SwatchColorWell()
    }

    /// As big as the swatches around it, not a color well's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwatchColorWell, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }

    func updateNSView(_ well: SwatchColorWell, context: Context) {
        well.showsColor = showsColor
        well.showsSpectrum = showsSpectrum
        well.onChange = onChange
        well.onCommit = onCommit
        well.onActiveChange = onActiveChange
        if isPicking == false, well.isActive {
            well.stopPicking()
        }
        if !well.isActive {
            well.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        }
    }
}

final class SwatchColorWell: NSColorWell {
    var showsColor = false {
        didSet { if showsColor != oldValue { needsDisplay = true } }
    }
    var showsSpectrum = false {
        didSet { if showsSpectrum != oldValue { needsDisplay = true } }
    }
    var onChange: ((RGBA) -> Void)?
    var onCommit: ((RGBA, RGBA?) -> Void)?
    var onActiveChange: ((Bool) -> Void)?
    private var settle: Task<Void, Never>?
    /// The color kept since the panel was last opened from here.
    private var kept: RGBA?

    init() {
        super.init(frame: .zero)
        colorWellStyle = .default
        target = self
        action = #selector(colorDidChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func activate(_ exclusive: Bool) {
        kept = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        place(panel)
        super.activate(exclusive)
        onActiveChange?(true)
    }

    /// Opens the color panel beside the swatch, just past the edge of the panel it sits in and level with it, so
    /// it shows up where you're looking rather than wherever it was last.
    private func place(_ panel: NSColorPanel) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let swatch = window.convertToScreen(convert(bounds, to: nil))
        let edge = enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)).maxX } ?? swatch.maxX
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let left = min(edge + 12, visible.maxX - size.width)
        let top = (swatch.maxY + 40).clamped(to: (visible.minY + size.height)...visible.maxY)
        panel.setFrameTopLeftPoint(NSPoint(x: max(visible.minX, left), y: top))
    }

    override func deactivate() {
        super.deactivate()
        onActiveChange?(false)
    }

    /// Ends picking for something chosen elsewhere, dropping a color still settling so it can't replace that.
    func stopPicking() {
        settle?.cancel()
        deactivate()
    }

    @objc private func colorDidChange() {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        let picked = RGBA(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        onChange?(picked)
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            onCommit?(picked, kept)
            kept = picked
        }
    }

    /// Drawn as a swatch rather than a well: its color, every hue, or a dark circle with a +, like None beside it.
    /// The ring marking it while the panel picks for it is drawn around it by the view it sits in.
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        if showsSpectrum {
            return drawSpectrum(in: circle)
        }
        (showsColor ? color : NSColor.black.withAlphaComponent(SwatchMetrics.toolShade)).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        guard !showsColor else { return }
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [.secondaryLabelColor])))
        if let symbol {
            symbol.draw(in: NSRect(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
    }

    /// Every hue around the circle, softening to white at the middle.
    private func drawSpectrum(in circle: NSBezierPath) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        circle.addClip()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width
        let steps = 90
        for step in 0..<steps {
            let from = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let to = CGFloat(step + 1) / CGFloat(steps) * 2 * .pi + 0.01
            context.move(to: center)
            context.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
            context.closePath()
            context.setFillColor(NSColor(hue: CGFloat(step) / CGFloat(steps), saturation: 0.75, brightness: 1, alpha: 1).cgColor)
            context.fillPath()
        }
        let white = [NSColor.white.withAlphaComponent(0.85).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        if let soft = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: white, locations: [0, 1]) {
            context.drawRadialGradient(soft, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: bounds.width * 0.42, options: [])
        }
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }
}

extension Color {
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBA {
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
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

/// How tall a value's pill or hover fill is: inset from its row's edges, with concentric corners.
func valueHeight(inCard: Bool) -> CGFloat {
    (inCard ? PanelMetrics.cardRowHeight : PanelMetrics.boxHeight) - PanelMetrics.pillInset * 2
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

/// A slider that is its whole box. The filled part is a lighter box, brightening toward a small handle at its end
/// that turns white while dragged; faint ticks an eighth apart mark the rest of the track, lined up so one falls on
/// the default, and the value sits at the right. Ticks, like the handle, don't show under the label or the value. The track runs the box's full width, so a middle value
/// sits in the middle; the handle fades out as it passes under the value rather than cross the number.
/// The fill can end short of the label, which reads over the track. Dragging on the fill changes the value by
/// how far the pointer moves; a click past the handle jumps there first. Double-click resets it. A drag is one
/// change, on release. Dragging past a detent, such as the default, catches on it, with a tap on a Force Touch
/// trackpad; holding ⌘ drags past freely. The pointer is an open hand over the slider and closes while it drags.
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
    /// Values the slider catches on. Nil puts one at the default when it's inside the range; a default at an end
    /// needs none, since a drag stops there anyway.
    var detents: [Double]?

    @State private var draft: Double?
    @State private var dragStart: Double?
    @State private var isHovered = false
    @State private var valueWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0
    /// The detent the value is resting on during a drag, so the tap plays once, as it catches.
    @State private var caught: Double?

    private nonisolated static let tickCount = 7
    /// How near, in screen points, a drag has to come to a detent to catch on it.
    private static let detentReach: CGFloat = 5
    private var span: Double { range.upperBound - range.lowerBound }
    private var shown: Double { draft ?? value.clamped(to: range) }

    private var stops: [Double] {
        if let detents { return detents }
        guard let defaultValue, range.lowerBound < defaultValue, defaultValue < range.upperBound else { return [] }
        return [defaultValue]
    }

    /// Where the ticks sit, as shares of the track: an eighth apart, shifted so one falls on the first detent,
    /// given as a share of the track too, wherever it is. Without one they sit on the eighths.
    nonisolated static func tickFractions(firstStop: Double?) -> [Double] {
        let spacing = 1.0 / Double(tickCount + 1)
        let phase = firstStop.map { ($0.truncatingRemainder(dividingBy: spacing) + spacing).truncatingRemainder(dividingBy: spacing) } ?? 0
        return stride(from: phase, through: 1, by: spacing).filter { $0 > 0.02 && $0 < 0.98 }
    }

    /// The detent a value catches on: the nearest within `reach`, in the slider's own units.
    nonisolated static func detent(for value: Double, among stops: [Double], reach: Double) -> Double? {
        stops.filter { abs($0 - value) <= reach }.min { abs($0 - value) < abs($1 - value) }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // At its lowest the fill is just wide enough to hold the handle.
            let minimum = min(width, 22)
            let track = max(1, width - 2 - minimum)
            let fill = minimum + CGFloat((shown - range.lowerBound) / span) * track
            let valueStart = width - PanelMetrics.insidePadding - valueWidth - 8
            let titleEnd = PanelMetrics.insidePadding + titleWidth + 4
            // The handle fades out under the label and the value, rather than cross either.
            let showsHandle = fill - 8 > titleEnd && fill - 8 < valueStart
            ZStack(alignment: .leading) {
                ControlBox()
                ForEach(Self.tickFractions(firstStop: stops.first.map { ($0 - range.lowerBound) / span }), id: \.self) { fraction in
                    let x = minimum + track * CGFloat(fraction)
                    if x > max(fill + 6, titleEnd), x < valueStart {
                        Capsule()
                            .fill(Color(nsColor: Theme.controlTick))
                            .frame(width: 1.5, height: 9)
                            .offset(x: x)
                    }
                }
                ForEach(stops, id: \.self) { stop in
                    let x = minimum + CGFloat((stop - range.lowerBound) / span) * track
                    if x > max(fill + 6, titleEnd), x < valueStart {
                        Capsule()
                            .fill(Color(nsColor: Theme.controlDetent))
                            .frame(width: 1.5, height: 12)
                            .offset(x: x)
                    }
                }
                LinearGradient(colors: [Color(nsColor: Theme.controlFillStart), Color(nsColor: Theme.controlFillEnd)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fill)
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.boxRadius, style: .continuous))
                // The handle turns white while it's dragged.
                Capsule()
                    .fill(dragStart != nil ? Color.white : Color(nsColor: Theme.controlHandle))
                    .animation(.easeOut(duration: 0.12), value: dragStart != nil)
                    .frame(width: 3, height: 16)
                    .offset(x: fill - 8)
                    .opacity(showsHandle ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: showsHandle)
                HStack {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                    Spacer(minLength: 8)
                    Text(format(shown))
                        .monospacedDigit()
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { valueWidth = $0 }
                }
                .padding(.horizontal, PanelMetrics.insidePadding)
            }
            .contentShape(Rectangle())
            .pointerStyle(dragStart != nil ? .grabActive : .grabIdle)
            .onHover { isHovered = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // The hand stays closed for the whole drag, even once the pointer leaves the slider.
                    NSCursor.closedHand.set()
                    let start = dragStart ?? {
                        // Past the handle, jump to the click; anywhere else, move from where it is.
                        let x = drag.startLocation.x
                        guard x > fill + 4 else { return shown }
                        return (range.lowerBound + Double((x - minimum) / track) * span).clamped(to: range)
                    }()
                    if dragStart == nil {
                        // Starting on a detent doesn't tap.
                        caught = stops.first { $0 == shown }
                    }
                    dragStart = start
                    var next = (start + Double(drag.translation.width / track) * span).clamped(to: range)
                    let stop = NSEvent.modifierFlags.contains(.command) ? nil
                        : Self.detent(for: next, among: stops, reach: Double(Self.detentReach / track) * span)
                    if let stop {
                        next = stop
                        if caught != stop {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                    }
                    caught = stop
                    if next != shown {
                        draft = next
                        onChange?(next)
                    }
                }
                .onEnded { _ in
                    if let draft, draft != value { onCommit(draft) }
                    draft = nil
                    dragStart = nil
                    caught = nil
                    (isHovered ? NSCursor.openHand : NSCursor.arrow).set()
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
