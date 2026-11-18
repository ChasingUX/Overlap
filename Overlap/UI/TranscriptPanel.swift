import AppKit
import SwiftUI

/// The Transcript tab: what's said in the videos on the timeline, following the playhead. Clicking a word moves the
/// playhead to it, and selecting words and pressing Delete cuts them from the video. Pauses and filler words are
/// marked, here and on the timeline, for one button to take out. Searching turns the top row into a field and lists
/// the lines that match, each a click from its moment.
struct TranscriptPanel: View {
    let store: ProjectStore
    @State private var isSearching = Self.debugSearch != nil
    @State private var query = Self.debugSearch ?? ""

    /// For checks: OVERLAP_SNAPSHOT_SEARCH=<words> opens the tab searching for them.
    private static let debugSearch: String? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["OVERLAP_SNAPSHOT_SEARCH"]
        #else
        nil
        #endif
    }()
    /// The match last gone to, by its place in the list.
    @State private var current: Int?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let transcript = store.timelineTranscript
        if transcript.isEmpty, store.transcribing == nil {
            emptyState
        } else {
            let hasQuery = isSearching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let matches = hasQuery ? transcript.matches(of: query) : []
            VStack(spacing: 0) {
                // The top row other panels' first labels line up with.
                topRow(matches)
                    .frame(height: PanelMetrics.topRowHeight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, PanelMetrics.topRowInset)

                if hasQuery {
                    SearchResults(matches: matches, current: current) { go(to: $0, in: matches) }
                } else {
                    TranscriptTextView(store: store, transcript: transcript)
                    footer(transcript)
                }
            }
            .onChange(of: query) { current = nil }
        }
    }

    /// "Transcript" and the search button, or, while searching, the field in their place.
    @ViewBuilder
    private func topRow(_ matches: [TranscriptMatch]) -> some View {
        if isSearching {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search the transcript", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    // Return and the arrows step through the matches; Esc closes.
                    .onSubmit { step(1, in: matches) }
                    .onKeyPress(.downArrow) { step(1, in: matches); return .handled }
                    .onKeyPress(.upArrow) { step(-1, in: matches); return .handled }
                    .onKeyPress(.escape) { closeSearch(); return .handled }
                    .onAppear { DispatchQueue.main.async { isFieldFocused = true } }
                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search")
                .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Theme.controlBox)))
        } else {
            HStack {
                PanelLabel("Transcript")
                Spacer()
                Button {
                    isSearching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut("f", modifiers: .command)
                .help("Search the transcript (⌘F)")
                .accessibilityLabel("Search the transcript")
            }
        }
    }

    private func go(to index: Int, in matches: [TranscriptMatch]) {
        guard matches.indices.contains(index) else { return }
        current = index
        store.playback.seek(to: matches[index].time)
    }

    private func step(_ delta: Int, in matches: [TranscriptMatch]) {
        guard !matches.isEmpty else { return }
        let next = current.map { ($0 + delta + matches.count) % matches.count } ?? (delta > 0 ? 0 : matches.count - 1)
        go(to: next, in: matches)
    }

    /// Back to the transcript, at the moment last gone to.
    private func closeSearch() {
        isSearching = false
        query = ""
        current = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.untranscribedVideos.isEmpty {
            PlaceholderPanel(icon: .transcript, title: "No speech found",
                             message: "Nothing is said in the videos on the timeline.")
        } else {
            PlaceholderPanel(icon: .transcript, title: "Transcribe speech",
                             message: "Writes out what's said in your videos, on this Mac.",
                             action: (title: "Transcribe", perform: { store.transcribe() }))
        }
    }

    /// Progress while transcribing; otherwise Cut while words are selected, or Remove for the marked pauses and
    /// fillers, then Add or Remove Captions, and Transcribe for videos added since. Captions don't show on the
    /// timeline, so this is where they come and go; they're styled by clicking one on the canvas.
    @ViewBuilder
    private func footer(_ transcript: TimelineTranscript) -> some View {
        let newVideos = store.transcribing == nil ? store.untranscribedVideos.count : 0
        let removable = transcript.pauseCount + transcript.fillerCount
        let captions = store.transcribing == nil ? store.project.tracks.first(where: { $0.captions != nil })?.id : nil
        let addsCaptions = store.transcribing == nil && !store.project.hasCaptions && !transcript.isEmpty
        if store.transcribing != nil || !store.transcriptSelection.isEmpty || removable > 0 || newVideos > 0 || addsCaptions || captions != nil {
            VStack(spacing: 8) {
                if let transcribing = store.transcribing {
                    TranscribingProgress(seconds: transcribing.seconds, duration: transcribing.duration,
                                         isPreparing: transcribing.isPreparing)
                } else if let first = store.transcriptSelection.first, let last = store.transcriptSelection.last {
                    Button {
                        store.cutTranscriptSelection()
                    } label: {
                        HStack(spacing: 8) {
                            Text("⌫")
                                .font(.system(size: 11))
                                .padding(.horizontal, 5)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                            Text("Cut \(first.range.start.shortDuration) – \(last.range.end.shortDuration)")
                        }
                    }
                    .buttonStyle(BoxButtonStyle())
                    .help("Takes the selected words out of the video and closes the gap")
                } else if removable > 0 {
                    Button(Self.removeTitle(pauses: transcript.pauseCount, fillers: transcript.fillerCount)) {
                        store.removePausesAndFillers()
                    }
                    .buttonStyle(BoxButtonStyle())
                    .help("Shortens each marked pause to a breath and takes out each filler word")
                }
                if addsCaptions {
                    Button("Add captions") {
                        store.addCaptions()
                    }
                    .buttonStyle(BoxButtonStyle())
                    .help("Shows what's said on the canvas, a phrase at a time, following every edit. Click a caption there to style them.")
                } else if let captions {
                    Button("Remove captions") {
                        store.removeCaptions(captions)
                    }
                    .buttonStyle(BoxButtonStyle())
                    .help("Takes the captions off the canvas; the transcript stays")
                }
                if newVideos > 0 {
                    Button(newVideos == 1 ? "Transcribe 1 new video" : "Transcribe \(newVideos) new videos") {
                        store.transcribe()
                    }
                    .buttonStyle(BoxButtonStyle())
                }
            }
            .padding(14)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    static func removeTitle(pauses: Int, fillers: Int) -> String {
        let pauseText = pauses == 1 ? "1 pause" : "\(pauses) pauses"
        let fillerText = fillers == 1 ? "1 filler" : "\(fillers) fillers"
        if pauses > 0, fillers > 0 { return "Remove \(pauseText) and \(fillerText)" }
        return "Remove \(pauses > 0 ? pauseText : fillerText)"
    }
}

/// The lines a search matches, each with its time and the match in bold; clicking one goes to it.
private struct SearchResults: View {
    let matches: [TranscriptMatch]
    let current: Int?
    let select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelLabel(matches.isEmpty ? "No matches" : matches.count == 1 ? "1 match" : "\(matches.count) matches")
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches.indices, id: \.self) { index in
                            SearchResultRow(match: matches[index], isCurrent: index == current) { select(index) }
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .onChange(of: current) {
                    if let current { proxy.scrollTo(current) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SearchResultRow: View {
    let match: TranscriptMatch
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(match.time.shortDuration)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(snippet)
                .font(.system(size: 12.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(isCurrent ? 0.09 : isHovered ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { action() }
    }

    /// The words around the match in gray, the match itself bold and white.
    private var snippet: AttributedString {
        var before = AttributedString((match.isCutBefore ? "…" : "") + match.before)
        before.foregroundColor = Color(white: 0.7)
        var found = AttributedString(match.match)
        found.foregroundColor = .white
        found.inlinePresentationIntent = .stronglyEmphasized
        var after = AttributedString(match.after + (match.isCutAfter ? "…" : ""))
        after.foregroundColor = Color(white: 0.7)
        return before + found + after
    }
}

/// How far transcribing has got: a line saying so over a thin bar.
private struct TranscribingProgress: View {
    let seconds: Double
    let duration: Double
    let isPreparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isPreparing ? "Getting the speech model…" : "Transcribing…")
                Spacer()
                if !isPreparing {
                    Text("\(Time(seconds: seconds).shortDuration) of \(Time(seconds: duration).shortDuration)")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.8))
                            .frame(width: geometry.size.width * (duration > 0 ? min(1, seconds / duration) : 0))
                    }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

extension NSAttributedString.Key {
    /// Which transcript item, by its place in `TimelineTranscript.items`, the text is.
    static let transcriptItem = NSAttributedString.Key("OverlapTranscriptItem")
}

/// The transcript as text that can be selected but not typed into, laid out by hand so each word and pause knows
/// its place on the timeline.
private struct TranscriptTextView: NSViewRepresentable {
    let store: ProjectStore
    let transcript: TimelineTranscript

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let text = TranscriptNSTextView(frame: .zero, textContainer: container)
        text.storage = storage
        text.coordinator = context.coordinator
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 14, height: 2)
        text.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.45),
            .foregroundColor: NSColor.white,
        ]
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.show(transcript)
        coordinator.follow(store.playback.currentTime, isPlaying: store.playback.isPlaying)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
        var store: ProjectStore
        weak var textView: TranscriptNSTextView?
        private var shown: TimelineTranscript?
        /// Brings the word being heard into view once, when the transcript comes back from a search.
        private var reveals = true
        /// Where each item sits in the text.
        private var itemRanges: [NSRange] = []
        private var current: Int?
        private var isRebuilding = false

        init(store: ProjectStore) {
            self.store = store
        }

        func show(_ transcript: TimelineTranscript) {
            guard transcript != shown, let textView, let storage = textView.textStorage else { return }
            shown = transcript
            isRebuilding = true
            let (text, ranges) = Self.text(for: transcript)
            itemRanges = ranges
            let scroll = textView.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin
            storage.setAttributedString(text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            // Words found while transcribing, or a cut, keep the reader where they were.
            if let scroll, let origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            current = nil
            textView.currentRange = nil
            isRebuilding = false
        }

        /// Lights the word being heard, and while playing keeps it in view.
        func follow(_ time: Time, isPlaying: Bool) {
            guard let textView else { return }
            let index = shown?.itemIndex(at: time)
            guard index != current else { return }
            current = index
            textView.currentRange = index.map { itemRanges[$0] }
            let reveal = reveals && index != nil
            if index != nil { reveals = false }
            guard isPlaying || reveal, let range = textView.currentRange, let rect = textView.rect(for: range),
                  let clip = textView.enclosingScrollView?.contentView else { return }
            let visible = clip.documentVisibleRect
            if !visible.insetBy(dx: 0, dy: 8).contains(rect) {
                clip.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - visible.height / 3)))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        /// The word being fixed, and the field it's retyped in.
        private var fixing: (source: WordSource, field: NSTextField)?
        private var cancelsFix = false

        /// Double-clicking a word opens a small field over it to retype it, for words heard wrong.
        func beginFixing(item index: Int) {
            guard let textView, let shown, shown.items.indices.contains(index), shown.sources.indices.contains(index),
                  let source = shown.sources[index], case let .word(text, _, _, _) = shown.items[index],
                  let rect = textView.rect(for: itemRanges[index]) else { return }
            endFixing()
            let field = NSTextField(string: text)
            field.font = NSFont.systemFont(ofSize: 13)
            field.textColor = .white
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = NSColor(white: 0.07, alpha: 1)
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.borderColor = NSColor.controlAccentColor.cgColor
            field.layer?.borderWidth = 1
            field.layer?.cornerRadius = 4
            field.delegate = self
            let width = min(max(rect.width + 44, 96), textView.bounds.width - rect.minX - 6)
            field.frame = CGRect(x: rect.minX - 4, y: rect.minY - 2, width: max(width, 60), height: rect.height + 4)
            textView.setSelectedRange(NSRange(location: NSMaxRange(itemRanges[index]), length: 0))
            textView.addSubview(field)
            fixing = (source, field)
            cancelsFix = false
            textView.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        private func endFixing() {
            guard let fixing else { return }
            self.fixing = nil
            fixing.field.removeFromSuperview()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let fixing, notification.object as? NSTextField === fixing.field else { return }
            let text = fixing.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let cancelled = cancelsFix
            endFixing()
            textView?.window?.makeFirstResponder(textView)
            if !cancelled, !text.isEmpty { store.correctWords([fixing.source], to: text) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Esc leaves the word as it was.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                cancelsFix = true
                self.textView?.window?.makeFirstResponder(self.textView)
                return true
            }
            return false
        }

        /// A click on a word or pause, without selecting, moves the playhead to it.
        func clicked(item index: Int) {
            guard let items = shown?.items, items.indices.contains(index) else { return }
            store.playback.seek(to: items[index].range.start)
        }

        /// Delete cuts the selected words, or, with none, deletes the selected clips as it does elsewhere.
        func delete() {
            if store.transcriptSelection.isEmpty {
                store.deleteSelection()
            } else {
                store.cutTranscriptSelection()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRebuilding, let textView, let storage = textView.textStorage else { return }
            var indexes = IndexSet()
            for value in textView.selectedRanges {
                let range = value.rangeValue
                guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
                storage.enumerateAttribute(.transcriptItem, in: range) { value, _, _ in
                    if let index = value as? Int { indexes.insert(index) }
                }
            }
            // Not while AppKit is still changing the selection, which SwiftUI may be redrawing for.
            let store = store
            DispatchQueue.main.async { store.selectTranscript(indexes) }
        }

        static let wordColor = NSColor(white: 0.86, alpha: 1)
        static let fillerColor = NSColor(white: 0.5, alpha: 1)

        /// The transcript's text: each paragraph under its time, words joined by spaces, fillers dimmed with a dotted
        /// underline, and pauses as small gray chips of their length.
        static func text(for transcript: TimelineTranscript) -> (NSAttributedString, [NSRange]) {
            let result = NSMutableAttributedString()
            var ranges: [NSRange] = []
            let body = NSFont.systemFont(ofSize: 13)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 14
            let stamp = NSMutableParagraphStyle()
            stamp.paragraphSpacing = 3
            let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: wordColor, .paragraphStyle: paragraph]
            var index = 0
            for (number, part) in transcript.paragraphs.enumerated() {
                if number > 0 { result.append(NSAttributedString(string: "\n", attributes: plain)) }
                result.append(NSAttributedString(string: part.start.shortDuration + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: stamp,
                ]))
                for (position, item) in part.items.enumerated() {
                    if position > 0 { result.append(NSAttributedString(string: " ", attributes: plain)) }
                    let start = result.length
                    var attributes = plain
                    attributes[.transcriptItem] = index
                    switch item {
                    case let .word(text, _, isFiller, _):
                        if isFiller {
                            attributes[.foregroundColor] = fillerColor
                            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                            attributes[.underlineColor] = NSColor(white: 1, alpha: 0.4)
                        }
                        result.append(NSAttributedString(string: text, attributes: attributes))
                    case let .pause(range, _):
                        let chip = NSMutableAttributedString(attachment: pauseChip(seconds: range.duration.seconds))
                        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
                        result.append(chip)
                    }
                    ranges.append(NSRange(location: start, length: result.length - start))
                    index += 1
                }
            }
            return (result, ranges)
        }

        /// A pause's length, "1.4 s", in a small rounded chip that sits on the line like a word.
        static func pauseChip(seconds: Double) -> NSTextAttachment {
            let label = String(format: "%.1f s", seconds) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor(white: 0.62, alpha: 1),
            ]
            let textSize = label.size(withAttributes: attributes)
            let size = NSSize(width: ceil(textSize.width) + 10, height: 15)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(white: 1, alpha: 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: 5, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -3, width: size.width, height: size.height)
            return attachment
        }
    }
}

/// The transcript's text view: it lights the word being heard, seeks on a click, and cuts on Delete.
private final class TranscriptNSTextView: NSTextView {
    /// Kept here: with TextKit 1 the view doesn't hold on to its own text.
    var storage: NSTextStorage?
    weak var coordinator: TranscriptTextView.Coordinator?

    /// The word or pause being heard, drawn with a soft rounded highlight.
    var currentRange: NSRange? {
        didSet {
            guard currentRange != oldValue else { return }
            for range in [oldValue, currentRange].compactMap({ $0 }) {
                if let rect = rect(for: range) { setNeedsDisplay(rect.insetBy(dx: -4, dy: -4)) }
            }
        }
    }

    /// Where a stretch of the text is drawn, in the view.
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let currentRange, let layoutManager, let textContainer, NSMaxRange(currentRange) <= (textStorage?.length ?? 0) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: currentRange, actualCharacterRange: nil)
            NSColor(white: 1, alpha: 0.14).setFill()
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                let box = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -2.5, dy: -0.5)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit follows the drag to select until the button comes up; a plain click selects nothing.
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // A double-click retypes the word.
        if event.clickCount == 2, let index = item(at: point) {
            coordinator?.beginFixing(item: index)
            return
        }
        guard selectedRange().length == 0, let index = item(at: point) else { return }
        coordinator?.clicked(item: index)
    }

    /// The item under a point, if the point is on it.
    private func item(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -2, dy: -2).contains(inContainer) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.transcriptItem, at: character, effectiveRange: nil) as? Int
    }

    // Delete, from the keyboard or the Edit menu, cuts the selected words.
    override func delete(_ sender: Any?) { coordinator?.delete() }
    override func deleteBackward(_ sender: Any?) { coordinator?.delete() }
    override func deleteForward(_ sender: Any?) { coordinator?.delete() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(delete(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}
