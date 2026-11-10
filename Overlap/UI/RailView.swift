import SwiftUI

/// The icon rail: Canvas, the clip tabs, then Media, evenly spaced. Selecting a clip opens its tab, so the rail
/// needs no marks for the selection. A tab's name and shortcut show beside it after a moment's hover, sooner than
/// a system tooltip, and at once going from one tab to the next.
struct RailView: View {
    static let width: CGFloat = 52
    let store: ProjectStore
    @State private var hoveredTab: PanelTab?
    @State private var tooltip: PanelTab?
    @State private var tooltipTimer: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(PanelTab.allCases.filter { $0 != .transitions }) { tab in
                button(for: tab)
            }
            // Transitions joins the bottom only while a crossfade is selected, so nothing above it moves.
            if store.selectedTransition != nil {
                button(for: .transitions)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: Self.width)
    }

    private func button(for tab: PanelTab) -> some View {
        let isActive = store.isPanelVisible && store.activeTab == tab
        // The chosen tab fills with the accent color; others show a soft gray tile on hover, and their icon brightens.
        let isHovered = hoveredTab == tab
        let fill = isActive ? Color.accentColor : (isHovered ? Color.primary.opacity(0.1) : Color.clear)
        return Button {
            tooltipTimer?.cancel()
            tooltip = nil
            store.showTab(tab)
        } label: {
            tab.icon.image
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(isHovered ? 0.85 : 0.4))
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .overlay(alignment: .leading) {
            if tooltip == tab {
                // Just past the rail's edge, over the panel.
                RailTooltip(title: tab.title, shortcut: "⌘\(tab.rawValue)")
                    .offset(x: 30 + (Self.width - 30) / 2 + 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.1), value: tooltip)
        .onHover { hover(tab, $0) }
        .accessibilityLabel(tab.title)
    }

    private func hover(_ tab: PanelTab, _ inside: Bool) {
        tooltipTimer?.cancel()
        if inside {
            hoveredTab = tab
            if tooltip != nil {
                tooltip = tab
                return
            }
            tooltipTimer = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { tooltip = tab }
            }
        } else if hoveredTab == tab {
            hoveredTab = nil
            // A moment's grace, so moving to the next tab keeps a tip showing.
            tooltipTimer = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { tooltip = nil }
            }
        }
    }
}

/// A tab's name and its shortcut, on a small dark tag.
private struct RailTooltip: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.primary)
            Text(shortcut)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: Theme.tooltip))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .fixedSize()
    }
}

/// The icon at the top of an empty state, large and gray.
struct EmptyStateIcon: View {
    let icon: AppIcon

    var body: some View {
        icon.image
            .font(.system(size: 26))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }
}

/// Eases a button back a little while it's pressed, matching the playback buttons.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PanelView: View {
    let store: ProjectStore

    var body: some View {
        switch store.activeTab {
        case .media:
            MediaPanel(store: store)
        case .canvas:
            CanvasPanel(store: store)
        case .video:
            VideoPanel(store: store)
        case .audio:
            if store.applicableTabs.contains(.audio) {
                AudioClipPanel(store: store)
            } else {
                MasterPanel(store: store)
            }
        case .transitions:
            TransitionPanel(store: store)
        case .text:
            TextPanel(store: store)
        }
    }
}

/// A tab's sections, spaced out down the panel. The rail names the tab, so the panel shows no title of its own;
/// VoiceOver still reads it.
struct ClipPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.top, PanelMetrics.firstLabelTop)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// What a tab shows with nothing to work on, in the middle of the panel: the tab's icon, a title and a line or two
/// saying what to do, wrapped into even lines.
struct PlaceholderPanel: View {
    let icon: AppIcon
    let title: String
    let message: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            EmptyStateIcon(icon: icon)
            Text(title)
                .font(PanelMetrics.emptyTitleFont)
                .multilineTextAlignment(.center)
            BalancedText {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // A button as Media's empty state has.
            if let action {
                Button(action.title, action: action.perform)
                    .padding(.top, 6)
            }
        }
        .padding(24)
        // In the middle of the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
