import AppKit
import SwiftUI

/// The app's surface colors. Overlap is always dark, darker than the system's dark mode so footage stands
/// out, close to the reference editor.
enum Theme {
    /// Title bar, rail, panel and the controls bar, all one color.
    static let chrome = gray(0x18)
    /// Around the canvas in the preview.
    static let previewSurround = gray(0x0C)
    /// A hairline around the canvas, so its edge shows even where the picture is as dark as the surround.
    static let canvasOutline = NSColor(white: 1, alpha: 0.1)
    /// The timeline and its transport row, one continuous surface.
    static let timeline = gray(0x10)
    /// Time grid lines that run down through every track.
    static let gridline = NSColor(white: 1, alpha: 0.03)
    /// The track a dragged clip will land on.
    static let landingTrack = NSColor(white: 1, alpha: 0.03)
    /// The gap a dragged track leaves behind.
    static let timelineSlot = gray(0x0A)
    /// A track lifted while it's dragged.
    static let timelineLifted = gray(0x1E)
    static let playhead = NSColor(srgbRed: 0.95, green: 0.36, blue: 0.32, alpha: 1)
    static let separator = NSColor(white: 1, alpha: 0.07)
    /// Clips are grayscale: a top-to-bottom gradient, a thin stroke and a soft shadow.
    static let clipTop = gray(0x33)
    static let clipBottom = gray(0x23)
    /// Audio clips sit a step darker than video clips.
    static let audioClipTop = gray(0x2B)
    static let audioClipBottom = gray(0x1E)
    static let clipStroke = NSColor(white: 1, alpha: 0.1)
    static let clipSelectedStroke = NSColor(white: 0.92, alpha: 1)
    static let waveform = NSColor(white: 0.62, alpha: 1)
    /// The quieter waveform in Media panel thumbnails.
    static let thumbnailWaveform = NSColor(white: 0.36, alpha: 1)
    /// The part of a clip above its fade curve, darkened so the fade's shape reads at a glance.
    static let fadeShade = NSColor(white: 0, alpha: 0.38)
    static let fadeLine = NSColor(white: 1, alpha: 0.55)
    /// Where two clips overlap: a darker box with the incoming curve bright and the outgoing one dim.
    static let crossfadeFill = NSColor(white: 0, alpha: 0.5)
    static let crossfadeStroke = NSColor(white: 1, alpha: 0.16)
    static let crossfadeIncoming = NSColor(white: 1, alpha: 0.9)
    static let crossfadeOutgoing = NSColor(white: 1, alpha: 0.4)
    /// Panel controls: each sits in its own box. A slider's filled part and a chosen option are a step lighter
    /// than the box.
    static let controlBox = gray(0x1E)
    static let controlFill = gray(0x2B)
    static let controlChosen = gray(0x35)
    static let controlTick = NSColor(white: 1, alpha: 0.13)
    /// A slider's detent, such as its default, a step brighter than the other ticks.
    static let controlDetent = NSColor(white: 1, alpha: 0.36)
    static let controlHandle = NSColor(white: 1, alpha: 0.5)
    /// A slider's fill brightens toward its handle, from just above the box to a step past `controlFill`.
    static let controlFillStart = gray(0x27)
    static let controlFillEnd = gray(0x33)
    /// The rail's tooltips, a step lighter than the chrome they float over.
    static let tooltip = gray(0x2A)
    /// Native sliders are tinted gray instead of the accent blue.
    static let sliderTint = NSColor(white: 0.78, alpha: 1)

    private static func gray(_ value: Int) -> NSColor {
        let component = CGFloat(value) / 255
        return NSColor(srgbRed: component, green: component, blue: component + 2 / 255, alpha: 1)
    }
}

extension NSColor {
    /// Resolves a dynamic color for an appearance, for places that need a `CGColor`.
    func cgColor(for appearance: NSAppearance) -> CGColor {
        var resolved = cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = cgColor
        }
        return resolved
    }
}

/// A one-pixel separator in the theme's color.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.separator))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
