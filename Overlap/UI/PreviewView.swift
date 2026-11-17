import AVFoundation
import SwiftUI

/// The composed canvas at the playhead: a rounded frame, inset from the edges, on a neutral gray surround so
/// footage colors read accurately.
struct PreviewView: NSViewRepresentable {
    let store: ProjectStore
    /// The canvas's width over its height. The frame keeps this shape; 16:9 until there's a canvas.
    let aspectRatio: CGFloat?
    /// The still shown in place of the player while nothing on the timeline has a picture.
    var stage: CGImage?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(player: store.playback.player, store: store)
        store.playback.onSwap = { [weak view] isSwapping in
            if isSwapping { view?.swapDidBegin() } else { view?.swapDidEnd() }
        }
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = store.playback.player
        view.aspectRatio = aspectRatio
        view.setStage(stage)
        // While a Text or Canvas slider is dragged, the handles follow what the preview shows.
        view.overlay.state = TransformOverlay.State(project: store.handlesPreview ?? store.project, selection: store.selection,
                                                    handlesClip: store.handlesClip,
                                                    time: store.playback.currentTime, isCropping: store.isCropping,
                                                    editingTitle: store.editingTitleClip,
                                                    aimedZoom: store.aimedClip != nil ? store.selectedZoom : nil)
    }
}

final class PlayerLayerView: NSView {
    static let padding: CGFloat = 44
    static let cornerRadius: CGFloat = 10

    let playerLayer = AVPlayerLayer()
    /// The handles for the selected picture, laid over the video frame.
    let overlay: TransformOverlay
    var aspectRatio: CGFloat? {
        didSet { if aspectRatio != oldValue { needsLayout = true } }
    }

    /// Every edit swaps in a rebuilt composition, and the player shows nothing until the new one's first frame
    /// is decoded. The frame on screen before the swap stays up, over the video, until then.
    private let stillLayer = CALayer()
    /// The empty canvas, over the player, while there's no picture to play.
    private let stageLayer = CALayer()
    /// The canvas's faint edge, over the picture and under the handles.
    private let outlineLayer = CALayer()
    private var still: CVPixelBuffer?
    private var isSwapping = false
    private var readyObservation: NSKeyValueObservation?
    private let store: ProjectStore
    /// An asset from the Media tab is being dragged over the preview, so the canvas's edge lights up.
    private(set) var isDropTargeted = false {
        didSet { if isDropTargeted != oldValue { updateOutline() } }
    }

    init(player: AVPlayer, store: ProjectStore) {
        self.store = store
        overlay = TransformOverlay(store: store)
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // The empty canvas, as the compositor draws it, until the first frame is drawn.
        playerLayer.backgroundColor = CGColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
        playerLayer.cornerRadius = Self.cornerRadius
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        playerLayer.addSublayer(stillLayer)
        stageLayer.contentsGravity = .resizeAspect
        stageLayer.isHidden = true
        playerLayer.addSublayer(stageLayer)
        outlineLayer.cornerRadius = Self.cornerRadius
        outlineLayer.cornerCurve = .continuous
        layer?.insertSublayer(outlineLayer, above: playerLayer)
        addSubview(overlay)
        readyObservation = playerLayer.observe(\.isReadyForDisplay) { [weak self] _, _ in
            Task { @MainActor in self?.removeStillWhenReady() }
        }
        // Assets dragged from the Media tab.
        registerForDraggedTypes([.string])
        updateSurround()
        updateOutline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setStage(_ image: CGImage?) {
        guard stageLayer.contents as! CGImage? !== image else { return }
        withoutAnimation {
            stageLayer.contents = image
            stageLayer.isHidden = image == nil
        }
    }

    func swapDidBegin() {
        isSwapping = true
        // During back-to-back swaps the first frame stays up; the player may have nothing to show by now.
        guard still == nil, let frame = playerLayer.displayedPixelBuffer(),
              let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        // Holding the buffer keeps its surface from being reused for later frames while it's on screen.
        still = frame
        withoutAnimation {
            stillLayer.contents = surface
            stillLayer.isHidden = false
        }
    }

    func swapDidEnd() {
        isSwapping = false
        removeStillWhenReady()
    }

    private func removeStillWhenReady() {
        guard still != nil, !isSwapping, playerLayer.isReadyForDisplay else { return }
        // A display refresh more, so the new frame is on screen before the still comes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, !self.isSwapping, self.playerLayer.isReadyForDisplay else { return }
            self.withoutAnimation {
                self.stillLayer.isHidden = true
                self.stillLayer.contents = nil
            }
            self.still = nil
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// Presses on the preview belong to it and its handles, never to moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurround()
    }

    private func updateSurround() {
        layer?.backgroundColor = Theme.previewSurround.cgColor(for: effectiveAppearance)
    }

    /// The frame is the largest canvas-shaped rectangle that fits inside the padding, centered.
    override func layout() {
        super.layout()
        let area = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let ratio = aspectRatio ?? 16 / 9
        var size = CGSize(width: max(0, area.width), height: max(0, area.width) / ratio)
        if size.height > area.height {
            size = CGSize(width: max(0, area.height) * ratio, height: max(0, area.height))
        }
        // Follow resizes exactly instead of animating behind them.
        withoutAnimation {
            playerLayer.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            stillLayer.frame = playerLayer.bounds
            stageLayer.frame = playerLayer.bounds
            outlineLayer.frame = playerLayer.frame
        }
        updateOutline()
        // The handles cover the whole preview, so clicks around the canvas reach them too.
        overlay.frame = bounds
        overlay.canvasRect = overlay.convert(playerLayer.frame, from: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// The canvas's faint one-pixel edge, or, while an asset is dragged over, a clear accent one.
    private func updateOutline() {
        withoutAnimation {
            outlineLayer.borderColor = (isDropTargeted ? NSColor.controlAccentColor : Theme.canvasOutline).cgColor
            // One pixel on any screen.
            outlineLayer.borderWidth = isDropTargeted ? 2 : 1 / (window?.backingScaleFactor ?? 2)
        }
    }

    // MARK: Drop from the Media tab

    /// The asset being dragged, when it's one of this project's. Anywhere on the preview counts, not only the canvas.
    private func draggedAsset(_ info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: .string),
              let id = TimelineDrag.assetID(from: string), store.project.asset(id) != nil else { return nil }
        return id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTargeted = draggedAsset(sender) != nil
        return isDropTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    /// Lands as a click on its row does: at the playhead, on a new track above the rest.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        guard let id = draggedAsset(sender) else { return false }
        store.addAssetAtPlayhead(id)
        return true
    }

    #if DEBUG
    /// Holds an asset over the preview, runs `whileHeld`, then drops it, as a drag from the Media tab does.
    func debugDrop(_ id: UUID, whileHeld: () -> Void) {
        isDropTargeted = true
        whileHeld()
        isDropTargeted = false
        store.addAssetAtPlayhead(id)
    }
    #endif

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    #if DEBUG
    /// Whether the player has a frame to show, and whether the still covers it.
    var debugDisplayState: (ready: Bool, stillShown: Bool) {
        (playerLayer.isReadyForDisplay, !stillLayer.isHidden)
    }
    #endif
}
