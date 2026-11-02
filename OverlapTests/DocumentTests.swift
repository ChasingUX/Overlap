import Foundation
import Testing
@testable import Overlap

@MainActor
struct DocumentTests {
    @Test func saveWritesAPackageThatOpensUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let package = folder.appending(path: "Saved.overlap", directoryHint: .isDirectory)

        // An untitled document keeps imported media in its staging folder until the first save.
        let document = ProjectDocument()
        let asset = Asset(id: UUID(), fileName: "song.m4a", displayName: "Song.m4a", kind: .audio, duration: Time(seconds: 3), hasAudio: true)
        try FileManager.default.createDirectory(at: document.store.mediaDirectory, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: document.store.mediaURL(for: asset))
        document.store.apply("Import Media") { project in
            project.assets.append(asset)
            project.addClip(asset: asset.id, at: Time(seconds: 1), preferredTrack: 0)
        }

        try document.write(to: package, ofType: "com.chasingux.overlap.project", for: .saveOperation, originalContentsURL: nil)
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "Project.json").path))
        #expect(try Data(contentsOf: package.appending(path: "Media/song.m4a")) == Data("media".utf8))

        let reopened = ProjectDocument()
        try reopened.read(from: package, ofType: "com.chasingux.overlap.project")
        #expect(reopened.store.project == document.store.project)
        #expect(reopened.store.mediaURL(for: asset).path == package.appending(path: "Media/song.m4a").path)
    }

    @Test func removedMediaIsLeftOutOfTheNextSave() throws {
        let package = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).overlap", directoryHint: .isDirectory)
        let document = ProjectDocument()
        let asset = Asset(id: UUID(), fileName: "old.wav", displayName: "Old.wav", kind: .audio, duration: Time(seconds: 1), hasAudio: true)
        try FileManager.default.createDirectory(at: document.store.mediaDirectory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: document.store.mediaURL(for: asset))
        document.store.apply("Import Media") { $0.assets.append(asset) }
        document.store.removeAsset(asset.id)

        try document.write(to: package, ofType: "com.chasingux.overlap.project", for: .saveOperation, originalContentsURL: nil)
        #expect(!FileManager.default.fileExists(atPath: package.appending(path: "Media/old.wav").path))
    }
}
