import AVFoundation
import Synchronization

/// A fill ready to draw, with a wallpaper resolved to its file.
enum ResolvedFill: Hashable, Sendable {
    case color(RGBA)
    case gradient(GradientFill)
    case image(URL)
}

/// A same-track crossfade as the picture sees it.
struct PictureTransition: Hashable, Sendable {
    var start: Double
    var end: Double
    var curve: Curve
    var style: VideoTransition

    func progress(at time: Double) -> Double {
        end > start ? ((time - start) / (end - start)).clamped(to: 0...1) : 1
    }
}

/// One clip's picture, as the compositor draws it.
struct RenderLayer: Sendable {
    enum Source: Sendable {
        /// A frame from a composition video track, turned upright.
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
        case image(URL)
        case title(Title)
        /// A background clip. It always draws behind the picture.
        case fill(ResolvedFill)
    }

    var clipID: UUID
    var source: Source
    var track: Int
    /// Composition seconds.
    var start: Double
    var end: Double
    var visual: Visual
    var transitionIn: PictureTransition?
    var transitionOut: PictureTransition?

    var isBackground: Bool {
        if case .fill = source { true } else { false }
    }

    func isActive(at time: Double) -> Bool {
        time >= start && time < end
    }
}

/// Everything the compositor needs to draw any frame: the canvas, its background and frame, and every picture
/// layer from the bottom track up.
struct RenderPlan: Sendable {
    var canvas: CGSize
    var background: ResolvedFill?
    var frame: PictureFrame
    var layers: [RenderLayer]
    /// A clip left out of the picture for now: text being typed into on the canvas, which the editor draws instead.
    var hiddenClip: UUID?

    /// Takes on the project's look without moving anything in time: the background and frame, and each layer's
    /// placement, text and fill. The canvas size and the clips' timing need a rebuild.
    mutating func takeLook(from project: Project, resolve: (BackgroundFill) -> ResolvedFill?) {
        background = project.background.flatMap(resolve)
        frame = project.frame
        for index in layers.indices {
            guard let clip = project.clip(layers[index].clipID) else { continue }
            layers[index].visual = clip.visual
            if let title = clip.title {
                layers[index].source = .title(title)
            } else if let fill = clip.fill, let resolved = resolve(fill) {
                layers[index].source = .fill(resolved)
            }
        }
    }
}

/// The plan shared by a composition's instructions and the compositor. Visual changes that don't move clips in
/// time (a drag in the preview, a slider in the Video tab) replace it in place, so they show without a rebuild.
final class RenderPlanBox: Sendable {
    private let plan: Mutex<RenderPlan>

    init(_ plan: RenderPlan) {
        self.plan = Mutex(plan)
    }

    var current: RenderPlan {
        plan.withLock { $0 }
    }

    func update(_ change: (inout RenderPlan) -> Void) {
        plan.withLock { change(&$0) }
    }
}

/// An instruction for a stretch of the timeline: the video tracks it needs, and the shared plan. Never changes after
/// it's made, so it's safe to share.
final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: RenderPlanBox

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], plan: RenderPlanBox) {
        self.timeRange = timeRange
        requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.plan = plan
    }
}
