import AVFoundation
import CoreImage
import ImageIO
import Synchronization

/// Draws a frame from a render plan with Core Image: the background, then every picture layer from the bottom track
/// up. Used by the compositor during playback and export, and directly by tests.
final class FrameRenderer: @unchecked Sendable {
    private struct TitleKey: Hashable {
        var title: Title
        var width: Double
        var height: Double
    }

    // Decoded images and drawn titles, kept between frames. Guarded by `lock`.
    private let lock = NSLock()
    private var images: [URL: CIImage] = [:]
    private var titles: [TitleKey: CIImage] = [:]

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The frame at `time`, `plan.canvas` in size with its origin at zero. `sourceFrame` supplies video frames
    /// by composition track.
    func image(plan: RenderPlan, at time: Double, placeholder: CIImage? = nil,
               sourceFrame: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: plan.canvas)
        let clear = placeholder ?? CIImage(color: .clear).cropped(to: canvas)

        // The background: the canvas's, under the background clip playing now on the highest track, if any.
        var background = plan.background.map { fill($0, in: canvas) }
        let backgroundLayers = plan.layers.filter { $0.isBackground && $0.isActive(at: time) }
        if let top = backgroundLayers.map(\.track).max() {
            let onTrack = backgroundLayers.filter { $0.track == top }.sorted { $0.start < $1.start }
            if let clips = blend(onTrack, at: time, render: { self.picture(of: $0, at: time, in: canvas, sourceFrame: sourceFrame) }) {
                background = clips.composited(over: background ?? CIImage(color: .black).cropped(to: canvas))
            }
        }

        // The picture: each track's clips, bottom track first.
        var picture = clear
        let active = plan.layers.filter { !$0.isBackground && $0.isActive(at: time) && $0.clipID != plan.hiddenClip }
        for track in Set(active.map(\.track)).sorted() {
            let onTrack = active.filter { $0.track == track }.sorted { $0.start < $1.start }
            if let image = blend(onTrack, at: time, render: { self.picture(of: $0, at: time, in: canvas, sourceFrame: sourceFrame) }) {
                picture = image.composited(over: picture)
            }
        }

        // Without a background, the canvas is black where nothing covers it.
        return picture.composited(over: background ?? CIImage(color: .black)).cropped(to: canvas)
    }

    // MARK: Layers

    /// One track's clips at a moment: a single clip, or two crossfading.
    private func blend(_ layers: [RenderLayer], at time: Double, render: (RenderLayer) -> CIImage?) -> CIImage? {
        guard layers.count == 2, let transition = layers[1].transitionIn else {
            return layers.compactMap(render).reduce(nil) { below, image in below.map { image.composited(over: $0) } ?? image }
        }
        let progress = transition.progress(at: time)
        switch transition.style {
        case .dissolve:
            let outgoing = render(layers[0]) ?? CIImage(color: .clear)
            let incoming = render(layers[1]) ?? CIImage(color: .clear)
            return outgoing.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming,
                kCIInputTimeKey: transition.curve.gain(at: progress),
            ])
        case .dipToBlack:
            // Down to black along the curve for the first half, then up from black for the second.
            if progress < 0.5 {
                return render(layers[0]).map { dimmed($0, to: transition.curve.gain(at: 1 - progress * 2)) }
            }
            return render(layers[1]).map { dimmed($0, to: transition.curve.gain(at: progress * 2 - 1)) }
        }
    }

    /// A clip's picture placed on the canvas: cropped, color-adjusted, fitted, rounded, moved, faded and shadowed.
    private func picture(of layer: RenderLayer, at time: Double, in canvas: CGRect, sourceFrame: (CMPersistentTrackID) -> CIImage?) -> CIImage? {
        let visual = layer.visual
        guard var image = source(of: layer, in: canvas, sourceFrame: sourceFrame) else { return nil }
        if case .fill = layer.source {
            return visual.opacity < 1 ? faded(image, to: visual.opacity) : image
        }
        image = atOrigin(image)
        if !visual.color.isNeutral {
            image = adjusted(image, visual.color)
        }
        // Media fits the canvas at a scale of 1; text is drawn at the canvas's own scale already.
        if case .title = layer.source {} else {
            let fit = min(canvas.width / image.extent.width, canvas.height / image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        }
        // The crop masks the fitted picture: what's left keeps its place and size. Placement and scale refer to the
        // whole picture, so they don't change as it's cropped.
        let size = image.extent.size
        var shown = image.extent
        if !visual.crop.isEmpty {
            let crop = visual.crop
            shown = CGRect(x: size.width * crop.left, y: size.height * crop.bottom,
                           width: size.width * max(0.01, 1 - crop.left - crop.right),
                           height: size.height * max(0.01, 1 - crop.top - crop.bottom))
            image = image.cropped(to: shown)
        }
        if visual.corners > 0 {
            image = masked(image, to: shown, radius: visual.corners * min(shown.width, shown.height))
        }

        var scale = visual.scale
        var opacity = visual.opacity
        var rise = 0.0
        if case let .title(title) = layer.source {
            // Titles come in over their first half second and go out over their last.
            for (animation, elapsed) in [(title.animationIn, time - layer.start), (title.animationOut, layer.end - time)] {
                guard animation != .none, elapsed < TitleAnimation.duration else { continue }
                let eased = Curve.sCurve.gain(at: max(0, elapsed) / TitleAnimation.duration)
                opacity *= eased
                if animation == .slide { rise += (1 - eased) * 0.04 * canvas.height }
                if animation == .pop { scale *= 0.85 + 0.15 * eased }
            }
        }

        // Center on the origin, scale, rotate clockwise, then move to the canvas center plus the offset. Core Image's
        // y runs up, so the offset's y and the rotation are flipped.
        let transform = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: -visual.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: canvas.midX + visual.x * canvas.width,
                                             y: canvas.midY - visual.y * canvas.height - rise))
        image = image.transformed(by: transform)
        if opacity < 1 {
            image = faded(image, to: opacity)
        }
        if visual.shadow > 0 {
            image = shadowed(image, amount: visual.shadow, canvasHeight: canvas.height)
        }
        return image
    }

    private func source(of layer: RenderLayer, in canvas: CGRect, sourceFrame: (CMPersistentTrackID) -> CIImage?) -> CIImage? {
        switch layer.source {
        case let .video(trackID, orientation):
            return sourceFrame(trackID)?.oriented(orientation)
        case let .image(url):
            return image(at: url, fitting: canvas.size)
        case let .title(title):
            return titleImage(title, canvas: canvas.size)
        case let .fill(fill):
            return self.fill(fill, in: canvas)
        }
    }

    // MARK: Effects

    private func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private func adjusted(_ image: CIImage, _ color: ColorAdjustment) -> CIImage {
        var image = image
        if color.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: color.exposure])
        }
        if color.contrast != 1 || color.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: color.contrast, kCIInputSaturationKey: color.saturation])
        }
        if color.temperature != 0 {
            // Treating the picture as lit by bluer light warms it, and by redder light cools it.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + 2500 * color.temperature, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        return image.cropped(to: image.extent)
    }

    private func masked(_ image: CIImage, to rect: CGRect, radius: Double) -> CIImage {
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": min(radius, min(rect.width, rect.height) / 2),
            kCIInputColorKey: CIColor.white,
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: rect)
    }

    private func faded(_ image: CIImage, to opacity: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    private func dimmed(_ image: CIImage, to level: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: level, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: level, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: level, w: 0),
        ])
    }

    /// A shadow below the picture's shape: a wide, soft one that lifts it off what's behind, and a tight one along its
    /// edge, dark enough to show on a dark background. 100 is a large, dark shadow.
    private func shadowed(_ image: CIImage, amount: Double, canvasHeight: Double) -> CIImage {
        let strength = min(max(amount, 0), 100) / 100
        let shape = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: image.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        func shadow(opacity: Double, blur: Double, drop: Double) -> CIImage {
            faded(shape, to: opacity)
                .applyingGaussianBlur(sigma: blur * canvasHeight)
                .transformed(by: CGAffineTransform(translationX: 0, y: -drop * canvasHeight))
        }
        // It darkens faster than it grows, so the middle of the slider already shows on a dark background.
        let darkness = strength.squareRoot()
        let wide = shadow(opacity: darkness, blur: 0.006 + 0.04 * strength, drop: 0.028 * strength)
        let edge = shadow(opacity: 0.7 * darkness, blur: 0.003 + 0.004 * strength, drop: 0.004 * strength)
        return image.composited(over: edge.composited(over: wide))
    }

    // MARK: Fills, images and titles

    func fill(_ fill: ResolvedFill, in canvas: CGRect) -> CIImage {
        switch fill {
        case let .color(color):
            return CIImage(color: ciColor(color)).cropped(to: canvas)
        case let .gradient(gradient):
            // The angle is measured with y running down, as on screen.
            let angle = gradient.angle * .pi / 180
            let direction = CGVector(dx: cos(angle), dy: -sin(angle))
            let half = abs(canvas.width / 2 * cos(angle)) + abs(canvas.height / 2 * sin(angle))
            let start = CGPoint(x: canvas.midX - direction.dx * half, y: canvas.midY - direction.dy * half)
            let end = CGPoint(x: canvas.midX + direction.dx * half, y: canvas.midY + direction.dy * half)
            let image = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: start),
                "inputPoint1": CIVector(cgPoint: end),
                "inputColor0": ciColor(gradient.from),
                "inputColor1": ciColor(gradient.to),
            ])?.outputImage ?? CIImage(color: ciColor(gradient.from))
            return image.cropped(to: canvas)
        case let .image(url):
            // A wallpaper fills the canvas, cropped at the edges as needed.
            guard let image = image(at: url, fitting: canvas.size) else { return CIImage(color: .black).cropped(to: canvas) }
            let scale = max(canvas.width / image.extent.width, canvas.height / image.extent.height)
            let scaled = atOrigin(image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(translationX: canvas.midX - scaled.extent.width / 2,
                                                            y: canvas.midY - scaled.extent.height / 2)).cropped(to: canvas)
        }
    }

    private func ciColor(_ color: RGBA) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, colorSpace: Self.sRGB)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// An image file decoded upright, at no more than twice the canvas size so large photos stay quick.
    private func image(at url: URL, fitting canvas: CGSize) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(canvas.width, canvas.height) * 2),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: decoded)
        images[url] = image
        return image
    }

    private func titleImage(_ title: Title, canvas: CGSize) -> CIImage? {
        let key = TitleKey(title: title, width: canvas.width, height: canvas.height)
        lock.lock()
        defer { lock.unlock() }
        if let cached = titles[key] { return cached }
        guard let drawn = TitleRenderer.image(for: title, canvas: canvas) else { return nil }
        let image = CIImage(cgImage: drawn)
        titles[key] = image
        return image
    }
}

/// The custom compositor AVFoundation runs for every frame of playback and export.
final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    // Shared by every compositor: a new one starts each time the picture is redrawn after a live change, and the
    // decoded images, drawn text and Core Image context should carry over.
    private static let renderer = FrameRenderer()
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    private var renderer: FrameRenderer { Self.renderer }
    private var context: CIContext { Self.context }
    /// AVFoundation labels the compositor's frames Core Media 709, its Rec. 709 for video, so they're written in
    /// that. Plain Rec. 709 has a different curve near black: frames written in it come out lighter than their
    /// sources, in the preview and in exports, most of all in dark tones.
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.coreMedia709)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    #if DEBUG
    /// Frames drawn since launch, for debug checks that the picture redraws when it should.
    static let renders = Atomic<Int>(0)
    /// The time of the frame drawn last.
    static let lastRenderedTime = Mutex<Double?>(nil)
    #endif

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        #if DEBUG
        Self.renders.add(1, ordering: .relaxed)
        Self.lastRenderedTime.withLock { $0 = request.compositionTime.seconds }
        #endif
        guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CocoaError(.featureUnsupported))
            return
        }
        let plan = instruction.plan.current
        let image = renderer.image(plan: plan, at: request.compositionTime.seconds) { trackID in
            request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
        }
        // The output can be smaller than the canvas, as for a preview at a lower size.
        let width = CGFloat(CVPixelBufferGetWidth(output))
        let height = CGFloat(CVPixelBufferGetHeight(output))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: width / plan.canvas.width, y: height / plan.canvas.height))
        context.render(scaled, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: Self.outputColorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// A frame of a plan at `time`, drawn `scale` times its canvas size, with `frames` standing in for the video
    /// tracks' frames. For drawing the picture where the player doesn't, as while the canvas is resized.
    static func still(of plan: RenderPlan, at time: Double, frames: [CMPersistentTrackID: CIImage], scale: CGFloat) -> CGImage? {
        let image = renderer.image(plan: plan, at: time) { frames[$0] }
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: outputColorSpace)
    }

    /// The preview's still while nothing on the timeline has a picture: the background on its own, as it exports,
    /// or without one, a dark placeholder marking the canvas.
    static func stage(for plan: RenderPlan) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: plan.canvas)
        let placeholder = plan.background == nil
            ? CIImage(color: CIColor(red: 0.075, green: 0.075, blue: 0.085)).cropped(to: canvas) : nil
        let image = renderer.image(plan: plan, at: 0, placeholder: placeholder) { _ in nil }
        return context.createCGImage(image, from: canvas, format: .RGBA8, colorSpace: outputColorSpace)
    }
}
