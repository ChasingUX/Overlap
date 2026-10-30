import AppKit
import SwiftUI

/// The app's surface colors. Light mode uses the system colors; dark mode goes darker than the
/// system defaults so footage stands out, close to the reference editor.
enum Theme {
    /// Title bar, rail, panel and the controls bar, all one color.
    static let chrome = dynamic(light: .windowBackgroundColor, dark: gray(0x18))
    /// Around the canvas in the preview.
    static let previewSurround = dynamic(light: NSColor(white: 0.16, alpha: 1), dark: gray(0x0C))
    /// The timeline and its transport row, one continuous surface.
    static let timeline = dynamic(light: .controlBackgroundColor, dark: gray(0x10))
    /// Time grid lines that run down through every track.
    static let gridline = dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.03))
    /// The track a dragged clip will land on.
    static let landingTrack = dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.03))
    /// The gap a dragged track leaves behind.
    static let timelineSlot = dynamic(light: NSColor(white: 0.86, alpha: 1), dark: gray(0x0A))
    /// A track lifted while it's dragged.
    static let timelineLifted = dynamic(light: .controlBackgroundColor, dark: gray(0x1E))
    static let playhead = NSColor(srgbRed: 0.95, green: 0.36, blue: 0.32, alpha: 1)
    static let separator = dynamic(light: .separatorColor, dark: NSColor(white: 1, alpha: 0.07))
    /// Clips are grayscale: a top-to-bottom gradient, a thin stroke and a soft shadow.
    static let clipTop = dynamic(light: NSColor(white: 0.98, alpha: 1), dark: gray(0x33))
    static let clipBottom = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: gray(0x23))
    /// Audio clips sit a step darker than video clips.
    static let audioClipTop = dynamic(light: NSColor(white: 0.95, alpha: 1), dark: gray(0x2B))
    static let audioClipBottom = dynamic(light: NSColor(white: 0.9, alpha: 1), dark: gray(0x1E))
    static let clipStroke = dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.1))
    static let clipSelectedStroke = dynamic(light: NSColor(white: 0.15, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
    static let waveform = dynamic(light: NSColor(white: 0.45, alpha: 1), dark: NSColor(white: 0.62, alpha: 1))
    /// The quieter waveform in Media panel thumbnails.
    static let thumbnailWaveform = dynamic(light: NSColor(white: 0.64, alpha: 1), dark: NSColor(white: 0.36, alpha: 1))
    /// The part of a clip above its fade curve, darkened so the fade's shape reads at a glance.
    static let fadeShade = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.38))
    static let fadeLine = dynamic(light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.55))
    /// Where two clips overlap: a darker box with the incoming curve bright and the outgoing one dim.
    static let crossfadeFill = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.5))
    static let crossfadeStroke = dynamic(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.16))
    static let crossfadeIncoming = dynamic(light: NSColor(white: 0.1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.9))
    static let crossfadeOutgoing = dynamic(light: NSColor(white: 0.1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.4))
    /// Panel controls: each sits in its own box. A slider's filled part and a chosen option are a step lighter
    /// than the box.
    static let controlBox = dynamic(light: NSColor(white: 0.98, alpha: 1), dark: gray(0x1E))
    static let controlFill = dynamic(light: NSColor(white: 0.88, alpha: 1), dark: gray(0x2B))
    static let controlChosen = dynamic(light: NSColor(white: 0.84, alpha: 1), dark: gray(0x35))
    static let controlTick = dynamic(light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.13))
    static let controlHandle = dynamic(light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.5))
    /// Native sliders are tinted gray instead of the accent blue.
    static let sliderTint = dynamic(light: NSColor(white: 0.45, alpha: 1), dark: NSColor(white: 0.78, alpha: 1))

    private static func gray(_ value: Int) -> NSColor {
        let component = CGFloat(value) / 255
        return NSColor(srgbRed: component, green: component, blue: component + 2 / 255, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// The one animation for layout changes, like the switch between a project with a preview and one without.
enum Motion {
    static let layout = Animation.smooth(duration: 0.35)
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
