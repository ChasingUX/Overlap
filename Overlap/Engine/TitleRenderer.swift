import AppKit
import CoreText

/// Draws a text clip's text, and its backdrop if it has one, into an image sized to fit. The text is laid out at
/// the canvas's scale: a size of 96 is 96 pixels tall on a 1080-pixel canvas.
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
        // The backdrop leaves room around the text.
        let inset = title.backdrop == nil ? CGSize(width: 2, height: 2) : CGSize(width: pointSize * 0.45, height: pointSize * 0.3)
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
        guard !title.fontFamily.isEmpty else { return .systemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: title.fontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
