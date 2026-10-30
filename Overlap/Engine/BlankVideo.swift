import AVFoundation

/// A one-second black movie, made once per launch in the temporary folder. Stretched under the whole timeline, it gives
/// the composition a video track everywhere, so the compositor draws backgrounds, images and text even where no
/// video plays.
enum BlankVideo {
    /// Made once per launch; everyone asking at the same time waits for the same one.
    @MainActor private static var making: Task<URL, Error>?

    @MainActor
    static func url() async throws -> URL {
        if let making { return try await making.value }
        let task = Task { try await make() }
        making = task
        do {
            return try await task.value
        } catch {
            making = nil
            throw error
        }
    }

    /// Written under a temporary name and moved into place, so nothing ever reads it half-written.
    @concurrent
    private static func make() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
        let url = folder.appending(path: "Overlap-blank-\(ProcessInfo.processInfo.processIdentifier).mov")
        let partial = folder.appending(path: "Overlap-blank-\(UUID().uuidString).mov")
        try await write(to: partial)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    @concurrent
    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                                         size: CVImageSize(width: 64, height: 64))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        var frame = try CVMutablePixelBuffer(attributes)
        frame.accessUnsafeMutableRawPlaneBytes { planes in
            for plane in planes {
                plane.bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        try await receiver.append(CVReadOnlyPixelBuffer(frame), with: .zero)
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
