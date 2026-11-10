import SwiftUI

/// Every icon the app draws, in one place.
/// SF Symbols stand in for Phosphor's icons until the PhosphorSwift package
/// (github.com/phosphor-icons/swift) is added; swapping happens here only.
/// The rail's tabs are outlines; the playback buttons stay filled.
enum AppIcon {
    case media
    case canvas
    case video
    case audio
    case text
    case transitions
    case zoom
    case importMedia
    case play
    case pause
    case goToStart
    case goToEnd
    case loop
    case zoomOut
    case zoomIn
    case waveform
    case image

    var symbolName: String {
        switch self {
        case .media: "photo.on.rectangle.angled"
        case .canvas: "aspectratio"
        case .video: "video"
        case .audio: "waveform"
        case .text: "textformat"
        case .transitions: "square.on.square.dashed"
        case .zoom: "plus.magnifyingglass"
        case .importMedia: "plus"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .goToStart: "backward.end.fill"
        case .goToEnd: "forward.end.fill"
        case .loop: "repeat"
        case .zoomOut: "minus"
        case .zoomIn: "plus"
        case .waveform: "waveform"
        case .image: "photo.fill"
        }
    }

    var image: Image { Image(systemName: symbolName) }
}
