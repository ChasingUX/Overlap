import AVFoundation
import Testing
@testable import Overlap

/// Finding where a video loops, from frame prints made up here and from a video written for the test, and trimming
/// a clip to a loop.
struct LoopTests {
    static let rate = 30.0

    /// A soft bright bar on black for each frame, a quarter of the frame wide, at a position from 0 (left) to 1
    /// (right). Thinner, it would pass out of its own way between frames, as little in real footage does.
    func prints(_ positions: [Double]) -> FramePrints {
        var values: [Float] = []
        for position in positions {
            let center = position * Double(FramePrints.width - 1)
            for _ in 0..<FramePrints.height {
                for x in 0..<FramePrints.width {
                    values.append(Float(max(0, 1 - abs(Double(x) - center) / 8)))
                }
            }
        }
        return FramePrints(times: positions.indices.map { Double($0) / Self.rate }, values: values)
    }

    /// A bar swinging left and right once a second, like a pendulum.
    func swing(seconds: Double) -> [Double] {
        (0..<Int(seconds * Self.rate)).map { 0.5 + 0.4 * sin(2 * .pi * Double($0) / Self.rate) }
    }

    @Test func aSwingLoopsOnceEachWholeSwing() {
        let prints = prints(swing(seconds: 4))
        let suggested = prints.suggestedLoops()
        #expect(!suggested.isEmpty)
        #expect(suggested.allSatisfy { abs($0.length - $0.length.rounded()) < 0.05 })
        #expect(suggested.contains { abs($0.length - 1) < 0.05 })
    }

    @Test func halfASwingIsntALoop() {
        // Half a second in, the bar is back in the middle but going the other way: the join would jerk.
        let prints = prints(swing(seconds: 3))
        let loops = prints.loops(from: 0, minimumLength: 0.3)
        #expect(!loops.contains { abs($0.length - 0.5) < 0.1 })
        #expect(loops.first.map { abs($0.length - 1) < 0.05 } == true)
        #expect(loops.first?.start == 0)
    }

    @Test func aSwingRepeatsEverySecondFromAnywhere() throws {
        let prints = prints(swing(seconds: 4))
        let repetition = try #require(prints.repetition())
        #expect(repetition.frames == 30)
        let loops = prints.loops(repeating: repetition, from: 0.5)
        #expect(loops.map { ($0.length * 10).rounded() / 10 } == [1, 2, 3])
        #expect(loops.allSatisfy { abs($0.start - 0.5) < 0.001 })
    }

    @Test func aWanderingMoveDoesntRepeat() {
        // Swinging faster and faster: the bar comes back to places, but never moving the same way for long.
        let prints = prints((0..<120).map { 0.5 + 0.4 * sin(Double($0 * $0) / 900) })
        #expect(prints.repetition() == nil)
    }

    @Test func aStillShotLoopsAnywhere() {
        let prints = prints(Array(repeating: 0.5, count: 60))
        #expect(prints.isStill)
    }

    @Test func aHeldFrameIsntSuggested() {
        // Two seconds of black match each other perfectly, but there's nothing in them to loop.
        var values = [Float](repeating: 0, count: 60 * FramePrints.size)
        values += prints(swing(seconds: 3)).values
        let prints = FramePrints(times: (0..<150).map { Double($0) / Self.rate }, values: values)
        let suggested = prints.suggestedLoops()
        #expect(!suggested.isEmpty)
        #expect(!suggested.contains { $0.end <= 2.05 })
    }

    @Test func aWrittenVideoLoopsWhereItRepeats() async throws {
        let url = try await writeSwingVideo(seconds: 3)
        let prints = try #require(await FramePrints.make(for: url) { _ in })
        #expect(prints.count == 90)
        #expect(abs(prints.rate - 30) < 0.5)
        let suggested = prints.suggestedLoops()
        #expect(suggested.contains { abs($0.length - 1) < 0.05 })
    }

    // MARK: Trimming

    @Test func trimmingToALoopKeepsThePictureInPlace() {
        var project = Project()
        let video = Asset(id: UUID(), fileName: "v.mov", displayName: "v.mov", kind: .video, duration: Time(seconds: 20), hasAudio: false)
        project.assets = [video]
        let clip = Clip(assetID: video.id, start: Time(seconds: 5), sourceStart: .zero, duration: Time(seconds: 10))
        project.tracks[0].clips = [clip]
        project.trimToLoop(clip.id, from: Time(seconds: 2), to: Time(seconds: 5))
        let trimmed = project.tracks[0].clips[0]
        #expect(trimmed.start == Time(seconds: 7))
        #expect(trimmed.sourceStart == Time(seconds: 2))
        #expect(trimmed.duration == Time(seconds: 3))
    }

    @Test func aLongerLoopMovesTheNextClipAlong() {
        var project = Project()
        let video = Asset(id: UUID(), fileName: "v.mov", displayName: "v.mov", kind: .video, duration: Time(seconds: 20), hasAudio: false)
        project.assets = [video]
        let first = Clip(assetID: video.id, start: .zero, sourceStart: .zero, duration: Time(seconds: 4))
        let next = Clip(assetID: video.id, start: Time(seconds: 4), sourceStart: .zero, duration: Time(seconds: 4))
        project.tracks[0].clips = [first, next]
        // In place it would start at 1 s and run into the next clip, so it keeps its start instead.
        project.trimToLoop(first.id, from: Time(seconds: 1), to: Time(seconds: 6))
        let clips = project.tracks[0].clips
        #expect(clips[0].start == .zero && clips[0].sourceStart == Time(seconds: 1) && clips[0].duration == Time(seconds: 5))
        #expect(clips[1].start == Time(seconds: 5))
    }

    // MARK: Sources

    /// The swinging bar as an H.264 movie at 30 fps.
    func writeSwingVideo(seconds: Double) async throws -> URL {
        let width = 320
        let height = 180
        let folder = FileManager.default.temporaryDirectory.appending(path: "LoopTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "swing.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let positions = swing(seconds: seconds)
        for (index, position) in positions.enumerated() {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let frame = try #require(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            let base = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            let center = position * Double(width - 1)
            for y in 0..<height {
                for x in 0..<width {
                    let level = UInt8(max(0, 1 - abs(Double(x) - center) / 80) * 255)
                    let pixel = base + y * rowBytes + x * 4
                    pixel[0] = level
                    pixel[1] = level
                    pixel[2] = level
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(positions.count), timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}
