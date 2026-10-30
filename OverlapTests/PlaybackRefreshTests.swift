import AVFoundation
import Testing
@testable import Overlap

/// Edits that only change how things look or sound go straight into the player item that's playing, so they show
/// on its next frame; edits that move clips need a new item.
@MainActor
struct PlaybackRefreshTests {
    func store() async throws -> (ProjectStore, Clip) {
        let pictures = PictureTests()
        let url = try await pictures.makeVideo(PictureTests.red)
        let asset = pictures.asset(url, kind: .video)
        var project = Project()
        project.assets = [asset]
        project.canvas = pictures.canvas
        project.tracks[0].clips = [pictures.clip(asset)]
        let store = ProjectStore(project: project, mediaDirectory: url.deletingLastPathComponent())
        store.rebuildPlayback()
        try await waitUntil { store.playback.player.currentItem != nil }
        return (store, project.tracks[0].clips[0])
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func lookEditsKeepThePlayerItem() async throws {
        let (store, clip) = try await store()
        let item = store.playback.player.currentItem
        store.apply("Look") { $0.changeVisual(of: [clip.id]) { $0.opacity = 0.5 } }
        try await waitUntil { store.playback.plan?.current.layers.first?.visual.opacity == 0.5 }
        #expect(store.playback.player.currentItem === item)
    }

    @Test func movingAClipMakesANewItem() async throws {
        let (store, clip) = try await store()
        let item = store.playback.player.currentItem
        store.apply("Move") { $0.tracks[0].clips[0].start = clip.start + Time(seconds: 1) }
        try await waitUntil { store.playback.player.currentItem !== item }
    }

    @Test func layoutAndMixTellLooksFromSoundsFromMoves() {
        var project = Project()
        let asset = UUID()
        project.tracks[0].clips = [Clip(assetID: asset, start: .zero, sourceStart: .zero, duration: Time(seconds: 2))]
        let options = CompositionBuilder.Options()
        let layout = CompositionBuilder.layout(of: project)
        let mix = CompositionBuilder.mix(of: project, options: options)

        var looks = project
        looks.tracks[0].clips[0].visual.scale = 0.5
        looks.tracks[0].isMuted = true
        #expect(CompositionBuilder.layout(of: looks) == layout)

        var sounds = project
        sounds.tracks[0].clips[0].volume = 0.5
        #expect(CompositionBuilder.layout(of: sounds) == layout)
        #expect(CompositionBuilder.mix(of: sounds, options: options) != mix)
        #expect(CompositionBuilder.mix(of: looks, options: options) != mix)

        var moved = project
        moved.tracks[0].clips[0].start = Time(seconds: 1)
        #expect(CompositionBuilder.layout(of: moved) != layout)

        var isolated = project
        isolated.tracks[0].clips[0].isolatesVoice = true
        #expect(CompositionBuilder.layout(of: isolated) != layout)
    }
}
