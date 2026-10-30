import AppKit
import SwiftUI

/// The store's toast, floating at the bottom of the window: a mark for how it went, what happened, and for a
/// finished export, a way to find the file. It slides up when it appears and back down when it goes.
struct ToastOverlay: View {
    let store: ProjectStore

    var body: some View {
        ZStack {
            if let toast = store.toast {
                ToastView(toast: toast, onDismiss: store.dismissToast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .animation(.smooth(duration: 0.3), value: store.toast)
    }
}

private struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(toast.kind == .done ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let file = toast.file {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    onDismiss()
                }
                .buttonStyle(ToastButtonStyle())
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: Theme.controlFill))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// A small rounded button that sits inside a toast.
private struct ToastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : 0.12))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
