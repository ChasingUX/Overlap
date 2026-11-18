import CoreMedia
import Foundation
import Speech
import Testing
@testable import Overlap

/// The Transcript tab: words placed on the timeline, the pauses and fillers it marks, and the cuts it makes.
struct TranscriptTests {
    let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Walkthrough.mov", kind: .video, duration: Time(seconds: 30),
                      hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)
    let song = Asset(id: UUID(), fileName: "s.m4a", displayName: "Theme.m4a", kind: .audio, duration: Time(seconds: 30),
                     hasAudio: true, sampleRate: 48_000, channelCount: 2)

    func seconds(_ value: Double) -> Time { Time(seconds: value) }

    func word(_ text: String, _ start: Double, _ end: Double) -> Transcript.Word {
        Transcript.Word(text: text, start: start, end: end)
    }

    /// "Hi there. ⟨1.5 s⟩ Um, open Settings. ⟨2.5 s⟩ Then press Done." over the video's first 13 seconds.
    var speech: Transcript {
        Transcript(words: [
            word("Hi", 0, 0.4), word("there.", 0.4, 1),
            word("Um,", 2.5, 3), word("open", 3, 3.4), word("Settings.", 3.4, 4),
            word("Then", 6.5, 6.8), word("press", 6.8, 7.2), word("Done.", 7.2, 8),
        ])
    }

    func project(_ clips: [Clip], onTracks tracks: [Int]? = nil) -> Project {
        var project = Project()
        project.assets = [video, song]
        for (index, clip) in clips.enumerated() {
            project.tracks[tracks?[index] ?? 0].clips.append(clip)
        }
        return project
    }

    func words(_ transcript: TimelineTranscript) -> [String] {
        transcript.items.map { item in
            switch item {
            case let .word(text, _, _, _): text
            case .pause: "·"
            }
        }
    }

    @Test func wordsLandWhereTheClipPlaysThem() throws {
        // Two seconds into the file, at 10 s on the timeline, at double speed.
        var clip = Clip(assetID: video.id, start: seconds(10), sourceStart: seconds(2.5), duration: seconds(3))
        clip.speed = 2
        let transcript = project([clip]).timelineTranscript([video.id: speech])
        // Only words the clip plays, from "Um," at 2.5 s in the file up to 8.5 s.
        #expect(words(transcript) == ["Um,", "open", "Settings.", "·", "Then", "press", "Done."])
        let first = try #require(transcript.items.first)
        #expect(first.range == TimeRange(start: seconds(10), duration: seconds(0.25)))
        let pauses = transcript.items.filter(\.isPause)
        let pause = try #require(pauses.first)
        #expect(pause.range == TimeRange(from: seconds(10.75), to: seconds(12)))
    }

    @Test func pausesAndFillersAreMarkedAndLongSilencesStartParagraphs() {
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        let transcript = project([clip]).timelineTranscript([video.id: speech])
        #expect(transcript.pauseCount == 2)
        #expect(transcript.fillerCount == 1)
        // The 2.5-second silence after "Settings." ends a paragraph; the pause stays with the sentence before it.
        #expect(transcript.paragraphs.count == 2)
        #expect(transcript.paragraphs[0].items.last?.isPause == true)
        #expect(transcript.paragraphs[1].start == seconds(6.5))
        #expect(Transcript.Word(text: "Uh...", start: 0, end: 1).isFiller)
        #expect(!Transcript.Word(text: "so,", start: 0, end: 1).isFiller)
    }

    @Test func removingShortensPausesAndTakesOutFillers() {
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        let cuts = project([clip]).timelineTranscript([video.id: speech]).removable.map(\.range)
        // The pause before "Um," and "Um," itself go as one, leaving a fifth of a second after "there."; the
        // second pause keeps a fifth of a second either side.
        #expect(cuts == [TimeRange(from: seconds(1.2), to: seconds(3)), TimeRange(from: seconds(4.2), to: seconds(6.3))])
    }

    @Test func cuttingClosesUpTheTrackAndLeavesOthers() throws {
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        let later = Clip(assetID: video.id, start: seconds(12), sourceStart: seconds(20), duration: seconds(4))
        let music = Clip(assetID: song.id, start: .zero, sourceStart: .zero, duration: seconds(20))
        var edited = project([clip, later, music], onTracks: [0, 0, 1])
        edited.cut([TranscriptCut(clip: clip.id, range: TimeRange(from: seconds(4), to: seconds(6)))])
        let pieces = edited.tracks[0].clips.sorted { $0.start < $1.start }
        #expect(pieces.map(\.start) == [.zero, seconds(4), seconds(10)])
        #expect(pieces.map(\.duration) == [seconds(4), seconds(4), seconds(4)])
        // The second piece plays on from after the cut.
        #expect(pieces[1].sourceStart == seconds(6))
        #expect(edited.tracks[1].clips == [music])
    }

    @Test func aVideosSplitSoundIsCutWithIt() {
        var picture = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        picture.usesAudio = false
        var sound = picture
        sound.id = UUID()
        sound.usesAudio = true
        sound.usesVideo = false
        var edited = project([picture, sound], onTracks: [1, 0])
        edited.cut([TranscriptCut(clip: sound.id, range: TimeRange(from: seconds(2), to: seconds(3)))])
        #expect(edited.tracks[0].clips.map(\.duration) == [seconds(2), seconds(7)])
        #expect(edited.tracks[1].clips.map(\.duration) == [seconds(2), seconds(7)])
    }

    @Test func cutsStayOutOfCrossfades() {
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        // Overlaps the last second of the first clip.
        let next = Clip(assetID: video.id, start: seconds(9), sourceStart: seconds(15), duration: seconds(5))
        var edited = project([clip, next])
        edited.cut([TranscriptCut(clip: clip.id, range: TimeRange(from: seconds(8), to: seconds(9.5)))])
        // Only 8–8.9 goes, leaving the piece after it a tenth of a second before the crossfade, which keeps its second.
        let pieces = edited.tracks[0].clips.sorted { $0.start < $1.start }
        #expect(pieces.map(\.start) == [.zero, seconds(8), seconds(8.1)])
        #expect(pieces.map(\.end) == [seconds(8), seconds(9.1), seconds(13.1)])
        #expect(edited.crossfades(onTrack: 0).map(\.range.duration) == [seconds(1)])
        #expect(Project.isPlayable(pieces))
    }

    @Test func selectedWordsCutUpToTheNextWord() {
        let first = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(5))
        let second = Clip(assetID: video.id, start: seconds(5), sourceStart: seconds(6), duration: seconds(3))
        let transcript = project([first, second]).timelineTranscript([video.id: speech])
        // "Um, open" in the first clip, then from "Settings." across into the second clip's "Then".
        #expect(words(transcript) == ["Hi", "there.", "·", "Um,", "open", "Settings.", "Then", "press", "Done."])
        let selected = transcript.cuts(covering: IndexSet([3, 4]))
        #expect(selected == [TranscriptCut(clip: first.id, range: TimeRange(from: seconds(2.5), to: seconds(3.4)))])
        let across = transcript.cuts(covering: IndexSet(5...6))
        #expect(across == [
            TranscriptCut(clip: first.id, range: TimeRange(from: seconds(3.4), to: seconds(4))),
            TranscriptCut(clip: second.id, range: TimeRange(from: seconds(5.5), to: seconds(5.8))),
        ])
    }

    @Test func recognizedTextBecomesTimedWords() {
        func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var piece = AttributedString(text)
            piece[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] =
                CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
            return piece
        }
        var text = timed("Hi", 0, 0.5)
        text += AttributedString(",")
        text += timed(" good morning", 0.5, 1.5)
        let words = Transcriber.words(in: text)
        #expect(words.map(\.text) == ["Hi,", "good", "morning"])
        #expect(words[1].start == 0.5)
        #expect(abs(words[2].end - 1.5) < 0.001)
    }

    @MainActor
    @Test func theTabGoesWithTheLastVideo() throws {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        store.load(project([clip]), mediaDirectory: store.mediaDirectory, transcripts: [video.id: speech, song.id: speech])
        #expect(store.project.hasVideoClips)
        #expect(!store.timelineTranscript.isEmpty)
        store.showTab(.transcript)
        store.apply("Delete") { $0.removeClips([clip.id]) }
        #expect(store.activeTab == .media)
        #expect(store.timelineTranscript.isEmpty)
        // Transcripts of media the project no longer has aren't saved.
        store.apply("Remove") { $0.removeAsset(self.song.id) }
        #expect(Set(store.transcriptsToSave.keys) == [video.id])
    }

    @MainActor
    @Test func removingIsOneUndoableStep() {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let undo = UndoManager()
        store.undoManager = undo
        let clip = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(10))
        store.load(project([clip]), mediaDirectory: store.mediaDirectory, transcripts: [video.id: speech])
        // Grouped by hand, as there's no event loop to group it.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        store.removePausesAndFillers()
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Remove Pauses and Fillers")
        #expect(store.project.tracks[0].clips.count == 3)
        #expect(store.timelineTranscript.pauseCount == 0)
        #expect(store.timelineTranscript.fillerCount == 0)
        undo.undo()
        #expect(store.project.tracks[0].clips.count == 1)
        #expect(store.timelineTranscript.pauseCount == 2)
    }
}
