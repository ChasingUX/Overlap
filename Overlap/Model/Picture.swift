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
        case .dipToBlack: "Dip to black"
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

/// How a title's lines line up, and which side stays put as its text gets wider or narrower. It isn't chosen: it
/// follows the side of the place the title keeps to, or else where it sits, left, middle or right third of the canvas.
enum TitleAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case leading, center, trailing

    /// The alignment for a title centered at `x`, a share of the canvas width from its middle.
    init(position x: Double) {
        self = x < -1.0 / 6 ? .leading : x > 1.0 / 6 ? .trailing : .center
    }
}

/// One of nine places a title can keep to: a corner, the middle of an edge, or the middle of the canvas. On a corner
/// or an edge, the title's box sits its margin in from the canvas's edges, and stays there as its text changes.
enum TitleAnchor: String, Hashable, Sendable, Codable, CaseIterable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    init(column: Int, row: Int) {
        self = Self.allCases[(row.clamped(to: -1...1) + 1) * 3 + column.clamped(to: -1...1) + 1]
    }

    /// The nearest place to a point on the canvas, by the third of it the point falls in, across and down.
    init(nearest point: CGPoint, canvas: CGSize) {
        func third(_ value: CGFloat, of length: CGFloat) -> Int { value < length / 3 ? -1 : value > length * 2 / 3 ? 1 : 0 }
        self.init(column: third(point.x, of: canvas.width), row: third(point.y, of: canvas.height))
    }

    private var index: Int { Self.allCases.firstIndex(of: self) ?? 4 }
    /// -1 on the left, 0 in the middle, 1 on the right.
    var column: Int { index % 3 - 1 }
    /// -1 at the top, 0 in the middle, 1 at the bottom.
    var row: Int { index / 3 - 1 }

    var alignment: TitleAlignment { column < 0 ? .leading : column > 0 ? .trailing : .center }

    var name: String {
        let across = ["left", "", "right"][column + 1]
        let down = ["Top", "", "Bottom"][row + 1]
        switch (down.isEmpty, across.isEmpty) {
        case (true, true): return "Middle"
        case (true, false): return across.capitalized
        case (false, true): return down
        case (false, false): return "\(down) \(across)"
        }
    }

    /// The margin in canvas pixels: a share of the canvas's shorter side, so it's the same down the sides as across
    /// the top.
    static func inset(_ margin: Double, canvas: CGSize) -> CGFloat {
        CGFloat(margin) * min(canvas.width, canvas.height)
    }

    /// Where a box `size` pixels across sits here, as the offset of its middle from the canvas's middle, a share of
    /// the canvas's width and height, as a `Visual` gives it.
    func center(ofBox size: CGSize, margin: Double, canvas: CGSize) -> (x: Double, y: Double) {
        let inset = Self.inset(margin, canvas: canvas)
        let x = 0.5 - (inset + size.width / 2) / max(canvas.width, 1)
        let y = 0.5 - (inset + size.height / 2) / max(canvas.height, 1)
        return (Double(column) * x, Double(row) * y)
    }

    /// The point on the canvas, in pixels from its top left, that a title's matching corner, edge or middle sits on.
    func point(margin: Double, canvas: CGSize) -> CGPoint {
        let inset = Self.inset(margin, canvas: canvas)
        return CGPoint(x: canvas.width / 2 + CGFloat(column) * (canvas.width / 2 - inset),
                       y: canvas.height / 2 + CGFloat(row) * (canvas.height / 2 - inset))
    }

    /// The box a picture `size` pixels across takes on the canvas at a placement's scale and turn.
    static func box(of size: CGSize, visual: Visual) -> CGSize {
        let width = size.width * visual.scale
        let height = size.height * visual.scale
        let angle = visual.rotation * .pi / 180
        return CGSize(width: abs(width * cos(angle)) + abs(height * sin(angle)),
                      height: abs(width * sin(angle)) + abs(height * cos(angle)))
    }
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
    /// A font family installed on the Mac, or one of the system's own designs (see `TitleFont`); empty for the
    /// system font.
    var fontFamily = ""
    /// Points on a 1080-pixel-tall canvas; the text scales with the canvas. A style sets it; the preview's handles
    /// size the text from there.
    var size = 96.0
    var weight = TitleWeight.bold
    var color = RGBA.white
    var alignment = TitleAlignment.center
    /// A rounded plate behind the text, for reading over busy pictures.
    var backdrop: RGBA?
    var animationIn = TitleAnimation.fade
    var animationOut = TitleAnimation.fade
    /// A soft shadow under the letters, for reading over pictures without a plate.
    var shadow = false
    /// The place on the canvas the title keeps to as it changes, or nil once it's dragged anywhere else.
    var anchor: TitleAnchor?
    /// How far in from the canvas's edges a title on a corner or an edge sits, as a share of the shorter side.
    var margin = Title.defaultMargin

    static let defaultMargin = 0.06
    static let marginRange = 0.0...0.15
    /// The sizes the Text tab's slider reaches; the preview's handles go further.
    static let sizeRange = 16.0...240.0

    /// The plate a title gets when Plate is chosen and it has none yet.
    static let plate = RGBA(red: 0, green: 0, blue: 0, alpha: 0.55)

    /// How the text stands out from the picture under it: not at all, by a shadow, or on a plate.
    var readability: TitleReadability {
        get { backdrop != nil ? .plate : shadow ? .shadow : .none }
        set {
            shadow = newValue == .shadow
            backdrop = newValue == .plate ? backdrop ?? Self.plate : nil
        }
    }

    /// The parts of a title's look "Use for all titles" copies: its font, color, readability and animation, not its
    /// words, size or alignment.
    mutating func takeLook(of other: Title) {
        fontFamily = other.fontFamily
        weight = other.weight
        color = other.color
        backdrop = other.backdrop
        shadow = other.shadow
        animationIn = other.animationIn
        animationOut = other.animationOut
    }
}

extension Title {
    /// Reads what's there and defaults the rest, so titles saved before a setting existed still open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 96
        weight = try container.decodeIfPresent(TitleWeight.self, forKey: .weight) ?? .bold
        color = try container.decodeIfPresent(RGBA.self, forKey: .color) ?? .white
        alignment = try container.decodeIfPresent(TitleAlignment.self, forKey: .alignment) ?? .center
        backdrop = try container.decodeIfPresent(RGBA.self, forKey: .backdrop)
        animationIn = try container.decodeIfPresent(TitleAnimation.self, forKey: .animationIn) ?? .fade
        animationOut = try container.decodeIfPresent(TitleAnimation.self, forKey: .animationOut) ?? .fade
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        anchor = try container.decodeIfPresent(TitleAnchor.self, forKey: .anchor)
        margin = try container.decodeIfPresent(Double.self, forKey: .margin) ?? Self.defaultMargin
    }
}

/// How a title's text stands out from the picture under it.
enum TitleReadability: String, Hashable, Sendable, CaseIterable {
    case none, shadow, plate

    var name: String { rawValue.capitalized }
}

/// The fonts the Text tab offers first: the system's own designs, then a few installed faces that read well on
/// video. The designs are kept in `Title.fontFamily` under names no installed family has.
enum TitleFont {
    static let rounded = ".rounded"
    static let serif = ".serif"
    static let mono = ".mono"

    static let designs: [(name: String, family: String)] = [("Rounded", rounded), ("New York", serif), ("Mono", mono)]
    static let faces = ["Avenir Next", "Futura", "Georgia"]

    /// What the Font menu shows for a title's font.
    static func name(of family: String) -> String {
        if family.isEmpty { return "System" }
        return designs.first { $0.family == family }?.name ?? family
    }
}

/// Ready-made titles. New text starts as Centered; the others set up projects for checks and tests.
enum TitleStyle: String, CaseIterable, Sendable {
    case centeredTitle, lowerThird, caption, boldIntro, endCard, callout

    var name: String {
        switch self {
        case .centeredTitle: "Centered"
        case .lowerThird: "Lower third"
        case .caption: "Caption"
        case .boldIntro: "Intro"
        case .endCard: "End card"
        case .callout: "Callout"
        }
    }

    var title: Title {
        switch self {
        case .centeredTitle:
            Title(text: "Title", size: 96, weight: .bold, shadow: true)
        case .lowerThird:
            Title(text: "Name\nRole", size: 44, weight: .semibold, alignment: .leading,
                  backdrop: RGBA(red: 0, green: 0, blue: 0, alpha: 0.55), animationIn: .slide, animationOut: .fade)
        case .caption:
            Title(text: "A line of caption", size: 40, weight: .medium, backdrop: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6))
        case .boldIntro:
            Title(text: "Intro", size: 160, weight: .heavy, animationIn: .pop, animationOut: .fade, shadow: true)
        case .endCard:
            Title(text: "Thanks for watching", size: 80, weight: .bold, shadow: true)
        case .callout:
            // A white pill with dark text, to point at something in the picture.
            Title(text: "Callout", size: 40, weight: .semibold, color: RGBA(hex: 0x141414),
                  backdrop: .white, animationIn: .pop, animationOut: .fade)
        }
    }

    /// The place the style's text keeps to.
    var anchor: TitleAnchor {
        switch self {
        case .centeredTitle, .boldIntro, .endCard: .center
        case .lowerThird: .bottomLeading
        case .caption: .bottom
        case .callout: .topTrailing
        }
    }

    /// Where the style places its text, near its place before it's measured onto it.
    var visual: Visual {
        var visual = Visual()
        switch self {
        case .centeredTitle, .boldIntro, .endCard:
            break
        case .lowerThird:
            visual.x = -0.38
            visual.y = 0.32
        case .caption:
            visual.y = 0.33
        case .callout:
            visual.x = 0.33
            visual.y = -0.33
        }
        return visual
    }
}
