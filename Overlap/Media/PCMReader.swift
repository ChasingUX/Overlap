import AVFoundation

/// Reads decoded audio as interleaved 32-bit float samples.
enum PCMReader {
    static func floatSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
    }

    /// Calls `handle` with each decoded buffer, in order. `output` must use float settings.
    nonisolated(nonsending) static func read(_ asset: AVAsset, output: AVAssetReaderOutput, _ handle: (UnsafeBufferPointer<Float>) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var samples: [Float] = []
        while let ready = try await provider.next() {
            ready.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                samples.withUnsafeMutableBytes { bytes in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                }
                samples.withUnsafeBufferPointer(handle)
            }
        }
    }
}
