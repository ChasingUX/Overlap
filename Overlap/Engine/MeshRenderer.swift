import CoreImage
import Synchronization

/// Draws mesh gradients as a browser draws the CSS they're written as: the base color, each pool over the ones
/// listed after it, blended in sRGB rather than linear light, then grain. A gradient doesn't change from frame to
/// frame, so each is drawn once per size and kept.
enum MeshRenderer {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB,
                                                     .cacheIntermediates: false])

    private struct Key: Hashable {
        var mesh: MeshFill
        var width: Int
        var height: Int
    }

    private struct Kept {
        /// Swatch-sized drawings, which are cheap to keep.
        var small: [Key: CGImage] = [:]
        /// Canvas-sized drawings, most recent last. Only a few stay, as a canvas being resized asks for new sizes.
        var large: [(key: Key, image: CGImage)] = []
    }

    private static let kept = Mutex(Kept())
    private static let smallestLarge = 512 * 512

    /// The gradient drawn at `size`, in sRGB.
    static func image(_ mesh: MeshFill, size: CGSize) -> CGImage? {
        let key = Key(mesh: mesh, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        guard key.width > 0, key.height > 0 else { return nil }
        let isLarge = key.width * key.height >= smallestLarge
        if let found = kept.withLock({ kept in isLarge ? kept.large.last { $0.key == key }?.image : kept.small[key] }) {
            return found
        }
        let rect = CGRect(x: 0, y: 0, width: key.width, height: key.height)
        guard let drawn = context.createCGImage(ciImage(mesh, in: rect), from: rect, format: .RGBA8, colorSpace: sRGB) else {
            return nil
        }
        kept.withLock { kept in
            if isLarge {
                kept.large.removeAll { $0.key == key }
                kept.large.append((key, drawn))
                if kept.large.count > 3 { kept.large.removeFirst() }
            } else {
                if kept.small.count > 96 { kept.small.removeAll() }
                kept.small[key] = drawn
            }
        }
        return drawn
    }

    /// The gradient filling `rect`, in the working space it's drawn in.
    static func ciImage(_ mesh: MeshFill, in rect: CGRect) -> CIImage {
        var image = CIImage(color: color(mesh.base)).cropped(to: rect)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        for spot in mesh.spots.reversed() {
            // Core Image's y runs up. A CSS circle's stops are measured along the line to the farthest corner.
            let center = CGPoint(x: rect.minX + spot.x * rect.width, y: rect.maxY - spot.y * rect.height)
            let reach = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 1
            let inner = spot.start * reach
            var faded = spot.color
            faded.alpha = 0
            guard let pool = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: center),
                "inputRadius0": inner,
                "inputRadius1": max(spot.end * reach, inner + 0.5),
                "inputColor0": color(spot.color),
                "inputColor1": color(faded),
            ])?.outputImage?.cropped(to: rect) else { continue }
            image = blended(pool, over: image, spot.blend)
        }
        if mesh.grain {
            image = grained(image, in: rect)
        }
        return dithered(image, in: rect).cropped(to: rect)
    }

    private static func blended(_ pool: CIImage, over image: CIImage, _ blend: MeshFill.Blend) -> CIImage {
        let filter = switch blend {
        case .normal: "CISourceOverCompositing"
        case .overlay: "CIOverlayBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        }
        return pool.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: image])
    }

    /// Fine colored noise laid over in overlay, as the web tools' SVG noise is: gray on average, so it leaves the
    /// colors as they were and only adds texture.
    private static func grained(_ image: CIImage, in rect: CGRect) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.24, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.24, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.24, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.38, y: 0.38, z: 0.38, w: 0.5),
        ]).cropped(to: rect)
        return grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// Noise a step of 255 either way, so smooth stretches don't band once they're 8 bits a channel.
    private static func dithered(_ image: CIImage, in rect: CGRect) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let step = 1.0 / 255
        let dither = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2 * step, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2 * step, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2 * step, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -step, y: -step, z: -step, w: 0),
        ]).cropped(to: rect)
        return dither.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func color(_ color: RGBA) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, colorSpace: sRGB)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
