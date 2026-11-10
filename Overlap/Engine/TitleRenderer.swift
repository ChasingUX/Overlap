import AppKit
import CoreText

/// Draws a text clip's text, its backdrop or shadow if it has one, into an image sized to fit. The text is laid out
/// at the canvas's scale: a size of 96 is 96 pixels tall on a 1080-pixel canvas.
enum TitleRenderer {
    static func image(for title: Title, canvas: CGSize) -> CGImage? {
        let scale = canvas.height / 1080
        let pointSize = CGFloat(title.size) * scale
        let font = font(for: title, size: pointSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch title.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.lineHeightMultiple = 1.05
        let color = CGColor(srgbRed: title.color.red, green: title.color.green, blue: title.color.blue, alpha: title.color.alpha)
        let text = NSAttributedString(string: title.text.isEmpty ? " " : title.text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let maxWidth = canvas.width * 0.9
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2)
        // The backdrop leaves room around the text, and a shadow room to spread.
        let blur = pointSize * 0.14
        let inset = title.backdrop != nil ? CGSize(width: pointSize * 0.45, height: pointSize * 0.3)
            : title.shadow ? CGSize(width: blur * 1.5, height: blur * 1.5) : CGSize(width: 2, height: 2)
        let size = CGSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        if let backdrop = title.backdrop {
            let radius = min(pointSize * 0.3, size.height / 2)
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(srgbRed: backdrop.red, green: backdrop.green, blue: backdrop.blue, alpha: backdrop.alpha))
            context.fillPath()
        }
        if title.shadow, title.backdrop == nil {
            // Soft and a little below the letters, dark enough to lift white text off a light picture.
            context.setShadow(offset: CGSize(width: 0, height: -pointSize * 0.04), blur: blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        }
        let path = CGPath(rect: CGRect(x: inset.width, y: inset.height, width: textSize.width, height: textSize.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    static func font(for title: Title, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = switch title.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = switch title.fontFamily {
        case TitleFont.rounded: .rounded
        case TitleFont.serif: .serif
        case TitleFont.mono: .monospaced
        default: nil
        }
        if let design {
            return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        guard !title.fontFamily.isEmpty else { return system }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: title.fontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension TitleRenderer {
    /// A small picture of the canvas with the text where it sits, at its scale, rotation and opacity, over a dark
    /// frame: what a text clip shows on the timeline, as frames do for video, and a style's tile in the Text tab, on
    /// a soft gray that stands in for a picture with `asTile`, where the text is drawn larger than it would be so it
    /// reads at that size, still where it sits. `height` is in pixels.
    static func frame(for title: Title, visual: Visual, canvas: CGSize, height: Int, asTile: Bool = false) -> CGImage? {
        let scale = CGFloat(height) / canvas.height
        let size = CGSize(width: max(1, (canvas.width * scale).rounded()), height: CGFloat(height))
        guard let context = CGContext(data: nil, width: Int(size.width), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The tile's gray runs top to bottom as a timeline clip's does, in the same neutral grays.
        if asTile, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                              colors: [CGColor(srgbRed: 0x33 / 255, green: 0x33 / 255, blue: 0x35 / 255, alpha: 1),
                                                       CGColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x25 / 255, alpha: 1)] as CFArray,
                                              locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        } else {
            context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        var title = title
        if asTile { title.size *= 1.7 }
        guard let text = image(for: title, canvas: size) else { return context.makeImage() }
        let drawn = CGSize(width: CGFloat(text.width) * visual.scale, height: CGFloat(text.height) * visual.scale)
        // The canvas's y runs down; the bitmap's runs up.
        context.translateBy(x: size.width / 2 + visual.x * size.width, y: size.height / 2 - visual.y * size.height)
        context.rotate(by: -visual.rotation * .pi / 180)
        context.setAlpha(visual.opacity)
        context.draw(text, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        return context.makeImage()
    }
}
