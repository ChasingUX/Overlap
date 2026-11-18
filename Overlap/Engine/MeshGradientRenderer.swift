import CoreImage
import SwiftUI
import Synchronization

/// Draws mesh gradients with SwiftUI's `MeshGradient`, for the picture as it plays and exports. A gradient is drawn
/// once, square, and stretched to the canvas: its points are shares of the canvas, so that's the same as drawing it
/// at the canvas's shape. Grain and a little dither go over the top at the canvas's own size.
enum MeshGradientRenderer {
    /// The drawing's side. Mesh gradients are smooth, so this stays sharp stretched over a 4K canvas.
    static let side = 1280

    private static let kept = Mutex<[(mesh: MeshGradientFill, image: CGImage)]>([])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The gradient as SwiftUI draws it, for the panel and for drawing here.
    @MainActor
    static func view(_ mesh: MeshGradientFill) -> MeshGradient {
        MeshGradient(width: mesh.columns, height: mesh.rows,
                     points: mesh.points.map { SIMD2(Float($0.x), Float($0.y)) },
                     colors: mesh.points.map { Color(.sRGB, red: $0.color.red, green: $0.color.green, blue: $0.color.blue, opacity: $0.color.alpha) },
                     smoothsColors: true, colorSpace: .perceptual)
    }

    /// Draws the gradient, if it isn't already, so the compositor finds it. Done wherever a gradient is chosen or
    /// changed, on the main actor, which SwiftUI draws on.
    @MainActor
    @discardableResult
    static func prepare(_ mesh: MeshGradientFill) -> CGImage? {
        let key = withoutGrain(mesh)
        if let found = kept.withLock({ $0.last { $0.mesh == key }?.image }) { return found }
        guard mesh.points.count == mesh.columns * mesh.rows, mesh.columns >= 2, mesh.rows >= 2 else { return nil }
        let renderer = ImageRenderer(content: Rectangle().fill(view(key)).frame(width: CGFloat(side), height: CGFloat(side)))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        kept.withLock { kept in
            kept.removeAll { $0.mesh == key }
            kept.append((key, image))
            // A gradient being dragged into shape draws a new one each step; only the latest few stay.
            if kept.count > 8 { kept.removeFirst() }
        }
        return image
    }

    /// The gradient ready for the compositor: drawn, then named in the plan.
    @MainActor
    static func resolved(_ mesh: MeshGradientFill) -> ResolvedFill {
        prepare(mesh)
        return .meshGradient(mesh)
    }

    /// The gradient filling `rect`, with its grain, from the drawing `prepare` made. Before one is made, the first
    /// point's color stands in.
    static func ciImage(_ mesh: MeshGradientFill, in rect: CGRect) -> CIImage {
        let key = withoutGrain(mesh)
        guard let drawn = kept.withLock({ $0.last { $0.mesh == key }?.image }) else {
            let first = mesh.points.first?.color ?? .black
            return CIImage(color: CIColor(red: first.red, green: first.green, blue: first.blue, alpha: 1, colorSpace: sRGB) ?? .black)
                .cropped(to: rect)
        }
        let image = CIImage(cgImage: drawn)
            .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(drawn.width), y: rect.height / CGFloat(drawn.height)))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
        let grained = mesh.grain > 0 ? MeshRenderer.grained(image, in: rect, spread: grainSpread(mesh.grain)) : image
        return MeshRenderer.dithered(grained, in: rect).cropped(to: rect)
    }

    /// How far a grain amount's noise strays from gray. Grain is laid over in linear light, where a little noise
    /// shows a lot, so it rises with the square: the low end fades in from nothing, and the top is the web tools' grain.
    static func grainSpread(_ grain: Double) -> Double {
        let amount = grain.clamped(to: 0...1)
        return 0.24 * amount * amount
    }

    private static func withoutGrain(_ mesh: MeshGradientFill) -> MeshGradientFill {
        var key = mesh
        key.grain = 0
        return key
    }
}
