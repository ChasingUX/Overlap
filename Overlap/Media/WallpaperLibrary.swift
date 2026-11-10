import Foundation

/// Wallpapers kept for every project, copied into ~/Library/Application Support/Overlap/Wallpapers. A project copies
/// one into its package when it uses it.
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
}
