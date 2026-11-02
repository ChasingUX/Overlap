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
                .padding(.horizontal, 10)
                .frame(height: PanelMetrics.boxHeight - PanelMetrics.pillInset * 2)
                .background(ChosenPill())
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// A label and a pop-up menu drawn by AppKit itself, for menus whose items need a picture and a detail beside the
/// title, which SwiftUI's menus can't show. It opens over the control with the chosen item lined up on it, as a
/// pop-up button's does, and keeps everything a native menu has: arrow keys, typing to jump, VoiceOver.
struct PopUpRow: View {
    struct Item {
        var title: String
        /// Shown at the item's right edge.
        var detail: String?
        /// Shown on a second line under the title.
        var subtitle: String?
        var image: NSImage?
        var isChosen = false
        /// Starts a new group, with a line above it.
        var startsGroup = false
        var action: () -> Void
    }

    let title: String
    let value: String
    var icon: NSImage?
    let items: () -> [Item]

    @State private var anchor = PopUpAnchor()

    var body: some View {
        ControlRow(title: title) {
            Button {
                anchor.popUp(items())
            } label: {
                HStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon)
                            .renderingMode(.template)
                            .foregroundStyle(.secondary)
                    }
                    Text(value)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: PanelMetrics.boxHeight - PanelMetrics.pillInset * 2)
                .background(ChosenPill())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PopUpAnchorView(anchor: anchor))
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(value)
        }
    }
}

/// Where a `PopUpRow`'s menu opens from: an empty AppKit view behind its pill.
@MainActor
final class PopUpAnchor {
    fileprivate weak var view: NSView?

    #if DEBUG
    /// Told about each menu as it opens, for debug checks that look at it.
    static var debugOnOpen: ((NSMenu) -> Void)?
    #endif

    func popUp(_ items: [PopUpRow.Item]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // The menu holds its items only weakly to their targets, so the actions are kept here while it's open.
        var actions: [MenuAction] = []
        var chosen: NSMenuItem?
        for item in items {
            if item.startsGroup, !menu.items.isEmpty { menu.addItem(.separator()) }
            let action = MenuAction(item.action)
            actions.append(action)
            let menuItem = NSMenuItem(title: item.title, action: #selector(MenuAction.choose), keyEquivalent: "")
            menuItem.target = action
            menuItem.image = item.image
            // macOS 27 hides menu pictures unless an item asks for its own; here the picture is the point.
            menuItem.preferredImageVisibility = .visible
            menuItem.subtitle = item.subtitle
            if let detail = item.detail { menuItem.badge = NSMenuItemBadge(string: detail) }
            menuItem.state = item.isChosen ? NSControl.StateValue.on : .off
            if item.isChosen { chosen = menuItem }
            menu.addItem(menuItem)
        }
        #if DEBUG
        if let debugOnOpen = Self.debugOnOpen {
            // The menu runs its own event loop while open; a timer in the common modes still fires inside it.
            nonisolated(unsafe) let open = (debugOnOpen, menu)
            let timer = Timer(timeInterval: 0.4, repeats: false) { _ in MainActor.assumeIsolated { open.0(open.1) } }
            RunLoop.main.add(timer, forMode: .common)
        }
        #endif
        // The chosen item opens right over the pill, the way a pop-up button's does.
        menu.popUp(positioning: chosen, at: NSPoint(x: 0, y: view.bounds.height - 1), in: view)
        withExtendedLifetime(actions) {}
    }
}

private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func choose() {
        run()
    }
}

/// The empty view a `PopUpRow`'s menu opens from.
final class PopUpAnchorNSView: NSView {}

private struct PopUpAnchorView: NSViewRepresentable {
    let anchor: PopUpAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PopUpAnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// A label and a color well. The color panel sends changes as it's dragged; they show at once through
/// `onChange`, and `onCommit` follows once the color has settled, as one undo step.
struct ColorRow: View {
    let title: String
    let color: RGBA
    var onChange: ((RGBA) -> Void)?
    let onCommit: (RGBA) -> Void

    @State private var settle: Task<Void, Never>?

    var body: some View {
        ControlRow(title: title) {
            ColorPicker(title, selection: Binding(get: { Color(rgba: color) }, set: { picked in
                let rgba = RGBA(picked)
                onChange?(rgba)
                settle?.cancel()
                settle = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onCommit(rgba)
                }
            }), supportsOpacity: false)
            .labelsHidden()
            .padding(.trailing, PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
        }
    }
}

/// A swatch with a +, for a color of your own: it opens the system color panel, shows each change as it's
/// made, and keeps the color once you stop changing it for a moment. It's a color well underneath, so it takes
/// turns with the other color controls for the one panel.
struct AddColorSwatch: NSViewRepresentable {
    /// Where the panel starts.
    let color: RGBA
    let onChange: (RGBA) -> Void
    /// The color kept, and the one kept earlier while picking this time, which it replaces.
    let onCommit: (RGBA, _ earlier: RGBA?) -> Void

    func makeNSView(context: Context) -> AddColorWell {
        AddColorWell()
    }

    /// As big as the grid's other swatches, not a color well's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AddColorWell, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }

    func updateNSView(_ well: AddColorWell, context: Context) {
        well.onChange = onChange
        well.onCommit = onCommit
        if !well.isActive {
            well.color = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        }
    }
}

final class AddColorWell: NSColorWell {
    var onChange: ((RGBA) -> Void)?
    var onCommit: ((RGBA, RGBA?) -> Void)?
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
        needsDisplay = true
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

    /// Drawn as a swatch rather than a well: an empty tile with a +, outlined like a chosen swatch while the panel
    /// is picking for it.
    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: isActive ? 1 : 0.5, dy: isActive ? 1 : 0.5), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.06).setFill()
        tile.fill()
        (isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.12)).setStroke()
        tile.lineWidth = isActive ? 2 : 1
        tile.stroke()
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [.secondaryLabelColor])))
        if let symbol {
            symbol.draw(in: NSRect(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
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
/// change, on release. Dragging past a detent, such as the default, catches on it, with a tap on a Force Touch
/// trackpad; holding ⌘ drags past freely.
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
    @State private var valueWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0
    /// The detent the value is resting on during a drag, so the tap plays once, as it catches.
    @State private var caught: Double?

    private static let tickCount = 7
    /// How near, in screen points, a drag has to come to a detent to catch on it.
    private static let detentReach: CGFloat = 5
    private var span: Double { range.upperBound - range.lowerBound }
    private var shown: Double { draft ?? value.clamped(to: range) }

    private var stops: [Double] {
        if let detents { return detents }
        guard let defaultValue, range.lowerBound < defaultValue, defaultValue < range.upperBound else { return [] }
        return [defaultValue]
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
                ForEach(1...Self.tickCount, id: \.self) { index in
                    let x = minimum + track * CGFloat(index) / CGFloat(Self.tickCount + 1)
                    if x > fill + 6, x < valueStart {
                        Capsule()
                            .fill(Color(nsColor: Theme.controlTick))
                            .frame(width: 1.5, height: 9)
                            .offset(x: x)
                    }
                }
                ForEach(stops, id: \.self) { stop in
                    let x = minimum + CGFloat((stop - range.lowerBound) / span) * track
                    if x > fill + 6, x < valueStart {
                        Capsule()
                            .fill(Color(nsColor: Theme.controlDetent))
                            .frame(width: 1.5, height: 12)
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
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
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
