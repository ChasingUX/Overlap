import Foundation
import Testing
@testable import Overlap

/// Live captions: phrases made from the transcript, the clips a captions track shows, and changing them.
struct CaptionTests {
    let video = Asset(id: UUID(), fileName: "v.mov", displayName: "Walkthrough.mov", kind: .video, duration: Time(seconds: 30),
                      hasAudio: true, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30)

    func seconds(_ value: Double) -> Time { Time(seconds: value) }

    /// Words a quarter second apart, from `start`, each a fifth of a second long.
    func words(_ text: String, from start: Double) -> [Transcript.Word] {
        text.split(separator: " ").enumerated().map { index, word in
            Transcript.Word(text: String(word), start: start + Double(index) * 0.25, end: start + Double(index) * 0.25 + 0.2)
        }
    }

    var speech: Transcript {
        Transcript(words: words("Hi, um, I'm going to walk you through the new dashboard.", from: 0)
            + words("First, open Settings from the sidebar, and you'll see Reports.", from: 5)
            + words("Pick who can see it.", from: 12))
    }

    func project(captions: Captions? = Captions()) -> Project {
        var project = Project()
        project.assets = [video]
        project.tracks[0].clips = [Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: seconds(20))]
        if let captions { project.tracks.append(Track(name: "Captions", captions: captions)) }
        return project
    }

    func phrases(lines: Int = 1) -> [CaptionPhrase] {
        project().timelineTranscript([video.id: speech]).captionPhrases(lines: lines)
    }

    @Test func phrasesBreakAtSentencesCommasAndFullLines() {
        // "um," is left out; a full line doesn't end on "from the", which go on with "sidebar,", and a comma ends a
        // caption once it's half full.
        #expect(phrases().map(\.text) == [
            "Hi, I'm going to walk you",
            "through the new dashboard.",
            "First, open Settings",
            "from the sidebar,",
            "and you'll see Reports.",
            "Pick who can see it.",
        ])
    }

    @Test func eachCaptionShowsUntilTheNextOrAMomentAfter() throws {
        let all = phrases()
        // Close together, a caption runs on into the next; never over it.
        #expect(all[0].range.end == all[1].range.start)
        for (one, next) in zip(all, all.dropFirst()) {
            #expect(one.range.end <= next.range.start)
        }
        // The last stays up a moment after its last word.
        let last = try #require(all.last)
        #expect(last.range.end == seconds(12 + 4 * 0.25 + 0.2) + TimelineTranscript.captionHold)
        // Words are timed from their caption's start, and found in its text.
        let first = try #require(all.first?.words.last)
        #expect(abs(first.start - 1.5) < 0.001)
        #expect((all[0].text as NSString).substring(with: NSRange(location: first.location, length: first.length)) == "you")
    }

    @Test func twoLinesBreakNearTheMiddleAtACommaWhenThereIsOne() {
        let two = phrases(lines: 2)
        #expect(two.first?.text == "Hi, I'm going to walk you\nthrough the new dashboard.")
        // Not after "from" or "the", which lead into what follows.
        #expect(two.contains { $0.text == "First, open Settings\nfrom the sidebar," })
    }

    @Test func captionsExportAsSubRip() {
        let srt = project().timelineTranscript([video.id: speech]).srt(lines: 1)
        let blocks = srt.components(separatedBy: "\n\n")
        #expect(blocks.count == 6)
        #expect(blocks[0] == "1\n00:00:00,000 --> 00:00:01,750\nHi, I'm going to walk you")
        #expect(blocks[5].hasPrefix("6\n00:00:12,000 --> 00:00:13,800\nPick who can see it."))
        // Two lines stay two lines.
        #expect(project().timelineTranscript([video.id: speech]).srt(lines: 2).contains("you\nthrough the new dashboard."))
    }

    @Test func aCaptionsTrackIsFilledAsTheProjectShows() throws {
        let stored = project()
        let transcript = stored.timelineTranscript([video.id: speech])
        let shown = stored.withCaptions(transcript)
        let track = try #require(shown.tracks.last)
        #expect(stored.tracks.last?.clips.isEmpty == true)
        #expect(track.clips.count == 6)
        // In the middle of the bottom, a margin up, with no animation.
        let caption = try #require(track.clips.first)
        #expect(caption.visual.x == 0)
        #expect(caption.visual.y > 0.3)
        #expect(caption.title?.animationIn == TitleAnimation.none)
        // Made again, each keeps its ID.
        #expect(stored.withCaptions(transcript).tracks.last?.clips.map(\.id) == track.clips.map(\.id))
        #expect(shown.captionsTrack(ofClip: caption.id) == track.id)
    }

    @Test func aCaptionsTrackStaysAndTakesNothingElse() {
        var edited = project()
        edited.normalizeTracks()
        #expect(edited.hasCaptions)
        let index = edited.tracks.count - 1
        #expect(!edited.isFree(track: index, range: TimeRange(start: .zero, duration: seconds(1))))
    }

    @Test func captionsStayAboveEveryOtherTrack() throws {
        var edited = project()
        edited.normalizeTracks()
        let captions = try #require(edited.tracks.last?.id)
        // Moved under the video, as a project saved before captions kept to the top might have them.
        edited.tracks.insert(edited.tracks.removeLast(), at: 0)
        edited.normalizeTracks()
        #expect(edited.tracks.last?.id == captions)
    }

    @Test func newTracksGoUnderCaptionsSoNothingCoversThem() throws {
        var edited = project()
        edited.normalizeTracks()
        let captions = try #require(edited.tracks.last?.id)
        // Added at the playhead on a new top track, as the Media and Text tabs add.
        let top = edited.tracks.count
        let added = edited.addClip(asset: video.id, at: .zero, target: .new(at: top))
        let addedID = try #require(added?.id)
        #expect(edited.tracks.last?.id == captions)
        #expect(edited.location(ofClip: addedID)?.track == edited.tracks.count - 2)
        // With every track taken where it goes, the new one goes under the captions too.
        let another = edited.addClip(asset: video.id, at: .zero, preferredTrack: 0)
        let anotherID = try #require(another?.id)
        #expect(edited.tracks.last?.id == captions)
        #expect(edited.location(ofClip: anotherID)?.track == edited.tracks.count - 2)
    }

    @Test func theSpokenWordIsLitWhenAsked() {
        // "Hi, I'm going to walk you": "I'm" starts half a second in.
        var title = Title(text: phrases()[0].text)
        title.spokenWords = phrases()[0].words
        #expect(title.lit(at: 0.6).litWord == nil)
        title.highlightsSpokenWord = true
        #expect(title.lit(at: -0.1).litWord == nil)
        #expect(title.lit(at: 0.6).litWord == 1)
        #expect(title.lit(at: 99).litWord == 5)
    }

    @Test func captionsAreSavedButTheirWordsAreNot() throws {
        var look = Captions.defaultLook
        look.spokenWords = [SpokenWord(start: 0, end: 1, location: 0, length: 2)]
        look.litWord = 0
        let track = Track(name: "Captions", captions: Captions(look: look, lines: 2, highlightsSpokenWord: true))
        let data = try JSONEncoder().encode(track)
        #expect(!String(decoding: data, as: UTF8.self).contains("spokenWords"))
        let read = try JSONDecoder().decode(Track.self, from: data)
        #expect(read.captions?.lines == 2)
        #expect(read.captions?.highlightsSpokenWord == true)
        #expect(read.captions?.look.spokenWords == nil)
        #expect(read.captions?.look.anchor == .bottom)
    }

    @MainActor
    func store() -> ProjectStore {
        let store = ProjectStore(mediaDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        store.load(project(captions: nil), mediaDirectory: store.mediaDirectory, transcripts: [video.id: speech])
        return store
    }

    @MainActor
    @Test func addingCaptionsSelectsThemInTheTextTab() throws {
        let store = store()
        store.showTab(.transcript)
        store.addCaptions()
        let track = try #require(store.selectedCaptionsTrack)
        #expect(store.activeTab == .text)
        #expect(store.shownProject.tracks.last?.clips.count == 6)
        // The Text tab's changes go to every caption.
        store.setTitle("Change Size") { $0.size = 60 }
        #expect(store.project.tracks.last?.captions?.look.size == 60)
        #expect(store.shownProject.tracks.last?.clips.allSatisfy { $0.title?.size == 60 } == true)
        // Clicking a caption selects them; clicking elsewhere goes back to the Transcript tab.
        store.select([])
        #expect(store.selectedCaptions == nil)
        #expect(store.activeTab == .transcript)
        let caption = try #require(store.shownProject.tracks.last?.clips.first)
        store.select([caption.id])
        #expect(store.selectedCaptions == track.id)
        #expect(store.selection.isEmpty)
        store.deleteSelection()
        #expect(!store.project.hasCaptions)
    }

    @MainActor
    @Test func typingOverACaptionFixesItsWords() throws {
        let store = store()
        store.addCaptions()
        let caption = try #require(store.shownProject.tracks.last?.clips.first { $0.title?.text == "First, open Settings" })
        store.beginEditingTitle(caption.id)
        #expect(store.editingTitleClip == caption.id)
        store.endEditingTitle(text: "First, open Preferences")
        #expect(store.transcripts[video.id]?.words.map(\.text).contains("Preferences") == true)
        #expect(store.shownProject.tracks.last?.clips.contains { $0.title?.text == "First, open Preferences" } == true)
        // Still selected, in the Text tab.
        #expect(store.selectedCaptions != nil)
    }

    @MainActor
    @Test func captionsFollowCutsAndFixedWords() throws {
        let store = store()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.addCaptions()
        undo.endUndoGrouping()
        let before = try #require(store.shownProject.tracks.last?.clips.last)
        // Taking out the long pause before "Pick" brings the last caption earlier.
        undo.beginUndoGrouping()
        store.removePausesAndFillers()
        undo.endUndoGrouping()
        let after = try #require(store.shownProject.tracks.last?.clips.last)
        #expect(after.title?.text == before.title?.text)
        #expect(after.start < before.start)

        let index = try #require(store.timelineTranscript.items.firstIndex {
            if case let .word(text, _, _, _) = $0 { text == "Settings" } else { false }
        })
        let source = try #require(store.timelineTranscript.sources[index])
        undo.beginUndoGrouping()
        store.correctWords([source], to: "Preferences")
        undo.endUndoGrouping()
        #expect(store.shownProject.tracks.last?.clips.contains { $0.title?.text.contains("Preferences") == true } == true)
        #expect(undo.undoActionName == "Fix Word")
        undo.undo()
        #expect(store.transcripts[video.id]?.words.contains { $0.text == "Settings" } == true)
    }
}
