import Foundation

/// A color in sRGB, each component 0 to 1.
struct RGBA: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a hex value like 0x1E3A8A.
    init(hex: Int, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A two-color linear gradient. `angle` is in degrees: 0 runs left to right, 90 top to bottom.
struct GradientFill: Hashable, Sendable, Codable {
    var from: RGBA
    var to: RGBA
    var angle: Double = 45
}

/// What fills the canvas behind the picture, or what a background clip shows.
enum BackgroundFill: Hashable, Sendable, Codable {
    case color(RGBA)
    case gradient(GradientFill)
    /// An image asset in the project.
    case wallpaper(UUID)

    /// Built-in swatches, shown first in the Canvas tab.
    static let colors: [BackgroundFill] = [0x0C0B10, 0xF5F5F7, 0x1C1C1E, 0x2C3E50, 0x1E3A8A, 0x0F766E]
        .map { .color(RGBA(hex: $0)) }
    static let gradients: [BackgroundFill] = [
        (0x4F46E5, 0xEC4899), (0x0EA5E9, 0x22C55E), (0xF97316, 0xEF4444), (0x111827, 0x4B5563),
        (0x7C3AED, 0x06B6D4), (0xFDE68A, 0xF472B6), (0x064E3B, 0x10B981), (0x1E293B, 0x7C3AED),
    ].map { .gradient(GradientFill(from: RGBA(hex: $0.0), to: RGBA(hex: $0.1))) }
}

/// The whole-picture frame: the composed clips inset from the canvas edges, rounded and shadowed over the
/// background. It needs a background to show around it, so it's off while there's none.
struct PictureFrame: Hashable, Sendable, Codable {
    /// How far the picture is inset on each side, as a share of the canvas size, 0 to 0.25.
    var padding: Double = 0
    /// 0 to 100.
    var shadow: Double = 0
    /// Corner radius as a share of the picture's shorter side, 0 to 0.25.
    var corners: Double = 0

    var isOff: Bool { padding == 0 && shadow == 0 && corners == 0 }
}

/// Fractions cut from each edge of a clip's source picture.
struct Crop: Hashable, Sendable, Codable {
    var left = 0.0
    var top = 0.0
    var right = 0.0
    var bottom = 0.0

    var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

struct ColorAdjustment: Hashable, Sendable, Codable {
    /// Stops, −2 to 2.
    var exposure = 0.0
    /// 0.5 to 1.5; 1 leaves it.
    var contrast = 1.0
    /// 0 to 2; 1 leaves it.
    var saturation = 1.0
    /// −1 cooler to 1 warmer.
    var temperature = 0.0

    var isNeutral: Bool { exposure == 0 && contrast == 1 && saturation == 1 && temperature == 0 }
}

/// How a clip's picture sits in the canvas. At the defaults it fills the canvas as large as it fits, centered.
struct Visual: Hashable, Sendable, Codable {
    /// The picture's center, offset from the canvas center, as a share of the canvas width and height. y runs down.
    var x = 0.0
    var y = 0.0
    /// 1 fits the canvas.
    var scale = 1.0
    /// Degrees, clockwise.
    var rotation = 0.0
    var crop = Crop()
    var opacity = 1.0
    /// Corner radius as a share of the picture's shorter side, 0 to 0.5.
    var corners = 0.0
    /// 0 to 100.
    var shadow = 0.0
    var color = ColorAdjustment()

    static let scaleRange = 0.05...4.0
}

/// How a same-track overlap between two pictures plays.
enum VideoTransition: String, Hashable, Sendable, Codable, CaseIterable {
    /// The incoming picture blends in along the crossfade's curve.
    case dissolve
    /// The outgoing picture fades to black for the first half, the incoming one up from black for the second.
    case dipToBlack

    var name: String {
        switch self {
        case .dissolve: "Dissolve"
        case .dipToBlack: "Dip to Black"
        }
    }
}

/// The canvas shape. Auto follows the first video added; the others are fixed sizes, or a custom one.
enum CanvasAspect: String, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case wide = "16:9"
    case tall = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case standard = "4:3"
    case custom

    var name: String {
        switch self {
        case .auto: "Auto"
        case .custom: "Custom"
        default: rawValue
        }
    }

    /// What the shape is for, as the Canvas tab's menu names it.
    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide: "Widescreen"
        case .tall: "Vertical"
        case .square: "Square"
        case .portrait: "Portrait"
        case .standard: "Classic"
        case .custom: "Custom"
        }
    }

    /// Width over height, for the fixed shapes.
    var ratio: Double? {
        size.map { Double($0.width) / Double($0.height) }
    }

    /// The fixed shape a size has, if it has one.
    static func shape(width: Int, height: Int) -> CanvasAspect? {
        let ratio = Double(width) / Double(max(height, 1))
        return allCases.first { $0.ratio.map { abs($0 - ratio) < 0.01 } ?? false }
    }

    /// A size's shape as a ratio: a standard one's name, such as 16:9, or width to height, such as 2.39:1.
    static func ratioName(width: Int, height: Int) -> String {
        if let known = shape(width: width, height: height) {
            return known.rawValue
        }
        let ratio = Double(width) / Double(max(height, 1))
        let rounded = (ratio * 100).rounded() / 100
        return "\(rounded.formatted(.number.precision(.fractionLength(0...2)))):1"
    }

    /// The canvas size for a fixed shape, at 1080 on its shorter side.
    var size: (width: Int, height: Int)? {
        switch self {
        case .wide: (1920, 1080)
        case .tall: (1080, 1920)
        case .square: (1080, 1080)
        case .portrait: (1080, 1350)
        case .standard: (1440, 1080)
        case .auto, .custom: nil
        }
    }

    static let frameRates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
}

// MARK: - Text

enum TitleWeight: String, Hashable, Sendable, Codable, CaseIterable {
    case regular, medium, semibold, bold, heavy

    var name: String { rawValue.capitalized }
}

enum TitleAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case leading, center, trailing
}

/// How a title comes in and goes out, over half a second.
enum TitleAnimation: String, Hashable, Sendable, Codable, CaseIterable {
    case none, fade, slide, pop

    var name: String { rawValue.capitalized }
    static let duration = 0.5
}

/// A text clip's text and look. Where it sits, how large and how opaque come from the clip's `Visual`.
struct Title: Hashable, Sendable, Codable {
    var text: String
    /// A font family installed on the Mac; empty for the system font.
    var fontFamily = ""
    /// Points on a 1080-pixel-tall canvas; the text scales with the canvas.
    var size = 96.0
    var weight = TitleWeight.bold
    var color = RGBA.white
    var alignment = TitleAlignment.center
    /// A rounded plate behind the text, for reading over busy pictures.
    var backdrop: RGBA?
    var animationIn = TitleAnimation.fade
    var animationOut = TitleAnimation.fade
}

/// Ready-made titles, dragged from the Text tab onto the timeline.
enum TitleStyle: String, CaseIterable, Sendable {
    case centeredTitle, lowerThird, caption, boldIntro

    var name: String {
        switch self {
        case .centeredTitle: "Centered Title"
        case .lowerThird: "Lower Third"
        case .caption: "Caption"
        case .boldIntro: "Bold Intro"
        }
    }

    var title: Title {
        switch self {
        case .centeredTitle:
            Title(text: "Title", size: 96, weight: .bold)
        case .lowerThird:
            Title(text: "Name\nRole", size: 44, weight: .semibold, alignment: .leading,
                  backdrop: RGBA(red: 0, green: 0, blue: 0, alpha: 0.55), animationIn: .slide, animationOut: .fade)
        case .caption:
            Title(text: "Caption", size: 40, weight: .medium, backdrop: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6))
        case .boldIntro:
            Title(text: "Intro", size: 160, weight: .heavy, animationIn: .pop, animationOut: .fade)
        }
    }

    /// Where the style places its text.
    var visual: Visual {
        var visual = Visual()
        switch self {
        case .centeredTitle, .boldIntro:
            break
        case .lowerThird:
            visual.x = -0.38
            visual.y = 0.32
        case .caption:
            visual.y = 0.33
        }
        return visual
    }
}
