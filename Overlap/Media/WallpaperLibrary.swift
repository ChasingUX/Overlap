import Foundation

/// Wallpapers and custom background colors kept for every project. Wallpapers are copied into
/// ~/Library/Application Support/Overlap/Wallpapers; a project copies one into its package when it uses it.
enum WallpaperLibrary {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Overlap/Wallpapers", directoryHint: .isDirectory)
    }

    static func wallpapers() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter(MediaImporter.isSupported).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keeps a copy of an image, unless one with the same name is already kept.
    static func add(_ url: URL) {
        let destination = folder.appending(path: url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? MediaImporter.cloneFile(url, to: destination)
    }

    private static let colorsKey = "customBackgroundColors"

    static var customColors: [RGBA] {
        guard let data = UserDefaults.standard.data(forKey: colorsKey) else { return [] }
        return (try? JSONDecoder().decode([RGBA].self, from: data)) ?? []
    }

    /// Remembers a custom color first in the list, keeping the eight most recent. `earlier` is one remembered
    /// moments before while the same color was being picked, so adjusting it keeps one swatch, not one per pause.
    static func remember(_ color: RGBA, replacing earlier: RGBA? = nil) {
        var colors = customColors.filter { $0 != color && $0 != earlier }
        colors.insert(color, at: 0)
        if let data = try? JSONEncoder().encode(Array(colors.prefix(8))) {
            UserDefaults.standard.set(data, forKey: colorsKey)
        }
    }
}
