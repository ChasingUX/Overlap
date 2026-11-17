import Foundation
import Testing
@testable import Overlap

/// What the Media tab shows for each asset, and adding one at the playhead.
@MainActor
struct MediaPanelTests {
    func asset(_ name: String, kind: AssetKind = .audio, seconds: Double = 20) -> Asset {
        Asset(id: UUID(), fileName: "a", displayName: name, kind: kind, duration: Time(seconds: seconds), hasAudio: kind != .image)
    }

    @Test func namesLeaveOffTheirFilesExtension() {
        #expect(asset("Theme.m4a").shownName == "Theme")
        #expect(asset("prism-1920x1080-15s.mp4", kind: .video).shownName == "prism-1920x1080-15s")
        #expect(asset("Logo.PNG", kind: .image).shownName == "Logo")
        // A dot that isn't before a media file's extension stays.
        #expect(asset("Screen Recording 2026-11-14 at 10.42.13", kind: .video).shownName == "Screen Recording 2026-11-14 at 10.42.13")
        #expect(asset("v1.2 final", kind: .video).shownName == "v1.2 final")
    }

    @Test func eachSaysWhatItIsAndHowLong() {
        #expect(asset("Theme.m4a").summary == "Audio · 0:20")
        #expect(asset("Clip.mov", kind: .video, seconds: 102).summary == "Video · 1:42")
        #expect(asset("Logo.png", kind: .image, seconds: 0).summary == "Image")
    }

    @Test func addingAtThePlayheadPutsItOnANewTopTrack() throws {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let song = asset("Theme.m4a")
        store.apply("Import Media") { project in
            project.assets = [song]
            project.addClip(asset: song.id, at: .zero, preferredTrack: 0)
        }
        let tracks = store.project.tracks.count
        store.playback.seek(to: Time(seconds: 3))
        store.addAssetAtPlayhead(song.id)
        let added = try #require(store.selectedClips.first)
        #expect(added.start == Time(seconds: 3))
        #expect(store.project.tracks.count == tracks + 1)
        #expect(store.project.tracks.last?.clips.map(\.id) == [added.id])
    }
}
