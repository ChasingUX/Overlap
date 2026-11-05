import AVFoundation
import Testing
@testable import Overlap

/// Exports real files through the exporter, then opens them again to check their format, size, length and
/// loudness.
@MainActor
struct ExportTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ExportTests-\(UUID().uuidString)")

    // MARK: Sources

    /// A stereo 1 kHz sine at a peak level in dBFS, with an optional two-sample full-scale click every two seconds.
    func makeTone(decibels: Double, seconds: Double = 4, clicks: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).wav")
        let sampleRate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let amplitude = Float(pow(10, decibels / 20))
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                samples[frame] = amplitude * sin(2 * .pi * 1000 * Float(frame) / Float(sampleRate))
                if clicks, frame % 96_000 < 2 { samples[frame] = frame % 2 == 0 ? 1 : -1 }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    func toneProject(_ url: URL, seconds: Double = 4) -> (Project, [UUID: URL]) {
        let asset = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Tone", kind: .audio,
                          duration: Time(seconds: seconds), hasAudio: true, sampleRate: 48_000, channelCount: 2)
        var project = Project()
        project.assets = [asset]
        project.tracks[0].clips = [Clip(assetID: asset.id, start: .zero, sourceStart: .zero, duration: Time(seconds: seconds))]
        return (project, [asset.id: url])
    }

    func audioOnly(_ format: ExportSettings.Format) -> ExportSettings {
        var settings = ExportSettings()
        settings.isAudioOnly = true
        settings.audioFormat = format
        return settings
    }

    func export(_ project: Project, urls: [UUID: URL], settings: ExportSettings, name: String = "Export") async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(name).\(settings.format.fileExtension)")
        let job = try await Exporter.job(for: project, assets: { id in urls[id].map { AVURLAsset(url: $0) } },
                                         settings: settings, destination: destination)
        try await Exporter.run(job) { _ in }
        return destination
    }

    // MARK: Reading back

    struct Sound {
        var samples: [Float]
        var format: AudioStreamBasicDescription

        var seconds: Double { Double(samples.count / 2) / format.mSampleRate }

        var loudness: Double? {
            var meter = LoudnessMeter(sampleRate: format.mSampleRate, channels: 2)
            samples.withUnsafeBufferPointer { meter.add($0) }
            return meter.integratedLoudness
        }

        var truePeak: Double {
            20 * log10(Double(TruePeakDetector.truePeak(of: samples, channels: 2)))
        }
    }

    func readSound(_ url: URL) async throws -> Sound {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: PCMReader.floatSettings(sampleRate: format.mSampleRate, channels: 2))
        var samples: [Float] = []
        try await PCMReader.read(asset, output: output) { samples.append(contentsOf: $0) }
        return Sound(samples: samples, format: format)
    }

    func videoTrack(_ url: URL) async throws -> (size: CGSize, codec: FourCharCode, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, descriptions) = try await track.load(.naturalSize, .formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try #require(descriptions.first))
        return (size, codec, try await asset.load(.duration).seconds)
    }

    // MARK: Sound

    @Test func audioExportReachesTheLoudnessTarget() async throws {
        let (project, urls) = toneProject(try makeTone(decibels: -30))
        let sound = try await readSound(try await export(project, urls: urls, settings: audioOnly(.wav)))
        #expect(sound.format.mSampleRate == 48_000)
        #expect(sound.format.mBitsPerChannel == 24)
        #expect(abs(try #require(sound.loudness) + 14) < 0.2)
        #expect(abs(sound.seconds - 4) < 0.01)
    }

    @Test func truePeaksStayUnderMinusOne() async throws {
        // Turning the tone up 10 dB to reach −14 LUFS would push its clicks 10 dB past full scale.
        let (project, urls) = toneProject(try makeTone(decibels: -24, clicks: true))
        let sound = try await readSound(try await export(project, urls: urls, settings: audioOnly(.wav)))
        #expect(sound.truePeak <= -0.95)
        // The level dips for a moment after each click while the limiter lets go, so it lands a little under.
        #expect(abs(try #require(sound.loudness) + 14) < 0.4)
    }

    @Test func offLeavesTheMixAsItPlays() async throws {
        var (project, urls) = toneProject(try makeTone(decibels: -20))
        project.normalizesLoudness = false
        let sound = try await readSound(try await export(project, urls: urls, settings: audioOnly(.wav)))
        #expect(abs(try #require(sound.loudness) + 20) < 0.1)
    }

    @Test func aiffAt44kHzIn16Bits() async throws {
        let (project, urls) = toneProject(try makeTone(decibels: -30))
        var settings = audioOnly(.aiff)
        settings.sampleRate = 44_100
        settings.bitDepth = 16
        let file = try await export(project, urls: urls, settings: settings)
        #expect(file.pathExtension == "aif")
        let sound = try await readSound(file)
        #expect(sound.format.mSampleRate == 44_100)
        #expect(sound.format.mBitsPerChannel == 16)
        #expect(sound.format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0)
        #expect(abs(try #require(sound.loudness) + 14) < 0.2)
    }

    @Test func m4aIsAAC() async throws {
        let (project, urls) = toneProject(try makeTone(decibels: -30))
        let sound = try await readSound(try await export(project, urls: urls, settings: audioOnly(.m4a)))
        #expect(sound.format.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(try #require(sound.loudness) + 14) < 0.5)
    }

    @Test func finishedExportShowsAToast() async throws {
        let (project, _) = toneProject(try makeTone(decibels: -30, seconds: 1), seconds: 1)
        let store = ProjectStore(project: project, mediaDirectory: directory)
        store.exportSettings = audioOnly(.wav)
        let destination = directory.appending(path: "Toast.wav")
        store.export(to: destination)
        let deadline = ContinuousClock.now + .seconds(10)
        while store.isExporting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.toast?.kind == .done)
        #expect(store.toast?.file == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aMissingFolderFailsAtOnce() async throws {
        let (project, urls) = toneProject(try makeTone(decibels: -30, seconds: 30), seconds: 30)
        let job = try await Exporter.job(for: project, assets: { id in urls[id].map { AVURLAsset(url: $0) } },
                                         settings: audioOnly(.wav), destination: directory.appending(path: "Gone/Export.wav"))
        let reports = ProgressCount()
        await #expect(throws: ExportError.cannotSave(in: "Gone")) {
            try await Exporter.run(job) { _ in reports.add() }
        }
        // It stops before measuring anything.
        #expect(reports.value == 0)
    }

    @Test func replacesAnEarlierExport() async throws {
        var (project, urls) = toneProject(try makeTone(decibels: -30))
        _ = try await export(project, urls: urls, settings: audioOnly(.wav))
        project.normalizesLoudness = false
        let sound = try await readSound(try await export(project, urls: urls, settings: audioOnly(.wav)))
        #expect(abs(try #require(sound.loudness) + 30) < 0.2)
        // Nothing is left behind but the sources and the one export.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasSuffix(".wav") || $0 == "Export.wav" }
        #expect(files == ["Export.wav"])
    }

    @Test func canceledExportLeavesNothingBehind() async throws {
        let (project, urls) = toneProject(try makeTone(decibels: -30, seconds: 60), seconds: 60)
        let destination = directory.appending(path: "Canceled.wav")
        let job = try await Exporter.job(for: project, assets: { id in urls[id].map { AVURLAsset(url: $0) } },
                                         settings: audioOnly(.wav), destination: destination)
        let task = Task { try await Exporter.run(job) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
    }

    // MARK: Video

    @Test func finishedVideoAtMinus14LUFS() async throws {
        // The milestone's goal: a picture-in-picture video with a title over a gradient, with sound, brought to
        // −14 LUFS and written as an MP4.
        let pictures = PictureTests()
        let mainURL = try await pictures.makeVideo(PictureTests.red)
        let insetURL = try await pictures.makeVideo(PictureTests.green)
        let main = pictures.asset(mainURL, kind: .video)
        let inset = pictures.asset(insetURL, kind: .video)
        var (project, urls) = toneProject(try makeTone(decibels: -28))
        urls[main.id] = mainURL
        urls[inset.id] = insetURL
        project.assets += [main, inset]
        project.canvas = Canvas(width: 640, height: 360, frameRate: 30)
        project.background = .gradient(GradientFill(from: .black, to: .white, angle: 90))
        var framed = pictures.clip(main, length: 4)
        framed.visual = Visual(scale: 0.8, corners: 0.05, shadow: 40)
        project.tracks[1].clips = [framed]
        var small = pictures.clip(inset, length: 4)
        small.visual = Visual(x: 0.3, y: -0.3, scale: 0.25, corners: 0.1, shadow: 50)
        project.tracks[2].clips = [small]
        var title = Title(text: "██████", size: 50, animationIn: .none, animationOut: .none)
        title.color = .white
        project.addTitle(title, visual: Visual(y: 0.3), at: .zero, target: .new(at: project.tracks.count))

        let file = try await export(project, urls: urls, settings: ExportSettings())
        #expect(file.pathExtension == "mp4")
        let video = try await videoTrack(file)
        #expect(video.size == CGSize(width: 640, height: 360))
        #expect(video.codec == kCMVideoCodecType_H264)
        // The title's five seconds are the longest clip.
        #expect(abs(video.seconds - project.duration.seconds) < 0.05)

        let sound = try await readSound(file)
        #expect(sound.format.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(try #require(sound.loudness) + 14) < 0.5)
        #expect(sound.truePeak < -0.5)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(try pictures.pixel(frame, x: 0.5, y: 0.02).red < 0.25)
        #expect(try pictures.pixel(frame, x: 0.5, y: 0.98).red > 0.75)
        #expect(try pictures.pixel(frame, x: 0.3, y: 0.5).isClose(to: PictureTests.red, within: 0.2))
        #expect(try pictures.pixel(frame, x: 0.74, y: 0.26).isClose(to: PictureTests.green, within: 0.2))
        #expect(try pictures.pixel(frame, x: 0.5, y: 0.8).isClose(to: .white, within: 0.15))
    }

    @Test func scalesDownInHEVC() async throws {
        let pictures = PictureTests()
        let url = try await pictures.makeVideo(PictureTests.blue)
        let clip = pictures.asset(url, kind: .video)
        var project = Project()
        project.assets = [clip]
        project.canvas = Canvas(width: 1920, height: 1080, frameRate: 30)
        project.tracks[0].clips = [pictures.clip(clip)]
        var settings = ExportSettings()
        settings.videoFormat = .mov
        settings.codec = .hevc
        settings.resolution = 720
        settings.quality = .small
        let file = try await export(project, urls: [clip.id: url], settings: settings)
        #expect(file.pathExtension == "mov")
        let video = try await videoTrack(file)
        #expect(video.size == CGSize(width: 1280, height: 720))
        #expect(video.codec == kCMVideoCodecType_HEVC)
        // A project without sound makes a file without a sound track.
        #expect(try await AVURLAsset(url: file).loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func cancelingAVideoMidwayStops() async throws {
        let (tone, urls) = toneProject(try makeTone(decibels: -30, seconds: 20), seconds: 20)
        var project = tone
        project.canvas = Canvas(width: 1920, height: 1080, frameRate: 30)
        project.addBackground(.gradient(GradientFill(from: .black, to: .white)), at: .zero, target: .new(at: 1))
        let clip = try #require(project.tracks[1].clips.first?.id)
        project.tracks[1].clips[0].duration = Time(seconds: 20)
        #expect(project.clip(clip)?.duration == Time(seconds: 20))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = try await Exporter.job(for: project, assets: { id in urls[id].map { AVURLAsset(url: $0) } },
                                         settings: ExportSettings(), destination: directory.appending(path: "Canceled.mp4"))
        let started = ContinuousClock.now
        let task = Task { try await Exporter.run(job) { _ in } }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
    }

    @Test func resolutionsStayAtOrBelowTheCanvas() {
        #expect(ExportSettings.resolutions(below: Canvas(width: 1920, height: 1080, frameRate: 30)) == [nil, 720])
        #expect(ExportSettings.resolutions(below: Canvas(width: 3840, height: 2160, frameRate: 30)) == [nil, 1080, 720])
        var settings = ExportSettings()
        settings.resolution = 1080
        // Portrait keeps its shape: 1080p means the shorter side.
        #expect(settings.pictureSize(for: Canvas(width: 2160, height: 3840, frameRate: 30)) == (1080, 1920))
    }
}

/// Counts progress reports, which arrive from the exporter's own thread.
private final class ProgressCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func add() {
        lock.withLock { count += 1 }
    }
}
