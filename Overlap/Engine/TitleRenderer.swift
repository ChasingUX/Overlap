import AppKit
import CoreText
import Synchronization

/// Draws a text clip's text, its backdrop or shadow if it has one, into an image sized to fit. The text is laid out
/// at the canvas's scale: a size of 96 is 96 pixels tall on a 1080-pixel canvas.
enum TitleRenderer {
    /// How a title's text is set: the framesetter, the text's own size, the room around it, and the whole image's.
    private struct Layout {
        var framesetter: CTFramesetter
        var textSize: CGSize
        var inset: CGSize
        var size: CGSize
        var pointSize: CGFloat
        var blur: CGFloat
    }

    private static func layout(for title: Title, canvas: CGSize) -> Layout {
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
        let text = NSMutableAttributedString(string: title.text.isEmpty ? " " : title.text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        // A caption lighting the word being said dims the rest.
        if let lit = title.litWord, let words = title.spokenWords, words.indices.contains(lit) {
            let dimmed = CGColor(srgbRed: title.color.red, green: title.color.green, blue: title.color.blue, alpha: title.color.alpha * 0.5)
            text.addAttribute(.foregroundColor, value: dimmed, range: NSRange(location: 0, length: text.length))
            let word = NSRange(location: words[lit].location, length: words[lit].length)
            if NSMaxRange(word) <= text.length { text.addAttribute(.foregroundColor, value: color, range: word) }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let maxWidth = canvas.width * 0.9
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2)
        // The backdrop leaves room around the text, and a shadow room to spread.
        let blur = pointSize * 0.14
        let inset = title.backdrop != nil ? CGSize(width: pointSize * 0.45, height: pointSize * 0.3)
            : title.shadow ? CGSize(width: blur * 1.5, height: blur * 1.5) : CGSize(width: 2, height: 2)
        let size = CGSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        return Layout(framesetter: framesetter, textSize: textSize, inset: inset, size: size, pointSize: pointSize, blur: blur)
    }

    private struct SizeKey: Hashable {
        var title: Title
        var width: Double
        var height: Double
    }

    private static let sizes = Mutex<[SizeKey: CGSize]>([:])

    /// The size of the image `image(for:canvas:)` draws, without drawing it. Captions measure every phrase each time
    /// the project changes, so sizes are kept.
    static func size(for title: Title, canvas: CGSize) -> CGSize {
        var plain = title
        plain.spokenWords = nil
        plain.litWord = nil
        let key = SizeKey(title: plain, width: canvas.width, height: canvas.height)
        if let known = sizes.withLock({ $0[key] }) { return known }
        let size = layout(for: plain, canvas: canvas).size
        sizes.withLock { sizes in
            if sizes.count > 4000 { sizes.removeAll() }
            sizes[key] = size
        }
        return size
    }

    static func image(for title: Title, canvas: CGSize) -> CGImage? {
        let layout = layout(for: title, canvas: canvas)
        let size = layout.size
        let pointSize = layout.pointSize
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
            context.setShadow(offset: CGSize(width: 0, height: -pointSize * 0.04), blur: layout.blur,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        }
        let path = CGPath(rect: CGRect(x: layout.inset.width, y: layout.inset.height, width: layout.textSize.width,
                                       height: layout.textSize.height), transform: nil)
        let frame = CTFramesetterCreateFrame(layout.framesetter, CFRange(), path, nil)
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
    /// frame: what a text clip shows on the timeline, as frames do for video. `height` is in pixels.
    static func frame(for title: Title, visual: Visual, canvas: CGSize, height: Int) -> CGImage? {
        let scale = CGFloat(height) / canvas.height
        let size = CGSize(width: max(1, (canvas.width * scale).rounded()), height: CGFloat(height))
        guard let context = CGContext(data: nil, width: Int(size.width), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
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
