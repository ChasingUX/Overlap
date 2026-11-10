import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Overlap

/// Renders frames through the same composition and compositor the player uses, then reads pixels back.
@MainActor
struct PictureTests {
    struct Pixel {
        var red: Double
        var green: Double
        var blue: Double

        func isClose(to color: RGBA, within tolerance: Double = 0.08) -> Bool {
            abs(red - color.red) <= tolerance && abs(green - color.green) <= tolerance && abs(blue - color.blue) <= tolerance
        }
    }

    static let red = RGBA(red: 1, green: 0, blue: 0)
    static let green = RGBA(red: 0, green: 1, blue: 0)
    static let blue = RGBA(red: 0, green: 0, blue: 1)

    let canvas = Canvas(width: 320, height: 180)
    let directory = FileManager.default.temporaryDirectory.appending(path: "PictureTests-\(UUID().uuidString)")

    // MARK: Sources

    func makeImage(_ color: RGBA, width: Int = 160, height: Int = 90) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Two seconds of one color, at 30 fps.
    func makeVideo(_ color: RGBA, width: Int = 320, height: Int = 180) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = UInt8(color.blue * 255)
                pixel[1] = UInt8(color.green * 255)
                pixel[2] = UInt8(color.red * 255)
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0...60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        // Without an end, the last frame has no length and the clip can't be inserted to the end of the file.
        writer.endSession(atSourceTime: CMTime(value: 61, timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    func asset(_ url: URL, kind: AssetKind) -> Asset {
        Asset(id: UUID(), fileName: url.lastPathComponent, displayName: url.lastPathComponent, kind: kind,
              duration: kind == .image ? .zero : Time(seconds: 2), hasAudio: false, pixelWidth: canvas.width, pixelHeight: canvas.height,
              frameRate: 30)
    }

    // MARK: Rendering

    /// The frame at `time`, read back as sRGB.
    func frame(of project: Project, urls: [UUID: URL], at time: Double) async throws -> CGImage {
        var project = project
        project.canvas = canvas
        let built = try await CompositionBuilder.build(project: project, assets: { id in urls[id].map { AVURLAsset(url: $0) } })
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// The color at a point given as shares of the frame's width and height, measured from the top left.
    func pixel(_ image: CGImage, x: Double, y: Double) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = Double(image.width) * x
        let py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        return Pixel(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }

    func clip(_ asset: Asset, at start: Double = 0, length: Double = 2) -> Clip {
        Clip(assetID: asset.id, start: Time(seconds: start), sourceStart: .zero, duration: Time(seconds: length))
    }

    // MARK: Tests

    @Test func backgroundClipFillsTheCanvas() async throws {
        var project = Project()
        project.addBackground(.color(Self.blue), at: .zero, target: .existing(project.tracks[0].id))
        let image = try await frame(of: project, urls: [:], at: 1)
        #expect(try pixel(image, x: 0.5, y: 0.5).isClose(to: Self.blue))
        #expect(try pixel(image, x: 0.05, y: 0.95).isClose(to: Self.blue))
    }

    @Test func scaledImageSitsOverTheCanvasBackground() async throws {
        let url = try makeImage(Self.green)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        project.background = .color(Self.blue)
        var still = clip(image)
        still.visual.scale = 0.5
        project.tracks[0].clips = [still]
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: Self.green))
        #expect(try pixel(rendered, x: 0.1, y: 0.1).isClose(to: Self.blue))
    }

    @Test func pictureInPicture() async throws {
        let mainURL = try await makeVideo(Self.red)
        let insetURL = try await makeVideo(Self.green)
        let main = asset(mainURL, kind: .video)
        let inset = asset(insetURL, kind: .video)
        var project = Project()
        project.assets = [main, inset]
        project.tracks[0].clips = [clip(main)]
        var small = clip(inset)
        small.visual.scale = 0.3
        small.visual.x = 0.3
        small.visual.y = 0.3
        project.tracks[1].clips = [small]
        let rendered = try await frame(of: project, urls: [main.id: mainURL, inset.id: insetURL], at: 1)
        // Video compression shifts solid colors a little.
        #expect(try pixel(rendered, x: 0.8, y: 0.8).isClose(to: Self.green, within: 0.2))
        #expect(try pixel(rendered, x: 0.25, y: 0.25).isClose(to: Self.red, within: 0.2))
    }

    @Test func overlappingPicturesDissolve() async throws {
        let redURL = try makeImage(Self.red)
        let greenURL = try makeImage(Self.green)
        let first = asset(redURL, kind: .image)
        let second = asset(greenURL, kind: .image)
        var project = Project()
        project.assets = [first, second]
        project.defaultCrossfadeCurve = .linear
        // Overlapping from 2 s to 4 s.
        project.tracks[0].clips = [clip(first, at: 0, length: 4), clip(second, at: 2, length: 4)]
        let urls = [first.id: redURL, second.id: greenURL]
        #expect(try pixel(try await frame(of: project, urls: urls, at: 1), x: 0.5, y: 0.5).isClose(to: Self.red))
        #expect(try pixel(try await frame(of: project, urls: urls, at: 5), x: 0.5, y: 0.5).isClose(to: Self.green))
        // Halfway through, both show equally.
        let middle = try pixel(try await frame(of: project, urls: urls, at: 3), x: 0.5, y: 0.5)
        #expect(abs(middle.red - middle.green) < 0.08)
        #expect(middle.red > 0.3 && middle.red < 0.9)
    }

    @Test func dipToBlackIsBlackHalfway() async throws {
        let redURL = try makeImage(Self.red)
        let greenURL = try makeImage(Self.green)
        let first = asset(redURL, kind: .image)
        let second = asset(greenURL, kind: .image)
        var project = Project()
        project.assets = [first, second]
        var incoming = clip(second, at: 2, length: 4)
        incoming.crossfadeVideoStyle = .dipToBlack
        project.tracks[0].clips = [clip(first, at: 0, length: 4), incoming]
        let middle = try pixel(try await frame(of: project, urls: [first.id: redURL, second.id: greenURL], at: 3), x: 0.5, y: 0.5)
        #expect(middle.isClose(to: .black, within: 0.06))
    }

    @Test func titleDrawsText() async throws {
        var project = Project()
        project.background = .color(.black)
        var title = Title(text: "█████")
        title.animationIn = .none
        title.animationOut = .none
        title.size = 60
        project.addTitle(title, at: .zero, target: .existing(project.tracks[0].id))
        let rendered = try await frame(of: project, urls: [:], at: 2)
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: .white, within: 0.15))
        #expect(try pixel(rendered, x: 0.05, y: 0.1).isClose(to: .black))
    }

    @Test func shadowShowsOnADarkBackground() async throws {
        let url = try makeImage(Self.red, width: 320, height: 180)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        let dark = RGBA(red: 0.11, green: 0.11, blue: 0.118)
        project.background = .color(dark)
        project.frame = PictureFrame(shadow: 100)
        var still = clip(image)
        still.visual = Visual(scale: 0.6)
        project.tracks[0].clips = [still]
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        // The picture ends at 0.8 down. Just below it the background is clearly darker; further down it's untouched.
        let below = try pixel(rendered, x: 0.5, y: 0.83)
        #expect(below.red < dark.red * 0.7)
        #expect(try pixel(rendered, x: 0.5, y: 0.97).isClose(to: dark, within: 0.02))
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: Self.red))
    }

    @Test func cropMasksWithoutMovingOrResizing() async throws {
        let url = try makeImage(Self.red, width: 320, height: 180)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        project.background = .color(Self.blue)
        var still = clip(image)
        still.visual.crop.left = 0.5
        project.tracks[0].clips = [still]
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        // The left half is cut away; the right half stays exactly where it was.
        #expect(try pixel(rendered, x: 0.25, y: 0.5).isClose(to: Self.blue))
        #expect(try pixel(rendered, x: 0.75, y: 0.5).isClose(to: Self.red))
        #expect(try pixel(rendered, x: 0.52, y: 0.05).isClose(to: Self.red))
    }

    @Test func roundedCornersShowTheBackground() async throws {
        let url = try makeImage(Self.red, width: 320, height: 180)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        project.background = .color(Self.blue)
        project.frame = PictureFrame(corners: 0.3)
        project.tracks[0].clips = [clip(image)]
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        #expect(try pixel(rendered, x: 0.01, y: 0.02).isClose(to: Self.blue))
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: Self.red))
    }

    @Test func theFrameInsetsAndRoundsThePicture() async throws {
        let url = try makeImage(Self.red, width: 320, height: 180)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        project.tracks[0].clips = [clip(image)]
        project.setBackground(.color(Self.blue))
        project.frame?.shadow = 0
        project.frame?.corners = 0.3
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        // A tenth of the canvas on each side shows the background; past it is the picture, rounded at its corners.
        #expect(try pixel(rendered, x: 0.05, y: 0.5).isClose(to: Self.blue))
        #expect(try pixel(rendered, x: 0.5, y: 0.05).isClose(to: Self.blue))
        #expect(try pixel(rendered, x: 0.15, y: 0.5).isClose(to: Self.red))
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: Self.red))
        #expect(try pixel(rendered, x: 0.11, y: 0.12).isClose(to: Self.blue))
    }

    @Test func meshGradientDrawsItsPools() async throws {
        let lilac = try #require(MeshFill.presets.first)
        var project = Project()
        project.addBackground(.mesh(lilac), at: .zero, target: .existing(project.tracks[0].id))
        let rendered = try await frame(of: project, urls: [:], at: 1)
        // The cyan pool on top sits at the top edge, 80% across; the base lilac shows where the pools thin out.
        #expect(try pixel(rendered, x: 0.8, y: 0.01).isClose(to: RGBA(hue: 182, saturation: 100, lightness: 56), within: 0.1))
        let middle = try pixel(rendered, x: 0.5, y: 0.5)
        #expect(middle.blue > middle.green)
    }

    @Test func gradientRunsFromItsFirstColor() async throws {
        var project = Project()
        project.addBackground(.gradient(GradientFill(from: Self.red, to: Self.blue, angle: 0)), at: .zero, target: .existing(project.tracks[0].id))
        let rendered = try await frame(of: project, urls: [:], at: 1)
        #expect(try pixel(rendered, x: 0.02, y: 0.5).isClose(to: Self.red, within: 0.1))
        #expect(try pixel(rendered, x: 0.98, y: 0.5).isClose(to: Self.blue, within: 0.1))
    }

    /// The milestone's goal: a picture-in-picture video with a title over a gradient background.
    @Test func pictureInPictureWithATitleOverAGradient() async throws {
        let mainURL = try await makeVideo(Self.red)
        let insetURL = try await makeVideo(Self.green)
        let main = asset(mainURL, kind: .video)
        let inset = asset(insetURL, kind: .video)
        var project = Project()
        project.assets = [main, inset]
        project.background = .gradient(GradientFill(from: .black, to: .white, angle: 90))
        project.frame = PictureFrame(shadow: 40, corners: 0.05)
        var framed = clip(main)
        framed.visual = Visual(scale: 0.8)
        project.tracks[0].clips = [framed]
        var small = clip(inset)
        small.visual = Visual(x: 0.3, y: -0.3, scale: 0.25)
        project.tracks[1].clips = [small]
        var title = Title(text: "██████", size: 50, animationIn: .none, animationOut: .none)
        title.color = .white
        project.addTitle(title, visual: Visual(y: 0.3), at: .zero, target: .new(at: project.tracks.count))
        let rendered = try await frame(of: project, urls: [main.id: mainURL, inset.id: insetURL], at: 1)

        // The gradient shows around the main video, dark at the top and light at the bottom.
        let top = try pixel(rendered, x: 0.5, y: 0.02)
        let bottom = try pixel(rendered, x: 0.5, y: 0.98)
        #expect(top.red < 0.25 && bottom.red > 0.75)
        // The main video fills the middle, the inset sits top right, and the title sits low in the middle.
        #expect(try pixel(rendered, x: 0.3, y: 0.5).isClose(to: Self.red, within: 0.2))
        #expect(try pixel(rendered, x: 0.74, y: 0.26).isClose(to: Self.green, within: 0.2))
        #expect(try pixel(rendered, x: 0.5, y: 0.8).isClose(to: .white, within: 0.15))
    }

    @Test func darkTonesComeThroughUnchanged() async throws {
        // How the compositor reads frames and how it writes them have to agree, or the picture lightens or
        // darkens, most of all in its darker tones.
        let gray = RGBA(red: 0.1, green: 0.1, blue: 0.12)
        let url = try await makeVideo(gray)
        let video = asset(url, kind: .video)
        var project = Project()
        project.assets = [video]
        project.tracks[0].clips = [clip(video)]
        let composited = try await pixel(frame(of: project, urls: [video.id: url], at: 1), x: 0.5, y: 0.5)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let original = try pixel(try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image, x: 0.5, y: 0.5)
        #expect(abs(composited.red - original.red) < 0.02)
        #expect(abs(composited.blue - original.blue) < 0.02)
    }

    @Test func theBlankTrackHasAFrameForEveryFrame() async throws {
        // Text over nothing else: the blank track is the only video under it, and a paused player only draws again
        // when the frame under the playhead changes. Stretched, one frame would cover everything, and the text
        // wouldn't show after a seek.
        var project = Project()
        _ = project.addTitle(Title(text: "Hi"), at: .zero, target: .existing(project.tracks[0].id))
        project.tracks[0].clips[0].duration = Time(seconds: 25)
        let built = try await CompositionBuilder.build(project: project, assets: { _ in nil })
        let base = try #require(built.composition.tracks(withMediaType: .video).first)
        #expect(base.segments.count == 3)
        #expect(base.segments.allSatisfy { $0.timeMapping.source.duration == $0.timeMapping.target.duration })
        #expect(base.segments.last?.timeMapping.target.end == Time(seconds: 25).cmTime)
        let blank = try #require(try await AVURLAsset(url: BlankVideo.url()).loadTracks(withMediaType: .video).first)
        #expect(try await blank.load(.nominalFrameRate) >= 29)
    }

    @Test func aBackgroundAloneIsThePicture() async throws {
        // Two seconds of silence: sound, with nothing visual on the timeline.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "silence.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let sound = Asset(id: UUID(), fileName: url.lastPathComponent, displayName: "Silence", kind: .audio,
                          duration: Time(seconds: 2), hasAudio: true)
        var project = Project()
        project.assets = [sound]
        project.tracks[0].clips = [clip(sound)]
        #expect(!project.hasPicture)
        var withBackground = project
        withBackground.background = .color(Self.blue)
        #expect(withBackground.hasPicture)
        // Choosing a background gives the composition a picture, so it's a rebuild rather than a look change.
        #expect(CompositionBuilder.layout(of: withBackground) != CompositionBuilder.layout(of: project))
        let image = try await frame(of: withBackground, urls: [sound.id: url], at: 1)
        #expect(try pixel(image, x: 0.5, y: 0.5).isClose(to: Self.blue))
    }

    @Test func lookChangesShowWithoutARebuild() async throws {
        var project = Project()
        project.canvas = canvas
        project.background = .color(Self.red)
        project.addBackground(.color(Self.blue), at: .zero, target: .existing(project.tracks[0].id))
        let built = try await CompositionBuilder.build(project: project, assets: { _ in nil })
        let plan = try #require(built.plan)
        var changed = project
        changed.background = .color(Self.green)
        let fillClip = try #require(changed.tracks[0].clips.first)
        changed.changeVisual(of: [fillClip.id]) { $0.opacity = 0.5 }
        plan.update { $0.takeLook(from: changed) { fill in if case let .color(color) = fill { .color(color) } else { nil } } }
        #expect(plan.current.background == .color(Self.green))
        #expect(plan.current.layers.first?.visual.opacity == 0.5)
    }

    @Test func mutedTracksDontDraw() async throws {
        let url = try makeImage(Self.red, width: 320, height: 180)
        let image = asset(url, kind: .image)
        var project = Project()
        project.assets = [image]
        project.background = .color(Self.blue)
        project.tracks[0].clips = [clip(image)]
        project.tracks[0].isMuted = true
        let rendered = try await frame(of: project, urls: [image.id: url], at: 1)
        #expect(try pixel(rendered, x: 0.5, y: 0.5).isClose(to: Self.blue))
    }
}
