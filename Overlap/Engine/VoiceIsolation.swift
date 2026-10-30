import AudioToolbox
import Foundation

/// Apple's on-device voice isolation, run inside an audio tap: it keeps speech and takes out background noise and
/// room echo. Set up in the tap's prepare, once the format is known, and used only from the tap's own thread.
/// If the unit can't take the tap's format, it's never made and the sound passes through untouched.
final class VoiceIsolation {
    private let unit: AudioUnit
    /// A copy of each block before it's processed, which the unit reads as its input.
    private let input: UnsafeMutableAudioBufferListPointer
    private let maximumFrames: Int
    private var sampleTime = 0.0
    /// Where the next block should start; a jump means a seek, and the unit forgets what it heard before.
    private var expectedStart: Double?

    /// How much of the isolated voice is used, in percent.
    static let strength: Float = 100

    init?(format: AudioStreamBasicDescription, maximumFrames: Int) {
        // The tap hands over one buffer per channel, which is what the unit works in.
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return nil }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let made else { return nil }
        unit = made
        self.maximumFrames = maximumFrames

        let channels = Int(format.mChannelsPerFrame)
        input = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            input[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maximumFrames * 4),
                                       mData: UnsafeMutableRawPointer.allocate(byteCount: maximumFrames * 4, alignment: 16))
        }

        var streamFormat = format
        var frames = UInt32(maximumFrames)
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frameCount, ioData in
            let isolation = Unmanaged<VoiceIsolation>.fromOpaque(refCon).takeUnretainedValue()
            guard let ioData else { return kAudio_ParamError }
            let destination = UnsafeMutableAudioBufferListPointer(ioData)
            let bytes = Int(frameCount) * 4
            for index in 0..<min(destination.count, isolation.input.count) {
                if destination[index].mData == nil {
                    destination[index].mData = isolation.input[index].mData
                } else if let target = destination[index].mData, let source = isolation.input[index].mData {
                    target.copyMemory(from: source, byteCount: bytes)
                }
                destination[index].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, size) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, size) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else {
            // Giving up here still runs deinit, which lets the unit go.
            return nil
        }
        // The standard model's delay holds steady. The high-quality one loads in the background and changes its delay
        // when it's ready, a few seconds in, which would make the sound jump.
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice), 0)
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, Self.strength, 0)
    }

    deinit {
        dispose()
    }

    private func dispose() {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for buffer in input {
            buffer.mData?.deallocate()
        }
        // The list itself was allocated with malloc.
        free(input.unsafeMutablePointer)
    }

    /// How far the isolated voice trails the original, in seconds, for sound in this format. Asked of a unit made just to
    /// find out, once per format.
    @MainActor
    static func latency(sampleRate: Double, channels: Int) -> Double {
        let key = "\(sampleRate)-\(channels)"
        if let known = latencies[key] { return known }
        let latency = VoiceIsolation(format: format(sampleRate: sampleRate, channels: channels), maximumFrames: 4096)?.latency ?? 0
        latencies[key] = latency
        return latency
    }

    @MainActor private static var latencies: [String: Double] = [:]

    /// The format audio taps hand over: 32-bit float, one buffer per channel.
    static func format(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// How far the isolated voice trails the original, in seconds.
    var latency: Double {
        var seconds = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
        return seconds
    }

    /// Isolates the voice in one block, in place. `start` is where it begins on the timeline, in frames.
    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double) {
        guard frames <= maximumFrames else { return }
        let blocks = UnsafeMutableAudioBufferListPointer(buffers)
        guard blocks.count == input.count else { return }
        if let expectedStart, abs(expectedStart - start) > 2 {
            AudioUnitReset(unit, kAudioUnitScope_Global, 0)
        }
        expectedStart = start + Double(frames)
        for index in 0..<blocks.count {
            guard let source = blocks[index].mData, let copy = input[index].mData else { return }
            copy.copyMemory(from: source, byteCount: frames * 4)
        }
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = sampleTime
        stamp.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        if AudioUnitRender(unit, &flags, &stamp, 0, UInt32(frames), buffers) != noErr {
            // Whatever went wrong, the original sound plays.
            for index in 0..<blocks.count {
                if let target = blocks[index].mData, let copy = input[index].mData {
                    target.copyMemory(from: copy, byteCount: frames * 4)
                }
            }
        }
    }
}
