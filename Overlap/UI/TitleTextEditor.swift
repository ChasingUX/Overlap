import AppKit

/// Typing into a text clip on the canvas: a text view in the title's own font, size, color, alignment and backdrop,
/// sized to its text where the title sits. It grows from the side the title lines up on, as the title will once
/// the text is applied. Return starts a new line, Esc cancels, and a click anywhere outside it, or losing focus,
/// applies the text.
final class TitleTextEditor: NSView, NSTextViewDelegate {
    let textView = NSTextView()
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void
    private var center = CGPoint.zero
    private var inset = CGSize.zero
    private var alignment = TitleAlignment.center
    /// How wide the title is drawn with the text it had, so its lined-up side stays where it is as the text changes.
    private var restingWidth: CGFloat = 0
    private var backdrop: NSColor?
    private var cornerRadius: CGFloat = 0
    /// Set once the edit has ended either way, so losing focus afterwards doesn't apply it again.
    private var isFinished = false
    private var clickMonitor: Any?

    init(text: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)
        textView.string = text
        textView.delegate = self
        textView.isRichText = false
        textView.drawsBackground = false
        // Typing is one undo step when it's applied, not a step per keystroke.
        textView.allowsUndo = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = .zero
        // Lines are laid out as wide as the title may wrap, so a selected line that ends in a return paints that far.
        // Views draw past their bounds unless told not to; the editor and its text stay inside its box.
        textView.clipsToBounds = true
        clipsToBounds = true
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Watches for clicks while the editor is up. A click outside it applies the text and then goes on as usual,
    /// wherever it lands. Views don't hear clicks on other views while a text view is being edited, so the editor
    /// listens itself, as the window's title field does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            DispatchQueue.main.async { self.commit() }
            return event
        }
    }

    var text: String { textView.string }

    /// Matches the title as drawn: `font` and `inset` are already at the preview's scale, `maxWidth` is the widest
    /// a line gets before it wraps, and `center` is where the title's middle sits.
    func show(_ title: Title, font: NSFont, inset: CGSize, maxWidth: CGFloat, center: CGPoint) {
        self.center = center
        self.inset = inset
        alignment = title.alignment
        backdrop = title.backdrop.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        cornerRadius = title.backdrop == nil ? 0 : font.pointSize * 0.3

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch title.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.lineHeightMultiple = 1.05
        let color = NSColor(srgbRed: title.color.red, green: title.color.green, blue: title.color.blue, alpha: title.color.alpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        textView.insertionPointColor = color
        textView.textContainer?.containerSize = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let resting = NSAttributedString(string: title.text.isEmpty ? " " : title.text, attributes: attributes)
            .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        restingWidth = max(ceil(resting.width), 4) + 2 + inset.width * 2
        fit()
    }

    /// Sizes the editor to its text, keeping the side the title lines up on where it is.
    private func fit() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).size
        // Room for the caret on an empty line.
        let textSize = CGSize(width: max(used.width, 4) + 2, height: max(used.height, textView.font?.pointSize ?? 12))
        let size = CGSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        let x = switch alignment {
        case .leading: center.x - restingWidth / 2
        case .trailing: center.x + restingWidth / 2 - size.width
        case .center: center.x - size.width / 2
        }
        frame = CGRect(x: x, y: center.y - size.height / 2, width: size.width, height: size.height)
        textView.frame = CGRect(x: inset.width, y: inset.height, width: textSize.width, height: textSize.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backdrop {
            backdrop.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        // A thin outline so the editing area reads against any picture.
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(cornerRadius, 3), yRadius: max(cornerRadius, 3))
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Applies the text, as when the editor loses focus or something else in the preview is clicked.
    func commit() {
        guard !isFinished else { return }
        isFinished = true
        onCommit(textView.string)
    }

    func textDidChange(_ notification: Notification) {
        fit()
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        isFinished = true
        onCancel()
        return true
    }
}
