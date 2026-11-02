import SwiftUI

/// The icon rail: Canvas, the clip tabs, then Media, evenly spaced. A dot marks tabs that apply to the selection.
struct RailView: View {
    static let width: CGFloat = 52
    let store: ProjectStore
    @State private var hoveredTab: PanelTab?

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
        let applies = store.applicableTabs.contains(tab)
        // The chosen tab fills with the accent color; others show a soft gray tile on hover, and their icon brightens.
        let isHovered = hoveredTab == tab
        let fill = isActive ? Color.accentColor : (isHovered ? Color.primary.opacity(0.1) : Color.clear)
        return Button {
            store.activeTab = tab
            store.isPanelVisible = true
        } label: {
            tab.icon.image
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? Color.white : (isHovered ? Color.primary.opacity(0.85) : Color.secondary))
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(alignment: .topTrailing) {
                    if applies {
                        Circle()
                            .fill(isActive ? Color.white : Color.accentColor)
                            .frame(width: 5, height: 5)
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { inside in
            if inside {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
        .help("\(tab.title) (⌘\(tab.rawValue))")
        .accessibilityLabel(tab.title)
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

/// A clip tab: its title, then sections spaced out down the panel.
struct ClipPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title)
                    .font(.headline)
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PlaceholderPanel: View {
    let icon: AppIcon
    let title: String
    let message: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            icon.image
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(BoxButtonStyle())
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
