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

    /// From CSS-style HSL: hue in degrees, saturation and lightness 0 to 100.
    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let s = saturation / 100
        let l = lightness / 100
        let chroma = (1 - abs(2 * l - 1)) * s
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case ..<1: (chroma, second, 0)
        case ..<2: (second, chroma, 0)
        case ..<3: (0, chroma, second)
        case ..<4: (0, second, chroma)
        case ..<5: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let lift = l - chroma / 2
        self.init(red: r + lift, green: g + lift, blue: b + lift, alpha: alpha)
    }

    /// Whether two colors look the same: within three steps of 255 in each channel, too close to tell apart.
    func isNear(_ other: RGBA) -> Bool {
        let step = 3.0 / 255 + 1e-9
        return abs(red - other.red) <= step && abs(green - other.green) <= step && abs(blue - other.blue) <= step
            && abs(alpha - other.alpha) <= step
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
    /// A two-color linear gradient, as projects made before mesh gradients have.
    case gradient(GradientFill)
    case mesh(MeshFill)
    /// An image asset in the project.
    case wallpaper(UUID)

    /// Built-in plain colors, in two rows: deep ones, from black and white through the hues, then soft ones.
    static let colors: [BackgroundFill] = [
        0x141414, 0xFFFFFF, 0xDB5B5D, 0xEE9C4D, 0xECB851, 0x519C6A, 0x4D9DE7, 0x935BF0, 0xE2709A,
        0x3A3A3C, 0xEFEFEF, 0xF4CBC3, 0xF8D08F, 0xF7E3A9, 0xBCE9C9, 0xBEDDF7, 0xDAC5F7,
    ].map { .color(RGBA(hex: $0)) }
    /// Built-in gradients: two rows of them, with Show More for any past that.
    static let gradients: [BackgroundFill] = MeshFill.presets.map { .mesh($0) }
}

/// How pictures sit on a background: scaled in from the canvas edges by the padding, with rounded corners and a
/// shadow. Titles move and shrink with the pictures, so a layout stays as it was, but keep their own look. At its
/// defaults it leaves the pictures as they are.
struct PictureFrame: Hashable, Sendable, Codable {
    /// How far the pictures are inset on each side, as a share of the canvas, 0 to 0.25.
    var padding = 0.0
    /// 0 to 100.
    var shadow = 0.0
    /// Corner radius as a share of each picture's shorter side, 0 to 0.5.
    var corners = 0.0

    static let standard = PictureFrame(padding: 0.1, shadow: 50, corners: 0.025)
    static let paddingRange = 0.0...0.25

    /// How much the padding shrinks the pictures, about the canvas center.
    var scale: Double { 1 - 2 * padding.clamped(to: Self.paddingRange) }
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

/// How a clip's picture sits in the canvas. At the defaults it fills the canvas as large as it fits, centered. Its
/// corners and shadow come from the project's frame; projects saved when each clip had its own still open, without
/// them.
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

/// How the canvas got its size. Auto follows the first video added; Custom is a size dragged to on the preview.
/// The named shapes are from when the Canvas tab offered them, kept so projects that chose one still open.
enum CanvasAspect: String, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case wide = "16:9"
    case tall = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case standard = "4:3"
    case custom
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
