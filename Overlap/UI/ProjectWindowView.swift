import SwiftUI

struct ProjectWindowView: View {
    @Bindable var store: ProjectStore
    @State private var previewHeight: CGFloat = 380
    @State private var dragStartHeight: CGFloat?

    /// The preview row also holds the panel, so it keeps enough height for the panel's controls.
    private let minimumPreviewHeight: CGFloat = 240
    private let minimumTimelineHeight: CGFloat = 200

    private static let panelWidth: CGFloat = 264

    /// With a preview, the rail and panel sit beside it and the timeline runs the full width of the window below.
    /// Projects with nothing visual have no preview: the rail and panel run the full height, over the timeline's
    /// left side, and the timeline's content starts after them. The timeline always spans the window, so the
    /// change is one motion: the preview folds up, the panel grows down over the timeline, and the timeline's
    /// content slides over to make room, all on the same animation.
    /// The split is drawn by hand so the controls bar's top border is a plain hairline, matching its bottom one;
    /// the system split view would draw its own thicker divider.
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let showsPreview = store.project.hasVisualClips
            let side = RailView.width + 1 + (store.isPanelVisible ? Self.panelWidth + 1 : 0)
            // The rail and panel are as tall as the preview, or the whole window without one.
            let top = showsPreview ? clampedPreviewHeight(in: size.height) : size.height
            ZStack(alignment: .topLeading) {
                PreviewView(playback: store.playback,
                            aspectRatio: store.project.canvas.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) })
                    .frame(width: max(0, size.width - side), height: showsPreview ? top : 0)
                    .opacity(showsPreview ? 1 : 0)
                    .clipped()
                    .padding(.leading, side)
                timelineArea(covered: showsPreview ? 0 : side)
                    .frame(width: size.width, height: showsPreview ? size.height - top : size.height)
                    .padding(.top, showsPreview ? top : 0)
                // Above the timeline, so while the layout changes the panel slides over it rather than under.
                sideColumn
                    .frame(width: side, height: top)
                if showsPreview {
                    resizeHandle(total: size.height)
                        .frame(width: size.width)
                        .padding(.top, top - 4)
                }
            }
            .coordinateSpace(.named(Self.editorSpace))
        }
        .background(Color(nsColor: Theme.chrome))
        .overlay(alignment: .top) { Hairline() }
        .animation(Motion.layout, value: store.project.hasVisualClips)
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .confirmationDialog(
            "Remove \(store.assetPendingRemoval?.displayName ?? "this media")?",
            isPresented: Binding(
                get: { store.assetPendingRemoval != nil },
                set: { if !$0 { store.assetPendingRemoval = nil } }
            ),
            presenting: store.assetPendingRemoval
        ) { asset in
            Button("Remove Media and Its Clips", role: .destructive) {
                store.removeAsset(asset.id)
            }
        } message: { _ in
            Text("It's on the timeline. Removing it also removes its clips.")
        }
    }

    private var sideColumn: some View {
        HStack(spacing: 0) {
            RailView(store: store)
            Hairline(vertical: true)
            if store.isPanelVisible {
                PanelView(store: store)
                    .frame(width: Self.panelWidth)
                Hairline(vertical: true)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: Theme.chrome))
    }

    private func clampedPreviewHeight(_ height: CGFloat? = nil, in total: CGFloat) -> CGFloat {
        (height ?? previewHeight).clamped(to: minimumPreviewHeight...max(minimumPreviewHeight, total - minimumTimelineHeight))
    }

    private static let editorSpace = "editor"

    /// An invisible strip over the controls bar's top border that resizes the preview.
    /// The drag is measured in the editor's fixed space: measured on the handle itself, which moves as the
    /// preview resizes, each change would shift the next reading and the divider would shake.
    private func resizeHandle(total: CGFloat) -> some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.editorSpace))
                .onChanged { drag in
                    // Start from the height as shown, so a drag begun past a limit doesn't jump.
                    let start = dragStartHeight ?? clampedPreviewHeight(in: total)
                    dragStartHeight = start
                    previewHeight = clampedPreviewHeight(start + drag.translation.height, in: total)
                }
                .onEnded { _ in dragStartHeight = nil })
    }

    /// The controls bar and timeline, full width. `covered` is how much of their left side the panel is over.
    private func timelineArea(covered: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Audio-only, the bar sits right under the toolbar, whose own border takes the place of its top one.
            TransportBar(store: store, showsTopBorder: store.project.hasVisualClips, leadingInset: covered)
            AnimatedTimeline(store: store, heightScale: store.project.hasVisualClips ? 1.2 : 1.6, coveredWidth: covered)
        }
    }
}
