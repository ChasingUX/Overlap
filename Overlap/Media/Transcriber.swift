import AVFoundation
import Speech

/// Writes out what's said in a file with Apple's speech recognition, on the Mac, in the language of the Mac's
/// region when it's one recognition supports, otherwise in English.
enum Transcriber {
    struct Progress: Sendable {
        /// Fetching the language's speech model, the first time it's used.
        var isPreparing: Bool
        /// How far into the file it's got, in seconds.
        var seconds: Double
        var words: [Transcript.Word]
    }

    enum Failure: LocalizedError {
        case unavailable
        case noLanguage
        case noSound

        var errorDescription: String? {
            switch self {
            case .unavailable: "Speech recognition isn't available on this Mac."
            case .noLanguage: "Speech recognition doesn't support this Mac's language."
            case .noSound: "The file has no sound to transcribe."
            }
        }
    }

    /// The rate the sound is read at; the analyzer takes it from there.
    private static let sampleRate = 16_000.0

    /// Every word in `url`'s sound, timed in the file's seconds. `progress` hears the words found so far each time
    /// a phrase is finished.
    static func transcribe(_ url: URL, progress: @escaping @Sendable (Progress) async -> Void) async throws -> [Transcript.Word] {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw Failure.noLanguage }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await progress(Progress(isPreparing: true, seconds: 0, words: []))
            try await request.downloadAndInstall()
        }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noSound }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()

        // Words arrive a phrase at a time, as the analyzer settles each one.
        let collector = Task {
            var words: [Transcript.Word] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
                await progress(Progress(isPreparing: false, seconds: result.range.end.seconds, words: words))
            }
            return words
        }

        return try await withTaskCancellationHandler {
            try await analyzer.start(inputSequence: inputs)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track],
                                                     audioSettings: PCMReader.floatSettings(sampleRate: sampleRate, channels: 1))
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                throw Failure.noSound
            }
            var position: AVAudioFramePosition = 0
            var failure: Error?
            try await PCMReader.read(asset, output: output) { samples in
                guard failure == nil, !samples.isEmpty,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0], let base = samples.baseAddress else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                channel.update(from: base, count: samples.count)
                do {
                    for converted in try converter.convert(buffer, at: AVAudioTime(sampleTime: position, atRate: sampleRate)) {
                        input.yield(converted)
                    }
                } catch {
                    failure = error
                }
                position += AVAudioFramePosition(samples.count)
            }
            if let failure { throw failure }
            for converted in try converter.flush() { input.yield(converted) }
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } onCancel: {
            input.finish()
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The timed words in a result. A run with no time of its own, such as punctuation, joins the word before it;
    /// a run holding more than one word shares its time between them by length.
    static func words(in text: AttributedString) -> [Transcript.Word] {
        var words: [Transcript.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                if !words.isEmpty { words[words.count - 1].text += piece }
                continue
            }
            let start = range.start.seconds
            let length = range.duration.seconds
            let parts = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            let letters = Double(parts.reduce(0) { $0 + $1.count })
            var offset = 0.0
            for part in parts {
                let share = letters > 0 ? length * Double(part.count) / letters : length / Double(parts.count)
                words.append(Transcript.Word(text: part, start: start + offset, end: start + offset + share))
                offset += share
            }
        }
        return words
    }
}
