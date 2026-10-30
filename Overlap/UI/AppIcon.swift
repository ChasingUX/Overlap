import SwiftUI

/// Every icon the app draws, in one place.
/// SF Symbols stand in for Phosphor's filled icons until the PhosphorSwift package
/// (github.com/phosphor-icons/swift) is added; swapping happens here only.
enum AppIcon {
    case media
    case canvas
    case video
    case audio
    case text
    case transitions
    case importMedia
    case play
    case pause
    case goToStart
    case goToEnd
    case zoomOut
    case zoomIn
    case waveform
    case image

    var symbolName: String {
        switch self {
        case .media: "film.stack.fill"
        case .canvas: "aspectratio.fill"
        case .video: "video.fill"
        case .audio: "speaker.wave.2.fill"
        case .text: "t.square.fill"
        case .transitions: "arrow.left.arrow.right.square.fill"
        case .importMedia: "plus"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .goToStart: "backward.end.fill"
        case .goToEnd: "forward.end.fill"
        case .zoomOut: "minus"
        case .zoomIn: "plus"
        case .waveform: "waveform"
        case .image: "photo.fill"
        }
    }

    var image: Image { Image(systemName: symbolName) }
}
