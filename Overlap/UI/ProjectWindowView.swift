import SwiftUI

struct ProjectWindowView: View {
    @Bindable var store: ProjectStore
    /// The controls bar and timeline keep their height as the window resizes; the preview takes the rest.
    @State private var timelineHeight: CGFloat = 380
    @State private var dragStartTimelineHeight: CGFloat?

    /// The preview row also holds the rail and panel, so it keeps enough height for all six rail buttons and the
    /// panel's controls.
    private let minimumPreviewHeight: CGFloat = 256
    private let minimumTimelineHeight: CGFloat = 200

    private static let panelWidth: CGFloat = 264

    private var aspectRatio: CGFloat? {
        store.project.canvas.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
    }

    /// The rail and panel sit beside the preview, and the controls bar and timeline run the full width of the
    /// window below. The preview is always there: before anything visual is added it shows the empty canvas.
    /// The split is drawn by hand so the controls bar's top border is a plain hairline, matching its bottom one;
    /// the system split view would draw its own thicker divider.
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let top = clampedPreviewHeight(in: size.height)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sideColumn
                    PreviewView(store: store, aspectRatio: aspectRatio, stage: store.stageImage)
                }
                .frame(height: top)
                .clipped()
                TransportBar(store: store)
                TimelineRepresentable(store: store)
            }
            .overlay(alignment: .topLeading) {
                resizeHandle(total: size.height)
                    .padding(.top, top - 4)
            }
            .coordinateSpace(.named(Self.editorSpace))
        }
        .background(Color(nsColor: Theme.chrome))
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) {
            ToastOverlay(store: store)
        }
        .sheet(isPresented: $store.isExportSheetShown) {
            ExportSheet(store: store)
        }
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
            // Above the panel, so the rail's tooltips float over it.
            RailView(store: store)
                .zIndex(1)
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

    /// The preview gets what the timeline leaves, within both minimums: a window too short for the timeline's
    /// height squeezes the timeline only once the preview is as small as it goes.
    private func clampedPreviewHeight(timeline: CGFloat? = nil, in total: CGFloat) -> CGFloat {
        (total - (timeline ?? timelineHeight)).clamped(to: minimumPreviewHeight...max(minimumPreviewHeight, total - minimumTimelineHeight))
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
                    let start = dragStartTimelineHeight ?? total - clampedPreviewHeight(in: total)
                    dragStartTimelineHeight = start
                    // Dragging the divider down grows the preview and shortens the timeline.
                    timelineHeight = total - clampedPreviewHeight(timeline: start - drag.translation.height, in: total)
                }
                .onEnded { _ in dragStartTimelineHeight = nil })
    }
}
