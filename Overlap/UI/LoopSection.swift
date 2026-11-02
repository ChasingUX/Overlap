import SwiftUI

/// Finds where the selected video loops and trims its clip to a loop. A video that repeats loops from anywhere, so
/// it offers one, two, three or four repeats from the playhead. Otherwise Suggested lists the best loops anywhere in
/// the video, each a different length, and From Playhead the best places to loop back to the frame under the
/// playhead. Pointing at a loop shades the part of the clip it keeps; clicking it trims the clip to it.
struct LoopSection: View {
    let store: ProjectStore
    let clip: Clip

    @State private var fromPlayhead = false

    var body: some View {
        PanelGroup(title: "Loop") {
            if let progress = store.loopProgress[clip.assetID] {
                ControlRow(title: "Finding loops") {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 96)
                        .padding(.trailing, PanelMetrics.insidePadding - PanelMetrics.pillInset - 2)
                }
            } else if let suggested = store.suggestedLoops[clip.assetID] {
                if let prints = store.framePrints[clip.assetID] {
                    if prints.isStill {
                        PanelNote(text: "This shot barely moves, so it loops from any point.")
                    } else if let repetition = store.repetitions[clip.assetID] {
                        let loops = store.repeatingLoops(in: clip)
                        PanelNote(text: String(format: "Repeats every %.1f s. Loops start at the playhead.", repetition.length))
                        if loops.isEmpty {
                            PanelNote(text: String(format: "Move the playhead earlier: a loop needs %.1f s after it.", repetition.length))
                        }
                        rows(loops, counting: true)
                    } else {
                        OptionRow(options: [("Suggested", false), ("From Playhead", true)], selected: fromPlayhead) { fromPlayhead = $0 }
                        let loops = fromPlayhead ? store.loopsFromPlayhead(in: clip) : suggested
                        if loops.isEmpty {
                            PanelNote(text: fromPlayhead ? "Nothing loops seamlessly back to this frame." : "This video has no seamless loops: it never comes back to the same picture.")
                        }
                        rows(loops, counting: false)
                    }
                } else {
                    PanelNote(text: "This video's frames couldn't be read.")
                }
            } else {
                Button("Find Loops") { store.findLoops(inAsset: clip.assetID) }
                    .buttonStyle(BoxButtonStyle())
            }
        }
        .onDisappear { store.highlightedLoop = nil }
    }

    /// A row for each loop. `counting` names them by how many repeats they hold.
    private func rows(_ loops: [Loop], counting: Bool) -> some View {
        ForEach(Array(loops.enumerated()), id: \.element) { index, loop in
            LoopRow(loop: loop, repeats: counting ? index + 1 : nil, isChosen: store.plays(loop, in: clip)) {
                store.trimToLoop(loop)
            } onHover: { inside in
                let highlight = LoopHighlight(clip: clip.id, start: loop.start, end: loop.end)
                if inside {
                    store.highlightedLoop = highlight
                } else if store.highlightedLoop == highlight {
                    store.highlightedLoop = nil
                }
            }
        }
    }
}

/// One loop: its length, and for a video that repeats how many repeats it holds, with where it sits in the video in
/// seconds.
private struct LoopRow: View {
    let loop: Loop
    let repeats: Int?
    let isChosen: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(String(format: "%.1f s", loop.length))
                    .monospacedDigit()
                if let repeats {
                    Text(repeats == 1 ? "1 repeat" : "\(repeats) repeats")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(String(format: "%.1f–%.1f", loop.start, loop.end))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, PanelMetrics.insidePadding)
        }
        .buttonStyle(BoxButtonStyle())
        .onHover(perform: onHover)
        .help("Trim the clip to this loop")
    }
}
