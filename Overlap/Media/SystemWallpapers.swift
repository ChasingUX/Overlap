import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Mac's aerial wallpapers that this Mac has downloaded, in the order System Settings lists them: Golden Gate,
/// Tahoe, Sequoia and the rest. Each is a video, and a background uses one still from it. Others show up once
/// they're picked in System Settings > Wallpaper, which downloads them; nothing is fetched from here.
enum SystemWallpapers {
    /// One aerial, or one look of a dynamic one, such as macOS Light. Some come in a portrait version too.
    struct Aerial: Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var video: URL
        var portraitVideo: URL?
        var thumbnail: URL

        /// What the still is called in a project, for a canvas that's wide or tall.
        func fileName(portrait: Bool) -> String {
            portrait && portraitVideo != nil ? "\(name) Portrait.heic" : "\(name).heic"
        }

        /// Both names it can have in a project.
        var fileNames: Set<String> { [fileName(portrait: false), fileName(portrait: true)] }
    }

    static let folder = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/com.apple.wallpaper/aerials", directoryHint: .isDirectory)

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            struct Variant: Decodable {
                var appearance: String?
                var orientation: String?
            }

            var id: String
            var accessibilityLabel: String
            var categories: [String]?
            var preferredOrder: Int?
            /// A dynamic aerial's looks share one name and differ in this.
            var variant: Variant?
        }

        struct Category: Decodable {
            var id: String
        }

        var assets: [Entry]
        var categories: [Category]
    }

    /// The downloaded aerials, by category as System Settings shows them, then in each one's own order. A dynamic
    /// one's looks are named for them, as macOS Light and macOS Dark, each with its portrait version alongside.
    @concurrent
    static func downloaded() async -> [Aerial] {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest/entries.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        let categoryOrder = Dictionary(manifest.categories.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [(rank: [Int], aerial: Aerial)] = []
        for (index, entry) in manifest.assets.enumerated() {
            let video = folder.appending(path: "videos/\(entry.id).mov")
            guard FileManager.default.fileExists(atPath: video.path) else { continue }
            let look = entry.variant?.appearance.map { " \($0.prefix(1).uppercased())\($0.dropFirst())" } ?? ""
            let name = entry.accessibilityLabel + look
            let isPortrait = entry.variant?.orientation == "portrait"
            if let existing = found.firstIndex(where: { $0.aerial.name == name }) {
                if isPortrait { found[existing].aerial.portraitVideo = video }
                continue
            }
            let category = entry.categories?.compactMap { categoryOrder[$0] }.min() ?? .max
            let thumbnail = folder.appending(path: "thumbnails/\(entry.id).png")
            let aerial = isPortrait
                ? Aerial(id: entry.id, name: name, video: video, portraitVideo: video, thumbnail: thumbnail)
                : Aerial(id: entry.id, name: name, video: video, thumbnail: thumbnail)
            found.append(([category, entry.preferredOrder ?? .max, index], aerial))
        }
        return found.sorted { $0.rank.lexicographicallyPrecedes($1.rank) }.map(\.aerial)
    }

    /// The aerial's opening frame, at most 4K on its longer side, from its portrait version when asked and it has
    /// one. Stills are kept in the caches folder under the aerial's name, so using one again is quick.
    @concurrent
    static func still(of aerial: Aerial, portrait: Bool) async -> URL? {
        let folder = URL.cachesDirectory.appending(path: "Overlap/System Wallpapers", directoryHint: .isDirectory)
        let still = folder.appending(path: aerial.fileName(portrait: portrait))
        if FileManager.default.fileExists(atPath: still.path) { return still }
        let video = portrait ? aerial.portraitVideo ?? aerial.video : aerial.video
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 3840)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".\(UUID().uuidString).heic")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try? FileManager.default.moveItem(at: partial, to: still)
        return FileManager.default.fileExists(atPath: still.path) ? still : nil
    }
}
