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

    private static let builtInColors = BackgroundFill.colors.compactMap { fill -> RGBA? in
        if case let .color(color) = fill { color } else { nil }
    }

    /// Your colors, most recent first.
    static var customColors: [RGBA] {
        guard let data = UserDefaults.standard.data(forKey: colorsKey),
              let kept = try? JSONDecoder().decode([RGBA].self, from: data) else { return [] }
        return shown(kept)
    }

    /// Remembers a custom color first in the list, keeping the eight most recent, and returns the color to use.
    @discardableResult
    static func remember(_ color: RGBA, replacing earlier: RGBA? = nil) -> RGBA {
        let (kept, use) = remembering(color, replacing: earlier, in: customColors)
        save(kept)
        return use
    }

    /// The kept colors to show: any that look the same as a built-in color or one before them are left out, as
    /// colors kept before near-copies were skipped can.
    static func shown(_ kept: [RGBA]) -> [RGBA] {
        var shown: [RGBA] = []
        for color in kept where !(builtInColors + shown).contains(where: { $0.isNear(color) }) {
            shown.append(color)
        }
        return shown
    }

    /// The kept colors after remembering `color`, and the color to use. One that looks the same as a built-in color
    /// or a kept one isn't kept again: that one is used instead. `earlier` is one remembered moments before while
    /// the same color was being picked, so adjusting it keeps one swatch, not one per pause.
    static func remembering(_ color: RGBA, replacing earlier: RGBA?, in kept: [RGBA]) -> (kept: [RGBA], use: RGBA) {
        var colors = kept.filter { $0 != earlier }
        if let builtIn = builtInColors.first(where: { $0.isNear(color) }) {
            return (colors, builtIn)
        }
        let use = colors.first { $0.isNear(color) } ?? color
        colors.removeAll { $0 == use }
        colors.insert(use, at: 0)
        return (Array(colors.prefix(8)), use)
    }

    private static func save(_ colors: [RGBA]) {
        if let data = try? JSONEncoder().encode(colors) {
            UserDefaults.standard.set(data, forKey: colorsKey)
        }
    }
}
